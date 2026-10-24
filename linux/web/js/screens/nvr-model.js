// The rules of the Monitor's wall (screens/nvr.js): tile count and paging, what each tile says, the budget for key pictures, snapshot refresh,
// keyboard actions and the two paths the page hands over. No DOM and no globals, so Node tests run it with fake time.

export const EPOCH_MIN_MS = 978307200000;      // 2001-01-01: the API's lower bound for a time (docs/superpowers/plans/2026-10-10-nvr/T00-contracts.md C.3)
export const EPOCH_MAX_MS = 4102444800000;     // 2100-01-01
export const DEFAULT_TILES = 9;          // page one shows up to nine cameras (a home has a handful); the browser decides how many of them play
export const PHONE_TILES = 2;
export const MAX_TILES = 16;
/** The sizes the page offers in its "Per page" control (any whole number from 1 to MAX_TILES works in ?tiles= and in storage). */
export const PAGE_SIZES = [4, 6, 9, 12, 16];
export const PHONE_MAX_WIDTH = 640;            // style.css switches to the phone layout at this width
export const MAX_WAVEFORM_CAMERAS = 16;        // GET nvr/activity takes at most 16 cameras
export const SNAPSHOT_INTERVAL_MS = 8000;      // the camera overview refreshes its pictures at the same pace (cameras.js THUMB_INTERVAL)
export const KEY_PICTURES_PER_SECOND = 20;     // the page-wide budget of key pictures while the timeline is dragged (addendum L8.5)
export const KEY_BURST = 6;
export const GRID_KEY_PICTURES = true;         // false cuts the key pictures of a drag: the tiles then only settle to exact pictures (first cut of the plan)
export const GRID_LEAD_LIMIT_BYTES = 16 * 1048576;   // a lead-in above this shows the key picture and "coarse" (addendum L7.2)

export const TEXT = {
  cameraOff: 'This camera is turned off',
  cameraOffline: 'The camera isn’t answering',
  cameraConnecting: 'Waiting for a picture…',
  recordingOff: 'Recording is off for this camera',
  nothingRecorded: 'Nothing recorded yet',
  driveMissing: 'The recordings drive isn’t connected',
  unreadable: 'Can’t read this part',
  unsupported: 'This browser can’t play recordings. Safari, or Chrome on a Mac, can.',
};

// MARK: Route, tile count, paging, paths

/** The `<epoch ms>` of a route (`#/nvr/1760099000000`): 1 to 15 digits inside the API's range, else null. */
export function parseEpochMs(value) {
  if (value === undefined || value === null || value === '') return null;
  const text = String(value);
  if (!/^[0-9]{1,15}$/.test(text)) return null;
  const ms = Number(text);
  return ms >= EPOCH_MIN_MS && ms <= EPOCH_MAX_MS ? ms : null;
}

function wholeTiles(text) {
  if (typeof text !== 'string' || !/^[0-9]{1,2}$/.test(text.trim())) return null;
  const n = Number(text);
  return n >= 1 && n <= MAX_TILES ? n : null;
}

/** The tile count the person chose: `?tiles=`, else localStorage `cb.nvr.tiles`; null when neither is one (1 to 16). */
export function chosenTileCount({ query = null, stored = null } = {}) {
  return wholeTiles(query) ?? wholeTiles(stored);
}

/** Tiles per page: `?tiles=` wins, then localStorage `cb.nvr.tiles`, then 9 (2 on a phone). Always 1 to 16. */
export function resolveTileCount({ query = null, stored = null, viewportWidth = Infinity } = {}) {
  return chosenTileCount({ query, stored }) ?? (viewportWidth <= PHONE_MAX_WIDTH ? PHONE_TILES : DEFAULT_TILES);
}

export function pageCount(total, perPage) {
  return total <= 0 ? 1 : Math.ceil(total / perPage);
}

/**
 * The pages as [start, end) ranges of a list of `total` cameras: `lengths` in order (the mosaic's, which depend on the pictures' shapes and
 * the wall's size), then pages of `perPage` for what they leave. Lengths that are not whole numbers above 0 count as none. Always one page at least.
 */
