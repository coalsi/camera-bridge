// A session shows at most `min(tileCap, the browser's cap)` cells (T08's POLICY_TABLE: Chrome 1, Safari 4 in the T06 decision), so a page of four tiles
// can have fewer players than tiles. The tiles without a player must stay on their snapshots instead of waiting for a picture that never comes.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGridController } from '../web/js/screens/nvr-controller.js';
import { fakeTime, settle } from './nvr-grid-helpers.mjs';

const T0 = 1760099000000;
const id = (n) => `00000000-0000-4000-8000-00000000000${n}`;

function makeCamera(n) {
  return {
    id: id(n), name: `Camera ${n}`, isEnabled: true, nvrEnabled: true,
    status: { connection: 'online', connectionReason: null, nvr: { state: 'recording', detail: null, pause: null, notes: [] } },
  };
}

function fakeCell(cameraId) {
  return {
    cameraId, kind: 'idle', listeners: new Set(),
    get coverage() { return { kind: this.kind, next: null, message: null }; },
    onChange(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); },
    set(kind) { this.kind = kind; for (const fn of [...this.listeners]) fn(); },
  };
}

// Like T08's session: only the first `cap` cameras get a cell, and `cell(id)` is undefined for the others.
function fakeSession(cap) {
  return {
    mode: 'live', position: T0 - 6000, cells: new Map(), calls: [],
    setCameras(ids) { this.calls.push(['setCameras', [...ids]]); this.cells = new Map(ids.slice(0, cap).map((cid) => [cid, fakeCell(cid)])); },
    cell(cid) { return this.cells.get(cid); },
    focus() {}, scrub() {}, goLive() {}, togglePlay() {}, seek() {}, suspend() {}, resume() {},
  };
}

function setup({ cap, count = 4, perPage = 4 }) {
  const time = fakeTime(0);
  const cameras = Array.from({ length: count }, (_, i) => makeCamera(i + 1));
  const session = fakeSession(cap);
  const answered = new Set();
  const catalog = {
    baseMs: T0 - 400 * 86_400_000,
    extent: () => ({ oldest: T0 - 86_400_000, newest: T0 }),
    onChange(fn) { answered.add(fn); return () => answered.delete(fn); },
  };
  const controller = createGridController({
    session, catalog, listCameras: () => cameras, subscribeCameras: () => () => {}, perPage,
    navigate: () => {}, replaceHash: () => {}, formatTime: (ms) => `t${ms - T0}`, now: time.now,
    setTimer: time.setTimer, clearTimer: time.clearTimer,
    setTick: (fn, ms) => { const handle = { stopped: false, timer: null }; const loop = () => { if (handle.stopped) return; fn(); handle.timer = time.setTimer(loop, ms); }; handle.timer = time.setTimer(loop, ms); return handle; },
    clearTick: (handle) => { handle.stopped = true; time.clearTimer(handle.timer); },
  });
  return { time, session, controller };
}

test('tiles beyond the session cap stay on their snapshots once the page has started, and the view says why', async () => {
  const t = setup({ cap: 1 });
  await t.controller.start();
  t.controller.noteRequest();
  t.session.cell(id(1)).set('recorded');
  await settle();
  const view = t.controller.view();
  assert.deepEqual(view.tiles.map((tile) => tile.look.state), ['snapshot', 'snapshot', 'snapshot', 'snapshot'], 'no spinner for a picture that cannot come');
  assert.deepEqual(view.tiles.map((tile) => tile.player), [true, false, false, false]);
  assert.deepEqual(view.tiles.slice(1).map((tile) => tile.look.refresh), [true, true, true], 'their snapshots keep refreshing');
  assert.equal(view.limited, true);
  assert.equal(view.playLimit, 1);
  t.controller.destroy();
});

test('a session with a cell for every tile is not limited', async () => {
  const t = setup({ cap: 9 });
  await t.controller.start();
  t.controller.noteRequest();
  const view = t.controller.view();
  assert.equal(view.limited, false);
  assert.equal(view.playLimit, 4);
  assert.deepEqual(view.tiles.map((tile) => tile.look.state), ['loading', 'loading', 'loading', 'loading']);
  t.controller.destroy();
});

test('before anything has started a limited page looks like any other: snapshots', async () => {
  const t = setup({ cap: 2 });
  await t.controller.start();
  const view = t.controller.view();
  assert.deepEqual(view.tiles.map((tile) => tile.look.state), ['snapshot', 'snapshot', 'snapshot', 'snapshot']);
  assert.equal(view.limited, true);
  assert.equal(view.playLimit, 2);
  t.controller.destroy();
});

test('a page of fewer tiles than the cap is not limited, and the limit counts only the tiles of this page', async () => {
  const t = setup({ cap: 3, count: 5, perPage: 4 });
  await t.controller.start();
  assert.equal(t.controller.view().limited, true);
  t.controller.nextPage();                 // one camera on the second page
  assert.equal(t.controller.view().limited, false);
  assert.equal(t.controller.view().playLimit, 1);
  t.controller.destroy();
});
