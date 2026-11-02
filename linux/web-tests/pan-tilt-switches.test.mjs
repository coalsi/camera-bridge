// The camera page's pan, tilt and zoom card (screens/camera.js createPanTiltCard): the owner's switches for a camera whose control says it
// pans, tilts or zooms (some fixed cameras say so when they can't). A switch shows only for what the control said (status.panTiltDetected,
// status.zoomDetected), is on unless the owner turned it off (panTiltEnabled, zoomEnabled false), saves with PATCH cameras/:id (with the
// CSRF token, as every camera option does) and follows the camera in place, in the fake browser with fake requests. The dev server's side
// is in night-vision-server.test.mjs.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let page;
let api;
let store;
let putCamera;
let CAMERA_DEFINITIONS;
let cameraConfiguration;
before(async () => {
  browser = installFakeBrowser();
  globalThis.Image = class { set src(value) { this.value = value; } get src() { return this.value; } };   // the preview's snapshots
  page = await import('../web/js/screens/camera.js');
  api = await import('../web/js/api.js');
  ({ store, putCamera } = await import('../web/js/store.js'));
  ({ CAMERA_DEFINITIONS, cameraConfiguration } = await import('../web-dev/lib/cameras.mjs'));
});
after(() => {
  delete globalThis.Image;
  browser?.restore();
});

const PATIO = '0A1B2C3D-0000-4000-8000-000000000031';
const NOTE = 'Some cameras say they can move or zoom when they can’t. Turn off what this one can’t do, and the Monitor and the Apple TV app no longer show its controls.';
/** A camera whose control said `detected` ({ panTilt, zoom }), with the owner's switches as `saved` gives them (absent: as detected). */
const camera = (detected = {}, saved = {}) => ({
  id: PATIO, name: 'Patio', ...saved,
  status: { connection: 'online', panTilt: false, zoom: false, panTiltDetected: detected.panTilt === true, zoomDetected: detected.zoom === true },
});

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
/** The card's visible switches, as [title, on]. */
const switches = (root) => all(root, (node) => node.localName === 'label' && node.classList.contains('switch-row') && visible(node))
  .map((row) => [byClass(row, 'title')[0].textContent, all(row, (node) => node.localName === 'input')[0].checked]);
/** The input of the switch titled `title`. */
const input = (root, title) => all(root, (node) => node.localName === 'label' && byClass(node, 'title')[0]?.textContent === title)
  .map((row) => all(row, (node) => node.localName === 'input')[0])[0];
const flip = (control, on) => { control.checked = on; control.dispatchEvent({ type: 'change', target: control }); };
const heading = (root) => all(root, (node) => node.localName === 'h2')[0].textContent;
const settle = async () => { for (let i = 0; i < 5; i += 1) await new Promise((resolve) => setImmediate(resolve)); };

// MARK: The card

test('the card shows a switch only for what the camera’s control said, under the one line about cameras that say they move', () => {
  const card = page.createPanTiltCard(camera(), { save() {} });
  assert.equal(card.el.hidden, true, 'hidden while the control said neither (it answers once the camera runs)');

  card.update(camera({ panTilt: true, zoom: true }));
  assert.equal(card.el.hidden, false);
  assert.equal(heading(card.el), 'Pan, tilt and zoom');
  assert.deepEqual(switches(card.el), [['Pan and tilt', true], ['Zoom', true]], 'on by default: as the control says');
  assert.ok(all(card.el, (node) => node.localName === 'p' && visible(node)).some((node) => node.textContent === NOTE), 'the one plain line');
  assert.equal(page.PAN_TILT_TEXT.note, NOTE);
  for (const control of all(card.el, (node) => node.localName === 'input')) assert.equal(control.getAttribute('role'), 'switch');

  card.update(camera({ panTilt: true }));
  assert.equal(heading(card.el), 'Pan and tilt');
  assert.deepEqual(switches(card.el), [['Pan and tilt', true]], 'a camera that does not zoom has no Zoom switch');
  card.update(camera({ zoom: true }));
  assert.equal(heading(card.el), 'Zoom');
  assert.deepEqual(switches(card.el), [['Zoom', true]]);
  card.update({ id: PATIO, name: 'Patio' });
  assert.equal(card.el.hidden, true, 'no status yet: nothing to offer');
});

test('a switch the owner turned off shows off; true and absent are both on', () => {
  const card = page.createPanTiltCard(camera({ panTilt: true, zoom: true }, { panTiltEnabled: false }), { save() {} });
  assert.deepEqual(switches(card.el), [['Pan and tilt', false], ['Zoom', true]]);
  card.update(camera({ panTilt: true, zoom: true }, { panTiltEnabled: true, zoomEnabled: false }));
  assert.deepEqual(switches(card.el), [['Pan and tilt', true], ['Zoom', false]]);
  // Turned off, then the control stopped saying it (the camera restarted and has not answered yet): the switch waits, hidden, as it was.
  card.update(camera({ panTilt: true }, { zoomEnabled: false }));
  assert.deepEqual(switches(card.el), [['Pan and tilt', true]]);
  card.update(camera({ panTilt: true, zoom: true }, { zoomEnabled: false }));
  assert.deepEqual(switches(card.el), [['Pan and tilt', true], ['Zoom', false]]);
});

