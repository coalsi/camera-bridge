// Settings › AI descriptions (screens/ai-settings.js): what the card shows from GET settings' `ai` (the service, the model, the limit, the key
// only as "Key saved" with its last four characters, the day's counts, a pause, the last problem with its time), the requests it makes
// (the settings first, the key after them, the key once and never back on the page, Try it) and the sentence about what leaves the box, in
// the fake browser with fake requests.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { ApiError } from '../web/js/api.js';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let ai;
before(async () => {
  browser = installFakeBrowser();
  ai = await import('../web/js/screens/ai-settings.js');
});
after(() => browser?.restore());

const WHAT_LEAVES = 'For each event on a camera with AI descriptions on, up to five still pictures from around the event are sent to the service you choose. No video, no sound, nothing else.';
const TRY_NOTE = 'Try it sends this camera’s current pictures to the service now, even when its AI switch is off.';
const PAUSED = 'Paused: the key was refused. Save a new key to start again.';
const RECORDINGS = 'AI descriptions need a place for recordings (Settings › Recording).';
const FAKE_KEY = 'sk-test-0000';
const DOOR = '0A1B2C3D-0000-4000-8000-000000000011';
const YARD = '0A1B2C3D-0000-4000-8000-000000000012';

const CLAUDE = {
  provider: 'anthropic', model: 'claude-haiku-5-5', baseURL: null, dailyLimit: 200, keySaved: true, keyHint: '0000', today: 3, last7Days: 12,
  limitReached: false, paused: false, lastError: null, lastErrorAt: null, needsRecordingsFolder: false,
};
const settingsWith = (changes = {}) => ({ bridgeName: 'Bridge', webhookPort: 21180, ai: { ...CLAUDE, ...changes } });
const OFF = { provider: null, keySaved: false, keyHint: null, today: 0, last7Days: 0 };

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const shown = (root, match) => all(root, match).filter(visible);
const inputs = (root) => all(root, (node) => node.localName === 'input');
const byName = (root, name) => all(root, (node) => node.dataset.ai === name)[0];
const button = (root, text) => shown(root, (node) => node.localName === 'button' && node.textContent === text)[0];
const keyInput = (root) => shown(root, (node) => node.localName === 'input' && node.getAttribute('type') === 'password')[0];
const shownText = (root) => {
  const parts = [];
  const walk = (node) => { if (node.hidden) return; if (!node.tagName) { parts.push(node.textContent); return; } for (const child of node.childNodes) walk(child); };
  walk(root);
  return parts.join(' ');
};
const settle = () => new Promise((resolve) => setImmediate(resolve));
const type = (input, value) => { input.value = value; input.dispatchEvent({ type: 'input', target: input }); };
const choose = (select, value) => { select.value = value; select.dispatchEvent({ type: 'change', target: select }); };
const submit = (card) => card.el.dispatchEvent({ type: 'submit', target: card.el, preventDefault() {} });

/** Fake requests: each one waits until the test answers it (`answer(value)` or `fail(error)`), in the order they were made. */
function fakeBridge({ cameras = [{ id: DOOR, name: 'Front door' }, { id: YARD, name: 'Yard' }] } = {}) {
  const sent = [];
  const waiting = [];
  const told = [];
  const notes = [];
  const wait = (request) => new Promise((resolve, reject) => { sent.push(request); waiting.push({ resolve, reject }); });
  const deps = {
    save: (body) => wait({ method: 'PATCH', path: 'settings', body: { ai: body } }),
    saveKey: (key) => wait({ method: 'PUT', path: 'ai/key', body: { key } }),
    removeKey: () => wait({ method: 'DELETE', path: 'ai/key' }),
    reload: () => wait({ method: 'GET', path: 'settings' }),
    tryIt: (cameraID) => wait({ method: 'POST', path: 'ai/try', body: { cameraID } }),
    cameras: () => cameras,
    watchCameras: () => () => {},
    confirm: async () => true,
    onSettings: (settings) => told.push(settings),
    notify: (text) => notes.push(text),
  };
  return {
    deps, sent, told, notes,
    answer: async (value = null) => { waiting.shift().resolve(value); await settle(); },
    fail: async (error) => { waiting.shift().reject(error); await settle(); },
  };
}