export function pageRanges(total, perPage, lengths = null) {
  const valid = Array.isArray(lengths) && lengths.every((n) => Number.isInteger(n) && n > 0) ? lengths : [];
  const size = Math.max(1, Math.trunc(perPage) || 1);
  const ranges = [];
  let start = 0;
  for (const n of valid) {
    if (start >= total) break;
    ranges.push([start, Math.min(total, start + n)]);
    start += n;
  }
  for (; start < total; start += size) ranges.push([start, Math.min(total, start + size)]);
  return ranges.length > 0 ? ranges : [[0, 0]];
}

export function clampPage(page, total, perPage) {
  return Math.min(Math.max(0, Math.trunc(page) || 0), pageCount(total, perPage) - 1);
}

export function pageSlice(list, page, perPage) {
  const p = clampPage(page, list.length, perPage);
  return list.slice(p * perPage, p * perPage + perPage);
}

const CAMERA_ID = /^[0-9A-Fa-f-]{36}$/;   // the pattern app.js routes on

function validMs(ms) {
  return typeof ms === 'number' && Number.isFinite(ms) && ms >= EPOCH_MIN_MS && ms <= EPOCH_MAX_MS ? Math.round(ms) : null;
}

/** The grid's own path: `/nvr` (live pictures) or `/nvr/<ms>` (paused there). */
export function gridPath(ms) {
  const valid = validMs(ms);
  return valid === null ? '/nvr' : `/nvr/${valid}`;
}

/** The watch screen's path: live without a time, paused at that moment with one. */
export function watchPath(cameraId, ms) {
  if (!CAMERA_ID.test(cameraId)) throw new RangeError('not a camera id');
  const valid = validMs(ms);
  return valid === null ? `/camera/${cameraId}/watch` : `/camera/${cameraId}/watch/${valid}`;
}

/** Cameras that feed the combined waveform: those with recordings, in list order, at most `max`. */
export function chooseWaveformCameras(cameras, extentOf, max = MAX_WAVEFORM_CAMERAS) {
  const withFootage = cameras.filter((camera) => extentOf(camera.id)).map((camera) => camera.id);
  return { ids: withFootage.slice(0, max), truncated: withFootage.length > max };
}

export function sameLocalDay(a, b) {
  return new Date(a).toDateString() === new Date(b).toDateString();
}

// MARK: What a tile says

/** The Record chip of a tile: the camera's `status.nvr.state` (T00 C.6), or what `nvrEnabled` implies when the status has none yet. */
export function recordChip(camera) {
  const state = camera.status?.nvr?.state ?? (camera.nvrEnabled ? 'waiting' : 'off');
  if (state === 'recording') return { text: 'REC', tone: 'recording' };
  if (state === 'paused') return { text: 'Paused', tone: 'warning' };
  if (state === 'waiting') return { text: 'Waiting', tone: 'idle' };
  return { text: 'Record off', tone: 'idle' };
}

function note(title, detail = null, tone = 'normal') {
  return { title, detail, tone, action: null };
}

/**
 * Everything a tile shows, from facts only.
 *   camera    the camera resource (isEnabled, nvrEnabled, status.connection, status.connectionReason, status.nvr)
 *   extent    catalog.extent(id): { oldest, newest } or null (no recordings)
 *   coverage  the tile's cell: { kind, next, message }; kind 'idle' while the cell has no desire
 *   started   a cell has been asked for anything yet (nothing decodes before that)
 * Returns { state, video, snapshot, refresh, busy, note, caption, chip }:
 *   video     the player's picture is on screen (the snapshot is hidden)
 *   snapshot  a loaded snapshot may be shown (the camera is online and the player is not showing)
 *   refresh   the snapshot should also be fetched again: only while no player picture is expected (the browser has few connections to spare)
 *   busy      show the delayed "Loading" spinner
 *   note      { title, detail, tone, action } text on the tile, or null; action is { id: 'retry', label } or null
 *   caption   'snapshot' | 'coarse' | null, the small label on a picture
 */
