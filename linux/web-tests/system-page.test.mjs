// The System page (screens/system.js): the factory reset says the box also forgets its Wi-Fi, SSH keys and update settings, and the Updates
// card says when an update did not start and the box went back to the version before (`update.state` "rolled-back", docs/linux/UPDATES.md), in
// the bridge's own sentence when it has one. In the fake browser, with a made-up bridge.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let renderSystem;
let system;

const reply = (status, data) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});
const BASE = { product: 'Camera Bridge OS', version: '0.1.130', mode: 'installed', canManage: true, canReboot: true, canUpdate: true, canInstall: false, sshEnabled: false };

before(async () => {
  browser = installFakeBrowser();
  globalThis.fetch = async (url) => {
    const path = String(url).replace('/api/v1/', '');
    if (path === 'system') return reply(200, system);
    if (path === 'status') return reply(200, { uptimeSeconds: 60, cameras: { total: 1, online: 1, paired: 1 } });
    return reply(404, { error: 'not_found', message: 'There is nothing here.' });
  };
  ({ renderSystem } = await import('../web/js/screens/system.js'));
});
after(() => browser?.restore());

const settle = async () => { for (let i = 0; i < 12; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const visibleText = (node) => (node.hidden ? '' : node.data !== undefined ? node.data : (node.childNodes ?? []).map(visibleText).join(''));
const updatesCard = (page) => all(page.el, (node) => node.classList?.contains('card') && all(node, (n) => n.localName === 'h2')[0]?.textContent === 'Updates')[0];

async function open(update) {
  system = { ...BASE, update };
  const page = renderSystem();
  browser.document.body.append(page.el);
  await settle();
  return page;
}

test('a rolled-back update: the Updates card says the bridge’s own sentence instead of "You have the latest version"', async () => {
  const sentence = 'Version 0.1.131 did not start properly, so the box went back to version 0.1.130 by itself.';
  const page = await open({ state: 'rolled-back', available: false, current: '0.1.130', failedVersion: '0.1.131', message: sentence, checked: new Date().toISOString() });
  try {
    const text = visibleText(updatesCard(page));
    assert.ok(text.includes(sentence), text);
    assert.doesNotMatch(text, /You have the latest version/);
  } finally {
    page.destroy();
  }
});

test('a rolled-back update without a sentence of the bridge’s: the page says it in its own words', async () => {
  const page = await open({ state: 'rolled-back', available: false, current: '0.1.130', failedVersion: '0.1.131', checked: new Date().toISOString() });
  try {
    const text = visibleText(updatesCard(page));
    assert.ok(text.includes('Version 0.1.131 did not start, so the box went back to 0.1.130. It won’t install that version again.'), text);
    assert.doesNotMatch(text, /You have the latest version/);
  } finally {
    page.destroy();
  }
});

test('an ordinary check still says the version is the latest', async () => {
  const page = await open({ state: 'idle', available: false, current: '0.1.130', checked: new Date().toISOString() });
  try {
    assert.match(visibleText(updatesCard(page)), /You have the latest version\./);
  } finally {
    page.destroy();
  }
});

test('the factory reset says the box also forgets its Wi-Fi, SSH keys and update settings, and leaves the network on Wi-Fi', async () => {
  const page = await open({ state: 'idle', current: '0.1.130' });
  try {
    all(page.el, (node) => node.localName === 'button' && node.textContent.trim() === 'Factory reset…')[0].click();
    await settle();
    const dialog = all(browser.document.body, (node) => node.localName === 'dialog')[0];
    assert.ok(dialog);
    assert.match(visibleText(dialog), /It also forgets the box’s Wi-Fi network, SSH keys and update settings, so a box on Wi-Fi drops off the network and opens its setup hotspot again\./);
    all(dialog, (node) => node.localName === 'button' && node.textContent.trim() === 'Cancel')[0].click();
  } finally {
    page.destroy();
  }
});