// MARK: What the card shows

test('the card shows provider, model, limit and only the key hint', () => {
  const card = ai.createAISettingsCard(settingsWith(), fakeBridge().deps);
  assert.equal(byName(card.el, 'provider').value, 'anthropic');
  assert.equal(byName(card.el, 'model').value, 'claude-haiku-5-5');
  assert.equal(byName(card.el, 'dailyLimit').value, '200');
  assert.match(shownText(card.el), /Key saved \(…0000\)/);
  assert.ok(button(card.el, 'Replace'), 'a Replace button');
  assert.ok(button(card.el, 'Remove'), 'a Remove button');
  assert.equal(keyInput(card.el), undefined, 'no key field while a key is saved');
  for (const input of inputs(card.el)) assert.ok(!String(input.value ?? '').includes('0000'), 'no input value holds a key');
  assert.match(shownText(card.el), /Today: 3 of 200 · last 7 days: 12/);

  const view = ai.aiSettingsView(settingsWith());
  assert.deepEqual([view.provider, view.model, view.dailyLimit, view.key], ['anthropic', 'claude-haiku-5-5', 200, 'Key saved (…0000)']);
  assert.equal(view.counts, 'Today: 3 of 200 · last 7 days: 12');
});

test('a key too short for a hint reads “Key saved” without the dots; no key reads as a field to paste one', () => {
  assert.equal(ai.aiSettingsView(settingsWith({ keyHint: null })).key, 'Key saved');
  const card = ai.createAISettingsCard(settingsWith({ keyHint: null }), fakeBridge().deps);
  assert.match(shownText(card.el), /Key saved/);
  assert.doesNotMatch(shownText(card.el), /…/);

  assert.equal(ai.aiSettingsView(settingsWith({ keySaved: false, keyHint: null })).key, null);
  const empty = ai.createAISettingsCard(settingsWith({ keySaved: false, keyHint: null }), fakeBridge().deps);
  const field = keyInput(empty.el);
  assert.ok(field, 'a key field');
  assert.deepEqual([field.getAttribute('type'), field.getAttribute('autocomplete'), field.value ?? ''], ['password', 'off', ''], 'write-only and empty');
});

test('the card says exactly what leaves the box', () => {
  for (const settings of [settingsWith(), settingsWith(OFF)]) {
    const card = ai.createAISettingsCard(settings, fakeBridge().deps);
    assert.equal(all(card.el, (node) => node.localName === 'h2')[0].textContent, 'AI descriptions');
    const sentences = shown(card.el, (node) => node.localName === 'p' && node.textContent === WHAT_LEAVES);
    assert.equal(sentences.length, 1, 'the sentence, word for word, in a paragraph of its own');
  }
  assert.equal(ai.AI_TEXT.whatLeaves, WHAT_LEAVES);
});