const PLAYER_STATES = new Set(['loading', 'recorded', 'live', 'coarse', 'gap', 'driveMissing', 'unreadable']);

export function tileState(input) {
  const look = describeTile(input);
  // Every picture carries its time: the playhead while a recording plays (the snapshots carry theirs in the caption).
  const clock = look.video && input.position !== null && input.position !== undefined ? input.formatTime(input.position) : null;
  return { ...look, clock, refresh: look.snapshot && !PLAYER_STATES.has(look.state) };
}

function describeTile({ camera, extent, coverage, started, playable = true, live = false, position = null, formatTime = String }) {
  const status = camera.status;
  const connection = status?.connection ?? 'connecting';
  const enabled = Boolean(camera.isEnabled);
  const online = enabled && connection === 'online';
  const kind = coverage?.kind ?? 'idle';
  const base = { state: 'snapshot', video: false, snapshot: online, busy: false, note: null, caption: null, chip: recordChip(camera) };

  // Live: the pictures are snapshots that keep refreshing (the caption gives the time); video plays only while the person scrubs.
  if (live && online && ['recorded', 'live', 'coarse', 'loading'].includes(kind)) return { ...base, caption: 'live' };

  switch (kind) {
    case 'recorded':
    case 'live':
      return { ...base, state: kind, video: true, snapshot: false };
    case 'coarse':
      return { ...base, state: 'coarse', video: true, snapshot: false, caption: 'coarse' };
    case 'unsupported':
      return { ...base, state: 'unsupported', note: note(coverage.message || TEXT.unsupported, null, 'warning') };
    case 'driveMissing':
      return { ...base, state: 'driveMissing', note: note(TEXT.driveMissing, null, 'error') };
    case 'unreadable': {
      const detail = coverage.message && coverage.message !== TEXT.unreadable ? coverage.message : null;
      return { ...base, state: 'unreadable', note: { ...note(TEXT.unreadable, detail, 'error'), action: { id: 'retry', label: 'Try again' } } };
    }
    case 'gap': {
      if (!camera.nvrEnabled) return { ...base, state: 'recordingOff', note: note(TEXT.recordingOff) };
      const title = position === null ? 'No recording here' : `No recording at ${formatTime(position)}`;
      return { ...base, state: 'gap', note: note(title, coverage.next ? `Next recording at ${formatTime(coverage.next)}` : null) };
    }
    case 'loading':
      return { ...base, state: 'loading', busy: true };
    default:
      break;
  }

  if (started) {
    if (!playable) return { ...base, state: 'unsupported', note: note(TEXT.unsupported, null, 'warning') };
    if (!extent) {
      return camera.nvrEnabled ? { ...base, state: 'nothingRecorded', note: note(TEXT.nothingRecorded) } : { ...base, state: 'recordingOff', note: note(TEXT.recordingOff) };
    }
    return { ...base, state: 'loading', busy: true };
  }
  if (!enabled) return { ...base, state: 'cameraOff', snapshot: false, note: note(TEXT.cameraOff) };
  if (connection === 'offline') return { ...base, state: 'cameraOffline', snapshot: false, note: note(TEXT.cameraOffline, status?.connectionReason || null, 'warning') };
  if (!online) return { ...base, state: 'cameraConnecting', snapshot: false, note: note(TEXT.cameraConnecting) };
  return { ...base, caption: 'live' };   // the page opens live: a refreshing snapshot, captioned with its time
}

const CHIP_WORDS = { REC: 'recording', Paused: 'recording paused', Waiting: 'waiting to record', 'Record off': 'not recording' };

/** One sentence for assistive technology: "Front door. Recording. No recording at 14:02:11." */
export function tileSummary(camera, tile) {
  const parts = [camera.name, CHIP_WORDS[tile.chip.text]];
  if (tile.note) parts.push(tile.note.title);
  if (tile.note?.detail) parts.push(tile.note.detail);
  return `${parts.filter(Boolean).join('. ')}.`;
}

