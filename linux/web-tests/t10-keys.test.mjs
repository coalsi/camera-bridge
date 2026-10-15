import test from 'node:test';
import assert from 'node:assert/strict';
import { isTypingTarget, keyAction } from '../web/js/nvr/timeline/keys.js';

test('keys: the map', () => {
  const key = (k, extra = {}) => keyAction({ key: k, target: { tagName: 'DIV' }, ...extra });
  assert.deepEqual(key(' '), { type: 'togglePlay' });
  assert.deepEqual(key('ArrowLeft'), { type: 'seek', deltaMs: -1000 });
  assert.deepEqual(key('ArrowRight', { shiftKey: true }), { type: 'seek', deltaMs: 10_000 });
  assert.deepEqual(key('ArrowRight', { altKey: true }), { type: 'seek', deltaMs: 60_000 });
  assert.deepEqual(key('l'), { type: 'live' });
  assert.deepEqual(key('L', { shiftKey: true }), { type: 'live' });
  assert.deepEqual(key('+'), { type: 'zoom', factor: 0.5 });
  assert.deepEqual(key('='), { type: 'zoom', factor: 0.5 });
  assert.deepEqual(key('-'), { type: 'zoom', factor: 2 });
  assert.deepEqual(key('Home'), { type: 'oldest' });
  assert.deepEqual(key('Escape'), { type: 'close' });
  assert.equal(key('x'), null);
  assert.deepEqual(key('ArrowLeft', { repeat: true }), { type: 'seek', deltaMs: -1000 });   // holding an arrow keeps seeking
  assert.equal(key(' ', { repeat: true }), null);                                            // holding Space does not flip play/pause
});

test('keys: never in a text field, a select, a dialog, or with ctrl or cmd; Space on a button is the button', () => {
  assert.equal(keyAction({ key: ' ', target: { tagName: 'INPUT' } }), null);
  assert.equal(keyAction({ key: 'ArrowLeft', target: { tagName: 'SELECT' } }), null);
  assert.equal(keyAction({ key: 'l', target: { tagName: 'DIV', isContentEditable: true } }), null);
  assert.equal(keyAction({ key: 'l', target: { tagName: 'BUTTON', closest: (s) => (s === 'dialog[open]' ? {} : null) } }), null);
  assert.deepEqual(keyAction({ key: 'l', target: { tagName: 'BUTTON', closest: () => null } }), { type: 'live' });
  assert.equal(keyAction({ key: 'l', ctrlKey: true, target: { tagName: 'DIV' } }), null);
  assert.equal(keyAction({ key: '-', metaKey: true, target: { tagName: 'DIV' } }), null);
  assert.equal(keyAction({ key: ' ', target: { tagName: 'BUTTON' } }), null);
  assert.equal(keyAction({ key: ' ', target: { tagName: 'A' } }), null);
  assert.deepEqual(keyAction({ key: 'ArrowLeft', target: { tagName: 'BUTTON' } }), { type: 'seek', deltaMs: -1000 });
  assert.equal(isTypingTarget(null), false);
});
