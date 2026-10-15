import { test } from 'node:test';
import assert from 'node:assert/strict';

test('the NVR grid modules import in Node without a DOM and export their entry points', async () => {
  assert.equal(typeof document, 'undefined', 'this test runs without a DOM');
  const screen = await import('../web/js/screens/nvr.js');
  assert.deepEqual(Object.keys(screen), ['renderNVR']);
  assert.equal(typeof screen.renderNVR, 'function');
  const controller = await import('../web/js/screens/nvr-controller.js');
  assert.deepEqual(Object.keys(controller), ['createGridController']);
});
