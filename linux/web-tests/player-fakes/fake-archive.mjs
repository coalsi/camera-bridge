// A synthetic recordings archive and a fake of the /api/v1 routes that serve it, following the contract in T00 C.5 (R5, R7 to R10).
// The "video" is a small JSON text, so a test can see which part a byte string stands for; sizes in the lists are the claimed ones.
import { ApiError } from '../../web/js/api.js';

export const ORIGIN = 1_760_000_000_000;            // epoch ms of the first file's start
export const MEDIA_START_TICKS = 123_456_789;        // the first tfdt of every file (90 kHz), so a file's anchor differs from its start
export const MIME = 'video/mp4; codecs="avc1.4d0032"';
export const FILE_A = 'a1b2c3d4e5f6';
export const FILE_B = 'b2c3d4e5f6a1';

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const toBuffer = (value) => encoder.encode(JSON.stringify(value)).slice().buffer;

/** What a media or init byte string stands for. */
export function decodeBytes(data) {
  return JSON.parse(decoder.decode(data instanceof ArrayBuffer ? new Uint8Array(data) : data));
}

/**
 * files: [{ key, startMs, parts, partMs = 2000, gop = 1, keyBytes = 700_000, deltaBytes = 100_000, mime = MIME, width = 2688, height = 1520,
 *           mediaStartTicks = MEDIA_START_TICKS }]
 * `gop` is the number of fragments in a GOP: every `gop`-th fragment starts with a keyframe, the others are continuation fragments.
 * `mediaStartTicks` is the first tfdt of the file, so its anchor is startMs - mediaStartTicks / 90 (0 for an ffmpeg clip).
 */
