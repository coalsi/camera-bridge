// Night vision on the page (screens/night-vision.js): what status.nightVision reads as, the requests (one at a time, the camera read back,
// the bridge's sentence on a refusal), the camera page's card, the Monitor's buttons and the column they share with the pan/tilt pad, in
// the fake browser with fake requests.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, test } from 'node:test';
import { ApiError } from '../web/js/api.js';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let nv;
before(async () => {
  browser = installFakeBrowser();
  nv = await import('../web/js/screens/night-vision.js');
});
after(() => browser?.restore());

const ID = '0A1B2C3D-0000-4000-8000-000000000002';
const OTHER = '0A1B2C3D-0000-4000-8000-000000000003';
const camera = (nightVision, id = ID) => ({ id, name: 'Driveway', status: { connection: 'online', ...(nightVision === undefined ? {} : { nightVision }) } });
const FULL = { modes: ['auto', 'on', 'off'], mode: 'auto', light: true, lightOn: false };

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList.contains(name));
const modeButton = (root, mode) => all(root, (node) => node.localName === 'button' && node.dataset.mode === mode)[0];
const checkbox = (root) => all(root, (node) => node.localName === 'input')[0];
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const settle = () => new Promise((resolve) => setImmediate(resolve));

/** Fake requests: each send waits until the test answers it (`answer(value)` or `fail(error)`); read gives the camera the test chose. */
function fakeBridge({ readBack = null, readFails = false } = {}) {
  const sent = [];
  const applied = [];
  const waiting = [];
  const deps = {
    send: (path, body) => new Promise((resolve, reject) => { sent.push({ path, body }); waiting.push({ resolve, reject }); }),
    read: async (path) => { if (readFails) throw new ApiError(0, 'network', 'The bridge didn’t answer.'); return typeof readBack === 'function' ? readBack(path) : readBack; },
    apply: (value) => applied.push(value),
  };
  return {
    deps, sent, applied,
    answer: async (value = null) => { waiting.shift().resolve(value); await settle(); },
    fail: async (error) => { waiting.shift().reject(error); await settle(); },
  };
}

// MARK: What status.nightVision reads as

test('a camera without night vision, or one that offers neither a mode nor a light, shows none', () => {
  assert.equal(nv.nightVisionView(null), null);
  assert.equal(nv.nightVisionView(camera(undefined)), null);
  assert.equal(nv.nightVisionView(camera(null)), null);
  assert.equal(nv.nightVisionView(camera({ modes: [], light: false })), null);
  assert.equal(nv.nightVisionView(camera({ modes: ['dusk'], light: false })), null, 'a mode the page does not know is not offered');
  assert.equal(nv.nightVisionView({ id: ID }), null);
});

test('the offered modes come in the page’s order with their words, the mode in use and its hint', () => {
  const view = nv.nightVisionView(camera({ modes: ['off', 'auto', 'on'], mode: 'on', light: true, lightOn: true }));
  assert.deepEqual(view.modes.map((entry) => entry.mode), ['auto', 'on', 'off']);
  assert.deepEqual(view.modes.map((entry) => entry.label), ['Auto', 'Night (IR on)', 'Day (IR off)']);
  assert.deepEqual([view.mode, view.light, view.lightOn], ['on', true, true]);
  assert.equal(view.hint, 'Black and white, with the IR lights on.');
  for (const entry of nv.NIGHT_VISION_MODES) assert.ok(!/firmware/i.test(`${entry.label} ${entry.short} ${entry.hint}`));
});

test('a mode or a lamp the camera hasn’t reported is unknown (the bridge leaves the key out), never guessed', () => {
  const view = nv.nightVisionView(camera({ modes: ['auto', 'off'], light: true }));
  assert.deepEqual([view.mode, view.lightOn, view.hint], [null, null, nv.NIGHT_VISION_TEXT.unknown]);
  assert.equal(nv.nightVisionView(camera({ modes: ['auto'], mode: null, light: false, lightOn: true })).lightOn, null, 'no lamp, no lamp state');
  assert.equal(nv.nightVisionView(camera({ modes: ['auto'], mode: 'dusk', light: false })).mode, null);
  const lampOnly = nv.nightVisionView(camera({ modes: [], light: true, lightOn: false }));
  assert.deepEqual([lampOnly.modes, lampOnly.light, lampOnly.lightOn], [[], true, false]);
});

