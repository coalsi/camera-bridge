// One tile's picture: a <video> fed through one MediaSource and one SourceBuffer in 'segments' mode.
//
// The surface knows nothing about cameras or plans. It is told bytes and buffer times and keeps four promises:
//   * operations on the SourceBuffer never overlap (one at a time, in the order asked);
//   * a chain break (a jump to somewhere else) is `abort()` then the new `timestampOffset`, then the bytes, and the init segment stays, unless
//     the policy's `initAfterBreak` asks for the init once more between the offset and the bytes (task T06's protocol abort + offset + init);
//   * a codec change rebuilds the MediaSource behind a held picture (the last frame drawn on a canvas), so the tile never flashes; the held
//     picture is the one on screen: the page's straightened canvas over the video when `holdFrom()` gives one (js/live/straighten.js);
//   * it never removes the buffered range under the playhead (the unit that holds the keepAround time stays; see planEviction).
// Buffer times are seconds on the page's time line: (epoch ms - the catalog's baseMs) / 1000.
import { realTimers } from './clock.js';
import { DEFAULT_POLICY, MESSAGES, planEviction, rangeHolds, unsupportedMessage } from './planner.js';

export const BUDGET_BYTES = 16 * 1_048_576;      // at most this much held per tile
const PRESENT_TIMEOUT_MS = 1500;                // a seek that shows no frame within this has failed
const SEEKED_FALLBACK_MS = 250;                 // after `seeked`, a frame callback this late is not coming (the same frame was already shown)
const FRAME_TOLERANCE_SEC = 0.75;               // a frame this near the target counts as the target's picture
const SOURCE_OPEN_TIMEOUT_MS = 3000;
const HOLD_BACK_SEC = 0.25;                     // a target this close before a held range is pulled into it
const REMOVE_SHIFT_SEC = 0.001;                 // remove() ranges are shifted 1 ms earlier so the next unit's first frame is never caught

function unsupported(mime) {
  const error = new Error(unsupportedMessage(mime));
  error.name = 'Unsupported';
  error.mime = mime;
  return error;
}

function waitForUpdateEnd(sourceBuffer) {
  let cancel = () => {};
  const promise = new Promise((resolve, reject) => {
    let failed = false;
    const onError = () => { failed = true; };
    const onEnd = () => {
      cancel();
      if (failed) reject(new Error(MESSAGES.playerFailed));
      else resolve();
    };
    cancel = () => {
      sourceBuffer.removeEventListener('updateend', onEnd);
      sourceBuffer.removeEventListener('error', onError);
      sourceBuffer.removeEventListener('abort', onError);
    };
    sourceBuffer.addEventListener('updateend', onEnd);
    sourceBuffer.addEventListener('error', onError);
    sourceBuffer.addEventListener('abort', onError);
  });
  return { promise, cancel };
}

export class MseSurface {
  #video;
  #canvas;
  #holdFrom;
  #policy;
  #timers;
  #scope;
  #budget;
  #rate = 1;
  #mediaSource = null;
  #sourceBuffer = null;
  #url = null;
  #mime = null;
  #generation = 0;
  #offsetSec = null;
  #initBytes = null;                // the init segment last appended to this buffer; repeated behind an abort() when the policy says so
  #ledger = [];
  #queue = Promise.resolve();
  #listeners = new Set();
  #holding = false;
  #destroyed = false;
  #forwarders = [];

  /**
   * `holdFrom()` gives the element whose picture is held instead of the video's own frame (a canvas the page draws the video on, drawn that
   * moment), or null for the video's frame.
   */
  constructor({ video, holdCanvas = null, holdFrom = null, policy = DEFAULT_POLICY, timers = realTimers, scope = globalThis, budgetBytes = BUDGET_BYTES }) {
    this.#video = video;
    this.#canvas = holdCanvas;
    this.#holdFrom = holdFrom;
    this.#policy = policy;
    this.#timers = timers;
    this.#scope = scope;
    this.#budget = budgetBytes;
    if (holdCanvas) holdCanvas.style.display = 'none';
    for (const type of ['waiting', 'ended', 'error']) {
      const forward = () => this.#emit({ type });
      video.addEventListener(type, forward);
      this.#forwarders.push([type, forward]);
    }
  }

  /** True when this browser can decode `mime` through MediaSource (or ManagedMediaSource on an iPhone). */
  static isSupported(mime, scope = globalThis) {
    const Source = scope.MediaSource ?? scope.ManagedMediaSource;
    return !!Source && typeof Source.isTypeSupported === 'function' && Source.isTypeSupported(mime);
  }

