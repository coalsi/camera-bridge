// The virtual archive: what the recordings folder would hold for the nine cameras, computed from the fixtures instead of read from disk.
//
// A camera records in runs (stretches without a break). A run is a chain of files; a file holds fragments; fragment n of a file is
// fragment n % parts of its fixture with the base media decode time advanced, so a file can be as long as the engine's (900 s) while the
// fixture is a few seconds. Everything here is arithmetic on (run start, fixture), nothing is stored per fragment, so three days of
// nine cameras cost a few thousand small objects. The lookups follow ArchiveReading (T00, B.2): boundaries are exact, a later-started
// file wins an overlap, ids are `<fileKey>.<index>` and come from the segment path alone.

import { boundaryAdjust, DAY, fixtureNameAt, HOUR } from './cameras.mjs';
import { fileKey as keyOf, fragmentId, parseFragmentId, segmentName } from './identity.mjs';

export const FILE_TARGET_MS = 900_000; // ArchiveConstants.fileMaximumDuration
export const LAG_MS = 300; // a fragment is visible this long after its last frame (the write)
export const MINUTE = 60_000;
const TICKS_PER_MS = 90;

const bounds = (array, accept) => {
  // the number of leading elements for which `accept` holds (the array is partitioned)
  let low = 0;
  let high = array.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (accept(array[middle])) low = middle + 1;
    else high = middle;
  }
  return low;
};

/** A deterministic number in [0, 1) from two integers (a small hash, so the same minute of the same camera always looks the same). */
export function noise(a, b) {
  let x = (Math.imul(a ^ 0x9e3779b9, 0x85ebca6b) ^ Math.imul(b + 0x7f4a7c15, 0xc2b2ae35)) >>> 0;
  x = Math.imul(x ^ (x >>> 15), 0x2c1b3c6d) >>> 0;
  x = Math.imul(x ^ (x >>> 12), 0x297a2d39) >>> 0;
  return ((x ^ (x >>> 15)) >>> 0) / 4294967296;
}

/** The geometry of one fixture: where fragment n of a long file starts and ends, and how many bytes the first n have. */
export function geometry(fixture) {
  const { parts, loopTicks } = fixture;
  const count = parts.length;
  const starts = parts.map((part) => part.startTicks);
  const ends = parts.map((part) => part.startTicks + part.ticks);
  const prefix = [0];
  for (const part of parts) prefix.push(prefix.at(-1) + part.bytes);
  const startTicks = (n) => Math.floor(n / count) * loopTicks + starts[n % count];
  let full = 0;
  for (let n = 1; n < 100_000; n += 1) {
    if (parts[n % count].key && startTicks(n) / TICKS_PER_MS >= FILE_TARGET_MS) {
      full = n;
      break;
    }
  }
  return {
    count,
    fullCount: full,
    startTicks,
    /** ms from the file's start to the start of fragment n (a double). */
    cum: (n) => startTicks(n) / TICKS_PER_MS,
    /** How many fragments have ended by `offsetMs` from the file's start. */
    visible(offsetMs) {
      if (offsetMs <= 0) return 0;
      const ticks = offsetMs * TICKS_PER_MS;
      const loops = Math.floor(ticks / loopTicks);
      return loops * count + bounds(ends, (end) => end <= ticks - loops * loopTicks);
    },
    /** The largest n whose fragment starts at or before `offsetMs` (-1 before the first). */
    indexAt(offsetMs) {
      if (offsetMs < 0) return -1;
      const ticks = offsetMs * TICKS_PER_MS;
      const loops = Math.floor(ticks / loopTicks);
      return loops * count + bounds(starts, (start) => start <= ticks - loops * loopTicks) - 1;
    },
    bytesBefore: (n) => Math.floor(n / count) * prefix[count] + prefix[n % count],
  };
}

