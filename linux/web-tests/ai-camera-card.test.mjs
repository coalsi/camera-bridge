// The camera page's AI descriptions card (screens/camera.js createAIDescriptionsCard): the camera's switch "Describe events with AI", off
// while no AI service is chosen in Settings (with the way there), what Settings says is missing, and the camera's last description with its
// time, in the fake browser with fake requests. And the camera page: the switch moves in place, the page is not built again.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let page;
let stampText;
before(async () => {
  browser = installFakeBrowser();
  page = await import('../web/js/screens/camera.js');
  ({ stampText } = await import('../web/js/stamp.js'));
});
after(() => browser?.restore());

const DOOR = '0A1B2C3D-0000-4000-8000-000000000021';
const T0 = 1760099000000;
const CLAUDE = { provider: 'anthropic', model: 'claude-haiku-5-5', keySaved: true, keyHint: '0000', today: 0, last7Days: 0, paused: false, needsRecordingsFolder: false };
const OFF = { provider: null, keySaved: false, today: 0, last7Days: 0, paused: false, needsRecordingsFolder: false };
const settingsWith = (ai) => ({ bridgeName: 'Bridge', ai });
const camera = (extra = {}) => ({ id: DOOR, name: 'Front door', aiDescriptions: false, status: { connection: 'online', lastEventDate: null }, ...extra });
const said = (summary, kind, concern) => ({ summary, kind, concern });

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const links = (root) => all(root, (node) => node.localName === 'a' && visible(node)).map((node) => [node.textContent, node.getAttribute('href')]);
const theSwitch = (root) => all(root, (node) => node.localName === 'input' && node.getAttribute('role') === 'switch')[0];
const settle = async () => { for (let i = 0; i < 5; i += 1) await new Promise((resolve) => setImmediate(resolve)); };

/**
 * The card with fake requests: `settings` and `events` answer at once (`events` may be an Error, or a function giving the list or throwing),
 * with the bridge's clock `clock.ms` as the answer's serverTime; `saved` keeps what the switch sent.
 */
function cardWith({ ai = CLAUDE, events = [], at = camera(), timers, clock = { ms: T0 } } = {}) {
  const saved = [];
  const asked = [];
  const card = page.createAIDescriptionsCard(at, {
    save: (on) => saved.push(on),
    settings: async () => { if (ai instanceof Error) throw ai; return settingsWith(ai); },
    events: async (cameraID) => {
      asked.push(cameraID);
      const list = typeof events === 'function' ? events() : events;
      if (list instanceof Error) throw list;
      return { more: false, serverTime: clock.ms, events: list };
    },
    ...(timers ?? {}),
  });
  return { card, saved, asked };
}

/** Timers the test runs by hand. */
function handTimers() {
  const timers = [];
  return { timers, setTimer: (fn, ms) => { timers.push({ fn, ms, done: false }); return timers.length; }, clearTimer: (n) => { timers[n - 1].done = true; } };
}
const fire = async (entry) => { entry.done = true; entry.fn(); await settle(); };
const waiting = (timers) => timers.filter((entry) => !entry.done);