test('the status line: the counts, the limit, a pause, the last problem with its time, and the recordings folder', () => {
  const at = '2026-10-19T16:05:00Z';
  const view = ai.aiSettingsView(settingsWith({ today: 200, last7Days: 640, limitReached: true, paused: true, lastError: 'The key was refused.', lastErrorAt: at, needsRecordingsFolder: true }));
  assert.equal(view.counts, 'Today: 200 of 200 · last 7 days: 640');
  assert.equal(view.limitReached, 'Today’s limit is reached. Events are kept without a description until midnight.');
  assert.equal(view.paused, PAUSED);
  assert.deepEqual(view.lastError, { message: 'The key was refused.', at });
  assert.equal(view.recordings, RECORDINGS);

  const card = ai.createAISettingsCard(settingsWith({ paused: true, lastError: 'The service could not be reached.', lastErrorAt: at, needsRecordingsFolder: true }), fakeBridge().deps);
  const text = shownText(card.el);
  assert.ok(text.includes(PAUSED));
  assert.ok(shown(card.el, (node) => node.textContent === RECORDINGS).length, 'the recordings sentence, word for word');
  const time = shown(card.el, (node) => node.localName === 'time')[0];
  assert.equal(time?.getAttribute('datetime'), at, 'the last problem shows when it was');
  assert.ok(shown(card.el, (node) => node.textContent.includes('The service could not be reached.') && node.textContent.includes(time.textContent)).length,
    'the time is shown with the problem');

  const quiet = ai.aiSettingsView(settingsWith());
  assert.deepEqual([quiet.limitReached, quiet.paused, quiet.lastError, quiet.recordings], [null, null, null, null]);
  assert.equal(ai.aiSettingsView(settingsWith({ lastError: 'The key was refused.', lastErrorAt: null })).lastError.at, null, 'a problem without a time still shows');
  const off = ai.aiSettingsView(settingsWith({ ...OFF, needsRecordingsFolder: true }));
  assert.deepEqual([off.provider, off.counts, off.recordings], [null, null, null], 'with no service chosen there is nothing to count or wait for');
});

test('Claude saved without a key says it needs one; a service at an address may need none', () => {
  const sentence = 'Claude needs a key: events are described once it is saved.';
  assert.equal(ai.aiSettingsView(settingsWith({ keySaved: false, keyHint: null })).needsKey, sentence);
  const card = ai.createAISettingsCard(settingsWith({ keySaved: false, keyHint: null }), fakeBridge().deps);
  assert.ok(shown(card.el, (node) => node.classList.contains('banner') && node.textContent === sentence).length, 'a banner with the sentence');
  assert.equal(ai.aiSettingsView(settingsWith()).needsKey, null, 'a key is saved');
  assert.equal(ai.aiSettingsView(settingsWith({ provider: 'openAICompatible', model: 'llava', baseURL: 'http://192.168.77.10:11434/v1', keySaved: false, keyHint: null })).needsKey, null);
  assert.equal(ai.aiSettingsView(settingsWith(OFF)).needsKey, null);
});

// MARK: Saving

test('saving a key sends it once and clears the field', async () => {
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith({ keySaved: false, keyHint: null }), bridge.deps);
  const input = keyInput(card.el);
  type(input, FAKE_KEY);
  submit(card);
  assert.deepEqual(bridge.sent, [{ method: 'PUT', path: 'ai/key', body: { key: FAKE_KEY } }], 'nothing else changed: only the key is sent');
  submit(card);
  assert.equal(bridge.sent.length, 1, 'a second Save while the first one runs sends nothing');
  await bridge.answer(null);   // 204
  assert.deepEqual(bridge.sent.at(-1), { method: 'GET', path: 'settings' }, 'then the card reads what the bridge has');
  await bridge.answer(settingsWith());
  assert.equal(bridge.sent.filter((request) => JSON.stringify(request.body ?? '').includes(FAKE_KEY)).length, 1, 'the key went out once');
  assert.equal(keyInput(card.el), undefined, 'the field is gone: a key is saved');
  assert.equal(input.value, '', 'the field the key was typed in is empty afterwards');
  assert.match(shownText(card.el), /Key saved \(…0000\)/);
  assert.equal(bridge.told.length, 1, 'the page hears of the new settings');

  button(card.el, 'Replace').click();
  assert.equal(keyInput(card.el).value, '', 'Replace opens an empty field');
  submit(card);
  assert.equal(bridge.sent.length, 2, 'an empty field sends nothing');
  assert.equal(keyInput(card.el), undefined, 'and the saved key shows again');
});

