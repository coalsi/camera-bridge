// What the page knows about the recordings: which cameras have some and how far they reach, the server's clock, and the JSON calls that
// plan a picture. Everything goes through the fetcher, so the page-wide request caps hold.
import { realTimers } from './clock.js';

const BASE_BEHIND_MS = 400 * 86_400_000;      // the page's time base is the server's first answer minus 400 days, so buffer times stay positive
const MAX_FILES = 256;
const SAMPLES = 5;
const MAX_POLL_DELAY_MS = 8000;
const MIN_TIME_MS = 978_307_200_000;          // 2001, the range the server accepts
const MAX_TIME_MS = 4_102_444_800_000;        // 2100

const idKey = (id) => String(id).toUpperCase();
const clampInteger = (value, low, high, fallback) => (Number.isFinite(value) ? Math.min(Math.max(Math.trunc(value), low), high) : fallback);

function milliseconds(value, name) {
  const ms = Math.floor(Number(value));
  if (!Number.isFinite(ms) || ms < MIN_TIME_MS || ms > MAX_TIME_MS) throw new RangeError(`${name} must be a time in milliseconds`);
  return ms;
}

export function createCatalog({ fetcher, now = Date.now, perf = () => performance.now(), intervalMs = 1000, timers = realTimers }) {
  const listeners = new Set();
  const files = new Map();                    // fileKey -> FileInfo, least recently used first
  let extents = new Map();                    // camera id (upper case) -> { oldest, newest, typicalGOP }
  let version = null;
  let baseMs;                                 // undefined until the first answer
  let skew = 0;
  let samples = [];
  let users = 0;
  let timer = null;
  let polling = false;
  let failures = 0;
  let firstAnswer = false;
  let phase = 'starting';
  const readyWaiters = [];                    // { resolve, reject }

  function emit(event) {
    for (const fn of [...listeners]) {
      try { fn(event); } catch (error) { console.error(error); }
    }
  }

  function adopt(serverTime) {
    if (baseMs !== undefined || !Number.isFinite(serverTime)) return;
    baseMs = serverTime - BASE_BEHIND_MS;
    for (const waiter of readyWaiters.splice(0)) waiter.resolve();
  }

  function remember(map) {
    for (const [key, info] of Object.entries(map || {})) {
      files.delete(key);
      files.set(key, info);
      if (files.size > MAX_FILES) files.delete(files.keys().next().value);
    }
  }

  function noteAnswer(answer) {
    adopt(answer?.serverTime);
    remember(answer?.files);
    return answer;
  }

  function sameExtent(a, b) {
    return a && b && a.oldest === b.oldest && a.newest === b.newest && a.typicalGOP === b.typicalGOP;
  }

  function setPhase(next) {
    if (next === phase) return;
    phase = next;
    emit({ kind: 'phase' });
  }

  function accept(answer, rtt) {
    adopt(answer.serverTime);
    samples = [...samples, { rtt, skew: answer.serverTime - (now() - rtt / 2) }].slice(-SAMPLES);
    skew = samples.reduce((best, sample) => (sample.rtt < best.rtt ? sample : best)).skew;

    const next = new Map();
    for (const camera of answer.cameras || []) next.set(idKey(camera.id), { oldest: camera.oldest, newest: camera.newest, typicalGOP: camera.typicalGOP ?? null });
    const changed = !firstAnswer || next.size !== extents.size || [...next].some(([id, extent]) => !sameExtent(extent, extents.get(id)));
    firstAnswer = true;
    extents = next;
    const versionChanged = version !== answer.catalogVersion;
    version = answer.catalogVersion;
    if (changed) emit({ kind: 'extents' });
    if (versionChanged) emit({ kind: 'version' });
    setPhase('ready');
  }

  async function pollOnce() {
    const sentAt = perf();
    try {
      const answer = await fetcher.json('nvr/cameras', { key: 'catalog', priority: -1 });
      accept(answer, Math.max(0, perf() - sentAt));
      failures = 0;
    } catch (error) {
      if (error && (error.name === 'Superseded' || error.name === 'AbortError')) return;
      failures += 1;
      if (failures >= 3 && baseMs === undefined) for (const waiter of readyWaiters.splice(0)) waiter.reject(error);      // nobody is answering
      if (error && error.status === 503 && error.code === 'archive_unavailable') setPhase(error.retryAfter !== null ? 'loading' : 'unavailable');
      else if (failures >= 3) setPhase('unavailable');
    }
  }

  async function loop() {
    if (polling || users === 0) return;
    polling = true;
    try { await pollOnce(); } finally { polling = false; }
    if (users === 0) return;
    const delay = failures === 0 ? intervalMs : Math.min(intervalMs * 2 ** failures, MAX_POLL_DELAY_MS);
    timer = timers.setTimeout(() => { timer = null; loop(); }, delay);
  }

  return {
    /** Polls nvr/cameras every `intervalMs` while at least one caller has started it. Reference counted. */
    start() {
      users += 1;
      if (users === 1) loop();
    },
    stop() {
      users = Math.max(0, users - 1);
      if (users === 0 && timer !== null) { timers.clearTimeout(timer); timer = null; }
    },
    /** The server's clock now, from the answer with the shortest round trip among the last five. */
    serverNow: () => now() + skew,
    /** Fixed for this page load once known: the first server time minus 400 days. Undefined until the first answer. */
    get baseMs() { return baseMs; },
    /** Resolves when `baseMs` is known (the first answer of any call); rejects with the last error after three polls in a row failed before that. */
    ready: () => (baseMs !== undefined ? Promise.resolve() : new Promise((resolve, reject) => readyWaiters.push({ resolve, reject }))),
    get version() { return version; },
    /**
     * 'starting' before the first answer; 'ready' after an answer; 'loading' while the store answers 503 archive_unavailable with a
     * Retry-After (it is loading); 'unavailable' for a 503 without one (no archive) and after three failed polls in a row.
     */
    get phase() { return phase; },
    extent: (cameraId) => extents.get(idKey(cameraId)) ?? null,
    /** fn({ kind: 'extents' | 'version' }); returns the unsubscribe function. */
    onChange(fn) {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },
    /** GET nvr/cameras/:id/fragments?at=&ahead= : the key part, the lead-in, the target and `ahead` parts after it. */
    async plan(cameraId, atMs, { ahead = 2, key } = {}) {
      const path = `nvr/cameras/${encodeURIComponent(cameraId)}/fragments?at=${milliseconds(atMs, 'atMs')}&ahead=${clampInteger(ahead, 0, 16, 2)}`;
      return noteAnswer(await fetcher.json(path, { key, priority: 1 }));
    },
    /** GET nvr/cameras/:id/fragments?after=&limit= : the parts after a fragment, across gaps and files. */
    async after(cameraId, fragmentId, { limit = 8, key } = {}) {
      const path = `nvr/cameras/${encodeURIComponent(cameraId)}/fragments?after=${encodeURIComponent(fragmentId)}&limit=${clampInteger(limit, 1, 64, 8)}`;
      return noteAnswer(await fetcher.json(path, { key, priority: 1 }));
    },
    /** GET nvr/activity?cameras=&from=&binMs=&bins= */
    async activity({ cameras, fromMs, binMs, bins, key }) {
      const ids = cameras.map((id) => encodeURIComponent(id)).join(',');
      const path = `nvr/activity?cameras=${ids}&from=${milliseconds(fromMs, 'fromMs')}&binMs=${clampInteger(binMs, 1000, 86_400_000, 1000)}&bins=${clampInteger(bins, 1, 2000, 1)}`;
      return noteAnswer(await fetcher.json(path, { key, priority: 0 }));
    },
    file: (fileKey) => files.get(fileKey),
  };
}
