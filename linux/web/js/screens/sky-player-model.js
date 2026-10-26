// The rules of Sky Watcher's clip player (sky-player.js), with no page in them: the stretch of recording it plays around a light and how it
// widens, the time of day it reads, where the light was at a moment (the overlay's point and the Zoom's origin), the Monitor's keys bounded by
// that stretch, and what it says when there is nothing to play. Nothing here touches the document or sends a request.
import { KEY_MAP } from './nvr-model.js';
import { SKY_TEXT, closeUpRect } from './sky-model.js';

const TEXT = SKY_TEXT.player;
const finite = (value) => (typeof value === 'number' && Number.isFinite(value) ? value : null);
const round = (value, places) => Math.round(value * 10 ** places) / 10 ** places;

// MARK: The window

/** From 15 s before the light to 15 s after it; the buttons widen both sides by a minute or five, up to half an hour. */
export const WINDOW = Object.freeze({ marginMs: 15_000, widenMs: Object.freeze([60_000, 300_000]), maxMarginMs: 30 * 60_000 });

/** The stretch of recording the player plays for `entry`: { from, to, start, end, marginMs } in epoch ms (the box's clock). */
export function clipWindow(entry, marginMs = WINDOW.marginMs) {
  const start = entry.start;
  const end = Math.max(start, entry.end ?? start);
  return { from: start - marginMs, to: end + marginMs, start, end, marginMs };
}

/** The margin after one more press of a widening button: `stepMs` more on each side, at most WINDOW.maxMarginMs. */
export function widenMargin(marginMs, stepMs) {
  return Math.min(WINDOW.maxMarginMs, marginMs + stepMs);
}

/** "15 s before and after", "1 min 15 s before and after", "5 min before and after". */
export function marginText(marginMs) {
  const seconds = Math.round(marginMs / 1000);
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  const parts = [minutes ? `${minutes} min` : '', rest || !minutes ? `${rest} s` : ''].filter(Boolean);
  return `${parts.join(' ')} before and after`;
}

const clocks = new Map();

/** "3:12:08 AM", or "3:12:08.4 AM" with `tenths` (the paused readout, as the Monitor's): the box's time of day in `zone`. */
export function clockText(ms, zone, { tenths = false } = {}) {
  if (!Number.isFinite(ms)) return '';
  const key = zone || '';
  if (!clocks.has(key)) {
    const make = (timeZone) => new Intl.DateTimeFormat('en-US', { timeZone, hour: 'numeric', minute: '2-digit', second: '2-digit', hourCycle: 'h12' });
    let format;
    try { format = make(zone || undefined); } catch { format = make(undefined); }
    clocks.set(key, format);
  }
  const p = {};
  for (const part of clocks.get(key).formatToParts(ms)) p[part.type] = part.value;
  const tenth = tenths ? `.${Math.floor((((ms % 1000) + 1000) % 1000) / 100)}` : '';
  return `${p.hour}:${p.minute}:${p.second}${tenth} ${p.dayPeriod}`;
}

// MARK: Where the light was

/** The path's points as { t, x, y } in time order (objects or [t, x, y] triples; what is not numbers is left out). */
function pointsOf(path) {
  const points = [];
  for (const point of Array.isArray(path) ? path : []) {
    const [t, x, y] = Array.isArray(point) ? point : [point?.t, point?.x, point?.y];
    if (finite(t) !== null && finite(x) !== null && finite(y) !== null) points.push({ t, x, y });
  }
  return points.sort((a, b) => a.t - b.t);
}

/**
 * Where the light was at `ms`: the path's point for that time, between two points by how far the time lies between them (the path carries `t`
 * in seconds from the entry's start, and x and y as 0…1 of the original picture). Before the first point it is the first ("before"), after the
 * last the last ("after"); `endMs`, the entry's end, says how long a path of one point lasts. -> { x, y, at }, or null for a path with no point.
 */
export function pathPointAt(path, startMs, ms, endMs = null) {
  const points = pointsOf(path);
  if (!points.length || !Number.isFinite(startMs) || !Number.isFinite(ms)) return null;
  const t = (ms - startMs) / 1000;
  const first = points[0];
  const last = points.at(-1);
  const lastT = Math.max(last.t, Number.isFinite(endMs) ? (endMs - startMs) / 1000 : last.t);
  const at = t < first.t ? 'before' : t > lastT ? 'after' : 'during';
  let x = first.x;
  let y = first.y;
  if (t >= last.t) {
    ({ x, y } = last);
  } else if (t > first.t) {
    const next = points.findIndex((point) => point.t > t);
    const a = points[next - 1];
    const b = points[next];
    const f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0;
    x = a.x + (b.x - a.x) * f;
    y = a.y + (b.y - a.y) * f;
  }
  return { x: round(x, 6), y: round(y, 6), at };
}

/** The close-up a still of the picture's shape would show (1920 wide, as the box keeps them), so the Zoom magnifies as much as the close-up does. */
const STILL_WIDTH = 1920;

