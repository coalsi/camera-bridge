// The Sky Watcher card on the camera page (screens/camera.js): the whole page in the fake browser with fake requests. Sky Watcher is a plugin:
// every camera's page has the card while the plugin is on and none while it is off. The card follows the AI descriptions card, turns the
// camera's sky settings on with one save (the bridge's refusal reaches the card, which says it in place), and neither the switch nor the
// camera's news builds the page again.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let store;
let putCamera;
let setPlugins;
let renderCamera;
let CAMERA_DEFINITIONS;
let cameraConfiguration;

before(async () => {
  browser = installFakeBrowser();
  globalThis.Image = class { set src(value) { this.value = value; } get src() { return this.value; } };
  ({ store, putCamera, setPlugins } = await import('../web/js/store.js'));
  ({ renderCamera } = await import('../web/js/screens/camera.js'));
  ({ CAMERA_DEFINITIONS, cameraConfiguration } = await import('../web-dev/lib/cameras.mjs'));
});
after(() => {
  delete globalThis.Image;
  browser?.restore();
});

const PLACE = { latitude: 40, longitude: -100, heightMeters: 0 };
const NEED_LOCATION = 'Set where the box is first.';

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList.contains(name));
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const cardTitled = (root, title) => byClass(root, 'card').find((card) => card.childNodes.some((child) => child.localName === 'h2' && child.textContent === title));
const theSwitch = (card) => all(card, (node) => node.localName === 'input' && node.getAttribute('role') === 'switch')[0];
const settle = async () => { for (let i = 0; i < 6; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
const flip = (input, on) => { input.checked = on; input.dispatchEvent({ type: 'change', target: input }); };
const reply = (status, data) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});

/** The bridge behind fetch: GET settings (with where the box is), and PATCH cameras/:id, which answers the camera with the change in it or refuses. */
function fakeBridge(camera, { refuse = null, refuseField = 'sky.location', place = PLACE } = {}) {
  const patches = [];
  let current = camera;
  globalThis.fetch = async (url, init = {}) => {
    if (init.method === 'PATCH' && url === `/api/v1/cameras/${camera.id}`) {
      const body = JSON.parse(init.body);
      patches.push(body);
      if (refuse) return reply(400, { error: 'invalid', message: refuse, field: refuseField });
      current = { ...current, ...body };
      return reply(200, current);
    }
    if (!init.method || init.method === 'GET') {
      if (url === '/api/v1/settings') return reply(200, { bridgeName: 'Bridge', webhookEnabled: false, webhookPort: 21090, sky: { location: place, flightFeedURL: null, aiDailyLimit: 50 } });
    }
    return reply(404, { error: 'not_found', message: 'There is nothing here.' });
  };
  return { patches };
}

