// The rules of the Events page (screens/events.js draws it): its filters and how they live in the address, the day groups, the link a row makes
// into the Monitor and which new events wait while the person reads. No DOM and no globals, so Node tests run it as is.
// The events themselves are wall-events-model.js gatherEvents(): { at, endAt, cameraId, cameraName, label, level, recorded, description }.
import { AI_KINDS, PRE_ROLL_MS } from './wall-events-model.js';
import { EPOCH_MIN_MS } from './nvr-model.js';

const DAY_MS = 86_400_000;
export const EVENT_RANGES = { today: 'Today', '24h': 'Last 24 hours', '7d': '7 days', '30d': '30 days' };
export const DEFAULT_RANGE = '7d';
export const CONCERN_CHOICES = { any: 'Any', notable: 'Alarm and unusual only', alarm: 'Alarm only' };
export const USUAL_TYPES = ['Motion', 'Person', 'Vehicle', 'Animal', 'Package', 'Face', 'Doorbell'];
export const DESCRIBE_WAIT_MS = 120_000;      // a description is "on its way" for an event this young
const CAMERA_ID = /^[0-9A-Fa-f-]{36}$/;
const CONCERNS = ['nothing', 'routine', 'unusual', 'alarm'];

export const concernRank = (concern) => CONCERNS.indexOf(concern);

export function emptyFilters() {
  return { cameras: [], types: [], saw: [], concern: 'any', described: false, q: '', range: DEFAULT_RANGE };
}

function list(value) {
  return String(value ?? '').split(',').map((part) => part.trim()).filter(Boolean);
}

/** The filters an address query ("cameras=…&type=Person,Doorbell&saw=person&concern=notable&described=1&q=jacket&range=24h") says; anything odd is left at its default. */
export function filtersFromQuery(query) {
  const filters = emptyFilters();
  let params;
  try { params = new URLSearchParams(String(query ?? '').replace(/^\?/, '')); } catch { return filters; }
  filters.cameras = list(params.get('cameras')).filter((cid) => CAMERA_ID.test(cid));
  filters.types = list(params.get('type'));
  filters.saw = list(params.get('saw')).filter((kind) => AI_KINDS.includes(kind));
  if (Object.hasOwn(CONCERN_CHOICES, params.get('concern'))) filters.concern = params.get('concern');
  filters.described = params.get('described') === '1';
  filters.q = (params.get('q') ?? '').slice(0, 100);
  if (Object.hasOwn(EVENT_RANGES, params.get('range'))) filters.range = params.get('range');
  return filters;
}

/** The address query for `filters`; what is at its default is left out, so no filter is the empty string. */
export function filtersToQuery(filters) {
  const params = new URLSearchParams();
  if (filters.cameras.length) params.set('cameras', filters.cameras.join(','));
  if (filters.types.length) params.set('type', filters.types.join(','));
  if (filters.saw.length) params.set('saw', filters.saw.join(','));
  if (filters.concern !== 'any') params.set('concern', filters.concern);
  if (filters.described) params.set('described', '1');
  if (filters.q.trim()) params.set('q', filters.q);
  if (filters.range !== DEFAULT_RANGE) params.set('range', filters.range);
  return params.toString().replace(/\+/g, '%20');
}

/** The range to ask the archive for: from the range's start, to now and everything newer (it follows live). */
export function queryRange(filters, now) {
  const fromMs = filters.range === 'today' ? new Date(new Date(now).setHours(0, 0, 0, 0)).getTime()
    : now - (filters.range === '24h' ? 1 : filters.range === '30d' ? 30 : 7) * DAY_MS;
  return { fromMs, toMs: Infinity };
}

/** The events `filters` let through, in the order given. */
export function filterEvents(events, filters, { now }) {
  const { fromMs } = queryRange(filters, now);
  const cameras = new Set(filters.cameras);
  const types = new Set(filters.types.map((type) => type.toLowerCase()));
  const saw = new Set(filters.saw);
  const words = filters.q.trim().toLowerCase();
  return events.filter((event) => {
    if (event.at < fromMs) return false;
    if (cameras.size && !cameras.has(event.cameraId)) return false;
    if (types.size && !types.has(event.label.toLowerCase())) return false;
    const said = event.description;
    if (saw.size && !(said && saw.has(said.kind))) return false;
    if (filters.concern === 'notable' && !(said && (said.concern === 'alarm' || said.concern === 'unusual'))) return false;
    if (filters.concern === 'alarm' && !(said && said.concern === 'alarm')) return false;
    if (filters.described && !said) return false;
    if (words && !(said && said.text.toLowerCase().includes(words))) return false;
    return true;
  });
}

/** The types to offer: the usual ones, then any other the events carry (once each, by their first spelling). */
export function typeChoices(events) {
  const seen = new Set(USUAL_TYPES.map((type) => type.toLowerCase()));
  const out = [...USUAL_TYPES];
  for (const event of events) {
    if (seen.has(event.label.toLowerCase())) continue;
    seen.add(event.label.toLowerCase());
    out.push(event.label);
  }
  return out;
}

const dayKey = (ms) => { const d = new Date(ms); return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`; };

/** Newest-first events in groups by local day: [{ key, label, events }], labelled Today, Yesterday, then the date (with the year when it is not this one). */
export function groupByDay(events, now) {
  const today = dayKey(now);
  const yesterday = dayKey(now - DAY_MS);
  const thisYear = new Date(now).getFullYear();
  const groups = [];
  for (const event of events) {
    const key = dayKey(event.at);
    let group = groups.at(-1);
    if (!group || group.key !== key) {
      const date = new Date(event.at);
      const label = key === today ? 'Today' : key === yesterday ? 'Yesterday'
        : date.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'short', ...(date.getFullYear() === thisYear ? {} : { year: 'numeric' }) });
      group = { key, label, events: [] };
      groups.push(group);
    }
    group.events.push(event);
  }
  return groups;
}

/** The Monitor's address for a row: that moment (a few seconds before it) with the event's camera, playing. Null when nothing was recorded then. */
export function eventPath(event) {
  if (event.recorded === false) return null;
  const ms = Math.round(event.at - PRE_ROLL_MS);
  return ms >= EPOCH_MIN_MS ? `/nvr/${ms}?camera=${event.cameraId}&play=1` : null;
}

/** True while the AI's words for the event may still come: the camera is described, the event is young and has none yet. */
export function isDescribing(event, camera, now) {
  return camera?.aiDescriptions === true && !event.description && now - event.at < DESCRIBE_WAIT_MS && now >= event.at;
}

export const eventKey = (event) => `${event.cameraId}|${event.label}|${event.at}`;

/**
 * Events that arrived since the list was drawn, while the person has scrolled down: they wait behind a "show" button so the rows being read
 * do not move. `known` is the keys drawn before. Only events newer than the newest known are held; an older page was asked for.
 */
export function holdNewEvents(events, known, { hold }) {
  if (!hold || known.size === 0) return { shown: events, held: [] };
  const newest = events.reduce((top, event) => (known.has(eventKey(event)) ? Math.max(top, event.at) : top), -Infinity);
  const held = events.filter((event) => !known.has(eventKey(event)) && event.at > newest);
  return { shown: held.length ? events.filter((event) => !held.includes(event)) : events, held };
}
