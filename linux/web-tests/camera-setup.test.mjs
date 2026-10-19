// "Set up for Camera Bridge" on the page: how the steps of a preview, a run and a restore read, the status line of a camera, and "Restart
// the camera now" (in the fake browser).
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { ApiError } from '../web/js/api.js';
import {
  cloudName, describeStep, FIX_ADDRESS_TEXT, previewText, RESTART_TEXT, restartControl, resultTitle, SETUP_TEXT, setupErrorText, setupRequest,
  setupStatusLine, setupSupported, stepList, stoppedText, summarize, withFixAddress,
} from '../web/js/screens/camera-setup.js';
import { FakeElement, installFakeBrowser } from './support/fake-browser.mjs';

let browser;
before(() => { browser = installFakeBrowser(); });
after(() => browser?.restore());

function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const buttons = (root) => all(root, (node) => node.localName === 'button');
const button = (root, text) => buttons(root).find((node) => (text instanceof RegExp ? text.test(node.textContent) : node.textContent.includes(text)));
const settle = () => new Promise((resolve) => setImmediate(resolve));

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

test('theButtonRestartsOnlyWhenPressed: “Restart the camera now” shows only where the camera waits for a restart, asks first, and sends once', async () => {
  const sent = [];
  const send = (path) => { sent.push(path); return Promise.resolve(null); };
  assert.equal(restartControl({ id: 'c1', name: 'Gate' }, { send }), null, 'the bridge did not offer it: no button');
  assert.equal(restartControl({ id: 'c1', name: 'Gate', restartOffered: false }, { send }), null);

  const control = restartControl({ id: 'c1', name: 'Gate', restartOffered: true }, { send });
  assert.match(control.textContent, /The camera says some changes apply after it restarts\./);
  assert.equal(RESTART_TEXT.button, 'Restart the camera now');
  // Where the keyboard goes as the buttons change.
  const focused = [];
  const focus = FakeElement.prototype.focus;
  FakeElement.prototype.focus = function () { focused.push(this); };
  try {
    button(control, RESTART_TEXT.button).click();
    assert.deepEqual(sent, [], 'pressing it asks first');
    assert.match(control.textContent, /“Gate” goes offline for about a minute/);
    assert.equal(focused.at(-1)?.textContent, 'Cancel');
    button(control, 'Cancel').click();
    assert.deepEqual(sent, [], 'cancelled: nothing is sent');
    assert.equal(focused.at(-1)?.textContent, RESTART_TEXT.button);
    button(control, RESTART_TEXT.button).click();
    button(control, /^Restart$/).click();
    button(control, /^Restart$/)?.click();
    await settle();
    assert.deepEqual(sent, ['cameras/c1/restart'], 'confirmed: one request');
    assert.match(control.textContent, /The camera is restarting\. It is back in about a minute\./);
    assert.equal(buttons(control).length, 0, 'nothing left to press again');
    const status = focused.at(-1);
    assert.equal(status?.textContent, RESTART_TEXT.sent, 'the pressed button is gone: the keyboard goes to the status line');
    assert.equal(status.getAttribute('tabindex'), '-1');
    assert.ok(control.childNodes.includes(status), 'the control’s own line');
  } finally {
    FakeElement.prototype.focus = focus;
  }

  // The setup's result offers it for a run whose done steps wait for a restart; a restore's result never (nothing waits on the bridge).
  assert.equal(summarize({ steps: [{ id: 'upnp', status: 'done', needsRestart: true }] }).restartWaits, true);
  assert.equal(summarize({ steps: [{ id: 'upnp', status: 'restored', needsRestart: true }] }).restartWaits, false);
  assert.equal(summarize({ steps: [{ id: 'upnp', status: 'done' }] }).restartWaits, false);
  assert.ok(restartControl({ id: 'c1', name: 'Gate' }, { offered: true, send }), 'offered by the run’s result');

  // A refusal says why, and the button comes back.
  const failing = restartControl({ id: 'c2', name: 'Porch', restartOffered: true },
    { send: () => Promise.reject(new ApiError(409, 'camera_restart_not_needed', 'The camera isn’t waiting for a restart, so Camera Bridge didn’t restart it.')) });
  button(failing, RESTART_TEXT.button).click();
  button(failing, /^Restart$/).click();
  await settle();
  assert.match(failing.textContent, /isn’t waiting for a restart/);
  assert.ok(button(failing, RESTART_TEXT.button));
});

// "Fix its address so the DNS stays": a Hikvision on DHCP, whose DNS would not last, is offered it under "Watch its internet".
const keeps = { address: '192.168.77.30', subnetMask: '255.255.255.0', gateway: '192.168.77.1', hardwareAddress: '02:00:00:00:00:30' };
const onDHCP = {
  steps: [
    { id: 'timeZone', title: 'Time zone', status: 'alreadyRight', changes: [] },
    { id: 'internetWatch', title: 'Watch its internet', status: 'notSupported', changes: [],
      detail: 'the camera takes its address from DHCP, so its DNS would go back to the router’s at the next renewal: choose “Fix its address so the DNS stays”, or set it by hand with a fixed address',
      fixAddress: { addressing: keeps, changes: [
        { label: 'Address', now: '192.168.77.30 from the router (DHCP)', after: '192.168.77.30, fixed (mask 255.255.255.0, gateway 192.168.77.1)' },
        { label: 'DNS', now: '8.8.8.8 and 1.1.1.1 from the router (DHCP)', after: 'the bridge (192.168.77.2)' }] } },
  ],
  canRestore: false,
};
const inputs = (root) => all(root, (node) => node.localName === 'input');

