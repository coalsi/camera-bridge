// Sky Watcher's clip player: a modal on the sky log that plays the camera's recording around one light, from 15 s before it to 15 s after it
// (wider on request), so the person never leaves the log. It is the Monitor's playback, not a second player: its fetcher, catalog, clock,
// session and cells (nvr/*), its grid controller driven for this one camera (screens/nvr-controller.js), its transport (nvr/transport.js: Play
// and Pause, a picture at a time, the speeds, the time of day), its keys (nvr-model.js keyAction) and its scrubbing (nvr/timeline/scrub.js).
// What is the player's own: the window (the scrubber spans it, with the light's own time marked on it; the playhead never leaves it and the end
// pauses), the light's path over the video at the matching times, the Zoom around the light, and what it says when there is nothing to play
// (the still instead). Closing it (X, Escape, a tap outside) stops playing and frees the stream. The picture is the camera's original one,
// never straightened: the path is in the original picture's coordinates.
import { get, getBytes } from '../api.js';
import { h, replace, spinner, svg } from '../dom.js';
import { icon } from '../icons.js';
import { subscribe } from '../store.js';
import { createCatalog } from '../nvr/catalog.js';
import { createCell } from '../nvr/cell.js';
import { LIVE_SNAP_MS, PlaybackClock, realTimers } from '../nvr/clock.js';
import { createFetcher } from '../nvr/fetcher.js';
import { choosePolicy, currentEnvironment } from '../nvr/planner.js';
import { createSession } from '../nvr/session.js';
import { speedLabel } from '../nvr/speed.js';
import { MseSurface } from '../nvr/surface.js';
import { createScrubController } from '../nvr/timeline/scrub.js';
import { createTransport } from '../nvr/transport.js';
import { createGridController } from './nvr-controller.js';
import { GRID_LEAD_LIMIT_BYTES, budgetedCell, createKeyDispatcher, createTokenBucket, keyAction } from './nvr-model.js';
import { SKY_TEXT, pathPoints } from './sky-model.js';
import { SKY_KEY_MAP, WINDOW, clipWindow, clockText, marginText, pathPointAt, playerNotice, widenMargin, windowedAction, zoomAt } from './sky-player-model.js';

const T = SKY_TEXT.player;
const IDLE = Object.freeze({ kind: 'idle', next: null, message: null });
const SHOWN = new Set(['recorded', 'coarse', 'live']);
const ARIA_EVERY_MS = 250;      // the scrubber's position is told to assistive technology at most this often
const END_SLACK_MS = 250;       // Play this close to the end of the window starts it again
let sequence = 0;

const round2 = (value) => Math.round(value * 100) / 100;
const percent = (fraction) => `${(Math.min(1, Math.max(0, fraction)) * 100).toFixed(3)}%`;

/** A function every `ms` on `timers` (the real ones, or a test's): -> { stop() }. */
function every(timers, fn, ms) {
  let id = null;
  let stopped = false;
  const run = () => { if (stopped) return; fn(); if (!stopped) id = timers.setTimeout(run, ms); };
  id = timers.setTimeout(run, ms);
  return { stop() { stopped = true; timers.clearTimeout(id); } };
}

/** The picture's size before the recording says: the camera's main stream, else 16:9. */
function streamSize(camera) {
  const info = camera?.status?.mainStreamInfo;
  return info?.width > 0 && info?.height > 0 ? { width: info.width, height: info.height } : { width: 1920, height: 1080 };
}

/**
 * Opens the player over the page. -> { el (the <dialog>), close(), window: { from, to } }
 *   camera     the camera resource (store.js): its id, name, status.nvr.pause (the drive), status.mainStreamInfo (the picture's shape)
 *   entry      the log's entry (sky-model.js normalizeEntry): start, end, path, watch
 *   zone       the box's time zone: the time of day is the box's, as on the log
 *   heading    the light's time ("3:12:08 AM"); what: what it was and where ("Moving light · North Sky")
 *   still      the address of its still (offered when there is no recording to play), or null; watchHref: the Monitor's watch screen at its moment
 *   onClose()  after it closed (the page puts the focus back)
 *   parts      the playback's pieces, for tests: { fetcher, catalog, clock, makeCell(id, { stage, getPause }), policy, timers, playable, frame,
 *              cancelFrame, subscribeCamera }. They are the player's: it stops and destroys them when it closes.
 */