test('the camera card switch is disabled with a link to Settings until a provider is set', async () => {
  const off = cardWith({ ai: OFF });
  await settle();
  const input = theSwitch(off.card.el);
  assert.equal(all(off.card.el, (node) => node.localName === 'h2')[0].textContent, 'AI descriptions');
  assert.match(off.card.el.textContent, /Describe events with AI/);
  assert.equal(input.checked, false);
  assert.equal(input.disabled, true, 'nothing to describe with yet');
  assert.deepEqual(links(off.card.el), [['Settings › AI descriptions', '#/settings/ai']]);
  assert.match(off.card.el.textContent, /To turn this on, choose an AI service in Settings › AI descriptions\./);
  off.card.destroy();

  const on = cardWith({ ai: CLAUDE });
  await settle();
  const ready = theSwitch(on.card.el);
  assert.equal(ready.disabled, false);
  assert.deepEqual(links(on.card.el), [], 'no way to Settings needed');
  ready.checked = true;
  ready.dispatchEvent({ type: 'change', target: ready });
  assert.deepEqual(on.saved, [true]);
  on.card.destroy();

  // A camera already on while no service is chosen (it was turned off in Settings) says so, and can still be turned off here.
  const left = cardWith({ ai: OFF, at: camera({ aiDescriptions: true }) });
  await settle();
  const still = theSwitch(left.card.el);
  assert.equal(still.checked, true);
  assert.equal(still.disabled, false);
  assert.match(left.card.el.textContent, /AI descriptions are on for this camera, but no AI service is chosen \(Settings › AI descriptions\)\./);
  assert.doesNotMatch(left.card.el.textContent, /To turn this on/);
  assert.deepEqual(links(left.card.el), [['Settings › AI descriptions', '#/settings/ai']]);
  still.checked = false;
  still.dispatchEvent({ type: 'change', target: still });
  assert.deepEqual(left.saved, [false]);
  assert.match(left.card.el.textContent, /To turn this on, choose an AI service in Settings › AI descriptions\./, 'off now: the way to turn it on');
  left.card.destroy();

  // Settings could not be read: the switch is not held back for it.
  const unknown = cardWith({ ai: new Error('The bridge didn’t answer.') });
  assert.equal(theSwitch(unknown.card.el).disabled, true, 'while Settings has not answered');
  await settle();
  assert.equal(theSwitch(unknown.card.el).disabled, false);
  assert.deepEqual(links(unknown.card.el), []);
  unknown.card.destroy();
});

test('the camera card says when Settings needs a recordings folder, a pause or a key', async () => {
  const folder = cardWith({ ai: { ...CLAUDE, needsRecordingsFolder: true } });
  await settle();
  assert.match(folder.card.el.textContent, /AI descriptions need a place for recordings \(Settings › Recording\)\./);
  assert.deepEqual(links(folder.card.el), [['Settings › Recording', '#/settings/recording']]);
  assert.equal(theSwitch(folder.card.el).disabled, false, 'it can be turned on before the folder is chosen');
  folder.card.destroy();

  // The pause and the missing key matter only to a camera that is on.
  const pausedOff = cardWith({ ai: { ...CLAUDE, paused: true } });
  await settle();
  assert.doesNotMatch(pausedOff.card.el.textContent, /Paused/);
  assert.deepEqual(links(pausedOff.card.el), []);
  const flip = theSwitch(pausedOff.card.el);
  flip.checked = true;
  flip.dispatchEvent({ type: 'change', target: flip });
  assert.match(pausedOff.card.el.textContent, /Paused: the key was refused\. Save a new key to start again\./, 'turned on: now it matters');
  pausedOff.card.destroy();

  const paused = cardWith({ ai: { ...CLAUDE, paused: true }, at: camera({ aiDescriptions: true }) });
  await settle();
  assert.match(paused.card.el.textContent, /Paused: the key was refused\. Save a new key to start again\./);
  assert.deepEqual(links(paused.card.el), [['Settings › AI descriptions', '#/settings/ai']]);
  paused.card.destroy();

  const keylessOff = cardWith({ ai: { ...CLAUDE, keySaved: false } });
  await settle();
  assert.doesNotMatch(keylessOff.card.el.textContent, /needs a key/);
  keylessOff.card.destroy();

  // All of them: the same order and words as Settings › AI descriptions (the pause, the key, the place for recordings).
  const everything = { ...CLAUDE, paused: true, keySaved: false, needsRecordingsFolder: true };
  const keyless = cardWith({ ai: everything, at: camera({ aiDescriptions: true }) });
  await settle();
  const { aiNotices, aiSettingsView } = await import('../web/js/screens/ai-settings.js');
  const settingsBanners = aiNotices(aiSettingsView(settingsWith(everything))).filter(Boolean).map((node) => node.textContent);
  const cardBanners = byClass(keyless.card.el, 'banner').map((node) => node.textContent);
  assert.equal(cardBanners.length, 3);
  assert.deepEqual(cardBanners, [`${settingsBanners[0]} Settings › AI descriptions`, `${settingsBanners[1]} Settings › AI descriptions`, settingsBanners[2]]);
  assert.match(cardBanners[1], /^Claude needs a key: events are described once it is saved\./);
  keyless.card.destroy();
});