export class VirtualArchive {
  /**
   * @param fixtures Map name -> fixture (fixtures.mjs)
   * @param definitions the camera definitions (cameras.mjs)
   * @param clock () => ms: the server's clock
   */
  constructor({ fixtures, definitions, clock }) {
    this.fixtures = fixtures;
    this.shapes = new Map([...fixtures].map(([name, fixture]) => [name, geometry(fixture)]));
    this.clock = clock;
    this.cameras = new Map(definitions.map((definition) => [definition.id, { definition, runs: [], files: [], names: new Set(), levels: new Map(), typicalKey: '', typicalValue: null, override: null }]));
    this.byKey = new Map();
    this.structure = 0;
  }

  // ---- building -------------------------------------------------------------------------------------------------------

  /** Starts a run at `start` (ms). Its first file is made at once, later ones as time passes. */
  openRun(cameraId, start, { sound = false } = {}) {
    const camera = this.cameras.get(cameraId);
    const run = { camera, start, end: null, files: [], sound };
    camera.runs.push(run);
    this.#addFile(run, start);
    this.structure += 1;
    return run;
  }

  #addFile(run, start) {
    const { camera } = run;
    const fixtureName = camera.override && start >= camera.override.from ? camera.override.name : fixtureNameAt(camera.definition, start);
    const fixture = this.fixtures.get(fixtureName);
    const shape = this.shapes.get(fixtureName);
    let suffix = 1;
    let segment = segmentName(camera.definition.id, start);
    while (camera.names.has(segment)) {
      suffix += 1;
      segment = segmentName(camera.definition.id, start, suffix);
    }
    camera.names.add(segment);
    const file = { run, camera, start, fixture, shape, segment, key: keyOf(segment), sound: run.sound, duration: shape.cum(shape.fullCount) };
    run.files.push(file);
    camera.files.push(file);
    this.byKey.set(file.key, file);
    return file;
  }

  /** The time up to which the run's footage is written: `end` once closed, else the clock less the write lag. */
  limit(run) {
    return run.end ?? this.clock() - LAG_MS;
  }

  /** Makes the files the open run has reached by now (call before reading). */
  refresh() {
    const lag = this.clock() - LAG_MS;
    for (const camera of this.cameras.values()) {
      const run = camera.runs.at(-1);
      if (!run || run.end !== null) continue;
      for (;;) {
        const last = run.files.at(-1);
        const next = last.start + last.duration + boundaryAdjust(camera.definition);
        if (next > lag) break;
        this.#addFile(run, next);
        this.structure += 1;
      }
    }
  }

  /** How many fragments of `file` are written. */
  visible(file) {
    return Math.min(file.shape.fullCount, file.shape.visible(this.limit(file.run) - file.start));
  }

  /** Ends the camera's open run at `at` (or now): the footage up to the last whole fragment stays. */
  closeRun(cameraId, at = this.clock()) {
    this.refresh();
    const run = this.cameras.get(cameraId).runs.at(-1);
    if (!run || run.end !== null) return;
    const limit = at - LAG_MS;
    // files that begin after the limit, or that have nothing written yet, go; a run with no file left is gone
    while (run.files.length) {
      const last = run.files.at(-1);
      if (last.start <= limit && last.shape.visible(limit - last.start) > 0) break;
      this.#removeFile(last);
    }
    this.structure += 1;
    if (!run.files.length) return;
    const last = run.files.at(-1);
    run.end = last.start + last.shape.cum(Math.min(last.shape.fullCount, last.shape.visible(limit - last.start)));
  }

  #removeFile(file) {
    const { run, camera } = file;
    run.files.splice(run.files.indexOf(file), 1);
    camera.files.splice(camera.files.indexOf(file), 1);
    this.byKey.delete(file.key);
    camera.names.delete(file.segment);
    if (!run.files.length) camera.runs.splice(camera.runs.indexOf(run), 1);
  }

  /** Files of this camera that start at or after `from` are made of fixture `name` (null: as the definition says): the keyframe fix. */
  setFixtureFrom(cameraId, from, name) {
    this.cameras.get(cameraId).override = name === null ? null : { from, name };
  }

  /** The camera has an open run. */
  isRecording(cameraId) {
    const run = this.cameras.get(cameraId).runs.at(-1);
    return !!run && run.end === null;
  }

  // ---- fragments --------------------------------------------------------------------------------------------------------

  #startMs = (file, n) => Math.round(file.start + file.shape.cum(n));

  #fragment(file, n) {
    const start = this.#startMs(file, n);
    const part = file.fixture.parts[n % file.shape.count];
    return {
      cameraId: file.camera.definition.id,
      file,
      index: n,
      id: fragmentId(file.key, n),
      start,
      end: this.#startMs(file, n + 1),
      mediaTicks: file.shape.startTicks(n),
      key: part.key,
      backToKey: part.backToKey,
      bytes: part.bytes,
    };
  }

  /** The fragment with start <= t < end; a later-started file wins an overlap; null in a gap. */
  containing(cameraId, t) {
    this.refresh();
    const files = this.cameras.get(cameraId)?.files;
    if (!files) return null;
    let at = bounds(files, (file) => file.start <= t + 1) - 1; // +1: a start of x.4 rounds to x
    for (let tries = 0; at >= 0 && tries < 2; tries += 1, at -= 1) {
      const file = files[at];
      const count = this.visible(file);
      let n = Math.min(count - 1, file.shape.indexAt(t - file.start));
      while (n + 1 < count && this.#startMs(file, n + 1) <= t) n += 1;
      while (n >= 0 && this.#startMs(file, n) > t) n -= 1;
      if (n >= 0 && n < count && t < this.#startMs(file, n + 1)) return this.#fragment(file, n);
    }
    return null;
  }

  /** The first fragment with start > t, across gaps and files. */
  startingAfter(cameraId, t) {
    this.refresh();
    const files = this.cameras.get(cameraId)?.files;
    if (!files) return null;
    let best = null;
    const here = bounds(files, (file) => file.start <= t) - 1;
    for (const file of [files[here - 1], files[here], files[here + 1]]) {
      if (!file) continue;
      const count = this.visible(file);
      let n = Math.max(0, file.shape.indexAt(t - file.start));
      while (n > 0 && this.#startMs(file, n - 1) > t) n -= 1;
      while (n < count && this.#startMs(file, n) <= t) n += 1;
      if (n >= count) continue;
      const candidate = this.#startMs(file, n);
      if (!best || candidate < best.start || (candidate === best.start && file.start > best.file.start)) best = this.#fragment(file, n);
    }
    return best;
  }

  /** The fragment an id names (it must belong to the camera and still exist), else null. */
  byId(cameraId, id) {
    this.refresh();
    const parsed = parseFragmentId(id);
    const file = parsed && this.byKey.get(parsed.fileKey);
    if (!file || file.camera.definition.id !== cameraId || parsed.index >= this.visible(file)) return null;
    return this.#fragment(file, parsed.index);
  }

  fileInfo(file) {
    const { info } = file.fixture;
    return { mime: info.mime, width: info.width, height: info.height, anchor: file.start, sound: file.sound };
  }

  readInit(fragment) {
    return fragment.file.fixture.init;
  }

  readFragment(fragment) {
    return fragment.file.fixture.fragmentBytes(fragment.index, fragment.mediaTicks);
  }

  // ---- extents, size, retention ---------------------------------------------------------------------------------------------

  extent(cameraId) {
    this.refresh();
    const camera = this.cameras.get(cameraId);
    if (!camera) return null;
    const first = camera.files.find((file) => this.visible(file) > 0);
    if (!first) return null;
    let newest = 0;
    for (const run of camera.runs) {
      const last = [...run.files].reverse().find((file) => this.visible(file) > 0);
      if (last) newest = Math.max(newest, Math.round(last.start + last.shape.cum(this.visible(last))));
    }
    const latest = [...camera.files].reverse().find((file) => this.visible(file) > 0);
    return { oldest: this.#startMs(first, 0), newest, typicalGOP: latest.fixture.gopSeconds };
  }

  fileBytes(file) {
    return file.shape.bytesBefore(this.visible(file));
  }

  usedBytes() {
    this.refresh();
    let total = 0;
    for (const camera of this.cameras.values()) for (const file of camera.files) total += this.fileBytes(file);
    return total;
  }

  /** Written fragments in all (the catalog version moves with it, like the engine's). */
  fragmentCount() {
    this.refresh();
    let total = 0;
    for (const camera of this.cameras.values()) for (const file of camera.files) total += this.visible(file);
    return total;
  }

  get version() {
    return this.structure + this.fragmentCount();
  }

  /** Retention: removes closed files that ended before `cutoff` (ms). Returns how many. */
  dropEndedBefore(cutoff) {
    let dropped = 0;
    for (const camera of this.cameras.values()) {
      for (const file of [...camera.files]) {
        if (!this.#isClosed(file)) continue;
        if (file.start + file.shape.cum(this.visible(file)) <= cutoff) {
          this.#removeFile(file);
          dropped += 1;
        }
      }
    }
    if (dropped) this.structure += 1;
    return dropped;
  }

  /** Retention: oldest closed file first, across cameras, until the archive is at most `maximumBytes`. Returns how many. */
  dropOldestUntil(maximumBytes) {
    let used = this.usedBytes();
    let dropped = 0;
    while (used > maximumBytes) {
      let oldest = null;
      for (const camera of this.cameras.values()) {
        const file = camera.files.find((candidate) => this.#isClosed(candidate));
        if (file && (!oldest || file.start < oldest.start)) oldest = file;
      }
      if (!oldest) break;
      used -= this.fileBytes(oldest);
      this.#removeFile(oldest);
      dropped += 1;
    }
    if (dropped) this.structure += 1;
    return dropped;
  }

  #isClosed(file) {
    return file.run.end !== null || file !== file.run.files.at(-1);
  }

  // ---- activity ---------------------------------------------------------------------------------------------------------------

  /** The ms of [a, b) with footage in the camera's files. */
  covered(camera, a, b) {
    const { files } = camera;
    let at = Math.max(0, bounds(files, (file) => file.start < a) - 2);
    let total = 0;
    let reached = a;
    for (; at < files.length && files[at].start < b; at += 1) {
      const file = files[at];
      const end = file.start + file.shape.cum(this.visible(file));
      const from = Math.max(a, file.start, reached);
      const to = Math.min(b, end);
      if (to > from) total += to - from;
      reached = Math.max(reached, end);
    }
    return total;
  }

  /** Non-keyframe bytes per second the camera shows during minute `minute` since the epoch: a daily rhythm with bursts. */
  minuteLevel(camera, minute) {
    const cached = camera.levels.get(minute);
    if (cached !== undefined) return cached;
    const fixture = this.fixtures.get(fixtureNameAt(camera.definition, minute * MINUTE));
    const hour = ((minute % 1440) / 60 + camera.definition.index) % 24;
    const rhythm = 0.55 + 0.45 * Math.sin(((hour - 7) / 24) * 2 * Math.PI);
    const burst = noise(camera.definition.index, Math.floor(minute / 6)) < 0.07 ? 3 + 5 * noise(minute, camera.definition.index) : 1;
    const level = fixture.nonKeyBytesPerSecond * rhythm * burst * (0.9 + 0.2 * noise(minute, 7));
    if (camera.levels.size > 20_000) camera.levels.clear();
    camera.levels.set(minute, level);
    return level;
  }

  /**
   * ArchiveReading.activity: `bins` bins of `binMs` from `from` (the caller aligns it). coverage is 0...1 (here 0...100), level the mean
   * level over the covered part of the bin, typical the median level over the covered minutes of the last 24 h (null under 30 minutes).
   */
  activity(cameraId, from, binMs, bins) {
    this.refresh();
    const camera = this.cameras.get(cameraId);
    const coverage = new Array(bins).fill(0);
    const level = new Array(bins).fill(0);
    if (!camera) return { typical: null, complete: true, coverage, level };
    for (let i = 0; i < bins; i += 1) {
      const a = from + i * binMs;
      const b = a + binMs;
      const seen = this.covered(camera, a, b);
      coverage[i] = Math.round((seen / binMs) * 100);
      if (seen <= 0) {
        level[i] = 0;
        continue;
      }
      let weighted = 0;
      const whole = seen >= binMs - 1;
      for (let m = Math.floor(a / MINUTE); m * MINUTE < b; m += 1) {
        const lo = Math.max(a, m * MINUTE);
        const hi = Math.min(b, (m + 1) * MINUTE);
        weighted += this.minuteLevel(camera, m) * (whole ? hi - lo : this.covered(camera, lo, hi));
      }
      const jitter = binMs < MINUTE ? 0.7 + 0.6 * noise(Math.floor(a / binMs), camera.definition.index) : 1;
      level[i] = Math.round((weighted / seen) * jitter * 10) / 10;
    }
    return { typical: this.typical(camera), complete: true, coverage, level };
  }

  typical(camera) {
    const now = this.clock();
    const key = `${Math.floor(now / MINUTE)}:${this.structure}`;
    if (camera.typicalKey === key) return camera.typicalValue;
    const levels = [];
    for (let m = Math.floor((now - DAY) / MINUTE); m < Math.floor(now / MINUTE); m += 1) {
      if (this.covered(camera, m * MINUTE, (m + 1) * MINUTE) >= MINUTE / 2) levels.push(this.minuteLevel(camera, m));
    }
    let value = null;
    if (levels.length * MINUTE >= 1_800_000) {
      levels.sort((x, y) => x - y);
      value = Math.round(levels[Math.floor(levels.length / 2)] * 10) / 10;
    }
    camera.typicalKey = key;
    camera.typicalValue = value;
    return value;
  }

  // ---- history ------------------------------------------------------------------------------------------------------------------

  /**
   * Gives every camera the history its definition asks for, ending now: three days with a daily gap, a camera stopped a few hours
   * ago, a camera that began minutes ago. File boundaries are the engine's: the first file of a run starts where the run does.
   */
  seed() {
    const now = this.clock();
    for (const camera of this.cameras.values()) {
      const definition = camera.definition;
      const sound = !!definition.recordSound;
      if (definition.history === 'fresh') {
        this.openRun(definition.id, now - definition.freshMinutes * MINUTE, { sound });
        continue;
      }
      const cutoff = Math.ceil((now - 3 * DAY) / FILE_TARGET_MS) * FILE_TARGET_MS;
      let start = cutoff;
      const gaps = [];
      if (definition.gap) {
        for (let day = Math.floor(cutoff / DAY); day <= Math.floor(now / DAY); day += 1) {
          const gapStart = day * DAY + definition.gap.hour * HOUR + definition.gap.minute * MINUTE;
          const gapEnd = gapStart + definition.gap.minutes * MINUTE;
          if (gapStart > cutoff && gapEnd <= now - HOUR) gaps.push([gapStart, gapEnd]);
        }
      }
      for (const [gapStart, gapEnd] of gaps) {
        this.openRun(definition.id, start, { sound });
        this.#closeAtMs(definition.id, gapStart);
        start = gapEnd;
      }
      this.openRun(definition.id, start, { sound });
      if (definition.history === 'stopped') this.#closeAtMs(definition.id, now - definition.stoppedHoursAgo * HOUR);
    }
  }

  /** Closes the open run as if the clock read `at`: used to build history. */
  #closeAtMs(cameraId, at) {
    const real = this.clock;
    this.clock = () => at;
    try {
      this.closeRun(cameraId, at);
    } finally {
      this.clock = real;
    }
  }
}
