// The rules of the Monitor's events list (screens/wall-events.js draws it): which events there are, which of them the timeline shows, where a
// click puts the playhead, and the battery badge of a tile. No DOM and no globals, so Node tests run it as is.
//
// Where the events come from:
//   - the archive's event log (GET nvr/events?cameras=&from=&to=&limit=): every event the bridge saw, kept beside the recordings, with its end
//     and whether the recordings hold it (`recorded`). createEventArchive loads it for the timeline's range: newest first, a page at a time,
//     the newer part again while the timeline follows live, older pages when the range grows or on "Show more".
//   - status.recentEvents of every camera: [{ name, date }], the newest 20 rising edges per camera ("Motion", "Person", "Doorbell ring", …),
//     stamped by the bridge (server time). In memory on the bridge, and all there is while no place for recordings is chosen.
//   - the live events this page saw (wall-events.js history): motion (with its end, so a duration), doorbell rings, detections. Stamped with
//     the server's clock as the page knows it.
// They describe the same moments: an event of one camera with the same kind within MERGE_MS of another is one event.

export const PRE_ROLL_MS = 3000;          // a click plays from a little before the event
export const MERGE_MS = 5000;             // the same kind at the same camera within 5 s is one event
export const LIVE_GRACE_MS = 120_000;     // an event this much newer than the camera's newest recording is still being written
export const PAGE_ROWS = 100;             // rows drawn at first, and added by "Show more"
export const LOW_BATTERY = 20;            // percent: below this the battery badge warns
export const ARCHIVE_PAGE = 200;          // events per GET nvr/events
export const ARCHIVE_MAX_RANGE_MS = 31 * 86_400_000;   // the route's longest range
export const ARCHIVE_REFRESH_MS = 30_000; // while following live, the newest part is asked again this often (ends, events the stream missed)
export const ARCHIVE_OVERLAP_MS = 600_000; // and from this far back, so events that began a little earlier get their ends
export const ARCHIVE_RETRY_MS = 10_000;   // after a failed answer (a 503 while the recordings load or their drive is away, a 429, …)
export const ARCHIVE_KEEP = 5000;         // events kept in the page at most, besides older pages asked for (the oldest go first)

const DETECTION_WORDS = /person|people|human|face|vehicle|car|animal|pet|dog|cat|package|parcel|line|intrusion|region|object|loiter/i;

/** The kind of an event name: { label, level } with level 'motion' | 'detection' | 'doorbell'. The label is the bridge's word ("Doorbell ring" -> "Doorbell"). */
export function eventKind(name) {
  const text = String(name ?? '').trim() || 'Event';
  if (/doorbell|ring/i.test(text)) return { label: 'Doorbell', level: 'doorbell' };
  if (/^motion$/i.test(text) || (/motion/i.test(text) && !DETECTION_WORDS.test(text))) return { label: 'Motion', level: 'motion' };
  return { label: text, level: 'detection' };
}

