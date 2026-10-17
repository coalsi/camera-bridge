import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MEDIA_REQUESTS, MEDIA_REQUESTS_WHILE_LIVE, SNAPSHOT_GUARD_MS, createSnapshotScheduler, loadPicture, whenKnown, keyAction } from '../web/js/screens/nvr-model.js';
import { fakeTime, settle } from './nvr-grid-helpers.mjs';

// MARK: snapshots

function snapshotFixture(options = {}) {
  const time = fakeTime(0);
  const loads = [];
  const results = options.results ?? (() => true);
  const scheduler = createSnapshotScheduler({
    load: (cid) => { loads.push([time.now(), cid]); return Promise.resolve(results(cid, loads.length)); },
    shouldRefresh: options.shouldRefresh ?? (() => true),
    now: time.now, setTimer: time.setTimer, clearTimer: time.clearTimer,
  });
  return { time, loads, scheduler };
}

test('snapshots load one at a time, then each tile again every 8 seconds', async () => {
  const { time, loads, scheduler } = snapshotFixture();
  scheduler.setIds(['a', 'b', 'c']);
  await settle();
  assert.deepEqual(loads.map((l) => l[1]), ['a', 'b', 'c']);
  assert.deepEqual(loads.map((l) => l[0]), [0, 0, 0]);
  time.advance(7999);
  await settle();
  assert.equal(loads.length, 3);
  time.advance(1);
  await settle();
  assert.deepEqual(loads.slice(3).map((l) => l[1]), ['a', 'b', 'c']);
  assert.equal(loads[3][0], 8000);
});

test('a load never starts while another is running', async () => {
  const time = fakeTime(0);
  let running = 0;
  let overlap = false;
  const releases = [];
  const scheduler = createSnapshotScheduler({
    load: () => { running += 1; if (running > 1) overlap = true; return new Promise((resolve) => releases.push(() => { running -= 1; resolve(true); })); },
    now: time.now, setTimer: time.setTimer, clearTimer: time.clearTimer,
  });
  scheduler.setIds(['a', 'b']);
  scheduler.poke();
  scheduler.poke();
  await settle();
  assert.equal(releases.length, 1);
  releases.shift()();
  await settle();
  assert.equal(releases.length, 1);
  assert.equal(overlap, false);
});

test('a failed load retries after 2.5 s, then 5 s, then at most every 8 s; a success resets it', async () => {
  let fail = true;
  const { time, loads, scheduler } = snapshotFixture({ results: () => !fail });
  scheduler.setIds(['a']);
  await settle();
  time.advance(2500); await settle();
  time.advance(5000); await settle();
  time.advance(8000); await settle();
  time.advance(8000); await settle();
  assert.deepEqual(loads.map((l) => l[0]), [0, 2500, 7500, 15500, 23500]);
  fail = false;
  time.advance(8000); await settle();
  time.advance(8000); await settle();
  assert.deepEqual(loads.slice(-2).map((l) => l[0]), [31500, 39500]);
});

test('a tile the player is showing is left alone until poke says otherwise; pause and resume hold the whole schedule', async () => {
  const showing = new Set(['a']);
  const { time, loads, scheduler } = snapshotFixture({ shouldRefresh: (cid) => !showing.has(cid) });
  scheduler.setIds(['a', 'b']);
  await settle();
  assert.deepEqual(loads.map((l) => l[1]), ['b']);
  showing.delete('a');
  scheduler.poke();
  await settle();
  assert.deepEqual(loads.map((l) => l[1]), ['b', 'a']);
  scheduler.pause();
  time.advance(60_000); await settle();
  assert.equal(loads.length, 2);
  scheduler.resume();
  await settle();
  assert.equal(loads.length, 4, 'both tiles were due');
  scheduler.refreshNow('a');
  await settle();
  assert.equal(loads.length, 5);
});

test('setIds drops tiles that left the page and starts the new ones at once; destroy stops everything', async () => {
  const { time, loads, scheduler } = snapshotFixture();
  scheduler.setIds(['a', 'b']);
  await settle();
  scheduler.setIds(['b', 'c']);
  await settle();
  assert.deepEqual(loads.map((l) => l[1]), ['a', 'b', 'c']);
  time.advance(8000); await settle();
  assert.deepEqual(loads.slice(3).map((l) => l[1]), ['b', 'c']);
  scheduler.destroy();
  time.advance(60_000); await settle();
  assert.equal(loads.length, 5);
  assert.equal(time.pendingTimers(), 0);
});

test('a load that throws or rejects counts as a failure and the schedule goes on', async () => {
  const time = fakeTime(0);
  let calls = 0;
  const scheduler = createSnapshotScheduler({
    load: () => { calls += 1; if (calls === 1) throw new Error('sync'); if (calls === 2) return Promise.reject(new Error('async')); return Promise.resolve(true); },
    now: time.now, setTimer: time.setTimer, clearTimer: time.clearTimer,
  });
  scheduler.setIds(['a']);
  await settle();
  time.advance(2500); await settle();
  time.advance(5000); await settle();
  assert.equal(calls, 3);
});


// MARK: waiting and keys

