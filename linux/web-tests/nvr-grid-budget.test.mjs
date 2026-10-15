import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTokenBucket, createKeyDispatcher, budgetedCell } from '../web/js/screens/nvr-model.js';
import { fakeTime, settle } from './nvr-grid-helpers.mjs';

// MARK: the key-picture budget

test('the token bucket starts full, spends one token per picture and refills at the rate', () => {
  const time = fakeTime(0);
  const bucket = createTokenBucket({ perSecond: 20, burst: 6, now: time.now });
  assert.equal(bucket.available(), 6);
  for (let i = 0; i < 6; i += 1) assert.equal(bucket.tryTake(), true);
  assert.equal(bucket.tryTake(), false);
  assert.equal(bucket.msUntilToken(), 50);
  time.advance(50);
  assert.equal(bucket.tryTake(), true);
  assert.equal(bucket.tryTake(), false);
  time.advance(10_000);
  assert.equal(bucket.available(), 6, 'never above the burst');
});

function dispatcherFixture({ perSecond = 20, burst = 6, focus = null } = {}) {
  const time = fakeTime(0);
  const bucket = createTokenBucket({ perSecond, burst, now: time.now });
  const state = { focus };
  const dispatcher = createKeyDispatcher({ bucket, focused: () => state.focus, setTimer: time.setTimer, clearTimer: time.clearTimer });
  const log = [];
  const ask = (tile, target) => dispatcher.offer(tile, { target }, (desire) => log.push([time.now(), tile, desire.target]));
  return { time, dispatcher, state, log, ask };
}

test('a key picture goes out when the turn ends while the bucket has tokens, and the newest wish of a tile replaces its older one', async () => {
  const { dispatcher, log, ask, time } = dispatcherFixture({ burst: 1 });
  ask('a', 1);
  assert.deepEqual(log, [], 'nothing is sent inside the turn that asked');
  await settle();
  assert.deepEqual(log, [[0, 'a', 1]]);
  ask('a', 2);
  ask('a', 3);
  await settle();
  assert.equal(dispatcher.stats().pending, 1);
  time.advance(50);
  assert.deepEqual(log.at(-1), [50, 'a', 3]);
  assert.equal(log.length, 2, 'wish 2 was replaced and never sent');
});

test('within one turn the hovered tile goes first even while tokens last, then the others in turn', async () => {
  const { log, ask } = dispatcherFixture({ focus: 'c' });
  ask('a', 1); ask('b', 1); ask('c', 1); ask('d', 1);
  await settle();
  assert.deepEqual(log.map((entry) => entry[1]), ['c', 'd', 'a', 'b']);
});

test('the hovered tile is served first in a round when tokens are short, the others in turn', async () => {
  const { time, log, ask } = dispatcherFixture({ burst: 1, focus: 'c' });
  ask('x', 0);                                  // takes the only token
  await settle();
  ask('a', 1); ask('b', 1); ask('c', 1); ask('d', 1);
  await settle();
  time.advance(50);
  time.advance(50);
  time.advance(50);
  time.advance(50);
  // x took the only token; then the hovered tile c, then the others in turn from the one after c (d, a, b)
  assert.deepEqual(log.map((entry) => entry[1]), ['x', 'c', 'd', 'a', 'b']);
});

test('a drag at 60 pictures a second over 4 tiles stays inside the budget and starves nobody', async () => {
  const { time, log, ask } = dispatcherFixture({ focus: 'a' });
  const tiles = ['a', 'b', 'c', 'd'];
  for (let step = 0; step < 120; step += 1) {         // two seconds, one event every 16 ms, every tile asked every event
    for (const tile of tiles) ask(tile, step);
    await settle();
    time.advance(16);
  }
  time.advance(1000);
  assert.ok(log.length <= 6 + 20 * 3 + 1, `delivered ${log.length}`);
  const counts = Object.fromEntries(tiles.map((tile) => [tile, log.filter((entry) => entry[1] === tile).length]));
  const values = Object.values(counts);
  assert.ok(Math.max(...values) - Math.min(...values) <= 1, JSON.stringify(counts));
  assert.ok(Math.min(...values) >= 10, JSON.stringify(counts));
  // the picture a tile gets is its newest wish, never an old one
  const lastStep = Math.max(...log.map((entry) => entry[2]));
  assert.equal(lastStep, 119);
});

test('cancel drops a waiting wish and the timer; forget also leaves the round-robin ring', async () => {
  const { dispatcher, log, ask, time } = dispatcherFixture({ burst: 1 });
  ask('x', 0);
  await settle();
  ask('a', 1);
  await settle();
  assert.equal(time.pendingTimers(), 1, 'waiting for a token');
  dispatcher.cancel('a');
  assert.equal(dispatcher.stats().pending, 0);
  assert.equal(time.pendingTimers(), 0);
  time.advance(1000);
  assert.deepEqual(log.map((entry) => entry[1]), ['x']);
  ask('b', 1);
  dispatcher.forget('b');
  ask('b', 2);
  assert.equal(dispatcher.stats().pending, 1);
});