test('a flip saves that switch alone, and the camera’s news does not move it back while the change is on its way', () => {
  const saved = [];
  let busy = null;
  const card = page.createPanTiltCard(camera({ panTilt: true, zoom: true }), { save: (change) => saved.push(change), busy: (key) => key === busy });
  flip(input(card.el, 'Pan and tilt'), false);
  assert.deepEqual(saved, [{ panTiltEnabled: false }]);
  busy = 'panTiltEnabled';
  card.update(camera({ panTilt: true, zoom: true }));   // the camera's status moved meanwhile, its switch not saved yet
  assert.deepEqual(switches(card.el), [['Pan and tilt', false], ['Zoom', true]], 'not back on while the change waits');
  busy = null;
  card.update(camera({ panTilt: true, zoom: true }, { panTiltEnabled: false }));   // saved
  assert.deepEqual(switches(card.el), [['Pan and tilt', false], ['Zoom', true]]);
  flip(input(card.el, 'Zoom'), false);
  flip(input(card.el, 'Pan and tilt'), true);
  assert.deepEqual(saved, [{ panTiltEnabled: false }, { zoomEnabled: false }, { panTiltEnabled: true }]);
});

// MARK: The camera page

const reply = (status, data) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});

/** `value` with its keys sorted, as the bridge's JSON has them. */
const sorted = (value) => Object.fromEntries(Object.entries(value).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));

/**
 * The camera page of Driveway, whose control says it pans, tilts and zooms, with fetch answering PATCH cameras/:id as the bridge does: the
 * camera with the change in it, its keys sorted (so a switch it did not have before comes in the middle of the answer, not at its end).
 */
async function openPage() {
  const start = sorted({ ...cameraConfiguration(CAMERA_DEFINITIONS[1]), vendorName: 'ONVIF',
    status: { connection: 'online', summary: 'Live', recentEvents: [], panTilt: true, zoom: true, panTiltDetected: true, zoomDetected: true,
      nvr: { state: 'off', detail: null, pause: null, notes: [] } } });
  store.cameras.set(start.id, start);
  const requests = [];
  let current = start;
  globalThis.fetch = async (url, init = {}) => {
    if (init.method === 'PATCH' && url === `/api/v1/cameras/${start.id}`) {
      const body = JSON.parse(init.body);
      requests.push({ body, headers: init.headers });
      current = sorted({ ...current, ...body, status: { ...current.status, panTilt: body.panTiltEnabled ?? current.status.panTilt } });
      return reply(200, current);
    }
    return reply(404, { error: 'not_found', message: 'There is nothing here.' });
  };
  const screen = page.renderCamera({ params: [start.id], navigate() {}, setTitle() {} });
  let card;
  for (let tries = 0; tries < 400 && !card; tries += 1) {
    card = byClass(screen.el, 'ptz-card')[0];
    if (!card) await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.ok(card, 'the card is on the page');
  return { start, screen, card, requests, close() { screen.destroy(); store.cameras.clear(); } };
}

test('the camera page has the card after Night vision, and a flip saves it with PATCH cameras/:id and the CSRF token', async (t) => {
  api.setCSRFToken('csrf-of-this-page');
  const p = await openPage();
  try {
    const cards = byClass(p.screen.el, 'card');
    assert.equal(cards[cards.indexOf(p.card) - 1], byClass(p.screen.el, 'nv-card')[0], 'right after the Night vision card');
    assert.deepEqual(switches(p.card), [['Pan and tilt', true], ['Zoom', true]]);
    const motion = cards.find((node) => node.childNodes[0]?.textContent === 'Motion');

    t.mock.timers.enable({ apis: ['setTimeout'] });
    flip(input(p.card, 'Pan and tilt'), false);
    await settle();
    assert.equal(p.requests.length, 0, 'saved a moment later, as the page’s other options are');
    t.mock.timers.tick(600);
    await settle();
    assert.deepEqual(p.requests.map((request) => request.body), [{ panTiltEnabled: false }]);
    assert.equal(p.requests[0].headers['X-CSRF-Token'], 'csrf-of-this-page');
    assert.equal(p.requests[0].headers['Content-Type'], 'application/json');
    assert.equal(store.cameras.get(p.start.id).panTiltEnabled, false, 'the answer is the camera, in the store');
    assert.equal(byClass(p.screen.el, 'card').find((node) => node.childNodes[0]?.textContent === 'Motion'), motion,
      'the page was not built again, though the answer carries the switch the camera did not have before');
    assert.deepEqual(switches(p.card), [['Pan and tilt', false], ['Zoom', true]]);
  } finally {
    t.mock.timers.reset();   // the page's own timers were made before: they are stopped with the real clock
    p.close();
  }
});

test('the card follows the camera in place: news from another browser moves the switch, and the page is not built again', async () => {
  const p = await openPage();
  try {
    const motion = byClass(p.screen.el, 'card').find((node) => node.childNodes[0]?.textContent === 'Motion');
    putCamera(sorted({ ...p.start, zoomEnabled: false }));
    await settle();   // a rebuild would have drawn the right column again by now
    assert.equal(byClass(p.screen.el, 'ptz-card')[0], p.card);
    assert.equal(byClass(p.screen.el, 'card').find((node) => node.childNodes[0]?.textContent === 'Motion'), motion, 'nothing was built again');
    assert.deepEqual(switches(p.card), [['Pan and tilt', true], ['Zoom', false]]);
    putCamera(sorted({ ...p.start, zoomEnabled: false, status: { ...p.start.status, panTiltDetected: false, zoomDetected: false } }));
    assert.equal(p.card.hidden, true, 'the control no longer says (the camera went away): no switches');
  } finally {
    p.close();
  }
});
