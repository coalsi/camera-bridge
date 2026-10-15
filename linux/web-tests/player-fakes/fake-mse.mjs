// A fake browser media stack for surface.js: a <video>, a MediaSource, a SourceBuffer, a canvas and URL.createObjectURL, all driven by
// the fake timers. The SourceBuffer understands the JSON "bytes" of fake-archive.mjs: an init says which file, a media segment says its
// tfdt and duration, and the fake adds the SourceBuffer's timestampOffset to put it on the buffer time line.
import { decodeBytes } from './fake-archive.mjs';

const EPSILON = 1e-6;

function domError(name, message) {
  const error = new Error(message);
  error.name = name;
  return error;
}

function mergeSegments(segments) {
  const ranges = [];
  for (const segment of [...segments].sort((x, y) => x.start - y.start)) {
    const last = ranges[ranges.length - 1];
    if (last && segment.start <= last.end + EPSILON) last.end = Math.max(last.end, segment.end);
    else ranges.push({ start: segment.start, end: segment.end });
  }
  return ranges;
}

export class FakeSourceBuffer extends EventTarget {
  constructor(owner, mime) {
    super();
    this.owner = owner;
    this.mime = mime;
    this.mode = 'sequence';
    this.timestampOffset = 0;
    this.updating = false;
    this.segments = [];            // { start, end, bytes } on the buffer time line
    this.ops = [];                 // what the surface asked, in order
    this.initFiles = [];
    this.removed = [];
    this.parserHasInit = false;    // only matters when owner.needInitAfterAbort: a browser that wants the init again after abort() (T06's conservative case)
  }

  get ranges() { return mergeSegments(this.segments); }

  get heldBytes() { return this.segments.reduce((sum, segment) => sum + segment.bytes, 0); }

  get buffered() {
    const ranges = this.ranges;
    return { length: ranges.length, start: (i) => ranges[i].start, end: (i) => ranges[i].end };
  }

  #finish(work, events = ['update', 'updateend']) {
    this.updating = true;
    this.dispatchEvent(new Event('updatestart'));
    this.owner.timers.setTimeout(() => {
      work();
      this.updating = false;
      for (const type of events) this.dispatchEvent(new Event(type));
    }, this.owner.appendDelayMs);
  }

  appendBuffer(bytes) {
    if (this.updating) throw domError('InvalidStateError', 'appendBuffer while updating');
    if (this.owner.failNextAppend) {
      const error = this.owner.failNextAppend;
      this.owner.failNextAppend = null;
      throw error;
    }
    const info = decodeBytes(bytes);
    if (info.kind === 'media' && this.owner.needInitAfterAbort && !this.parserHasInit) throw domError('InvalidStateError', 'a media segment needs the init segment again after abort()');
    if (info.kind === 'init') this.parserHasInit = true;
    if (info.kind === 'media' && this.owner.quotaBytes !== null && this.heldBytes + bytes.byteLength > this.owner.quotaBytes) throw domError('QuotaExceededError', 'quota');
    this.ops.push({ op: info.kind === 'init' ? 'appendInit' : 'append', id: info.id ?? null, file: info.file, offset: this.timestampOffset, bytes: bytes.byteLength });
    this.#finish(() => {
      if (info.kind === 'init') {
        this.initFiles.push(info.file);
        return;
      }
      const start = info.tfdtTicks / 90_000 + this.timestampOffset;
      this.segments.push({ start, end: start + info.durationTicks / 90_000, bytes: bytes.byteLength });
    });
  }

  abort() {
    this.ops.push({ op: 'abort' });
    if (this.owner.needInitAfterAbort) this.parserHasInit = false;
  }

  /** Like the real thing: removes the coded frames (here: segments) whose start lies in [start, end). */
  remove(start, end) {
    if (this.updating) throw domError('InvalidStateError', 'remove while updating');
    this.ops.push({ op: 'remove', start, end });
    this.removed.push({ start, end });
    this.#finish(() => {
      this.segments = this.segments.filter((segment) => !(segment.start >= start && segment.start < end));
    });
  }

  changeType(mime) {
    this.ops.push({ op: 'changeType', mime });
    this.mime = mime;
  }

  /** The browser evicts by itself (a test calls this). */
  evictByBrowser(start, end) {
    this.segments = this.segments.filter((segment) => !(segment.start >= start && segment.start < end));
  }
}

export class FakeMediaSource extends EventTarget {
  static supported = (mime) => /avc1/.test(mime);
  static isTypeSupported(mime) { return FakeMediaSource.supported(mime); }

  constructor(owner) {
    super();
    this.owner = owner;
    this.readyState = 'closed';
    this.sourceBuffers = [];
  }

