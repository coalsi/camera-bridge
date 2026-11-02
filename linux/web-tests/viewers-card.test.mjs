// Settings › Security › Apple TV (screens/viewers-card.js): the Apple TVs that can watch this bridge, each with when it was added and last
// used, Remove (asked first) and "Add an Apple TV" with the 8 letters the TV shows; and the address #/pair/<code> in the TV's QR code, which
// opens Settings at the card with the code filled in and the keyboard on Add, and never adds the TV by itself. In the fake browser, with the
// functions the card calls injected, as for the Signed-in browsers card; the bridge's zone is Phoenix.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { FakeElement, installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let PAIR_ROUTE;
let createViewersCard;
let isPairPath;
let tidyCode;
let viewerTitle;
let viewerUse;
before(async () => {
  browser = installFakeBrowser();
  ({ PAIR_ROUTE, createViewersCard, isPairPath, tidyCode, viewerTitle, viewerUse } = await import('../web/js/screens/viewers-card.js'));
  (await import('../web/js/store.js')).setBridgeZone('America/Phoenix');
});
after(() => browser?.restore());

const NOW = Date.UTC(2026, 9, 31, 21, 0, 0);   // Oct 31, 2026, 2:00 PM in Phoenix
const DAY = 86_400_000;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');   // whole seconds, as the bridge says its dates
const plain = (text) => text.replace(/[\u202f\u00a0]/g, ' ');   // newer ICU puts a narrow no-break space before PM
const tick = () => new Promise((resolve) => setImmediate(resolve));
const settle = async () => { for (let i = 0; i < 12; i += 1) await tick(); };
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));
const named = (root, text) => all(root, (node) => node.localName === 'button' && node.textContent.trim() === text);
const visibleText = (node) => (node.hidden ? '' : node.data !== undefined ? node.data : (node.childNodes ?? []).map(visibleText).join(''));
const inputOf = (root) => all(root, (node) => node.localName === 'input')[0];
const fieldText = (root) => inputOf(root).value ?? '';   // a real input starts at '', the fake one has no value until it is set
const typeCode = (root, text) => { inputOf(root).value = text; };
const submit = (root) => { const form = all(root, (node) => node.localName === 'form')[0]; form.dispatchEvent({ type: 'submit', target: form, preventDefault() {} }); };
const problemOf = (card) => visibleText(byClass(card.el, 'viewer-problem')[0]);
const rowIDs = (card) => byClass(card.el, 'viewer-item').map((row) => row.dataset.id);
const refusal = (status, code, message) => Object.assign(new Error(message), { status, code });

const LIVING_ROOM = { id: 'v1', name: 'Living Room', device: 'Apple TV 4K (3rd generation)', created: iso(NOW - 3 * DAY), lastSeen: iso(NOW - 120_000), address: '192.0.2.40' };
const BEDROOM = { id: 'v2', name: 'Bedroom', device: null, created: iso(NOW - DAY), lastSeen: null, address: null };
const DEN = { id: 'v3', name: 'Den', device: 'Apple TV HD', created: iso(NOW - 9 * DAY), lastSeen: iso(NOW - 10_000), address: '192.0.2.41' };
const VIEWERS = [LIVING_ROOM, BEDROOM, DEN];

/** Records what takes the focus and what is scrolled to (the fake browser does neither); `restore()` puts the fake back. */
function watchFocus() {
  const focused = [];
  const scrolled = [];
  const saved = FakeElement.prototype.focus;
  FakeElement.prototype.focus = function focus() { focused.push(this); };
  FakeElement.prototype.scrollIntoView = function scrollIntoView() { scrolled.push(this); };
  return { focused, scrolled, restore() { FakeElement.prototype.focus = saved; delete FakeElement.prototype.scrollIntoView; } };
}

// MARK: The list

