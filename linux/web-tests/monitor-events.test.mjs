// The Monitor's events list (screens/wall-events-model.js) and the click that plays the wall from an event (nvr-controller.js playAt).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  ARCHIVE_MAX_RANGE_MS, ARCHIVE_OVERLAP_MS, ARCHIVE_PAGE, ARCHIVE_REFRESH_MS, ARCHIVE_RETRY_MS, LIVE_GRACE_MS, MERGE_MS, PAGE_ROWS, PRE_ROLL_MS, batteryBadge,
  createEventArchive, durationText, eventKind, eventRange, gatherEvents, isRecorded, pickAction, sameEvent, seekTarget, visibleEvents,
} from '../web/js/screens/wall-events-model.js';
import { createGridController } from '../web/js/screens/nvr-controller.js';
import { fakeTime, settle } from './nvr-grid-helpers.mjs';
import { installFakeBrowser } from './support/fake-browser.mjs';

const T0 = 1760099000000;
const id = (n) => `00000000-0000-4000-8000-00000000000${n}`;
const iso = (ms) => new Date(ms).toISOString();

function camera(n, recent = [], extra = {}) {
  return { id: id(n), name: `Camera ${n}`, isEnabled: true, nvrEnabled: true, status: { connection: 'online', recentEvents: recent, ...extra } };
}

test('eventKind names motion, detections and doorbell rings', () => {
  assert.deepEqual(eventKind('Motion'), { label: 'Motion', level: 'motion' });
  assert.deepEqual(eventKind('Doorbell ring'), { label: 'Doorbell', level: 'doorbell' });
  assert.deepEqual(eventKind('Person'), { label: 'Person', level: 'detection' });
  assert.deepEqual(eventKind('Vehicle'), { label: 'Vehicle', level: 'detection' });
  assert.deepEqual(eventKind('Alarm input 1'), { label: 'Alarm input 1', level: 'detection' });
  assert.deepEqual(eventKind(''), { label: 'Event', level: 'detection' });
  assert.deepEqual(eventKind(undefined), { label: 'Event', level: 'detection' });
});

test('gatherEvents reads every camera’s recent events and the live ones, and merges the same moment', () => {
  const cameras = [
    camera(1, [{ name: 'Motion', date: iso(T0) }, { name: 'Person', date: iso(T0) }, { name: 'Motion', date: iso(T0 + 60_000) }]),
    camera(2, [{ name: 'Doorbell ring', date: iso(T0 + 30_000) }, { name: 'Motion', date: 'not a date' }]),
    { id: id(3), name: 'Camera 3' },   // no status at all
  ];
  const live = [
    // The page saw camera 1's second motion 1.2 s after the bridge stamped it (the page's clock), and saw it end 9 s later.
    { at: T0 + 61_200, endAt: T0 + 70_000, id: id(1), name: 'Camera 1', text: 'Motion', level: 'motion' },
    { at: T0 + 30_500, endAt: null, id: id(2), name: 'Camera 2', text: 'Doorbell ring', level: 'doorbell' },
    { at: T0 + 90_000, endAt: null, id: id(9), name: 'Gone', text: 'Motion', level: 'motion' },    // a camera that is no longer there
    { at: T0 + 120_000, endAt: null, id: id(3), name: 'Camera 3', text: 'Motion', level: 'motion' }, // only live, not in the bridge's list yet
  ];
  const events = gatherEvents({ cameras, live });
  assert.deepEqual(events.map((e) => [e.cameraId, e.label, e.at - T0, e.endAt === null ? null : e.endAt - T0]), [
    [id(1), 'Motion', 0, null],
    [id(1), 'Person', 0, null],
    [id(2), 'Doorbell', 30_000, null],
    [id(1), 'Motion', 60_000, 70_000],    // the bridge's stamp, the page's end
    [id(3), 'Motion', 120_000, null],
  ]);
  assert.equal(events[0].cameraName, 'Camera 1');
});

test('gatherEvents takes the archive’s events with their ends and recorded flag, and merges them with the bridge’s and the live ones', () => {
  const cameras = [camera(1, [{ name: 'Motion', date: iso(T0) }]), camera(2)];
  const archived = [
    { id: 'a', cameraID: id(1).toUpperCase(), kind: 'Motion', start: T0, end: T0 + 9_000, recorded: true },
    { id: 'b', cameraID: id(2), kind: 'Doorbell ring', start: T0 + 30_000, end: T0 + 30_000, recorded: false },
    { id: 'c', cameraID: id(2), kind: 'Person', start: T0 - 86_400_000, end: null, recorded: true },   // a day ago: only the archive knows it
    { id: 'd', cameraID: id(9), kind: 'Motion', start: T0, end: null, recorded: true },               // a camera that is no longer there
    { id: 'e', cameraID: id(1), kind: 'Motion', start: 'soon', end: null, recorded: true },            // not a time
  ];
  const live = [{ at: T0 + 30_800, endAt: null, id: id(2), name: 'Camera 2', text: 'Doorbell ring', level: 'doorbell' }];
  const events = gatherEvents({ cameras, live, archived });
  assert.deepEqual(events.map((e) => [e.cameraId, e.label, e.at - T0, e.endAt === null ? null : e.endAt - T0, e.recorded]), [
    [id(2), 'Person', -86_400_000, null, true],
    [id(1), 'Motion', 0, 9_000, true],
    [id(2), 'Doorbell', 30_000, 0 + 30_000, false],   // the archive's stamp, not the page's 0.8 s later
  ]);
  assert.equal(gatherEvents({ cameras }).at(0).recorded, null, 'without the archive nobody said');
});