function finite(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

/**
 * Every event known, merged, oldest first: [{ at, endAt, cameraId, cameraName, label, level, recorded }].
 *   cameras   the camera resources (store.js cameraList()); status.recentEvents is read defensively
 *   live      wall-events.js history: [{ at, endAt?, id, name, text, level }]
 *   archived  the archive's events (GET nvr/events): [{ id, cameraID, kind, start, end, recorded }]
 * `endAt` is null when the event's end is not known; `recorded` is the archive's word (true or false), null when it did not say.
 */
export function gatherEvents({ cameras = [], live = [], archived = [] } = {}) {
  const names = new Map(cameras.map((camera) => [camera.id, camera.name]));
  const byUpper = new Map(cameras.map((camera) => [String(camera.id).toUpperCase(), camera.id]));
  const raw = [];
  for (const record of archived) {
    const cameraId = byUpper.get(String(record?.cameraID ?? '').toUpperCase());
    if (cameraId === undefined || !finite(record.start)) continue;
    raw.push({
      at: record.start, endAt: finite(record.end) && record.end >= record.start ? record.end : null, cameraId, ...eventKind(record.kind),
      recorded: typeof record.recorded === 'boolean' ? record.recorded : null, source: 'archive',
    });
  }
  for (const camera of cameras) {
    const recent = Array.isArray(camera?.status?.recentEvents) ? camera.status.recentEvents : [];
    for (const record of recent) {
      const at = Date.parse(record?.date);
      if (!finite(at)) continue;
      raw.push({ at, endAt: null, cameraId: camera.id, ...eventKind(record.name), recorded: null, source: 'bridge' });
    }
  }
  for (const entry of live) {
    if (!entry || !finite(entry.at) || !names.has(entry.id)) continue;
    const kind = entry.level === 'doorbell' ? { label: 'Doorbell', level: 'doorbell' } : eventKind(entry.text);
    raw.push({ at: entry.at, endAt: finite(entry.endAt) && entry.endAt >= entry.at ? entry.endAt : null, cameraId: entry.id, ...kind, recorded: null, source: 'live' });
  }
  raw.sort((a, b) => a.at - b.at);

  // One event per camera and kind within MERGE_MS: the archive's stamp wins, then the bridge's (both are the server's own), the end comes from
  // whichever knows it, and whether it is recorded from the archive.
  const rank = { archive: 2, bridge: 1, live: 0 };
  const merged = [];
  const lastOf = new Map();   // camera|label -> the merged event it would join
  for (const event of raw) {
    const group = `${event.cameraId}|${event.label}`;
    const last = lastOf.get(group);
    if (last && event.at - last.at <= MERGE_MS) {
      if (rank[event.source] > rank[last.source]) { last.at = event.at; last.source = event.source; }
      if (event.endAt !== null && (last.endAt === null || event.endAt > last.endAt)) last.endAt = event.endAt;
      if (event.recorded !== null && (last.recorded === null || event.source === 'archive')) last.recorded = event.recorded;
      continue;
    }
    const next = { ...event, cameraName: names.get(event.cameraId) ?? '' };
    merged.push(next);
    lastOf.set(group, next);
  }
  return merged.map(({ source, ...event }) => ({ ...event, endAt: event.endAt !== null && event.endAt >= event.at ? event.endAt : null }));
}

/** The time range of the list: what the timeline shows (its viewport). While the timeline follows live, everything newer counts too. */
export function eventRange(viewport, { following = false } = {}) {
  if (!viewport || !finite(viewport.startMs) || !finite(viewport.durationMs)) return { fromMs: -Infinity, toMs: Infinity };
  return { fromMs: viewport.startMs, toMs: following ? Infinity : viewport.startMs + viewport.durationMs };
}

/**
 * The events the list shows, newest first: those of `cameraIds` (the cameras on the wall, or the one opened on its own) inside the range.
 * Same time: by camera name, so the order never flickers.
 */
export function visibleEvents(events, { cameraIds, fromMs = -Infinity, toMs = Infinity }) {
  const wanted = new Set(cameraIds);
  return events
    .filter((event) => wanted.has(event.cameraId) && event.at >= fromMs && event.at <= toMs)
    .sort((a, b) => b.at - a.at || a.cameraName.localeCompare(b.cameraName) || a.label.localeCompare(b.label));
}

/**
 * True when the camera's recordings hold the event (or are still being written up to it): a click can play it. The archive's `recorded: false`
 * (nothing was recorded then, or retention took it) wins; otherwise the camera's recorded span decides.
 */
export function isRecorded(event, extent) {
  if (event?.recorded === false) return false;
  if (!extent || !finite(extent.oldest) || !finite(extent.newest)) return false;
  return event.at >= extent.oldest - PRE_ROLL_MS && event.at <= extent.newest + LIVE_GRACE_MS;
}

/** Where a click puts the playhead: PRE_ROLL_MS before the event, never before the camera's oldest recording nor after its newest. Null when not recorded. */
export function seekTarget(event, extent, preRollMs = PRE_ROLL_MS) {
  if (!isRecorded(event, extent)) return null;
  return Math.round(Math.max(extent.oldest, Math.min(event.at - preRollMs, extent.newest)));
}

/** The same event as `selected` ({ cameraId, label, at }): a merge may move its time by up to MERGE_MS. */
export function sameEvent(event, selected) {
  return Boolean(selected) && event.cameraId === selected.cameraId && event.label === selected.label && Math.abs(event.at - selected.at) <= MERGE_MS;
}

/** "8 s", "2 min 5 s", "1 h 4 min"; null under half a second or when unknown. */
export function durationText(ms) {
  if (!finite(ms) || ms < 500) return null;
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds} s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return seconds % 60 ? `${minutes} min ${seconds % 60} s` : `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  return minutes % 60 ? `${hours} h ${minutes % 60} min` : `${hours} h`;
}

/**
 * What happens on a click, for the wall: { targetMs, leaveSolo } or null (nothing recorded there). The list is scoped to the camera opened on its
 * own while there is one, so the wall then stays on it; an event of another camera (not possible from a scoped list) shows every camera again.
 */
export function pickAction(event, { extent, soloId = null }) {
  const targetMs = seekTarget(event, extent);
  if (targetMs === null) return null;
  return { targetMs, leaveSolo: soloId !== null && soloId !== event.cameraId };
}

/** The battery badge of a camera: { level, charging, low, text } from status.battery ({ level: percent, charging, source }), or null when absent. */
export function batteryBadge(camera) {
  const battery = camera?.status?.battery;
  if (!battery || typeof battery !== 'object') return null;
  const raw = Number(battery.level);
  if (!Number.isFinite(raw)) return null;
  const level = Math.round(Math.min(100, Math.max(0, raw)));
  const charging = battery.charging === true;
  return { level, charging, low: level < LOW_BATTERY, text: `${level}%` };
}

// MARK: The archive's events

/**
 * Loads the archive's events for the list: `{ want({ cameraIds, fromMs, toMs }), events(), hasOlder(), loadOlder(), destroy() }`.
 *   load({ cameras, fromMs, toMs, limit })  GET nvr/events; resolves to its answer ({ events, more }), rejects on a failure
 *   onChange()                              new events arrived
 *   now()                                   the server's clock (an open end of the range, following live, is now)
 * One request at a time. What is loaded is one stretch of time (`span`), complete from its start to its end unless the newest-first page
 * stopped short (`more`): then the older part of the range waits for loadOlder(). A range that moves later asks for the newer part, while
 * following live every ARCHIVE_REFRESH_MS from ARCHIVE_OVERLAP_MS back; a range that reaches earlier asks for the older part. A newer
 * part that stops short (a burst on a busy wall) leaves a `gap` between where it began and its oldest event: that is asked for next,
 * before anything else, a page at a time until one is whole, so the list never keeps a hole between the newest events and the older ones.
 * Other cameras start again, and an answer for cameras that are no longer asked for is ignored. A failure (a 503 while the recordings load
 * or their drive is away included) waits ARCHIVE_RETRY_MS and asks again: it never counts as a range without events. The route never
 * splits a millisecond between pages, so the next older page is asked up to the oldest start loaded, that start excluded.
 * At most `keep` events stay (ARCHIVE_KEEP, plus the older pages asked for); past it the oldest go and `span` starts after them again.
 */
export function createEventArchive({ load, onChange = () => {}, now = () => Date.now(), setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = (handle) => clearTimeout(handle), pageSize = ARCHIVE_PAGE, keep = ARCHIVE_KEEP } = {}) {
  let key = '';
  let generation = 0;         // +1 whenever the cameras change: an answer asked for under another generation is not used
  let cameras = [];
  let wanted = null;          // { fromMs, toMs, following }
  let loaded = new Map();     // `${cameraID}|${id}` -> event
  let span = null;            // { fromMs, toMs }: everything between is loaded, except below `fromMs` when `more`, and inside `gap`
  let gap = null;             // { fromMs, toMs } inside `span`: a newer part stopped short above it, so events may be missing there
  let more = false;
  let olderAsked = false;
  let room = keep;            // events kept at most: `keep`, or more once older pages were asked for (they are not dropped again at once)
  let busy = false;
  let lastNewerAt = -Infinity;
  let timer = null;
  let timerAt = Infinity;     // when `timer` fires
  let waitUntil = -Infinity;
  let destroyed = false;

  /** The range to ask for, in whole milliseconds and never longer than the route allows (rounded first, then held to ARCHIVE_MAX_RANGE_MS). */
  function range() {
    if (!wanted) return null;
    const toMs = Math.ceil(wanted.following || !finite(wanted.toMs) ? now() + 60_000 : wanted.toMs);
    const fromMs = finite(wanted.fromMs) ? Math.max(Math.floor(wanted.fromMs), toMs - ARCHIVE_MAX_RANGE_MS) : toMs - 86_400_000;
    return toMs > fromMs ? { fromMs, toMs } : null;
  }

  /** One timer, the earliest asked for: a retry after a failure does not wait for the next refresh. */
  function schedule(ms) {
    if (destroyed) return;
    const at = now() + Math.max(0, ms);
    if (timer !== null) {
      if (timerAt <= at) return;
      clearTimer(timer);
    }
    timerAt = at;
    timer = setTimer(() => { timer = null; timerAt = Infinity; pump(); }, Math.max(0, ms));
  }

  /** The next request, or null: the gap a newer part left, the newer part, then the older part, then nothing. */
  function next() {
    const want = range();
    if (!want || cameras.length === 0) return null;
    if (!span || want.toMs <= span.fromMs || want.fromMs >= span.toMs) return { fromMs: want.fromMs, toMs: want.toMs, part: 'all' };
    if (gap) return { fromMs: gap.fromMs, toMs: gap.toMs, part: 'gap' };
    if (want.toMs > span.toMs) {
      const due = now() - lastNewerAt >= ARCHIVE_REFRESH_MS || want.toMs - span.toMs > 60_000;
      if (due) return { fromMs: Math.max(want.fromMs, span.toMs - ARCHIVE_OVERLAP_MS), toMs: want.toMs, part: 'newer' };
      schedule(ARCHIVE_REFRESH_MS - (now() - lastNewerAt));
    }
    if (want.fromMs < span.fromMs && (!more || olderAsked)) return { fromMs: want.fromMs, toMs: span.fromMs, part: 'older' };
    return null;
  }

  function adopt(request, answer) {
    if (request.part !== 'all' && !span) return;
    const events = Array.isArray(answer?.events) ? answer.events.filter((e) => e && typeof e.id === 'string' && finite(e.start)) : [];
    if (request.part === 'all') {   // a stretch of its own: what was loaded before is outside it
      loaded = new Map();
      room = keep;
    }
    for (const event of events) loaded.set(`${String(event.cameraID).toUpperCase()}|${event.id}`, event);
    const cut = answer?.more === true;
    const oldest = events.length ? Math.min(...events.map((e) => e.start)) : request.fromMs;
    const reached = cut ? oldest : request.fromMs;
    if (request.part === 'all') {
      span = { fromMs: reached, toMs: request.toMs };
      gap = null;
      more = cut;
      olderAsked = false;
      lastNewerAt = now();
    } else if (request.part === 'newer' || request.part === 'gap') {
      // Whole from `reached` up; below it, down to where the request began, waits for the next request (the route never splits a
      // millisecond, so a page that stops short always leaves something older than its oldest event).
      if (request.part === 'newer') {
        lastNewerAt = now();
        span = { fromMs: span.fromMs, toMs: request.toMs };
      }
      const fromMs = Math.max(request.fromMs, span.fromMs);
      gap = reached > fromMs ? { fromMs, toMs: reached } : null;
    } else {
      span = { fromMs: reached, toMs: span.toMs };
      more = cut;
      olderAsked = false;
      room = Math.max(room, loaded.size);   // the page asked for stays
    }
    if (loaded.size > room) evict();
  }

  /**
   * Back to `room` events, in agreement with `span`: first those outside it (the farthest first), then the oldest inside it. Only a newer
   * part (and its gap) passes `room`, and it reaches to the end of the range, so the oldest are the end farthest from what the list shows. A
   * millisecond is never split, and `span` then starts at the oldest event kept, with `more`, so "Show older events" asks for the rest again.
   * A gap below the oldest kept is no longer asked for (it is part of the rest); one that reaches above it is held to the new `span`.
   */
  function evict() {
    const inside = [];
    const outside = [];
    for (const entry of loaded) (entry[1].start >= span.fromMs && entry[1].start < span.toMs ? inside : outside).push(entry);
    const distance = ([, event]) => (event.start < span.fromMs ? span.fromMs - event.start : event.start - span.toMs + 1);
    if (inside.length <= room) {
      outside.sort((a, b) => distance(a) - distance(b));
      loaded = new Map([...inside, ...outside.slice(0, room - inside.length)]);
      return;
    }
    inside.sort((a, b) => b[1].start - a[1].start);
    let kept = inside.slice(0, room);
    const edge = kept.at(-1)[1].start;
    if (inside[room][1].start === edge) {
      const newer = kept.filter(([, event]) => event.start !== edge);
      kept = newer.length ? newer : inside.filter(([, event]) => event.start === edge);
    }
    loaded = new Map(kept);
    span = { fromMs: kept.reduce((low, [, event]) => Math.min(low, event.start), Infinity), toMs: span.toMs };
    if (gap) gap = gap.toMs > span.fromMs ? { fromMs: Math.max(gap.fromMs, span.fromMs), toMs: gap.toMs } : null;
    more = true;
    olderAsked = false;
  }

  function pump() {
    if (destroyed || busy) return;
    if (now() < waitUntil) { schedule(waitUntil - now()); return; }
    const request = next();
    if (!request) return;
    busy = true;
    const asked = generation;
    Promise.resolve()
      .then(() => load({ cameras, fromMs: request.fromMs, toMs: request.toMs, limit: pageSize }))
      .then((answer) => {
        busy = false;
        if (destroyed || asked !== generation) { pump(); return; }   // for cameras that are no longer asked for
        adopt(request, answer);
        onChange();
        pump();
        if (wanted?.following) schedule(ARCHIVE_REFRESH_MS);
      }, () => {
        busy = false;
        if (destroyed) return;
        if (asked !== generation) { pump(); return; }
        waitUntil = now() + ARCHIVE_RETRY_MS;
        schedule(ARCHIVE_RETRY_MS);
      });
  }

  return {
    /** The cameras and range the list shows; cheap when nothing changed. `toMs` Infinity: following live. */
    want({ cameraIds = [], fromMs = -Infinity, toMs = Infinity } = {}) {
      const ids = [...new Set(cameraIds.map((cid) => String(cid)))].sort().slice(0, 16);
      const nextKey = ids.join(',');
      if (nextKey !== key) {
        key = nextKey;
        generation += 1;
        cameras = ids;
        loaded = new Map();
        span = null;
        gap = null;
        more = false;
        olderAsked = false;
        room = keep;
        lastNewerAt = -Infinity;
        waitUntil = -Infinity;
      }
      wanted = { fromMs, toMs, following: !finite(toMs) };
      pump();
    },
    /** The loaded events (the route's shape), any order. */
    events: () => [...loaded.values()],
    /** True when the range holds older events than those loaded (the newest-first page stopped short). */
    hasOlder() {
      const want = range();
      return Boolean(more && span && want && want.fromMs < span.fromMs);
    },
    /** Asks for the next older page of the range. */
    loadOlder() {
      olderAsked = true;
      pump();
    },
    /** A request is under way (tests). */
    get busy() { return busy; },
    destroy() {
      destroyed = true;
      if (timer !== null) clearTimer(timer);
      timer = null;
      timerAt = Infinity;
    },
  };
}
