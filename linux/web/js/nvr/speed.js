// Playback speeds of the Monitor: the steps in their groups, the sound rule, how far ahead the cells fetch, and which speeds are time-lapse.
// No DOM, so Node tests run it as is.
//
//   Slow        ¼× and ½×        the video element's playbackRate (slow motion)
//   Normal      1×               the only speed with sound
//   Fast        2×, 4× and 8×    playbackRate, the cells fetching further ahead
//   Time-lapse  30× to 300×      no playbackRate (it cannot go that high smoothly, and fetching every part at that speed would flood the
//                                box): the session shows the key picture at the playhead every LAPSE_STEP_MS instead (session.js)

export const SPEED_GROUPS = Object.freeze([
  Object.freeze({ id: 'slow', label: 'Slow', speeds: Object.freeze([0.25, 0.5]) }),
  Object.freeze({ id: 'normal', label: 'Normal', speeds: Object.freeze([1]) }),
  Object.freeze({ id: 'fast', label: 'Fast', speeds: Object.freeze([2, 4, 8]) }),
  Object.freeze({ id: 'lapse', label: 'Time-lapse', speeds: Object.freeze([30, 60, 120, 300]) }),
]);
export const SPEEDS = Object.freeze(SPEED_GROUPS.flatMap((group) => group.speeds));
/** From this speed on the picture is stepped key picture by key picture (time-lapse), not played. */
export const LAPSE_FROM = 30;
/** How often a time-lapse shows the next key picture. */
export const LAPSE_STEP_MS = 500;
/** The time-lapse speeds a saved clip can be made at (the clip bar's Time-lapse, the bridge's `speed`). */
export const LAPSE_SPEEDS = SPEED_GROUPS.find((group) => group.id === 'lapse').speeds;
const MAX_AHEAD = 6;

/** The step nearest to `value` by ratio (the lower one on a tie); 1 for anything that is not a positive number. */
export function nearestSpeed(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return 1;
  const distance = (step) => Math.abs(Math.log(step / n));
  return SPEEDS.reduce((best, step) => (distance(step) < distance(best) - 1e-9 ? step : best), SPEEDS[0]);
}

/** The step `direction` (+1 or -1) from `rate`, across the groups; the ends stay. */
export function stepSpeed(rate, direction) {
  const at = SPEEDS.indexOf(nearestSpeed(rate));
  return SPEEDS[Math.max(0, Math.min(SPEEDS.length - 1, at + (direction < 0 ? -1 : 1)))];
}

/** True for the speeds that step key pictures instead of playing. */
export const isTimelapse = (rate) => Number(rate) >= LAPSE_FROM;

/** The group of a speed: 'slow', 'normal', 'fast' or 'lapse'. */
export function speedGroup(rate) {
  const step = nearestSpeed(rate);
  return SPEED_GROUPS.find((group) => group.speeds.includes(step)).id;
}

const FRACTIONS = new Map([[0.25, '¼'], [0.5, '½']]);
export const speedLabel = (rate) => `${FRACTIONS.get(Number(rate)) ?? rate}×`;

function span(seconds) {
  if (seconds >= 60 && seconds % 60 === 0) return `${seconds / 60} min`;
  return `${seconds} s`;
}

/**
 * What a speed does, in words, for its tooltip: "Slow motion", "As recorded", "4 times as fast", and for a time-lapse how long a minute takes
 * ("1 min = 2 s" at 30×; "5 min = 1 s" at 300×) and an hour.
 */
export function speedDescription(rate) {
  const step = nearestSpeed(rate);
  if (step < 1) return `Slow motion, ${step === 0.5 ? 'half' : 'a quarter of the'} speed`;
  if (step === 1) return 'As recorded, with sound';
  if (!isTimelapse(step)) return `${step} times as fast, no sound`;
  // The recording that passes in one second, as a round "N min = M s".
  const perSecond = step;                       // seconds of recording in one second
  const minute = perSecond >= 60 ? `${span(perSecond)} = 1 s` : `1 min = ${span(60 / perSecond)}`;
  return `Time-lapse: ${minute}, 1 hour = ${span(3600 / perSecond)}`;
}

/** True when recorded sound plays at this speed: at 1× only (slow motion and every faster speed play the picture alone). */
export const soundAllowed = (rate) => Number(rate) === 1;

/** How many times further ahead than at 1× a cell keeps its buffer (and how often it asks): 1 up to 1×, growing with the speed, capped. */
export function aheadFactor(rate) {
  const n = Number(rate);
  return Number.isFinite(n) && n > 1 ? Math.min(MAX_AHEAD, Math.ceil(n / 2) + 1) : 1;
}