export function openSkyPlayer({ camera, entry, zone, heading = '', what = '', still = null, watchHref = null, onClose = () => {}, parts = {} }) {
  const timers = parts.timers ?? realTimers;
  const frameFn = parts.frame ?? ((fn) => requestAnimationFrame(fn));
  const cancelFrameFn = parts.cancelFrame ?? ((id) => cancelAnimationFrame(id));
  const playable = parts.playable ?? (typeof globalThis.MediaSource !== 'undefined' || typeof globalThis.ManagedMediaSource !== 'undefined');
  const id = camera.id;
  let current = camera;
  let margin = WINDOW.marginMs;
  let range = clipWindow(entry, margin);
  let picture = streamSize(camera);
  let videoSized = false;
  let stillOK = Boolean(still);
  let presented = false;          // a recorded picture of this window has been shown
  let startedOnce = false;        // the window has been asked to play
  let blocked = null;             // what the player says instead of playing (playerNotice), or null
  let zoomed = false;
  let scrubbing = false;
  let hoverX = null;
  let trackWidth = 0;
  let lastAriaAt = -Infinity;
  let drawnAt = null;
  let frameId = null;
  let renderQueued = false;
  let downOutside = false;
  let closed = false;
  let stopRendering = null;
  let stopSession = null;
  let stopCamera = null;

  // MARK: The Monitor's playback, for this one camera

  const fetcher = parts.fetcher ?? createFetcher({ get, getBytes, sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)) });
  const catalog = parts.catalog ?? createCatalog({ fetcher });
  const clock = parts.clock ?? new PlaybackClock({ serverNow: () => catalog.serverNow() });
  const dispatcher = createKeyDispatcher({ bucket: createTokenBucket({ now: () => timers.now() }), focused: () => id,
    setTimer: (fn, ms) => timers.setTimeout(fn, ms), clearTimer: (timer) => timers.clearTimeout(timer) });
  const video = h('video', { class: 'sky-player-video', 'aria-label': `Recording of ${camera.name ?? 'the camera'}` });
  video.muted = true;
  video.playsInline = true;
  video.setAttribute('playsinline', '');
  video.controls = false;
  const holdCanvas = h('canvas', { class: 'sky-player-hold', 'aria-hidden': 'true' });
  const stage = { video, holdCanvas };
  const getPause = () => current.status?.nvr?.pause ?? null;
  const makeCell = parts.makeCell ?? ((cameraId) => createCell({
    cameraId, stage, catalog, fetcher, clock, leadLimitBytes: GRID_LEAD_LIMIT_BYTES, getPause,
    createSurface: ({ video: v, holdCanvas: c }) => new MseSurface({ video: v, holdCanvas: c }),
  }));
  let controller = null;
  const session = createSession({
    catalog, fetcher, clock, tileCap: 1, timers, policy: parts.policy ?? choosePolicy(currentEnvironment()),
    createCell: (cameraId) => budgetedCell(makeCell(cameraId, { stage, getPause }), { id: cameraId, dispatcher, onRequest: () => controller?.noteRequest() }),
  });
  const cameraListeners = new Set();
  controller = createGridController({
    session, catalog, listCameras: () => [current], subscribeCameras: (fn) => { cameraListeners.add(fn); return () => cameraListeners.delete(fn); },
    perPage: 1, initialMs: null, playable, navigate: () => {}, replaceHash: () => {}, remember: () => {},
    formatTime: (ms) => clockText(ms, zone), now: () => timers.now(),
    setTimer: (fn, ms) => timers.setTimeout(fn, ms), clearTimer: (timer) => timers.clearTimeout(timer),
    setTick: (fn, ms) => every(timers, fn, ms), clearTick: (tick) => tick?.stop(),
  });

  /** The end the playhead stops at: the window's, and never within a few seconds of now (playing there would go live, and a clip has no live). */
  const end = () => Math.max(range.from, Math.min(range.to, catalog.serverNow() - LIVE_SNAP_MS - 1000));
  const coverage = () => session.cell(id)?.coverage ?? IDLE;
  /** Where the playhead is drawn: the session's, once the window was asked to play; before that, the window's start (a new clock reads live). */
  const playheadAt = () => (startedOnce ? session.position : range.from);

  // MARK: The picture: the still, the video, the light's path over them

  const stillImg = still ? h('img', { class: 'sky-player-still', src: still, alt: '', decoding: 'async' }) : null;
  const pathLine = svg('polyline', { class: 'sky-path-line', points: '', fill: 'none' });
  const startMark = svg('circle', { class: 'sky-mark sky-mark--start', cx: 0, cy: 0, r: 0 });
  const endMark = svg('circle', { class: 'sky-mark sky-mark--end', cx: 0, cy: 0, r: 0 });
  const nowMark = svg('circle', { class: 'sky-player-now', cx: 0, cy: 0, r: 0 });
  const overlay = svg('svg', { class: 'sky-path sky-player-path', 'aria-hidden': 'true', focusable: 'false', preserveAspectRatio: 'none', viewBox: '0 0 1920 1080' },
    pathLine, startMark, endMark, nowMark);
  // The Zoom is a CSS transform of the picture with its origin at the light; the path is drawn beside it, in the same frame, with its view
  // box on the part of the picture that is on screen, so that its lines keep their width.
  const pictureEl = h('div', { class: 'sky-player-picture' }, stillImg, video, holdCanvas);
  const frameEl = h('div', { class: 'sky-player-frame' }, pictureEl, overlay);
  const busy = h('span', { class: 'sky-player-busy', hidden: true }, spinner());
  // What the picture says (the Monitor's tile notes: a hole after part of the window, a part it cannot read), over the picture's foot; what the
  // player says instead of playing is a line of its own above the picture, so the still stays whole.
  const note = h('div', { class: 'sky-player-note', role: 'status', hidden: true });
  const notice = h('div', { class: 'sky-player-notice', role: 'status', hidden: true });
  const stageEl = h('div', { class: 'sky-player-stage', dataset: { layer: 'still', zoom: 'false' } }, frameEl, busy, note);

  function setPicture(width, height) {
    if (!(width > 0 && height > 0)) return;
    picture = { width, height };
    stageEl.style.setProperty('--sky-ratio', String(round2(width / height)));
    drawPath();
    drawNow(playheadAt());
    drawnAt = null;
  }

  /** The part of the picture on screen: all of it, or with the Zoom `z` the part a scale about its origin leaves in the frame. In its pixels. */
  function viewBoxFor(z) {
    const { width, height } = picture;
    if (!z) return `0 0 ${width} ${height}`;
    const ox = z.x / 100;
    const oy = z.y / 100;
    return `${round2(width * (ox - ox / z.scale))} ${round2(height * (oy - oy / z.scale))} ${round2(width / z.scale)} ${round2(height / z.scale)}`;
  }

  /** The whole path, faint, with where it began and ended; the light itself is drawn where it is at the playhead (drawNow). */
  function drawPath() {
    const { width, height } = picture;
    const points = pathPoints(entry.path, width, height);
    const list = points ? points.split(' ').map((pair) => pair.split(',')) : [];
    const scale = zoomed ? zoomScale() : 1;
    const size = Math.max(width, height);
    pathLine.setAttribute('points', list.length >= 2 ? points : '');
    for (const [mark, at] of [[startMark, list[0]], [endMark, list.at(-1)]]) {
      mark.setAttribute('r', String(at && list.length >= 2 ? round2((size * 0.006) / scale) : 0));
      if (at) { mark.setAttribute('cx', at[0]); mark.setAttribute('cy', at[1]); }
    }
    nowMark.setAttribute('r', String(round2((size * 0.016) / scale)));
  }

  const zoomScale = () => zoomAt(entry.path, entry.start, playheadAt(), picture)?.scale ?? 1;

  /** The light where it is at `ms`, and the Zoom's origin there. */
  function drawNow(ms) {
    const point = pathPointAt(entry.path, entry.start, ms, entry.end);
    const at = point?.at ?? 'none';            // 'before' | 'during' | 'after': drawn differently (sky.css); 'none': no path
    if (nowMark.dataset.at !== at) nowMark.dataset.at = at;
    if (point) {
      nowMark.setAttribute('cx', String(round2(point.x * picture.width)));
      nowMark.setAttribute('cy', String(round2(point.y * picture.height)));
    }
    const z = zoomed ? zoomAt(entry.path, entry.start, ms, picture) : null;
    overlay.setAttribute('viewBox', viewBoxFor(z));
    if (!z) return;
    pictureEl.style.setProperty('--sky-zoom', String(z.scale));
    pictureEl.style.setProperty('--sky-zoom-x', `${z.x}%`);
    pictureEl.style.setProperty('--sky-zoom-y', `${z.y}%`);
  }

  for (const type of ['loadedmetadata', 'resize']) {
    video.addEventListener(type, () => {
      if (!(video.videoWidth > 0)) return;
      videoSized = true;
      setPicture(video.videoWidth, video.videoHeight);
    });
  }
  stillImg?.addEventListener('load', () => { if (!videoSized) setPicture(stillImg.naturalWidth, stillImg.naturalHeight); });
  stillImg?.addEventListener('error', () => { stillOK = false; stillImg.hidden = true; queueRender(); });

  // MARK: The transport (the Monitor's), Zoom and the keys' help

  const transport = createTransport({ onPlay: () => togglePlay(), onStep: (direction) => step(direction), onSpeed: (rate) => controller.setSpeed(rate), keyMap: SKY_KEY_MAP });
  const zoomButton = h('button', { class: 'btn small sky-player-zoom', type: 'button', 'aria-pressed': 'false', title: T.zoomHint, onclick: () => setZoom(!zoomed) },
    icon('search'), h('span', { class: 'sky-player-zoom-word' }, T.zoom));
  const transportRow = h('div', { class: 'nvr-transport sky-player-transport' },
    transport.frameBackButton, transport.playButton, transport.frameForwardButton, transport.readout, transport.speedGroup, zoomButton, transport.keysHelp);

  // MARK: The scrubber over the window, the light's own time marked on it

  const span = h('div', { class: 'sky-scrub-span', 'aria-hidden': 'true' });
  const playhead = h('div', { class: 'nvr-playhead', 'aria-hidden': 'true' });
  const bubble = h('div', { class: 'nvr-bubble', 'aria-hidden': 'true', hidden: true });
  const track = h('div', { class: 'nvr-track sky-scrub-track', role: 'slider', tabindex: 0, 'aria-label': T.position, 'aria-orientation': 'horizontal' }, span, playhead, bubble);
  const fromLabel = h('span', { class: 'sky-scrub-from' });
  const lightLabel = h('span', { class: 'sky-scrub-light' });
  const toLabel = h('span', { class: 'sky-scrub-to' });
  const marginLabel = h('span', { class: 'sky-player-margin' });
  const widenButtons = WINDOW.widenMs.map((stepMs, index) => h('button', {
    class: 'btn small', type: 'button', 'aria-label': index === 0 ? T.widenOneLabel : T.widenFiveLabel, title: index === 0 ? T.widenOneLabel : T.widenFiveLabel,
    onclick: () => setMargin(widenMargin(margin, stepMs)),
  }, index === 0 ? T.widenOne : T.widenFive));
  const narrowButton = h('button', { class: 'btn small ghost', type: 'button', hidden: true, onclick: () => setMargin(WINDOW.marginMs) }, T.narrow);
  const scrub = h('div', { class: 'sky-scrub' }, track, h('div', { class: 'sky-scrub-ends', 'aria-hidden': 'true' }, fromLabel, lightLabel, toLabel));
  const widenRow = h('div', { class: 'sky-player-widen' }, marginLabel, widenButtons, narrowButton);

  const scrubber = createScrubController({
    session,
    timeForX: (x) => range.from + (Math.min(Math.max(x, 0), trackWidth) / Math.max(1, trackWidth)) * (range.to - range.from),
    clampMs: (ms) => Math.min(Math.max(ms, range.from), end()),
    requestFrame: (fn) => frameFn(fn),
    cancelFrame: (frame) => cancelFrameFn(frame),
    isEnabled: () => !closed && !blocked && controller.canAct() && trackWidth > 0,
    onStart: () => { scrubbing = true; track.classList.add('is-scrubbing'); },
    onEnd: () => { scrubbing = false; track.classList.remove('is-scrubbing'); drawnAt = null; },
  });
  const measure = () => {
    const box = track.getBoundingClientRect();
    trackWidth = box.width || 0;
    return box.left || 0;
  };
  const localX = (event) => event.clientX - measure();
  track.addEventListener('pointerdown', (event) => {
    const x = localX(event);
    if (!scrubber.down({ id: event.pointerId, pointerType: event.pointerType, x, button: event.button })) return;
    try { track.setPointerCapture(event.pointerId); } catch { /* a synthetic pointer has nothing to capture */ }
    track.focus?.({ preventScroll: true });
    event.preventDefault?.();
  });
  track.addEventListener('pointermove', (event) => {
    const x = localX(event);
    hoverX = event.pointerType === 'mouse' || scrubber.scrubbing ? x : null;
    scrubber.move({ id: event.pointerId, x });
  });
  track.addEventListener('pointerup', (event) => {
    scrubber.up({ id: event.pointerId, x: localX(event) });
    try { track.releasePointerCapture(event.pointerId); } catch { /* already released */ }
    if (event.pointerType !== 'mouse') hoverX = null;
  });
  track.addEventListener('pointercancel', () => scrubber.cancel());
  track.addEventListener('lostpointercapture', () => scrubber.cancel());
  track.addEventListener('pointerleave', () => { if (!scrubber.scrubbing) hoverX = null; });

  /** The window's marks: the light's own span on the scrubber, the times at its ends, the margin and its buttons. */
  function drawWindow() {
    const length = Math.max(1, range.to - range.from);
    span.style.left = percent((range.start - range.from) / length);
    span.style.width = percent((range.end - range.start) / length);
    fromLabel.textContent = clockText(range.from, zone);
    lightLabel.textContent = `${T.light} ${clockText(range.start, zone)}`;
    toLabel.textContent = clockText(range.to, zone);
    marginLabel.textContent = marginText(margin);
    track.setAttribute('aria-valuemin', String(Math.round(range.from)));
    track.setAttribute('aria-valuemax', String(Math.round(range.to)));
    narrowButton.hidden = margin === WINDOW.marginMs;
    widenButtons.forEach((button) => { button.disabled = margin >= WINDOW.maxMarginMs; });
    drawnAt = null;
  }

  /** The playhead, the bubble and the light at the playhead; the slider's value at most every 250 ms. */
  function drawPosition() {
    const ms = playheadAt();
    const length = Math.max(1, range.to - range.from);
    const showsBubble = (scrubbing || hoverX !== null) && trackWidth > 0;
    if (ms !== drawnAt) {
      drawnAt = ms;
      playhead.style.left = percent((ms - range.from) / length);
      drawNow(ms);
    }
    if (showsBubble) {
      const at = scrubbing ? ms : range.from + (Math.min(Math.max(hoverX, 0), trackWidth) / trackWidth) * length;
      bubble.hidden = false;
      bubble.textContent = clockText(at, zone);
      bubble.style.left = percent((at - range.from) / length);
    } else if (!bubble.hidden) bubble.hidden = true;
    const now = timers.now();
    if (now - lastAriaAt >= ARIA_EVERY_MS) {
      lastAriaAt = now;
      track.setAttribute('aria-valuenow', String(Math.round(Math.min(Math.max(ms, range.from), range.to))));
      track.setAttribute('aria-valuetext', clockText(ms, zone));
    }
  }

  // MARK: Head and foot

  const titleId = `sky-player-${++sequence}`;
  const xButton = h('button', { class: 'btn small ghost sky-player-x', type: 'button', 'aria-label': T.close, title: `${T.close} (Esc)`, onclick: () => close() }, icon('x'));
  const head = h('header', { class: 'sky-player-head' },
    h('div', { class: 'sky-player-title', id: titleId }, h('h2', null, heading), what ? h('p', { class: 'sky-player-what' }, what) : null), xButton);
  const watchLink = watchHref ? h('a', { class: 'btn small', href: watchHref, onclick: () => close() }, icon('film'), T.watch) : null;
  const foot = h('div', { class: 'sky-player-foot' }, watchLink, h('button', { class: 'btn small sky-player-done', type: 'button', onclick: () => close() }, T.close));
  const controls = h('div', { class: 'sky-player-controls' }, transportRow, scrub, widenRow);
  const panel = h('div', { class: 'sky-player-panel', tabindex: '-1' }, head, notice, stageEl, controls, foot);
  const dialog = h('dialog', { class: 'sky-player', 'aria-labelledby': titleId }, panel);

  // MARK: What the person does

  /** Play or Pause; nothing asked yet: from the window's start; paused at its end: from its start again. */
  function togglePlay() {
    if (closed || blocked) return;
    const view = controller.view();
    if (view.transport.mode === 'snapshots') { startedOnce = true; controller.playAt(range.from); return; }
    if (session.mode === 'paused' && session.position >= end() - END_SLACK_MS) { session.play(range.from); queueRender(); return; }
    controller.togglePlay();
  }

  /** One picture back or forward (paused: a step never plays), never out of the window. */
  function step(direction) {
    if (closed || blocked) return;
    const action = windowedAction({ action: 'nudge', direction, deltaMs: direction * 1000 }, { mode: 'paused', positionMs: session.position, from: range.from, to: end() });
    if (action?.kind === 'step') controller.stepFrame(action.direction);
  }

  function perform(action) {
    if (action.kind === 'toggle') togglePlay();
    else if (action.kind === 'step') step(action.direction);
    else if (action.kind === 'seek') controller.seek(action.deltaMs);
    else if (action.kind === 'speed') controller.stepSpeed(action.step);
  }

  function setZoom(on) {
    zoomed = on && Boolean(zoomAt(entry.path, entry.start, playheadAt(), picture));
    stageEl.dataset.zoom = String(zoomed);
    zoomButton.setAttribute('aria-pressed', String(zoomed));
    drawnAt = null;
    drawPath();
    drawNow(playheadAt());
  }

  /** A wider (or the first) window: the playhead stays where it is; one that is now outside it is brought in, playing or not as it was. */
  function setMargin(next) {
    if (closed) return;
    margin = next;
    range = clipWindow(entry, margin);
    drawWindow();
    const at = session.position;
    if (startedOnce && (at < range.from || at > end())) session.showAt(Math.min(Math.max(at, range.from), end()));
    render();
  }

  // The Monitor's keys, bounded by the window (sky-player-model.js windowedAction), and Escape closes. Not while typing in a field.
  function onKey(event) {
    if (closed) return;
    if (event.key === 'Escape') { event.preventDefault?.(); event.stopImmediatePropagation?.(); close(); return; }
    const target = event.target;
    const closest = (selector) => (typeof target?.closest === 'function' ? target.closest(selector) : null);
    const typing = Boolean(closest('input, select, textarea, [contenteditable=""], [contenteditable="true"]'));
    const activatable = Boolean(closest('button, a[href], summary, [role="button"], [role="switch"], [role="tab"], [role="menuitem"]'));
    const action = windowedAction(keyAction(event, { typing, activatable }), { mode: session.mode, positionMs: session.position, from: range.from, to: end() });
    if (!action || blocked || !controller.canAct()) return;
    event.preventDefault?.();
    event.stopImmediatePropagation?.();
    perform(action);
  }

  const onVisibility = () => { if (document.hidden) controller.suspend(); else controller.resume(); };

  // MARK: Drawing what the controller says

  function readoutText(t) {
    const ms = t.positionMs ?? range.from;
    return `${clockText(ms, zone, { tenths: t.mode === 'paused' })}${t.mode === 'playing' && t.rate !== 1 ? `  ${speedLabel(t.rate)}` : ''}`;
  }

  /** Puts `content` in `el` (and shows it) unless it already holds what `key` names. */
  function fill(el, key, content) {
    if (el.dataset.key === key) return;
    el.dataset.key = key;
    el.hidden = !content;
    replace(el, content);
  }

  function drawNote(next, look) {
    notice.dataset.kind = next?.kind ?? '';
    fill(notice, next ? `${next.kind}|${next.body}` : '', next ? [
      h('strong', null, next.title), h('p', { class: 'small' }, next.body),
      next.retry ? h('div', { class: 'actions' }, h('button', { class: 'btn small', type: 'button', onclick: () => controller.retryCatalog() }, T.retry)) : null,
    ] : null);
    const shows = !next && look?.note && (look.state === 'unreadable' || (look.state === 'gap' && presented));
    fill(note, shows ? `${look.state}|${look.note.title}|${look.note.detail ?? ''}` : '', shows ? [
      h('strong', null, look.note.title), look.note.detail ? h('p', { class: 'small' }, look.note.detail) : null,
      look.note.action ? h('div', { class: 'actions' }, h('button', { class: 'btn small', type: 'button', onclick: () => controller.retryTile() }, look.note.action.label)) : null,
    ] : null);
  }

  function render() {
    renderQueued = false;
    if (closed) return;
    guard();
    const view = controller.view();
    const t = view.transport;
    const cover = coverage();
    if (SHOWN.has(cover.kind)) presented = true;
    blocked = playerNotice({
      playable, phase: view.phase, catalogPhase: catalog.phase, extent: catalog.extent(id), from: range.from, to: end(), coverage: cover, presented,
      pause: current.status?.nvr?.pause ?? null, hasStill: stillOK,
    });
    // The first play, once the recordings are known and there is something to play.
    if (!startedOnce && !blocked && view.phase === 'ready' && controller.canAct()) {
      startedOnce = true;
      controller.playAt(range.from);
    }
    // A start that met a hole before any picture (before the first recording, or between two) plays from the next recording in the window,
    // unless the person paused.
    if (startedOnce && !blocked && !presented && session.mode === 'paused' && !session.holding && cover.kind === 'gap'
      && Number.isFinite(cover.next) && cover.next > session.position && cover.next < end()) {
      controller.playAt(cover.next);
    }
    const shown = blocked ? { ...t, playing: false, canPlay: false, canStep: false, canSpeed: false } : t;
    transport.render(shown, { atLive: false, text: readoutText(t) });
    stageEl.dataset.layer = presented && !blocked ? 'video' : 'still';
    drawNote(blocked, view.tiles[0]?.look ?? null);
    busy.hidden = Boolean(blocked) || !(cover.kind === 'loading' || (!presented && view.phase !== 'unreachable'));
    track.setAttribute('aria-disabled', String(Boolean(blocked)));
    zoomButton.disabled = !zoomAt(entry.path, entry.start, entry.start, picture);
    drawPosition();
  }

  function queueRender() {
    if (renderQueued || closed) return;
    renderQueued = true;
    queueMicrotask(render);
  }

  /** The window's end pauses there (and live, which a clip has no use for, comes back to it). Each frame, and with each of the controller's
   *  ticks (a frame may not come while the page is in the background). */
  function guard() {
    const mode = session.mode;
    const stop = end();
    if (!startedOnce || !(mode === 'live' || (mode === 'playing' && session.position >= stop))) return;
    session.pause();
    session.showAt(stop);
    queueRender();
  }

  /** Each frame: the end of the window, then the playhead and the light move. */
  function frame() {
    frameId = null;
    if (closed) return;
    guard();
    drawPosition();
    frameId = frameFn(frame);
  }

  // MARK: Opening and closing

  function close() {
    if (closed) return;
    closed = true;
    if (frameId !== null) cancelFrameFn(frameId);
    frameId = null;
    document.removeEventListener('keydown', onKey, true);
    document.removeEventListener('visibilitychange', onVisibility);
    stopCamera?.();
    stopSession?.();
    stopRendering?.();
    scrubber.cancel();
    controller.destroy();
    session.destroy();            // the cell and its player: the MediaSource is let go, the video emptied
    catalog.stop();
    fetcher.destroy();            // nothing in flight any more, nothing more to come
    dispatcher.destroy();
    video.pause?.();
    video.removeAttribute('src');
    video.load?.();
    try { if (dialog.open) dialog.close(); } catch { /* already closed */ }
    dialog.remove();
    try { onClose(); } catch (error) { console.error(error); }
  }

  dialog.addEventListener('cancel', (event) => { event.preventDefault?.(); close(); });
  dialog.addEventListener('close', () => close());
  dialog.addEventListener('pointerdown', (event) => { downOutside = event.target === dialog; });
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog && downOutside) close();
    downOutside = false;
  });

  stopRendering = controller.subscribe(render);
  stopSession = session.onChange(queueRender);
  const subscribeCamera = parts.subscribeCamera ?? ((fn) => subscribe((kind, detail) => { if (kind === 'camera' && detail?.id === id) fn(detail); }));
  stopCamera = subscribeCamera((next) => {
    if (closed || !next) return;
    current = next;
    for (const fn of [...cameraListeners]) fn();
    queueRender();
  });
  document.addEventListener('keydown', onKey, true);
  document.addEventListener('visibilitychange', onVisibility);

  setPicture(picture.width, picture.height);
  drawWindow();
  document.body.append(dialog);
  try { dialog.showModal(); } catch { dialog.setAttribute('open', ''); }
  panel.focus?.({ preventScroll: true });     // the keys work at once, and Space is Play rather than the first button's click
  render();
  catalog.start();
  controller.start().catch((error) => console.error(error));
  frameId = frameFn(frame);

  return {
    el: dialog,
    close,
    /** The window it plays now: { from, to } in epoch ms. */
    get window() { return { from: range.from, to: range.to }; },
  };
}
