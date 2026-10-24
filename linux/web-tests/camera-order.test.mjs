// The cameras' order: the saved order, the drag and the keyboard move on the Monitor, and the rollback when the save fails.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { orderCameras, placeAt } from '../web/js/camera-order.js';
import { attachReorder, HOLD_MS } from '../web/js/screens/nvr-reorder.js';
import { installFakeBrowser } from './support/fake-browser.mjs';

installFakeBrowser();
const { store, cameraList, setCameraOrder, saveCameraOrder, subscribe } = await import('../web/js/store.js');

const cam = (id, name) => ({ id, name });
const A = cam('a', 'Alley'), B = cam('b', 'Back door'), C = cam('c', 'Camera 10'), D = cam('d', 'Camera 2');
const names = (list) => list.map((camera) => camera.id).join('');

test('without a saved order the cameras are by name, numbers by value', () => {
  assert.equal(names(orderCameras([C, D, B, A], [])), 'abdc');
  assert.equal(names(orderCameras([C, D, B, A], undefined)), 'abdc');
});

test('the saved order comes first; cameras not in it follow by name; ids that no longer exist and repeats are ignored', () => {
  assert.equal(names(orderCameras([A, B, C, D], ['c', 'a'])), 'cabd');
  assert.equal(names(orderCameras([A, B, C, D], ['gone', 'd', 'd', 'b', 'also-gone'])), 'dbac');
  assert.equal(names(orderCameras([A, B], ['b', 'a', 'new'])), 'ba');
});

test('placeAt: the camera takes the place of the one it is dropped on', () => {
  assert.deepEqual(placeAt(['a', 'b', 'c', 'd'], 'a', 'c'), ['b', 'c', 'a', 'd']);
  assert.deepEqual(placeAt(['a', 'b', 'c', 'd'], 'd', 'b'), ['a', 'd', 'b', 'c']);
  const same = ['a', 'b'];
  assert.equal(placeAt(same, 'a', 'a'), same);
  assert.equal(placeAt(same, 'a', 'zz'), same, 'an id that is not there changes nothing');
});

test('the store lists by the order it was given and tells subscribers', () => {
  store.cameras = new Map([A, B, C, D].map((camera) => [camera.id, camera]));
  const seen = [];
  const off = subscribe((kind) => seen.push(kind));
  setCameraOrder(['d', 'c']);
  assert.equal(names(cameraList()), 'dcab');
  setCameraOrder(undefined);
  assert.equal(names(cameraList()), 'abdc');
  assert.deepEqual(seen, ['order', 'order']);
  off();
});

test('saving: the page takes the order at once and sends it in one PATCH; a failure puts the old order back and says so', async () => {
  store.cameras = new Map([A, B, C, D].map((camera) => [camera.id, camera]));
  setCameraOrder(['a', 'b']);
  const sent = [];
  assert.equal(await saveCameraOrder(['b', 'a', 'd', 'c'], { save: async (order) => { sent.push(order); } }), true);
  assert.deepEqual(sent, [['b', 'a', 'd', 'c']]);
  assert.equal(names(cameraList()), 'badc');

  let during = null;
  const errors = [];
  const saved = await saveCameraOrder(['d', 'c', 'b', 'a'], {
    save: async () => { during = names(cameraList()); throw new Error('offline'); },
    onError: (error) => errors.push(error.message),
  });
  assert.equal(during, 'dcba', 'optimistic');
  assert.equal(saved, false);
  assert.equal(names(cameraList()), 'badc', 'rolled back');
  assert.deepEqual(errors, ['offline']);
});

test('a failed save does not undo a newer move', async () => {
  store.cameras = new Map([A, B].map((camera) => [camera.id, camera]));
  setCameraOrder([]);
  let fail;
  const first = saveCameraOrder(['b', 'a'], { save: () => new Promise((_, reject) => { fail = reject; }) });
  await saveCameraOrder(['a', 'b'], { save: async () => {} });
  fail(new Error('late'));
  await first;
  assert.equal(names(cameraList()), 'ab');
});

// MARK: The drag and the keyboard

function rig({ ids = ['a', 'b', 'c'], enabled = true } = {}) {
  const handlers = new Map();
  const grid = {
    addEventListener(type, fn) { handlers.set(type, fn); },
    removeEventListener(type) { handlers.delete(type); },
  };
  const timers = [];
  const log = { marks: [], commits: [], said: [], steps: [] };
  const at = { x: 0, y: 0 };
  const stop = attachReorder(grid, {
    tileId: (node) => node?.tile ?? null,
    targetAt: (x) => ids[Math.floor(x / 100)] ?? null,
    mark: (id, kind) => log.marks.push([id, kind]),
    enabled: () => enabled,
    commit: (id, target) => log.commits.push([id, target]),
    step: (id, delta) => { log.steps.push([id, delta]); return `${id} moved ${delta}`; },
    announce: (text) => log.said.push(text),
    setTimer: (fn, ms) => { timers.push({ fn, ms }); return timers.length - 1; },
    clearTimer: (t) => { if (timers[t]) timers[t].fn = null; },
  });
  const fire = (type, event = {}) => {
    const out = { pointerId: 1, isPrimary: true, button: 0, pointerType: 'mouse', clientX: 0, clientY: 0, target: { tile: 'a', closest: () => null },
      preventDefault() { out.prevented = true; }, stopPropagation() { out.stopped = true; }, ...event };
    handlers.get(type)?.(out);
    return out;
  };
  return { fire, log, timers, stop, handlers, tile: (id, extra = {}) => ({ tile: id, closest: () => null, ...extra }) };
}

