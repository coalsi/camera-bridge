// The System page (screens/system.js): the factory reset says the box also forgets its Wi-Fi, SSH keys and update settings, and the Updates
// card says when an update did not start and the box went back to the version before (docs/linux/UPDATES.md), in the bridge's own sentence when
// it has one. The bridge says that with `update.failedVersion` and the sentence in `message`, its state staying "idle" (cb-update's "rolled-back"
// is mapped to it: BridgeDaemon/RequestFileSystemControl.swift and its test aVersionThatDidNotStartIsReportedWithTheBoxsSentence); the updates
// below are what it sends. In the fake browser, with a made-up bridge.
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

// What the box sends after it went back from 0.1.131 by itself (cb-update boot, then a check that found 0.1.131 again).
const SENTENCE = 'Version 0.1.131 did not start properly, so the box went back to version 0.1.130 by itself. It will not be offered again; a newer version will be.';
const ROLLED_BACK = { state: 'idle', available: false, current: '0.1.130', latest: '0.1.131', notes: '', checked: new Date().toISOString(), message: SENTENCE,
  rebootRequired: false, failedVersion: '0.1.131' };

test('a version that did not start: the Updates card says the bridge’s own sentence instead of "You have the latest version"', async () => {
  const page = await open(ROLLED_BACK);
  try {
    const text = visibleText(updatesCard(page));
    assert.ok(text.includes(SENTENCE), text);
    assert.doesNotMatch(text, /You have the latest version/);
    assert.equal(all(updatesCard(page), (node) => node.classList?.contains('banner') && node.classList.contains('warning')).length, 1, 'as a warning');
  } finally {
    page.destroy();
  }
});

test('a version that did not start, without a sentence of the bridge’s: the page says it in its own words', async () => {
  const { message, ...withoutSentence } = ROLLED_BACK;
  assert.ok(message);
  const page = await open(withoutSentence);
  try {
    const text = visibleText(updatesCard(page));
    assert.ok(text.includes('Version 0.1.131 did not start, so the box went back to 0.1.130. It won’t install that version again.'), text);
    assert.doesNotMatch(text, /You have the latest version/);
  } finally {
    page.destroy();
  }
});

test('a newer version after a rollback is offered as usual (the bridge names no failed version then)', async () => {
  const page = await open({ state: 'idle', available: true, current: '0.1.130', latest: '0.1.132', notes: '', checked: new Date().toISOString(),
    message: 'version 0.1.132 is available (you have 0.1.130)', rebootRequired: false });
  try {
    const text = visibleText(updatesCard(page));
    assert.match(text, /0\.1\.132 is available/);
    assert.doesNotMatch(text, /did not start/);
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
