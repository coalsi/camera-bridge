// The logic of the NVR grid page, without a DOM: which cameras are on the page, what each tile says, what the transport does, how a tile opens
// the watch screen and how the page comes back. nvr.js builds the session, the cells and the DOM and hands them in; the tests hand in fakes.
import { stepSpeed } from '../nvr/speed.js';
import { EPOCH_MIN_MS, chooseWaveformCameras, gridPath, pageRanges, tileState, tileSummary, watchPath, whenKnown } from './nvr-model.js';

const IDLE = Object.freeze({ kind: 'idle', next: null, message: null });
const TICK_MS = 250;            // the readout moves and the address is kept in step this often
const PAUSED_HASH_MS = 1000;    // while paused the address follows the playhead at most this often (Safari allows 100 address changes in 30 s)
const PLAYING_HASH_MS = 5000;   // while playing, at most this often

function sameIds(a, b) {
  return a.length === b.length && a.every((id, i) => id === b[i]);
}

/**
 * deps:
 *   session, catalog           T08's session and catalog (T00 C.10); nvr.js starts and stops them
 *   listCameras()              the cameras in list order (store.js cameraList)
 *   subscribeCameras(fn)       fn() when the camera list or a camera's status changed; returns an unsubscribe
 *   perPage, initialMs, initialPage, initialFocus, playable
 *   paginate(cameras)          optional: the lengths of the pages in list order (the mosaic's), or null for pages of perPage; relayout() asks again.
 *                              Until it first gives lengths, pages of perPage stand in, and the remembered page and camera (initialPage,
 *                              initialFocus) wait for the real pages. Whenever the pages change (a new size, a camera added or removed, a
 *                              picture's new shape), the page that holds the camera that led the page on screen shows.
 *   navigate(path), replaceHash(path)    app.js navigate, and history.replaceState for the address
 *   remember({ page, focusId, opened })  module memory of nvr.js, so coming back finds the same page and tile
 *   formatTime(ms), now()
 *   setWaveformCameras(ids), setSnapshotIds(ids), pokeSnapshots()
 *   setTimer, clearTimer, setTick, clearTick, defer    injectable time
 */
