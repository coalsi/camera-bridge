// The activity waveform: which bins to ask the bridge for, how cameras combine, and how tall a bar is. Pure functions, no DOM.
// The waveform is non-keyframe bytes per second, so it follows activity only on variable-bit-rate or smart-codec streams.

export const BIN_LADDER_SEC = [2, 5, 10, 30, 60, 120, 300, 600, 1200, 1800, 3600];
export const MIN_COLUMN_PX = 2;
export const MAX_REQUEST_BINS = 2000;                       // GET nvr/activity: bins 1...2000
export const MAX_REQUEST_SPAN_MS = 31 * 86_400_000;         // and bins x binMs at most 31 days
export const ELEVATED_FACTOR = 1.5;                         // bars above 1.5 x typical are amber
export const REFERENCE_FACTOR = 4;                          // the bar scale tops out at 4 x typical
export const LEVEL_FLOOR = 1000;                            // bytes per second: the smallest scale when no typical level exists yet
const MAX_PLAN_WIDTH_PX = 2600;                             // with a quarter-window margin on each side, 2600 px stays under 2000 bins

/** The smallest rung of the ladder that keeps columns at least 2 px wide, in milliseconds. */
export function chooseBin(durationMs, widthPx) {
  const wanted = durationMs / (Math.max(1, widthPx) / MIN_COLUMN_PX);
  for (const seconds of BIN_LADDER_SEC) if (seconds * 1000 >= wanted) return seconds * 1000;
  return BIN_LADDER_SEC[BIN_LADDER_SEC.length - 1] * 1000;
}

/** `from` is always a multiple of the bin, so panning moves whole columns and never reshuffles them. */
export function alignFrom(startMs, binMs) {
  return Math.floor(startMs / binMs) * binMs;
}

/**
 * The request for a viewport: the visible range plus a quarter of the window on each side (so a small pan needs no new request), never beyond
 * the end of now, and never more than the server accepts. When the range is too wide the newest part wins.
 */
export function planActivityRequest(viewport, widthPx, nowMs) {
  const binMs = chooseBin(viewport.durationMs, Math.min(widthPx, MAX_PLAN_WIDTH_PX));
  const limitMs = Math.min(MAX_REQUEST_BINS * binMs, MAX_REQUEST_SPAN_MS);
  const viewEndMs = viewport.startMs + viewport.durationMs;
  const nowEndMs = Math.ceil((nowMs + binMs) / binMs) * binMs;
  let fromMs = alignFrom(viewport.startMs - viewport.durationMs / 4, binMs);
  let toMs = Math.ceil(Math.min(viewEndMs + viewport.durationMs / 4, nowEndMs) / binMs) * binMs;
  if (toMs - fromMs > limitMs) {
    fromMs = alignFrom(viewport.startMs, binMs);
    toMs = Math.ceil(Math.min(viewEndMs, nowEndMs) / binMs) * binMs;
  }
  if (toMs - fromMs > limitMs) fromMs = toMs - limitMs;
  if (toMs <= fromMs) toMs = fromMs + binMs;
  return { fromMs, binMs, bins: Math.round((toMs - fromMs) / binMs) };
}

/** True when an answer already holds every bin the viewport can show (nothing is recorded after now). */
export function planCovers(plan, viewport, nowMs) {
  if (!plan) return false;
  const wantedEnd = Math.min(viewport.startMs + viewport.durationMs, nowMs);
  return plan.fromMs <= viewport.startMs && plan.fromMs + plan.bins * plan.binMs >= wantedEnd;
}

function p99(values) {
  const sorted = values.filter((v) => Number.isFinite(v) && v >= 0).sort((a, b) => a - b);
  return sorted.length ? sorted[Math.min(sorted.length - 1, Math.ceil(0.99 * sorted.length) - 1)] : 0;
}

/**
 * Cameras on one waveform. `byCamera` is the `byCamera` object of GET nvr/activity. Coverage is the best of the cameras per bin.
 * One camera: its own bytes per second and its own typical level. Several cameras: each bin is the busiest camera relative to
 * its own typical level (so `typical` is 1); a camera without a typical level yet is measured against its own 99th percentile.
 */
export function combineActivity(byCamera, bins) {
  const cameras = Object.values(byCamera || {}).filter((c) => c && Array.isArray(c.level) && Array.isArray(c.coverage));
  const level = new Array(bins).fill(0);
  const coverage = new Array(bins).fill(0);
  if (cameras.length === 0) return { level, coverage, typical: null };
  const single = cameras.length === 1;
  const scales = cameras.map((c) => {
    if (single) return 1;
    if (Number.isFinite(c.typical) && c.typical > 0) return c.typical;
    return Math.max(p99(c.level), LEVEL_FLOOR);
  });
  cameras.forEach((c, k) => {
    for (let i = 0; i < bins; i += 1) {
      const cover = c.coverage[i] || 0;
      if (cover > coverage[i]) coverage[i] = cover;
      if (cover > 0) level[i] = Math.max(level[i], (c.level[i] || 0) / scales[k]);
    }
  });
  const allHaveTypical = cameras.every((c) => Number.isFinite(c.typical) && c.typical > 0);
  const typical = single ? (Number.isFinite(cameras[0].typical) && cameras[0].typical > 0 ? cameras[0].typical : null) : allHaveTypical ? 1 : null;
  return { level, coverage, typical };
}

/** Levels of the bins that have footage and touch the viewport: what the p99 scale is measured over. */
export function visibleLevels(combined, plan, viewport) {
  const out = [];
  for (let i = 0; i < combined.level.length; i += 1) {
    const binStart = plan.fromMs + i * plan.binMs;
    if (binStart + plan.binMs <= viewport.startMs || binStart >= viewport.startMs + viewport.durationMs) continue;
    if (combined.coverage[i] > 0) out.push(combined.level[i]);
  }
  return out;
}

/** The level that fills the bar area: 4 x typical, or the 99th percentile of what is visible (never under 1 KB/s). */
export function waveformReference(typical, levels) {
  if (Number.isFinite(typical) && typical > 0) return REFERENCE_FACTOR * typical;
  return Math.max(p99(levels), LEVEL_FLOOR);
}

/** Bar half-height as a fraction of the half-height of the area: the square root keeps small movement visible. */
export function barHeight(level, reference) {
  if (!(reference > 0) || !(level > 0)) return 0;
  return Math.sqrt(Math.min(level / reference, 1));
}

/** Amber bars: above 1.5 x typical (always taller than the dashed normal line, so colour is never the only signal). */
export function isElevated(level, typical) {
  return Number.isFinite(typical) && typical > 0 && level > ELEVATED_FACTOR * typical;
}