// MARK: The key-picture budget

/** A token bucket: `burst` tokens, refilled at `perSecond`. */
export function createTokenBucket({ perSecond = KEY_PICTURES_PER_SECOND, burst = KEY_BURST, now = () => performance.now() } = {}) {
  let tokens = burst;
  let last = now();
  const refill = () => {
    const t = now();
    tokens = Math.min(burst, tokens + (Math.max(0, t - last) / 1000) * perSecond);
    last = t;
  };
  return {
    tryTake() {
      refill();
      if (tokens >= 1) { tokens -= 1; return true; }
      return false;
    },
    msUntilToken() {
      refill();
      return tokens >= 1 ? 0 : Math.max(1, Math.ceil(((1 - tokens) / perSecond) * 1000));
    },
    available() {
      refill();
      return Math.floor(tokens);
    },
  };
}

/**
 * Spends the bucket on key pictures. Each tile keeps only its newest wish (latest wins). Tokens go out in rounds: every tile that is waiting
 * is served once per round, the focused (hovered) tile first, the others in turn, so nothing starves and the hovered tile is never behind.
 * The wishes of one scrub reach every tile in the same turn; they are sent when that turn ends (`defer`, a microtask), so even while tokens
 * last the hovered tile goes first.
 */
export function createKeyDispatcher({ bucket, focused = () => null, setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = (t) => clearTimeout(t),
  defer = (fn) => queueMicrotask(fn) }) {
  const pending = new Map();       // id -> { desire, deliver }
  const served = new Set();        // ids served in the current round
  let ring = [];                   // ids in the order they first asked
  let last = null;
  let timer = null;                // waiting for a token
  let scheduled = false;           // a drain is queued for the end of this turn
  let delivered = 0;

  function pick() {
    let eligible = [...pending.keys()].filter((id) => !served.has(id));
    if (eligible.length === 0) {
      served.clear();
      eligible = [...pending.keys()];
    }
    const hovered = focused();
    if (hovered !== null && eligible.includes(hovered)) return hovered;
    const start = last === null ? 0 : (ring.indexOf(last) + 1) % Math.max(1, ring.length);
    for (let i = 0; i < ring.length; i += 1) {
      const id = ring[(start + i) % ring.length];
      if (eligible.includes(id)) return id;
    }
    return eligible[0];
  }

  function drain() {
    while (pending.size > 0) {
      if (!bucket.tryTake()) {
        timer = setTimer(() => { timer = null; drain(); }, bucket.msUntilToken());
        return;
      }
      const id = pick();
      const entry = pending.get(id);
      pending.delete(id);
      served.add(id);
      last = id;
      delivered += 1;
      try { entry.deliver(entry.desire); } catch (error) { console.error(error); }
    }
  }

  function kick() {
    if (scheduled || timer !== null) return;
    scheduled = true;
    defer(() => { scheduled = false; drain(); });
  }

  function cancel(id) {
    pending.delete(id);
    if (pending.size === 0 && timer !== null) { clearTimer(timer); timer = null; }
  }

  return {
    offer(id, desire, deliver) {
      if (!ring.includes(id)) ring.push(id);
      pending.set(id, { desire, deliver });
      kick();
    },
    cancel,
    forget(id) {
      cancel(id);
      served.delete(id);
      ring = ring.filter((other) => other !== id);
      if (last === id) last = null;
    },
    stats: () => ({ pending: pending.size, delivered }),
    destroy() {
      if (timer !== null) clearTimer(timer);
      timer = null;
      pending.clear();
    },
  };
}

/**
 * Puts a cell behind the budget. Only a key picture asked for during a drag (`precision: 'key'`, not playing) waits for a token; an exact
 * picture, a play request, suspend and destroy go straight through and drop the tile's waiting key wish. Anything else the cell has is
 * forwarded as is. `onRequest(id, desire)` runs first for every request: the page learns that something has been asked for. With
 * `keyPictures: false` a key picture is dropped instead of sent.
 */
