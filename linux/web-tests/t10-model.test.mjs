import test from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_PRESET, RETRY_MS, REFRESH_MS, ZOOM_KEY, createTimelineModel } from '../web/js/nvr/timeline/model.js';

const MIN = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;
const CAM = 'AAAAAAAA-0000-4000-8000-000000000001';
const T0 = Date.UTC(2026, 9, 14, 20, 0, 0);

/** Everything the model touches, with time under the test's control. */
function rig({ mode = 'live', stored = null, extent = { oldest: T0 - 3 * DAY, newest: T0 - 1000, typicalGOP: 2 } } = {}) {
  const clock = { server: T0, perf: 0 };
  const timers = [];
  const store = new Map(stored ? [['cb.nvr.zoom', stored]] : []);
  const sessionListeners = new Set();
  const catalogListeners = new Set();
  const requests = [];
  const session = {
    mode,
    position: mode === 'live' ? T0 - 6000 : T0 - 2 * HOUR,
    onChange(fn) { sessionListeners.add(fn); return () => sessionListeners.delete(fn); },
  };
  const catalog = {
    extents: new Map(extent ? [[CAM, extent]] : []),
    serverNow: () => clock.server,
    extent(id) { return this.extents.get(id) ?? null; },
    onChange(fn) { catalogListeners.add(fn); return () => catalogListeners.delete(fn); },
    activity(request) {
      return new Promise((resolve, reject) => requests.push({ request, resolve, reject }));
    },
  };
  const model = createTimelineModel({
    session, catalog, widthPx: 800,
    storage: { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) },
    setTimer: (fn, ms) => { const timer = { fn, ms, at: clock.perf + ms, live: true }; timers.push(timer); return timer; },
    clearTimer: (timer) => { if (timer) timer.live = false; },
    perf: () => clock.perf,
  });
  const answerFor = (request, { complete = true, level = 5000 } = {}) => ({
    from: request.fromMs, binMs: request.binMs, bins: request.bins, serverTime: clock.server, catalogVersion: 1,
    byCamera: { [CAM]: { typical: 2000, complete, coverage: new Array(request.bins).fill(100), level: new Array(request.bins).fill(level) } },
  });
  const advance = (ms) => {
    clock.perf += ms; clock.server += ms;
    for (const timer of timers.filter((t) => t.live && t.at <= clock.perf)) { timer.live = false; timer.fn(); }
  };
  const flush = () => new Promise((resolve) => setImmediate(resolve));
  return {
    clock, model, session, catalog, requests, timers, store, answerFor, advance, flush,
    setMode(next) { session.mode = next; sessionListeners.forEach((fn) => fn()); },
    catalogChanged() { catalogListeners.forEach((fn) => fn({ kind: 'extents' })); },
    async answer(index = requests.length - 1, options) { requests[index].resolve(this.answerFor(requests[index].request, options)); await flush(); },
  };
}

test('the remembered preset is used, a bad value falls back to one hour, and a choice is remembered', () => {
  const remembered = rig({ stored: '6h' });
  remembered.model.setCameras([CAM]);
  assert.equal(remembered.model.preset, '6h');
  assert.equal(remembered.model.viewport.durationMs, 6 * HOUR * 1.04);
  const bad = rig({ stored: 'banana' });
  assert.equal(bad.model.preset, DEFAULT_PRESET);
  bad.model.setCameras([CAM]);
  bad.model.select('24h');
  assert.equal(bad.store.get(ZOOM_KEY), '24h');
  assert.equal(bad.model.viewport.durationMs, DAY * 1.04);
});

test('storage that throws is survivable', () => {
  const model = createTimelineModel({
    session: { mode: 'live', position: T0 - 6000, onChange: () => () => {} },
    catalog: { serverNow: () => T0, extent: () => null, onChange: () => () => {}, activity: () => new Promise(() => {}) },
    storage: { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); } },
  });
  assert.equal(model.preset, DEFAULT_PRESET);
  model.select('6h');                                  // the write fails quietly
  assert.equal(model.preset, '6h');
});

test('with nothing recorded the model is empty and asks for nothing', async () => {
  const r = rig({ extent: null });
  r.model.setCameras([CAM]);
  assert.equal(r.model.empty, true);
  assert.equal(r.model.oldestMs, null);
  r.model.tick();
  assert.equal(r.requests.length, 0);
  r.catalog.extents.set(CAM, { oldest: T0 - HOUR, newest: T0, typicalGOP: 2 });     // the first part is written
  r.catalogChanged();
  assert.equal(r.model.empty, false);
  assert.equal(r.requests.length, 1);
});