test('a change applied by hand changes only status.nightVision, and a camera without it stays as it is', () => {
  const before = camera(FULL);
  const next = nv.withNightVision(before, { mode: 'off', light: true });
  assert.deepEqual(next.status.nightVision, { ...FULL, mode: 'off', lightOn: true });
  assert.equal(before.status.nightVision.mode, 'auto', 'the camera it came from is not changed');
  assert.equal(next.status.connection, 'online');
  const plain = camera(undefined);
  assert.equal(nv.withNightVision(plain, { mode: 'on' }), plain);
});

test('a refusal reads as the bridge’s sentence; a script error never shows its own text', () => {
  assert.equal(nv.nightVisionErrorText(new ApiError(422, 'night_vision_failed', 'The camera accepted night vision on but stayed in off.')), 'The camera accepted night vision on but stayed in off.');
  assert.equal(nv.nightVisionErrorText(new ApiError(409, 'no_night_vision', 'This camera can’t switch that right now.')), 'This camera can’t switch that right now.');
  assert.equal(nv.nightVisionErrorText(new ApiError(0, 'timeout', 'The bridge took too long to answer.')), 'The bridge took too long to answer.');
  assert.equal(nv.nightVisionErrorText(new TypeError('x is undefined')), nv.NIGHT_VISION_TEXT.failed);
  assert.equal(nv.nightVisionErrorText(new ApiError(422, 'night_vision_failed', '  ')), nv.NIGHT_VISION_TEXT.failed);
});

// MARK: The requests

test('a change is POST cameras/:id/night-vision, then the camera is read back and put in the store', async () => {
  const fresh = camera({ ...FULL, mode: 'on' });
  const bridge = fakeBridge({ readBack: fresh });
  const requests = nv.createNightVisionRequests(bridge.deps);
  const pending = requests.change(camera(FULL), { mode: 'on' });
  assert.deepEqual(bridge.sent, [{ path: `cameras/${ID}/night-vision`, body: { mode: 'on' } }]);
  assert.equal(requests.busy(ID), true);
  await bridge.answer(null);   // 204
  assert.deepEqual(await pending, { camera: fresh });
  assert.deepEqual(bridge.applied, [fresh]);
  assert.equal(requests.busy(ID), false);
});

test('one change at a time for a camera; another camera is not held up', async () => {
  const bridge = fakeBridge({ readBack: (path) => camera(FULL, path.endsWith(OTHER) ? OTHER : ID) });
  const requests = nv.createNightVisionRequests(bridge.deps);
  const first = requests.change(camera(FULL), { mode: 'off' });
  assert.equal(await requests.change(camera(FULL), { mode: 'on' }), null, 'the second change of the same camera is not sent');
  const other = requests.change(camera(FULL, OTHER), { light: true });
  assert.deepEqual(bridge.sent.map((entry) => entry.path), [`cameras/${ID}/night-vision`, `cameras/${OTHER}/night-vision`]);
  await bridge.answer();
  await bridge.answer();
  assert.ok((await first).camera && (await other).camera);
});

test('a camera in the answer is used as it is; a camera that can’t be read back shows the change as asked', async () => {
  const answered = camera({ ...FULL, mode: 'off' });
  const bridge = fakeBridge({ readBack: () => { throw new Error('read must not be asked'); } });
  const pending = nv.createNightVisionRequests(bridge.deps).change(camera(FULL), { mode: 'off' });
  await bridge.answer(answered);
  assert.equal((await pending).camera, answered);

  const lost = fakeBridge({ readFails: true });
  const asked = nv.createNightVisionRequests(lost.deps).change(camera(FULL), { light: true });
  await lost.answer(null);
  assert.deepEqual((await asked).camera.status.nightVision, { ...FULL, lightOn: true });
  assert.equal(lost.applied.length, 1);
});

