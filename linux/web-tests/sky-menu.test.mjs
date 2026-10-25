// The menu's Sky Watcher item (js/app.js): Sky Watcher is a plugin, so its item is in the left menu (and the phone's tab bar, which is the same
// nav) beside Notifications only while the plugin is on, whatever the cameras are set to; and #/sky opens its page, or says it is off. app.js is
// started signed in, in the fake browser, with a fake bridge behind fetch whose Sky Watcher plugin starts off, as on a new box.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

const SKY = '0A1B2C3D-0000-4000-8000-000000000004';
const DOOR = '0A1B2C3D-0000-4000-8000-000000000001';
const camera = (id, name, skyDetector) => ({ id, name, isEnabled: true, vendorName: 'ONVIF', status: { connection: 'online' }, ...(skyDetector ? { skyDetector } : {}) });
const WATCHING = { enabled: true, facing: 0, tilt: 20, groundPercent: 12, nightProfile: true, lensLayout: 'dual' };

let browser;
let store;
let putCamera;
let setPlugins;
const requests = [];
let skyPlugin = false;
const reply = (data, status = 200) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});

before(async () => {
  browser = installFakeBrowser(globalThis, { hash: '#/about' });
  globalThis.fetch = async (url, init = {}) => {
    const path = String(url).replace('/api/v1/', '');
    requests.push(`${init.method ?? 'GET'} ${path}`);
    if (path === 'session') return reply({ authenticated: true, setupRequired: false, bridgeName: 'Dev Bridge', csrfToken: 'token' });
    if (path === 'system') return reply({ product: 'Camera Bridge OS', version: '0.1.1', canManage: false });
    if (path === 'plugins') return reply({ plugins: [{ id: 'wyze', enabled: false }, { id: 'eufy', enabled: false }, { id: 'sky', enabled: skyPlugin }] });
    if (path === 'cameras') return reply({ cameras: [camera(DOOR, 'Front Door')] });
    if (path === 'settings') return reply({ cameraOrder: [], timeZone: 'America/Chicago', sky: { location: null } });
    if (path === 'notifications') return reply({ unread: 0, notifications: [] });
    if (path.startsWith('notifications/')) return reply({ shown: [], unread: 0 });
    if (path.startsWith(`sky/cameras/${SKY}/night`)) {
      return reply({ camera: SKY, night: '2026-10-24', view: 'night', from: 1, to: 2, serverTime: 3, entries: [], conditions: [], counts: { unexplained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 0 }, aim: null, learning: null });
    }
    return reply({ error: 'not_found', message: 'There is nothing here.' }, 404);
  };
  ({ store, putCamera, setPlugins } = await import('../web/js/store.js'));
  await import('../web/js/app.js');
  await settle();
});
after(() => browser?.restore());

const settle = async () => { for (let i = 0; i < 12; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const nav = () => all(browser.document.getElementById('app'), (node) => node.localName === 'nav')[0];
const items = () => all(nav(), (node) => node.localName === 'a');
const visibleItems = () => items().filter((link) => !link.hidden).map((link) => [link.getAttribute('href'), link.textContent.trim()]);
const skyItem = () => items().find((link) => link.getAttribute('href') === '#/sky');
const MENU_OFF = ['Monitor', 'Events', 'Notifications', 'Cameras', 'Plugins', 'Log', 'System', 'Settings', 'About'];
const MENU_ON = ['Monitor', 'Events', 'Notifications', 'Sky Watcher', 'Cameras', 'Plugins', 'Log', 'System', 'Settings', 'About'];
const goto = async (hash) => {
  location.hash = hash;
  window.dispatchEvent({ type: 'hashchange' });
  await settle();
};
const headings = () => all(browser.document.getElementById('app'), (node) => node.localName === 'h1' || node.localName === 'h2').map((node) => node.textContent);

test('the page asks the bridge which plugins are on when it starts, and the menu has no Sky Watcher item while the plugin is off', () => {
  assert.ok(nav(), 'the page started signed in');
  assert.ok(requests.includes('GET plugins'), requests.join(', '));
  assert.ok(skyItem(), 'the item is in the menu');
  assert.equal(skyItem().hidden, true);
  assert.deepEqual(visibleItems().map(([, label]) => label), MENU_OFF);
});

test('a camera that has Sky Watcher on does not bring the item while the plugin is off', () => {
  putCamera(camera(SKY, 'North Sky', WATCHING));
  assert.equal(skyItem().hidden, true, 'the camera’s settings are kept, but the plugin is what shows the item');
  assert.deepEqual(visibleItems().map(([, label]) => label), MENU_OFF);
});

test('switching the plugin on shows the item right after Notifications, with a camera that watches the sky or without one', () => {
  store.cameras.delete(SKY);
  setPlugins([{ id: 'wyze', enabled: false }, { id: 'sky', enabled: true }]);
  assert.equal(skyItem().hidden, false);
  assert.deepEqual(visibleItems().map(([, label]) => label), MENU_ON, 'right after Notifications, with no camera set to watch the sky');
  assert.deepEqual(visibleItems().find(([, label]) => label === 'Sky Watcher'), ['#/sky', 'Sky Watcher']);
  assert.equal(skyItem().getAttribute('title'), 'Sky Watcher');
  assert.ok(all(skyItem(), (node) => node.localName === 'svg').length === 1, 'with its icon');
  // Cameras coming and going change nothing about it.
  putCamera(camera(SKY, 'North Sky', WATCHING));
  assert.equal(skyItem().hidden, false);
  putCamera(camera(SKY, 'North Sky', { ...WATCHING, enabled: false }));
  assert.equal(skyItem().hidden, false, 'it is shown all the time, not only once a camera has it on');
  store.cameras.delete(SKY);
});

test('the tab bar of a phone is this same menu: one nav, one item', () => {
  const navs = all(browser.document.getElementById('app'), (node) => node.localName === 'nav');
  assert.equal(navs.length, 1);
  assert.equal(items().filter((link) => link.getAttribute('href') === '#/sky').length, 1);
});

test('the item opens #/sky, which is Sky Watcher’s page', async () => {
  putCamera(camera(SKY, 'North Sky', WATCHING));
  await goto('#/sky');
  assert.match(browser.document.title, /^Sky Watcher · Dev Bridge$/);
  assert.ok(headings().includes('Sky Watcher'), headings().join('|'));
  assert.ok(requests.includes(`GET sky/cameras/${SKY}/night?view=night`), 'it asked for the latest night of the camera that watches the sky');

  // The camera named in the address, and its night.
  requests.length = 0;
  await goto(`#/sky/${SKY}?night=2026-10-23&view=day`);
  assert.ok(requests.includes(`GET sky/cameras/${SKY}/night?date=2026-10-23&view=day`), requests.join(', '));
});

test('switching the plugin off takes the item away, and #/sky says Sky Watcher is off, with the way to Plugins', async () => {
  setPlugins([{ id: 'sky', enabled: false }]);
  assert.equal(skyItem().hidden, true);
  assert.deepEqual(visibleItems().map(([, label]) => label), MENU_OFF);
  requests.length = 0;
  await goto('#/about');
  await goto('#/sky');
  assert.ok(headings().includes('Sky Watcher is off'), headings().join('|'));
  const links = all(browser.document.getElementById('app'), (node) => node.localName === 'a' && !node.hidden && /Plugins/.test(node.textContent) && node.getAttribute('href') === '#/plugins');
  assert.ok(links.some((link) => link.classList.contains('btn')), 'a button to Plugins in the page');
  assert.deepEqual(requests.filter((request) => request.startsWith('GET sky/')), [], 'nothing is asked of the sky log while the plugin is off');
});
