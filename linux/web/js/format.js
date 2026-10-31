// Words for numbers and dates. Times of day are said in the bridge's time zone (store.js bridgeZone).
import { bridgeZone } from './store.js';
import { zonedFormat } from './zone.js';

const relative = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });

/** "2 minutes ago", "now" */
export function timeAgo(value, now = Date.now()) {
  const then = typeof value === 'string' ? Date.parse(value) : value;
  if (!Number.isFinite(then)) return '';
  const seconds = Math.round((then - now) / 1000);
  if (Math.abs(seconds) < 10) return 'just now';
  const units = [['day', 86400], ['hour', 3600], ['minute', 60], ['second', 1]];
  for (const [unit, size] of units) {
    if (Math.abs(seconds) >= size) return relative.format(Math.round(seconds / size), unit);
  }
  return 'just now';
}

/** "14:02:11": the time of day of a date, an ISO text or epoch milliseconds, in `zone` (the bridge's when omitted). */
export function clock(value, zone = bridgeZone()) {
  const ms = typeof value === 'string' ? Date.parse(value) : value instanceof Date ? value.getTime() : value;
  if (!Number.isFinite(ms)) return '';
  return zonedFormat({ hour: '2-digit', minute: '2-digit', second: '2-digit' }, zone).format(ms);
}

/** "9:40 PM": the hour and minute of a date, an ISO text or epoch milliseconds, in `zone` (the bridge's when omitted); '' for one that is not a time. */
export function timeOfDay(value, zone = bridgeZone()) {
  const ms = typeof value === 'string' ? Date.parse(value) : value instanceof Date ? value.getTime() : value;
  if (!Number.isFinite(ms)) return '';
  return zonedFormat({ hour: 'numeric', minute: '2-digit' }, zone).format(ms);
}

/** "Oct 31, 2026, 2:14 PM": a date and time in `zone` (the bridge's when omitted); '' for one that is not a time. */
export function dateTime(value, zone = bridgeZone()) {
  const ms = typeof value === 'string' ? Date.parse(value) : value instanceof Date ? value.getTime() : value;
  if (!Number.isFinite(ms)) return '';
  return zonedFormat({ dateStyle: 'medium', timeStyle: 'short' }, zone).format(ms);
}

/** 93784 -> "1 day 2 hours" */
export function duration(seconds) {
  seconds = Math.max(0, Math.round(seconds));
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
  if (days) return `${plural(days, 'day')} ${plural(hours, 'hour')}`;
  if (hours) return `${plural(hours, 'hour')} ${plural(minutes, 'minute')}`;
  if (minutes) return plural(minutes, 'minute');
  return plural(seconds, 'second');
}

export function bytes(n) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = n;
  let i = 0;
  while (value >= 1000 && i < units.length - 1) { value /= 1000; i++; }
  return `${value >= 100 || i === 0 ? Math.round(value) : value.toFixed(1)} ${units[i]}`;
}

/** "43 GB", "2.4 TB": decimal units like the rest of the bridge, a decimal only below 10 (`bytes` keeps one up to 100): the Recording card's sizes. */
export function sizeText(n) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = n;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1; }
  return `${value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

export function plural(n, one, many = `${one}s`) {
  return `${n} ${n === 1 ? one : many}`;
}

/** "Vehicle detection" from "vehicle" */
export function capitalize(text) {
  return text ? text[0].toUpperCase() + text.slice(1) : text;
}
