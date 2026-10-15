// The visible window of the timeline: { startMs, durationMs } in epoch milliseconds (server time). Pure functions, no DOM.
// The window never starts before the oldest recording (or 24 h before now on a young archive) and never ends more than 4% of its
// own length after now, so the live edge always has a little room on the right.

export const PRESETS = ['10m', '1h', '6h', '24h', 'all'];
export const PRESET_LABELS = { '10m': '10 min', '1h': '1 h', '6h': '6 h', '24h': '24 h', all: 'All' };
export const MIN_WINDOW_MS = 60_000;
export const RIGHT_MARGIN = 0.04;

const TEN_MINUTES_MS = 600_000;
const DAY_MS = 86_400_000;
const PRESET_SPAN_MS = { '10m': TEN_MINUTES_MS, '1h': 3_600_000, '6h': 21_600_000, '24h': DAY_MS };

/** The earliest start the window may have: the oldest recording, but never later than 24 hours before now. */
export function floorMs({ oldestMs, nowMs }) {
  return Math.min(Number.isFinite(oldestMs) ? oldestMs : Infinity, nowMs - DAY_MS);
}

/** The longest window: from the floor to now plus the right margin. */
export function maxDurationMs(limits) {
  return (limits.nowMs - floorMs(limits)) / (1 - RIGHT_MARGIN);
}

/** Brings a window inside the limits: at least 60 s long, at most the whole archive, not before the floor, not past now + 4%. */
export function clampViewport(viewport, limits) {
  const durationMs = Math.min(Math.max(viewport.durationMs, MIN_WINDOW_MS), maxDurationMs(limits));
  const latestStartMs = limits.nowMs - durationMs * (1 - RIGHT_MARGIN);
  const startMs = Math.max(floorMs(limits), Math.min(viewport.startMs, latestStartMs));
  return { startMs, durationMs };
}

/**
 * The window a preset button shows. From live: [now - N, now + 4% of N]. From the past: N centred on the playhead.
 * 'all' is the oldest recording to now (at least ten minutes).
 */
export function presetViewport(preset, { nowMs, oldestMs = null, playheadMs = null, isLive = true }) {
  const limits = { oldestMs, nowMs };
  if (preset === 'all') {
    const startMs = Math.min(Number.isFinite(oldestMs) ? oldestMs : Infinity, nowMs - TEN_MINUTES_MS);
    return clampViewport({ startMs, durationMs: (nowMs - startMs) * (1 + RIGHT_MARGIN) }, limits);
  }
  const span = PRESET_SPAN_MS[preset];
  if (span === undefined) throw new RangeError(`Unknown timeline preset: ${preset}`);
  if (isLive || !Number.isFinite(playheadMs)) {
    return clampViewport({ startMs: nowMs - span, durationMs: span * (1 + RIGHT_MARGIN) }, limits);
  }
  return clampViewport({ startMs: playheadMs - span / 2, durationMs: span }, limits);
}

/** `factor` multiplies the visible duration (0.5 shows half as much time, 2 twice as much); the time under `anchorMs` stays under the pointer. */
export function zoomViewport(viewport, factor, anchorMs, limits) {
  const durationMs = Math.min(Math.max(viewport.durationMs * factor, MIN_WINDOW_MS), maxDurationMs(limits));
  const fraction = Math.min(1, Math.max(0, (anchorMs - viewport.startMs) / viewport.durationMs));
  return clampViewport({ startMs: anchorMs - fraction * durationMs, durationMs }, limits);
}

export function panViewport(viewport, deltaMs, limits) {
  return clampViewport({ startMs: viewport.startMs + deltaMs, durationMs: viewport.durationMs }, limits);
}

export function xForTime(viewport, ms, widthPx) {
  return ((ms - viewport.startMs) / viewport.durationMs) * widthPx;
}

export function timeForX(viewport, x, widthPx) {
  return viewport.startMs + (x / widthPx) * viewport.durationMs;
}

/** True when two windows are the same to the millisecond. */
export function sameViewport(a, b) {
  return !!a && !!b && a.startMs === b.startMs && a.durationMs === b.durationMs;
}

/** DOM wheel deltas come in pixels (0), lines (1) or pages (2). */
export function wheelPixels(delta, deltaMode = 0) {
  return deltaMode === 1 ? delta * 16 : deltaMode === 2 ? delta * 400 : delta;
}

/** Scrolling up (or a trackpad pinch out, which browsers send as ctrl + wheel) gives a factor below 1: zoom in. */
export function wheelZoomFactor(deltaY, deltaMode = 0) {
  const pixels = Math.max(-400, Math.min(400, wheelPixels(deltaY, deltaMode)));
  return Math.exp(pixels * 0.0015);
}

/** What a wheel event on the timeline means: 'zoom' (ctrl or cmd), 'pan' (shift, or a mostly horizontal wheel), or 'none' (the page scrolls). */
export function classifyWheel({ ctrlKey = false, metaKey = false, shiftKey = false, deltaX = 0, deltaY = 0 }) {
  if (ctrlKey || metaKey) return 'zoom';
  if (shiftKey || Math.abs(deltaX) > Math.abs(deltaY)) return 'pan';
  return 'none';
}

/** The pan a 'pan' wheel event asks for, in milliseconds (positive is later). */
export function wheelPanMs(viewport, widthPx, { deltaX = 0, deltaY = 0, deltaMode = 0, shiftKey = false }) {
  const delta = shiftKey && deltaX === 0 ? deltaY : deltaX;
  return (wheelPixels(delta, deltaMode) / widthPx) * viewport.durationMs;
}