test('gatherEvents keeps a description and a merge does not lose it', () => {
  const said = (summary, kind, concern) => ({ summary, kind, concern });
  const cameras = [camera(1), camera(2), camera(3)];
  const archived = [
    { id: 'a', cameraID: id(1), kind: 'Person', start: T0, end: T0 + 9_000, recorded: true, description: said('A man in a red jacket walks to the door', 'person', 'routine') },
    // Two motions of camera 2 within MERGE_MS: only the later one was described.
    { id: 'b', cameraID: id(2), kind: 'Motion', start: T0 + 60_000, end: null, recorded: true, description: null },
    { id: 'c', cameraID: id(2), kind: 'Motion', start: T0 + 62_000, end: null, recorded: true, description: said('Branches move in the wind', 'nothing', 'routine') },
    // Two of camera 3 within MERGE_MS, both described: the one that matters more stays.
    { id: 'd', cameraID: id(3), kind: 'Person', start: T0 + 90_000, end: null, recorded: true, description: said('A person walks by', 'person', 'routine') },
    { id: 'e', cameraID: id(3), kind: 'Person', start: T0 + 92_000, end: null, recorded: true, description: said('A person tries the door handle', 'person', 'alarm') },
    { id: 'f', cameraID: id(1), kind: 'Vehicle', start: T0 + 120_000, end: null, recorded: true, description: said('  A car stops at the gate  ', 'vehicle', 'whatever') },
    { id: 'g', cameraID: id(1), kind: 'Motion', start: T0 + 180_000, end: null, recorded: true, description: said('', 'other', 'unusual') },   // no words
  ];
  // The page saw camera 1's person 0.3 s before the bridge stamped it: the live one has no description of its own.
  const live = [{ at: T0 - 300, endAt: null, id: id(1), name: 'Camera 1', text: 'Person', level: 'detection' }];
  const events = gatherEvents({ cameras, live, archived });
  assert.deepEqual(events.map((e) => [e.cameraId, e.label, e.at - T0, e.description]), [
    [id(1), 'Person', 0, { text: 'A man in a red jacket walks to the door', concern: 'routine', kind: 'person' }],
    [id(2), 'Motion', 60_000, { text: 'Nothing notable', concern: 'nothing', kind: 'nothing' }],
    [id(3), 'Person', 90_000, { text: 'A person tries the door handle', concern: 'alarm', kind: 'person' }],
    [id(1), 'Vehicle', 120_000, { text: 'A car stops at the gate', concern: 'routine', kind: 'vehicle' }],
    [id(1), 'Motion', 180_000, null],
  ]);
  assert.equal(gatherEvents({ cameras: [camera(1, [{ name: 'Motion', date: iso(T0) }])] }).at(0).description, null, 'the bridge’s own events have none');
});

test('isRecorded believes the archive when it says nothing was recorded', () => {
  const extent = { oldest: T0, newest: T0 + 3_600_000 };
  assert.equal(isRecorded({ at: T0 + 60_000, recorded: false }, extent), false);
  assert.equal(isRecorded({ at: T0 + 60_000, recorded: true }, extent), true);
  assert.equal(isRecorded({ at: T0 + 60_000, recorded: null }, extent), true);
  assert.equal(isRecorded({ at: T0 + 60_000, recorded: true }, null), false, 'and a camera with nothing recorded now has nothing to play');
  assert.equal(pickAction({ at: T0 + 60_000, cameraId: id(1), recorded: false }, { extent }), null);
});

test('gatherEvents keeps two events of one kind that are further apart than MERGE_MS', () => {
  const cameras = [camera(1, [{ name: 'Motion', date: iso(T0) }, { name: 'Motion', date: iso(T0 + MERGE_MS + 1) }])];
  assert.equal(gatherEvents({ cameras }).length, 2);
});

test('visibleEvents scopes to the wall’s cameras and the range, newest first', () => {
  const cameras = [
    camera(1, [{ name: 'Motion', date: iso(T0) }, { name: 'Motion', date: iso(T0 + 600_000) }]),
    camera(2, [{ name: 'Person', date: iso(T0 + 300_000) }, { name: 'Motion', date: iso(T0 - 7_200_000) }]),
    camera(3, [{ name: 'Motion', date: iso(T0 + 400_000) }]),
  ];
  const events = gatherEvents({ cameras });
  const wall = visibleEvents(events, { cameraIds: [id(1), id(2)], fromMs: T0 - 1000, toMs: T0 + 3_600_000 });
  assert.deepEqual(wall.map((e) => [e.cameraName, e.at - T0]), [['Camera 1', 600_000], ['Camera 2', 300_000], ['Camera 1', 0]]);
  const solo = visibleEvents(events, { cameraIds: [id(2)] });
  assert.deepEqual(solo.map((e) => e.at - T0), [300_000, -7_200_000]);
});

test('visibleEvents breaks a tie by camera name so the order is stable', () => {
  const cameras = [camera(2, [{ name: 'Motion', date: iso(T0) }]), camera(1, [{ name: 'Motion', date: iso(T0) }])];
  assert.deepEqual(visibleEvents(gatherEvents({ cameras }), { cameraIds: [id(1), id(2)] }).map((e) => e.cameraName), ['Camera 1', 'Camera 2']);
});

test('eventRange is the timeline’s viewport; following live leaves the end open', () => {
  const viewport = { startMs: T0, durationMs: 3_600_000 };
  assert.deepEqual(eventRange(viewport), { fromMs: T0, toMs: T0 + 3_600_000 });
  assert.deepEqual(eventRange(viewport, { following: true }), { fromMs: T0, toMs: Infinity });
  assert.deepEqual(eventRange(null), { fromMs: -Infinity, toMs: Infinity });
});

test('seekTarget plays from three seconds before, inside the recordings', () => {
  const extent = { oldest: T0, newest: T0 + 3_600_000 };
  assert.equal(PRE_ROLL_MS, 3000);
  assert.equal(seekTarget({ at: T0 + 60_000 }, extent), T0 + 57_000);
  assert.equal(seekTarget({ at: T0 + 1000 }, extent), T0);                         // clamped to the oldest recording
  assert.equal(seekTarget({ at: T0 + 3_600_000 + 10_000 }, extent), T0 + 3_600_000); // newer than the archive: its newest moment
  assert.equal(seekTarget({ at: T0 - 60_000 }, extent), null);                      // before the recordings
  assert.equal(seekTarget({ at: T0 + 3_600_000 + LIVE_GRACE_MS + 1 }, extent), null);
  assert.equal(seekTarget({ at: T0 + 60_000 }, null), null);                        // nothing recorded for that camera
  assert.equal(isRecorded({ at: T0 + 60_000 }, extent), true);
});

