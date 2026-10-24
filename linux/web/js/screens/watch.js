// The watch screen: #/camera/:id/watch[/<epoch ms>]. One camera's picture, live or recorded, with a transport row and the timeline below it.
// This file only wires things together: the rules are in watch-state.js, the timeline is nvr/timeline/*, the player is nvr/{session,cell,surface}.js.
import { get, getBytes } from '../api.js';
import { h, replace, toast } from '../dom.js';
import { icon } from '../icons.js';
import { store, subscribe } from '../store.js';
import { createStraightenedView, isOn } from '../live/straighten.js';
import { createCatalog } from '../nvr/catalog.js';
import { createCell } from '../nvr/cell.js';
import { LIVE_SNAP_MS, PlaybackClock } from '../nvr/clock.js';
import { createFetcher } from '../nvr/fetcher.js';
import { createSession } from '../nvr/session.js';
import { MseSurface } from '../nvr/surface.js';
import { keyAction } from '../nvr/timeline/keys.js';
import { createTimeline, ensureStylesheet } from '../nvr/timeline/view.js';
import { createClip } from '../nvr/clip.js';
import { footageOf } from '../nvr/clip-range.js';
import { banners } from './banners.js';
import { backLink, statePill } from './common.js';
import { MANUAL_STEPS, optimizeDialog } from './optimize-dialog.js';
import { createPreview } from './preview.js';
import { EMPTY_TIMELINE_OFF, EMPTY_TIMELINE_ON, OLDEST_CAPTION, formatReadout, gopCaption, makeTimeFormatter, recorderHealthy, shouldStartLive, stageState } from './watch-state.js';

// T09's lite.js hands out the Record switch. It is imported on demand, so this screen works (without the switch) before that file exists.
const loadNVR = () => import('../nvr/lite.js').then((lite) => lite.loadNVR()).catch(() => null);

const LOADING_DELAY_MS = 300;
const CATALOG_GRACE_MS = 3000;          // without a catalog answer or a `phase`, an empty catalog counts as ready after this long
const HASH_EVERY_MS = 2000;
const LEAD_LIMIT_BYTES = 16 * 1024 * 1024;

/** A picture correction as text, to tell when it changed ('' while off). */
const correctionText = (c) => (isOn(c) ? `${Number(c.straighten) || 0},${Number(c.level) || 0}` : '');

function debugEnabled() {
  try { return globalThis.localStorage.getItem('cb.nvr.debug') === '1'; } catch { return false; }
}

/**
 * `player`: the player's pieces, replaceable by a test ({ createCell, Surface }; the cell of nvr/cell.js and the MseSurface of nvr/surface.js).
 */