test('a key the bridge refuses shows its sentence and stays in the field to be corrected', async () => {
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith({ keySaved: false, keyHint: null }), bridge.deps);
  type(keyInput(card.el), 'sk test');
  submit(card);
  await bridge.fail(new ApiError(400, 'invalid', 'Paste the key from your AI service as it is.', 'key'));
  assert.match(shownText(card.el), /Paste the key from your AI service as it is\./);
  assert.equal(keyInput(card.el).value, 'sk test');
});

test('a new service and a key: the key is sent only after the bridge saved the service', async () => {
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith(), bridge.deps);
  choose(byName(card.el, 'provider'), 'openAICompatible');
  type(byName(card.el, 'baseURL'), 'http://192.168.77.10:11434/v1');
  type(byName(card.el, 'model'), 'llava');
  type(keyInput(card.el), FAKE_KEY);
  submit(card);
  assert.deepEqual(bridge.sent, [{ method: 'PATCH', path: 'settings', body: { ai: { provider: 'openAICompatible', model: 'llava', baseURL: 'http://192.168.77.10:11434/v1' } } }],
    'the service first: changing it removes the saved key on the bridge, so a key sent before would be lost');
  await bridge.answer(settingsWith({ provider: 'openAICompatible', model: 'llava', baseURL: 'http://192.168.77.10:11434/v1', keySaved: false, keyHint: null }));
  assert.deepEqual(bridge.sent.at(-1), { method: 'PUT', path: 'ai/key', body: { key: FAKE_KEY } });
  await bridge.answer(null);
  await bridge.answer(settingsWith({ provider: 'openAICompatible', model: 'llava', baseURL: 'http://192.168.77.10:11434/v1' }));
  assert.deepEqual(bridge.sent.map((request) => request.method), ['PATCH', 'PUT', 'GET']);
  assert.equal(keyInput(card.el), undefined);
});

test('a key typed for one service is never sent to another: changing the service empties the field', async () => {
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith({ keySaved: false, keyHint: null }), bridge.deps);
  const input = keyInput(card.el);
  type(input, FAKE_KEY);
  choose(byName(card.el, 'provider'), 'openAICompatible');
  assert.equal(input.value, '', 'the Claude key leaves with Claude');
  type(byName(card.el, 'baseURL'), 'http://192.168.77.10:11434/v1');
  type(byName(card.el, 'model'), 'llava');
  submit(card);
  await bridge.answer(settingsWith({ provider: 'openAICompatible', model: 'llava', baseURL: 'http://192.168.77.10:11434/v1', keySaved: false, keyHint: null }));
  assert.deepEqual(bridge.sent.map((request) => request.method), ['PATCH'], 'no PUT: the key was typed for Claude');

  type(keyInput(card.el), FAKE_KEY);
  choose(byName(card.el, 'provider'), '');
  assert.equal(input.value, '', 'Off empties it too');
});

test('a Save with nothing changed sends nothing and says so', () => {
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith(), bridge.deps);
  submit(card);
  assert.deepEqual(bridge.sent, []);
  assert.deepEqual(bridge.notes, ['Nothing to change.']);
});

test('a key saved while the settings could not be read again says it is saved', async () => {
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith({ keySaved: false, keyHint: null }), bridge.deps);
  const input = keyInput(card.el);
  type(input, FAKE_KEY);
  submit(card);
  await bridge.answer(null);   // PUT 204
  await bridge.fail(new ApiError(0, 'network', 'The bridge didn’t answer.'));
  assert.match(shownText(card.el), /Key saved; reload the page to see it\./);
  assert.doesNotMatch(shownText(card.el), /The bridge didn’t answer/);
  assert.equal(input.value, '');
});

