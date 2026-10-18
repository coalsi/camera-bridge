// "Set up for Camera Bridge" on the page: how the steps of a preview, a run and a restore read, and the status line of a camera.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { cloudName, describeStep, resultTitle, SETUP_TEXT, setupErrorText, setupStatusLine, setupSupported, stoppedText, summarize } from '../web/js/screens/camera-setup.js';

const preview = {
  steps: [
    { id: 'timeZone', title: 'Time zone', status: 'alreadyRight', changes: [], needsRestart: false },
    { id: 'timeSource', title: 'Time from the bridge', status: 'notOffered', changes: [], detail: 'Camera Bridge OS serves time to cameras; this bridge does not.' },
    { id: 'streams', title: 'Streams for recording, Apple Home and live view', status: 'willChange', needsRestart: false,
      changes: [{ label: 'Main stream', now: 'H.265, 20 fps, keyframe every 2.5 s', after: 'H.264, 20 fps, keyframe every 2 s' }] },
    { id: 'upnp', title: 'UPnP off', status: 'notSupported', changes: [],
      detail: 'Camera Bridge can’t change this camera’s UPnP setting yet. If it has one, block the camera’s internet in your router (see Keep this camera local).' },
    { id: 'cloud', title: 'Cloud off', status: 'willChange', changes: [{ label: 'Hik-Connect (the maker’s cloud)', now: 'on', after: 'off' }] },
  ],
  canRestore: false,
};

test('a step reads as its title, its status in words and each change from now to after', () => {
  const streams = describeStep(preview.steps[2]);
  assert.equal(streams.statusText, 'Will change');
  assert.deepEqual(streams.lines, ['Main stream: H.265, 20 fps, keyframe every 2.5 s → H.264, 20 fps, keyframe every 2 s']);
  assert.equal(describeStep(preview.steps[3]).detail,
    'Camera Bridge can’t change this camera’s UPnP setting yet. If it has one, block the camera’s internet in your router (see Keep this camera local).',
    'what to do instead is said');
  assert.equal(describeStep({ id: 'cleanPicture', status: 'notSupported', detail: 'not supported by this camera' }).detail, null, 'the status already says it is not supported');
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

test('the local-only help names the cloud the setup turned off by its maker', () => {
  assert.equal(cloudName({ manufacturer: 'Hikvision' }), 'its cloud (Hik-Connect)');
  assert.equal(cloudName({ manufacturer: 'HIKVISION Digital Technology' }), 'its cloud (Hik-Connect)');
  assert.equal(cloudName({ manufacturer: 'IPCAM' }), 'the maker’s cloud');
  assert.equal(cloudName({}), 'the maker’s cloud');
});

test('a run with a refused step that did not stop it is not called stopped', () => {
  const streams = { id: 'streams', title: 'Streams for recording, Apple Home and live view', status: 'refused', detail: 'The camera says its main stream is H.264 but still sends H.265.' };
  const cloud = { id: 'cloud', title: 'Cloud off', status: 'done' };
  assert.equal(resultTitle(summarize({ steps: [streams, cloud], stoppedAt: null })), 'Camera set up, but not every change took');
  assert.equal(resultTitle(summarize({ steps: [streams, { ...cloud, status: 'notRun' }], stoppedAt: 'streams' })), 'The setup stopped');
  assert.equal(resultTitle(summarize({ steps: [cloud] })), 'Camera set up');
  assert.equal(resultTitle(summarize({ steps: [] })), 'Nothing was changed');
  assert.equal(resultTitle(summarize({ steps: [{ ...cloud, status: 'restored' }] }), { restored: true }), 'Original settings restored');
});

test('a run that stopped says so, and says when “Watch its internet” still ran after the stop', () => {
  const streams = { id: 'streams', title: 'Streams for recording, Apple Home and live view', status: 'refused', detail: 'ONVIF minimal: didn’t stick' };
  const cloud = { id: 'cloud', title: 'Cloud off', status: 'notRun' };
  const watch = { id: 'internetWatch', title: 'Watch its internet', status: 'done' };
  assert.equal(stoppedText(summarize({ steps: [streams, cloud, { ...watch, status: 'notRun' }], stoppedAt: 'streams' })),
    'The camera refused “Streams for recording, Apple Home and live view”, so the setup stopped there. The changes before it stay; '
      + '“Restore original settings” puts them back.');
  for (const status of ['done', 'refused']) {
    assert.equal(stoppedText(summarize({ steps: [streams, cloud, { ...watch, status }], stoppedAt: 'streams' })),
      'The camera refused “Streams for recording, Apple Home and live view”, so the setup stopped there, except for “Watch its internet”, '
        + 'which still ran. The changes made stay; “Restore original settings” puts them back.', status);
  }
  assert.equal(stoppedText(summarize({ steps: [{ ...watch, status: 'refused' }], stoppedAt: 'internetWatch' })),
    'The camera refused “Watch its internet”, so the setup stopped there. The changes before it stay; “Restore original settings” puts them back.');
  assert.equal(stoppedText(summarize({ steps: [watch] })), null);
});