test('each Apple TV is its name and model, then when it was added and last used, and from where', async () => {
  assert.equal(viewerTitle(LIVING_ROOM), 'Living Room · Apple TV 4K (3rd generation)');
  assert.equal(viewerTitle(BEDROOM), 'Bedroom', 'no model: the name alone');
  assert.equal(viewerTitle({ ...BEDROOM, name: '', device: 'Apple TV HD' }), 'Apple TV · Apple TV HD', 'no name: the box says “Apple TV”, and so does the card');
  assert.equal(plain(viewerUse(LIVING_ROOM, NOW)), 'Added Oct 28, 2026, 2:00 PM · last used 2 min ago from 192.0.2.40', 'in the bridge’s time');
  assert.equal(plain(viewerUse(DEN, NOW)), 'Added Oct 22, 2026, 2:00 PM · last used just now from 192.0.2.41');
  assert.equal(plain(viewerUse(BEDROOM, NOW)), 'Added Oct 30, 2026, 2:00 PM · not used yet');
  assert.equal(plain(viewerUse({ ...LIVING_ROOM, lastSeen: iso(NOW - 5 * DAY), address: null }, NOW)), 'Added Oct 28, 2026, 2:00 PM · last used 5 days ago', 'no address: no “from”');
  assert.equal(plain(viewerUse({ ...LIVING_ROOM, lastSeen: iso(NOW - DAY - 60_000) }, NOW)), 'Added Oct 28, 2026, 2:00 PM · last used yesterday from 192.0.2.40');

  const card = createViewersCard({ load: async () => ({ viewers: VIEWERS }), now: () => NOW });
  await settle();
  assert.deepEqual(rowIDs(card), ['v1', 'v2', 'v3'], 'the Apple TVs in the order the bridge gives them');
  const rows = byClass(card.el, 'viewer-item');
  assert.ok(plain(visibleText(rows[0])).includes('Living Room · Apple TV 4K (3rd generation)'));
  assert.ok(plain(visibleText(rows[0])).includes('Added Oct 28, 2026, 2:00 PM · last used 2 min ago from 192.0.2.40'));
  assert.ok(plain(visibleText(rows[1])).includes('Bedroom'));
  assert.ok(plain(visibleText(rows[1])).includes('Added Oct 30, 2026, 2:00 PM · not used yet'));
  assert.doesNotMatch(visibleText(card.el), /No Apple TV is added yet/, 'there are some');
  assert.equal(byClass(card.el, 'viewer-list')[0].hidden, false);
  assert.ok(plain(visibleText(card.el)).includes('Living Room · Apple TV 4K (3rd generation)'), 'the list itself is shown, not only its rows');
  card.destroy();
});

test('the card says what an Apple TV can do, that none is added yet, and asks for the 8 letters the TV shows', async () => {
  const card = createViewersCard({ load: async () => ({ viewers: [] }), now: () => NOW });
  await settle();
  assert.equal(all(card.el, (node) => node.localName === 'h2')[0].textContent, 'Apple TV');
  const text = visibleText(card.el);
  assert.ok(text.includes('Apple TVs with the Camera Bridge app. Each one can watch your cameras, live and recorded, and move cameras that pan and tilt. It can’t change anything else, and it never needs the password.'), text);
  assert.ok(text.includes('No Apple TV is added yet.'), text);
  assert.equal(byClass(card.el, 'viewer-list')[0].hidden, true, 'no empty list is left standing above it');
  assert.ok(text.includes('Add an Apple TV'), text);
  assert.ok(text.includes('Open Camera Bridge on the Apple TV and enter the code it shows.'), text);
  const input = inputOf(card.el);
  assert.equal(input.getAttribute('placeholder'), 'BCDF-GHJK');
  assert.equal(input.getAttribute('autocomplete'), 'off');
  assert.equal(input.getAttribute('autocapitalize'), 'characters');
  assert.equal(all(card.el, (node) => node.localName === 'label')[0].getAttribute('for'), input.id, 'the label names the field');
  assert.equal(named(card.el, 'Add').length, 1);
  card.destroy();
});