test('the “Saved without /chat/completions” note goes after a save that failed or took nothing off', async () => {
  const note = /without “\/chat\/completions”/;
  const home = { provider: 'openAICompatible', model: 'llava', baseURL: 'http://192.168.77.11:11434/v1' };
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith({ ...home, baseURL: 'http://192.168.77.10:11434/v1' }), bridge.deps);
  type(byName(card.el, 'baseURL'), 'http://192.168.77.11:11434/v1/chat/completions');
  submit(card);
  await bridge.fail(new ApiError(422, 'settings_failed', 'The settings could not be saved.'));
  assert.doesNotMatch(shownText(card.el), note, 'nothing was saved');

  type(byName(card.el, 'baseURL'), 'http://192.168.77.11:11434/v1/chat/completions');
  submit(card);
  await bridge.answer(settingsWith(home));
  assert.match(shownText(card.el), note);
  type(byName(card.el, 'dailyLimit'), '50');
  submit(card);
  await bridge.answer(settingsWith({ ...home, dailyLimit: 50 }));
  assert.doesNotMatch(shownText(card.el), note, 'that save took nothing off');
});

test('a refused service change sends no key', async () => {
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith(), bridge.deps);
  choose(byName(card.el, 'provider'), 'openAICompatible');
  type(byName(card.el, 'baseURL'), 'ftp://192.168.77.10/v1');
  type(byName(card.el, 'model'), 'llava');
  type(keyInput(card.el), FAKE_KEY);
  submit(card);
  await bridge.fail(new ApiError(400, 'invalid', 'Enter the service’s address, like https://example.com/v1.', 'ai.baseURL'));
  assert.deepEqual(bridge.sent.map((request) => request.method), ['PATCH']);
  assert.match(shownText(card.el), /Enter the service’s address/);
  assert.equal(keyInput(card.el).value, FAKE_KEY, 'the key waits for a service that saves');
});

test('changing the service says the saved key goes with it', () => {
  const card = ai.createAISettingsCard(settingsWith(), fakeBridge().deps);
  assert.doesNotMatch(shownText(card.el), /removes the saved key/);
  choose(byName(card.el, 'provider'), 'openAICompatible');
  assert.match(shownText(card.el), /Changing the service removes the saved key\./);
  assert.ok(keyInput(card.el), 'a field for the new service’s key');
  choose(byName(card.el, 'provider'), 'anthropic');
  assert.doesNotMatch(shownText(card.el), /removes the saved key/);
  assert.match(shownText(card.el), /Key saved \(…0000\)/);

  const home = ai.createAISettingsCard(settingsWith({ provider: 'openAICompatible', model: 'llava', baseURL: 'http://192.168.77.10:11434/v1' }), fakeBridge().deps);
  type(byName(home.el, 'baseURL'), 'http://192.168.77.10:11434/v2');
  assert.doesNotMatch(shownText(home.el), /removes the saved key/, 'another path on the same server keeps the key');
  type(byName(home.el, 'baseURL'), 'http://192.168.77.11:11434/v1');
  assert.match(shownText(home.el), /Changing the service removes the saved key\./, 'another server does not');
});

test('OpenAI-compatible shows the address field; Claude does not', () => {
  const card = ai.createAISettingsCard(settingsWith(), fakeBridge().deps);
  assert.equal(visible(byName(card.el, 'baseURL')), false);
  assert.equal(visible(byName(card.el, 'model')), true);
  choose(byName(card.el, 'provider'), 'openAICompatible');
  assert.equal(visible(byName(card.el, 'baseURL')), true);
  assert.equal(byName(card.el, 'model').value, '', 'Claude’s model is no name for another service');
  type(byName(card.el, 'model'), 'llava');
  choose(byName(card.el, 'provider'), 'anthropic');
  assert.equal(visible(byName(card.el, 'baseURL')), false);
  assert.equal(byName(card.el, 'model').value, 'claude-haiku-5-5', 'Claude gets its own model back');
  choose(byName(card.el, 'provider'), '');
  assert.deepEqual(['model', 'dailyLimit', 'baseURL'].map((name) => visible(byName(card.el, name))), [false, false, false], 'Off asks for nothing');
});

