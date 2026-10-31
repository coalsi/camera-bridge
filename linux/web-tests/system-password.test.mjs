// What erases or opens the box asks for the administrator password again (screens/system.js, dom.js phraseDialog and promptDialog): the
// dialog has "Your Camera Bridge password", sends it with the request, and on the bridge's refusal says its sentence beside the field and stays
// open. Shown here with the factory reset and SSH, on the System page in the fake browser with a made-up bridge.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let renderSystem;
const posts = [];
let refusals = [];

const reply = (status, data) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});

const SYSTEM = { product: 'Camera Bridge OS', version: '0.1.130', mode: 'installed', canManage: true, canReboot: true, canUpdate: false, canInstall: false, sshEnabled: false };

before(async () => {
  browser = installFakeBrowser();
  globalThis.fetch = async (url, init = {}) => {
    const path = String(url).replace('/api/v1/', '');
    if ((init.method ?? 'GET') === 'POST') {
      posts.push({ path, body: JSON.parse(init.body ?? '{}') });
      const refusal = refusals.shift();
      if (refusal) return reply(refusal.status, refusal.body);
      if (path === 'system/ssh') return reply(200, { ...SYSTEM, sshEnabled: true });
      return reply(200, {});
    }
    if (path === 'system') return reply(200, SYSTEM);
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
const byText = (root, tag, text) => all(root, (node) => node.localName === tag && node.textContent.trim() === text)[0];
const dialog = () => all(browser.document.body, (node) => node.localName === 'dialog')[0] ?? null;
const byId = (root, id) => all(root, (node) => node.getAttribute('id') === id)[0];
const type = (input, value) => { input.value = value; input.dispatchEvent({ type: 'input', target: input }); };
const submit = (root) => { const form = all(root, (node) => node.localName === 'form')[0]; form.dispatchEvent({ type: 'submit', target: form, preventDefault() {} }); };
const visibleText = (node) => (node.hidden ? '' : node.data !== undefined ? node.data : (node.childNodes ?? []).map(visibleText).join(''));

test('the factory reset asks for the password, says a wrong one beside the field and stays open, then sends it', async () => {
  const page = renderSystem();
  browser.document.body.append(page.el);
  try {
    await settle();
    byText(page.el, 'button', 'Factory reset…').click();
    await settle();
    const open = dialog();
    assert.ok(open, 'the dialog is open');
    const label = all(open, (node) => node.localName === 'label' && node.getAttribute('for') === 'dialog-password')[0];
    assert.equal(label.textContent, 'Your Camera Bridge password');
    const password = byId(open, 'dialog-password');
    assert.equal(password.getAttribute('type'), 'password');
    assert.equal(password.getAttribute('autocomplete'), 'current-password');
    const go = byText(open, 'button', 'Erase everything and restart');
    type(byId(open, 'phrase-input'), 'RESET');
    assert.equal(go.disabled, true, 'the button waits for the password too');
    type(password, 'not it');
    assert.equal(go.disabled, false);

    refusals = [{ status: 403, body: { error: 'wrong_password', message: 'That password isn’t right.' } }];
    submit(open);
    await settle();
    assert.deepEqual(posts.at(-1), { path: 'system/factory-reset', body: { confirm: 'RESET', password: 'not it' } });
    assert.equal(dialog(), open, 'the dialog stays open');
    assert.equal(open.open, true);
    assert.equal(visibleText(byId(open, 'dialog-password-problem')), 'That password isn’t right.', 'beside the field');

    refusals = [{ status: 429, body: { error: 'too_many_attempts', message: 'Too many wrong passwords. Wait a minute and try again.' } }];
    submit(open);
    await settle();
    assert.equal(visibleText(byId(open, 'dialog-password-problem')), 'Too many wrong passwords. Wait a minute and try again.');

    type(password, 'the right one');
    submit(open);
    await settle();
    assert.deepEqual(posts.at(-1), { path: 'system/factory-reset', body: { confirm: 'RESET', password: 'the right one' } });
    assert.equal(open.open, false, 'taken: the dialog closes');
    assert.equal(posts.filter((p) => p.path === 'system/factory-reset').length, 3);
  } finally {
    page.destroy();
  }
});

test('turning on SSH sends the keys with the password; Cancel sends nothing', async () => {
  const page = renderSystem();
  browser.document.body.append(page.el);
  try {
    await settle();
    const before = posts.length;
    byText(page.el, 'button', 'Turn on SSH…').click();
    await settle();
    let open = dialog();
    byText(open, 'button', 'Cancel').click();
    await settle();
    assert.equal(posts.length, before, 'cancelled: nothing sent');

    byText(page.el, 'button', 'Turn on SSH…').click();
    await settle();
    open = dialog();
    type(byId(open, 'prompt-input'), 'ssh-ed25519 AAAA me@laptop');
    type(byId(open, 'dialog-password'), 'secret words');
    refusals = [{ status: 403, body: { error: 'password_required', message: 'Type your Camera Bridge password to turn on SSH.' } }];
    submit(open);
    await settle();
    assert.equal(open.open, true);
    assert.equal(visibleText(byId(open, 'dialog-password-problem')), 'Type your Camera Bridge password to turn on SSH.');
    submit(open);
    await settle();
    assert.deepEqual(posts.at(-1), { path: 'system/ssh', body: { enabled: true, authorizedKeys: 'ssh-ed25519 AAAA me@laptop', password: 'secret words' } });
    assert.equal(open.open, false);
  } finally {
    page.destroy();
  }
});
