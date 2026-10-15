// catalog.js: the poll, the server's clock, the time base, the extents and the JSON calls.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError } from '../web/js/api.js';
import { createCatalog } from '../web/js/nvr/catalog.js';
import { createFetcher } from '../web/js/nvr/fetcher.js';
import { FILE_A, FILE_B, MIME, ORIGIN, createArchive, createFakeApi } from './player-fakes/fake-archive.mjs';
import { createFakeTimers } from './player-fakes/fake-timers.mjs';

const SERVER_AT_ZERO = ORIGIN + 3_600_000;
const FOUR_HUNDRED_DAYS = 400 * 86_400_000;

function setup({ latency, localBehindMs = 2500, intervalMs } = {}) {
  const timers = createFakeTimers();
  const archive = createArchive({
    timers,
    files: [{ key: FILE_A, startMs: ORIGIN, parts: 30, gop: 4 }, { key: FILE_B, startMs: ORIGIN + 80_000, parts: 10, gop: 1 }],
  });
  const api = createFakeApi({ archives: [archive], timers, latency });
  const fetcher = createFetcher({ get: api.get, getBytes: api.getBytes, sleep: timers.sleep });
  // The page's own clock runs `localBehindMs` behind the server's.
  const catalog = createCatalog({ fetcher, now: () => SERVER_AT_ZERO - localBehindMs + timers.now(), perf: timers.now, timers, intervalMs });
  return { timers, archive, api, fetcher, catalog };
}

const polls = (api) => api.requests('nvr/cameras').filter((entry) => entry.path === 'nvr/cameras');

describe('polling', () => {
  it('polls at once and then every second while started, and stops when stopped', async () => {
    const { catalog, api, timers } = setup();
    catalog.start();
    await timers.advance(1);
    assert.equal(polls(api).length, 1);
    await timers.advance(2200);
    assert.equal(polls(api).length, 3);
    catalog.stop();
    await timers.advance(10_000);
    assert.equal(polls(api).length, 3);
  });

  it('is reference counted', async () => {
    const { catalog, api, timers } = setup();
    catalog.start();
    catalog.start();
    await timers.advance(100);
    assert.equal(polls(api).length, 1, 'a second start does not poll again');
    catalog.stop();
    await timers.advance(3000);
    assert.ok(polls(api).length >= 3, 'still polling after one stop');
    catalog.stop();
    const count = polls(api).length;
    await timers.advance(10_000);
    assert.equal(polls(api).length, count);
    catalog.start();
    await timers.advance(100);
    assert.equal(polls(api).length, count + 1);
    catalog.stop();
  });

  it('never has two polls in flight, even when an answer takes longer than the interval', async () => {
    const { catalog, api, timers } = setup({ latency: (kind) => (kind === 'json' ? 3000 : 25) });
    catalog.start();
    await timers.advance(10_000);
    catalog.stop();
    assert.equal(api.stats().worst.json, 1);
    assert.equal(polls(api).length, 3);          // at 0, 4000 and 8000
  });

  it('backs off 2, 4, 8, 8 seconds after failures and recovers', async () => {
    const { catalog, api, timers } = setup();
    api.failWhen('nvr/cameras', () => new ApiError(500, 'error', 'Broken.'), { times: 4 });
    catalog.start();
    await timers.advance(1);
    const starts = [];
    for (let i = 0; i < 40_000; i += 100) {
      await timers.advance(100);
      const count = polls(api).length;
      if (starts.length < count) starts.push(polls(api).at(-1).startedAt);
    }
    catalog.stop();
    const gaps = starts.slice(1).map((time, i) => time - starts[i] - 10);      // minus the 10 ms the fake takes to answer
    assert.deepEqual(gaps.slice(0, 5), [2000, 4000, 8000, 8000, 1000]);
    assert.notEqual(catalog.version, null, 'the fifth poll succeeded');
  });
});

