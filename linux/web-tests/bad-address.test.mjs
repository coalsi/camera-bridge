// A mangled address (js/app.js): a link with a stray "%" cannot be decoded, and the page draws "That page doesn't exist" with the menu, at
// start-up and on a later change of address, instead of a blank screen. app.js is started signed in, in the fake browser, with a fake bridge
// behind fetch (as in viewers-route.test.mjs).
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
const failures = [];
const onRejection = (reason) => { failures.push(reason); };
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
const headings = () => all(app(), (node) => node.localName === 'h1' || node.localName === 'h2').map((node) => node.textContent);
const menu = () => all(app(), (node) => node.localName === 'nav');
async function goto(hash) {
  location.hash = hash;
  window.dispatchEvent({ type: 'hashchange' });
  await settle();
}

before(async () => {
  process.on('unhandledRejection', onRejection);
  browser = installFakeBrowser(globalThis, { hash: '#/%' });
  globalThis.fetch = async (url) => {
    const path = String(url).replace('/api/v1/', '');
    if (path === 'session') return reply({ authenticated: true, setupRequired: false, bridgeName: 'Dev Bridge', csrfToken: 'token' });
    if (path === 'system') return reply({ product: 'Camera Bridge OS', version: '0.1.1', canManage: false });
    if (path === 'plugins') return reply({ plugins: [] });
    if (path === 'cameras') return reply({ cameras: [] });
    if (path === 'notifications') return reply({ unread: 0, notifications: [] });
    return reply({ error: 'not_found', message: 'There is nothing here.' }, 404);
  };
  await import('../web/js/app.js');
  await settle();
});
after(async () => {
  try {
    await goto('#/about');
  } finally {
    process.off('unhandledRejection', onRejection);
    browser?.restore();
  }
});

test('opened at #/%, the page draws "That page doesn’t exist" with its menu', () => {
  assert.deepEqual(failures, []);
  assert.ok(menu().length > 0, 'the menu is drawn');
  assert.ok(headings().includes('That page doesn’t exist'), headings().join('|'));
  assert.match(browser.document.title, /^Not found/);
});

test('a later address that cannot be decoded does the same, and a good one after it still opens its page', async () => {
  for (const hash of ['#/camera/%E0%A4%A', '#/settings/%zz', '#/nvr/%']) {
    await goto('#/about');
    assert.ok(!headings().includes('That page doesn’t exist'), `#/about before ${hash}`);
    await goto(hash);
    assert.ok(headings().includes('That page doesn’t exist'), `${hash}: ${headings().join('|')}`);
  }
  await goto('#/about');
  assert.ok(!headings().includes('That page doesn’t exist'));
  assert.deepEqual(failures, []);
});