test('a mouse drag onto another tile moves the camera there, with a drop mark that follows the pointer; a small move is just a click', () => {
  const r = rig();
  r.fire('pointerdown', { clientX: 10 });
  r.fire('pointermove', { clientX: 12 });
  assert.deepEqual(r.log.marks, [], 'not yet a drag');
  r.fire('pointermove', { clientX: 150 });
  r.fire('pointermove', { clientX: 250 });
  r.fire('pointerup', { clientX: 250 });
  assert.deepEqual(r.log.commits, [['a', 'c']]);
  assert.deepEqual(r.log.marks, [['a', 'dragging'], ['b', 'drop'], ['b', null], ['c', 'drop'], ['a', null], ['c', null]]);
  const click = r.fire('click');
  assert.ok(click.prevented && click.stopped, 'the click that ends a drag is swallowed');
  assert.equal(r.fire('click').prevented, undefined, 'only that one');

  const plain = rig();
  plain.fire('pointerdown', { clientX: 10 });
  plain.fire('pointerup', { clientX: 10 });
  assert.deepEqual(plain.log.commits, []);
  assert.equal(plain.fire('click').prevented, undefined, 'a plain click still reaches the tile');
});

test('dropping on its own place, or outside the tiles, or pressing Escape, moves nothing', () => {
  const r = rig();
  r.fire('pointerdown', { clientX: 10 });
  r.fire('pointermove', { clientX: 60 });
  r.fire('pointerup', { clientX: 60 });
  assert.deepEqual(r.log.commits, []);
  const out = rig();
  out.fire('pointerdown', { clientX: 10 });
  out.fire('pointermove', { clientX: 900 });
  out.fire('pointerup', { clientX: 900 });
  assert.deepEqual(out.log.commits, []);
  const esc = rig();
  esc.fire('pointerdown', { clientX: 10 });
  esc.fire('pointermove', { clientX: 150 });
  esc.fire('keydown', { key: 'Escape' });
  esc.fire('pointerup', { clientX: 150 });
  assert.deepEqual(esc.log.commits, []);
});

test('buttons, other mouse buttons and a disabled wall start no drag', () => {
  const r = rig();
  r.fire('pointerdown', { target: r.tile('a', { closest: () => ({}) }) });
  r.fire('pointermove', { clientX: 150 });
  r.fire('pointerup', { clientX: 150 });
  r.fire('pointerdown', { button: 2 });
  r.fire('pointermove', { clientX: 150 });
  r.fire('pointerup', { clientX: 150 });
  const off = rig({ enabled: false });
  off.fire('pointerdown');
  off.fire('pointermove', { clientX: 150 });
  off.fire('pointerup', { clientX: 150 });
  assert.deepEqual([r.log.commits, off.log.commits], [[], []]);
});

test('on touch a press and hold starts the drag; moving before the hold is a scroll and starts nothing', () => {
  const held = rig();
  held.fire('pointerdown', { pointerType: 'touch', clientX: 10 });
  assert.equal(held.timers.at(-1).ms, HOLD_MS);
  held.fire('pointermove', { pointerType: 'touch', clientX: 150 });
  assert.deepEqual(held.log.marks, [], 'not dragging before the hold');
  held.timers.at(-1).fn?.();
  assert.equal(held.log.marks.length, 0, 'the scroll cancelled the hold');

  const r = rig();
  r.fire('pointerdown', { pointerType: 'touch', clientX: 10 });
  r.timers.at(-1).fn();
  assert.deepEqual(r.log.marks, [['a', 'dragging']]);
  assert.equal(r.fire('contextmenu').prevented, true, 'no browser menu from the hold');
  const move = r.fire('pointermove', { pointerType: 'touch', clientX: 120 });
  assert.equal(move.prevented, true);
  const scroll = r.fire('touchmove');
  assert.equal(scroll.prevented, true, 'the page does not scroll with the drag');
  r.fire('pointerup', { pointerType: 'touch', clientX: 120 });
  assert.deepEqual(r.log.commits, [['a', 'b']]);

  const tap = rig();
  tap.fire('pointerdown', { pointerType: 'touch' });
  tap.fire('pointerup', { pointerType: 'touch' });
  assert.equal(tap.timers.at(-1).fn, null, 'a tap cancels the hold');
  assert.equal(tap.fire('touchmove').prevented, undefined);
});

test('Alt + an arrow key moves the focused tile and announces it; other keys are left alone', () => {
  const r = rig();
  const left = r.fire('keydown', { key: 'ArrowLeft', altKey: true });
  assert.ok(left.prevented);
  r.fire('keydown', { key: 'ArrowDown', altKey: true });
  assert.deepEqual(r.log.steps, [['a', -1], ['a', 1]]);
  assert.deepEqual(r.log.said, ['a moved -1', 'a moved 1']);
  for (const event of [{ key: 'ArrowLeft' }, { key: 'ArrowLeft', altKey: true, ctrlKey: true }, { key: 'a', altKey: true }, { key: 'ArrowLeft', altKey: true, target: { closest: () => null } }]) {
    const other = r.fire('keydown', event);
    assert.equal(other.prevented, undefined);
  }
  assert.equal(r.log.steps.length, 2);
  const off = rig({ enabled: false });
  off.fire('keydown', { key: 'ArrowLeft', altKey: true });
  assert.deepEqual(off.log.steps, []);
});

test('stopping removes every listener', () => {
  const r = rig();
  r.stop();
  assert.equal(r.handlers.size, 0);
});