export function createGridController(deps) {
  const {
    session, catalog, listCameras, subscribeCameras, perPage, initialMs = null, initialPage = 0, initialFocus = null, playable = true, paginate = () => null,
    navigate, replaceHash, remember = () => {}, formatTime = String, now = () => Date.now(),
    setWaveformCameras = () => {}, setSnapshotIds = () => {}, pokeSnapshots = () => {},
    setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = (t) => clearTimeout(t),
    setTick = (fn, ms) => setInterval(fn, ms), clearTick = (t) => clearInterval(t), defer = (fn) => queueMicrotask(fn),
    catalogTimeoutMs = 10000,
  } = deps;

  const listeners = new Set();
  const cellWatchers = new Map();     // camera id -> unsubscribe from that cell's onChange
  const unsubscribers = [];
  let ranges = pageRanges(listCameras().length, perPage);   // the pages as [start, end) of the camera list (pageRanges)
  let page = clampTo(initialPage);
  // The remembered page and camera, kept until paginate first gives the real pages (the stand-in pages of perPage hold other cameras).
  let pending = deps.paginate ? { page: initialPage, focus: initialFocus } : null;
  let slice = [];
  let started = false;                // something has been asked of a cell; before that nothing decodes
  let phase = 'connecting';           // 'connecting' | 'ready' | 'unreachable'
  let focusId = null;
  let waveform = { ids: [], truncated: false };
  let onlyId = null;     // the camera the timeline shows alone (one camera on the whole wall), or null: every camera
  let tickTimer = null;
  let queued = false;
  let destroyed = false;
  let lastHash = null;                // the grid path last written to the address
  let lastHashAt = -Infinity;

  function schedule() {
    if (queued || destroyed) return;
    queued = true;
    defer(() => {
      queued = false;
      if (destroyed) return;
      for (const fn of [...listeners]) fn();
    });
  }

  function cellOf(id) {
    try { return session.cell(id) ?? null; } catch { return null; }
  }

  function attachCells() {
    for (const [id, off] of cellWatchers) {
      if (!slice.includes(id)) { off(); cellWatchers.delete(id); }
    }
    for (const id of slice) {
      if (cellWatchers.has(id)) continue;
      const cell = cellOf(id);
      if (cell) cellWatchers.set(id, cell.onChange(() => schedule()));
    }
  }

  function clampTo(next) {
    return Math.min(Math.max(0, Math.trunc(next) || 0), ranges.length - 1);
  }

  function sameRanges(a, b) {
    return a.length === b.length && a.every(([start, end], i) => start === b[i][0] && end === b[i][1]);
  }

  /** The page of the camera at `index` in the list, or the page as it is. */
  function pageHolding(index) {
    const at = ranges.findIndex(([start, end]) => index >= start && index < end);
    return at >= 0 ? at : page;
  }

  /** The pages again from paginate; `keepLead`: when they changed, the page that holds the camera that led the page on screen (the focused
   *  one, else the first) shows. A page chosen by hand (setPage) keeps its number. */
  function applyPage({ keepLead = true } = {}) {
    const cameras = listCameras();
    const lengths = paginate(cameras);
    const next = pageRanges(cameras.length, perPage, lengths);
    let preferred = null;
    if (pending && lengths) {
      const at = cameras.findIndex((camera) => camera.id === pending.focus);
      ranges = next;
      page = at >= 0 ? pageHolding(at) : pending.page;
      preferred = pending.focus;
      pending = null;
    } else if (keepLead && slice.length > 0 && !sameRanges(next, ranges)) {
      const leadId = slice.includes(focusId) ? focusId : slice[0];
      const at = cameras.findIndex((camera) => camera.id === leadId);
      ranges = next;
      if (at >= 0) page = pageHolding(at);
    } else {
      ranges = next;
    }
    page = clampTo(page);
    const [start, end] = ranges[page];
    const ids = cameras.slice(start, end).map((camera) => camera.id);
    if (sameIds(ids, slice)) return;
    slice = ids;
    session.setCameras(slice);
    setSnapshotIds(slice);
    if (preferred !== null && slice.includes(preferred) && focusId !== preferred) {
      focusId = preferred;
      session.focus(focusId);
    } else if (!slice.includes(focusId)) {
      focusId = focusId === null && slice.includes(initialFocus) ? initialFocus : (slice[0] ?? null);
      session.focus(focusId);
    }
    attachCells();
    if (started) session.seek(0);        // the new cells take the playhead where it is
    remember({ page, focusId });
  }

  function refreshWaveform() {
    const cameras = onlyId === null ? listCameras() : listCameras().filter((camera) => camera.id === onlyId);
    const next = chooseWaveformCameras(cameras, (id) => catalog.extent(id));
    if (!sameIds(next.ids, waveform.ids)) setWaveformCameras(next.ids);
    waveform = next;
  }

  function canAct() {
    return !destroyed && phase === 'ready' && playable;
  }

  function handoffMs() {
    return started && session.mode !== 'live' ? Math.round(session.position) : null;
  }

  // MARK: The address follows the playhead, so a reload or Back finds the same moment

  function syncAddress() {
    if (!started || phase !== 'ready') return;
    const mode = session.mode;
    let path = null;
    if (mode === 'live') path = gridPath(null);
    else if (now() - lastHashAt >= (mode === 'paused' ? PAUSED_HASH_MS : PLAYING_HASH_MS)) path = gridPath(session.position);
    if (path === null || path === lastHash) return;
    lastHash = path;
    lastHashAt = now();
    replaceHash(path);
  }

  function onTick() {
    if (destroyed) return;
    attachCells();
    if (!started) return;
    if (session.mode === 'playing') schedule();    // the readout is moving
    syncAddress();
  }

  async function connect() {
    phase = 'connecting';
    schedule();
    try {
      // The catalog's time base (first server time minus 400 days) exists once it has answered; before that it is undefined, NaN or 0.
      await whenKnown(() => Number.isFinite(catalog.baseMs) && catalog.baseMs >= EPOCH_MIN_MS, { subscribe: (fn) => catalog.onChange(fn), timeoutMs: catalogTimeoutMs, setTimer, clearTimer });
    } catch {
      if (!destroyed) { phase = 'unreachable'; schedule(); }
      return;
    }
    if (destroyed) return;
    phase = 'ready';
    refreshWaveform();
    if (initialMs !== null && !started) session.scrub(initialMs);     // paused there: the cells fetch exact pictures
    schedule();
  }

  // MARK: The view

  function view() {
    const cameras = listCameras();
    const byId = new Map(cameras.map((camera) => [camera.id, camera]));
    const mode = session.mode;
    const position = started ? session.position : null;
    const handoff = handoffMs();
    const tiles = slice.filter((id) => byId.has(id)).map((id) => {
      const camera = byId.get(id);
      // A session shows at most min(tileCap, the browser's cap) cells (T08 POLICY_TABLE), so a page can have more tiles than players. A tile with no
      // cell can never get a picture: it stays a snapshot tile (started false) instead of showing a spinner for ever.
      const cell = cellOf(id);
      const player = cell !== null;
      const look = tileState({ camera, extent: catalog.extent(id), coverage: cell?.coverage ?? IDLE, started: started && player, playable, live: started && mode === 'live', position, formatTime });
      return { id, name: camera.name, href: `#${watchPath(id, handoff)}`, focused: id === focusId, player, look, summary: tileSummary(camera, look) };
    });
    const playLimit = tiles.filter((tile) => tile.player).length;
    const total = cameras.length;
    const [start, end] = ranges[clampTo(page)];
    return {
      phase, playable, noCameras: total === 0,
      page, pages: ranges.length, perPage, total,
      first: total === 0 ? 0 : start + 1, last: Math.min(total, end),
      tiles,
      playLimit, limited: playLimit < tiles.length,
      transport: {
        mode: started ? mode : 'snapshots',
        playing: started && (mode === 'playing' || mode === 'live'),
        canPlay: canAct(),
        canGoLive: canAct() && started && mode !== 'live',
        positionMs: position,
        rate: session.rate ?? 1,
        canSpeed: canAct() && started && mode !== 'live',
      },
      waveform,
      noRecordings: phase === 'ready' && waveform.ids.length === 0 && !cameras.some((camera) => camera.nvrEnabled),
    };
  }

  // MARK: Actions

  const api = {
    view,
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); },

    /** Call after the catalog has been started. Shows the tiles at once; resolves when the catalog has answered or given up. */
    async start() {
      applyPage();
      unsubscribers.push(subscribeCameras(() => { applyPage(); refreshWaveform(); schedule(); }));
      unsubscribers.push(catalog.onChange(() => { refreshWaveform(); schedule(); }));
      tickTimer = setTick(onTick, TICK_MS);
      schedule();
      await connect();
    },
    retryCatalog() { if (phase === 'unreachable' && !destroyed) return connect(); return Promise.resolve(); },

    /** The budgeted cells call this for every request: the first one ends "nothing has been asked yet". */
    noteRequest() {
      if (started || destroyed) return;
      started = true;
      attachCells();
      pokeSnapshots();
      schedule();
    },

    togglePlay() {
      if (!canAct()) return;
      if (started) session.togglePlay(); else session.goLive();
      schedule();
    },
    goLive() { if (canAct()) { session.goLive(); schedule(); } },
    /** The playback speed (nvr/speed.js): every playing tile follows the shared clock. */
    setSpeed(rate) { if (canAct()) { session.setRate(rate); schedule(); } },
    stepSpeed(step) { if (canAct()) { session.setRate(stepSpeed(session.rate ?? 1, step)); schedule(); } },
    /** The timeline shows `id`'s recordings alone (one camera on the whole wall), or every camera's again (null). */
    showOnly(id) {
      if (destroyed || id === onlyId) return;
      onlyId = id;
      refreshWaveform();
      schedule();
    },
    /**
     * Plays every tile of the page from `ms` (an event of the list): the shared playhead moves there and the cells play, the timeline follows
     * the playhead, and the address follows as it does after a drag. Within five seconds of now it is live. False when it cannot act.
     */
    playAt(ms) {
      if (!canAct() || !Number.isFinite(ms)) return false;
      session.play(ms);
      schedule();
      return true;
    },
    seek(deltaMs) { if (canAct()) { session.seek(deltaMs); schedule(); } },
    retryTile() { if (canAct()) session.seek(0); },
    key(keyAction) {
      if (!keyAction) return;
      if (keyAction.action === 'togglePlay') api.togglePlay();
      else if (keyAction.action === 'goLive') api.goLive();
      else if (keyAction.action === 'seek') api.seek(keyAction.deltaMs);
      else if (keyAction.action === 'speed') api.stepSpeed(keyAction.step);
    },

    setPage(next) {
      if (destroyed) return;
      page = next;
      applyPage({ keepLead: false });
      schedule();
    },
    /**
     * The pages again (paginate's answer changed: the wall's size, the mosaic's width, a picture's shape). The page that holds the focused
     * (hovered) camera shows, else the one that holds the camera that led the page on screen, so the wall stays where it was.
     */
    relayout() {
      if (destroyed) return;
      applyPage();
      schedule();
    },
    nextPage() { api.setPage(page + 1); },
    previousPage() { api.setPage(page - 1); },
    get page() { return page; },
    get focusedId() { return focusId; },
    canAct,

    /** The hovered or focused tile gets the first token and the first exact picture. It stays until another tile is chosen. */
    focus(id) {
      if (destroyed || id === focusId || !slice.includes(id)) return;
      focusId = id;
      session.focus(id);
      remember({ page, focusId });
      schedule();
    },

    /** Opens the watch screen on this camera at the shared moment. The grid's own address is set first, so Back returns to it. */
    openTile(id) {
      if (destroyed || !slice.includes(id)) return;
      const ms = handoffMs();
      remember({ page, focusId: id, opened: id });
      replaceHash(gridPath(ms));
      navigate(watchPath(id, ms));
    },

    suspend() { if (!destroyed) session.suspend(); },
    resume() { if (!destroyed) { session.resume(); schedule(); } },

    destroy() {
      if (destroyed) return;
      destroyed = true;
      if (tickTimer !== null) clearTick(tickTimer);
      tickTimer = null;
      for (const off of unsubscribers.splice(0)) off();
      for (const off of cellWatchers.values()) off();
      cellWatchers.clear();
      listeners.clear();
    },
  };
  return api;
}