test('the list is not called empty before it is read, or when it could not be read', async () => {
  let release;
  const waiting = createViewersCard({ load: () => new Promise((resolve) => { release = resolve; }), now: () => NOW });
  await settle();
  assert.doesNotMatch(visibleText(waiting.el), /No Apple TV is added yet/, 'still reading');
  release({ viewers: [] });
  await settle();
  assert.match(visibleText(waiting.el), /No Apple TV is added yet/);
  waiting.destroy();

  const broken = createViewersCard({ load: async () => { throw refusal(0, 'network', 'The bridge didn’t answer. Check that it is on and that this device is on the same network.'); }, now: () => NOW });
  await settle();
  assert.equal(problemOf(broken), 'The bridge didn’t answer. Check that it is on and that this device is on the same network.', 'the bridge’s words');
  assert.doesNotMatch(visibleText(broken.el), /No Apple TV is added yet/, 'it may have some: it could not say');
  broken.destroy();

  const silent = createViewersCard({ load: async () => { throw new Error(''); }, now: () => NOW });
  await settle();
  assert.equal(problemOf(silent), 'The Apple TVs can’t be read right now.', 'ours when it has none');
  silent.destroy();

  let failing = true;
  const later = createViewersCard({ load: async () => { if (failing) throw new Error('The bridge didn’t answer.'); return { viewers: [BEDROOM] }; }, now: () => NOW });
  await settle();
  assert.equal(problemOf(later), 'The bridge didn’t answer.');
  failing = false;
  await later.refresh();
  assert.equal(problemOf(later), '', 'read again: the problem is gone');
  assert.deepEqual(rowIDs(later), ['v2']);
  later.destroy();
});

// MARK: The code

test('a code is 8 letters shown as ABCD-EFGH, however it was typed', () => {
  for (const typed of ['bcdfghjk', 'BCDF-GHJK', ' bcdf ghjk ', 'bcdf-ghjk', 'BC DF-GH JK', 'bcdf\u2013ghjk', 'bcdf\u00a0ghjk', 'bcdf\u2212ghjk']) {
    assert.equal(tidyCode(typed), 'BCDF-GHJK', JSON.stringify(typed));
  }
  for (const typed of ['', '   ', 'BCDFGHJ', 'BCDF-GHJK-L', 'BCDFGHJKL', '1234-5678', 'BCDF-GHJ1', 'BCDF-GHJ!', 'ÉCDF-GHJK', null, undefined]) {
    assert.equal(tidyCode(typed), '', JSON.stringify(typed));
  }
});

test('the address in the TV’s QR code is #/pair/<code>, and #/pair/sensors stays the sensors bridge’s', () => {
  assert.equal('pair/BCDF-GHJK'.match(PAIR_ROUTE)[1], 'BCDF-GHJK');
  assert.equal('pair/bcdfghjk'.match(PAIR_ROUTE)[1], 'bcdfghjk');
  assert.equal('pair/bcdf ghjk'.match(PAIR_ROUTE)[1], 'bcdf ghjk', 'a space the address carried as %20');
  assert.equal(isPairPath('pair/BCDF-GHJK'), true);
  assert.equal(isPairPath('pair/bcdfghjk'), true);
  assert.equal(isPairPath('pair/sensors'), false, 'the sensors bridge’s page');
  assert.equal(isPairPath('pair/BCDF-GHJ'), false);
  assert.equal(isPairPath('pair/BCDF-GHJK-L'), false);
  assert.equal(isPairPath('pair/BCDF--GHJK'), false);
  assert.equal(isPairPath('pair/'), false);
  assert.equal(isPairPath('pair'), false);
  assert.equal(isPairPath('settings/BCDF-GHJK'), false);
  assert.equal(isPairPath('camera/0A1B2C3D-0000-4000-8000-000000000001/pair'), false);
  assert.equal(isPairPath('xpair/BCDF-GHJK'), false);
});

// MARK: Add

