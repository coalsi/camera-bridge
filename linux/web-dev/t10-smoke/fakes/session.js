// Smoke stand-in for T08's js/nvr/session.js: a clock (live / paused / playing) and a cell that settles 80 ms after the last scrub.
import { LIVE_SNAP_MS } from './clock.js';

export function createSession({ catalog, createCell }) {
  const listeners = new Set();
  let mode = 'live';
  let anchor = 0;
  let since = 0;
  let cell = null;
  let settle = null;
  let goLiveCalls = 0;
  let liveTimer = null;
  const emit = () => listeners.forEach((fn) => fn());
  const now = () => catalog.serverNow();
  const session = {
    get mode() { return mode; },
    get goLiveCalls() { return goLiveCalls; },
    get position() { return mode === 'live' ? now() - 6000 : mode === 'playing' ? anchor + (performance.now() - since) : anchor; },
    onChange(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    setCameras(ids) { cell = createCell({ cameraId: ids[0] }); },
    cell: () => cell,
    beginScrub() {},
    scrub(ms) {
      mode = 'paused'; anchor = ms; cell.set('loading'); emit();
      clearTimeout(settle);
      settle = setTimeout(() => {
        const gap = window.__gap;
        const inGap = gap && ms >= gap.from && ms < gap.to;
        cell.set(inGap ? 'gap' : 'recorded', inGap ? { next: gap.to } : {});
        emit();
      }, 80);
    },
    endScrub() {
      if (anchor >= now() - LIVE_SNAP_MS) { mode = 'live'; cell.set('live'); } else { mode = 'playing'; since = performance.now(); }
      emit();
    },
    play(ms) { anchor = ms ?? session.position; since = performance.now(); mode = 'playing'; emit(); },
    pause() { anchor = session.position; mode = 'paused'; emit(); },
    togglePlay() { if (mode === 'paused') session.play(); else session.pause(); },
    // Like the real cell: the first live picture comes a moment after the request, not in the same breath (the snapshot is the picture until then).
    goLive() {
      goLiveCalls += 1; mode = 'live'; cell.set('loading'); emit();
      clearTimeout(liveTimer);
      liveTimer = setTimeout(() => { if (mode === 'live') { cell.set('live'); emit(); } }, 400);
    },
    seek(deltaMs) { const target = session.position + deltaMs; session.beginScrub(); session.scrub(target); session.endScrub(); },
    suspend() {},
    resume() {},
    destroy() { clearTimeout(settle); clearTimeout(liveTimer); listeners.clear(); },
  };
  return session;
}
