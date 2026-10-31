// The factory reset and the cameras Camera Bridge changed (screens/system.js): the dialog no longer says the cameras are not touched; it lists
// the cameras that Set up for Camera Bridge changed (`setupBackup`) and, ticked unless the person unticks it, gives each its own settings back
// (POST cameras/:id/setup/restore) one at a time before the reset is sent. A camera that can't is named and the reset goes on; Cancel stops it.
// On the System page in the fake browser with a made-up bridge whose restores can be held.
import assert from 'node:assert/strict';
import { after, afterEach, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let renderSystem;
let RESET_TEXT;
let store;
const posts = [];
let answers = [];   // the answers of the next POSTs, in order: { status, body }, or { hold: true } to wait for release()
const held = [];

const reply = (status, data) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});

const SYSTEM = { product: 'Camera Bridge OS', version: '0.1.130', mode: 'installed', canManage: true, canReboot: true, canUpdate: false, canInstall: false, sshEnabled: false };
const DOOR = '0A1B2C3D-0000-4000-8000-000000000041';
const PORCH = '0A1B2C3D-0000-4000-8000-000000000042';
const SHED = '0A1B2C3D-0000-4000-8000-000000000043';
const BACKUP = { version: 1, created: '2026-10-20T15:00:00Z' };

before(async () => {
  browser = installFakeBrowser();
  globalThis.fetch = async (url, init = {}) => {
    const path = String(url).replace('/api/v1/', '');
    if ((init.method ?? 'GET') === 'POST') {
      posts.push({ path, body: JSON.parse(init.body ?? '{}') });
      const answer = answers.shift();
      if (answer?.hold) await new Promise((resolve) => held.push(resolve));
      if (answer?.status) return reply(answer.status, answer.body);
      return reply(200, path.endsWith('/setup/restore') ? { steps: [{ id: 'cloud', title: 'Cloud off', status: 'restored' }], canRestore: false } : {});
    }
    if (path === 'system') return reply(200, SYSTEM);
    if (path === 'status') return reply(200, { uptimeSeconds: 60, cameras: { total: 3, online: 3, paired: 3 } });
    return reply(404, { error: 'not_found', message: 'There is nothing here.' });
  };
  ({ renderSystem, RESET_TEXT } = await import('../web/js/screens/system.js'));
  ({ store } = await import('../web/js/store.js'));
});
after(() => browser?.restore());
afterEach(() => { store.cameras = new Map(); answers = []; posts.length = 0; });