test('Add sends the code, says the TV can watch, and lists it; a code the bridge does not know is said on the card', async () => {
  let list = [BEDROOM];
  let loads = 0;
  const sent = [];
  const approved = [];
  const card = createViewersCard({
    load: async () => { loads += 1; return { viewers: list }; },
    approve: async (code) => {
      sent.push(code);
      if (code !== 'BCDF-GHJK') throw refusal(404, 'no_such_code', 'No Apple TV is waiting with this code. Check the code on the TV: it shows a new one every 10 minutes.');
      list = [LIVING_ROOM, ...list];
      return { viewer: LIVING_ROOM };
    },
    onApproved: (viewer) => approved.push(viewer.id),
    now: () => NOW,
  });
  await settle();
  assert.equal(loads, 1);
  assert.deepEqual(rowIDs(card), ['v2']);

  typeCode(card.el, 'bcdf ghjl');
  submit(card.el);
  await settle();
  assert.deepEqual(sent, ['BCDF-GHJL'], 'typed in lower case with a space, sent as ABCD-EFGH');
  assert.equal(problemOf(card), 'No Apple TV is waiting with this code. Check the code on the TV: it shows a new one every 10 minutes.', 'the bridge’s words, on the card');
  assert.deepEqual(rowIDs(card), ['v2'], 'the list is as it was');
  assert.equal(loads, 1, 'and not read again');
  assert.equal(inputOf(card.el).value, 'bcdf ghjl', 'the code stays in the field to be put right');
  assert.deepEqual(approved, []);
  assert.equal(named(card.el, 'Add')[0].getAttribute('aria-disabled'), null);

  typeCode(card.el, 'bcdf ghjk');
  submit(card.el);
  await settle();
  assert.deepEqual(sent, ['BCDF-GHJL', 'BCDF-GHJK']);
  assert.equal(inputOf(card.el).value, '', 'the field empties');
  assert.equal(problemOf(card), '', 'the earlier problem is gone');
  const said = () => visibleText(all(card.el, (node) => node.getAttribute('role') === 'status')[0]);
  assert.equal(said(), 'Living Room can watch your cameras now.');
  assert.equal(loads, 2, 'the list is read again');
  assert.deepEqual(rowIDs(card), ['v1', 'v2'], 'with the new Apple TV in it');
  assert.deepEqual(approved, ['v1'], 'the page is told, to leave the #/pair address');

  typeCode(card.el, 'bcdf ghjl');
  submit(card.el);
  await settle();
  assert.equal(said(), '', 'what was said of the last one does not stand beside the next refusal');
  assert.match(problemOf(card), /^No Apple TV is waiting/);
  card.destroy();
});

test('what was said of the last TV added is gone once another is removed', async () => {
  let list = [BEDROOM];
  const card = createViewersCard({
    load: async () => ({ viewers: list }),
    approve: async () => { list = [LIVING_ROOM, ...list]; return { viewer: LIVING_ROOM }; },
    remove: async (id) => { list = list.filter((viewer) => viewer.id !== id); },
    confirm: async () => true,
    now: () => NOW,
  });
  await settle();
  typeCode(card.el, 'bcdfghjk');
  submit(card.el);
  await settle();
  const said = () => visibleText(all(card.el, (node) => node.getAttribute('role') === 'status')[0]);
  assert.equal(said(), 'Living Room can watch your cameras now.');
  named(byClass(card.el, 'viewer-item').find((row) => row.dataset.id === 'v2'), 'Remove')[0].click();
  await settle();
  assert.equal(said(), '');
  assert.deepEqual(rowIDs(card), ['v1']);
  card.destroy();
});

test('Add without 8 letters asks for them and sends nothing', async () => {
  const sent = [];
  const card = createViewersCard({ load: async () => ({ viewers: [] }), approve: async (code) => { sent.push(code); return { viewer: LIVING_ROOM }; }, now: () => NOW });
  await settle();
  for (const typed of ['', '  ', 'bcdf', 'bcdf ghj', 'bcdf ghjk l', '1234 5678']) {
    typeCode(card.el, typed);
    submit(card.el);
    await settle();
    assert.equal(problemOf(card), 'Enter the 8 letters the Apple TV shows.', JSON.stringify(typed));
  }
  assert.deepEqual(sent, []);
  typeCode(card.el, 'bcdfghjk');
  submit(card.el);
  await settle();
  assert.deepEqual(sent, ['BCDF-GHJK']);
  assert.equal(problemOf(card), '', 'asked for no more');
  card.destroy();
});

