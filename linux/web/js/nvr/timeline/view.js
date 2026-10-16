// The timeline control: zoom buttons, the track (one canvas, a playhead and a time bubble), and the pointer, wheel and keyboard handling.
// Built with the DOM API only. The track is repainted only when the window, the data, the size or the theme changes; the playhead and the
// bubble move with `style.transform` from one animation-frame loop, which is also where the newest scrub position is handed to the session.
import { h, replace } from '../../dom.js';
import { makeTimeFormatter, valueText } from '../../screens/watch-state.js';
import { paintTimeline } from './draw.js';
import { createTimelineModel, release } from './model.js';
import { createScrubController } from './scrub.js';
import { makeTicks } from './ticks.js';
import { PRESETS, PRESET_LABELS, classifyWheel, timeForX, wheelPanMs, wheelZoomFactor, xForTime } from './viewport.js';

export const STYLESHEET = '/nvr-watch.css';
export const EMPTY_TEXT = 'Nothing recorded yet. Turn on Record to build a timeline.';

/** Adds the NVR watch stylesheet unless the page already has it (index.html links it; this covers a page that does not yet). */
export function ensureStylesheet(href = STYLESHEET) {
  if (document.querySelector(`link[rel="stylesheet"][href="${href}"]`)) return;
  document.head.append(h('link', { rel: 'stylesheet', href }));
}

/**
 * createTimeline({ host, session, catalog, timeZone, isHealthy, onRelease })
 *   -> { el, model, setCameras(ids), setPreset(preset), zoomBy(factor), perform(action), announce(text), setEmptyText(text), destroy() }
 * `session` is the T08 session (mode, position, beginScrub, scrub, endScrub, seek, togglePlay, goLive, onChange), `catalog` the T08 catalog.
 * `onRelease({ ms, edge })` is called when a drag ends; `edge` is 'oldest' or 'now' when the pointer was beyond the recordings.
 */