export function createArchive({ timers, cameraId = 'CAM-1', files, serverEpochAtZero = ORIGIN + 3_600_000 }) {
  let version = 1;
  const build = (spec) => {
    const file = { mime: MIME, width: 2688, height: 1520, partMs: 2000, gop: 1, keyBytes: 700_000, deltaBytes: 100_000, mediaStartTicks: MEDIA_START_TICKS, ...spec };
    file.anchor = file.startMs - file.mediaStartTicks / 90;
    file.parts = Array.from({ length: file.parts }, (_, index) => ({
      file: file.key,
      index,
      start: file.startMs + index * file.partMs,
      end: file.startMs + (index + 1) * file.partMs,
      key: index % file.gop === 0,
      backToKey: index % file.gop,
      byteLength: 32 + (index % file.gop === 0 ? file.keyBytes : file.deltaBytes),
    }));
    return file;
  };
  const state = files.map(build);

  const idOf = (part) => `${part.file}.${part.index}`;
  const fileOf = (key) => state.find((file) => file.key === key);
  const allParts = () => state.flatMap((file) => file.parts);

  const archive = {
    cameraId,
    serverTime: () => serverEpochAtZero + timers.now(),
    get catalogVersion() { return version; },
    idOf,

    byId(id) {
      const [key, index] = id.split('.');
      return fileOf(key)?.parts.find((part) => part.index === Number(index));
    },

    /** The part with start <= ms < end; the file that started later wins an overlap. */
    containing(ms) {
      for (const file of [...state].sort((a, b) => b.startMs - a.startMs)) {
        const part = file.parts.find((p) => p.start <= ms && ms < p.end);
        if (part) return part;
      }
      return undefined;
    },

    /** The first part that starts after ms, across gaps and files. */
    startingAfter(ms) {
      let best;
      for (const part of allParts()) if (part.start > ms && (!best || part.start < best.start)) best = part;
      return best;
    },

    extent() {
      const parts = allParts();
      if (!parts.length) return null;
      const gop = state.find((file) => file.parts.length)?.gop ?? 1;
      const partMs = state.find((file) => file.parts.length)?.partMs ?? 2000;
      return { oldest: Math.min(...parts.map((p) => p.start)), newest: Math.max(...parts.map((p) => p.end)), typicalGOP: (gop * partMs) / 1000 };
    },

    /** Retention: parts that ended before `ms` are gone. */
    removeBefore(ms) {
      for (const file of state) file.parts = file.parts.filter((part) => part.end > ms);
      version += 1;
    },

    /** Recording goes on: `count` more parts at the end of the last file. */
    append(count) {
      const file = state[state.length - 1];
      for (let n = 0; n < count; n += 1) {
        const index = file.parts.length ? file.parts[file.parts.length - 1].index + 1 : 0;
        file.parts.push({
          file: file.key, index, start: file.startMs + index * file.partMs, end: file.startMs + (index + 1) * file.partMs,
          key: index % file.gop === 0, backToKey: index % file.gop, byteLength: 32 + (index % file.gop === 0 ? file.keyBytes : file.deltaBytes),
        });
      }
      version += 1;
    },

    /** Recording starts again in a new file (same shape as the `files` entries), after the ones there are. */
    addFile(spec) {
      state.push(build(spec));
      version += 1;
    },

    describe(part) {
      return { id: idOf(part), file: part.file, start: part.start, end: part.end, bytes: Math.max(0, part.byteLength - 32), key: part.key };
    },

    fileInfo(fileKey, initId) {
      const file = fileOf(fileKey);
      return { mime: file.mime, width: file.width, height: file.height, anchor: file.anchor, initId, sound: false };
    },

    /** R7 mode at. */
    plan(at, ahead = 2) {
      const found = archive.containing(at);
      if (!found) {
        const extent = archive.extent();
        const base = { serverTime: archive.serverTime(), found: false, at, next: null, newest: extent ? extent.newest : null };
        if (!extent) return { ...base, reason: 'empty' };
        if (at < extent.oldest) return { ...base, reason: 'beforeStart', next: extent.oldest };
        if (at >= extent.newest) return { ...base, reason: 'afterEnd' };
        return { ...base, reason: 'gap', next: archive.startingAfter(at)?.start ?? null };
      }
      const file = fileOf(found.file);
      const key = file.parts.find((p) => p.index === found.index - found.backToKey);
      if (!key) throw new ApiError(410, 'gone', 'That recording was removed.');
      let parts = file.parts.filter((p) => p.index >= key.index && p.index <= found.index);
      let exact = true;
      let targetIndex = parts.length - 1;
      if (parts.length > 64) { parts = [key]; exact = false; targetIndex = 0; }
      for (let n = 0; n < ahead; n += 1) {
        const next = archive.startingAfter(parts[parts.length - 1].start);
        if (!next) break;
        parts.push(next);
      }
      return { serverTime: archive.serverTime(), found: true, at, exact, targetIndex, parts: parts.map(archive.describe), files: archive.filesFor(parts) };
    },

    filesFor(parts) {
      const files = {};
      for (const part of parts) if (!files[part.file]) files[part.file] = archive.fileInfo(part.file, idOf(part));
      return files;
    },

    /** R7 mode after. */
    after(id, limit = 8) {
      const from = archive.byId(id);
      if (!from) throw new ApiError(410, 'gone', 'That recording was removed.');
      const parts = [];
      let previous = from;
      while (parts.length < limit) {
        const next = archive.startingAfter(previous.start);
        if (!next) break;
        parts.push(next);
        previous = next;
      }
      return { serverTime: archive.serverTime(), parts: parts.map(archive.describe), files: archive.filesFor(parts) };
    },

    mediaBytes(part) {
      const file = fileOf(part.file);
      const ticks = file.mediaStartTicks + (part.start - file.startMs) * 90;
      return toBuffer({ kind: 'media', id: idOf(part), file: part.file, tfdtTicks: ticks, durationTicks: (part.end - part.start) * 90, key: part.key });
    },

    initBytes(fileKey) { return toBuffer({ kind: 'init', file: fileKey }); },
  };
  return archive;
}