test('a second press while the first is still out sends nothing more, and every refusal is said', async () => {
  const sent = [];
  let finish;
  let next = () => new Promise((resolve) => { finish = resolve; });
  const card = createViewersCard({ load: async () => ({ viewers: [] }), approve: (code) => { sent.push(code); return next(); }, now: () => NOW });
  await settle();
  typeCode(card.el, 'bcdfghjk');
  submit(card.el);
  submit(card.el);
  await settle();
  assert.deepEqual(sent, ['BCDF-GHJK'], 'once');
  assert.equal(named(card.el, 'Add')[0].getAttribute('aria-disabled'), 'true', 'Add is dimmed while it waits (and keeps the keyboard, which a disabled button would not)');
  assert.ok(!named(card.el, 'Add')[0].disabled, 'not disabled, which would take the keyboard off it');
  finish({ viewer: LIVING_ROOM });
  await settle();
  assert.equal(named(card.el, 'Add')[0].getAttribute('aria-disabled'), null);

  const messages = [
    [refusal(409, 'too_many_viewers', '20 Apple TVs are added already. Remove one you no longer use, then try again.'), '20 Apple TVs are added already. Remove one you no longer use, then try again.'],
    [refusal(500, 'storage', 'The Apple TV couldn’t be saved. The disk may be full or read-only.'), 'The Apple TV couldn’t be saved. The disk may be full or read-only.'],
    [new Error(''), 'That Apple TV couldn’t be added.'],
  ];
  for (const [error, said] of messages) {
    next = () => Promise.reject(error);
    typeCode(card.el, 'bcdfghjk');
    submit(card.el);
    await settle();
    assert.equal(problemOf(card), said);
    assert.equal(inputOf(card.el).value, 'bcdfghjk', 'nothing was added: the code stays');
    assert.equal(named(card.el, 'Add')[0].getAttribute('aria-disabled'), null, 'and Add can be pressed again');
  }
  card.destroy();
});

test('fill puts the code in the field as ABCD-EFGH and the keyboard on Add, and adds nothing', async () => {
  const watch = watchFocus();
  const sent = [];
  const card = createViewersCard({ load: async () => ({ viewers: [] }), approve: async (code) => { sent.push(code); return { viewer: LIVING_ROOM }; }, now: () => NOW });
  try {
    await settle();
    card.fill('12345678');
    assert.equal(fieldText(card.el), '', 'not a code: the field is left alone');
    assert.deepEqual(watch.focused, []);
    card.fill('bcdfghjk');
    assert.equal(inputOf(card.el).value, 'BCDF-GHJK');
    assert.equal(watch.focused.length, 1);
    assert.equal(watch.focused[0], named(card.el, 'Add')[0], 'the keyboard is on Add');
    await settle();
    assert.deepEqual(sent, [], 'a link alone must not add someone’s Apple TV');
  } finally {
    watch.restore();
    card.destroy();
  }
});

// MARK: Remove

test('Remove asks first: No sends nothing, Remove takes the TV off the list', async () => {
  const removed = [];
  const questions = [];
  let answer = false;
  let list = [LIVING_ROOM, BEDROOM];
  const card = createViewersCard({
    load: async () => ({ viewers: list }),
    remove: async (id) => { removed.push(id); list = list.filter((viewer) => viewer.id !== id); },
    confirm: async (question) => { questions.push(question); return answer; },
    now: () => NOW,
  });
  await settle();
  const button = (id) => named(byClass(card.el, 'viewer-item').find((row) => row.dataset.id === id), 'Remove')[0];
  button('v1').click();
  await settle();
  assert.deepEqual(questions, [{
    title: 'Remove Living Room?',
    body: 'Living Room · Apple TV 4K (3rd generation). It stops showing your cameras at once and needs a new code to come back.',
    confirm: 'Remove',
    danger: true,
  }]);
  assert.deepEqual(removed, [], 'No: nothing is sent');
  assert.deepEqual(rowIDs(card), ['v1', 'v2']);

  answer = true;
  button('v1').click();
  await settle();
  assert.deepEqual(removed, ['v1']);
  assert.deepEqual(rowIDs(card), ['v2']);
  assert.equal(questions.at(-1).title, 'Remove Living Room?');
  assert.equal(problemOf(card), '');

  button('v2').click();
  await settle();
  assert.equal(questions.at(-1).title, 'Remove Bedroom?');
  assert.equal(questions.at(-1).body, 'Bedroom. It stops showing your cameras at once and needs a new code to come back.', 'no model: the name alone');
  assert.deepEqual(rowIDs(card), []);
  assert.match(visibleText(card.el), /No Apple TV is added yet/, 'the last one is gone');
  card.destroy();
});

