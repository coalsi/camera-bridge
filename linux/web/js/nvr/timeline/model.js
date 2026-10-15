// What the timeline knows: the visible window, whether it follows the live edge, and the activity bins for it.
// No DOM. `session` and `catalog` are the T08 objects (only the members named below are used); timers and storage are injected for tests.
import { PRESETS, RIGHT_MARGIN, clampViewport, panViewport, presetViewport, sameViewport, xForTime, zoomViewport } from './viewport.js';
import { combineActivity, planActivityRequest, planCovers, visibleLevels, waveformReference } from './activity.js';

export const ZOOM_KEY = 'cb.nvr.zoom';
export const DEFAULT_PRESET = '1h';
export const REFRESH_MS = 2000;                       // the waveform follows new footage at most this often
export const RETRY_MS = [2000, 4000, 8000, 16000];    // after a failed request
const MAX_INCOMPLETE_RETRIES = 30;

/** `onChange(fn)` may or may not hand back an unsubscribe function: call it when it does. */
export const release = (unsubscribe) => (typeof unsubscribe === 'function' ? unsubscribe() : undefined);

/** localStorage that never throws (private windows, blocked storage). */
export function safeStorage() {
  return {
    getItem(key) { try { return globalThis.localStorage.getItem(key); } catch { return null; } },
    setItem(key, value) { try { globalThis.localStorage.setItem(key, value); } catch { /* not remembered */ } },
  };
}

