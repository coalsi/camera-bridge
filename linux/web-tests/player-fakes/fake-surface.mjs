// A surface for cell and session tests: the same methods as MseSurface, and it throws when the cell breaks one of the rules MSE needs.
//   * an append needs the init of its file to have been appended last;
//   * a chain (or the first append) must start at a key part, and a part that is not a chain break must continue the previous one;
//   * tfdt + timestampOffset must equal the start the cell believes in (this is what makes the time arithmetic checkable end to end);
//   * a seek shows a picture only when at least 700 ms of the same buffered range lie after it (the decoders' hold-back).
import { unsupportedMessage } from '../../web/js/nvr/planner.js';
import { decodeBytes } from './fake-archive.mjs';

const EPSILON = 1e-6;

export class FakeSurface {
  constructor({ timers, holdBackMs = 700, seekMs = 5, appendMs = 2, unsupported = () => false } = {}) {
    this.timers = timers;
    this.holdBackSec = holdBackMs / 1000;
    this.seekMs = seekMs;
    this.appendMs = appendMs;
    this.unsupported = unsupported;
    this.generation = 0;
    this.mime = null;
    this.log = [];
    this.segments = [];            // { startSec, endSec, id, key }
    this.activeInit = null;
    this.last = null;              // the segment appended last
    this.time = 0;
    this.playing = false;
    this.playedFrom = 0;
    this.playedAt = 0;
    this.stalledMs = 0;
    this.destroyed = false;
    this.listeners = new Set();
    this.busy = 0;
    this.worstBusy = 0;
  }

  async #work(ms) {
    this.busy += 1;
    this.worstBusy = Math.max(this.worstBusy, this.busy);
    await this.timers.sleep(ms);
    this.busy -= 1;
  }

  #guard() {
    if (this.destroyed) throw Object.assign(new Error('destroyed'), { name: 'AbortError' });
  }

  onEvent(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }

  emit(type) { for (const fn of [...this.listeners]) fn({ type }); }

  async open(mime) {
    this.#guard();
    if (this.mime === mime) return;
    if (this.unsupported(mime)) throw Object.assign(new Error(unsupportedMessage(mime)), { name: 'Unsupported', mime });
    if (this.mime !== null) this.#wipe();
    this.mime = mime;
    this.log.push({ op: 'open', mime });
  }

  #wipe() {
    this.generation += 1;
    this.segments = [];
    this.activeInit = null;
    this.last = null;
    this.playing = false;
  }

  async reset() {
    this.#guard();
    this.#wipe();
    this.log.push({ op: 'reset' });
  }

  async appendInit(bytes) {
    this.#guard();
    if (!this.mime) throw new Error('append before open');
    const info = decodeBytes(bytes);
    if (info.kind !== 'init') throw new Error('appendInit was given a media segment');
    await this.#work(this.appendMs);
    this.activeInit = info.file;
    this.log.push({ op: 'appendInit', file: info.file });
  }

  async append(bytes, { timestampOffsetSec, chainBreak = false, startSec, endSec, key = true } = {}) {
    this.#guard();
    if (!this.mime) throw new Error('append before open');
    const info = decodeBytes(bytes);
    if (info.kind !== 'media') throw new Error('append was given an init segment');
    if (this.activeInit !== info.file) throw new Error(`${info.id}: appended without the init of its file (last init: ${this.activeInit})`);
    const trueStart = info.tfdtTicks / 90_000 + timestampOffsetSec;
    const trueEnd = trueStart + info.durationTicks / 90_000;
    if (Math.abs(trueStart - startSec) > EPSILON || Math.abs(trueEnd - endSec) > EPSILON) {
      throw new Error(`${info.id}: tfdt + offset puts it at ${trueStart}..${trueEnd} but the cell believes ${startSec}..${endSec}`);
    }
    if (key !== info.key) throw new Error(`${info.id}: key flag ${key} does not match the segment (${info.key})`);
    if (chainBreak || !this.last) {
      if (!info.key) throw new Error(`${info.id}: a chain must start at a key part`);
    } else if (Math.abs(this.last.endSec - trueStart) > 0.003) {
      throw new Error(`${info.id}: appended as a continuation but the previous segment ${this.last.id} ends at ${this.last.endSec}, not ${trueStart}`);
    }
    await this.#work(this.appendMs);
    const segment = { startSec: trueStart, endSec: trueEnd, id: info.id, key: info.key };
    this.segments = this.segments.filter((s) => s.id !== info.id);
    this.segments.push(segment);
    this.last = segment;
    this.log.push({ op: 'append', id: info.id, chainBreak, key: info.key, startSec: trueStart, endSec: trueEnd });
  }

  held() {
    const out = [];
    for (const segment of [...this.segments].sort((a, b) => a.startSec - b.startSec)) {
      const last = out[out.length - 1];
      if (last && segment.startSec <= last.end + 0.003) last.end = Math.max(last.end, segment.endSec);
      else out.push({ start: segment.startSec, end: segment.endSec });
    }
    return out;
  }

  /** The browser threw a range away by itself. */
  drop(startSec, endSec) {
    this.segments = this.segments.filter((s) => !(s.startSec >= startSec && s.startSec < endSec));
  }

  async seek(sec) {
    this.#guard();
    this.#freeze();
    await this.#work(this.seekMs);
    const range = this.held().find((r) => sec >= r.start && sec < r.end);
    const presented = !!range && range.end - sec >= this.holdBackSec;
    if (presented) this.time = sec;
    this.log.push({ op: 'seek', sec, presented, at: this.timers.now() });
    return { presented, mediaTime: presented ? sec : null };
  }

  async play() {
    this.#guard();
    this.#freeze();
    this.playing = true;
    this.playedFrom = this.time;
    this.playedAt = this.timers.now();
    this.log.push({ op: 'play' });
    await this.#work(this.seekMs);
    return { presented: true, mediaTime: this.time };
  }

  pause() {
    this.#freeze();
    this.playing = false;
    this.log.push({ op: 'pause' });
  }

  #freeze() {
    if (!this.playing) return;
    this.time = this.currentTime();
    this.playedFrom = this.time;
    this.playedAt = this.timers.now();
  }

  /** While playing the position runs with the timers, and stops (stalls) at the end of what is held. */
  currentTime() {
    if (!this.playing) return this.time;
    const wanted = this.playedFrom + (this.timers.now() - this.playedAt) / 1000;
    const range = this.held().find((r) => this.playedFrom >= r.start - 0.003 && this.playedFrom < r.end);
    if (!range) return this.playedFrom;
    if (wanted > range.end) { this.stalledMs += (wanted - range.end) * 1000; return range.end; }
    return wanted;
  }

  async evict(keepAroundSec) {
    this.log.push({ op: 'evict', keepAroundSec });
  }

  destroy() {
    this.destroyed = true;
    this.log.push({ op: 'destroy' });
  }

  // Test helpers

  appends() { return this.log.filter((entry) => entry.op === 'append'); }
  seeks() { return this.log.filter((entry) => entry.op === 'seek'); }
  presents() { return this.seeks().filter((entry) => entry.presented); }
  ops() { return this.log.map((entry) => entry.op === 'append' ? `append ${entry.id}${entry.chainBreak ? '!' : ''}` : entry.op); }
}