test('a refused change gives the sentence and puts nothing in the store', async () => {
  const bridge = fakeBridge();
  const pending = nv.createNightVisionRequests(bridge.deps).change(camera(FULL), { mode: 'on' });
  await bridge.fail(new ApiError(422, 'night_vision_failed', 'The camera accepted night vision on but stayed in auto.'));
  assert.deepEqual(await pending, { message: 'The camera accepted night vision on but stayed in auto.' });
  assert.deepEqual(bridge.applied, []);
});

// MARK: The camera page's card

test('the card is hidden for a camera without night vision and appears when the camera says it has it', () => {
  const card = nv.createNightVisionCard(camera(undefined), fakeBridge().deps);
  assert.equal(card.el.hidden, true);
  card.update(camera(FULL));
  assert.equal(card.el.hidden, false);
  card.update(camera(undefined, OTHER));
  assert.equal(card.el.hidden, false, 'another camera’s news is not this card’s');
  card.update(camera(undefined));
  assert.equal(card.el.hidden, true);
});

test('the card shows the offered modes as one control, the mode in use pressed, its hint, and the IR lights switch only with a lamp', () => {
  const card = nv.createNightVisionCard(camera({ modes: ['auto', 'off'], mode: 'off', light: false }), fakeBridge().deps);
  const group = all(card.el, (node) => node.getAttribute('role') === 'group')[0];
  assert.equal(group.getAttribute('aria-label'), 'Night vision');
  assert.deepEqual(['auto', 'on', 'off'].map((mode) => visible(modeButton(card.el, mode))), [true, false, true]);
  assert.deepEqual(['auto', 'off'].map((mode) => modeButton(card.el, mode).getAttribute('aria-pressed')), ['false', 'true']);
  assert.equal(modeButton(card.el, 'off').textContent, 'Day (IR off)');
  assert.equal(byClass(card.el, 'nv-hint')[0].textContent, 'Colour, with the IR lights off.');
  assert.equal(visible(checkbox(card.el)), false, 'no lamp, no switch');
  card.update(camera({ ...FULL, lightOn: true }));
  assert.equal(visible(checkbox(card.el)), true);
  assert.equal(checkbox(card.el).checked, true);
  assert.equal(checkbox(card.el).getAttribute('role'), 'switch');
  assert.match(card.el.textContent, /IR lights/);
});