/** Just enough of an <img>: what it was told to load, and a way to finish that load. */
function fakeImage() {
  return {
    src: '', onload: null, onerror: null, removed: 0,
    removeAttribute(name) { if (name === 'src') { this.src = ''; this.removed += 1; } },
  };
}

test('loadPicture resolves true when the picture loaded and false when it failed', async () => {
  const time = fakeTime(0);
  const img = fakeImage();
  const loaded = loadPicture(img, '/api/v1/cameras/a/snapshot?t=1', { setTimer: time.setTimer, clearTimer: time.clearTimer });
  assert.equal(img.src, '/api/v1/cameras/a/snapshot?t=1');
  img.onload();
  assert.equal(await loaded, true);
  assert.equal(img.onload, null);
  assert.equal(time.pendingTimers(), 0);
  const failed = loadPicture(img, '/api/v1/cameras/a/snapshot?t=2', { setTimer: time.setTimer, clearTimer: time.clearTimer });
  img.onerror();
  assert.equal(await failed, false);
  assert.equal(img.removed, 0, 'a picture that failed has nothing left to cancel');
});

test('a picture that takes too long is given up and its load cancelled, so it no longer holds one of the browser\'s connections', async () => {
  // Before, the guard only stopped waiting: the <img> went on loading (a camera slow to give a snapshot) while the next picture started.
  const time = fakeTime(0);
  const img = fakeImage();
  const loaded = loadPicture(img, '/api/v1/cameras/eufy/snapshot?t=1', { setTimer: time.setTimer, clearTimer: time.clearTimer });
  time.advance(SNAPSHOT_GUARD_MS - 1);
  await settle();
  assert.equal(img.src, '/api/v1/cameras/eufy/snapshot?t=1');
  time.advance(1);
  assert.equal(await loaded, false);
  assert.equal(img.src, '', 'the load was cancelled');
  assert.equal(img.removed, 1);
  img.onload?.();
  assert.equal(img.onload, null);
});

test('the page leaves one of the six connections free: three media requests, two while the live video holds one', () => {
  // Event stream 1 + live video 1 (live only) + JSON 1 + media (pictures counted): 1 + 3 + 1 = 5 while recordings play, 1 + 1 + 2 + 1 = 5 live.
  assert.equal(1 + MEDIA_REQUESTS + 1, 5);
  assert.equal(1 + 1 + MEDIA_REQUESTS_WHILE_LIVE + 1, 5);
});

test('whenKnown resolves at once, on a callback, or on a poll, and rejects at the deadline', async () => {
  const time = fakeTime(0);
  const options = (extra = {}) => ({ setTimer: time.setTimer, clearTimer: time.clearTimer, timeoutMs: 1000, pollMs: 250, ...extra });

  await whenKnown(() => true, options());

  let known = false;
  let notify = () => {};
  const viaCallback = whenKnown(() => known, options({ subscribe: (fn) => { notify = fn; return () => { notify = () => {}; }; } }));
  known = true;
  notify();
  await viaCallback;
  assert.equal(time.pendingTimers(), 0, 'timers are cleared once resolved');

  known = false;
  const viaPoll = whenKnown(() => known, options());
  time.advance(500);
  known = true;
  time.advance(250);
  await viaPoll;

  const neverKnown = whenKnown(() => false, options());
  time.advance(1000);
  await assert.rejects(neverKnown, /timeout/);
  assert.equal(time.pendingTimers(), 0);

  await assert.rejects(async () => {
    const throwing = whenKnown(() => { throw new Error('not yet'); }, options());
    time.advance(1000);
    await throwing;
  }, /timeout/);
});

test('keyAction maps Space, the arrows and L, and stays out of the way in fields and on buttons', () => {
  const key = (name, extra = {}) => ({ key: name, shiftKey: false, altKey: false, ctrlKey: false, metaKey: false, defaultPrevented: false, ...extra });
  assert.deepEqual(keyAction(key(' ')), { action: 'togglePlay' });
  assert.equal(keyAction(key(' '), { activatable: true }), null);
  assert.deepEqual(keyAction(key('ArrowLeft')), { action: 'seek', deltaMs: -1000 });
  assert.deepEqual(keyAction(key('ArrowRight', { shiftKey: true })), { action: 'seek', deltaMs: 10_000 });
  assert.deepEqual(keyAction(key('ArrowLeft', { altKey: true })), { action: 'seek', deltaMs: -60_000 });
  assert.deepEqual(keyAction(key('ArrowRight'), { activatable: true }), { action: 'seek', deltaMs: 1000 });
  assert.deepEqual(keyAction(key('l')), { action: 'goLive' });
  assert.deepEqual(keyAction(key('L', { shiftKey: true })), { action: 'goLive' });
  assert.equal(keyAction(key('l'), { typing: true }), null);
  assert.equal(keyAction(key(' ', { ctrlKey: true })), null);
  assert.equal(keyAction(key('ArrowLeft', { metaKey: true })), null);
  assert.equal(keyAction(key('ArrowLeft', { defaultPrevented: true })), null);
  assert.equal(keyAction(key('+')), null);
  assert.equal(keyAction(key('Home')), null);
});