describe('time base and clock', () => {
  it('the base is the first server time minus 400 days, and it never moves', async () => {
    const { catalog, api, timers } = setup();
    assert.equal(catalog.baseMs, undefined);
    catalog.start();
    await timers.advance(1);
    assert.equal(catalog.baseMs, undefined, 'the first answer is still on its way');
    await timers.advance(20);
    const first = catalog.baseMs;
    assert.equal(first, SERVER_AT_ZERO + 10 - FOUR_HUNDRED_DAYS);
    await timers.advance(5000);
    assert.equal(catalog.baseMs, first);
    catalog.stop();
  });

  it('ready() resolves with the first answer of any call, even a plan', async () => {
    const { catalog, timers } = setup();
    let ready = false;
    catalog.ready().then(() => { ready = true; });
    await timers.advance(50);
    assert.equal(ready, false);
    const plan = catalog.plan('CAM-1', ORIGIN + 13_000);
    await timers.advance(50);
    await plan;
    assert.equal(ready, true);
    assert.equal(catalog.baseMs, SERVER_AT_ZERO + 60 - FOUR_HUNDRED_DAYS + 0, 'the plan was answered at 60 ms: 50 for the wait, 10 for latency');
  });

  it('ready() rejects with the last error after three polls in a row failed before any answer, and a later success still sets the base', async () => {
    const { catalog, api, timers } = setup();
    api.failWhen('nvr/cameras', () => new ApiError(500, 'error', 'Broken.'), { times: 3 });
    const waiting = catalog.ready().then(() => 'ready', (error) => error.code);
    catalog.start();
    await timers.advance(7000);                       // polls at 0, 2 and 6 s fail
    assert.equal(await waiting, 'error');
    assert.equal(catalog.baseMs, undefined);
    await timers.advance(10_000);                     // the fourth poll comes 8 s later
    assert.equal(catalog.baseMs !== undefined, true, 'the fourth poll succeeded');
    await catalog.ready();
    catalog.stop();
  });

  it('serverNow() follows the server although the local clock is 2.5 s behind', async () => {
    const { catalog, timers } = setup();
    catalog.start();
    await timers.advance(2000);
    const truth = SERVER_AT_ZERO + timers.now();
    assert.ok(Math.abs(catalog.serverNow() - truth) <= 10, `off by ${catalog.serverNow() - truth} ms`);
    catalog.stop();
  });

  it('uses the answer with the shortest round trip among the last five', async () => {
    const trips = [400, 10, 300, 300, 300, 300, 300, 300];
    let call = 0;
    const { catalog, timers } = setup({ latency: (kind) => (kind === 'json' ? trips[call++] ?? 300 : 25) });
    catalog.start();
    await timers.advance(1000);                   // the first answer (400 ms round trip) is in
    const roughError = Math.abs(catalog.serverNow() - (SERVER_AT_ZERO + timers.now()));
    assert.ok(roughError > 150, `a 400 ms trip leaves ${roughError} ms of doubt`);
    await timers.advance(2000);                   // the 10 ms trip is in
    const sharp = Math.abs(catalog.serverNow() - (SERVER_AT_ZERO + timers.now()));
    assert.ok(sharp <= 10, `the 10 ms trip should win, off by ${sharp}`);
    await timers.advance(8000);                   // five slower answers later it has aged out
    const aged = Math.abs(catalog.serverNow() - (SERVER_AT_ZERO + timers.now()));
    assert.ok(aged > 100, `the old best sample should be gone, off by ${aged}`);
    catalog.stop();
  });
});

