// "Set up for Camera Bridge" on the page: how the steps of a preview, a run and a restore read, and the status line of a camera.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { describeStep, SETUP_TEXT, setupErrorText, setupStatusLine, setupSupported, summarize } from '../web/js/screens/camera-setup.js';

const preview = {
  steps: [
    { id: 'timeZone', title: 'Time zone', status: 'alreadyRight', changes: [], needsRestart: false },
    { id: 'timeSource', title: 'Time from the bridge', status: 'notOffered', changes: [], detail: 'Camera Bridge OS serves time to cameras; this bridge does not.' },
    { id: 'streams', title: 'Streams for recording, Apple Home and live view', status: 'willChange', needsRestart: false,
      changes: [{ label: 'Main stream', now: 'H.265, 20 fps, keyframe every 2.5 s', after: 'H.264, 20 fps, keyframe every 2 s' }] },
    { id: 'upnp', title: 'UPnP off', status: 'notSupported', changes: [], detail: 'not supported by this camera' },
    { id: 'cloud', title: 'Cloud off (Hik-Connect)', status: 'willChange', changes: [{ label: 'Hik-Connect (the maker’s cloud)', now: 'on', after: 'off' }] },
  ],
  canRestore: false,
};

test('a step reads as its title, its status in words and each change from now to after', () => {
  const streams = describeStep(preview.steps[2]);
  assert.equal(streams.statusText, 'Will change');
  assert.deepEqual(streams.lines, ['Main stream: H.265, 20 fps, keyframe every 2.5 s → H.264, 20 fps, keyframe every 2 s']);
  assert.equal(describeStep(preview.steps[3]).detail, null, 'the status already says it is not supported');
  assert.equal(describeStep(preview.steps[1]).detail, 'Camera Bridge OS serves time to cameras; this bridge does not.');
  assert.equal(describeStep({ id: 'cloud', status: 'refused', detail: 'Invalid Content (badParameters)' }).detail, 'Invalid Content (badParameters)');
  assert.equal(describeStep({ id: 'cloud', status: 'done', detail: 'via ISAPI' }).detail, null);
  assert.equal(describeStep({ id: 'x', status: 'refused', detail: 'the camera kept it on' }).detail, 'The camera kept it on.');
  assert.equal(describeStep({ status: 'done', needsRestart: true }).needsRestart, true);
});

test('a preview and a run are summed up for the dialog', () => {
  const info = summarize(preview);
  assert.equal(info.toChange, 2);
  assert.equal(info.streamsWillChange, true);
  const run = summarize({ steps: [{ id: 'streams', title: 'Streams', status: 'done', needsRestart: true }, { id: 'upnp', title: 'UPnP off', status: 'refused' },
    { id: 'cloud', title: 'Cloud off', status: 'notRun' }], stoppedAt: 'upnp', canRestore: true, streamRestarted: true });
  assert.deepEqual([run.done, run.refused, run.stoppedAt, run.needsRestart, run.canRestore, run.streamRestarted], [1, 1, 'UPnP off', true, true, true]);
  assert.equal(summarize(null).toChange, 0);
});

test('the camera page says whether and when a camera was set up', () => {
  assert.equal(setupStatusLine({}), SETUP_TEXT.notSetUp);
  assert.equal(setupStatusLine({ setupState: { version: 1, started: '2026-10-16T17:00:00Z' } }), 'Setup did not finish');
  assert.equal(setupStatusLine({ setupState: { version: 1, applied: '2026-10-16T17:00:00Z' } }, 'en-US'), 'Set up for Camera Bridge (1) on Oct 16, 2026');
  assert.equal(SETUP_TEXT.button, 'Set up for Camera Bridge');
});

test('only cameras the bridge reaches directly are offered the setup', () => {
  assert.ok(setupSupported({ vendor: 'hikvision' }) && setupSupported({ vendor: 'onvif' }) && setupSupported({ vendor: 'reolink' }));
  assert.ok(!setupSupported({ vendor: 'rtsp' }) && !setupSupported({ vendor: 'demo' }) && !setupSupported({ vendor: 'go2rtc' }) && !setupSupported(null));
});

test('failures read as one sentence', () => {
  assert.match(setupErrorText({ status: 409, code: 'camera_setup_busy' }), /already being changed/);
  assert.match(setupErrorText({ code: 'timeout' }), /didn’t answer in time/);
  assert.equal(setupErrorText({ status: 422, message: 'The camera refused the login.' }), 'The camera refused the login.');
});