test('choosing a camera asks once; a second identical request is not made while the first is out', async () => {
  const r = rig();
  r.model.setCameras([CAM]);
  assert.equal(r.requests.length, 1);
  const { request } = r.requests[0];
  assert.equal(request.cameras.join(), CAM);
  assert.equal(request.fromMs % request.binMs, 0);
  r.model.select('1h');
  r.model.pan(-5 * MIN);
  assert.equal(r.requests.length, 1, 'one request in flight, latest wins');
  await r.answer(0);
  assert.ok(r.model.data);
  assert.equal(r.model.data.combined.level.length, request.bins);
  assert.equal(r.model.scale().typical, 2000);
  assert.equal(r.model.scale().reference, 8000);
});

test('latest wins: while one request is out, only the newest wanted plan is sent after it', async () => {
  const r = rig();
  r.model.setCameras([CAM]);
  r.model.select('6h');
  r.model.select('24h');
  r.model.select('10m');
  assert.equal(r.requests.length, 1);
  await r.answer(0);
  assert.equal(r.requests.length, 2, 'exactly one follow-up');
  assert.equal(r.requests[1].request.binMs, 2000);           // the 10 minute window, not the 6 h or 24 h one in between
});

test('a pan inside the margin needs no request, a pan beyond it does', async () => {
  const r = rig({ mode: 'paused' });
  r.model.setCameras([CAM]);
  await r.answer(0);
  const before = r.requests.length;
  r.model.pan(-5 * MIN);
  assert.equal(r.requests.length, before);
  r.model.pan(-3 * HOUR);
  assert.equal(r.requests.length, before + 1);
});

test('new footage refreshes the waveform at most every two seconds', async () => {
  const r = rig();
  r.model.setCameras([CAM]);
  await r.answer(0);
  assert.equal(r.requests.length, 1);
  const recorded = () => { r.catalog.extents.get(CAM).newest += 1000; r.catalogChanged(); };
  r.advance(500);
  recorded();
  assert.equal(r.requests.length, 1, 'too soon');
  r.advance(REFRESH_MS);
  await r.flush();
  assert.equal(r.requests.length, 2);
  await r.answer(1);
  r.advance(REFRESH_MS + 1);
  recorded();
  assert.equal(r.requests.length, 3, 'after two quiet seconds a change refreshes at once');
});

test('while the window shows only the past, new footage (after it) asks for nothing; retention inside it does', async () => {
  // Playing recordings from two hours ago: the catalog changes every second while the cameras record, and the bins on screen stay the same.
  const r = rig({ mode: 'playing' });
  r.model.setCameras([CAM]);
  r.model.select('1h');
  await r.answer(r.requests.length - 1);
  const asked = r.requests.length;
  for (let second = 0; second < 30; second += 1) {
    r.catalog.extents.get(CAM).newest += 1000;
    r.catalogChanged();
    r.advance(1000);
    r.model.tick();
    await r.flush();
    if (r.requests.length > asked) await r.answer(r.requests.length - 1);
  }
  assert.equal(r.requests.length, asked, 'nothing new can show in a window that ends before the newest recording');
  r.catalog.extents.get(CAM).oldest = r.model.viewport.startMs + 10 * MIN;     // retention removed the start of what is on screen
  r.catalogChanged();
  r.advance(REFRESH_MS + 1);
  r.model.tick();
  await r.flush();
  assert.equal(r.requests.length, asked + 1);
});

test('failures retry after 2, 4, 8, 16, 16 seconds and show a problem from the second one', async () => {
  const r = rig();
  r.model.setCameras([CAM]);
  const delays = [];
  for (let i = 0; i < 5; i += 1) {
    r.requests[i].reject(new Error('down'));
    await r.flush();
    delays.push(r.timers.at(-1).ms);
    r.advance(r.timers.at(-1).ms);
    await r.flush();
  }
  assert.deepEqual(delays, [2000, 4000, 8000, 16000, 16000]);
  assert.deepEqual(delays.slice(0, 4), RETRY_MS);
  assert.equal(r.model.problem, true);
  await r.answer(5);
  assert.equal(r.model.problem, false);
});

test('a superseded request is not a failure', async () => {
  const r = rig();
  r.model.setCameras([CAM]);
  const error = new Error('Superseded');
  error.name = 'Superseded';
  r.requests[0].reject(error);
  await r.flush();
  assert.equal(r.model.problem, false);
  assert.equal(r.timers.filter((t) => t.live).length, 0);
});

