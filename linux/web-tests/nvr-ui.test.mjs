import test from 'node:test';
import assert from 'node:assert/strict';
import { loadNVR } from '../web/js/nvr/lite.js';

test('loadNVR imports the aggregator, and the aggregator offers exactly what the other screens call', async () => {
  const ui = await loadNVR();
  assert.ok(ui, 'ui.js loads (a syntax error in the NVR code would make this null)');
  assert.deepEqual(Object.keys(ui).sort(), ['chooseStorage', 'keyframeNote', 'recordCard', 'recordSwitch', 'storageCard']);
  for (const name of Object.keys(ui)) assert.equal(typeof ui[name], 'function', name);
});

test('the Record code offers the two calls of the contract', async () => {
  const record = await import('../web/js/nvr/record.js');
  assert.equal(typeof record.setRecording, 'function');
  assert.equal(typeof record.setRecordSound, 'function');
});