test('the choice is a checkbox, off by default; chosen, the step changes the address and the DNS, and the run says which address it keeps', () => {
  assert.equal(FIX_ADDRESS_TEXT.choice('192.168.77.30'), 'Fix its address so the DNS stays (keeps 192.168.77.30)');
  let changed = null;
  const list = stepList(onDHCP, { fixAddress: { chosen: false, onChange: (value) => { changed = value; } } });
  const [box] = inputs(list);
  assert.equal(box?.getAttribute('type'), 'checkbox');
  assert.ok(!box.checked, 'off by default');
  assert.match(list.textContent, /Fix its address so the DNS stays \(keeps 192\.168\.77\.30\)/);
  assert.match(list.textContent, /Keeps its address 192\.168\.77\.30, mask 255\.255\.255\.0 and gateway 192\.168\.77\.1 as they are/);
  box.checked = true;
  box.dispatchEvent({ type: 'change', target: box });
  assert.equal(changed, true);

  // Not chosen: nothing changes, and the run is sent without it.
  assert.equal(summarize(withFixAddress(onDHCP, false)).toChange, 0);
  assert.deepEqual(setupRequest(onDHCP, false), { confirm: true });
  // Chosen: the step will change its address (kept as it is) and its DNS, and the run carries the address the preview showed.
  const chosen = withFixAddress(onDHCP, true);
  const watch = describeStep(chosen.steps[1]);
  assert.equal(watch.statusText, 'Will change');
  assert.deepEqual(watch.lines, ['Address: 192.168.77.30 from the router (DHCP) → 192.168.77.30, fixed (mask 255.255.255.0, gateway 192.168.77.1)',
    'DNS: 8.8.8.8 and 1.1.1.1 from the router (DHCP) → the bridge (192.168.77.2)']);
  assert.equal(watch.detail, null, 'the reason it was not offered alone is gone');
  assert.equal(summarize(chosen).toChange, 1);
  assert.equal(summarize(chosen).watchWillChange, true);
  assert.deepEqual(setupRequest(onDHCP, true),
    { confirm: true, fixAddress: true, keeps: { address: '192.168.77.30', subnetMask: '255.255.255.0', gateway: '192.168.77.1' } });
  assert.equal(inputs(stepList(chosen, { fixAddress: { chosen: true, onChange() {} } }))[0].checked, true);

  // No offer: no checkbox, and the choice changes nothing.
  const plain = { steps: [{ id: 'internetWatch', title: 'Watch its internet', status: 'willChange', changes: [{ label: 'DNS', now: '8.8.8.8', after: 'the bridge' }] }] };
  assert.equal(inputs(stepList(plain, { fixAddress: { chosen: false, onChange() {} } })).length, 0);
  assert.deepEqual(setupRequest(plain, true), { confirm: true });
  assert.deepEqual(withFixAddress(plain, true), plain);
  // A result shows no checkbox.
  assert.equal(inputs(stepList(onDHCP)).length, 0);
});

test('a run that fixed the address shows the router reservation, with the hardware address when the camera said it', () => {
  const done = { id: 'internetWatch', title: 'Watch its internet', status: 'done', changes: [], detail: 'via ISAPI', fixedAddress: keeps };
  assert.equal(describeStep(done).reserve, 'Reserve 192.168.77.30 for this camera in your router (its hardware address is 02:00:00:00:00:30).');
  assert.match(stepList({ steps: [done] }).textContent, /Reserve 192\.168\.77\.30 for this camera in your router \(its hardware address is 02:00:00:00:00:30\)\./);
  const noMAC = { ...done, fixedAddress: { ...keeps, hardwareAddress: undefined } };
  assert.equal(describeStep(noMAC).reserve, 'Reserve 192.168.77.30 for this camera in your router.');
  assert.equal(describeStep({ ...done, fixedAddress: undefined }).reserve, null);
  assert.equal(describeStep({ ...done, fixedAddress: { address: '<b>x</b>' } }).reserve, null, 'only an address');
});

test('a preview whose only offer is the choice does not say “Nothing to change”', () => {
  const unchosen = previewText(onDHCP, false, 'Gate');
  assert.equal(unchosen.title, 'Set up for Camera Bridge?');
  assert.match(unchosen.text, /^Nothing changes on “Gate” unless you choose “Fix its address so the DNS stays” below\./);
  assert.equal(unchosen.open, true, 'Cancel, not Close: there is something to choose');
  const chosen = previewText(onDHCP, true, 'Gate');
  assert.equal(chosen.title, 'Set up for Camera Bridge?');
  assert.match(chosen.text, /^Here is what changes on “Gate”\./);
  const right = previewText({ steps: [{ id: 'timeZone', status: 'alreadyRight' }] }, false, 'Gate');
  assert.equal(right.title, 'Nothing to change');
  assert.equal(right.open, false);
});