test('pickAction stays on the camera opened on its own and leaves it only for another camera’s event', () => {
  const extent = { oldest: T0, newest: T0 + 3_600_000 };
  const event = { at: T0 + 60_000, cameraId: id(1) };
  assert.deepEqual(pickAction(event, { extent }), { targetMs: T0 + 57_000, leaveSolo: false });
  assert.deepEqual(pickAction(event, { extent, soloId: id(1) }), { targetMs: T0 + 57_000, leaveSolo: false });
  assert.deepEqual(pickAction(event, { extent, soloId: id(2) }), { targetMs: T0 + 57_000, leaveSolo: true });
  assert.equal(pickAction(event, { extent: null }), null);
});

test('sameEvent follows an event whose time a merge moved', () => {
  const selected = { cameraId: id(1), label: 'Motion', at: T0 + 1200 };
  assert.equal(sameEvent({ cameraId: id(1), label: 'Motion', at: T0 }, selected), true);
  assert.equal(sameEvent({ cameraId: id(1), label: 'Person', at: T0 }, selected), false);
  assert.equal(sameEvent({ cameraId: id(2), label: 'Motion', at: T0 }, selected), false);
  assert.equal(sameEvent({ cameraId: id(1), label: 'Motion', at: T0 + 60_000 }, selected), false);
  assert.equal(sameEvent({ cameraId: id(1), label: 'Motion', at: T0 }, null), false);
});

test('durationText', () => {
  assert.equal(durationText(null), null);
  assert.equal(durationText(200), null);
  assert.equal(durationText(8_400), '8 s');
  assert.equal(durationText(125_000), '2 min 5 s');
  assert.equal(durationText(120_000), '2 min');
  assert.equal(durationText(3_840_000), '1 h 4 min');
});

test('batteryBadge reads status.battery defensively', () => {
  assert.equal(batteryBadge(null), null);
  assert.equal(batteryBadge(camera(1)), null);
  assert.equal(batteryBadge(camera(1, [], { battery: null })), null);
  assert.equal(batteryBadge(camera(1, [], { battery: { level: 'lots' } })), null);
  assert.deepEqual(batteryBadge(camera(1, [], { battery: { level: 64, charging: false, source: 'battery' } })), { level: 64, charging: false, low: false, text: '64%' });
  assert.deepEqual(batteryBadge(camera(1, [], { battery: { level: 12.4, charging: true } })), { level: 12, charging: true, low: true, text: '12%' });
  assert.equal(batteryBadge(camera(1, [], { battery: { level: 140 } })).level, 100);
});

// MARK: The click: the controller plays the wall from the event