export function createTimeline({ host = null, session, catalog, timeZone, isHealthy = () => true, onRelease = null }) {
  ensureStylesheet();
  const zone = timeZone || Intl.DateTimeFormat().resolvedOptions().timeZone;
  const format = makeTimeFormatter({ timeZone: zone });
  const model = createTimelineModel({ session, catalog });

  let width = 0;
  let height = 0;
  let dpr = 1;
  let colors = null;
  let dirty = true;
  let rafId = 0;
  let flushPending = null;            // the scrub controller's "next frame" callback, run first thing in the loop
  let hoverX = null;
  let lastBubble = { x: NaN, ms: NaN };
  let lastPlayheadX = NaN;
  let lastSecondAt = -Infinity;
  let ariaDirty = true;
  let lastAriaAt = -Infinity;
  let ticksKey = '';
  let ticks = [];
  let scrubbing = false;
  let destroyed = false;
  let extentKey = '';

  // MARK: Elements

  const canvas = h('canvas', { class: 'nvr-canvas' });
  const playhead = h('div', { class: 'nvr-playhead', 'aria-hidden': 'true' });
  const bubble = h('div', { class: 'nvr-bubble', 'aria-hidden': 'true', hidden: true });
  const track = h('div', {
    class: 'nvr-track', role: 'slider', tabindex: 0, 'aria-label': 'Recording position', 'aria-orientation': 'horizontal', dataset: { nvr: 'track' },
  }, canvas, playhead, bubble);
  const empty = h('p', { class: 'nvr-empty small muted', hidden: true }, EMPTY_TEXT);
  const problem = h('p', { class: 'nvr-problem small', role: 'status', hidden: true }, 'The activity graph can’t load right now. Trying again.');
  const announcer = h('div', { class: 'sr-only', role: 'status', 'aria-live': 'polite' });
  const presetButtons = PRESETS.map((preset) => h('button', {
    class: 'btn small nvr-preset', type: 'button', 'aria-pressed': 'false', dataset: { preset }, onclick: () => model.select(preset),
  }, PRESET_LABELS[preset]));
  const toolbar = h('div', { class: 'nvr-toolbar', role: 'group', 'aria-label': 'Timeline zoom' },
    h('div', { class: 'nvr-presets' }, presetButtons),
    h('div', { class: 'nvr-zoom' },
      h('button', { class: 'btn small', type: 'button', 'aria-label': 'Zoom out', onclick: () => zoomBy(2) }, '−'),
      h('button', { class: 'btn small', type: 'button', 'aria-label': 'Zoom in', onclick: () => zoomBy(0.5) }, '+')));
  const el = h('div', { class: 'nvr-timeline', dataset: { nvr: 'timeline' } }, toolbar, track, empty, problem, announcer);
  if (host) host.append(el);

  // MARK: Actions

  function zoomBy(factor) {
    const v = model.viewport;
    const at = session.position;
    model.zoom(factor, at >= v.startMs && at <= v.startMs + v.durationMs ? at : v.startMs + v.durationMs / 2);
  }

  function goToOldest() {
    const oldest = model.oldestMs;
    if (oldest === null) return;
    session.beginScrub();
    session.scrub(oldest);
    session.endScrub();
  }

  const controller = createScrubController({
    session,
    timeForX: (x) => timeForX(model.viewport, x, width),
    clampMs: (ms) => Math.min(Math.max(ms, model.oldestMs ?? ms), model.nowMs),
    requestFrame: (fn) => { flushPending = fn; return 1; },
    cancelFrame: () => { flushPending = null; },
    isEnabled: () => !model.empty && width > 0,
    onStart: () => { scrubbing = true; track.classList.add('is-scrubbing'); },
    onEnd: (info) => { scrubbing = false; track.classList.remove('is-scrubbing'); ariaDirty = true; onRelease?.(info); },
  });

  // MARK: Painting

  function readColors() {
    const css = getComputedStyle(el);
    const v = (name, fallback) => css.getPropertyValue(name).trim() || fallback;
    colors = {
      track: v('--bg-raised', '#1c1c1f'), span: v('--surface-2', '#2c2c30'), tick: v('--border-strong', '#4a4a52'), label: v('--text-3', '#8a8a93'),
      bar: v('--text-2', '#b4b4bc'), hot: v('--brand-accent', '#e06a5a'), normal: v('--text-3', '#8a8a93'), gap: v('--border-strong', '#4a4a52'),
    };
  }

  function paint() {
    if (!width || !height) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    if (!colors) readColors();
    const v = model.viewport;
    const key = `${v.startMs}|${v.durationMs}|${width}`;
    if (key !== ticksKey) { ticksKey = key; ticks = makeTicks(v, width, { timeZone: zone }); }
    const data = model.data;
    const scale = model.scale();
    paintTimeline(ctx, {
      width, height, dpr, colors, viewport: v, ticks, oldestMs: model.oldestMs, newestMs: model.newestMs,
      plan: data ? data.plan : null, combined: data ? data.combined : null, reference: scale ? scale.reference : 0, typical: scale ? scale.typical : null,
      enabled: !model.empty,
    });
  }

  function resize() {
    const rect = track.getBoundingClientRect();
    dpr = window.devicePixelRatio || 1;
    width = Math.floor(rect.width);
    height = Math.floor(rect.height);
    canvas.width = Math.max(1, Math.round(width * dpr));
    canvas.height = Math.max(1, Math.round(height * dpr));
    model.setWidth(width);
    dirty = true;
  }

  function updateChrome() {
    const selected = model.preset;
    for (const button of presetButtons) button.setAttribute('aria-pressed', String(button.dataset.preset === selected));
    empty.hidden = !model.empty;
    problem.hidden = !model.problem;
    track.setAttribute('aria-disabled', String(model.empty));
  }

  function updateAria() {
    const now = model.nowMs;
    const oldest = model.oldestMs ?? now;
    const position = Math.min(Math.max(session.position, oldest), now);
    track.setAttribute('aria-valuemin', String(Math.round(oldest)));
    track.setAttribute('aria-valuemax', String(Math.round(now)));
    track.setAttribute('aria-valuenow', String(Math.round(position)));
    track.setAttribute('aria-valuetext', model.empty ? 'Nothing recorded yet' : valueText({ mode: session.mode, positionMs: session.position, serverNowMs: now, healthy: isHealthy(), format }));
  }

  // MARK: The loop

  function frame(timestamp) {
    if (destroyed) return;
    rafId = requestAnimationFrame(frame);
    if (flushPending) { const run = flushPending; flushPending = null; run(); }
    if (dirty) { dirty = false; updateChrome(); paint(); }

    const v = model.viewport;
    const x = xForTime(v, session.position, width);
    if (!(Math.abs(x - lastPlayheadX) < 0.1)) {
      lastPlayheadX = x;
      playhead.style.transform = `translateX(${x.toFixed(1)}px)`;
      playhead.hidden = x < -1 || x > width + 1;
    }

    const bubbleX = scrubbing ? x : hoverX;
    if (bubbleX === null || model.empty) {
      if (!bubble.hidden) bubble.hidden = true;
    } else {
      const ms = scrubbing ? session.position : timeForX(v, bubbleX, width);
      if (bubbleX !== lastBubble.x || ms !== lastBubble.ms) {
        lastBubble = { x: bubbleX, ms };
        bubble.hidden = false;
        bubble.textContent = format(ms);
        bubble.style.transform = `translateX(${Math.min(Math.max(bubbleX, 36), Math.max(36, width - 36)).toFixed(1)}px)`;
      }
    }

    if (ariaDirty && timestamp - lastAriaAt >= 250 && !scrubbing) { ariaDirty = false; lastAriaAt = timestamp; updateAria(); }
    if (timestamp - lastSecondAt >= 1000) {
      lastSecondAt = timestamp;
      model.tick();
      ariaDirty = true;
      const key = `${model.oldestMs}|${model.newestMs}|${model.empty}`;      // new footage lengthens the recorded span
      if (key !== extentKey) { extentKey = key; dirty = true; }
    }
  }

  // MARK: Events

  const localX = (event) => event.clientX - track.getBoundingClientRect().left;

  track.addEventListener('pointerdown', (event) => {
    if (!controller.down({ id: event.pointerId, pointerType: event.pointerType, x: localX(event), button: event.button })) return;
    try { track.setPointerCapture(event.pointerId); } catch { /* a synthetic pointer has nothing to capture */ }
    track.focus({ preventScroll: true });
    event.preventDefault();
  });
  track.addEventListener('pointermove', (event) => {
    hoverX = event.pointerType === 'mouse' || controller.scrubbing ? localX(event) : null;
    controller.move({ id: event.pointerId, x: localX(event) });
  });
  track.addEventListener('pointerup', (event) => {
    controller.up({ id: event.pointerId, x: localX(event) });
    try { track.releasePointerCapture(event.pointerId); } catch { /* already released */ }
    if (event.pointerType !== 'mouse') hoverX = null;
  });
  track.addEventListener('pointercancel', () => controller.cancel());
  track.addEventListener('lostpointercapture', () => controller.cancel());
  track.addEventListener('pointerleave', () => { if (!controller.scrubbing) hoverX = null; });
  track.addEventListener('wheel', (event) => {
    const kind = classifyWheel(event);
    if (kind === 'none' || model.empty) return;
    event.preventDefault();
    if (kind === 'zoom') model.zoom(wheelZoomFactor(event.deltaY, event.deltaMode), timeForX(model.viewport, localX(event), width));
    else model.pan(wheelPanMs(model.viewport, width, event));
  }, { passive: false });

  const unsubscribeModel = model.onChange(() => { dirty = true; });
  const unsubscribeSession = session.onChange(() => { ariaDirty = true; });
  const observer = new ResizeObserver(() => resize());
  observer.observe(track);
  const scheme = window.matchMedia('(prefers-color-scheme: dark)');
  const onScheme = () => { colors = null; dirty = true; };
  scheme.addEventListener('change', onScheme);
  document.addEventListener('cb-themechange', onScheme);   // js/theme.js: Light or Dark chosen on this browser
  const onVisible = () => { if (!document.hidden) { model.tick(); dirty = true; ariaDirty = true; } };
  document.addEventListener('visibilitychange', onVisible);

  rafId = requestAnimationFrame(frame);
  resize();

  return {
    el,
    model,
    setCameras(ids) { model.setCameras(ids); },
    setPreset(preset) { model.select(preset); },
    zoomBy,
    announce(text) { replace(announcer, text); },
    /** The sentence shown while nothing is recorded (the screen knows whether Record is on). */
    setEmptyText(text) { if (empty.textContent !== text) empty.textContent = text; },
    /** Runs one action of keys.js on the session and the timeline. */
    perform(action) {
      switch (action.type) {
        case 'togglePlay': session.togglePlay(); break;
        case 'seek': session.seek(action.deltaMs); break;
        case 'live': session.goLive(); break;
        case 'zoom': zoomBy(action.factor); break;
        case 'oldest': goToOldest(); break;
        default: break;
      }
    },
    destroy() {
      destroyed = true;
      cancelAnimationFrame(rafId);
      controller.cancel();
      observer.disconnect();
      scheme.removeEventListener('change', onScheme);
      document.removeEventListener('cb-themechange', onScheme);
      document.removeEventListener('visibilitychange', onVisible);
      release(unsubscribeModel);
      release(unsubscribeSession);
      model.dispose();
    },
  };
}