/**
 * The Zoom: how much it magnifies (as much as the light's close-up does, two to six times) and its origin, the light at `ms`, in per cent of
 * the picture (the CSS transform's origin, so the light stays where it is and the sky around it grows). -> { scale, x, y }, or null with no path.
 */
export function zoomAt(path, startMs, ms, { width = 1920, height = 1080 } = {}) {
  const point = pathPointAt(path, startMs, ms);
  if (!point) return null;
  const tall = width > 0 && height > 0 ? (STILL_WIDTH * height) / width : STILL_WIDTH * (9 / 16);
  const rect = closeUpRect(path, STILL_WIDTH, tall);
  const scale = rect ? Math.min(6, Math.max(2, STILL_WIDTH / rect.width)) : 2;
  return { scale: round(scale, 2), x: round(point.x * 100, 2), y: round(point.y * 100, 2) };
}

// MARK: The keys

/** The keyboard help: the Monitor's own lines (nvr-model.js KEY_MAP) for the keys a clip uses, and Esc. */
export const SKY_KEY_MAP = Object.freeze([
  ...KEY_MAP.filter(([keys]) => keys === 'Space' || keys === '← →' || keys === 'Shift + ← →'),
  ['Alt + ← →', '10 seconds back or forward'],
  ...KEY_MAP.filter(([keys]) => keys === ', .'),
  ['Esc', TEXT.close],
]);

/**
 * A key of the Monitor's (nvr-model.js keyAction: Space, ← →, Shift or Alt with them, `,` and `.`) in the clip player, bounded by its window:
 * ← → step a picture while paused and move a second while playing, never past either end; a jump stops at the end it would pass; live is not one
 * of a clip's places. -> { kind: 'toggle' } | { kind: 'step', direction } | { kind: 'seek', deltaMs } | { kind: 'speed', step } | null
 *   state  { mode: 'paused' | 'playing' | …, positionMs, from, to }
 */
export function windowedAction(action, { mode, positionMs, from, to }) {
  if (!action) return null;
  const seek = (deltaMs) => {
    const target = Math.min(Math.max(positionMs + deltaMs, from), to);
    const delta = Math.round(target - positionMs);
    return delta === 0 ? null : { kind: 'seek', deltaMs: delta };
  };
  switch (action.action) {
    case 'togglePlay': return { kind: 'toggle' };
    case 'speed': return { kind: 'speed', step: action.step };
    case 'seek': return seek(action.deltaMs);
    case 'nudge':
      if (mode !== 'paused') return seek(action.deltaMs);
      if ((action.direction < 0 && positionMs <= from) || (action.direction > 0 && positionMs >= to)) return null;
      return { kind: 'step', direction: action.direction < 0 ? -1 : 1 };
    default: return null;
  }
}

// MARK: What it says instead of playing

const notice = (kind, title, body, hasStill, retry = false) => ({ kind, title, body: hasStill ? `${body} ${TEXT.still}` : body, retry });

/**
 * What the player says instead of the recording, or null while there is one to play. In order: the browser cannot play recordings; they cannot
 * be reached (the bridge does not answer, or has no place for them); they are loading (the bridge just started); the recordings drive is away;
 * there is none of this moment (removed to make room, never made, or a hole as long as the rest of the window before any picture was shown). With
 * a still, it offers it.
 *   playable      the browser has Media Source Extensions
 *   phase         the grid controller's: 'connecting' | 'ready' | 'unreachable'
 *   catalogPhase  the catalog's: 'starting' | 'ready' | 'loading' | 'unavailable'
 *   extent        the camera's recordings, { oldest, newest } or null; from, to: the window
 *   coverage      the cell's { kind, next, message }; presented: a recorded picture of this window has been shown
 *   pause         the camera's status.nvr.pause ('folderMissing': the drive is away); hasStill: the entry has a still
 * -> { kind: 'unplayable' | 'unreachable' | 'loading' | 'drive' | 'missing', title, body, retry }
 */
export function playerNotice({ playable = true, phase = 'connecting', catalogPhase = 'starting', extent = null, from, to, coverage = null, presented = false, pause = null, hasStill = false }) {
  if (!playable) return notice('unplayable', TEXT.unplayableTitle, TEXT.unplayableBody, hasStill);
  if (coverage?.kind === 'unsupported') return notice('unplayable', TEXT.unplayableTitle, coverage.message || TEXT.unplayableBody, hasStill);
  if (phase === 'unreachable' || catalogPhase === 'unavailable') return notice('unreachable', TEXT.unreachableTitle, TEXT.unreachableBody, hasStill, true);
  if (catalogPhase === 'loading' && !presented) return notice('loading', TEXT.loadingTitle, TEXT.loadingBody, hasStill);
  if (pause === 'folderMissing' || coverage?.kind === 'driveMissing') return notice('drive', TEXT.driveTitle, TEXT.driveBody, hasStill);
  if (phase !== 'ready' || presented) return null;
  const missing = notice('missing', TEXT.missingTitle, TEXT.missingBody, hasStill);
  if (!extent || !(extent.newest > from) || !(extent.oldest < to)) return missing;
  if (coverage?.kind === 'gap' && !(Number.isFinite(coverage.next) && coverage.next < to)) return missing;
  return null;
}
