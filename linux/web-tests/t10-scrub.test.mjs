import test from 'node:test';
import assert from 'node:assert/strict';
import { TOUCH_SLOP_PX, createScrubController } from '../web/js/nvr/timeline/scrub.js';

/** A session that only records what it was told, and frames that run when the test says so. */
function rig({ clampMs, enabled = true } = {}) {
  const calls = [];
  const session = {
    beginScrub: () => calls.push(['begin']),
    scrub: (ms) => calls.push(['scrub', ms]),
    endScrub: () => calls.push(['end']),
  };
  let next = 1;
  const frames = new Map();
  const controller = createScrubController({
    session,
    timeForX: (x) => 1_000_000 + x * 1000,            // 1 s per pixel
    clampMs,
    requestFrame: (fn) => { frames.set(next, fn); return next++; },
    cancelFrame: (id) => frames.delete(id),
    isEnabled: () => enabled,
  });
  const runFrame = () => { const all = [...frames.values()]; frames.clear(); all.forEach((fn) => fn()); };
  return { calls, controller, runFrame, frames };
}

test('a mouse press begins at once; the release flushes the newest position and ends once', () => {
  const { calls, controller, runFrame } = rig();
  assert.equal(controller.down({ id: 1, pointerType: 'mouse', x: 100 }), true);
  controller.move({ id: 1, x: 110 });
  controller.move({ id: 1, x: 120 });
  assert.deepEqual(calls, [['begin']]);                   // nothing is sent between frames
  runFrame();
  assert.deepEqual(calls, [['begin'], ['scrub', 1_120_000]]);
  controller.move({ id: 1, x: 130 });
  controller.up({ id: 1, x: 140 });                       // no frame ran: the release carries the newest position
  assert.deepEqual(calls.slice(2), [['scrub', 1_140_000], ['end']]);
  assert.equal(controller.active, false);
});

test('a release where the pointer already was sends the position only once', () => {
  const { calls, controller, runFrame } = rig();
  controller.down({ id: 1, x: 50 });
  runFrame();
  controller.up({ id: 1, x: 50 });
  assert.deepEqual(calls, [['begin'], ['scrub', 1_050_000], ['end']]);
});

test('a click is begin, scrub, end', () => {
  const { calls, controller } = rig();
  controller.down({ id: 7, pointerType: 'mouse', x: 50 });
  controller.up({ id: 7, x: 50 });
  assert.deepEqual(calls, [['begin'], ['scrub', 1_050_000], ['end']]);
});

test('120 Hz of pointer events gives at most one scrub per animation frame, and the last position wins', () => {
  const { calls, controller, runFrame } = rig();
  controller.down({ id: 1, pointerType: 'mouse', x: 0 });
  const seconds = 2;
  const frames = 60 * seconds;
  let x = 0;
  for (let f = 0; f < frames; f += 1) {
    for (let e = 0; e < 2; e += 1) { x += 1; controller.move({ id: 1, x }); }    // two events per frame: 120 Hz on a 60 Hz display
    runFrame();
  }
  controller.up({ id: 1, x: x + 1 });
  const scrubs = calls.filter((c) => c[0] === 'scrub');
  assert.equal(scrubs.length, frames + 1);                // one per frame, and the release
  assert.equal(scrubs.at(-1)[1], 1_000_000 + (x + 1) * 1000);
  assert.deepEqual(calls.at(-1), ['end']);
  assert.equal(calls.filter((c) => c[0] === 'begin').length, 1);
  assert.equal(calls.filter((c) => c[0] === 'end').length, 1);
});

test('a finger scrubs only after 6 px, and a tap scrubs once', () => {
  const swipe = rig();
  swipe.controller.down({ id: 3, pointerType: 'touch', x: 100 });
  swipe.controller.move({ id: 3, x: 100 + TOUCH_SLOP_PX - 1 });
  swipe.runFrame();
  assert.deepEqual(swipe.calls, []);
  swipe.controller.move({ id: 3, x: 100 + TOUCH_SLOP_PX });
  assert.deepEqual(swipe.calls, [['begin']]);
  swipe.runFrame();
  swipe.controller.up({ id: 3, x: 130 });
  assert.deepEqual(swipe.calls.map((c) => c[0]), ['begin', 'scrub', 'scrub', 'end']);

  const tap = rig();
  tap.controller.down({ id: 4, pointerType: 'touch', x: 20 });
  tap.controller.up({ id: 4, x: 22 });
  assert.deepEqual(tap.calls, [['begin'], ['scrub', 1_022_000], ['end']]);

  const dragThenBack = rig();
  dragThenBack.controller.down({ id: 5, pointerType: 'touch', x: 100 });
  dragThenBack.controller.move({ id: 5, x: 103 });
  dragThenBack.controller.up({ id: 5, x: 103 });          // never passed the slop: still a tap
  assert.deepEqual(dragThenBack.calls.map((c) => c[0]), ['begin', 'scrub', 'end']);
});

test('only the first pointer counts, other buttons and a disabled track are ignored', () => {
  const { calls, controller } = rig();
  assert.equal(controller.down({ id: 1, x: 10 }), true);
  assert.equal(controller.down({ id: 2, x: 20 }), false);
  controller.move({ id: 2, x: 99 });
  controller.up({ id: 2, x: 99 });
  assert.equal(controller.active, true);
  controller.up({ id: 1, x: 10 });
  assert.deepEqual(calls.map((c) => c[0]), ['begin', 'scrub', 'end']);
  const right = rig();
  assert.equal(right.controller.down({ id: 1, x: 1, button: 2 }), false);
  const off = rig({ enabled: false });
  assert.equal(off.controller.down({ id: 1, x: 1 }), false);
  assert.deepEqual(off.calls, []);
});

test('cancel ends the scrub where it is, and only once', () => {
  const { calls, controller } = rig();
  controller.down({ id: 1, x: 5 });
  controller.cancel();
  controller.cancel();
  assert.deepEqual(calls.map((c) => c[0]), ['begin', 'scrub', 'end']);
  const idle = rig();
  idle.controller.cancel();
  assert.deepEqual(idle.calls, []);
});

test('positions are clamped between the oldest recording and now', () => {
  const { calls, controller } = rig({ clampMs: (ms) => Math.min(Math.max(ms, 1_000_500), 1_900_000) });
  controller.down({ id: 1, x: 0 });
  controller.move({ id: 1, x: 5000 });
  controller.up({ id: 1, x: 5000 });
  assert.deepEqual(calls.filter((c) => c[0] === 'scrub').map((c) => c[1]), [1_900_000]);
  assert.equal(controller.lastMs, 1_900_000);
  assert.equal(controller.lastEdge, 'now');
});

test('the release says which edge it was clamped to, so the screen can explain', () => {
  const ends = [];
  const session = { beginScrub() {}, scrub() {}, endScrub() {} };
  const make = (clampMs) => createScrubController({
    session, timeForX: (x) => x, clampMs, requestFrame: () => 1, cancelFrame() {}, onEnd: (info) => ends.push(info),
  });
  const before = make((ms) => Math.max(ms, 500));
  before.down({ id: 1, x: 100 });
  before.up({ id: 1, x: 100 });
  const inside = make((ms) => ms);
  inside.down({ id: 1, x: 700 });
  inside.up({ id: 1, x: 700 });
  assert.deepEqual(ends, [{ ms: 500, edge: 'oldest' }, { ms: 700, edge: null }]);
});