test('the camera card shows the camera’s last description with its time, or “No description in the latest events”', async () => {
  const event = (n, description, kind = 'Person') => ({ id: `e${n}`, cameraID: DOOR, kind, start: T0 - n * 60_000, end: null, recorded: true, description });
  const described = cardWith({ events: [event(1, null, 'Motion'), event(2, said('A person tries the door handle', 'person', 'alarm')), event(3, said('A cat crosses the lawn', 'animal', 'routine'))] });
  await settle();
  assert.deepEqual(described.asked, [DOOR]);
  const summary = byClass(described.card.el, 'ai-cam-summary')[0];
  assert.equal(summary.textContent, 'A person tries the door handle', 'the newest event that has one');
  assert.equal(summary.dataset.concern, 'alarm');
  const time = all(described.card.el, (node) => node.localName === 'time')[0];
  assert.equal(time.getAttribute('datetime'), new Date(T0 - 120_000).toISOString());
  assert.equal(time.textContent, `Alarm · Person · ${stampText(T0 - 120_000)}`);
  described.card.destroy();

  const nothing = cardWith({ events: [event(1, said('Rain on the lens', 'nothing', 'routine'), 'Motion')] });
  await settle();
  const dim = byClass(nothing.card.el, 'ai-cam-summary')[0];
  assert.deepEqual([dim.textContent, dim.dataset.concern], ['Nothing notable', 'nothing']);
  assert.equal(all(nothing.card.el, (node) => node.localName === 'time')[0].textContent, `Motion · ${stampText(T0 - 60_000)}`);
  nothing.card.destroy();

  const hostile = cardWith({ events: [event(1, said('<b onclick=alert(1)>hi</b>', 'other', 'unusual'))] });
  await settle();
  const words = byClass(hostile.card.el, 'ai-cam-summary')[0];
  assert.equal(words.textContent, '<b onclick=alert(1)>hi</b>');
  assert.ok(words.childNodes.every((node) => !node.tagName), 'the words stay words');
  assert.equal(words.getAttribute('style'), null);
  hostile.card.destroy();

  const none = cardWith({ events: [event(1, null, 'Motion')] });
  await settle();
  assert.match(none.card.el.textContent, /No description in the latest events/);
  assert.equal(byClass(none.card.el, 'ai-cam-summary').length, 0);
  none.card.destroy();

  const failed = cardWith({ events: new Error('The recordings are not available.') });
  await settle();
  assert.doesNotMatch(failed.card.el.textContent, /No description/, 'not known is not “none”');
  failed.card.destroy();

  // The marks: the page's danger and warning colours, from data-concern; routine has none, "Nothing notable" is dimmed.
  const css = readFileSync(new URL('../web/style.css', import.meta.url), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
  const rule = (selector) => [...css.matchAll(/([^{}]+)\{([^}]*)\}/g)]
    .filter(([, selectors]) => selectors.split(',').some((part) => part.trim().startsWith(selector))).map(([, , body]) => body).join(' ');
  assert.match(rule('.ai-cam-summary[data-concern="alarm"]'), /background: var\(--danger\)/);
  assert.match(rule('.ai-cam-summary[data-concern="unusual"]'), /background: var\(--warning\)/);
  assert.match(rule('.ai-cam-summary[data-concern="nothing"]'), /color: var\(--text-3\)/);
  assert.equal(rule('.ai-cam-summary[data-concern="routine"]'), '');
});