test('turning it off saves no service', async () => {
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith(), bridge.deps);
  choose(byName(card.el, 'provider'), '');
  submit(card);
  assert.deepEqual(bridge.sent, [{ method: 'PATCH', path: 'settings', body: { ai: { provider: null } } }]);
  await bridge.answer(settingsWith(OFF));
  assert.equal(button(card.el, 'Try it'), undefined, 'no Try it without a service');
  assert.doesNotMatch(shownText(card.el), /Today:/);
});

test('an address ending in /chat/completions is saved without it, and the card says so', async () => {
  assert.deepEqual(ai.cleanAddress(' https://api.openai.com/v1/chat/completions '), { address: 'https://api.openai.com/v1', stripped: true });
  assert.deepEqual(ai.cleanAddress('http://192.168.77.10:11434/v1/Chat/Completions/'), { address: 'http://192.168.77.10:11434/v1', stripped: true });
  assert.deepEqual(ai.cleanAddress('http://192.168.77.10:11434/v1'), { address: 'http://192.168.77.10:11434/v1', stripped: false });

  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith({ provider: 'openAICompatible', model: 'llava', baseURL: 'http://192.168.77.10:11434/v1' }), bridge.deps);
  assert.doesNotMatch(shownText(card.el), /chat\/completions/);
  type(byName(card.el, 'baseURL'), 'http://192.168.77.10:11434/v1/chat/completions');
  type(byName(card.el, 'dailyLimit'), '50');
  submit(card);
  assert.deepEqual(bridge.sent[0].body, { ai: { dailyLimit: 50 } }, 'the address is the one saved already, once the end is taken off');
  await bridge.answer(settingsWith({ provider: 'openAICompatible', model: 'llava', baseURL: 'http://192.168.77.10:11434/v1', dailyLimit: 50 }));
  assert.equal(byName(card.el, 'baseURL').value, 'http://192.168.77.10:11434/v1');
  assert.match(shownText(card.el), /without “\/chat\/completions”/);
});

test('a daily limit out of range is not sent', () => {
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith(), bridge.deps);
  type(byName(card.el, 'dailyLimit'), '0');
  submit(card);
  assert.deepEqual(bridge.sent, []);
  assert.match(shownText(card.el), /The daily limit is 1 to 5000 descriptions\./);
});

test('removing the key asks first, then the card shows a field for a new one', async () => {
  const bridge = fakeBridge();
  let asked = 0;
  const card = ai.createAISettingsCard(settingsWith(), { ...bridge.deps, confirm: async () => { asked += 1; return asked > 1; } });
  button(card.el, 'Remove').click();
  await settle();
  assert.deepEqual(bridge.sent, [], 'a “no” removes nothing');
  button(card.el, 'Remove').click();
  await settle();
  assert.deepEqual(bridge.sent, [{ method: 'DELETE', path: 'ai/key' }]);
  await bridge.answer(null);
  await bridge.answer(settingsWith({ keySaved: false, keyHint: null }));
  assert.ok(keyInput(card.el));
  assert.doesNotMatch(shownText(card.el), /Key saved/);
});

test('news from the rest of the page keeps what is being typed; a changed choice is shown', () => {
  const card = ai.createAISettingsCard(settingsWith(), fakeBridge().deps);
  type(byName(card.el, 'dailyLimit'), '75');
  card.update(settingsWith({ today: 4, bridgeName: 'Renamed' }));
  assert.equal(byName(card.el, 'dailyLimit').value, '75');
  assert.match(shownText(card.el), /Today: 4 of 200/);
  card.update(settingsWith({ dailyLimit: 300 }));
  assert.equal(byName(card.el, 'dailyLimit').value, '300');
});

// MARK: Try it