  /** Counts MediaSource rebuilds. Anything the owner remembers about the buffer is void when this changes. */
  get generation() { return this.#generation; }
  get mime() { return this.#mime; }

  /** fn({ type: 'waiting' | 'ended' | 'error' | 'startstreaming' | 'endstreaming' }); returns the unsubscribe function. */
  onEvent(fn) {
    this.#listeners.add(fn);
    return () => this.#listeners.delete(fn);
  }

  /** Makes the surface ready for `mime`: builds the MediaSource, or rebuilds it (or changes the type) when the codec string differs. */
  open(mime) {
    return this.#serial(async () => {
      if (this.#sourceBuffer && this.#mime === mime) return;
      if (!MseSurface.isSupported(mime, this.#scope)) throw unsupported(mime);
      if (!this.#sourceBuffer) {
        await this.#build(mime);
      } else if (this.#policy.mimeChange === 'changeType' && typeof this.#sourceBuffer.changeType === 'function') {
        await this.#idle(this.#sourceBuffer);
        this.#sourceBuffer.changeType(mime);
        this.#mime = mime;
        this.#initBytes = null;
      } else {
        await this.#rebuild(mime);
      }
    });
  }

  /** Throws the buffer away and builds it again for the same codec (after a decoder error). The last picture is held meanwhile. */
  reset() {
    return this.#serial(async () => {
      if (this.#mime) await this.#rebuild(this.#mime);
    });
  }

  appendInit(bytes) {
    return this.#serial(async () => {
      const sourceBuffer = this.#need();
      await this.#idle(sourceBuffer);
      await this.#appendBuffer(sourceBuffer, bytes);
      this.#initBytes = bytes;
    });
  }