export function createTimelineModel({
  session, catalog, storage: injectedStorage = safeStorage(), widthPx = 800,
  setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = (id) => clearTimeout(id), perf = () => performance.now(),
}) {
  // Whatever storage is given, a failing read or write is never the model's failure.
  const storage = {
    getItem(key) { try { return injectedStorage.getItem(key); } catch { return null; } },
    setItem(key, value) { try { injectedStorage.setItem(key, value); } catch { /* not remembered */ } },
  };
  const listeners = new Set();
  let cameras = [];
  let width = widthPx;
  let disposed = false;
  let initialised = false;
  let preset = PRESETS.includes(storage.getItem(ZOOM_KEY)) ? storage.getItem(ZOOM_KEY) : DEFAULT_PRESET;
  let following = session.mode === 'live';
  let lastMode = session.mode;
  let data = null;                    // { plan, answer, combined, reference }
  let problem = false;                // the last two activity requests failed
  let wanted = null;                  // the plan to fetch next
  let inflight = false;
  let failures = 0;
  let incompleteRetries = 0;
  let stale = false;
  let lastFetchAt = -Infinity;
  let retryTimer = null;
  let refreshTimer = null;

  const nowMs = () => catalog.serverNow();
  const emit = (kind) => { for (const fn of [...listeners]) fn(kind); };

  function extents() {
    return cameras.map((id) => catalog.extent(id)).filter(Boolean);
  }
  function oldestMs() {
    const all = extents();
    return all.length ? Math.min(...all.map((e) => e.oldest)) : null;
  }
  function limits() { return { oldestMs: oldestMs(), nowMs: nowMs() }; }

  function anchoredAtLive(durationMs) {
    return clampViewport({ startMs: nowMs() - durationMs / (1 + RIGHT_MARGIN), durationMs }, limits());
  }

  let viewport = presetViewport(preset, { nowMs: nowMs(), oldestMs: null, playheadMs: session.position, isLive: session.mode === 'live' });

  function setViewport(next) {
    if (sameViewport(viewport, next)) return false;
    viewport = next;
    emit('viewport');
    request(false);
    return true;
  }

  // MARK: Data

  function request(force) {
    if (disposed || cameras.length === 0 || extents().length === 0) return;   // nothing recorded: nothing to ask for
    const plan = planActivityRequest(viewport, width, nowMs());
    if (!force && data && data.plan.binMs === plan.binMs && planCovers(data.plan, viewport, nowMs())) return;
    wanted = plan;
    pump();
  }

  function pump() {
    if (disposed || inflight || !wanted || retryTimer) return;
    const plan = wanted;
    const ids = [...cameras];
    wanted = null;
    inflight = true;
    lastFetchAt = perf();
    Promise.resolve(catalog.activity({ cameras: ids, fromMs: plan.fromMs, binMs: plan.binMs, bins: plan.bins, key: 'timeline-activity' }))
      .then((answer) => {
        inflight = false;
        if (disposed) return;
        if (ids.join() !== cameras.join()) { pump(); return; }       // the cameras changed while this was on its way
        failures = 0;
        problem = false;
        const effective = { ...plan, fromMs: Number.isFinite(answer.from) ? answer.from : plan.fromMs };
        const combined = combineActivity(answer.byCamera, plan.bins);
        data = { plan: effective, answer, combined };
        const incomplete = Object.values(answer.byCamera || {}).some((c) => c && c.complete === false);
        if (incomplete && incompleteRetries < MAX_INCOMPLETE_RETRIES) { incompleteRetries += 1; stale = true; scheduleRefresh(); } else if (!incomplete) incompleteRetries = 0;
        emit('data');
        pump();
      })
      .catch((error) => {
        inflight = false;
        if (disposed) return;
        if (error?.name === 'Superseded') { pump(); return; }
        failures += 1;
        if (failures >= 2 && !problem) { problem = true; emit('data'); }
        wanted = wanted || plan;
        retryTimer = setTimer(() => { retryTimer = null; pump(); }, RETRY_MS[Math.min(failures - 1, RETRY_MS.length - 1)]);
      });
  }

  function scheduleRefresh() {
    if (disposed || !stale || refreshTimer) return;
    const wait = Math.max(0, REFRESH_MS - (perf() - lastFetchAt));
    const run = () => { refreshTimer = null; if (!stale) return; stale = false; request(true); };
    if (wait === 0) run();
    else refreshTimer = setTimer(run, wait);
  }

  const stopCatalog = catalog.onChange(() => {
    if (!initialised && extents().length) { initialised = true; reselect(); }
    stale = true;
    scheduleRefresh();
  });

  // MARK: Following the live edge

  function handleSession() {
    const mode = session.mode;
    if (mode === 'live' && lastMode !== 'live') { following = true; reanchor(); }
    if (mode !== 'live') following = false;
    lastMode = mode;
  }
  const stopSession = session.onChange(() => handleSession());

  function reanchor() {
    if (following && PRESETS.includes(preset)) {
      setViewport(presetViewport(preset, { nowMs: nowMs(), oldestMs: oldestMs(), isLive: true }));
    } else if (following) {
      setViewport(anchoredAtLive(viewport.durationMs));
    }
  }

  /** Shows the remembered preset again (a window the person zoomed by hand falls back to the default). */
  function reselect() {
    selectPreset(PRESETS.includes(preset) ? preset : DEFAULT_PRESET, { remember: false });
  }

  function selectPreset(name, { remember = true } = {}) {
    if (!PRESETS.includes(name)) throw new RangeError(`Unknown timeline preset: ${name}`);
    const isLive = session.mode === 'live';
    preset = name;
    following = isLive;
    initialised = extents().length > 0;
    if (remember) storage.setItem(ZOOM_KEY, name);
    const next = presetViewport(name, { nowMs: nowMs(), oldestMs: oldestMs(), playheadMs: session.position, isLive });
    if (!setViewport(next)) emit('viewport');
    return viewport;
  }

  const model = {
    get viewport() { return viewport; },
    get preset() { return preset; },
    get following() { return following; },
    get cameras() { return cameras; },
    get data() { return data; },
    get problem() { return problem; },
    /** True when none of the cameras has anything recorded: the track is disabled. */
    get empty() { return extents().length === 0; },
    get oldestMs() { return oldestMs(); },
    get newestMs() { const all = extents(); return all.length ? Math.max(...all.map((e) => e.newest)) : null; },
    get typicalGOP() { const all = extents().map((e) => e.typicalGOP).filter((v) => Number.isFinite(v)); return all.length ? Math.max(...all) : null; },
    get nowMs() { return nowMs(); },
    get limits() { return limits(); },

    setCameras(ids) {
      if (ids.join() === cameras.join()) return;
      cameras = [...ids];
      data = null;
      problem = false;
      failures = 0;
      stale = false;
      wanted = null;
      initialised = false;
      reselect();
      request(true);
      emit('data');
    },

    setWidth(px) {
      if (!(px > 0) || px === width) return;
      width = px;
      emit('viewport');
      request(false);
    },

    select: selectPreset,

    zoom(factor, anchorMs) {
      const next = zoomViewport(viewport, factor, anchorMs, limits());
      const rightEdge = viewport.startMs + viewport.durationMs;
      if (!(following && anchorMs >= rightEdge - viewport.durationMs * 0.05)) following = false;
      preset = 'custom';
      if (!setViewport(following ? anchoredAtLive(next.durationMs) : next)) emit('viewport');
    },

    pan(deltaMs) {
      following = false;
      preset = 'custom';
      if (!setViewport(panViewport(viewport, deltaMs, limits()))) emit('viewport');
    },

    /** Shows the whole archive without remembering it as the preset. */
    showAll() { return selectPreset('all'); },

    /** Once a second: slide a following window by the time that passed, bring the playhead back into view while playing, and refresh stale bins. */
    tick() {
      if (disposed) return;
      handleSession();
      const now = nowMs();
      if (following) {
        const next = PRESETS.includes(preset)
          ? presetViewport(preset, { nowMs: now, oldestMs: oldestMs(), isLive: true })
          : anchoredAtLive(viewport.durationMs);
        // Less than one pixel of movement is not worth a redraw.
        if (Math.abs(xForTime(viewport, next.startMs, width)) >= 1 || next.durationMs !== viewport.durationMs) setViewport(next);
      } else if (session.mode === 'playing') {
        const at = session.position;
        if (at < viewport.startMs || at > viewport.startMs + viewport.durationMs) {
          setViewport(clampViewport({ startMs: at - viewport.durationMs / 2, durationMs: viewport.durationMs }, limits()));
        }
      }
      scheduleRefresh();
    },

    /** What the painter needs from the data: the scale for the visible bins. */
    scale() {
      if (!data) return null;
      const reference = waveformReference(data.combined.typical, visibleLevels(data.combined, data.plan, viewport));
      return { reference, typical: data.combined.typical };
    },

    onChange(fn) { listeners.add(fn); return () => listeners.delete(fn); },

    dispose() {
      disposed = true;
      clearTimer(retryTimer);
      clearTimer(refreshTimer);
      release(stopCatalog);
      release(stopSession);
      listeners.clear();
    },
  };
  return model;
}