test('Try it shows the sentence, the seconds, or the error sentence', async () => {
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith(), bridge.deps);
  assert.ok(shown(card.el, (node) => node.textContent === TRY_NOTE).length, 'the card says Try it sends the pictures now');
  const camera = shown(card.el, (node) => node.localName === 'select' && node.dataset.ai === 'tryCamera')[0];
  assert.deepEqual(camera.childNodes.map((option) => option.textContent), ['Front door', 'Yard']);
  choose(camera, YARD);
  button(card.el, 'Try it').click();
  assert.deepEqual(bridge.sent, [{ method: 'POST', path: 'ai/try', body: { cameraID: YARD } }]);
  assert.match(shownText(card.el), /Trying…/);
  button(card.el, 'Try it')?.click();
  assert.equal(bridge.sent.length, 1, 'one try at a time');
  await bridge.answer({ summary: 'A person walks up to the front door', kind: 'person', concern: 'routine', seconds: 6.2 });
  assert.match(shownText(card.el), /A person walks up to the front door/);
  assert.match(shownText(card.el), /Took 6\.2 s/);
  assert.deepEqual(bridge.sent.at(-1), { method: 'GET', path: 'settings' }, 'the counts are read again: a try counts');
  const summary = shown(card.el, (node) => node.classList.contains('ai-try-summary'))[0];
  await bridge.answer(settingsWith({ today: 4 }));
  assert.match(shownText(card.el), /Today: 4 of 200/);
  assert.equal(shown(card.el, (node) => node.classList.contains('ai-try-summary'))[0], summary, 'the answer stays when the counts come in, not drawn (and announced) again');

  button(card.el, 'Try it').click();
  assert.deepEqual(bridge.sent.at(-1).body, { cameraID: YARD }, 'the chosen camera stays chosen');
  await bridge.fail(new ApiError(502, 'The key was refused.', 'The key was refused.'));
  assert.match(shownText(card.el), /The key was refused\./);
  const result = all(card.el, (node) => node.classList.contains('ai-try-result'))[0];
  assert.equal(result.getAttribute('role'), 'status');
  assert.deepEqual(all(result, (node) => node.hasAttribute('role')), [], 'no live region (an alert) inside the status region');
  assert.doesNotMatch(shownText(card.el), /A person walks up/);
  assert.doesNotMatch(shownText(card.el), /Took/);
});

test('Try it’s camera list follows the cameras the page hears of, without drawing the answer again', async () => {
  const list = [];
  let heard = null;
  let stopped = false;
  const bridge = fakeBridge({ cameras: list });
  const card = ai.createAISettingsCard(settingsWith(), { ...bridge.deps, watchCameras: (fn) => { heard = fn; return () => { stopped = true; }; } });
  assert.equal(button(card.el, 'Try it'), undefined, 'Settings can open before the page has heard of any camera');
  list.push({ id: DOOR, name: 'Front door' });
  heard();
  button(card.el, 'Try it').click();
  await bridge.answer({ summary: 'A cat crosses the yard', kind: 'animal', concern: 'routine', seconds: 5 });
  const summary = shown(card.el, (node) => node.classList.contains('ai-try-summary'))[0];
  list.push({ id: YARD, name: 'Yard' });
  heard();
  const camera = shown(card.el, (node) => node.localName === 'select' && node.dataset.ai === 'tryCamera')[0];
  assert.deepEqual(camera.childNodes.map((option) => option.textContent), ['Front door', 'Yard']);
  assert.equal(shown(card.el, (node) => node.classList.contains('ai-try-summary'))[0], summary, 'the answer is not drawn (and announced) again');
  card.destroy();
  assert.equal(stopped, true, 'the card stops listening when Settings closes');
});

test('a Try it answer goes when another service is saved', async () => {
  const bridge = fakeBridge();
  const card = ai.createAISettingsCard(settingsWith(), bridge.deps);
  button(card.el, 'Try it').click();
  await bridge.fail(new ApiError(502, 'The key was refused.', 'The key was refused.'));
  await bridge.answer(settingsWith({ paused: true }));
  assert.match(shownText(card.el), /The key was refused\./);
  card.update(settingsWith({ provider: 'openAICompatible', model: 'llava', baseURL: 'http://192.168.77.10:11434/v1', keySaved: false, keyHint: null }));
  assert.doesNotMatch(shownText(card.el), /The key was refused\./, 'it was the other service’s answer');
});