async function until(find) {
  for (let tries = 0; tries < 400; tries += 1) {
    const found = find();
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error('it never appeared');
}

/** The camera's page; `plugin` says whether the Sky Watcher plugin is on (it is, unless a test says it is not). */
async function openPage(extra = {}, bridgeOptions = {}, { plugin = true } = {}) {
  const camera = {
    ...cameraConfiguration(CAMERA_DEFINITIONS[1]), vendorName: 'ONVIF', aiDescriptions: false,
    status: { connection: 'online', summary: 'Live', recentEvents: [], nvr: { state: 'off', detail: null, pause: null, notes: [] } }, ...extra,
  };
  store.cameras.set(camera.id, camera);
  setPlugins([{ id: 'sky', enabled: plugin }]);
  const bridge = fakeBridge(camera, bridgeOptions);
  const page = renderCamera({ params: [camera.id], navigate() {}, setTitle() {} });
  const close = () => { page.destroy(); store.cameras.clear(); setPlugins([]); };
  let card = null;
  try {
    // With the plugin off there is no card to wait for: the card after it (Audio) says the right column is drawn.
    card = await until(() => (plugin ? cardTitled(page.el, 'Sky Watcher') : cardTitled(page.el, 'AI descriptions') && cardTitled(page.el, 'Remove')));
  } catch (error) {
    close();
    throw error;
  }
  await settle();
  return { camera, bridge, page, card: plugin ? card : null, close };
}

test('the card follows the AI descriptions card, and is off for a camera that never watched the sky', async () => {
  const p = await openPage();
  try {
    const cards = byClass(p.page.el, 'card');
    assert.equal(cards.indexOf(p.card), cards.indexOf(cardTitled(p.page.el, 'AI descriptions')) + 1, 'right after the AI descriptions card');
    assert.equal(theSwitch(p.card).checked, false);
    assert.equal(visible(byClass(p.card, 'sky-setup')[0]), false);
  } finally {
    p.close();
  }
});

test('turning it on sends the camera’s sky settings in one request, and the page is not built again', async () => {
  const p = await openPage({ skyDetector: { enabled: false, facing: 0, tilt: 20, groundPercent: 12, nightProfile: true, lensLayout: 'dual' } });
  try {
    const preview = byClass(p.page.el, 'preview')[0];
    flip(theSwitch(p.card), true);
    await settle();
    assert.deepEqual(p.bridge.patches, [{ skyDetector: { enabled: true, facing: 0, tilt: 20, groundPercent: 12, nightProfile: true, lensLayout: 'dual' } }], 'one save, at once');
    assert.equal(cardTitled(p.page.el, 'Sky Watcher'), p.card, 'the card is the same');
    assert.equal(byClass(p.page.el, 'preview')[0], preview, 'the preview keeps running');
    assert.equal(store.cameras.get(p.camera.id).skyDetector.enabled, true, 'the store has the bridge’s answer');
    assert.equal(theSwitch(p.card).checked, true);
    assert.ok(visible(byClass(p.card, 'sky-status')[0]), 'the status is there');
    assert.deepEqual(all(p.card, (node) => node.localName === 'a' && visible(node)).map((a) => a.getAttribute('href')), [`#/sky/${p.camera.id}`]);

    // News from the camera: its status moves the lines, nothing is built again.
    putCamera({ ...store.cameras.get(p.camera.id), status: { ...p.camera.status, sky: {
      running: true, stream: 'main', analysisWidth: 1920, picturesPerSecond: 5, aim: { quality: 'good', planes: 23, stars: 0, residualPixels: 14, lenses: [{ quality: 'good', planes: 12, stars: 0, residualPixels: 12 }, { quality: 'good', planes: 11, stars: 0, residualPixels: 16 }] },
      learning: { ready: true, planes: 31, satellites: 12 } } } });
    const lines = all(p.card, (node) => node.localName === 'p' && visible(node)).map((node) => node.textContent);
    assert.ok(lines.includes('Left lens: good, 12 planes matched, 12 px'));
    assert.ok(lines.includes('Right lens: good, 11 planes matched, 16 px'));
    assert.ok(lines.includes('Watching the main stream at 1920 px, 5 pictures a second'));
    assert.equal(cardTitled(p.page.el, 'Sky Watcher'), p.card);
    assert.equal(byClass(p.page.el, 'preview')[0], preview);
  } finally {
    p.close();
  }
});

test('the bridge’s refusal shows in the card, the switch goes back to off, and the camera is not changed', async () => {
  const p = await openPage({}, { refuse: NEED_LOCATION, place: null });
  try {
    flip(theSwitch(p.card), true);
    await settle();
    assert.equal(p.bridge.patches.length, 0, 'asking first: a camera that never watched the sky');
    const start = all(p.card, (node) => node.localName === 'button' && node.textContent === 'Start watching')[0];
    start.click();
    await settle();
    assert.equal(p.bridge.patches.length, 1);
    const alerts = all(p.card, (node) => node.getAttribute?.('role') === 'alert' && visible(node)).map((node) => node.textContent);
    assert.deepEqual(alerts, [NEED_LOCATION]);
    assert.equal(theSwitch(p.card).checked, false);
    assert.equal(store.cameras.get(p.camera.id).skyDetector, undefined, 'nothing was turned on');
    assert.equal(cardTitled(p.page.el, 'Sky Watcher'), p.card, 'and the page is not built again');
  } finally {
    p.close();
  }
});

test('while the Sky Watcher plugin is off no camera page has the card, and the rest of the page is as always', async () => {
  const p = await openPage({ skyDetector: { enabled: true, facing: 0, tilt: 20, groundPercent: 12, nightProfile: true, lensLayout: 'dual' } }, {}, { plugin: false });
  try {
    assert.equal(cardTitled(p.page.el, 'Sky Watcher'), undefined, 'no Sky Watcher card, though this camera was set to watch the sky');
    assert.ok(cardTitled(p.page.el, 'AI descriptions'), 'the cards around it are there');
    assert.ok(cardTitled(p.page.el, 'Remove'));
    assert.equal(all(p.page.el, (node) => node.getAttribute?.('href') === `#/sky/${p.camera.id}`).length, 0, 'and no way to its log from here');
    assert.deepEqual(p.bridge.patches, [], 'nothing was sent');
    assert.equal(store.cameras.get(p.camera.id).skyDetector.enabled, true, 'the camera keeps what it was set to');
  } finally {
    p.close();
  }
});

test('every camera’s page has the card while the plugin is on, a camera that never watched the sky included', async () => {
  for (const definition of [CAMERA_DEFINITIONS[0], CAMERA_DEFINITIONS[2]]) {
    const camera = { ...cameraConfiguration(definition), vendorName: 'ONVIF', aiDescriptions: false, status: { connection: 'online', summary: 'Live', recentEvents: [], nvr: { state: 'off', detail: null, pause: null, notes: [] } } };
    store.cameras.set(camera.id, camera);
    setPlugins([{ id: 'sky', enabled: true }]);
    fakeBridge(camera);
    const page = renderCamera({ params: [camera.id], navigate() {}, setTitle() {} });
    try {
      const card = await until(() => cardTitled(page.el, 'Sky Watcher'));
      assert.ok(card, definition.name);
      assert.equal(theSwitch(card).checked, false, `${definition.name}: never watched, off`);
    } finally {
      page.destroy();
      store.cameras.clear();
      setPlugins([]);
    }
  }
});

test('a camera page opened before the plugin was switched on has the card the next time it is opened', async () => {
  const off = await openPage({}, {}, { plugin: false });
  off.close();
  const on = await openPage({}, {}, { plugin: true });
  try {
    assert.ok(on.card, 'the card is there once the plugin is on');
  } finally {
    on.close();
  }
});

test('the bridge’s “turn on Sky Watcher in Plugins first” reaches the card with a way to Plugins, and the camera is not changed', async () => {
  const p = await openPage({}, { refuse: 'Turn on Sky Watcher in Plugins first.', refuseField: 'plugins.sky' });
  try {
    flip(theSwitch(p.card), true);
    await settle();
    all(p.card, (node) => node.localName === 'button' && node.textContent === 'Start watching')[0].click();
    await settle();
    const alerts = all(p.card, (node) => node.getAttribute?.('role') === 'alert' && visible(node)).map((node) => node.textContent);
    assert.deepEqual(alerts, ['Turn on Sky Watcher in Plugins first.']);
    const links = all(p.card, (node) => node.localName === 'a' && visible(node) && node.getAttribute('href') === '#/plugins');
    assert.deepEqual(links.map((link) => link.textContent), ['Open Plugins']);
    assert.equal(theSwitch(p.card).checked, false);
    assert.equal(store.cameras.get(p.camera.id).skyDetector, undefined, 'nothing was turned on');
  } finally {
    p.close();
  }
});