test('a delivery that throws does not stop the others', async () => {
  const time = fakeTime(0);
  const dispatcher = createKeyDispatcher({ bucket: createTokenBucket({ now: time.now }), setTimer: time.setTimer, clearTimer: time.clearTimer });
  const got = [];
  const original = console.error;
  console.error = () => {};
  try {
    dispatcher.offer('a', {}, () => { throw new Error('boom'); });
    dispatcher.offer('b', {}, () => got.push('b'));
    await settle();
  } finally {
    console.error = original;
  }
  assert.deepEqual(got, ['b']);
});

function fakeCell() {
  const cell = {
    requests: [], suspended: 0, destroyed: 0, kind: 'idle', extra: 'x',
    request(desire) { this.requests.push(desire); },
    suspend() { this.suspended += 1; },
    destroy() { this.destroyed += 1; },
    onChange(fn) { this.listener = fn; return () => { this.listener = null; }; },
    get coverage() { return { kind: this.kind, next: null, message: null }; },
  };
  return cell;
}

test('budgetedCell: a key picture in a drag waits for a token, everything else goes through at once', async () => {
  const time = fakeTime(0);
  const dispatcher = createKeyDispatcher({ bucket: createTokenBucket({ burst: 1, now: time.now }), setTimer: time.setTimer, clearTimer: time.clearTimer });
  const seen = [];
  const a = fakeCell();
  const b = fakeCell();
  const wrappedA = budgetedCell(a, { id: 'a', dispatcher, onRequest: (cid, desire) => seen.push([cid, desire.precision]) });
  const wrappedB = budgetedCell(b, { id: 'b', dispatcher });
  wrappedA.request({ targetMs: 1, precision: 'key', playing: false, epoch: 1 });
  wrappedB.request({ targetMs: 1, precision: 'key', playing: false, epoch: 1 });
  await settle();
  assert.equal(a.requests.length, 1);
  assert.equal(b.requests.length, 0, 'b waits for a token');
  wrappedB.request({ targetMs: 2, precision: 'exact', playing: false, epoch: 1 });
  assert.deepEqual(b.requests.map((r) => r.targetMs), [2], 'an exact picture is not budgeted and drops the waiting key wish');
  time.advance(1000);
  assert.deepEqual(b.requests.map((r) => r.targetMs), [2], 'the dropped wish never arrives');
  wrappedA.request({ targetMs: 3, precision: 'key', playing: true, epoch: 2 });
  assert.equal(a.requests.at(-1).targetMs, 3, 'playing goes straight through');
  assert.deepEqual(seen, [['a', 'key'], ['a', 'key']]);
});

test('with key pictures off a drag asks the cell for nothing; exact pictures and play still go through', async () => {
  const time = fakeTime(0);
  const dispatcher = createKeyDispatcher({ bucket: createTokenBucket({ now: time.now }), setTimer: time.setTimer, clearTimer: time.clearTimer });
  const seen = [];
  const cell = fakeCell();
  const wrapped = budgetedCell(cell, { id: 'a', dispatcher, keyPictures: false, onRequest: () => seen.push('asked') });
  wrapped.request({ targetMs: 1, precision: 'key', playing: false, epoch: 1 });
  await settle();
  assert.equal(cell.requests.length, 0);
  assert.equal(dispatcher.stats().pending, 0);
  wrapped.request({ targetMs: 2, precision: 'exact', playing: false, epoch: 2 });
  wrapped.request({ targetMs: 3, precision: 'key', playing: true, epoch: 3 });
  assert.deepEqual(cell.requests.map((r) => r.targetMs), [2, 3]);
  assert.equal(seen.length, 3, 'the page still learns that something was asked');
});

test('budgetedCell forwards every other member and cleans up on suspend and destroy', () => {
  const time = fakeTime(0);
  const dispatcher = createKeyDispatcher({ bucket: createTokenBucket({ burst: 0, now: time.now }), setTimer: time.setTimer, clearTimer: time.clearTimer });
  const cell = fakeCell();
  const wrapped = budgetedCell(cell, { id: 'a', dispatcher });
  assert.equal(wrapped.extra, 'x');
  cell.kind = 'recorded';
  assert.equal(wrapped.coverage.kind, 'recorded');
  const off = wrapped.onChange(() => {});
  assert.equal(typeof cell.listener, 'function');
  off();
  assert.equal(cell.listener, null);
  wrapped.request({ targetMs: 1, precision: 'key', playing: false, epoch: 1 });
  assert.equal(dispatcher.stats().pending, 1);
  wrapped.suspend();
  assert.equal(cell.suspended, 1);
  assert.equal(dispatcher.stats().pending, 0);
  wrapped.request({ targetMs: 2, precision: 'key', playing: false, epoch: 2 });
  wrapped.destroy();
  assert.equal(cell.destroyed, 1);
  assert.equal(dispatcher.stats().pending, 0);
});