describe('extents and changes', () => {
  it('exposes extent(), version and reports only what changed', async () => {
    const { catalog, archive, timers } = setup();
    const events = [];
    const off = catalog.onChange((event) => events.push(event.kind));
    catalog.start();
    await timers.advance(50);
    assert.deepEqual(catalog.extent('CAM-1'), { oldest: ORIGIN, newest: ORIGIN + 100_000, typicalGOP: 8 });
    assert.equal(catalog.extent('cam-1').newest, ORIGIN + 100_000, 'ids compare without regard to case');
    assert.equal(catalog.extent('NOPE'), null);
    assert.equal(catalog.version, 1);
    assert.deepEqual(events, ['extents', 'version', 'phase']);
    await timers.advance(3000);
    assert.deepEqual(events, ['extents', 'version', 'phase'], 'nothing changed, nothing announced');
    archive.append(2);
    await timers.advance(1100);
    assert.deepEqual(events, ['extents', 'version', 'phase', 'extents', 'version']);
    assert.equal(catalog.extent('CAM-1').newest, ORIGIN + 104_000);
    off();
    archive.removeBefore(ORIGIN + 40_000);
    await timers.advance(1100);
    assert.equal(events.length, 5, 'an unsubscribed listener hears nothing');
    assert.equal(catalog.extent('CAM-1').oldest, ORIGIN + 40_000);
    catalog.stop();
  });

  it('the first answer is announced as a change even when no camera has a recording', async () => {
    const timers = createFakeTimers();
    const archive = createArchive({ timers, files: [] });
    const api = createFakeApi({ archives: [archive], timers });
    const fetcher = createFetcher({ get: api.get, getBytes: api.getBytes, sleep: timers.sleep });
    const catalog = createCatalog({ fetcher, now: () => SERVER_AT_ZERO + timers.now(), perf: timers.now, timers });
    const events = [];
    catalog.onChange((event) => events.push(event.kind));
    catalog.start();
    await timers.advance(2500);
    catalog.stop();
    assert.deepEqual(events, ['extents', 'version', 'phase']);
    assert.equal(catalog.extent('CAM-1'), null);
  });

  it('a listener that throws does not stop the others', async () => {
    const { catalog, timers } = setup();
    const heard = [];
    const realError = console.error;
    console.error = () => {};
    catalog.onChange(() => { throw new Error('boom'); });
    catalog.onChange((event) => heard.push(event.kind));
    catalog.start();
    await timers.advance(50);
    console.error = realError;
    catalog.stop();
    assert.deepEqual(heard, ['extents', 'version', 'phase']);
  });
});

describe('phase', () => {
  it('starts as starting, is ready after an answer, and each change is announced once', async () => {
    const { catalog, timers } = setup();
    const kinds = [];
    catalog.onChange((event) => kinds.push(event.kind));
    assert.equal(catalog.phase, 'starting');
    catalog.start();
    await timers.advance(3000);
    assert.equal(catalog.phase, 'ready');
    assert.equal(kinds.filter((kind) => kind === 'phase').length, 1);
    catalog.stop();
  });

  it('is loading while the store answers 503 archive_unavailable with a Retry-After, then ready', async () => {
    const { catalog, api, timers } = setup();
    api.failWhen('nvr/cameras', () => new ApiError(503, 'archive_unavailable', 'Loading.', null, { retryAfter: 0 }), { times: 4 });
    catalog.start();
    await timers.advance(100);
    assert.equal(catalog.phase, 'loading', 'one poll (four tries) failed');
    await timers.advance(5000);
    assert.equal(catalog.phase, 'ready');
    catalog.stop();
  });

  it('is unavailable for a 503 without Retry-After (no archive), and after three failed polls in a row; ready again on an answer', async () => {
    const none = setup();
    none.api.failWhen('nvr/cameras', () => new ApiError(503, 'archive_unavailable', 'No archive.'), { times: 100 });
    none.catalog.start();
    await none.timers.advance(10_000);
    assert.equal(none.catalog.phase, 'unavailable');
    none.catalog.stop();

    const broken = setup();
    broken.api.failWhen('nvr/cameras', () => new ApiError(500, 'error', 'Broken.'), { times: 3 });
    broken.catalog.start();
    await broken.timers.advance(5000);
    assert.equal(broken.catalog.phase, 'starting', 'two failures are not enough');
    await broken.timers.advance(3000);
    assert.equal(broken.catalog.phase, 'unavailable');
    await broken.timers.advance(10_000);
    assert.equal(broken.catalog.phase, 'ready');
    broken.catalog.stop();
  });
});

