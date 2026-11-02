// The address #/pair/<code> in the router and the menu (js/app.js): the code in an Apple TV's QR code opens Settings at the Apple TV card with
// the code filled in, and the menu marks Settings; #/pair/sensors is still the sensors bridge's page, marked under Cameras. app.js is started
// signed in, in the fake browser, with a fake bridge behind fetch (as in sky-menu.test.mjs).
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { FakeElement, installFakeBrowser } from './support/fake-browser.mjs';

const SETTINGS = {
  bridgeName: 'Dev Bridge', timeZone: 'America/Phoenix', logLevel: 'info', basePort: 21100, sensorsBridgePort: 21190, webhookEnabled: false, webhookPort: 21180, cameraOrder: [],
  ai: { provider: 'anthropic', model: 'claude-haiku-5-5', keySaved: true, keyHint: '0000', today: 0, last7Days: 0, paused: false, needsRecordingsFolder: false },
};
const LIVING_ROOM = { id: 'v1', name: 'Living Room', device: 'Apple TV 4K (3rd generation)', created: '2026-10-28T21:00:00Z', lastSeen: null, address: null };

let browser;
const requests = [];
const addresses = [];
const scrolled = [];
const reply = (data, status = 200) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});

const tick = () => new Promise((resolve) => setImmediate(resolve));
const settle = async () => { for (let i = 0; i < 12; i += 1) await tick(); };
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const app = () => browser.document.getElementById('app');
const items = () => all(all(app(), (node) => node.localName === 'nav')[0], (node) => node.localName === 'a');
const marked = () => items().filter((link) => link.getAttribute('aria-current') === 'page').map((link) => link.textContent.trim());
const headings = () => all(app(), (node) => node.localName === 'h1' || node.localName === 'h2').map((node) => node.textContent);
const cardInput = () => all(all(app(), (node) => node.classList?.contains('viewers-card'))[0] ?? { childNodes: [] }, (node) => node.localName === 'input')[0];
const recordingHost = () => all(app(), (node) => node.getAttribute('id') === 'recording')[0];
async function goto(hash) {
  location.hash = hash;
  window.dispatchEvent({ type: 'hashchange' });
  await settle();
}
/** Settings loads its Recording card on demand; the test waits for it so that nothing is still arriving when the fake browser is taken away. */
async function settled() {
  for (let i = 0; i < 400 && !recordingHost()?.firstChild; i += 1) await tick();
  await settle();
}

before(async () => {
  browser = installFakeBrowser(globalThis, { hash: '#/pair/sensors' });
  browser.document.append(app());   // the page is in the document, as a card is only scrolled to while it is
  FakeElement.prototype.scrollIntoView = function scrollIntoView() { scrolled.push(this); };
  globalThis.history = { replaceState: (state, title, url) => { addresses.push(url); location.hash = url; } };
  globalThis.fetch = async (url, init = {}) => {
    const path = String(url).replace('/api/v1/', '');
    requests.push(`${init.method ?? 'GET'} ${path}`);
    if (path === 'session') return reply({ authenticated: true, setupRequired: false, bridgeName: 'Dev Bridge', csrfToken: 'token' });
    if (path === 'system') return reply({ product: 'Camera Bridge OS', version: '0.1.1', canManage: false });
    if (path === 'plugins') return reply({ plugins: [] });
    if (path === 'cameras') return reply({ cameras: [] });
    if (path === 'settings') return reply(SETTINGS);
    if (path === 'viewers') return reply({ viewers: [] });
    if (path === 'viewers/approve') return reply({ viewer: LIVING_ROOM }, 201);
    if (path === 'auth/sessions') return reply({ sessions: [] });
    if (path === 'sensors-bridge') return reply({ paired: false, setupCode: '123-45-678', qrSVG: '<svg/>' });
    if (path === 'notifications') return reply({ unread: 0, notifications: [] });
    if (path.startsWith('notifications/')) return reply({ shown: [], unread: 0 });
    return reply({ error: 'not_found', message: 'There is nothing here.' }, 404);
  };
  await import('../web/js/app.js');
  await settle();
});
after(async () => {
  try {
    await goto('#/about');   // whatever screen is open is destroyed: Settings' Recording card polls, and a failed test must end the run, not hang it
  } finally {
    delete FakeElement.prototype.scrollIntoView;
    delete globalThis.history;
    browser?.restore();
  }
});

test('#/pair/sensors is still the sensors bridge’s page, and the menu marks Cameras for it', () => {
  assert.deepEqual(marked(), ['Cameras']);
  assert.ok(headings().includes('Sensors bridge'), headings().join('|'));
  assert.match(browser.document.title, /^Sensors bridge · Dev Bridge$/);
  assert.ok(requests.includes('GET sensors-bridge'), 'its pairing panel asked for the setup code');
  assert.ok(!headings().includes('Apple TV'));
});

test('#/pair/<code> opens Settings, the menu marks Settings, and the card has the code in its field', async () => {
  requests.length = 0;
  await goto('#/pair/bcdfghjk');
  await settled();
  assert.deepEqual(marked(), ['Settings']);
  assert.match(browser.document.title, /^Settings · Dev Bridge$/);
  assert.ok(headings().includes('Settings'), headings().join('|'));
  assert.ok(headings().includes('Apple TV'), 'the Apple TV card is in Settings');
  assert.equal(cardInput().value, 'BCDF-GHJK');
  assert.equal(scrolled.length, 1, 'Settings was scrolled to the card');
  assert.ok(scrolled[0].classList.contains('viewers-card'));
  assert.deepEqual(requests.filter((request) => request.startsWith('POST') || request.startsWith('DELETE')), [], 'opening the address adds nothing');
  assert.ok(!headings().includes('Sensors bridge'));
});

test('the same address written with the dash and capitals, or with a space, opens the same card', async () => {
  for (const hash of ['#/pair/BCDF-GHJK', '#/pair/bcdf%20ghjk']) {
    await goto('#/about');
    await goto(hash);
    await settled();
    assert.deepEqual(marked(), ['Settings'], hash);
    assert.equal(cardInput().value, 'BCDF-GHJK', hash);
  }
});

test('letters of another count, or digits, are not a code: no Settings, and the page does not exist', async () => {
  for (const hash of ['#/pair/bcdfghj', '#/pair/bcdfghjkl', '#/pair/1234-5678']) {
    await goto(hash);
    assert.ok(headings().includes('That page doesn’t exist'), `${hash}: ${headings().join('|')}`);
    assert.ok(!marked().includes('Settings'), hash);
  }
});

test('adding the Apple TV from #/pair/<code> makes the address #/settings, and Settings stays marked', async () => {
  addresses.length = 0;
  await goto('#/pair/bcdfghjk');
  await settled();
  const form = all(all(app(), (node) => node.classList?.contains('viewers-card'))[0], (node) => node.localName === 'form')[0];
  form.dispatchEvent({ type: 'submit', target: form, preventDefault() {} });
  await settle();
  assert.ok(requests.includes('POST viewers/approve'));
  assert.deepEqual(addresses, ['#/settings']);
  assert.equal(location.hash, '#/settings');
  assert.deepEqual(marked(), ['Settings']);
});