  /**
   * Appends one media segment. `chainBreak` (or a different `timestampOffsetSec`) first resets the parser with abort() and sets the offset, and
   * with the policy's `initAfterBreak` the init segment appended last comes once more before the bytes (abort + offset + init).
   * `startSec`, `endSec` and `key` describe the segment for memory accounting: a key segment starts a GOP unit that is removed as a whole.
   */
  append(bytes, { timestampOffsetSec, chainBreak = false, startSec, endSec, key = true } = {}) {
    return this.#serial(async () => {
      const sourceBuffer = this.#need();
      await this.#idle(sourceBuffer);
      const offsetChanged = typeof timestampOffsetSec === 'number' && this.#offsetSec !== timestampOffsetSec;
      if (chainBreak || offsetChanged) {
        sourceBuffer.abort();
        if (typeof timestampOffsetSec === 'number') {
          sourceBuffer.timestampOffset = timestampOffsetSec;
          this.#offsetSec = timestampOffsetSec;
        }
        if (this.#policy.initAfterBreak && this.#initBytes) await this.#appendBuffer(sourceBuffer, this.#initBytes);
      }
      await this.#appendBuffer(sourceBuffer, bytes);
      if (Number.isFinite(startSec) && Number.isFinite(endSec)) this.#ledger.push({ startSec, endSec, bytes: bytes.byteLength, key });
    });
  }

  /**
   * Shows the picture at `bufferSec`. Resolves { presented, mediaTime, via }: presented is true when a frame near the target was shown, false after
   * 1.5 s without one; `via` says what proved it ('frame-callback', 'seeked' when the page is not being drawn, or 'timeout').
   */
  async seek(bufferSec) {
    this.#alive();
    const target = this.#pullIntoHeld(bufferSec);
    const frame = this.#nextFrame(target, PRESENT_TIMEOUT_MS);
    this.#video.currentTime = target;
    const result = await frame;
    if (this.#holding) this.#release();
    return result;
  }

  /** Starts playing; resolves { presented } when the first frame after the start was shown. Rejects when the browser refuses to play. */
  async play() {
    this.#alive();
    this.#video.playbackRate = this.#rate;
    const frame = this.#nextFrame(null, PRESENT_TIMEOUT_MS);
    await this.#video.play();
    return frame;
  }

  pause() { this.#video.pause(); }

  get rate() { return this.#rate; }

  /** The speed the video plays at (1 to 10, the Monitor's steps); it applies at once and to every later play. */
  setRate(rate) {
    this.#rate = rate;
    this.#video.defaultPlaybackRate = rate;   // a new source (a rebuilt MediaSource) starts at this
    this.#video.playbackRate = rate;
  }

  /** The video's position in buffer seconds. */
  currentTime() { return this.#video.currentTime; }

  /** The ranges the video element holds, in buffer seconds. */
  held() {
    const sourceBuffer = this.#sourceBuffer;
    if (!sourceBuffer || this.#destroyed) return [];
    try {
      const ranges = sourceBuffer.buffered;
      const out = [];
      for (let i = 0; i < ranges.length; i += 1) out.push({ start: ranges.start(i), end: ranges.end(i) });
      return out;
    } catch {
      return [];
    }
  }

  /** Removes what lies farthest from `keepAroundSec` until at most the budget is held; the GOP unit holding `keepAroundSec` always stays. */
  evict(keepAroundSec) {
    return this.#serial(() => this.#evict(keepAroundSec, this.#budget));
  }

  destroy() {
    if (this.#destroyed) return;
    this.#destroyed = true;
    for (const [type, forward] of this.#forwarders) this.#video.removeEventListener(type, forward);
    this.#forwarders = [];
    this.#listeners.clear();
    this.#detach();
    if (this.#canvas) {
      this.#canvas.style.display = 'none';
      this.#canvas.width = 0;
      this.#canvas.height = 0;
    }
    this.#sourceBuffer = null;
    this.#mediaSource = null;
    this.#ledger = [];
  }

  // MARK: Building

  async #build(mime) {
    const Source = this.#scope.MediaSource ?? this.#scope.ManagedMediaSource;
    const video = this.#video;
    video.muted = true;
    video.playsInline = true;
    video.disableRemotePlayback = true;            // ManagedMediaSource needs it before it opens; it does no harm for MediaSource
    const mediaSource = new Source();
    const opened = new Promise((resolve, reject) => {
      const timer = this.#timers.setTimeout(() => reject(new Error(MESSAGES.playerFailed)), SOURCE_OPEN_TIMEOUT_MS);
      mediaSource.addEventListener('sourceopen', () => { this.#timers.clearTimeout(timer); resolve(); }, { once: true });
    });
    for (const type of ['startstreaming', 'endstreaming']) mediaSource.addEventListener(type, () => this.#emit({ type }));
    const url = this.#scope.URL.createObjectURL(mediaSource);
    this.#url = url;
    video.src = url;
    await opened;
    this.#scope.URL.revokeObjectURL(url);
    this.#url = null;
    const sourceBuffer = mediaSource.addSourceBuffer(mime);
    sourceBuffer.mode = 'segments';
    this.#mediaSource = mediaSource;
    this.#sourceBuffer = sourceBuffer;
    this.#mime = mime;
    this.#offsetSec = null;
    this.#initBytes = null;
  }

  async #rebuild(mime) {
    this.#hold();
    this.#detach();
    this.#sourceBuffer = null;
    this.#mediaSource = null;
    this.#generation += 1;
    this.#ledger = [];
    await this.#build(mime);
  }

  #detach() {
    const video = this.#video;
    if (this.#url) { this.#scope.URL.revokeObjectURL(this.#url); this.#url = null; }
    video.pause();
    video.removeAttribute('src');
    video.load();
  }

  /** Draws the frame on screen to the canvas and shows it, so a rebuilt buffer does not blank the tile. */
  #hold() {
    const canvas = this.#canvas;
    const video = this.#video;
    if (!canvas || !video.videoWidth || video.readyState < 2) return;
    try {
      const shown = this.#holdFrom?.() ?? null;
      canvas.width = shown ? shown.width : video.videoWidth;
      canvas.height = shown ? shown.height : video.videoHeight;
      canvas.getContext('2d').drawImage(shown ?? video, 0, 0);
      canvas.style.display = '';
      this.#holding = true;
    } catch {
      this.#holding = false;
    }
  }

  #release() {
    this.#holding = false;
    if (!this.#canvas) return;
    this.#canvas.style.display = 'none';
    this.#canvas.width = 0;
    this.#canvas.height = 0;
  }

  // MARK: Doing things one at a time

  #serial(task) {
    if (this.#destroyed) return Promise.reject(this.#destroyedError());
    const run = this.#queue.then(() => { this.#alive(); return task(); });
    this.#queue = run.catch(() => {});
    return run;
  }

  #destroyedError() {
    const error = new Error('The surface was destroyed.');
    error.name = 'AbortError';
    return error;
  }

  #alive() {
    if (this.#destroyed) throw this.#destroyedError();
  }

  #need() {
    if (!this.#sourceBuffer) throw new Error('The surface is not open.');
    return this.#sourceBuffer;
  }

  async #idle(sourceBuffer) {
    if (sourceBuffer.updating) await waitForUpdateEnd(sourceBuffer).promise;
  }

  async #appendBuffer(sourceBuffer, bytes, retried = false) {
    const done = waitForUpdateEnd(sourceBuffer);
    try {
      sourceBuffer.appendBuffer(bytes);
    } catch (error) {
      done.cancel();
      if (!retried && error && error.name === 'QuotaExceededError') {
        await this.#evict(this.#video.currentTime, Math.floor(this.#budget / 2));
        return this.#appendBuffer(sourceBuffer, bytes, true);
      }
      throw error;
    }
    await done.promise;
  }

  // MARK: Memory

  /** Forgets what the browser removed by itself. A part whose sound ends a frame before its picture is still held (rangeHolds), and removable. */
  #syncLedger() {
    const ranges = this.held();
    this.#ledger = this.#ledger.filter((entry) => ranges.some((r) => rangeHolds(r, entry.startSec, entry.endSec)));
  }

  async #evict(keepAroundSec, budget) {
    const sourceBuffer = this.#sourceBuffer;
    if (!sourceBuffer) return;
    this.#syncLedger();
    const { remove } = planEviction(this.#ledger, keepAroundSec, budget);
    for (const unit of remove) {
      await this.#idle(sourceBuffer);
      const done = waitForUpdateEnd(sourceBuffer);
      try {
        sourceBuffer.remove(Math.max(0, unit.startSec - REMOVE_SHIFT_SEC), Math.max(0, unit.endSec - REMOVE_SHIFT_SEC));
      } catch (error) {
        done.cancel();
        throw error;
      }
      await done.promise;
      this.#ledger = this.#ledger.filter((entry) => !unit.entries.includes(entry));
    }
  }

  // MARK: Showing a frame

  #pullIntoHeld(sec) {
    const ranges = this.held();
    if (ranges.some((r) => sec >= r.start && sec < r.end)) return sec;
    const next = ranges.filter((r) => r.start > sec && r.start - sec <= HOLD_BACK_SEC).sort((a, b) => a.start - b.start)[0];
    return next ? next.start + 0.001 : sec;
  }

  /** Resolves when the video shows a frame (near `targetSec` when given). Uses requestVideoFrameCallback and falls back to `seeked`. */
  #nextFrame(targetSec, timeoutMs) {
    const video = this.#video;
    const scope = this.#scope;
    const timers = this.#timers;
    return new Promise((resolve) => {
      let done = false;
      let handle = null;
      let fallback = null;
      const hasCallback = typeof video.requestVideoFrameCallback === 'function';
      const finish = (presented, mediaTime = null, via = 'timeout') => {
        if (done) return;
        done = true;
        if (handle !== null && typeof video.cancelVideoFrameCallback === 'function') video.cancelVideoFrameCallback(handle);
        timers.clearTimeout(giveUp);
        if (fallback !== null) timers.clearTimeout(fallback);
        video.removeEventListener('seeked', onSeeked);
        video.removeEventListener('playing', onPlaying);
        resolve({ presented, mediaTime, via });
      };
      const onFrame = (_now, metadata) => {
        handle = null;
        if (targetSec === null || Math.abs(metadata.mediaTime - targetSec) <= FRAME_TOLERANCE_SEC) finish(true, metadata.mediaTime, 'frame-callback');
        else handle = video.requestVideoFrameCallback(onFrame);          // a frame from before the seek
      };
      const afterTwoFrames = (fn) => {
        if (typeof scope.requestAnimationFrame === 'function') scope.requestAnimationFrame(() => scope.requestAnimationFrame(fn));
        else timers.setTimeout(fn, 34);
      };
      const onSeeked = () => {
        const check = () => { if (!done && video.readyState >= 2) finish(true, video.currentTime, 'seeked'); };
        if (hasCallback) fallback = timers.setTimeout(check, SEEKED_FALLBACK_MS);
        else afterTwoFrames(check);
      };
      const onPlaying = () => finish(true, video.currentTime, 'playing');
      const giveUp = timers.setTimeout(() => finish(false), timeoutMs);
      if (hasCallback) handle = video.requestVideoFrameCallback(onFrame);
      if (targetSec !== null) video.addEventListener('seeked', onSeeked);
      else if (!hasCallback) video.addEventListener('playing', onPlaying);
    });
  }

  #emit(event) {
    for (const fn of [...this.#listeners]) {
      try { fn(event); } catch (error) { console.error(error); }
    }
  }
}
