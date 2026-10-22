// Playback speeds of the Monitor: the steps, the sound rule and how far ahead the cells fetch. No DOM, so Node tests run it as is.

export const SPEEDS = [1, 2, 3, 5, 10];
export const MUTE_ABOVE = 2;      // recorded sound plays up to this speed; above it the picture plays alone
const MAX_AHEAD = 6;

/** The step nearest to `value` (the lower one on a tie); 1 for anything that is not a positive number. */
export function nearestSpeed(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return 1;
  return SPEEDS.reduce((best, step) => (Math.abs(step - n) < Math.abs(best - n) ? step : best), SPEEDS[0]);
}

/** The step `direction` (+1 or -1) from `rate`; the ends stay. */
export function stepSpeed(rate, direction) {
  const at = SPEEDS.indexOf(nearestSpeed(rate));
  return SPEEDS[Math.max(0, Math.min(SPEEDS.length - 1, at + (direction < 0 ? -1 : 1)))];
}

export const speedLabel = (rate) => `${rate}×`;

/** True when recorded sound plays at this speed. */
export const soundAllowed = (rate) => !(Number(rate) > MUTE_ABOVE);

/** How many times further ahead than at 1× a cell keeps its buffer (and how often it asks): 1 at 1×, growing with the speed, capped. */
export function aheadFactor(rate) {
  const n = Number(rate);
  return Number.isFinite(n) && n > 1 ? Math.min(MAX_AHEAD, Math.ceil(n / 2) + 1) : 1;
}