test('a TV the bridge no longer has counts as removed; any other refusal is said and the TV stays', async () => {
  let failure = refusal(404, 'not_found', 'That Apple TV isn’t added any more.');
  let loads = 0;
  const card = createViewersCard({
    load: async () => { loads += 1; return { viewers: loads === 1 ? [LIVING_ROOM, BEDROOM] : [BEDROOM] }; },
    remove: async () => { throw failure; },
    confirm: async () => true,
    now: () => NOW,
  });
  await settle();
  named(byClass(card.el, 'viewer-item')[0], 'Remove')[0].click();
  await settle();
  assert.deepEqual(rowIDs(card), ['v2'], 'it was gone already');
  assert.equal(problemOf(card), '');

  failure = refusal(500, 'error', 'Something went wrong (500).');
  named(byClass(card.el, 'viewer-item')[0], 'Remove')[0].click();
  await settle();
  assert.equal(problemOf(card), 'Something went wrong (500).');
  assert.deepEqual(rowIDs(card), ['v2'], 'still there');

  failure = new Error('');
  named(byClass(card.el, 'viewer-item')[0], 'Remove')[0].click();
  await settle();
  assert.equal(problemOf(card), 'That Apple TV couldn’t be removed.');
  card.destroy();
});

test('a card that is gone says nothing more', async () => {
  let release;
  const card = createViewersCard({ load: () => new Promise((resolve) => { release = resolve; }), now: () => NOW });
  await settle();
  card.destroy();
  release({ viewers: [LIVING_ROOM] });
  await settle();
  assert.deepEqual(rowIDs(card), [], 'the late answer is not drawn');
});

// MARK: The bridge's routes

test('without injected functions the card calls GET viewers, POST viewers/approve {code} and DELETE viewers/:id', async () => {
  const realFetch = globalThis.fetch;
  const calls = [];
  const odd = { ...LIVING_ROOM, id: 'a b/c' };
  let list = [BEDROOM];
  globalThis.fetch = async (url, init = {}) => {
    const path = String(url).replace('/api/v1/', '');
    calls.push([init.method ?? 'GET', path, init.body ? JSON.parse(init.body) : undefined]);
    const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
    if (init.method === 'POST') { list = [odd, ...list]; return json(201, { viewer: odd }); }
    if (init.method === 'DELETE') { list = list.filter((viewer) => viewer.id !== odd.id); return new Response(null, { status: 204 }); }
    return json(200, { viewers: list });
  };
  const card = createViewersCard({ confirm: async () => true, now: () => NOW });
  try {
    await settle();
    typeCode(card.el, 'bcdf ghjk');
    submit(card.el);
    await settle();
    named(byClass(card.el, 'viewer-item')[0], 'Remove')[0].click();
    await settle();
    assert.deepEqual(calls, [
      ['GET', 'viewers', undefined],
      ['POST', 'viewers/approve', { code: 'BCDF-GHJK' }],
      ['GET', 'viewers', undefined],
      ['DELETE', 'viewers/a%20b%2Fc', undefined],
      ['GET', 'viewers', undefined],
    ]);
    assert.deepEqual(rowIDs(card), ['v2']);
  } finally {
    card.destroy();
    globalThis.fetch = realFetch;
  }
});

// MARK: Settings

const SETTINGS = {
  bridgeName: 'Bridge', timeZone: 'UTC', logLevel: 'info', basePort: 21100, sensorsBridgePort: 21190, webhookEnabled: false, webhookPort: 21180,
  ai: { provider: 'anthropic', model: 'claude-haiku-5-5', keySaved: true, keyHint: '0000', today: 0, last7Days: 0, paused: false, needsRecordingsFolder: false },
};

/**
 * Settings drawn in the fake browser over a bridge that answers only what `routes` lists ("GET viewers": [status, body]) besides the settings;
 * the page's address is `hash`. `run` gets what it needs to look: the requests made, the addresses `history.replaceState` was given, what was
 * focused and scrolled to. Everything is put back afterwards.
 */