test('a new event on a camera that is on asks for its description again a little later', async () => {
  const hand = handTimers();
  const events = [];
  const on = (date) => camera({ aiDescriptions: true, status: { connection: 'online', lastEventDate: date } });
  const { card, asked } = cardWith({ events, timers: hand, at: on(null) });
  await settle();
  assert.equal(asked.length, 1);
  assert.match(card.el.textContent, /No description in the latest events/);
  card.update(on(null));
  assert.equal(hand.timers.length, 0, 'nothing new happened');
  card.update(on(new Date(T0).toISOString()));
  card.update(on(new Date(T0 + 2000).toISOString()));
  assert.equal(hand.timers.length, 1, 'one ask for a burst');
  assert.equal(hand.timers[0].ms, 30_000, 'after the describer had time for it');
  events.push({ id: 'n', cameraID: DOOR, kind: 'Person', start: T0, end: null, recorded: true, description: said('A man carries a ladder to the gate', 'person', 'unusual') });
  await fire(hand.timers[0]);
  assert.equal(asked.length, 2);
  assert.equal(byClass(card.el, 'ai-cam-summary')[0]?.textContent, 'A man carries a ladder to the gate');
  assert.equal(waiting(hand.timers).length, 0, 'described: nothing more to ask');
  card.destroy();

  // A camera that is off is not described: its events bring no asking again.
  const quiet = handTimers();
  const off = cardWith({ timers: quiet });
  await settle();
  off.card.update(camera({ status: { connection: 'online', lastEventDate: new Date(T0).toISOString() } }));
  assert.equal(quiet.timers.length, 0);
  off.card.destroy();
});

test('while the newest event has no description and is under two minutes old (the bridge’s clock), the card asks every 30 s', async () => {
  const hand = handTimers();
  const clock = { ms: T0 + 10_000 };
  const newest = { id: 'w', cameraID: DOOR, kind: 'Person', start: T0, end: null, recorded: true, description: null };
  const older = { id: 'o', cameraID: DOOR, kind: 'Motion', start: T0 - 600_000, end: null, recorded: true, description: said('A cat crosses the lawn', 'animal', 'routine') };
  const { card, asked } = cardWith({ events: [newest, older], timers: hand, clock, at: camera({ aiDescriptions: true }) });
  await settle();
  assert.equal(byClass(card.el, 'ai-cam-summary')[0]?.textContent, 'A cat crosses the lawn', 'the last one there is, meanwhile');
  for (const at of [40_000, 70_000, 100_000]) {
    assert.equal(waiting(hand.timers).length, 1, `${at - 30_000} ms after the event: asks again`);
    assert.equal(waiting(hand.timers)[0].ms, 30_000);
    clock.ms = T0 + at;
    await fire(waiting(hand.timers)[0]);
  }
  clock.ms = T0 + 130_000;
  await fire(waiting(hand.timers)[0]);
  assert.equal(asked.length, 5);
  assert.equal(waiting(hand.timers).length, 0, 'two minutes old: it stops');
  card.destroy();

  // Off, or no service: nothing to wait for.
  for (const [at, ai] of [[camera(), CLAUDE], [camera({ aiDescriptions: true }), OFF]]) {
    const idle = handTimers();
    const other = cardWith({ events: [newest], timers: idle, clock: { ms: T0 + 10_000 }, at, ai });
    await settle();
    assert.equal(idle.timers.length, 0);
    other.card.destroy();
  }
});

test('a first load that fails is tried once more 30 s later', async () => {
  const hand = handTimers();
  let fail = 2;
  const { card, asked } = cardWith({ timers: hand, events: () => (fail-- > 0 ? new Error('The bridge didn’t answer.') : []) });
  await settle();
  assert.equal(asked.length, 1);
  assert.equal(waiting(hand.timers).length, 1);
  assert.equal(hand.timers[0].ms, 30_000);
  await fire(hand.timers[0]);
  assert.equal(asked.length, 2);
  assert.equal(waiting(hand.timers).length, 0, 'once only');
  assert.doesNotMatch(card.el.textContent, /No description/);
  card.destroy();

  const later = handTimers();
  let first = true;
  const ok = cardWith({ timers: later, events: () => (first ? (first = false, new Error('down')) : []) });
  await settle();
  await fire(later.timers[0]);
  assert.match(ok.card.el.textContent, /No description in the latest events/, 'the retry answered');
  ok.card.destroy();
});

