// Plugins (#/plugins, screens/plugins.js) with Sky Watcher as the third: its entry, its switch and its link to #/sky, and what the page knows
// of the switches (store.js: pluginOn, setPlugins, loadPlugins) so that the menu and the camera page follow them. In the fake browser, with a
// fake bridge behind fetch.
import assert from 'node:assert/strict';
import { after, before, beforeEach, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let store;
let page;
const requests = [];
const state = { wyze: false, eufy: false, sky: false };
let failing = false;

const SUMMARY = 'Watches the sky with a camera pointed up and keeps a log of planes, satellites, meteors and anything it can’t explain.';
const NEEDS = 'A camera that looks at the sky, and a recordings folder for the sky log.';
const reply = (data, status = 200) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});
const list = () => ({
  plugins: [
    { id: 'wyze', name: 'Wyze', summary: 'Sign in to your Wyze account to see your Wyze cameras and add them.', needs: 'A Wyze account and an API key.', needsInternet: true, internetNote: 'Signing in uses Wyze’s cloud.', enabled: state.wyze },
    { id: 'eufy', name: 'eufy', summary: 'Sign in to a eufy account to see its cameras and add them.', needs: 'A eufy account.', needsInternet: true, internetNote: 'Signing in goes through eufy’s cloud.', enabled: state.eufy },
    { id: 'sky', name: 'Sky Watcher', summary: SUMMARY, needs: NEEDS, needsInternet: false, internetNote: 'Works without the internet.', enabled: state.sky },
  ],
});

before(async () => {
  browser = installFakeBrowser();
  globalThis.fetch = async (url, init = {}) => {
    const path = String(url).replace('/api/v1/', '');
    requests.push(`${init.method ?? 'GET'} ${path}${init.body ? ` ${init.body}` : ''}`);
    if (path === 'plugins' && (!init.method || init.method === 'GET')) return reply(list());
    const match = path.match(/^plugins\/(wyze|eufy|sky)$/);
    if (match && init.method === 'PATCH') {
      if (failing) return reply({ error: 'unavailable', message: 'The bridge couldn’t save that.' }, 503);
      state[match[1]] = JSON.parse(init.body).enabled === true;
      return reply(list());
    }
    return reply({ error: 'not_found', message: 'There is nothing here.' }, 404);
  };
  store = await import('../web/js/store.js');
  page = await import('../web/js/screens/plugins.js');
});
after(() => browser?.restore());
beforeEach(() => {
  Object.assign(state, { wyze: false, eufy: false, sky: false });
  failing = false;
  requests.length = 0;
  store.setPlugins([]);
});