async function withSettings({ params, hash, routes = {} }, run) {
  const { renderSettings } = await import('../web/js/screens/settings.js');
  const realFetch = globalThis.fetch;
  const requests = [];
  const bodies = [];
  globalThis.fetch = async (url, init = {}) => {
    const key = `${init.method ?? 'GET'} ${String(url).replace('/api/v1/', '')}`;
    requests.push(key);
    if (init.body) bodies.push(JSON.parse(init.body));
    const answer = { 'GET settings': [200, SETTINGS], ...routes }[key];
    if (!answer) throw new TypeError('fetch failed (no bridge in this test)');
    return new Response(JSON.stringify(answer[1]), { status: answer[0], headers: { 'Content-Type': 'application/json' } });
  };
  const watch = watchFocus();
  const addresses = [];
  globalThis.history = { replaceState: (state, title, url) => { addresses.push(url); globalThis.location.hash = url; } };
  globalThis.location.hash = hash;
  let screen = null;
  try {
    screen = renderSettings({ params, setTitle: () => {} });
    browser.document.append(screen.el);
    const recordingHost = () => all(screen.el, (node) => node.getAttribute('id') === 'recording')[0];
    for (let i = 0; i < 400 && !recordingHost()?.firstChild; i += 1) await tick();   // the recording screens load
    for (let i = 0; i < 20; i += 1) await tick();
    await run({ screen, requests, bodies, addresses, focused: watch.focused, scrolled: watch.scrolled, card: byClass(screen.el, 'viewers-card')[0] });
  } finally {
    screen?.el.remove();
    screen?.destroy();
    watch.restore();
    delete globalThis.history;
    globalThis.fetch = realFetch;
  }
}

test('Settings opened from #/pair/<code> shows the card with the code filled in and the keyboard on Add', async () => {
  await withSettings({ params: ['apple-tv', 'bcdfghjk'], hash: '#/pair/bcdfghjk', routes: { 'GET viewers': [200, { viewers: [LIVING_ROOM] }] } }, ({ requests, scrolled, focused, card }) => {
    assert.ok(card, 'the Apple TV card is in Settings');
    assert.equal(scrolled.length, 1, 'scrolled to once');
    assert.equal(scrolled[0], card, 'to the Apple TV card');
    assert.equal(all(card, (node) => node.localName === 'h2')[0].textContent, 'Apple TV');
    assert.equal(inputOf(card).value, 'BCDF-GHJK', 'the code from the address, as the TV shows it');
    assert.ok(focused.includes(named(card, 'Add')[0]), 'the keyboard is on Add');
    assert.deepEqual(rowIDs({ el: card }), ['v1'], 'the Apple TVs already added are there');
    assert.ok(requests.includes('GET viewers'));
    assert.deepEqual(requests.filter((request) => request.startsWith('POST')), [], 'nothing was approved: a link alone must not add someone’s Apple TV');
  });
});

test('Settings opened without a code has the card, and moves nothing', async () => {
  await withSettings({ params: [], hash: '#/settings', routes: { 'GET viewers': [200, { viewers: [] }] } }, ({ scrolled, focused, card }) => {
    assert.ok(card);
    assert.equal(fieldText(card), '');
    assert.deepEqual(scrolled, []);
    assert.deepEqual(focused, []);
    assert.match(visibleText(card), /No Apple TV is added yet/);
  });
});

test('Add from the #/pair address makes the address #/settings, so a reload or Back does not fill the code again', async () => {
  const routes = { 'GET viewers': [200, { viewers: [] }], 'POST viewers/approve': [201, { viewer: LIVING_ROOM }] };
  await withSettings({ params: ['apple-tv', 'bcdfghjk'], hash: '#/pair/bcdfghjk', routes }, async ({ requests, bodies, addresses, card }) => {
    assert.deepEqual(addresses, [], 'filling in the code leaves the address as it is');
    submit(card);
    await settle();
    assert.deepEqual(requests.filter((request) => request.startsWith('POST')), ['POST viewers/approve']);
    assert.deepEqual(bodies, [{ code: 'BCDF-GHJK' }]);
    assert.deepEqual(addresses, ['#/settings']);
    assert.match(visibleText(card), /Living Room can watch your cameras now\./);
  });
});

test('Add from Settings itself leaves the address alone', async () => {
  const routes = { 'GET viewers': [200, { viewers: [] }], 'POST viewers/approve': [201, { viewer: LIVING_ROOM }] };
  await withSettings({ params: [], hash: '#/settings', routes }, async ({ requests, addresses, card }) => {
    typeCode(card, 'bcdf ghjk');
    submit(card);
    await settle();
    assert.ok(requests.includes('POST viewers/approve'));
    assert.deepEqual(addresses, []);
  });
});