test('Try it waits for a camera and for a saved service', () => {
  const none = ai.createAISettingsCard(settingsWith(), fakeBridge({ cameras: [] }).deps);
  assert.equal(button(none.el, 'Try it'), undefined);
  assert.match(shownText(none.el), /Add a camera to try it\./);
  const unsaved = ai.createAISettingsCard(settingsWith(OFF), fakeBridge().deps);
  choose(byName(unsaved.el, 'provider'), 'anthropic');
  assert.equal(button(unsaved.el, 'Try it'), undefined, 'Try it uses the saved service');
});

// MARK: Settings

test('Settings has an AI section, before Troubleshooting, holding the card', async () => {
  const { renderSettings } = await import('../web/js/screens/settings.js');
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (String(url).endsWith('/api/v1/settings')) {
      return new Response(JSON.stringify(settingsWith({ timeZone: 'UTC', logLevel: 'info', basePort: 21100, sensorsBridgePort: 21190, webhookEnabled: false })), { status: 200, headers: { 'Content-Type': 'application/json' } });
    }
    throw new TypeError('fetch failed (no bridge in this test)');
  };
  let screen = null;
  try {
    screen = renderSettings({ params: [], setTitle: () => {} });
    for (let i = 0; i < 20; i += 1) await settle();
    const titles = all(screen.el, (node) => node.classList.contains('section-title')).map((node) => node.textContent);
    assert.ok(titles.includes('AI'), `sections: ${titles.join(', ')}`);
    assert.equal(titles.indexOf('AI') + 1, titles.indexOf('Troubleshooting'));
    const section = all(screen.el, (node) => node.classList.contains('settings-section')).find((node) => node.childNodes[0].textContent === 'AI');
    assert.ok(all(section, (node) => node.localName === 'h2' && node.textContent === 'AI descriptions').length);
  } finally {
    screen?.destroy();
    globalThis.fetch = realFetch;
  }
});

// Final review M2: nothing tells an owner that a newer Claude model may not work with Camera Bridge's request, so the field says to leave it.
test('Claude’s model field says to leave it on the default unless the model is known to work', () => {
  const HINT = 'Leave it on the default unless you know another model works with Camera Bridge.';
  const claude = ai.createAISettingsCard(settingsWith());
  assert.equal(ai.AI_TEXT.claudeModelHint, HINT);
  const hintsOf = (card) => shown(card.el, (node) => node.classList?.contains('hint')).map((node) => node.textContent);
  assert.ok(hintsOf(claude).includes(HINT), 'under the model field of Claude');
  const field = (card) => all(card.el, (node) => node.classList?.contains('field') && all(node, (inner) => inner === byName(card.el, 'model')).length > 0)[0];
  assert.ok(shownText(field(claude)).includes(HINT), 'in the model field itself, below its input');
  claude.destroy();

  // Not for a service whose models are the owner's own business, and not when no service is chosen.
  const home = ai.createAISettingsCard(settingsWith({ provider: 'openAICompatible', model: 'llava', baseURL: 'http://192.168.77.10:11434/v1', keySaved: false }));
  assert.ok(!hintsOf(home).includes(HINT));
  home.destroy();
  const off = ai.createAISettingsCard(settingsWith(OFF));
  assert.ok(!hintsOf(off).includes(HINT));
  // Choosing a service in the card moves the hint with it.
  choose(byName(off.el, 'provider'), 'anthropic');
  assert.ok(hintsOf(off).includes(HINT));
  choose(byName(off.el, 'provider'), 'openAICompatible');
  assert.ok(!hintsOf(off).includes(HINT));
  off.destroy();
});