function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));
const settle = async () => { for (let i = 0; i < 10; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
const cards = (el) => byClass(el, 'plugin-card');
const cardOf = (el, name) => cards(el).find((card) => all(card, (node) => node.localName === 'h2')[0]?.textContent === name);
const theSwitch = (card) => all(card, (node) => node.localName === 'input' && node.getAttribute('role') === 'switch')[0];
const isOn = (card) => theSwitch(card).checked === true;   // the fake DOM leaves `checked` unset for an unchecked box
const flip = (input, on) => { input.checked = on; input.dispatchEvent({ type: 'change', target: input }); };
const text = (node) => all(node, () => true).filter((n) => n.localName === 'p').map((n) => n.textContent);

async function open() {
  const screen = page.renderPlugins({ navigate() {} });
  await settle();
  return screen;
}

test('the store knows which plugins are on: nothing is until it has been read', async () => {
  assert.equal(store.pluginOn('sky'), false);
  assert.equal(store.pluginOn('nobody'), false);
  const seen = [];
  const stop = store.subscribe((kind) => seen.push(kind));
  store.setPlugins([{ id: 'sky', enabled: true }, { id: 'wyze', enabled: false }, { id: 'eufy' }, { name: 'no id', enabled: true }, null]);
  assert.equal(store.pluginOn('sky'), true);
  assert.equal(store.pluginOn('wyze'), false);
  assert.equal(store.pluginOn('eufy'), false, 'no word is off');
  assert.deepEqual(seen, ['plugins'], 'whoever shows a plugin’s things is told');
  store.setPlugins([{ id: 'sky', enabled: false }]);
  assert.equal(store.pluginOn('sky'), false);
  store.setPlugins('not a list');
  assert.equal(store.pluginOn('sky'), false, 'an answer that is not a list switches nothing on');
  stop();
});

test('loadPlugins reads GET plugins into the store', async () => {
  state.sky = true;
  const plugins = await store.loadPlugins();
  assert.deepEqual(requests, ['GET plugins']);
  assert.deepEqual(plugins.map((plugin) => plugin.id), ['wyze', 'eufy', 'sky']);
  assert.equal(store.pluginOn('sky'), true);
  assert.equal(store.pluginOn('wyze'), false);
  state.sky = false;
  await store.loadPlugins();
  assert.equal(store.pluginOn('sky'), false, 'read again, it follows');
});

test('Sky Watcher is the third plugin, with its sentence, its switch, off, and a link to #/sky', async () => {
  const screen = await open();
  const lede = byClass(screen.el, 'lede')[0].textContent;
  assert.match(lede, /watching the sky/, 'the page’s own sentence is not only about connecting cameras any more');
  assert.deepEqual(cards(screen.el).map((card) => all(card, (node) => node.localName === 'h2')[0].textContent), ['Wyze', 'eufy', 'Sky Watcher']);
  const sky = cardOf(screen.el, 'Sky Watcher');
  assert.ok(text(sky).includes(SUMMARY), 'one plain sentence of what it does');
  assert.ok(text(sky).includes(NEEDS));
  assert.equal(isOn(sky), false, 'off by default');
  assert.deepEqual(byClass(sky, 'pill').map((pill) => pill.textContent), ['Off']);
  const open1 = all(sky, (node) => node.localName === 'a' && /Open/.test(node.textContent));
  assert.deepEqual(open1.map((a) => a.getAttribute('href')), ['#/sky'], 'its link opens the Sky Watcher page');
  // The other two keep their own pages, and nothing about them changed.
  assert.deepEqual(all(cardOf(screen.el, 'Wyze'), (node) => node.localName === 'a').map((a) => a.getAttribute('href')), ['#/plugins/wyze']);
  assert.deepEqual(all(cardOf(screen.el, 'eufy'), (node) => node.localName === 'a').map((a) => a.getAttribute('href')), ['#/plugins/eufy']);
  assert.equal(store.pluginOn('sky'), false);
  screen.destroy();
});

test('the switch turns it on and off with PATCH plugins/sky, and the page follows', async () => {
  const seen = [];
  const stop = store.subscribe((kind) => seen.push(kind));
  const screen = await open();
  requests.length = 0;
  seen.length = 0;
  flip(theSwitch(cardOf(screen.el, 'Sky Watcher')), true);
  await settle();
  assert.deepEqual(requests, ['PATCH plugins/sky {"enabled":true}', 'GET plugins'], 'one change, then the list again');
  assert.equal(state.sky, true);
  assert.equal(store.pluginOn('sky'), true, 'the menu and the camera page know at once');
  assert.ok(seen.includes('plugins'));
  let sky = cardOf(screen.el, 'Sky Watcher');
  assert.equal(isOn(sky), true);
  assert.deepEqual(byClass(sky, 'pill').map((pill) => pill.textContent), ['On']);
  assert.equal(store.pluginOn('wyze'), false, 'the others are not touched');

  flip(theSwitch(sky), false);
  await settle();
  assert.equal(state.sky, false);
  assert.equal(store.pluginOn('sky'), false);
  sky = cardOf(screen.el, 'Sky Watcher');
  assert.equal(isOn(sky), false);
  stop();
  screen.destroy();
});

test('a switch the bridge would not change goes back to what the bridge has', async () => {
  const screen = await open();
  failing = true;
  const input = theSwitch(cardOf(screen.el, 'Sky Watcher'));
  flip(input, true);
  await settle();
  assert.equal(state.sky, false);
  assert.equal(store.pluginOn('sky'), false);
  assert.equal(isOn(cardOf(screen.el, 'Sky Watcher')), false, 'it shows what is true');
  screen.destroy();
});

test('the page keeps the store current whenever it reads the list: a switch changed elsewhere shows up in the menu', async () => {
  state.sky = true;
  const screen = await open();
  assert.equal(store.pluginOn('sky'), true);
  assert.equal(isOn(cardOf(screen.el, 'Sky Watcher')), true);
  screen.destroy();
});
