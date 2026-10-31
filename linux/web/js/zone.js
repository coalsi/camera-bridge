// Times in a time zone, for every page: the wall-clock fields of an instant, the first instant of a day, formatters kept per zone, and the
// zone's short name. Nothing here reads the bridge's zone (store.js bridgeZone does) or the machine's own, except browserZone(): the caller
// passes the zone. No DOM: Node tests run it as is. (The timeline's ticks, nvr/timeline/ticks.js, use these too.)

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/** The zone this browser is in (an IANA name), UTC when it gives none. */
export function browserZone() {
  try { return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'; } catch { return 'UTC'; }
}

/** Whether `zone` is a time zone this browser knows. */
export function knownZone(zone) {
  if (typeof zone !== 'string' || !zone) return false;
  try { new Intl.DateTimeFormat('en-US', { timeZone: zone }); return true; } catch { return false; }
}

const formatters = new Map();

/** An Intl.DateTimeFormat for `options` in `timeZone` (kept, so a clock that ticks every second makes none). `locale` undefined: the browser's. */
export function zonedFormat(options, timeZone, locale = undefined) {
  const id = `${JSON.stringify(options)}|${timeZone}|${locale ?? ''}`;
  let f = formatters.get(id);
  if (!f) {
    f = new Intl.DateTimeFormat(locale, { ...options, timeZone });
    formatters.set(id, f);
  }
  return f;
}

/** The wall-clock fields of an instant in a zone: { year, month, day, hour, minute, second, offsetMs }; `offsetMs` is local minus UTC. */
export function zonedParts(ms, timeZone) {
  const parts = {};
  for (const part of zonedFormat({
    hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric',
  }, timeZone, 'en-US').formatToParts(ms)) {
    if (part.type !== 'literal') parts[part.type] = Number(part.value);
  }
  parts.hour %= 24;
  const wholeSecondMs = Math.floor(ms / 1000) * 1000;
  parts.offsetMs = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second) - wholeSecondMs;
  return parts;
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

/** The first instant of the day `ms` falls on in `timeZone` (midnight there, on daylight-saving days too). */
export function startOfZonedDay(ms, timeZone) {
  const p = zonedParts(ms, timeZone);
  return startOfLocalDay(p.year, p.month, p.day, timeZone);
}

/** "2026-10-31": the calendar day `ms` falls on in `timeZone`. */
export function zonedDayKey(ms, timeZone) {
  const p = zonedParts(ms, timeZone);
  return `${p.year}-${String(p.month).padStart(2, '0')}-${String(p.day).padStart(2, '0')}`;
}

/** Whether `a` and `b` fall on the same calendar day in `timeZone`. */
export function sameZonedDay(a, b, timeZone) {
  return zonedDayKey(a, timeZone) === zonedDayKey(b, timeZone);
}

/** The day before the one `key` (zonedDayKey) names, as a key. */
export function previousDayKey(key) {
  const [y, m, d] = key.split('-').map(Number);
  const date = new Date(Date.UTC(y, m - 1, d) - DAY);
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, '0')}-${String(date.getUTCDate()).padStart(2, '0')}`;
}

/** The zone's short name at `ms` ("MST", "GMT+1"), or '' when the browser gives none. */
export function zoneShortName(timeZone, ms = Date.now(), locale = undefined) {
  try {
    return zonedFormat({ timeZoneName: 'short', hour: 'numeric' }, timeZone, locale).formatToParts(ms).find((part) => part.type === 'timeZoneName')?.value ?? '';
  } catch { return ''; }
}

/** Whether two zones tell the same time at `ms` (and so the page need not name the bridge's). */
export function sameClock(a, b, ms = Date.now()) {
  if (a === b) return true;
  try { return zonedParts(ms, a).offsetMs === zonedParts(ms, b).offsetMs; } catch { return false; }
}

/**
 * The instant a wall-clock time names in `timeZone`: `date` "2026-10-31" and `time` "14:05" or "14:05:30" (what <input type="date"> and
 * <input type="time"> give). In the hour a clock goes back the first of the two instants; in one it skips, the instant an hour later. Null for text
 * that is not a date and time.
 */
export function zonedInstant(date, time, timeZone) {
  const d = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(date ?? '').trim());
  const t = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(String(time ?? '').trim());
  if (!d || !t) return null;
  const [year, month, day] = [Number(d[1]), Number(d[2]), Number(d[3])];
  const [hour, minute, second] = [Number(t[1]), Number(t[2]), Number(t[3] ?? 0)];
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) return null;
  const wall = Date.UTC(year, month - 1, day, hour, minute, second);
  // The zone's offset half a day before and after: the wall time minus each is an instant that may tell that time. Both do in the hour a clock
  // goes back (the first is taken); neither does in the hour it skips (then the offset from before the change, which lands an hour later).
  const before = zonedParts(wall - 12 * HOUR, timeZone).offsetMs;
  const after = zonedParts(wall + 12 * HOUR, timeZone).offsetMs;
  const tells = (ms) => { const p = zonedParts(ms, timeZone); return p.year === year && p.month === month && p.day === day && p.hour === hour && p.minute === minute; };
  const fits = [wall - before, wall - after].filter(tells);
  return fits.length ? Math.min(...fits) : wall - before;
}

/** The date and time fields' text ("2026-10-31", "14:05") for `ms` in `timeZone`: what a date and a time input show. */
export function zonedInputs(ms, timeZone) {
  const p = zonedParts(ms, timeZone);
  const two = (n) => String(n).padStart(2, '0');
  return { date: `${p.year}-${two(p.month)}-${two(p.day)}`, time: `${two(p.hour)}:${two(p.minute)}` };
}