describe('the JSON calls', () => {
  it('plan() asks for the time and the look-ahead, floors the time and keeps what it learns about files', async () => {
    const { catalog, api, timers } = setup();
    const pending = catalog.plan('CAM-1', ORIGIN + 13_000.9, { ahead: 1, key: 'plan:CAM-1' });
    await timers.advance(50);
    const plan = await pending;
    assert.equal(api.log.at(-1).path, `nvr/cameras/CAM-1/fragments?at=${ORIGIN + 13_000}&ahead=1`);
    assert.equal(plan.found, true);
    assert.deepEqual(catalog.file(FILE_A), { mime: MIME, width: 2688, height: 1520, anchor: plan.files[FILE_A].anchor, initId: `${FILE_A}.4`, sound: false });
    assert.equal(catalog.file('ffffffffffff'), undefined);
    const defaulted = catalog.plan('CAM-1', ORIGIN + 13_000);
    await timers.advance(50);
    await defaulted;
    assert.ok(api.log.at(-1).path.endsWith('&ahead=2'));
  });

  it('plan() refuses a time the server would refuse, without asking', async () => {
    const { catalog, api } = setup();
    await assert.rejects(catalog.plan('CAM-1', Number.NaN), RangeError);
    await assert.rejects(catalog.plan('CAM-1', 5), RangeError);
    await assert.rejects(catalog.plan('CAM-1', 4_200_000_000_000), RangeError);
    assert.equal(api.log.length, 0);
  });

  it('after() asks for the parts after a fragment', async () => {
    const { catalog, api, timers } = setup();
    const pending = catalog.after('CAM-1', `${FILE_A}.28`, { limit: 3 });
    await timers.advance(50);
    const answer = await pending;
    assert.equal(api.log.at(-1).path, `nvr/cameras/CAM-1/fragments?after=${FILE_A}.28&limit=3`);
    assert.deepEqual(answer.parts.map((p) => p.id), [`${FILE_A}.29`, `${FILE_B}.0`, `${FILE_B}.1`]);
    assert.ok(catalog.file(FILE_B));
  });

  it('after() with an id the server no longer has fails with code gone', async () => {
    const { catalog, archive, timers } = setup();
    archive.removeBefore(ORIGIN + 20_000);
    const pending = catalog.after('CAM-1', `${FILE_A}.1`).catch((error) => error);
    await timers.advance(50);
    assert.equal((await pending).code, 'gone');
  });

  it('activity() joins the cameras and passes whole numbers', async () => {
    const { catalog, api, timers } = setup();
    const pending = catalog.activity({ cameras: ['CAM-1', 'CAM-2'], fromMs: ORIGIN + 0.4, binMs: 60_000, bins: 24, key: 'activity' });
    await timers.advance(50);
    const answer = await pending;
    assert.equal(api.log.at(-1).path, `nvr/activity?cameras=CAM-1,CAM-2&from=${ORIGIN}&binMs=60000&bins=24`);
    assert.equal(answer.byCamera['CAM-1'].level.length, 24);
  });

  it('remembers at most 256 files, dropping the least recently used', async () => {
    const answers = [];
    for (let i = 0; i < 300; i += 1) answers.push({ serverTime: SERVER_AT_ZERO, found: false, files: { [`f${String(i).padStart(11, '0')}`]: { mime: MIME, width: 1, height: 1, anchor: 1, initId: 'x.0', sound: false } } });
    let next = 0;
    const catalog = createCatalog({ fetcher: { json: async () => answers[next++] }, now: Date.now, perf: () => 0, timers: createFakeTimers() });
    for (let i = 0; i < 300; i += 1) await catalog.plan('CAM-1', ORIGIN);
    assert.equal(catalog.file('f00000000000'), undefined);
    assert.equal(catalog.file('f00000000043'), undefined);
    assert.ok(catalog.file('f00000000044'));
    assert.ok(catalog.file('f00000000299'));
  });
});