function splitPath(path) {
  const url = new URL(path, 'http://bridge.invalid/');
  return { segments: url.pathname.replace(/^\//, '').split('/'), query: url.searchParams };
}

/** True for the routes that answer bytes (a fragment, an init, a key fragment); the others answer JSON. */
export function isBytesPath(path) {
  const { segments } = splitPath(path);
  return segments[3] === 'keyframe' || (segments[3] === 'fragments' && segments.length >= 5);
}

/** The JSON routes of T00 C.5 (R5, R6, R7) over `archives`: the answer, or an ApiError thrown. `path` is relative to /api/v1/. */
export function routeJson(archives, path) {
  const { segments, query } = splitPath(path);
  const archive = archives.find((candidate) => candidate.cameraId === segments[2]);
  if (segments.join('/') === 'nvr/cameras') {
    return {
      serverTime: archives[0].serverTime(),
      catalogVersion: Math.max(...archives.map((a) => a.catalogVersion)),
      cameras: archives.filter((a) => a.extent()).map((a) => ({ id: a.cameraId, ...a.extent() })),
    };
  }
  if (segments[3] === 'fragments' && segments.length === 4) {
    if (!archive) return { serverTime: archives[0].serverTime(), found: false, at: Number(query.get('at')), reason: 'empty', next: null, newest: null };
    if (query.has('after')) return archive.after(query.get('after'), query.has('limit') ? Number(query.get('limit')) : 8);
    return archive.plan(Number(query.get('at')), query.has('ahead') ? Number(query.get('ahead')) : 2);
  }
  if (segments.join('/') === 'nvr/activity') {
    const bins = Number(query.get('bins'));
    const byCamera = {};
    for (const id of query.get('cameras').split(',')) byCamera[id] = { typical: 1000, complete: true, coverage: Array(bins).fill(100), level: Array(bins).fill(500) };
    return { from: Number(query.get('from')), binMs: Number(query.get('binMs')), bins, serverTime: archives[0].serverTime(), catalogVersion: 1, byCamera };
  }
  throw new ApiError(404, 'not_found', 'No such route.');
}

/** The media routes (R8, R9, R10): { data: ArrayBuffer, headers: Headers }, or an ApiError thrown. */
export function routeBytes(archives, path) {
  const { segments, query } = splitPath(path);
  const archive = archives.find((candidate) => candidate.cameraId === segments[2]);
  if (!archive) throw new ApiError(404, 'not_found', 'No such camera.');
  const gone = () => new ApiError(410, 'gone', 'That recording was removed.');
  if (segments[3] === 'keyframe') {
    const found = archive.containing(Number(query.get('at')));
    if (!found) throw new ApiError(404, 'gap', 'No recording then.', null, { next: archive.startingAfter(Number(query.get('at')))?.start });
    const file = archive.fileInfo(found.file, null);
    const key = archive.byId(`${found.file}.${found.index - found.backToKey}`);
    if (!key) throw gone();
    const header = { id: archive.idOf(key), file: key.file, start: key.start, end: key.end, mime: file.mime, width: file.width, height: file.height, anchor: file.anchor, initId: archive.idOf(key) };
    return { data: archive.mediaBytes(key), headers: new Headers({ 'Content-Type': 'video/mp4', 'X-CB-Part': JSON.stringify(header) }) };
  }
  if (segments[3] === 'fragments') {
    const part = archive.byId(segments[4]);
    if (!part) throw gone();
    if (segments[5] === 'init') return { data: archive.initBytes(part.file), headers: new Headers({ 'Content-Type': 'video/mp4' }) };
    return { data: archive.mediaBytes(part), headers: new Headers({ 'Content-Type': 'video/mp4' }) };
  }
  throw new ApiError(404, 'not_found', 'No such route.');
}

/** A fake of get() and getBytes() from api.js over one or more archives. `latency(kind, path)` is the milliseconds an answer takes. */
export function createFakeApi({ archives, timers, latency = (kind) => (kind === 'bytes' ? 25 : 10) }) {
  const log = [];
  const rules = [];
  const now = { bytes: 0, json: 0 };
  const worst = { bytes: 0, json: 0 };
  const perCamera = new Map();            // camera id -> { now, worst } for media requests

  async function request(kind, path, options = {}) {
    const entry = { kind, path, startedAt: timers.now(), aborted: false, signalAbortedAtStart: !!options.signal?.aborted };
    log.push(entry);
    const { segments } = splitPath(path);
    const cameraId = segments[0] === 'nvr' && segments[1] === 'cameras' ? segments[2] : undefined;
    now[kind] += 1;
    worst[kind] = Math.max(worst[kind], now[kind]);
    if (kind === 'bytes') {
      const slot = perCamera.get(cameraId) ?? { now: 0, worst: 0 };
      slot.now += 1;
      slot.worst = Math.max(slot.worst, slot.now);
      perCamera.set(cameraId, slot);
    }
    try {
      await new Promise((resolve, reject) => {
        const timer = timers.setTimeout(resolve, latency(kind, path));
        options.signal?.addEventListener('abort', () => {
          timers.clearTimeout(timer);
          entry.aborted = true;
          reject(Object.assign(new Error('aborted'), { name: 'AbortError' }));
        }, { once: true });
      });
      entry.answeredAt = timers.now();
      for (const rule of rules) {
        if (rule.times > 0 && rule.match(path, entry)) {
          rule.times -= 1;
          throw rule.error();
        }
      }
      return kind === 'json' ? routeJson(archives, path) : routeBytes(archives, path);
    } finally {
      now[kind] -= 1;
      if (kind === 'bytes') perCamera.get(cameraId).now -= 1;
    }
  }

  return {
    get: (path, options) => request('json', path, options),
    getBytes: (path, options) => request('bytes', path, options),
    log,
    stats: () => ({ now: { ...now }, worst: { ...worst }, perCamera: new Map([...perCamera].map(([id, slot]) => [id, slot.worst])) }),
    /** The next `times` requests whose path matches fail with `error()`. */
    failWhen(match, error, { times = 1 } = {}) { rules.push({ match: typeof match === 'function' ? match : (path) => path.includes(match), error, times }); },
    clearFailures() { rules.length = 0; },
    requests: (pattern) => log.filter((entry) => entry.path.includes(pattern)),
  };
}
