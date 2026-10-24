// The range a saved clip covers, as the timeline shows it (a red band with a handle at each end) and the clip bar sets it (10 s to 15 min). No
// DOM, so Node tests run it as is. Times are epoch ms; `footage` is { oldestMs, newestMs } of the cameras on offer (null: not known yet).

/** The lengths the clip bar offers. */
export const CLIP_LENGTHS = Object.freeze([10_000, 30_000, 60_000, 300_000, 900_000]);
export const DEFAULT_LENGTH_MS = 30_000;
/** The shortest clip (the bridge's clips are at least a second). */
export const MIN_CLIP_MS = 1000;
/** The longest clip of one camera (the bridge's ClipLimits.standard: 7 200 s). */
export const MAX_CLIP_MS = 7_200_000;

/** "10 s", "30 s", "1 min", "15 min", "1 h 5 min": a length as the clip bar names it. */
export function lengthLabel(ms) {
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds} s`;
  const minutes = Math.floor(seconds / 60), rest = seconds % 60;
  if (minutes < 60) return rest ? `${minutes} min ${rest} s` : `${minutes} min`;
  const hours = Math.floor(minutes / 60), mins = minutes % 60;
  return mins ? `${hours} h ${mins} min` : `${hours} h`;
}

function clamp(ms, footage) {
  if (!footage) return ms;
  return Math.min(Math.max(ms, footage.oldestMs), footage.newestMs);
}

/**
 * The range of `lengthMs` at `anchorMs` (the playhead when Save clip was pressed): it ends at the anchor and covers the length before it;
 * where there is not that much footage before the anchor it starts at the anchor instead. Either way it stays inside the footage.
 */
export function defaultRange({ anchorMs, lengthMs = DEFAULT_LENGTH_MS, footage = null }) {
  const anchor = clamp(anchorMs, footage);
  let from = anchor - lengthMs;
  let to = anchor;
  if (footage && from < footage.oldestMs) {
    from = anchor;
    to = anchor + lengthMs;
  }
  from = clamp(from, footage);
  to = clamp(to, footage);
  if (footage && to - from < lengthMs) {
    // Less footage after the anchor than the length too: take what there is on both sides.
    from = clamp(to - lengthMs, footage);
    to = clamp(from + lengthMs, footage);
  }
  return { fromMs: from, toMs: to };
}

/**
 * The range with its `edge` ('from' or 'to') dragged to `ms`: inside the footage, never past the other edge, at least MIN_CLIP_MS long. A
 * range longer than MAX_CLIP_MS is allowed (the bar says it is too long), so a drag never jumps.
 */
export function moveEdge(range, edge, ms, footage = null) {
  const at = clamp(ms, footage);
  if (edge === 'from') return { fromMs: Math.min(at, range.toMs - MIN_CLIP_MS), toMs: range.toMs };
  return { fromMs: range.fromMs, toMs: Math.max(at, range.fromMs + MIN_CLIP_MS) };
}

/** What the clip bar says about the range: its length and whether the bridge can save it. */
export function rangeCheck(range) {
  const lengthMs = range.toMs - range.fromMs;
  return { lengthMs, tooShort: lengthMs < MIN_CLIP_MS, tooLong: lengthMs > MAX_CLIP_MS };
}

/** The keyboard on a handle: ← → one second, Shift ten, Page Up and Page Down a minute; null for another key. */
export function edgeKeyDelta(event) {
  const sign = { ArrowLeft: -1, ArrowDown: -1, PageDown: -1, ArrowRight: 1, ArrowUp: 1, PageUp: 1 }[event.key];
  if (!sign) return null;
  if (event.key.startsWith('Page')) return sign * 60_000;
  return sign * (event.shiftKey ? 10_000 : 1000);
}

/** The footage of several cameras: the oldest and newest recorded moments of any of them (catalog extents), or null when none has any. */
export function footageOf(extents) {
  const known = extents.filter((extent) => extent && Number.isFinite(extent.oldest) && Number.isFinite(extent.newest));
  if (!known.length) return null;
  return { oldestMs: Math.min(...known.map((e) => e.oldest)), newestMs: Math.max(...known.map((e) => e.newest)) };
}