export function renderWatch({ params, navigate, setTitle, player = {} }) {
  const { createCell: newCell = createCell, Surface = MseSurface } = player;
  const id = params[0];
  const startMs = params[1] && /^\d{10,15}$/.test(params[1]) ? Number(params[1]) : null;
  let camera = store.cameras.get(id);
  if (!camera) {
    return {
      el: h('div', null, backLink('#/cameras', 'Cameras'),
        h('div', { class: 'empty' }, h('h2', null, 'This camera was removed'), h('a', { class: 'btn primary', href: '#/cameras' }, 'Back to your cameras'))),
      destroy() {},
    };
  }
  ensureStylesheet();
  setTitle(`${camera.name}: recordings`);

  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const format = makeTimeFormatter({ timeZone: zone });
  const mountedAt = performance.now();
  let destroyed = false;
  let presented = false;                // a recorded or live frame has been shown on this stage
  let opened = startMs === null;       // the start time of the address has been applied
  let liveAsked = startMs !== null;    // the session was asked to go live (an address with a time never is: openAt moves the playhead instead)
  let lastKey = '';
  let lastPreviewWanted = null;
  let loadingTimer = null;
  let wasLoading = false;
  let transientCaption = null;
  let transientTimer = null;
  let lastOverlayKind = null;
  let lastMode = null;
  let lastHash = '';
  let lastHashAt = -Infinity;
  let scrubbable = false;
  let recordControl = null;
  const playable = typeof globalThis.MediaSource !== 'undefined' || typeof globalThis.ManagedMediaSource !== 'undefined';

  // MARK: The player

  const video = h('video', { class: 'watch-video', 'aria-label': `Recording of ${camera.name}`, dataset: { nvr: 'video' } });
  video.muted = true;
  video.playsInline = true;
  video.setAttribute('playsinline', '');
  video.controls = false;
  const holdCanvas = h('canvas', { class: 'watch-hold', hidden: true, 'aria-hidden': 'true' });
  const fetcher = createFetcher({ get, getBytes, sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)) });
  const catalog = createCatalog({ fetcher });
  const clock = new PlaybackClock({ serverNow: () => catalog.serverNow() });
  const stage = { video, holdCanvas };
  // The one place that knows how a cell is built for this screen; the session asks for it once per camera.
  // getPause: status.nvr.pause of this camera as the page's store has it; 'folderMissing' makes a 410 mean "the recordings drive is gone" (T08 D.6).
  const makeCell = () => newCell({
    cameraId: id, stage, catalog, fetcher, clock, leadLimitBytes: LEAD_LIMIT_BYTES, getPause: () => camera.status?.nvr?.pause ?? null,
    createSurface: ({ video: v, holdCanvas: c }) => new Surface({ video: v, holdCanvas: c, holdFrom }),
  });
  const session = createSession({ catalog, fetcher, clock, createCell: makeCell, tileCap: 1 });
  catalog.start();
  session.setCameras([id]);

  // MARK: Elements

  const preview = createPreview(camera, { note: false });
  preview.el.classList.add('watch-preview');
  const badge = h('span', { class: 'pill plain watch-badge', hidden: true });
  const loadingPill = h('span', { class: 'pill plain watch-loading', hidden: true }, 'Loading');
  const overlayEl = h('div', { class: 'watch-overlay', hidden: true });   // announced through the timeline's polite region, once per kind
  const stageEl = h('div', { class: 'watch-stage', dataset: { nvr: 'stage', layer: 'preview' } },
    preview.el, video, holdCanvas, h('div', { class: 'watch-badges' }, badge, loadingPill), overlayEl);

  // The recording straightened as the camera's page says (js/live/straighten.js): a canvas right after the video, under the hold, with the
  // video's classes, so the stage's layers show it as they would the video. Made the first time the correction is on; it follows the store.
  let straightened = null;
  let straightenedAs = null;
  function straighten() {
    const correction = camera.pictureCorrection ?? null;
    if (correctionText(correction) === straightenedAs) return;
    straightenedAs = correctionText(correction);
    if (straightened) straightened.set(correction);
    else if (isOn(correction)) straightened = createStraightenedView({ source: video, correction });
  }
  straighten();

  /**
   * The picture the player holds on screen while it builds its buffer again (nvr/surface.js): the straightened canvas, drawn now with the
   * camera's correction (a WebGL canvas can be copied only right after a draw), so the hold never flashes the camera's original picture; null
   * while the picture is not straightened (the video's own frame is then what the person sees). The stage's own video is this screen's to
   * straighten, so the cell's `holdFrom` (for the video it makes itself) has nothing to give.
   */
  function holdFrom() {
    straightened?.set(camera.pictureCorrection ?? null);
    return straightened?.canvas ?? null;
  }

  const captionText = h('span', { class: 'watch-caption-text muted small' });
  const nudgeButton = h('button', { class: 'btn small', type: 'button', hidden: true, onclick: turnOnRecord }, 'Turn on Record');
  const captionRow = h('div', { class: 'watch-caption row' }, captionText, nudgeButton);

  const playButton = h('button', { class: 'btn small watch-play', type: 'button', onclick: () => session.togglePlay(), dataset: { nvr: 'play' } });
  const readoutPrimary = h('span', { class: 'watch-time', dataset: { nvr: 'readout' } });
  const readoutSecondary = h('span', { class: 'watch-ago muted small' });
  const liveButton = h('button', { class: 'btn small', type: 'button', onclick: () => session.goLive(), dataset: { nvr: 'go-live' } }, icon('bolt'), 'Go live');
  const recordSlot = h('div', { class: 'watch-record' });
  // Saving a clip: the playhead is the end (the newest recorded moment while live).
  const clip = createClip({
    cameras: () => [{ id, name: camera.name, pictureCorrection: camera.pictureCorrection }],
    endMs: () => (session.mode === 'live' ? catalog.serverNow() : session.position),
    footage: () => footageOf([catalog.extent(id)]),
    timeline: { setClipRange: (range, onEdge) => timeline?.setClipRange(range, onEdge) },
    onChange: () => update(),
  });
  const transport = h('div', { class: 'watch-transport' },
    playButton, h('div', { class: 'watch-readout', role: 'timer', 'aria-live': 'off' }, readoutPrimary, readoutSecondary), liveButton, clip.button, recordSlot);

  const timeline = createTimeline({
    session, catalog, timeZone: zone,
    isHealthy: () => healthy(),
    onRelease: ({ edge }) => { if (edge === 'oldest') flashCaption(OLDEST_CAPTION); },
  });
  timeline.setCameras([id]);

  const gopText = h('div', { class: 'title' });
  const fixButton = h('button', { class: 'btn small', type: 'button', onclick: fixKeyFrames }, 'Make scrubbing smoother…');
  const gopBlock = h('div', { class: 'banner info watch-gop', hidden: true }, icon('info'),
    h('div', { class: 'text' }, gopText,
      h('details', { class: 'small' }, h('summary', null, 'How to fix it on the camera'), h('ol', { class: 'steps' }, MANUAL_STEPS.map((line) => h('li', null, line)))),
      h('div', { class: 'actions' }, fixButton)));

  const heading = h('div', { class: 'page-head' });
  const bannerHost = banners();

  function renderHead() {
    const nvr = camera.status?.nvr;
    const chip = nvr?.state === 'recording' ? h('span', { class: 'pill recording', dataset: { nvr: 'rec-chip' } }, 'REC')
      : nvr?.state === 'waiting' ? h('span', { class: 'pill warning', dataset: { nvr: 'rec-chip' } }, 'REC waiting')
        : nvr?.state === 'paused' ? h('span', { class: 'pill warning', dataset: { nvr: 'rec-chip' } }, 'REC paused') : null;
    replace(heading, h('h1', null, camera.name), statePill(camera), chip);
  }

  // MARK: What is on screen

  const healthy = () => recorderHealthy({
    nvrEnabled: camera.nvrEnabled === true, nvrState: camera.status?.nvr?.state ?? 'off', extent: catalog.extent(id), serverNowMs: catalog.serverNow(),
  });

  function flashCaption(text) {
    transientCaption = text;
    clearTimeout(transientTimer);
    transientTimer = setTimeout(() => { transientCaption = null; update(); }, 4000);
    update();
  }

  function phase() {
    if (catalog.phase) return catalog.phase;      // 'starting' | 'ready' | 'loading' | 'unavailable' when the catalog says
    return catalog.extent(id) || performance.now() - mountedAt > CATALOG_GRACE_MS ? 'ready' : 'starting';
  }

  /**
   * Live with a healthy recorder is the recorded edge, and T08's session is idle until it is asked (nothing decodes before the first scrub, play
   * or go live), so the screen asks once. It does so from update(), which runs every 250 ms and on every change, so it also happens when the
   * person turns Record on while watching and the first footage arrives. A person who has already scrubbed, paused or played is left alone.
   */
  function startLive() {
    if (liveAsked || document.hidden) return;
    const mode = session.mode;
    if (mode !== 'live') { liveAsked = true; return; }
    if (!shouldStartLive({ addressHasTime: startMs !== null, started: liveAsked, mode, healthy: healthy() })) return;
    liveAsked = true;
    session.goLive();
  }

  function update() {
    clip.tick();
    if (destroyed) return;
    startLive();
    const extent = catalog.extent(id);
    const cell = session.cell(id)?.coverage ?? { kind: 'idle', next: null, message: null };
    if (cell.kind === 'recorded' || cell.kind === 'live' || cell.kind === 'coarse') presented = true;
    const mode = session.mode;
    const position = session.position;
    const now = catalog.serverNow();
    const state = stageState({
      mode, nvrEnabled: camera.nvrEnabled === true, nvrState: camera.status?.nvr?.state ?? 'off', extent, serverNowMs: now, positionMs: position,
      cell, presented, catalogPhase: phase(), playable, formatTime: format,
    });

    const readout = formatReadout({ mode, positionMs: position, serverNowMs: now, healthy: healthy(), format });
    if (readoutPrimary.textContent !== readout.primary) readoutPrimary.textContent = readout.primary;
    if (readoutSecondary.textContent !== readout.secondary) readoutSecondary.textContent = readout.secondary;

    const showsPlay = mode === 'paused';
    const key = JSON.stringify([state, transientCaption, showsPlay, mode, extent ? extent.typicalGOP : null]);
    if (key === lastKey) { writeHash(); return; }
    lastKey = key;

    stageEl.dataset.layer = state.layer;
    // The snapshot stays under the video until a recorded frame has been shown, so the stage is never empty.
    const previewWanted = !(state.layer === 'video' && presented);
    if (previewWanted !== lastPreviewWanted) {
      lastPreviewWanted = previewWanted;
      if (previewWanted) preview.start(); else preview.stop();
    }
    badge.hidden = state.badge.kind === 'none';
    badge.className = `pill plain watch-badge ${state.badge.kind}`;
    badge.textContent = state.badge.text;
    if (state.loading && !wasLoading) loadingTimer = setTimeout(() => { loadingPill.hidden = false; }, LOADING_DELAY_MS);
    if (!state.loading) { clearTimeout(loadingTimer); loadingPill.hidden = true; }
    wasLoading = state.loading;

    if (state.overlay) {
      replace(overlayEl, h('div', { class: 'text' }, h('strong', null, state.overlay.title), h('p', { class: 'small' }, state.overlay.body)),
        state.overlay.actions.length ? h('div', { class: 'actions' }, state.overlay.actions.map((a) => h('button', {
          class: `btn small${a.primary ? ' primary' : ''}`, type: 'button', onclick: () => overlayAction(a.id, cell),
        }, a.label))) : null);
      overlayEl.hidden = false;
      if (state.overlay.kind !== lastOverlayKind) timeline.announce(state.overlay.title);
    } else {
      overlayEl.hidden = true;
    }
    lastOverlayKind = state.overlay ? state.overlay.kind : null;
    if (mode !== lastMode && mode === 'live') timeline.announce('Live');
    lastMode = mode;

    timeline.setEmptyText(camera.nvrEnabled === true ? EMPTY_TIMELINE_ON : EMPTY_TIMELINE_OFF);
    const caption = transientCaption || state.caption;
    captionText.textContent = caption || '';
    captionRow.hidden = !caption;
    nudgeButton.hidden = !state.nudge;

    replace(playButton, icon(showsPlay ? 'play' : 'pause'), showsPlay ? 'Play' : 'Pause');
    playButton.setAttribute('aria-label', showsPlay ? 'Play' : 'Pause');
    scrubbable = state.scrubbable;
    playButton.disabled = !state.scrubbable || (mode === 'live' && !healthy());
    liveButton.disabled = mode === 'live';

    const text = gopCaption(extent ? extent.typicalGOP : null);
    gopBlock.hidden = text === null;
    if (text !== null) gopText.textContent = text;
    writeHash();
  }

  // MARK: Actions

  function overlayAction(actionId, cell) {
    if (actionId === 'live') session.goLive();
    else if (actionId === 'jump' && Number.isFinite(cell.next)) jumpTo(cell.next);
    else if (actionId === 'retry') jumpTo(session.position);
  }

  /** Go to a time and play from there (what releasing a drag there would do). */
  function jumpTo(ms) {
    session.beginScrub();
    session.scrub(ms);
    session.endScrub();
  }

  /** Opens at the time in the address, paused. A time within the live window just stays live. */
  function openAt(ms) {
    const extent = catalog.extent(id);
    if (ms >= catalog.serverNow() - LIVE_SNAP_MS) return;
    jumpTo(extent ? Math.max(ms, extent.oldest) : ms);
    session.pause();
  }

  async function turnOnRecord() {
    try {
      const { setRecording } = await import('../nvr/record.js');
      await setRecording(id, true);
    } catch (error) {
      toast(error?.message || 'Record couldn’t be turned on.', 'error');
    }
  }

  async function fixKeyFrames() {
    const outcome = await optimizeDialog(camera);
    if (outcome === 'applied') toast('Camera settings changed. New recordings will scrub better.', 'ok');
  }

  /** The address follows the playhead (at most every 2 s), so a reload comes back to the same minute. */
  function writeHash() {
    if (!opened) return;                 // keep the time of the address until it has been applied
    const t = performance.now();
    if (t - lastHashAt < HASH_EVERY_MS) return;
    const target = `#/camera/${id}/watch${session.mode === 'live' ? '' : `/${Math.round(session.position)}`}`;
    if (target === lastHash) return;
    lastHash = target;
    lastHashAt = t;
    try { history.replaceState(history.state, '', target); } catch { /* a sandboxed frame */ }
  }

  // MARK: Wiring

  const onKey = (event) => {
    const typingNow = Boolean(event.target?.closest?.('input, select, textarea, [contenteditable=""], [contenteditable="true"]')) || Boolean(document.querySelector('dialog[open]'));
    if (!typingNow && clip.key(event)) { event.preventDefault(); return; }
    const action = keyAction(event);
    if (!action) return;
    event.preventDefault();
    if (action.type === 'close') { navigate(`/camera/${id}`); return; }
    // Nothing to play, seek or jump to while nothing is recorded, or while live is only the snapshot slideshow.
    if (action.type === 'togglePlay' && playButton.disabled) return;
    if ((action.type === 'seek' || action.type === 'oldest') && !scrubbable) return;
    timeline.perform(action);
  };
  const onVisibility = () => {
    if (document.hidden) session.suspend();
    else { session.resume(); update(); }
  };
  document.addEventListener('keydown', onKey);
  document.addEventListener('visibilitychange', onVisibility);

  // Events can come at the rate of the pointer; the screen is brought up to date at most once per animation frame.
  let updateQueued = false;
  const scheduleUpdate = () => {
    if (updateQueued || destroyed) return;
    updateQueued = true;
    requestAnimationFrame(() => { updateQueued = false; update(); });
  };

  const stopStore = subscribe((kind, detail) => {
    if (destroyed) return;
    if (kind === 'removed' && detail === id) { toast('This camera was removed.'); navigate('/'); return; }
    if (kind === 'camera' && detail?.id === id) { camera = detail; straighten(); renderHead(); scheduleUpdate(); }
  });
  const stopSession = session.onChange(scheduleUpdate);
  const stopCatalog = catalog.onChange(() => {
    if (!opened && catalog.extent(id)) { opened = true; openAt(startMs); }
    scheduleUpdate();
  });
  const stopCell = session.cell(id)?.onChange?.(scheduleUpdate);
  const ticker = setInterval(update, 250);

  loadNVR().then((ui) => {
    if (destroyed || !ui) return;
    recordControl = ui.recordSwitch(camera, { variant: 'panel' });
    recordSlot.append(recordControl.el);
  });

  renderHead();
  update();

  if (debugEnabled()) globalThis.__cbWatch = { session, catalog, clock, timeline, video, stage: stageEl, fetcher };

  return {
    el: h('div', { class: 'watch', dataset: { nvr: 'watch', camera: id } },
      backLink(`#/camera/${id}`, camera.name), heading, bannerHost, stageEl, captionRow, transport, clip.el, timeline.el, gopBlock),
    destroy() {
      destroyed = true;
      clearInterval(ticker);
      clearTimeout(loadingTimer);
      clearTimeout(transientTimer);
      document.removeEventListener('keydown', onKey);
      document.removeEventListener('visibilitychange', onVisibility);
      for (const stop of [stopStore, stopSession, stopCatalog, stopCell]) if (typeof stop === 'function') stop();
      recordControl?.destroy?.();
      clip.destroy();
      timeline.destroy();
      session.destroy();
      catalog.stop();
      fetcher.destroy();
      preview.destroy();
      bannerHost.destroy();
      straightened?.destroy();
      video.removeAttribute('src');
      if (globalThis.__cbWatch?.session === session) delete globalThis.__cbWatch;
    },
  };
}