test('the card asks for the camera’s newest page of 200 events over the route’s longest range', async () => {
  const realFetch = globalThis.fetch;
  const urls = [];
  globalThis.fetch = async (url) => { urls.push(String(url)); return new Response(JSON.stringify({ from: 0, to: 0, serverTime: T0, more: false, events: [] }), { status: 200, headers: { 'Content-Type': 'application/json' } }); };
  try {
    const card = page.createAIDescriptionsCard(camera(), { save() {}, settings: async () => settingsWith(CLAUDE) });
    await settle();
    card.destroy();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(urls.length, 1);
  const url = new URL(urls[0], 'http://bridge');
  assert.equal(url.pathname, '/api/v1/nvr/events');
  assert.equal(url.searchParams.get('cameras'), DOOR);
  assert.equal(url.searchParams.get('limit'), '200');
  assert.equal(Number(url.searchParams.get('to')) - Number(url.searchParams.get('from')), 31 * 86_400_000);
});

test('the camera page follows the AI switch in place (the page is not built again)', async () => {
  const { store, putCamera } = await import('../web/js/store.js');
  const { CAMERA_DEFINITIONS, cameraConfiguration } = await import('../web-dev/lib/cameras.mjs');
  globalThis.Image = class { set src(value) { this.value = value; } get src() { return this.value; } };   // the preview's snapshots
  const start = { ...cameraConfiguration(CAMERA_DEFINITIONS[1]), vendorName: 'ONVIF', aiDescriptions: false,
    status: { connection: 'online', summary: 'Live', recentEvents: [], nvr: { state: 'off', detail: null, pause: null, notes: [] } } };
  store.cameras.set(start.id, start);
  const screen = page.renderCamera({ params: [start.id], navigate() {}, setTitle() {} });
  try {
    await settle();
    const card = byClass(screen.el, 'ai-cam-card')[0];
    assert.ok(card, 'the card is on the page');
    const cards = byClass(screen.el, 'card');
    const motion = cards.findIndex((node) => node.childNodes[0]?.textContent === 'Motion');
    assert.equal(cards[motion + 1], card, 'right after Motion');
    putCamera({ ...start, aiDescriptions: true });
    await settle();   // a rebuild would have drawn the right column again by now
    assert.equal(byClass(screen.el, 'ai-cam-card')[0], card, 'the same card');
    assert.equal(byClass(screen.el, 'card')[motion], cards[motion], 'and the same Motion card: nothing was built again');
    assert.equal(theSwitch(card).checked, true);

    // A flip is on its way: the camera's own news meanwhile (its status moved) does not put the switch back.
    const input = theSwitch(card);
    input.checked = false;
    input.dispatchEvent({ type: 'change', target: input });
    putCamera({ ...start, aiDescriptions: true, status: { ...start.status, summary: 'Still live' } });
    assert.equal(input.checked, false, 'not back on while the change waits');
  } finally {
    screen.destroy();
    store.cameras.clear();
    delete globalThis.Image;
  }
});

// Final review M3: the model's words are isolated from the text around them (a bidi control that got through still cannot reorder the row).
test('the model’s sentence is bidi-isolated wherever the page draws it', () => {
  const declarations = (file, selector) => {
    const css = readFileSync(new URL(`../web/${file}`, import.meta.url), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
    return [...css.matchAll(/([^{}]+)\{([^}]*)\}/g)]
      .filter(([, selectors]) => selectors.split(',').some((part) => part.trim() === selector)).map(([, , body]) => body).join(' ');
  };
  assert.match(declarations('monitor.css', '.mon-event-ai'), /unicode-bidi:\s*isolate/, 'the Monitor’s events list');
  assert.match(declarations('style.css', '.ai-cam-summary'), /unicode-bidi:\s*isolate/, 'the camera page’s AI card');
  assert.match(declarations('style.css', '.ai-try-summary'), /unicode-bidi:\s*isolate/, 'Try it in Settings');
});