export function budgetedCell(cell, { id, dispatcher, onRequest = () => {}, keyPictures = GRID_KEY_PICTURES }) {
  const own = {
    request(desire) {
      onRequest(id, desire);
      if (desire.precision === 'key' && desire.playing !== true) {
        if (keyPictures) dispatcher.offer(id, desire, (next) => cell.request(next));      // false: the grid only settles to exact pictures
      } else {
        dispatcher.cancel(id);
        cell.request(desire);
      }
    },
    suspend() {
      dispatcher.cancel(id);
      return cell.suspend();
    },
    destroy() {
      dispatcher.forget(id);
      return cell.destroy();
    },
  };
  return new Proxy(cell, {
    get(target, property) {
      if (Object.hasOwn(own, property)) return own[property];
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
}

// MARK: Snapshots

/** Media requests the page has in flight (fetcher.js), its pictures counted: three, and two while the live video holds a connection of its own. */
export const MEDIA_REQUESTS = 3;
export const MEDIA_REQUESTS_WHILE_LIVE = 2;
/** A picture that has not loaded after this long is given up. */
export const SNAPSHOT_GUARD_MS = 10_000;

/**
 * Loads `url` into `img` (an <img>, or anything with `src`, `onload`, `onerror` and `removeAttribute`): resolves true when it loaded, false when it
 * failed or took longer than `timeoutMs`. A load that took too long is cancelled (its `src` removed): an <img> that keeps loading keeps one of the
 * browser's six connections to the bridge (a camera slow to give a picture), while the next picture and the player need them.
 */
export function loadPicture(img, url, { timeoutMs = SNAPSHOT_GUARD_MS, setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = (t) => clearTimeout(t) } = {}) {
  return new Promise((resolve) => {
    let finished = false;
    const finish = (ok, cancel = false) => {
      if (finished) return;
      finished = true;
      clearTimer(guard);
      img.onload = null;
      img.onerror = null;
      if (cancel) img.removeAttribute('src');
      resolve(ok);
    };
    const guard = setTimer(() => finish(false, true), timeoutMs);
    img.onload = () => finish(true);
    img.onerror = () => finish(false);
    img.src = url;
  });
}

/**
 * Refreshes the tiles' snapshots one at a time (the browser has six connections to the bridge and the player and the event stream use
 * most of them). `load(id)` resolves true when a new picture is on the tile. A failure retries after 2.5 s, 5 s, then every `intervalMs`.
 * `shouldRefresh(id)` false leaves a tile alone (the player is showing); call `poke()` when that changes.
 */
export function createSnapshotScheduler({ load, shouldRefresh = () => true, intervalMs = SNAPSHOT_INTERVAL_MS, retryMs = 2500, now = () => Date.now(),
  setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = (t) => clearTimeout(t) }) {
  const entries = new Map();   // id -> { due, failures }
  let busy = false;
  let paused = false;
  let destroyed = false;
  let timer = null;

  function disarm() {
    if (timer !== null) { clearTimer(timer); timer = null; }
  }

  function run(id) {
    busy = true;
    let result;
    try { result = Promise.resolve(load(id)); } catch { result = Promise.resolve(false); }
    result.then((ok) => ok === true, () => false).then((ok) => {
      busy = false;
      const entry = entries.get(id);
      if (entry) {
        entry.failures = ok ? 0 : entry.failures + 1;
        entry.due = now() + (ok ? intervalMs : Math.min(intervalMs, retryMs * 2 ** (entry.failures - 1)));
      }
      pump();
    });
  }

  function pump() {
    if (destroyed || paused || busy) return;
    disarm();
    const t = now();
    let pick = null;
    let wake = Infinity;
    for (const [id, entry] of entries) {
      if (!shouldRefresh(id)) continue;
      if (entry.due <= t) {
        if (pick === null || entry.due < entries.get(pick).due) pick = id;
      } else {
        wake = Math.min(wake, entry.due);
      }
    }
    if (pick !== null) { run(pick); return; }
    if (wake !== Infinity) timer = setTimer(() => { timer = null; pump(); }, Math.max(0, wake - t));
  }

  return {
    setIds(ids) {
      for (const id of [...entries.keys()]) if (!ids.includes(id)) entries.delete(id);
      for (const id of ids) if (!entries.has(id)) entries.set(id, { due: now(), failures: 0 });
      pump();
    },
    refreshNow(id) {
      const entry = entries.get(id);
      if (entry) entry.due = now();
      pump();
    },
    poke: pump,
    pause() { paused = true; disarm(); },
    resume() { paused = false; pump(); },
    destroy() { destroyed = true; disarm(); entries.clear(); },
  };
}

// MARK: Waiting, keys

/**
 * Resolves when `isKnown()` is true: checked now, on every `subscribe` callback and every `pollMs`, and rejects after `timeoutMs`
 * (a bounded wait, never an endless loop). The page uses it for the catalog's first answer.
 */
export function whenKnown(isKnown, { subscribe = () => () => {}, timeoutMs = 10000, pollMs = 250, setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = (t) => clearTimeout(t) } = {}) {
  return new Promise((resolve, reject) => {
    const check = () => { try { return isKnown() === true; } catch { return false; } };
    if (check()) { resolve(); return; }
    let done = false;
    let off = () => {};
    let poll = null;
    let deadline = null;
    const finish = (error) => {
      if (done) return;
      done = true;
      off();
      if (poll !== null) clearTimer(poll);
      if (deadline !== null) clearTimer(deadline);
      if (error) reject(error); else resolve();
    };
    off = subscribe(() => { if (check()) finish(); });
    if (done) off();
    const tick = () => {
      if (check()) { finish(); return; }
      poll = setTimer(tick, pollMs);
    };
    poll = setTimer(tick, pollMs);
    deadline = setTimer(() => finish(new Error('timeout')), timeoutMs);
  });
}

/**
 * The transport keys of the grid, from a keydown event's fields. `typing`: focus is in an input, select, textarea or editable text, or a
 * dialog is open. `activatable`: focus is on something Space already operates (a button, a link, a switch).
 * Returns { action: 'togglePlay' | 'goLive' } or { action: 'seek', deltaMs } or { action: 'speed', step: -1 | 1 } or null.
 */
/**
 * The Monitor's keys (the page's key map, KEY_MAP below): Space play or pause; ← and → one picture back or forward while paused, a second
 * while playing; Shift + ← → a minute; Alt + ← → ten seconds (on a focused tile Alt + arrow moves the tile instead: nvr.js); , and . slower
 * and faster; L live. Never while typing, never with ctrl or cmd.
 */
export function keyAction(event, { typing = false, activatable = false } = {}) {
  if (typing || event.defaultPrevented || event.ctrlKey || event.metaKey) return null;
  const arrow = event.key === 'ArrowLeft' ? -1 : event.key === 'ArrowRight' ? 1 : 0;
  if (arrow !== 0) {
    if (event.shiftKey) return { action: 'seek', deltaMs: arrow * 60000 };
    if (event.altKey) return { action: 'seek', deltaMs: arrow * 10000 };
    return { action: 'nudge', direction: arrow, deltaMs: arrow * 1000 };    // a picture while paused, a second while playing
  }
  switch (event.key) {
    case ' ': return activatable ? null : { action: 'togglePlay' };
    case 'l':
    case 'L': return { action: 'goLive' };
    case ',': return { action: 'speed', step: -1 };
    case '.': return { action: 'speed', step: 1 };
    default: return null;
  }
}

/** The Monitor's key map as its keyboard help shows it: [keys, what they do]. */
export const KEY_MAP = Object.freeze([
  ['Space', 'Play or pause'],
  ['← →', 'Paused: one picture back or forward. Playing: 1 second'],
  ['Shift + ← →', '1 minute back or forward'],
  ['Alt + ← →', '10 seconds back or forward (on a focused camera: move it)'],
  [', .', 'Slower, faster'],
  ['L', 'Live'],
  ['C', 'Save a clip (Esc cancels, Return saves)'],
]);