  addSourceBuffer(mime) {
    if (this.readyState !== 'open') throw domError('InvalidStateError', 'not open');
    const sourceBuffer = new FakeSourceBuffer(this.owner, mime);
    this.sourceBuffers.push(sourceBuffer);
    this.owner.sourceBuffers.push(sourceBuffer);
    return sourceBuffer;
  }
}

export class FakeVideo extends EventTarget {
  constructor(owner) {
    super();
    this.owner = owner;
    this.readyState = 0;
    this.videoWidth = 0;
    this.videoHeight = 0;
    this.paused = true;
    this.muted = false;
    this.playsInline = false;
    this.disableRemotePlayback = false;
    this._src = '';
    this.#time = 0;
    this.frameCallbacks = new Map();
    this.nextHandle = 1;
    this.log = [];
    this.autoPresent = true;        // present a frame when a seek lands in held data
    this.playPromise = null;
  }

  #time;

  get src() { return this._src; }

  set src(url) {
    this._src = url;
    const source = this.owner.urls.get(url);
    this.owner.attached = source ?? null;
    if (source && !this.owner.neverOpen) {
      this.owner.timers.setTimeout(() => {
        source.readyState = 'open';
        source.dispatchEvent(new Event('sourceopen'));
      }, 1);
    }
  }

  get currentTime() { return this.#time; }

  set currentTime(value) {
    this.#time = value;
    this.log.push({ op: 'currentTime', value });
    this.dispatchEvent(new Event('seeking'));
    this.owner.timers.setTimeout(() => {
      const held = this.owner.heldRanges().some((r) => value >= r.start - EPSILON && value < r.end);
      if (held) { this.readyState = 4; this.videoWidth = 2688; this.videoHeight = 1520; }
      this.dispatchEvent(new Event('seeked'));
      if (held && this.autoPresent) this.presentFrame(value);
    }, this.owner.seekDelayMs);
  }

  /** The browser composed a frame whose presentation time is `mediaTime`. */
  presentFrame(mediaTime) {
    const callbacks = [...this.frameCallbacks];
    this.frameCallbacks.clear();
    for (const [, callback] of callbacks) callback(this.owner.timers.now(), { mediaTime, presentedFrames: 1 });
  }

  requestVideoFrameCallback(callback) {
    const handle = this.nextHandle++;
    this.frameCallbacks.set(handle, callback);
    return handle;
  }

  cancelVideoFrameCallback(handle) { this.frameCallbacks.delete(handle); }

  removeAttribute(name) {
    if (name === 'src') { this._src = ''; this.owner.attached = null; this.readyState = 0; this.log.push({ op: 'removeSrc' }); }
  }

  load() { this.log.push({ op: 'load' }); }

  async play() {
    if (this.owner.playError) throw this.owner.playError;
    this.paused = false;
    this.log.push({ op: 'play' });
    this.dispatchEvent(new Event('playing'));
    if (this.autoPresent) this.owner.timers.setTimeout(() => this.presentFrame(this.#time), this.owner.seekDelayMs);
  }

  pause() { this.paused = true; this.log.push({ op: 'pause' }); }
}

export class FakeCanvas {
  constructor() {
    this.width = 0;
    this.height = 0;
    this.style = { display: '' };
    this.draws = [];
  }

  getContext() {
    return { drawImage: (source, x, y) => this.draws.push({ width: this.width, height: this.height, x, y, from: source }) };
  }
}

/** Everything the surface needs, with `scope` as its globalThis. */
export function createFakeMedia({ timers, managed = false, appendDelayMs = 2, seekDelayMs = 5, quotaBytes = null, needInitAfterAbort = false } = {}) {
  const owner = {
    timers, appendDelayMs, seekDelayMs, quotaBytes, needInitAfterAbort,
    sourceBuffers: [], mediaSources: [], attached: null, urls: new Map(), revoked: [], playError: null, failNextAppend: null, neverOpen: false,
    heldRanges: () => (owner.attached ? owner.attached.sourceBuffers.flatMap((sb) => sb.ranges) : []),
  };
  let urlCount = 0;
  class SourceClass extends FakeMediaSource {
    constructor() { super(owner); owner.mediaSources.push(this); }
  }
  const video = new FakeVideo(owner);
  const canvas = new FakeCanvas();
  const scope = {
    URL: {
      createObjectURL(source) { const url = `blob:fake/${++urlCount}`; owner.urls.set(url, source); return url; },
      revokeObjectURL(url) { owner.revoked.push(url); },
    },
    requestAnimationFrame: (fn) => timers.setTimeout(() => fn(timers.now()), 16),
  };
  if (managed) scope.ManagedMediaSource = SourceClass;
  else scope.MediaSource = SourceClass;
  SourceClass.isTypeSupported = (mime) => FakeMediaSource.supported(mime);
  return { owner, video, canvas, scope, SourceClass, sourceBuffer: () => owner.sourceBuffers.at(-1) };
}