const settle = async () => { for (let i = 0; i < 12; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byText = (root, tag, text) => all(root, (node) => node.localName === tag && node.textContent.trim() === text)[0];
const byId = (root, id) => all(root, (node) => node.getAttribute('id') === id)[0];
const dialog = () => all(browser.document.body, (node) => node.localName === 'dialog')[0] ?? null;
const type = (input, value) => { input.value = value; input.dispatchEvent({ type: 'input', target: input }); };
const submit = (root) => { const form = all(root, (node) => node.localName === 'form')[0]; form.dispatchEvent({ type: 'submit', target: form, preventDefault() {} }); };
const visibleText = (node) => (node.hidden ? '' : node.data !== undefined ? node.data : (node.childNodes ?? []).map(visibleText).join(''));
const toasts = () => browser.document.getElementById('toasts').textContent;
const release = async () => { held.shift()(); await settle(); };

function withCameras() {
  store.cameras = new Map([
    [DOOR, { id: DOOR, name: 'Front Door', isEnabled: true, setupBackup: BACKUP }],
    [PORCH, { id: PORCH, name: 'Porch', isEnabled: true, setupBackup: BACKUP }],
    [SHED, { id: SHED, name: 'Shed', isEnabled: true }],
  ]);
}

/** Opens the System page's factory reset with the sentence and a password typed in: { page, open }. */
async function openReset() {
  const page = renderSystem();
  browser.document.body.append(page.el);
  await settle();
  byText(page.el, 'button', 'Factory reset…').click();
  await settle();
  const open = dialog();
  type(byId(open, 'phrase-input'), 'RESET');
  type(byId(open, 'dialog-password'), 'the right one');
  return { page, open };
}

const restoreOf = (id) => ({ path: `cameras/${id}/setup/restore`, body: { confirm: true } });
const RESET = { path: 'system/factory-reset', body: { confirm: 'RESET', password: 'the right one' } };

test('it no longer says the cameras are not touched, and with no camera changed it asks nothing about them', async () => {
  const { page, open } = await openReset();
  try {
    assert.ok(!open.textContent.includes('not touched'));
    assert.equal(byId(open, 'reset-give-back'), undefined, 'no camera has a backup: nothing to give back');
    submit(open);
    await settle();
    assert.deepEqual(posts, [RESET]);
    assert.equal(open.open, false);
  } finally {
    page.destroy();
  }
});

test('the cameras Camera Bridge changed get their own settings back first, one at a time; one that can’t is named and the reset goes on', async () => {
  withCameras();
  const { page, open } = await openReset();
  try {
    assert.ok(open.textContent.includes('Camera Bridge changed the settings of Front Door and Porch when it set them up.'), 'the cameras with a backup, by name');
    assert.ok(!open.textContent.includes('Shed'), 'not one the setup never changed');
    const check = byId(open, 'reset-give-back');
    assert.equal(check.checked, true, 'on unless the person turns it off');
    assert.equal(all(open, (node) => node.localName === 'label' && node.getAttribute('for') === 'reset-give-back')[0].textContent.startsWith(RESET_TEXT.giveBack), true);
    assert.equal(RESET_TEXT.giveBack, 'Give the cameras their own settings back first');

    answers = [{ hold: true, status: 409, body: { error: 'camera_setup_busy', code: 'camera_setup_busy', message: 'Another change is under way.' } }, { hold: true }];
    submit(open);
    await settle();
    assert.deepEqual(posts, [restoreOf(DOOR)], 'the first camera only, while it is being restored');
    assert.match(visibleText(open), /Giving Front Door its own settings back \(1 of 2\)…/);
    await release();
    assert.deepEqual(posts, [restoreOf(DOOR), restoreOf(PORCH)], 'then the next');
    assert.match(visibleText(open), /Front Door: This camera’s settings are already being changed\. Try again in a minute\./, 'the failure, by name');
    await release();
    assert.deepEqual(posts, [restoreOf(DOOR), restoreOf(PORCH), RESET], 'and the reset goes on');
    assert.equal(open.open, false);
    assert.ok(toasts().includes(RESET_TEXT.resetting));
    assert.ok(toasts().includes('Front Door didn’t get its own settings back.'), 'said again once the dialog is gone');
  } finally {
    page.destroy();
  }
});

test('a wrong password sends no camera again; a camera that put back only some settings is named', async () => {
  withCameras();
  const { page, open } = await openReset();
  try {
    answers = [{ status: 200, body: { steps: [{ id: 'cloud', title: 'Cloud off', status: 'refused' }] } }, {},
      { status: 403, body: { error: 'wrong_password', message: 'That password isn’t right.' } }];
    submit(open);
    await settle();
    assert.deepEqual(posts, [restoreOf(DOOR), restoreOf(PORCH), RESET]);
    assert.match(visibleText(open), /Front Door: Some settings could not be put back\./);
    assert.equal(visibleText(byId(open, 'dialog-password-problem')), 'That password isn’t right.');
    assert.equal(open.open, true, 'the dialog stays');
    submit(open);
    await settle();
    assert.deepEqual(posts.slice(3), [RESET], 'the reset only: each camera is sent once');
    assert.equal(open.open, false);
  } finally {
    page.destroy();
  }
});

test('turned off, no camera is sent anything; Cancel while a camera is restored stops before the next and before the reset', async () => {
  withCameras();
  let { page, open } = await openReset();
  try {
    const check = byId(open, 'reset-give-back');
    check.checked = false;
    submit(open);
    await settle();
    assert.deepEqual(posts, [RESET], 'turned off: the reset only');
  } finally {
    page.destroy();
  }

  posts.length = 0;
  ({ page, open } = await openReset());
  try {
    answers = [{ hold: true }];
    submit(open);
    await settle();
    assert.deepEqual(posts, [restoreOf(DOOR)]);
    byText(open, 'button', 'Cancel').click();
    await settle();
    assert.equal(open.open, false);
    await release();
    assert.deepEqual(posts, [restoreOf(DOOR)], 'the camera being restored finishes; nothing after it is sent, the reset least of all');
    assert.ok(toasts().includes('Nothing was erased. Front Door has its own settings back.'));
  } finally {
    page.destroy();
  }
});