function controllerWith({ playable = true } = {}) {
  const time = fakeTime(0);
  const cameras = [camera(1), camera(2)];
  const calls = [];
  const session = {
    mode: 'live', position: T0, cells: new Map(),
    setCameras(ids) { this.cells = new Map(ids.map((cid) => [cid, { coverage: { kind: 'idle' }, onChange: () => () => {} }])); },
    cell(cid) { return this.cells.get(cid); },
    focus() {}, scrub() {}, goLive() {}, togglePlay() {}, seek() {}, suspend() {}, resume() {},
    play(ms) { calls.push(['play', ms]); this.mode = 'playing'; this.position = ms; },
  };
  const listeners = new Set();
  const catalog = {
    baseMs: Number.NaN, extent: () => ({ oldest: T0 - 86_400_000, newest: T0 }),
    onChange(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    answer() { this.baseMs = T0 - 400 * 86_400_000; for (const fn of [...listeners]) fn({ kind: 'extents' }); },
  };
  const controller = createGridController({
    session, catalog, listCameras: () => cameras, subscribeCameras: () => () => {}, perPage: 4, playable,
    navigate: () => {}, replaceHash: () => {}, now: time.now, setTimer: time.setTimer, clearTimer: time.clearTimer,
    setTick: () => 0, clearTick: () => {}, defer: (fn) => fn(),
  });
  return { controller, catalog, calls };
}

test('playAt plays every tile from the time once the recordings answered', async () => {
  const { controller, catalog, calls } = controllerWith();
  const started = controller.start();
  assert.equal(controller.playAt(T0 - 60_000), false);           // not ready yet: nothing happens
  catalog.answer();
  await started;
  await settle();
  assert.equal(controller.playAt(T0 - 60_000), true);
  assert.deepEqual(calls, [['play', T0 - 60_000]]);
  assert.equal(controller.playAt(Number.NaN), false);
  controller.destroy();
});

test('playAt does nothing in a browser that cannot play recordings', async () => {
  const { controller, catalog, calls } = controllerWith({ playable: false });
  const started = controller.start();
  catalog.answer();
  await started;
  assert.equal(controller.playAt(T0 - 60_000), false);
  assert.deepEqual(calls, []);
  controller.destroy();
});

// MARK: The archive's events: what the list asks GET nvr/events for

/** The route's page: the first `limit`, never splitting a millisecond (ArchiveEventLog.page; the dev server's eventPage). */
function pageOf(sorted, limit) {
  if (sorted.length <= limit) return sorted;
  const boundary = sorted[limit - 1].start;
  if (sorted[limit].start !== boundary) return sorted.slice(0, limit);
  const newer = sorted.filter((e) => e.start > boundary);
  return newer.length ? newer : sorted.filter((e) => e.start === boundary);
}

/**
 * A fake GET nvr/events over `stored` (route shape), newest first and paged like the route, with every request kept. It refuses what the
 * route refuses (a range that is not whole milliseconds, or longer than 31 days) with a 400; `hold()` keeps the next answers until released.
 */
function fakeRoute(stored) {
  const requests = [];
  let failNext = 0;
  let failStatus = 429;
  let holding = false;
  const held = [];
  return {
    requests,
    failNext(n = 1, status = 429) { failNext = n; failStatus = status; },
    hold() { holding = true; },
    /** Answers the held requests, in order, and stops holding. */
    release() { holding = false; for (const answer of held.splice(0)) answer(); },
    get held() { return held.length; },
    load(query) {
      requests.push(query);
      if (failNext > 0) { failNext -= 1; return Promise.reject(Object.assign(new Error('failed'), { status: failStatus })); }
      if (!Number.isInteger(query.fromMs) || !Number.isInteger(query.toMs) || query.toMs - query.fromMs > ARCHIVE_MAX_RANGE_MS) {
        return Promise.reject(Object.assign(new Error('invalid'), { status: 400, field: 'to' }));
      }
      const answer = () => {
        const wanted = new Set(query.cameras.map((c) => c.toUpperCase()));
        const found = stored.filter((e) => wanted.has(e.cameraID.toUpperCase()) && e.start >= query.fromMs && e.start < query.toMs)
          .sort((a, b) => b.start - a.start || (a.id < b.id ? -1 : 1));
        const page = pageOf(found, query.limit);
        return { from: query.fromMs, to: query.toMs, serverTime: 0, more: page.length < found.length, events: page };
      };
      if (!holding) return Promise.resolve(answer());
      return new Promise((resolve) => held.push(() => resolve(answer())));
    },
  };
}

function archiveWith(stored, { start = T0, ...options } = {}) {
  const time = fakeTime(start);
  const route = fakeRoute(stored);
  let changes = 0;
  const archive = createEventArchive({ load: (q) => route.load(q), now: time.now, setTimer: time.setTimer, clearTimer: time.clearTimer, onChange: () => { changes += 1; }, ...options });
  return { archive, route, time, changes: () => changes };
}

const stored = (n, cam = 1, step = 60_000, from = T0 - 86_400_000) =>
  Array.from({ length: n }, (_, i) => ({ id: `e${cam}-${i}`, cameraID: id(cam), kind: 'Motion', start: from + i * step, end: from + i * step + 5000, recorded: true }));

test('the archive asks for the timeline’s range once and the list has its events', async () => {
  const { archive, route, changes } = archiveWith(stored(30));
  archive.want({ cameraIds: [id(1)], fromMs: T0 - 86_400_000, toMs: T0 - 86_400_000 + 3_600_000 });
  await settle();
  assert.equal(route.requests.length, 1);
  assert.deepEqual(route.requests[0], { cameras: [id(1)], fromMs: T0 - 86_400_000, toMs: T0 - 86_400_000 + 3_600_000, limit: ARCHIVE_PAGE });
  assert.equal(archive.events().length, 30);
  assert.equal(changes(), 1);
  archive.want({ cameraIds: [id(1)], fromMs: T0 - 86_400_000 + 600_000, toMs: T0 - 86_400_000 + 1_200_000 });   // inside what is loaded
  await settle();
  assert.equal(route.requests.length, 1, 'nothing more to ask');
  assert.equal(archive.hasOlder(), false);
  archive.destroy();
});

test('a range that grows asks only for the part that is missing; other cameras start again', async () => {
  const { archive, route } = archiveWith([...stored(30), ...stored(10, 2)]);
  const day = T0 - 86_400_000;
  archive.want({ cameraIds: [id(1)], fromMs: day + 600_000, toMs: day + 1_200_000 });
  await settle();
  archive.want({ cameraIds: [id(1)], fromMs: day, toMs: day + 1_200_000 });   // zoomed out to the left
  await settle();
  assert.deepEqual(route.requests.at(-1), { cameras: [id(1)], fromMs: day, toMs: day + 600_000, limit: ARCHIVE_PAGE }, 'the older part');
  archive.want({ cameraIds: [id(1)], fromMs: day, toMs: day + 3_600_000 });   // and to the right
  await settle();
  assert.deepEqual(route.requests.at(-1), { cameras: [id(1)], fromMs: day + 1_200_000 - ARCHIVE_OVERLAP_MS, toMs: day + 3_600_000, limit: ARCHIVE_PAGE },
    'the newer part, from a little before, for the ends of events that began earlier');
  assert.equal(archive.events().length, 30);
  archive.want({ cameraIds: [id(2), id(1)], fromMs: day, toMs: day + 3_600_000 });
  await settle();
  assert.deepEqual(route.requests.at(-1).cameras, [id(1), id(2)], 'the wall changed: the whole range for its cameras');
  assert.equal(archive.events().length, 40);
  archive.destroy();
});

test('a page that stops short leaves the rest for “Show more”', async () => {
  const { archive, route } = archiveWith(stored(ARCHIVE_PAGE + 50, 1, 10_000));
  const day = T0 - 86_400_000;
  archive.want({ cameraIds: [id(1)], fromMs: day, toMs: day + 86_400_000 });
  await settle();
  assert.equal(route.requests.length, 1);
  assert.equal(archive.events().length, ARCHIVE_PAGE);
  assert.equal(archive.hasOlder(), true);
  archive.want({ cameraIds: [id(1)], fromMs: day, toMs: day + 86_400_000 });
  await settle();
  assert.equal(route.requests.length, 1, 'not on its own');
  archive.loadOlder();
  await settle();
  const oldestLoaded = day + 50 * 10_000;
  assert.deepEqual(route.requests.at(-1), { cameras: [id(1)], fromMs: day, toMs: oldestLoaded, limit: ARCHIVE_PAGE });
  assert.equal(archive.events().length, ARCHIVE_PAGE + 50);
  assert.equal(archive.hasOlder(), false);
  archive.destroy();
});

test('following live asks for the newest part again every ten seconds, and a failure waits', async () => {
  const events = stored(5, 1, 60_000, T0 - 300_000);
  const { archive, route, time } = archiveWith(events);
  archive.want({ cameraIds: [id(1)], fromMs: T0 - 3_600_000, toMs: Infinity });
  await settle();
  assert.equal(route.requests.length, 1);
  assert.equal(route.requests[0].toMs, T0 + 60_000, 'an open end is a minute past now');
  events.push({ id: 'late', cameraID: id(1), kind: 'Person', start: T0 + 20_000, end: null, recorded: true });
  time.advance(ARCHIVE_REFRESH_MS / 2);
  archive.want({ cameraIds: [id(1)], fromMs: T0 - 3_600_000, toMs: Infinity });
  await settle();
  assert.equal(route.requests.length, 1, 'not yet');
  time.advance(ARCHIVE_REFRESH_MS / 2);
  await settle();
  assert.equal(route.requests.length, 2, 'the timer asked again');
  assert.equal(route.requests[1].fromMs, T0 + 60_000 - ARCHIVE_OVERLAP_MS);
  assert.ok(archive.events().some((e) => e.id === 'late'));

  route.failNext(1);
  time.advance(ARCHIVE_REFRESH_MS);
  await settle();
  assert.equal(route.requests.length, 3);
  archive.want({ cameraIds: [id(1)], fromMs: T0 - 3_600_000, toMs: Infinity });
  await settle();
  assert.equal(route.requests.length, 3, 'waits after a failure');
  time.advance(ARCHIVE_RETRY_MS);
  await settle();
  assert.equal(route.requests.length, 4, 'and tries again');
  archive.destroy();
  time.advance(ARCHIVE_REFRESH_MS * 4);
  await settle();
  assert.equal(route.requests.length, 4, 'nothing after destroy');
});

test('the archive never asks for more than the route allows', async () => {
  const { archive, route } = archiveWith([]);
  archive.want({ cameraIds: [id(1)], fromMs: T0 - 90 * 86_400_000, toMs: T0 });
  await settle();
  assert.equal(route.requests[0].toMs - route.requests[0].fromMs, ARCHIVE_MAX_RANGE_MS);
  archive.want({ cameraIds: [], fromMs: T0 - 1000, toMs: T0 });
  await settle();
  assert.equal(route.requests.length, 1, 'no cameras: no request');
  archive.want({ cameraIds: Array.from({ length: 20 }, (_, i) => `00000000-0000-4000-8000-0000000000${String(i).padStart(2, '0')}`), fromMs: T0 - 1000, toMs: T0 });
  await settle();
  assert.equal(route.requests.at(-1).cameras.length, 16);
  archive.destroy();
});

test('a range is whole milliseconds and never longer than the route allows, whatever the clock’s fraction', async () => {
  const cases = [[0.3, 40, true], [0.7, 90, true], [0.25, 40, false], [0.999, 90, false], [0.5, 31, false]];
  for (const [fraction, days, following] of cases) {
    const { archive, route } = archiveWith(stored(1, 1, 0, T0 - 3_600_000), { start: T0 + fraction });
    archive.want({ cameraIds: [id(1)], fromMs: T0 + fraction - days * 86_400_000, toMs: following ? Infinity : T0 + fraction });
    await settle();
    const [request] = route.requests;
    const label = `${days} days, ${following ? 'following' : 'looking back'}, now + ${fraction} ms`;
    assert.ok(Number.isInteger(request.fromMs) && Number.isInteger(request.toMs), label);
    assert.ok(request.toMs - request.fromMs <= ARCHIVE_MAX_RANGE_MS, `${label}: ${request.toMs - request.fromMs - ARCHIVE_MAX_RANGE_MS} ms too long`);
    assert.ok(request.toMs >= T0 + fraction, `${label}: the end is not cut`);
    assert.equal(archive.events().length, 1, `${label}: the route answered`);
    archive.destroy();
  }
});

test('a 503 (the recordings load, or their drive is away) is asked again later, never taken for a range without events', async () => {
  const { archive, route, time, changes } = archiveWith(stored(3, 1, 60_000, T0 - 600_000));
  const want = () => archive.want({ cameraIds: [id(1)], fromMs: T0 - 3_600_000, toMs: T0 });
  route.failNext(1, 503);
  want();
  await settle();
  assert.equal(route.requests.length, 1);
  assert.equal(archive.events().length, 0);
  assert.equal(changes(), 0, 'nothing to draw from a failure');
  want();
  await settle();
  assert.equal(route.requests.length, 1, 'it waits');
  time.advance(ARCHIVE_RETRY_MS);
  await settle();
  assert.equal(route.requests.length, 2);
  assert.deepEqual(route.requests[1], route.requests[0], 'the whole range again');
  assert.equal(archive.events().length, 3);
  archive.destroy();
});

test('a stretch of its own starts from nothing: what was loaded for another one goes', async () => {
  const day = T0 - 86_400_000;
  const events = stored(30, 1, 60_000, day);
  const { archive, route } = archiveWith(events);
  archive.want({ cameraIds: [id(1)], fromMs: day, toMs: day + 600_000 });
  await settle();
  assert.equal(archive.events().length, 10);
  archive.want({ cameraIds: [id(1)], fromMs: day + 1_200_000, toMs: day + 1_800_000 });
  await settle();
  assert.deepEqual(route.requests.at(-1), { cameras: [id(1)], fromMs: day + 1_200_000, toMs: day + 1_800_000, limit: ARCHIVE_PAGE });
  assert.deepEqual(archive.events().map((e) => e.id).sort(), events.slice(20).map((e) => e.id).sort());
  archive.destroy();
});

test('the cap drops the oldest and says so: what is loaded stays whole from its start, and “Show older events” brings the rest back', async () => {
  // 12 events 50 to 28 minutes ago; pages of 4; at most 10 kept besides the older pages asked for.
  const events = stored(12, 1, 120_000, T0 - 3_000_000);
  const { archive, route, time } = archiveWith(events, { keep: 10, pageSize: 4 });
  const ids = () => archive.events().map((e) => e.id).sort();
  const from = (n) => events.slice(n).map((e) => e.id);
  archive.want({ cameraIds: [id(1)], fromMs: T0 - 3_600_000, toMs: Infinity });
  await settle();
  archive.loadOlder();
  await settle();
  archive.loadOlder();
  await settle();
  assert.deepEqual(ids(), from(0).sort(), 'three pages asked for: all twelve, the cap does not take them back');
  assert.equal(archive.hasOlder(), false);

  // Three more arrive while following live: the newer part brings them, and the three oldest go.
  for (const offset of [5_000, 10_000, 15_000]) events.push({ id: `new-${offset}`, cameraID: id(1), kind: 'Motion', start: T0 + offset, end: null, recorded: true });
  time.advance(ARCHIVE_REFRESH_MS);
  await settle();
  assert.equal(route.requests.at(-1).fromMs, T0 + 60_000 - ARCHIVE_OVERLAP_MS, 'the newer part');
  assert.deepEqual(ids(), from(3).sort());
  const oldestKept = Math.min(...archive.events().map((e) => e.start));
  assert.ok(events.filter((e) => e.start >= oldestKept).every((e) => archive.events().some((l) => l.id === e.id)), 'no hole after the oldest kept');
  assert.equal(archive.hasOlder(), true, 'the list offers the dropped ones again');

  archive.loadOlder();
  await settle();
  assert.deepEqual(route.requests.at(-1), { cameras: [id(1)], fromMs: T0 - 3_600_000, toMs: oldestKept, limit: 4 });
  assert.deepEqual(ids(), from(0).sort(), 'asked for: they stay');
  assert.equal(archive.hasOlder(), false);
  archive.destroy();
});

/** Every answer in: a newer part that stops short asks for the rest at once, one page after another. */
async function settleAll() {
  for (let i = 0; i < 20; i += 1) await settle();
}

/** 15 events of camera 1 in the last hour, then `count` events of cameras 1 and 2 in under half a minute after T0 (a busy wall). */
function burstAfter(count) {
  const events = stored(15, 1, 180_000, T0 - 3_000_000);
  const burst = Array.from({ length: count }, (_, i) =>
    ({ id: `burst-${i}`, cameraID: id(1 + (i % 2)), kind: 'Motion', start: T0 + 500 + Math.floor((i * 29_000) / count), end: null, recorded: true }));
  return { events, burst };
}

test('a burst of more than a page between two refreshes is loaded whole while following live, with no click and no hole', async () => {
  for (const count of [30, 45, 100]) {
    const { events, burst } = burstAfter(count);
    const { archive, route, time } = archiveWith(events, { pageSize: 20 });
    const missing = () => events.filter((e) => !archive.events().some((l) => l.id === e.id)).length;
    const want = () => archive.want({ cameraIds: [id(1), id(2)], fromMs: T0 - 3_600_000, toMs: Infinity });
    want();
    await settleAll();
    assert.equal(archive.events().length, 15);
    events.push(...burst);
    time.advance(ARCHIVE_REFRESH_MS);
    await settleAll();
    const [, newer, gap] = route.requests;
    assert.deepEqual([newer.fromMs, newer.toMs], [T0 + 60_000 - ARCHIVE_OVERLAP_MS, T0 + ARCHIVE_REFRESH_MS + 60_000], `${count}: the newer part`);
    assert.equal(gap.fromMs, newer.fromMs, `${count}: then what it did not reach, at once`);
    assert.ok(gap.toMs < newer.toMs && gap.toMs > T0, `${count}: up to the oldest event of the newer page`);
    assert.equal(missing(), 0, `${count}: every event, with no click`);
    assert.equal(archive.hasOlder(), false, `${count}: nothing older to offer`);
    for (let refresh = 0; refresh < 3; refresh += 1) {
      time.advance(ARCHIVE_REFRESH_MS);
      want();
      await settleAll();
      assert.equal(missing(), 0, `${count}: still every event after refresh ${refresh + 1}`);
      assert.equal(archive.events().length, events.length);
      assert.equal(archive.hasOlder(), false);
    }
    archive.destroy();
  }
});

test('the gap a burst left is asked again after a failure, before anything else', async () => {
  const { events, burst } = burstAfter(30);
  const { archive, route, time } = archiveWith(events, { pageSize: 20 });
  const missing = () => events.filter((e) => !archive.events().some((l) => l.id === e.id)).length;
  archive.want({ cameraIds: [id(1), id(2)], fromMs: T0 - 3_600_000, toMs: Infinity });
  await settleAll();
  events.push(...burst);
  route.hold();
  time.advance(ARCHIVE_REFRESH_MS);   // the newer part, on its way
  await settle();
  assert.equal(route.held, 1);
  route.failNext(1, 503);             // and the gap after it fails
  route.release();
  await settleAll();
  assert.equal(route.requests.length, 3);
  assert.equal(missing(), 10, 'the 10 oldest of the burst wait for the next try');
  time.advance(ARCHIVE_RETRY_MS);
  await settleAll();
  assert.deepEqual(route.requests[3], route.requests[2], 'the gap again, not the newer part');
  assert.equal(missing(), 0);
  archive.destroy();
});

test('a burst bigger than the cap keeps the newest events whole and offers the rest as older', async () => {
  const { events, burst } = burstAfter(45);
  const { archive, time } = archiveWith(events, { pageSize: 20, keep: 30 });
  archive.want({ cameraIds: [id(1), id(2)], fromMs: T0 - 3_600_000, toMs: Infinity });
  await settleAll();
  events.push(...burst);
  time.advance(ARCHIVE_REFRESH_MS);
  await settleAll();
  const noHole = () => {
    const oldest = Math.min(...archive.events().map((e) => e.start));
    return events.filter((e) => e.start >= oldest).every((e) => archive.events().some((l) => l.id === e.id));
  };
  assert.deepEqual(archive.events().map((e) => e.id).sort(), burst.slice(15).map((e) => e.id).sort(), 'the newest 30');
  assert.ok(noHole(), 'nothing missing after the oldest kept');
  assert.equal(archive.hasOlder(), true);
  archive.loadOlder();
  await settleAll();
  assert.ok(burst.every((e) => archive.events().some((l) => l.id === e.id)), 'the older page brings the rest of the burst');
  assert.ok(noHole());
  archive.destroy();
});

test('an answer for cameras the list no longer shows is not used, even when the same cameras are back by then', async () => {
  const { archive, route, time } = archiveWith([...stored(5, 1, 60_000, T0 - 600_000), ...stored(5, 2, 60_000, T0 - 600_000)]);
  const want = (cam) => archive.want({ cameraIds: [id(cam)], fromMs: T0 - 3_600_000, toMs: Infinity });
  want(1);
  await settle();
  assert.equal(route.requests.length, 1);
  route.hold();
  time.advance(ARCHIVE_REFRESH_MS);   // the newer part, on its way
  await settle();
  assert.equal(route.held, 1);
  want(2);
  want(1);
  route.release();
  await settle();
  assert.equal(route.requests.length, 3);
  assert.deepEqual(route.requests[2], { cameras: [id(1)], fromMs: T0 - 3_600_000, toMs: T0 + ARCHIVE_REFRESH_MS + 60_000, limit: ARCHIVE_PAGE },
    'the whole range again, for the cameras shown now');
  assert.equal(archive.events().length, 5);
  archive.destroy();
});

test('the route’s pages never split a millisecond, so paging below the oldest start loses nothing', async () => {
  // A ring with its motion and person at one moment, as the router stamps one publication, between other events.
  const events = [
    ...stored(3, 1, 60_000, T0 - 600_000),
    ...['Doorbell ring', 'Motion', 'Person'].map((kind, i) => ({ id: `ring-${i}`, cameraID: id(1), kind, start: T0 - 300_000, end: T0 - 300_000, recorded: true })),
    ...stored(3, 2, 60_000, T0 - 200_000),
  ];
  for (const pageSize of [1, 2, 3, 4, 5]) {
    const { archive } = archiveWith(events, { pageSize });
    archive.want({ cameraIds: [id(1), id(2)], fromMs: T0 - 3_600_000, toMs: T0 });
    await settle();
    for (let i = 0; i < 12 && archive.hasOlder(); i += 1) { archive.loadOlder(); await settle(); }
    assert.equal(archive.events().length, events.length, `pages of ${pageSize}`);
    archive.destroy();
  }
});

// MARK: The list: the keyboard and "Show more"

/** The few DOM parts the list's focus handling needs, on top of the fake browser: focus, contains, querySelector by tag, class and data-*. */
function withFocus(document) {
  const proto = Object.getPrototypeOf(document.createElement('div'));
  const saved = { focus: proto.focus, contains: proto.contains, querySelector: proto.querySelector };
  let focused = null;
  const matches = (node, selector) => {
    const parts = /^([a-z]+)?((?:\.[\w-]+)*)(?:\[data-([\w-]+)="([^"]*)"\])?$/.exec(selector);
    if (!parts || !node.tagName) return false;
    const [, tag, classes, data, value] = parts;
    if (tag && node.localName !== tag) return false;
    if (!classes.split('.').filter(Boolean).every((name) => node.classList.contains(name))) return false;
    return data === undefined || node.dataset[data.replace(/-(\w)/g, (_, c) => c.toUpperCase())] === value;
  };
  proto.focus = function focus() { focused = this; };
  proto.contains = function contains(node) { for (let n = node; n; n = n.parentNode) if (n === this) return true; return false; };
  proto.querySelector = function querySelector(selector) {
    for (const child of this.childNodes) {
      if (matches(child, selector)) return child;
      const inner = child.tagName ? child.querySelector(selector) : null;
      if (inner) return inner;
    }
    return null;
  };
  // Like a browser: a focused element that left the page leaves the focus on the body.
  Object.defineProperty(document, 'activeElement', { configurable: true, get: () => (focused?.isConnected ? focused : document.body) });
  return () => Object.assign(proto, saved);
}

test('“Show older events” keeps the keyboard on the button while the older page loads, then moves it to the first new row', async () => {
  const browser = installFakeBrowser();
  const unfocus = withFocus(browser.document);
  const { store } = await import('../web/js/store.js');
  const { createWallEvents } = await import('../web/js/screens/wall-events.js');
  try {
    store.cameras.set(id(1), camera(1));
    const route = fakeRoute(stored(ARCHIVE_PAGE + 50, 1, 10_000, T0 - 86_400_000));
    const context = { cameraIds: [id(1)], range: { fromMs: T0 - 86_400_000, toMs: T0 }, extentOf: () => ({ oldest: T0 - 2 * 86_400_000, newest: T0 }) };
    const wall = createWallEvents({ now: () => T0, loadEvents: (query) => route.load(query), onChange: () => wall.update(context) });
    browser.document.append(wall.list);
    wall.update(context);
    await settle();
    const active = () => browser.document.activeElement;

    const showMore = wall.list.querySelector('button.mon-more');
    assert.equal(showMore?.textContent, `Show ${PAGE_ROWS} more`);
    showMore.focus();
    showMore.click();
    assert.equal(active().dataset.index, String(PAGE_ROWS), 'the rows that were loaded already: the first new one');

    const older = wall.list.querySelector('button.mon-more');
    assert.equal(older?.textContent, 'Show older events');
    older.focus();
    route.hold();
    older.click();
    await settle();
    assert.equal(route.held, 1, 'the older page is on its way');
    assert.ok(active().classList?.contains('mon-more') && wall.list.contains(active()), 'the keyboard stays on the button, not on the page');

    route.release();
    await settle();
    assert.equal(active().dataset.index, String(ARCHIVE_PAGE), 'then the first of the older rows');
    wall.destroy();
  } finally {
    store.cameras.clear();
    unfocus();
    browser.restore();
  }
});

// MARK: The list: AI descriptions

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));

