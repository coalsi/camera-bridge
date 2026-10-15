import test from 'node:test';
import assert from 'node:assert/strict';
import { MANUAL_STEPS, WHAT_IT_CAN_CHANGE, describeOptimizeResult, optimizeErrorText } from '../web/js/screens/optimize-dialog.js';

test('the dialog names everything the optimizer can change', () => {
  const text = WHAT_IT_CAN_CHANGE.join(' ');
  for (const word of ['6 Mbit/s', 'H.265', 'H.264', '15 and 25', 'B-frames', 'sub stream']) assert.ok(text.includes(word), word);
  assert.equal(MANUAL_STEPS.length, 4);
});

test('a result with changes is applied and offers undo only when the bridge says it can', () => {
  const info = describeOptimizeResult({ applied: [{ id: 'bitrate', title: 'Lowered the bit rate to 6 Mbit/s' }], failed: [], canUndo: true, mayNeedRecordingReEnabled: true, scoreBefore: 40, scoreAfter: 90 });
  assert.equal(info.outcome, 'applied');
  assert.equal(info.canUndo, true);
  assert.equal(info.reenable, true);
  assert.equal(info.applied[0].title, 'Lowered the bit rate to 6 Mbit/s');
  assert.equal(describeOptimizeResult({ applied: [{ id: 'a', title: 'A' }], canUndo: false }).canUndo, false);
});

test('a result without changes is a failure, and undo is never offered for nothing', () => {
  const info = describeOptimizeResult({ applied: [], failed: [{ id: 'codec', reason: 'The camera refused H.264.' }], canUndo: true });
  assert.equal(info.outcome, 'failed');
  assert.equal(info.canUndo, false);
  assert.equal(info.failed[0].reason, 'The camera refused H.264.');
});

test('a malformed result does not throw', () => {
  for (const bad of [null, undefined, {}, { applied: 'x', failed: 3 }, { applied: [null, {}], failed: [null] }]) {
    const info = describeOptimizeResult(bad);
    assert.equal(info.outcome, 'failed');
    assert.deepEqual(info.applied, []);
  }
});

test('errors become one calm sentence each', () => {
  assert.match(optimizeErrorText({ status: 409, code: 'optimize_busy' }), /already being changed/);
  assert.match(optimizeErrorText({ status: 0, code: 'timeout' }), /two minutes/);
  assert.match(optimizeErrorText({ status: 404, code: 'not_found' }), /doesn’t have the camera optimizer/);
  assert.equal(optimizeErrorText({ status: 422, code: 'optimize_failed', message: 'The camera isn’t answering.' }), 'The camera isn’t answering.');
  assert.match(optimizeErrorText({ status: 422, code: 'optimize_failed' }), /Nothing was changed/);
  assert.equal(optimizeErrorText({ message: 'Boom' }), 'Boom');
  assert.match(optimizeErrorText(undefined), /Nothing was changed/);
});
