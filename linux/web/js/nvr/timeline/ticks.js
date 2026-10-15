// Ruler ticks for the timeline: [{ ms, label, major }], aligned to the viewer's local clock and correct on daylight-saving days.
// Steps under an hour are aligned to the zone's own offset; hour steps keep ticks whose local hour is a multiple of the step; day
// steps use the first instant of each local calendar day. Nothing here reads the machine's time zone: the caller passes one.

const SECOND = 1000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** The fixed step table, 1 second to 7 days. */
export const TICK_STEPS_MS = [
  1 * SECOND, 2 * SECOND, 5 * SECOND, 10 * SECOND, 15 * SECOND, 30 * SECOND,
  1 * MINUTE, 2 * MINUTE, 5 * MINUTE, 10 * MINUTE, 15 * MINUTE, 30 * MINUTE,
  1 * HOUR, 2 * HOUR, 3 * HOUR, 6 * HOUR, 12 * HOUR,
  1 * DAY, 2 * DAY, 7 * DAY,
];

const formatters = new Map();
function formatter(key, timeZone, locale, options) {
  const id = `${key}|${timeZone}|${locale || ''}`;
  let f = formatters.get(id);
  if (!f) {
    f = new Intl.DateTimeFormat(locale, { timeZone, ...options });
    formatters.set(id, f);
  }
  return f;
}

/** The wall-clock fields of an instant in a zone. `offsetMs` is local minus UTC. */
export function zonedParts(ms, timeZone) {
  const parts = {};
  for (const part of formatter('parts', timeZone, 'en-US', {
    hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric',
  }).formatToParts(ms)) {
    if (part.type !== 'literal') parts[part.type] = Number(part.value);
  }
  parts.hour %= 24;
  const wholeSecondMs = Math.floor(ms / SECOND) * SECOND;
  parts.offsetMs = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second) - wholeSecondMs;
  return parts;
}

/** Days since 1970-01-01 of a local calendar date. */
function dayNumber(parts) {
  return Math.floor(Date.UTC(parts.year, parts.month - 1, parts.day) / DAY);
}

/** The first instant of a local calendar day (a day that starts with a skipped hour starts at the first instant that exists). */
export function startOfLocalDay(year, month, day, timeZone) {
  const guess = Date.UTC(year, month - 1, day);
  let ms = guess - zonedParts(guess, timeZone).offsetMs;
  ms = guess - zonedParts(ms, timeZone).offsetMs;
  for (let i = 0; i < 3; i += 1) {
    const p = zonedParts(ms, timeZone);
    if (p.year === year && p.month === month && p.day === day) break;
    ms += HOUR;
  }
  return ms;
}

function labelFor(ms, step, major, timeZone, locale) {
  if (step >= DAY || (step >= HOUR && major)) {
    const options = step >= DAY && major
      ? { day: 'numeric', month: 'short', year: 'numeric' }
      : { weekday: 'short', day: 'numeric', month: 'short' };
    return formatter(`date${major ? 'M' : ''}${step >= DAY ? 'D' : ''}`, timeZone, locale, options).format(ms);
  }
  const options = step < MINUTE
    ? { hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }
    : { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' };
  return formatter(step < MINUTE ? 'hms' : 'hm', timeZone, locale, options).format(ms);
}

function isMajor(ms, step, timeZone) {
  const p = zonedParts(ms, timeZone);
  if (step < MINUTE) return p.second === 0;
  if (step < HOUR) return p.minute === 0;
  if (step < DAY) return p.hour === 0 && p.minute === 0;
  return p.day === 1;
}

/** Instants `stepMs` apart whose local wall-clock time is a multiple of `stepMs` (steps that divide an hour, or exactly one hour). */
function alignedInstants(startMs, endMs, stepMs, timeZone) {
  const out = [];
  const offset = zonedParts(startMs, timeZone).offsetMs;
  let ms = Math.ceil((startMs + offset) / stepMs) * stepMs - offset;
  for (; ms <= endMs; ms += stepMs) out.push(ms);
  return out;
}

/**
 * Ticks for the viewport, at least `minSpacingPx` apart (the smallest step in the table that is wide enough).
 * `timeZone` is an IANA name; `locale` only changes the words of the labels.
 */
export function makeTicks(viewport, widthPx, { timeZone, minSpacingPx = 80, locale } = {}) {
  if (!(widthPx > 0) || !(viewport.durationMs > 0)) return [];
  const zone = timeZone || Intl.DateTimeFormat().resolvedOptions().timeZone;
  const startMs = viewport.startMs;
  const endMs = viewport.startMs + viewport.durationMs;
  const wanted = (viewport.durationMs * minSpacingPx) / widthPx;
  const step = TICK_STEPS_MS.find((s) => s >= wanted) ?? TICK_STEPS_MS[TICK_STEPS_MS.length - 1];

  let instants;
  if (step < HOUR) {
    instants = alignedInstants(startMs, endMs, step, zone);
  } else if (step < DAY) {
    const everyHours = step / HOUR;
    instants = alignedInstants(startMs, endMs, HOUR, zone).filter((ms) => zonedParts(ms, zone).hour % everyHours === 0);
  } else {
    instants = [];
    const first = zonedParts(startMs, zone);
    let cursor = Date.UTC(first.year, first.month - 1, first.day);
    const everyDays = step / DAY;
    for (let guard = 0; guard < 4000; guard += 1, cursor += DAY) {
      const n = Math.floor(cursor / DAY);
      const keep = everyDays === 1 ? true : everyDays === 2 ? n % 2 === 0 : (((n - 4) % 7) + 7) % 7 === 0;   // 1970-01-05 was a Monday
      if (!keep) continue;
      const date = new Date(cursor);
      const ms = startOfLocalDay(date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate(), zone);
      if (ms > endMs) break;
      if (ms >= startMs) instants.push(ms);
    }
  }
  if (wanted > step) {
    // Beyond the last step of the table (a window of many months): every n-th Monday, so labels still do not touch.
    const stride = Math.ceil(wanted / step);
    instants = instants.filter((_, index) => index % stride === 0);
  }
  return instants.map((ms) => {
    const major = isMajor(ms, step, zone);
    return { ms, label: labelFor(ms, step, major, zone, locale), major };
  });
}