/** A wall's events list over `route`, for camera 1 and the last hour, following live; `clock.ms` is the server's clock. */
async function wallWith(route) {
  const browser = installFakeBrowser();
  const unfocus = withFocus(browser.document);
  const { store } = await import('../web/js/store.js');
  const { createWallEvents } = await import('../web/js/screens/wall-events.js');
  store.cameras.set(id(1), camera(1));
  const clock = { ms: T0 };
  const context = { cameraIds: [id(1)], range: { fromMs: T0 - 3_600_000, toMs: Infinity }, extentOf: () => ({ oldest: T0 - 86_400_000, newest: T0 }) };
  const wall = createWallEvents({ now: () => clock.ms, loadEvents: (query) => route.load(query), onChange: () => wall.update(context) });
  browser.document.append(wall.list);
  wall.update(context);
  await settle();
  return {
    wall, clock, context,
    rows: () => byClass(wall.list, 'mon-event'),
    done() { wall.destroy(); store.cameras.clear(); unfocus(); browser.restore(); },
  };
}

test('a row shows the summary under the kind; alarm red, unusual amber, nothing dimmed', async () => {
  const said = (summary, kind, concern) => ({ summary, kind, concern });
  const event = (n, description, kind = 'Person') => ({ id: `ai-${n}`, cameraID: id(1), kind, start: T0 - n * 60_000, end: null, recorded: true, description });
  const route = fakeRoute([
    event(1, said('A person tries the door handle', 'person', 'alarm')),
    event(2, said('A van parks across the driveway', 'vehicle', 'unusual'), 'Vehicle'),
    event(3, said('A man in a red jacket walks to the door', 'person', 'routine')),
    event(4, said('Leaves blow across the porch', 'nothing', 'routine'), 'Motion'),
    event(5, null, 'Motion'),
    event(6, said('<img src=x onerror=alert(1)>', 'other', 'routine'), 'Motion'),
  ]);
  const wall = await wallWith(route);
  try {
    const rows = wall.rows();
    assert.equal(rows.length, 6);
    const shown = rows.map((row) => {
      const parts = row.childNodes.filter((node) => node.tagName);
      const kind = parts.findIndex((node) => node.classList.contains('mon-event-kind'));
      const summary = parts.findIndex((node) => node.classList.contains('mon-event-ai'));
      if (summary >= 0) assert.ok(summary > kind, 'the summary comes after the kind');
      return summary < 0 ? null : [parts[summary].textContent, parts[summary].dataset.concern];
    });
    assert.deepEqual(shown, [
      ['A person tries the door handle', 'alarm'],
      ['A van parks across the driveway', 'unusual'],
      ['A man in a red jacket walks to the door', 'routine'],
      ['Nothing notable', 'nothing'],
      null,
      ['<img src=x onerror=alert(1)>', 'routine'],
    ]);
    const hostile = byClass(rows[5], 'mon-event-ai')[0];
    assert.ok(hostile.childNodes.every((node) => !node.tagName), 'the words stay words: no element is made of them');
    assert.match(rows[0].getAttribute('aria-label'), /, alarm: A person tries the door handle$/, 'a screen reader hears it, and how much it matters');
    assert.match(rows[1].getAttribute('aria-label'), /, unusual: A van parks across the driveway$/);
    assert.match(rows[2].getAttribute('aria-label'), /, A man in a red jacket walks to the door$/);
    assert.equal(byClass(rows[0], 'mon-event-ai')[0].getAttribute('style'), null, 'no inline style');
  } finally {
    wall.done();
  }

  // The colours: the page's danger and warning, kept dark on the wall (it is dark whatever the page's appearance); routine has no mark.
  const css = readFileSync(new URL('../web/monitor.css', import.meta.url), 'utf8');
  const style = readFileSync(new URL('../web/style.css', import.meta.url), 'utf8');
  /** The declarations of every rule with a selector that starts with `selector` (in a list too), in order. */
  const rule = (selector) => [...css.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{([^}]*)\}/g)]
    .filter(([, selectors]) => selectors.split(',').some((part) => part.trim().startsWith(selector)))
    .map(([, , body]) => body).join(' ');
  assert.match(rule('.mon-event-ai[data-concern="alarm"]'), /var\(--danger\)/);
  assert.match(rule('.mon-event-ai[data-concern="unusual"]'), /var\(--warning\)/);
  assert.match(rule('.mon-event-ai[data-concern="nothing"]'), /color:\s*var\(--mon-dim\)/);
  assert.equal(rule('.mon-event-ai[data-concern="routine"]'), '', 'routine: no mark');
  const darkOf = (name) => new RegExp(`${name}:\\s*(#[0-9a-f]{6})`, 'i').exec(style)[1];
  const wallBlock = /\.monitor \{([^}]*)\}/.exec(css)[1];
  assert.match(wallBlock, new RegExp(`--danger:\\s*${darkOf('--danger')}`, 'i'), 'the wall keeps the dark red in a light page');
  assert.match(wallBlock, new RegExp(`--warning:\\s*${darkOf('--warning')}`, 'i'));
});

test('a description that arrives later updates the row in place', async () => {
  const stored = [{ id: 'later', cameraID: id(1), kind: 'Person', start: T0 - 20_000, end: null, recorded: true, description: null }];
  const route = fakeRoute(stored);
  const wall = await wallWith(route);
  try {
    assert.equal(wall.rows().length, 1);
    assert.equal(byClass(wall.wall.list, 'mon-event-ai').length, 0, 'not described yet');
    // The describer wrote its line a few seconds later; the list asks for the newest part again, from a little before.
    stored[0] = { ...stored[0], description: { summary: 'A courier leaves a parcel at the door', kind: 'delivery', concern: 'routine' } };
    wall.clock.ms += 61_000;
    wall.wall.update(wall.context);
    await settle();
    assert.equal(route.requests.length, 2, 'the newer part was asked for again');
    const rows = wall.rows();
    assert.equal(rows.length, 1, 'the same row, no new one');
    assert.equal(byClass(rows[0], 'mon-event-ai')[0]?.textContent, 'A courier leaves a parcel at the door');
    assert.match(rows[0].getAttribute('aria-label'), /A courier leaves a parcel at the door$/);
  } finally {
    wall.done();
  }
});