test('choosing a mode: everything waits for the camera (marked unavailable, not disabled), then shows what the bridge read back', async () => {
  const bridge = fakeBridge({ readBack: camera({ ...FULL, mode: 'on' }) });
  const card = nv.createNightVisionCard(camera(FULL), bridge.deps);
  modeButton(card.el, 'on').click();
  assert.deepEqual(bridge.sent.map((entry) => entry.body), [{ mode: 'on' }]);
  for (const mode of ['auto', 'on', 'off']) assert.equal(modeButton(card.el, mode).getAttribute('aria-disabled'), 'true');
  assert.equal(checkbox(card.el).getAttribute('aria-disabled'), 'true');
  assert.equal(card.el.getAttribute('aria-busy'), 'true');
  assert.equal(all(card.el, (node) => node.getAttribute('role') === 'status')[0].textContent, 'Switching…');
  modeButton(card.el, 'off').click();
  assert.equal(bridge.sent.length, 1, 'a second press while waiting sends nothing');
  const press = { type: 'click', defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
  checkbox(card.el).dispatchEvent(press);
  assert.equal(press.defaultPrevented, true, 'the switch does not move while waiting');

  await bridge.answer(null);
  assert.equal(modeButton(card.el, 'on').getAttribute('aria-pressed'), 'true');
  assert.equal(modeButton(card.el, 'auto').getAttribute('aria-pressed'), 'false');
  assert.equal(modeButton(card.el, 'on').hasAttribute('aria-disabled'), false);
  assert.equal(card.el.getAttribute('aria-busy'), 'false');
  assert.equal(byClass(card.el, 'nv-hint')[0].textContent, 'Black and white, with the IR lights on.');
  assert.equal(bridge.applied.length, 1, 'the camera read back went to the store');
});

test('the mode already in use sends nothing', () => {
  const bridge = fakeBridge();
  const card = nv.createNightVisionCard(camera(FULL), bridge.deps);
  modeButton(card.el, 'auto').click();
  assert.deepEqual(bridge.sent, []);
});

test('a refusal (422) shows the bridge’s sentence in the error style, keeps the mode as it was, and goes with the next change that works', async () => {
  const bridge = fakeBridge({ readBack: camera({ ...FULL, mode: 'off' }) });
  const card = nv.createNightVisionCard(camera(FULL), bridge.deps);
  modeButton(card.el, 'on').click();
  await bridge.fail(new ApiError(422, 'night_vision_failed', 'The camera accepted night vision on but stayed in auto.'));
  const banner = all(card.el, (node) => node.classList.contains('banner'))[0];
  assert.ok(banner?.classList.contains('error'), 'the error banner');
  assert.equal(banner.getAttribute('role'), 'alert');
  assert.equal(banner.textContent, 'The camera accepted night vision on but stayed in auto.');
  assert.equal(modeButton(card.el, 'auto').getAttribute('aria-pressed'), 'true');
  assert.equal(modeButton(card.el, 'on').hasAttribute('aria-disabled'), false, 'the controls work again');
  card.update(camera({ ...FULL }));
  assert.equal(all(card.el, (node) => node.classList.contains('banner'))[0], banner, 'news from the store does not draw the alert again');

  modeButton(card.el, 'off').click();
  assert.equal(all(card.el, (node) => node.classList.contains('banner')).length, 0, 'a new try clears it');
  await bridge.answer(null);
  assert.equal(modeButton(card.el, 'off').getAttribute('aria-pressed'), 'true');
});

test('the IR lights switch sends light on or off; a refused one goes back to where the lamp is', async () => {
  const bridge = fakeBridge({ readBack: camera({ ...FULL, lightOn: true }) });
  const card = nv.createNightVisionCard(camera(FULL), bridge.deps);
  const input = checkbox(card.el);
  input.checked = true;
  input.dispatchEvent({ type: 'change', target: input });
  assert.deepEqual(bridge.sent.map((entry) => entry.body), [{ light: true }]);
  await bridge.answer(null);
  assert.equal(input.checked, true);

  input.checked = false;
  input.dispatchEvent({ type: 'change', target: input });
  assert.deepEqual(bridge.sent.at(-1).body, { light: false });
  await bridge.fail(new ApiError(409, 'no_night_vision', 'This camera can’t switch that right now.'));
  assert.equal(input.checked, true, 'the lamp is still on');
  assert.match(card.el.textContent, /This camera can’t switch that right now\./);
});

test('the IR lights switch stays where it was put while the camera answers, then shows the lamp: on as answered, or back after a refusal', async () => {
  const bridge = fakeBridge({ readBack: camera({ ...FULL, lightOn: true }) });
  const card = nv.createNightVisionCard(camera(FULL), bridge.deps);
  const input = checkbox(card.el);
  input.checked = true;
  input.dispatchEvent({ type: 'change', target: input });
  assert.equal(all(card.el, (node) => node.getAttribute('role') === 'status')[0].textContent, 'Switching…');
  assert.equal(input.checked, true, 'on while the camera answers, not back to off beside “Switching…”');
  card.update(camera(FULL));   // the store hears from the camera meanwhile, its lamp still off
  assert.equal(input.checked, true, 'news from the store does not move it back either');
  await bridge.answer(null);
  assert.equal(input.checked, true);

  input.checked = false;
  input.dispatchEvent({ type: 'change', target: input });
  assert.equal(input.checked, false, 'off while the camera answers');
  await bridge.fail(new ApiError(422, 'night_vision_failed', 'The camera refused the lamp command.'));
  assert.equal(input.checked, true, 'refused: back where the lamp is');
  modeButton(card.el, 'off').click();
  assert.equal(input.checked, true, 'a mode change leaves the switch where the lamp is');
  await bridge.answer(null);
});

test('news from the store moves the card in place, even while a change is on its way', async () => {
  const bridge = fakeBridge({ readBack: camera({ ...FULL, mode: 'on' }) });
  const card = nv.createNightVisionCard(camera(FULL), bridge.deps);
  card.update(camera({ ...FULL, mode: 'off' }));
  assert.equal(modeButton(card.el, 'off').getAttribute('aria-pressed'), 'true');
  modeButton(card.el, 'on').click();
  card.update(camera({ ...FULL, mode: 'off', lightOn: true }));
  assert.equal(checkbox(card.el).checked, true);
  assert.equal(modeButton(card.el, 'on').getAttribute('aria-disabled'), 'true', 'still waiting');
  await bridge.answer(null);
  assert.equal(modeButton(card.el, 'on').getAttribute('aria-pressed'), 'true');
  card.destroy();
});

test('the camera page carries the card and moves it in place when the store hears from the camera (the page is not built again)', async () => {
  const { store, putCamera } = await import('../web/js/store.js');
  const { renderCamera } = await import('../web/js/screens/camera.js');
  const { CAMERA_DEFINITIONS, cameraConfiguration } = await import('../web-dev/lib/cameras.mjs');
  globalThis.Image = class { set src(value) { this.value = value; } get src() { return this.value; } };   // the preview's snapshots
  const start = { ...cameraConfiguration(CAMERA_DEFINITIONS[1]), vendorName: 'ONVIF',
    status: { connection: 'online', summary: 'Live', recentEvents: [], nvr: { state: 'off', detail: null, pause: null, notes: [] } } };
  store.cameras.set(start.id, start);
  const page = renderCamera({ params: [start.id], navigate() {}, setTitle() {} });
  try {
    await settle();
    const card = byClass(page.el, 'nv-card')[0];
    assert.ok(card, 'the card is on the page');
    assert.equal(card.hidden, true, 'hidden while the camera has said nothing about night vision');
    putCamera({ ...start, status: { ...start.status, nightVision: FULL } });
    assert.equal(byClass(page.el, 'nv-card')[0], card, 'the same card');
    assert.equal(card.hidden, false);
    assert.equal(modeButton(card, 'auto').getAttribute('aria-pressed'), 'true');
    putCamera({ ...start, status: { ...start.status, nightVision: { ...FULL, mode: 'off' } } });
    assert.equal(modeButton(card, 'off').getAttribute('aria-pressed'), 'true');
  } finally {
    page.destroy();
    store.cameras.clear();
    delete globalThis.Image;
  }
});

// MARK: The Monitor's buttons

test('the Monitor’s buttons show only for a camera with night vision, each mode with its words and the IR lights toggle', () => {
  const buttons = nv.createNightVisionButtons(fakeBridge().deps);
  assert.equal(buttons.el.hidden, true);
  buttons.setCamera(camera(undefined));
  assert.equal(buttons.el.hidden, true);
  buttons.setCamera(camera(FULL));
  assert.equal(buttons.el.hidden, false);
  assert.deepEqual(['auto', 'on', 'off'].map((mode) => modeButton(buttons.el, mode).getAttribute('aria-label')), ['Auto', 'Night (IR on)', 'Day (IR off)']);
  assert.deepEqual(['auto', 'on', 'off'].map((mode) => modeButton(buttons.el, mode).getAttribute('aria-pressed')), ['true', 'false', 'false']);
  assert.equal(modeButton(buttons.el, 'on').getAttribute('title'), 'Night (IR on): Black and white, with the IR lights on.');
  assert.equal(modeButton(buttons.el, 'on').textContent, 'Night', 'the short word under the icon (the label holds it, for voice control)');
  const light = byClass(buttons.el, 'mon-nv-light')[0];
  assert.deepEqual([light.getAttribute('aria-label'), light.getAttribute('aria-pressed'), byClass(light, 'mon-nv-state')[0].textContent], ['IR lights', 'false', 'Off']);
  buttons.setCamera(camera({ modes: ['auto', 'off'], light: false }));
  assert.equal(modeButton(buttons.el, 'on').hidden, true);
  assert.equal(light.hidden, true);
  buttons.setCamera(null);
  assert.equal(buttons.el.hidden, true);
});

test('a press on the Monitor waits for the camera, then shows its answer; a refusal says why under the buttons', async () => {
  const bridge = fakeBridge({ readBack: camera({ ...FULL, mode: 'off' }) });
  const buttons = nv.createNightVisionButtons(bridge.deps);
  buttons.setCamera(camera(FULL));
  modeButton(buttons.el, 'off').click();
  const status = all(buttons.el, (node) => node.getAttribute('role') === 'status')[0];
  assert.equal(status.textContent, 'Switching…');
  assert.equal(modeButton(buttons.el, 'auto').getAttribute('aria-disabled'), 'true');
  buttons.setCamera(camera(FULL));   // the wall draws again meanwhile
  assert.equal(modeButton(buttons.el, 'auto').getAttribute('aria-disabled'), 'true');
  modeButton(buttons.el, 'on').click();
  assert.equal(bridge.sent.length, 1);
  await bridge.answer(null);
  assert.equal(modeButton(buttons.el, 'off').getAttribute('aria-pressed'), 'true');
  assert.equal(status.textContent, '');

  byClass(buttons.el, 'mon-nv-light')[0].click();
  assert.deepEqual(bridge.sent.at(-1).body, { light: true }, 'the lamp was off');
  await bridge.fail(new ApiError(422, 'night_vision_failed', 'The camera refused the lamp command.'));
  assert.equal(status.textContent, 'The camera refused the lamp command.');
  buttons.setCamera(camera(FULL));
  assert.equal(status.textContent, 'The camera refused the lamp command.', 'it stays while the same camera is shown');
  buttons.setCamera(camera(FULL, OTHER));
  assert.equal(status.textContent, '', 'another camera starts clean');
  buttons.destroy();
});

test('a new refusal on the Monitor is brought into view once (the column scrolls on a narrower screen), the wall drawing again does not', async () => {
  const bridge = fakeBridge();
  const buttons = nv.createNightVisionButtons(bridge.deps);
  buttons.setCamera(camera(FULL));
  const status = all(buttons.el, (node) => node.getAttribute('role') === 'status')[0];
  const shown = [];
  status.scrollIntoView = (options) => shown.push(options);
  modeButton(buttons.el, 'on').click();
  assert.deepEqual(shown, [], 'not for “Switching…”');
  await bridge.fail(new ApiError(422, 'night_vision_failed', 'The camera kept its old setting.'));
  assert.deepEqual(shown, [{ block: 'nearest' }]);
  buttons.setCamera(camera({ ...FULL, lightOn: true }));   // news from the store: drawn again, the sentence stays
  assert.equal(status.textContent, 'The camera kept its old setting.');
  assert.equal(shown.length, 1);
  modeButton(buttons.el, 'on').click();
  await bridge.fail(new ApiError(422, 'night_vision_failed', 'The camera kept its old setting.'));
  assert.equal(shown.length, 2, 'the same sentence after another try is shown again');
});

test('a lamp whose state is unknown is turned on by the toggle', () => {
  const bridge = fakeBridge();
  const buttons = nv.createNightVisionButtons(bridge.deps);
  buttons.setCamera(camera({ modes: ['auto'], mode: 'auto', light: true }));
  const light = byClass(buttons.el, 'mon-nv-light')[0];
  assert.equal(byClass(light, 'mon-nv-state')[0].textContent, '');
  light.click();
  assert.deepEqual(bridge.sent.map((entry) => entry.body), [{ light: true }]);
});

test('an answer that arrives after the wall moved to another camera changes nothing on screen', async () => {
  const bridge = fakeBridge({ readBack: camera({ ...FULL, mode: 'on' }) });
  const buttons = nv.createNightVisionButtons(bridge.deps);
  buttons.setCamera(camera(FULL));
  modeButton(buttons.el, 'on').click();
  buttons.setCamera(camera({ ...FULL, mode: 'off' }, OTHER));
  assert.equal(modeButton(buttons.el, 'off').hasAttribute('aria-disabled'), false, 'the other camera is not waiting');
  await bridge.fail(new ApiError(422, 'night_vision_failed', 'The camera kept its old setting.'));
  assert.equal(all(buttons.el, (node) => node.getAttribute('role') === 'status')[0].textContent, '');
  assert.equal(modeButton(buttons.el, 'off').getAttribute('aria-pressed'), 'true');
});

// MARK: The Monitor's column

test('the Monitor’s column holds the pad for a camera that turns and the buttons for one with night vision, and says when it holds both', async () => {
  const { createPanTiltPad } = await import('../web/js/live/pan-tilt.js');
  const pad = createPanTiltPad();
  const buttons = nv.createNightVisionButtons(fakeBridge().deps);
  const side = nv.createMonitorSide(pad, buttons);
  const turning = (extra) => ({ ...camera(undefined), status: { connection: 'online', panTilt: true, zoom: false, ...extra } });
  assert.equal(side.el.classList.contains('mon-side'), true);
  assert.deepEqual([...side.el.childNodes], [pad.el, buttons.el], 'the pad first, the night vision beside or under it');
  assert.deepEqual([side.el.hidden, side.el.dataset.both], [true, 'false'], 'nothing opened on its own');

  side.setCamera(turning());
  assert.deepEqual([side.el.hidden, pad.el.hidden, buttons.el.hidden, side.el.dataset.both], [false, false, true, 'false'], 'a camera that only turns');
  side.setCamera(camera(FULL));
  assert.deepEqual([side.el.hidden, pad.el.hidden, buttons.el.hidden, side.el.dataset.both], [false, true, false, 'false'], 'night vision alone');
  side.setCamera(turning({ zoom: true, nightVision: FULL }));
  assert.deepEqual([side.el.hidden, pad.el.hidden, buttons.el.hidden, side.el.dataset.both], [false, false, false, 'true'], 'both: side by side where there is room');
  assert.equal(byClass(pad.el, 'mon-ptz-zoom')[0].hidden, false, 'with its zoom');
  side.setCamera(camera(undefined));
  assert.deepEqual([side.el.hidden, side.el.dataset.both], [true, 'false'], 'neither');
  side.setCamera(turning({ nightVision: FULL }));
  side.setCamera(null);
  assert.deepEqual([side.el.hidden, pad.el.hidden, buttons.el.hidden, side.el.dataset.both], [true, true, true, 'false'], 'back to the whole wall');
  side.destroy();
});

test('monitor.css keeps the column with both no taller than the events: side by side on a wide screen, else stacked and scrolling', () => {
  const css = readFileSync(new URL('../web/monitor.css', import.meta.url), 'utf8');
  const match = (pattern) => { const found = css.match(pattern); assert.ok(found, `${pattern} is in monitor.css`); return found.slice(1).map(Number); };
  const [events] = match(/\.mon-activity \{ max-height: (\d+)px;/);
  const [wide] = match(/@media \(min-width: (\d+)px\) \{ \.mon-side\[data-both="true"\] \{ flex-direction: row; \} \}/);
  assert.ok(wide > 1100, `side by side from ${wide} px: never where the row under the wall is one column, nor on a phone`);
  const [from, to, column] = match(/@media \(min-width: (\d+)px\) and \(max-width: (\d+)px\) \{ \.mon-side\[data-both="true"\] \{ max-height: (\d+)px; overflow: hidden auto;/);
  assert.deepEqual([from, to], [900, wide - 1], 'stacked and held from where the monitor has a fixed height (900 px) up to side by side');
  assert.ok(column <= events, `the stacked column (${column} px) is no taller than the events (${events} px)`);
});