test('an incomplete answer is asked again, a bounded number of times', async () => {
  const r = rig();
  r.model.setCameras([CAM]);
  let answered = 0;
  for (let i = 0; i < 40; i += 1) {
    if (r.requests.length <= i) { r.advance(REFRESH_MS + 1); await r.flush(); }
    if (r.requests.length <= i) break;
    await r.answer(i, { complete: false });
    answered += 1;
  }
  assert.ok(answered <= 32, `answered ${answered} incomplete requests`);
  assert.ok(answered >= 2);
});

test('while live the window slides with now, but not for less than a pixel', () => {
  const r = rig();
  r.model.setCameras([CAM]);
  r.model.select('10m');
  const first = r.model.viewport;
  r.advance(500);
  r.model.tick();
  assert.equal(r.model.viewport.startMs, first.startMs, '500 ms of a 10 minute window over 800 px is under one pixel');
  r.advance(10_000);
  r.model.tick();
  assert.ok(r.model.viewport.startMs > first.startMs);
  assert.equal(r.model.viewport.durationMs, first.durationMs);
  assert.equal(r.model.viewport.startMs, r.catalog.serverNow() - 10 * MIN);
});

test('panning stops following; Go Live (the session going live again) follows again', () => {
  const r = rig();
  r.model.setCameras([CAM]);
  r.model.select('1h');
  assert.equal(r.model.following, true);
  r.model.pan(-HOUR);
  assert.equal(r.model.following, false);
  assert.equal(r.model.preset, 'custom');
  r.setMode('paused');
  r.setMode('live');
  assert.equal(r.model.following, true);
  assert.equal(r.model.viewport.startMs, r.catalog.serverNow() - Math.round(r.model.viewport.durationMs / 1.04));
});

test('leaving live stops following; selecting a preset from the past centres it on the playhead', () => {
  const r = rig();
  r.model.setCameras([CAM]);
  r.setMode('paused');
  r.session.position = T0 - 5 * HOUR;
  assert.equal(r.model.following, false);
  r.model.select('1h');
  assert.equal(r.model.following, false);
  const v = r.model.viewport;
  assert.equal(v.startMs + v.durationMs / 2, r.session.position);
});

test('zoom around the pointer leaves live, zoom at the right edge stays pinned to it', () => {
  const r = rig();
  r.model.setCameras([CAM]);
  r.model.select('1h');
  const v = r.model.viewport;
  r.model.zoom(0.5, v.startMs + v.durationMs * 0.2);
  assert.equal(r.model.following, false);
  const r2 = rig();
  r2.model.setCameras([CAM]);
  r2.model.select('1h');
  const w = r2.model.viewport;
  r2.model.zoom(0.5, w.startMs + w.durationMs * 0.99);
  assert.equal(r2.model.following, true);
  assert.equal(r2.model.viewport.durationMs, w.durationMs / 2);
});

test('while playing, a playhead that leaves the window brings the window with it', () => {
  const r = rig({ mode: 'playing' });
  r.model.setCameras([CAM]);
  r.model.select('10m');
  const v = r.model.viewport;
  r.session.position = v.startMs + v.durationMs + 5 * MIN;
  r.model.tick();
  const after = r.model.viewport;
  assert.ok(r.session.position >= after.startMs && r.session.position <= after.startMs + after.durationMs);
});

test('All needs the oldest recording, which may arrive after the model was made', () => {
  const r = rig({ stored: 'all', extent: null });
  r.model.setCameras([CAM]);
  const before = r.model.viewport;
  r.catalog.extents.set(CAM, { oldest: T0 - 2 * DAY, newest: T0, typicalGOP: 2 });
  r.catalogChanged();
  assert.ok(r.model.viewport.startMs < before.startMs);
  assert.equal(r.model.viewport.startMs, T0 - 2 * DAY);
});

test('changing the cameras drops the old answer and asks again', async () => {
  const r = rig();
  r.model.setCameras([CAM]);
  await r.answer(0);
  assert.ok(r.model.data);
  const other = 'BBBBBBBB-0000-4000-8000-000000000002';
  r.catalog.extents.set(other, { oldest: T0 - DAY, newest: T0 - 1000, typicalGOP: 2 });
  r.model.setCameras([other]);
  assert.equal(r.model.data, null);
  assert.equal(r.requests.length, 2);
});

test('after dispose nothing happens', async () => {
  const r = rig();
  r.model.setCameras([CAM]);
  r.model.dispose();
  await r.answer(0);
  assert.equal(r.model.data, null);
  r.model.tick();
  r.catalogChanged();
  assert.equal(r.requests.length, 1);
});
