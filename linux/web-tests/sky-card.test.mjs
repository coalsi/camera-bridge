// The camera page's Sky Watcher card (screens/sky-card.js createSkyDetectorCard): the switch "Watch the sky", the questions it asks when it is
// turned on (which way the camera faces, where the box is, the lens layout), what the box refuses and why, the browser's location, the aim by
// lens and the stream, in the fake browser with fake requests. And the camera page: the card sits after the AI card, and it moves in place.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let page;
let ApiError;
before(async () => {
  browser = installFakeBrowser();
  ({ ApiError } = await import('../web/js/api.js'));
  page = await import('../web/js/screens/sky-card.js');
});
after(() => browser?.restore());

const SKY = '0A1B2C3D-0000-4000-8000-000000000004';
const PLACE = { latitude: 40, longitude: -100, heightMeters: 0 };
const WIDE = { width: 4256, height: 1888 };
const NORMAL = { width: 1920, height: 1080 };
const camera = (extra = {}, picture = WIDE) => ({ id: SKY, name: 'North Sky', status: { connection: 'online', mainStreamInfo: picture }, ...extra });
const configured = (overrides = {}) => ({ enabled: false, facing: 90, tilt: 30, groundPercent: 10, nightProfile: true, lensLayout: 'single', ...overrides });
const boxWith = (location) => ({ bridgeName: 'Bridge', sky: { location, flightFeedURL: null, aiDailyLimit: 50 } });
const refused = (message, field) => new ApiError(400, 'invalid', message, field);
const NEED_LOCATION = 'Set where the box is first.';
const NEED_FOLDER = 'Choose a recordings folder first: the sky log is kept with the recordings.';
const BATTERY = 'Battery cameras can’t watch the sky: it would keep them awake.';

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));
const field = (root, name) => all(root, (node) => node.dataset?.field === name)[0];
const button = (root, text) => all(root, (node) => node.localName === 'button' && node.textContent === text)[0];
const links = (root) => all(root, (node) => node.localName === 'a' && visible(node)).map((node) => [node.textContent, node.getAttribute('href')]);
const theSwitch = (root) => all(root, (node) => node.localName === 'input' && node.getAttribute('role') === 'switch')[0];
const alerts = (root) => all(root, (node) => node.getAttribute?.('role') === 'alert' && visible(node)).map((node) => node.textContent);
/** The text a person can read: what is not hidden. */
function shown(root) {
  const parts = [];
  const walk = (node) => {
    if (node.hidden) return;
    if (node.data !== undefined) parts.push(node.data);
    for (const child of node.childNodes ?? []) walk(child);
  };
  walk(root);
  return parts.join('');
}
const paragraphs = (root) => all(root, (node) => node.localName === 'p' && visible(node)).map((node) => node.textContent);
/** Time that moves only when the test says: { setTimeout, clearTimeout, advance(ms) }. */
function fakeTimers() {
  let now = 0;
  let next = 1;
  const due = new Map();
  return {
    setTimeout(fn, ms) { const id = next++; due.set(id, { at: now + ms, fn }); return id; },
    clearTimeout(id) { due.delete(id); },
    advance(ms) {
      now += ms;
      for (const [id, timer] of [...due].sort((a, b) => a[1].at - b[1].at)) if (timer.at <= now) { due.delete(id); timer.fn(); }
    },
  };
}
const settle = async () => { for (let i = 0; i < 6; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
const flip = (input, on) => { input.checked = on; input.dispatchEvent({ type: 'change', target: input }); };
const type = (input, value) => { input.value = value; input.dispatchEvent({ type: 'input', target: input }); input.dispatchEvent({ type: 'change', target: input }); };
const pressed = (root, attribute) => all(root, (node) => node.localName === 'button' && node.getAttribute('aria-pressed') === 'true' && node.dataset?.[attribute] !== undefined).map((node) => node.dataset[attribute]);

/**
 * The card with fake requests: `settings` answers `box` (an Error: it could not be read), `save` and `saveLocation` record what they were
 * sent and fail with the errors the test queued in `refusals`, one for each call.
 */
function cardWith({ at = camera(), box = boxWith(null), geolocate, refusals = [], placeRefusals = [], timers } = {}) {
  const calls = { saves: [], places: [] };
  const card = page.createSkyDetectorCard(at, {
    save: async (value) => { calls.saves.push(value); const error = refusals.shift(); if (error) throw error; },
    saveLocation: async (place) => { calls.places.push(place); const error = placeRefusals.shift(); if (error) throw error; },
    settings: async () => { if (box instanceof Error) throw box; return box; },
    geolocate,
    timers,
  });
  return { card, calls, refusals, placeRefusals };
}

// MARK: The words

test('the card is Sky Watcher: its switch, what it does, and what leaves the box', async () => {
  const { card } = cardWith();
  await settle();
  assert.equal(all(card.el, (node) => node.localName === 'h2')[0].textContent, 'Sky Watcher');
  const text = shown(card.el);
  assert.match(text, /Watch the sky/);
  assert.match(text, /For a camera that looks at the sky\. Camera Bridge logs everything that crosses it — planes, satellites, meteors, bugs and birds — and tells you only about what it can’t explain\. One camera can’t tell how far away something is, so it compares how things move across the sky; it never guesses a real size or speed\./);
  assert.match(text, /It works without the internet\. When the internet is there, Camera Bridge can also download satellite orbits once a day and ask free online services for flights and weather in a wide area around you, never your exact spot\. Still pictures of what it can’t explain go to your AI service if you set one up\. Nothing leaves the box while it’s off\./);
  assert.doesNotMatch(card.el.textContent, /Sky detector/i);
  assert.equal(theSwitch(card.el).checked, false);
  assert.equal(visible(byClass(card.el, 'sky-setup')[0]), false, 'the questions wait for the switch');
  assert.equal(visible(byClass(card.el, 'sky-status')[0]), false, 'and so does the status');
  assert.deepEqual(links(card.el), [], 'nothing to open: it has never been on');
  card.destroy();
});

// MARK: Turning it on

test('turning it on for the first time asks which way the camera faces, where the box is and the lens layout; nothing is saved until Start', async () => {
  const { card, calls } = cardWith();
  await settle();
  flip(theSwitch(card.el), true);
  await settle();
  assert.deepEqual(calls.saves, [], 'asking first');
  assert.equal(theSwitch(card.el).checked, true, 'the switch shows what was asked for');
  assert.ok(visible(byClass(card.el, 'sky-setup')[0]));
  const text = shown(card.el);
  for (const sentence of ['Which way the camera faces', 'Tilt above the horizon', 'Ground and horizon at the bottom', 'Where the box is', 'Kept only on this box.', 'Latitude', 'Longitude', 'Lens layout']) assert.match(text, new RegExp(sentence));
  assert.ok(button(card.el, 'Use this browser’s location'));
  assert.deepEqual(['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'].map((word) => Boolean(button(card.el, word))), Array(8).fill(true));
  assert.deepEqual(pressed(card.el, 'facing'), ['0'], 'north to start with');
  assert.deepEqual(pressed(card.el, 'layout'), ['dual'], 'a wide stitched picture is two lenses');
  assert.equal(field(card.el, 'tilt').value, '20');
  assert.equal(field(card.el, 'ground').value, '12');
  assert.equal(field(card.el, 'tilt').getAttribute('min'), '0');
  assert.equal(field(card.el, 'tilt').getAttribute('max'), '90');
  assert.equal(field(card.el, 'ground').getAttribute('max'), '60');
  assert.ok(visible(button(card.el, 'Start watching')));

  button(card.el, 'NE').click();
  assert.deepEqual(pressed(card.el, 'facing'), ['45']);
  type(field(card.el, 'latitude'), '40.5');
  type(field(card.el, 'longitude'), '-100.25');
  assert.deepEqual(calls.saves, [], 'still nothing sent');

  button(card.el, 'Start watching').click();
  await settle();
  assert.deepEqual(calls.places, [{ latitude: 40.5, longitude: -100.25 }], 'the place, once, for the whole bridge');
  assert.deepEqual(calls.saves, [{ enabled: true, facing: 45, tilt: 20, groundPercent: 12, nightProfile: true, lensLayout: 'dual' }], 'then everything the camera was asked');
  assert.equal(theSwitch(card.el).checked, true);

  // The camera as the bridge now has it: the questions stay as settings, the status appears.
  card.update(camera({ skyDetector: configured({ enabled: true, facing: 45, tilt: 20, groundPercent: 12, lensLayout: 'dual' }) }));
  assert.ok(visible(byClass(card.el, 'sky-status')[0]));
  assert.equal(visible(button(card.el, 'Start watching')), false, 'Start is for the first time only');
  assert.ok(visible(byClass(card.el, 'sky-setup')[0]), 'the answers stay on the card, to change');
  assert.deepEqual(links(card.el), [['Open the sky log', `#/sky/${SKY}`]]);
  card.destroy();
});

test('a picture that is not wide starts as one lens; flipping the switch back while it asks cancels', async () => {
  const { card, calls } = cardWith({ at: camera({}, NORMAL) });
  await settle();
  flip(theSwitch(card.el), true);
  assert.deepEqual(pressed(card.el, 'layout'), ['single']);
  button(card.el, 'Two lenses side by side').click();
  assert.deepEqual(pressed(card.el, 'layout'), ['dual'], 'the person decides');
  flip(theSwitch(card.el), false);
  assert.equal(theSwitch(card.el).checked, false);
  assert.equal(visible(byClass(card.el, 'sky-setup')[0]), false);
  assert.deepEqual(calls.saves, []);
  card.destroy();
});

test('the card needs a location and a folder, and says why', async () => {
  const { card, calls, refusals } = cardWith();
  await settle();
  flip(theSwitch(card.el), true);

  // No location on the box: its sentence is shown in place, the switch goes back to off, the questions stay.
  refusals.push(refused(NEED_LOCATION, 'sky.location'));
  button(card.el, 'Start watching').click();
  await settle();
  assert.equal(calls.saves.length, 1, 'the box is asked, and decides');
  assert.deepEqual(calls.places, [], 'there was no place to send');
  assert.deepEqual(alerts(card.el), [NEED_LOCATION]);
  assert.equal(theSwitch(card.el).checked, false, 'back to off');
  assert.ok(visible(byClass(card.el, 'sky-setup')[0]), 'and the questions are still there to answer');
  assert.ok(visible(button(card.el, 'Start watching')));

  // A place typed, but no folder for recordings: its sentence, with the way to Settings.
  type(field(card.el, 'latitude'), '40');
  type(field(card.el, 'longitude'), '-100');
  refusals.push(refused(NEED_FOLDER, 'nvrFolder'));
  button(card.el, 'Start watching').click();
  await settle();
  assert.deepEqual(alerts(card.el), [NEED_FOLDER]);
  assert.deepEqual(links(card.el), [['Settings › Recording', '#/settings/recording']]);
  assert.equal(theSwitch(card.el).checked, false);
  assert.deepEqual(calls.places, [{ latitude: 40, longitude: -100 }], 'the place went to the box once');

  // A camera that runs on a battery.
  refusals.push(refused(BATTERY));
  button(card.el, 'Start watching').click();
  await settle();
  assert.deepEqual(alerts(card.el), [BATTERY]);
  assert.deepEqual(links(card.el), [], 'no way to Settings for that one');
  assert.equal(calls.places.length, 1, 'the same place is not sent again');

  // Flipping the switch again tries again with the same answers; this time it works, and the sentence goes.
  flip(theSwitch(card.el), true);
  await settle();
  assert.deepEqual(alerts(card.el), []);
  assert.equal(theSwitch(card.el).checked, true);
  assert.equal(calls.saves.length, 4);
  assert.equal(calls.saves.at(-1).enabled, true);
  card.destroy();
});

test('a place the box could not keep, or that is not a place, is said in place and nothing is turned on', async () => {
  const { card, calls, placeRefusals } = cardWith();
  await settle();
  flip(theSwitch(card.el), true);
  type(field(card.el, 'latitude'), '91');
  type(field(card.el, 'longitude'), '-100');
  button(card.el, 'Start watching').click();
  await settle();
  assert.match(shown(card.el), /Latitude is a number from −90 to 90\./);
  assert.deepEqual([calls.places, calls.saves], [[], []], 'nothing sent for a latitude that is not one');
  assert.equal(theSwitch(card.el).checked, false, 'it is not on');
  type(field(card.el, 'latitude'), '40');
  type(field(card.el, 'longitude'), 'west');
  button(card.el, 'Start watching').click();
  await settle();
  assert.match(shown(card.el), /Longitude is a number from −180 to 180\./);
  assert.doesNotMatch(shown(card.el), /Latitude is a number/, 'the one that is right says nothing');

  type(field(card.el, 'longitude'), '-100');
  placeRefusals.push(refused('That place isn’t on the map.', 'sky.location'));
  button(card.el, 'Start watching').click();
  await settle();
  assert.deepEqual(alerts(card.el), ['That place isn’t on the map.']);
  assert.deepEqual(calls.saves, [], 'the camera is not asked while the place is refused');
  card.destroy();
});

test('Use this browser’s location fills the fields; refusal says type it in', async () => {
  const asked = [];
  const grant = { getCurrentPosition(ok) { asked.push('asked'); ok({ coords: { latitude: 40.12345678, longitude: -100.98765432 } }); } };
  const { card, calls } = cardWith({ geolocate: grant });
  await settle();
  flip(theSwitch(card.el), true);
  button(card.el, 'Use this browser’s location').click();
  await settle();
  assert.deepEqual(asked, ['asked']);
  assert.equal(field(card.el, 'latitude').value, '40.1235');
  assert.equal(field(card.el, 'longitude').value, '-100.9877');
  assert.deepEqual(alerts(card.el), []);
  assert.deepEqual(calls.places, [], 'filling the fields sends nothing: Start does');
  card.destroy();

  const deny = { getCurrentPosition(ok, fail) { fail({ code: 1, message: 'User denied Geolocation' }); } };
  const denied = cardWith({ geolocate: deny });
  await settle();
  flip(theSwitch(denied.card.el), true);
  type(field(denied.card.el, 'latitude'), '12');
  button(denied.card.el, 'Use this browser’s location').click();
  await settle();
  assert.match(shown(denied.card.el), /Your browser didn’t share its location\. Type it in instead: latitude and longitude, with a minus sign for west\./);
  assert.equal(field(denied.card.el, 'latitude').value, '12', 'what was typed stays');
  assert.equal(field(denied.card.el, 'longitude').value, '');
  denied.card.destroy();

  // A browser with no location to give (the box is served over plain HTTP, where most browsers give none).
  const none = cardWith({ geolocate: undefined });
  await settle();
  flip(theSwitch(none.card.el), true);
  button(none.card.el, 'Use this browser’s location').click();
  await settle();
  assert.match(shown(none.card.el), /Your browser didn’t share its location\. Type it in instead: latitude and longitude, with a minus sign for west\./);
  none.card.destroy();
});

test('a browser that never answers is said to have refused after 10 seconds; one that answers late still fills the fields', async () => {
  const timers = fakeTimers();
  let answer = null;
  const late = { getCurrentPosition(ok) { answer = ok; } };
  const { card } = cardWith({ geolocate: late, timers });
  await settle();
  flip(theSwitch(card.el), true);
  button(card.el, 'Use this browser’s location').click();
  await settle();
  assert.match(shown(card.el), /Asking this browser…/);
  timers.advance(10_000);
  const sentence = 'Your browser didn’t share its location. Type it in instead: latitude and longitude, with a minus sign for west.';
  assert.ok(shown(card.el).includes(sentence), 'said next to the fields after 10 s');
  assert.doesNotMatch(shown(card.el), /Asking this browser…/);
  // The person allowed it in the end: the fields are filled and the sentence goes.
  answer({ coords: { latitude: 41.5, longitude: -87.25 } });
  assert.equal(field(card.el, 'latitude').value, '41.5');
  assert.equal(field(card.el, 'longitude').value, '-87.25');
  assert.ok(!shown(card.el).includes(sentence));
  card.destroy();

  // An answer in time stops the clock: no sentence after it.
  const quick = fakeTimers();
  const grant = { getCurrentPosition(ok) { ok({ coords: { latitude: 40, longitude: -100 } }); } };
  const granted = cardWith({ geolocate: grant, timers: quick });
  await settle();
  flip(theSwitch(granted.card.el), true);
  button(granted.card.el, 'Use this browser’s location').click();
  quick.advance(20_000);
  assert.ok(!shown(granted.card.el).includes(sentence));
  granted.card.destroy();
});

test('a camera set up before turns on at once with what it had, and the place the box already has is in the fields', async () => {
  const at = camera({ skyDetector: configured({ facing: 90, tilt: 30, groundPercent: 10, nightProfile: false }) });
  const { card, calls } = cardWith({ at, box: boxWith(PLACE) });
  await settle();
  assert.equal(field(card.el, 'latitude').value, '40');
  assert.equal(field(card.el, 'longitude').value, '-100');
  flip(theSwitch(card.el), true);
  await settle();
  assert.deepEqual(calls.saves, [{ enabled: true, facing: 90, tilt: 30, groundPercent: 10, nightProfile: false, lensLayout: 'single' }]);
  assert.deepEqual(calls.places, [], 'the place is the box’s already');
  assert.deepEqual(links(card.el), [['Open the sky log', `#/sky/${SKY}`]], 'it has been on: its log can be opened even while it is off');
  card.destroy();

  // The same camera on a box that has lost its place asks again.
  const lost = cardWith({ at, box: boxWith(null) });
  await settle();
  flip(theSwitch(lost.card.el), true);
  await settle();
  assert.deepEqual(lost.calls.saves, []);
  assert.ok(visible(button(lost.card.el, 'Start watching')));
  lost.card.destroy();
});

test('turning it off saves it off with the same answers', async () => {
  const on = camera({ skyDetector: configured({ enabled: true, facing: 315, tilt: 25, groundPercent: 15, lensLayout: 'dual' }) });
  const { card, calls } = cardWith({ at: on, box: boxWith(PLACE) });
  await settle();
  assert.equal(theSwitch(card.el).checked, true);
  flip(theSwitch(card.el), false);
  await settle();
  assert.deepEqual(calls.saves, [{ enabled: false, facing: 315, tilt: 25, groundPercent: 15, nightProfile: true, lensLayout: 'dual' }]);
  assert.equal(theSwitch(card.el).checked, false);
  card.update(camera({ skyDetector: configured({ enabled: false, facing: 315, tilt: 25, groundPercent: 15, lensLayout: 'dual' }) }));
  assert.equal(visible(byClass(card.el, 'sky-status')[0]), false);
  assert.equal(theSwitch(card.el).checked, false);
  card.destroy();
});

// MARK: Changing it while it is on

test('a change while it is on saves everything, once the box answered the one before; a refusal puts the field back', async () => {
  const on = camera({ skyDetector: configured({ enabled: true, facing: 0, tilt: 20, groundPercent: 12, lensLayout: 'dual' }) });
  const { card, calls, refusals } = cardWith({ at: on, box: boxWith(PLACE) });
  await settle();
  type(field(card.el, 'tilt'), '35');
  await settle();
  assert.deepEqual(calls.saves.at(-1), { enabled: true, facing: 0, tilt: 35, groundPercent: 12, nightProfile: true, lensLayout: 'dual' });
  button(card.el, 'W').click();
  await settle();
  assert.deepEqual(calls.saves.at(-1), { enabled: true, facing: 270, tilt: 35, groundPercent: 12, nightProfile: true, lensLayout: 'dual' });
  button(card.el, 'One lens').click();
  await settle();
  assert.equal(calls.saves.at(-1).lensLayout, 'single');
  type(field(card.el, 'ground'), '95');
  await settle();
  assert.equal(calls.saves.at(-1).groundPercent, 60, 'ground and horizon: at most 60 %');
  assert.equal(field(card.el, 'ground').value, '60');
  type(field(card.el, 'tilt'), '-5');
  await settle();
  assert.equal(calls.saves.at(-1).tilt, 0);

  // The bridge as it is after those saves; then a refused one.
  card.update(camera({ skyDetector: configured({ enabled: true, facing: 270, tilt: 0, groundPercent: 60, lensLayout: 'single' }) }));
  refusals.push(refused('Tilt can’t be more than 90°.', 'skyDetector.tilt'));
  type(field(card.el, 'tilt'), '80');
  await settle();
  assert.deepEqual(alerts(card.el), ['Tilt can’t be more than 90°.']);
  assert.equal(field(card.el, 'tilt').value, '0', 'back to what the box has');
  assert.equal(theSwitch(card.el).checked, true, 'still on: it was a change, not a start');
  card.destroy();
});

test('the place can be changed while it is on, and a place that is not one is not sent', async () => {
  const on = camera({ skyDetector: configured({ enabled: true }) });
  const { card, calls } = cardWith({ at: on, box: boxWith(PLACE) });
  await settle();
  type(field(card.el, 'latitude'), '41.25');
  await settle();
  assert.deepEqual(calls.places, [{ latitude: 41.25, longitude: -100 }]);
  type(field(card.el, 'longitude'), '');
  await settle();
  assert.equal(calls.places.length, 1, 'an empty longitude is not a place to send');
  assert.deepEqual(calls.saves, [], 'and the camera is not touched by it');
  card.destroy();
});

// MARK: The aim and the stream

test('the card shows the aim and the stream', async () => {
  const sky = {
    running: true, stream: 'main', analysisWidth: 1920, picturesPerSecond: 5, problem: null, profile: null,
    aim: { quality: 'good', planes: 23, stars: 0, residualPixels: 14, updated: 1760099000000, lenses: [], note: null },
    learning: { ready: true, planes: 31, satellites: 12 },
  };
  const at = camera({ skyDetector: configured({ enabled: true, lensLayout: 'single' }), status: { connection: 'online', sky } });
  const { card } = cardWith({ at, box: boxWith(PLACE) });
  await settle();
  let lines = paragraphs(card.el);
  assert.ok(lines.includes('Aim: good, 23 planes matched, 14 px'));
  assert.ok(lines.includes('It gets more exact by itself over a few nights.'));
  assert.ok(lines.includes('Watching the main stream at 1920 px, 5 pictures a second'));
  assert.ok(!lines.includes('Flight matching is loose until the aim is good.'), 'not while the aim is good');
  assert.ok(!lines.some((line) => /Still learning/.test(line)));

  // Rough: flight matching is loose; the box is still learning; the camera seems to have moved.
  const rough = { ...sky, aim: { quality: 'rough', planes: 0, stars: 0, residualPixels: null, updated: null, lenses: [], note: 'The camera seems to have moved; aiming again.' }, learning: { ready: false, planes: 12, satellites: 0 } };
  card.update({ ...at, status: { connection: 'online', sky: rough } });
  lines = paragraphs(card.el);
  assert.ok(lines.includes('Aim: rough'));
  assert.ok(lines.includes('Flight matching is loose until the aim is good.'));
  assert.ok(lines.includes('Still learning this sky: 12 of 30 planes matched. No alerts until then.'));
  assert.ok(lines.includes('The camera seems to have moved; aiming again.'));
  assert.ok(!lines.includes('Aim: good, 23 planes matched, 14 px'), 'replaced, not added to');
  card.destroy();
});

test('two lenses are two lines: each lens’s own aim', async () => {
  const sky = {
    running: true, stream: 'sub', analysisWidth: 1280, picturesPerSecond: 5, problem: null,
    aim: {
      quality: 'good', planes: 40, stars: 214, residualPixels: 5, updated: 1, note: null,
      lenses: [{ quality: 'precise', planes: 30, stars: 214, residualPixels: 1.8 }, { quality: 'good', planes: 23, stars: 0, residualPixels: 14 }],
    },
    learning: { ready: true, planes: 40, satellites: 12 },
  };
  const at = camera({ skyDetector: configured({ enabled: true, lensLayout: 'dual' }), status: { connection: 'online', sky } });
  const { card } = cardWith({ at, box: boxWith(PLACE) });
  await settle();
  const lines = paragraphs(card.el);
  assert.ok(lines.includes('Left lens: precise, 214 stars matched, 1.8 px'));
  assert.ok(lines.includes('Right lens: good, 23 planes matched, 14 px'));
  assert.ok(!lines.some((line) => line.startsWith('Aim:')), 'not the overall line as well');
  assert.ok(lines.includes('Watching the sub stream at 1280 px, 5 pictures a second'));

  // Before any fit the box reports no lenses: a dual camera still says both are rough.
  card.update({ ...at, status: { connection: 'online', sky: { ...sky, aim: { quality: 'rough', planes: 0, stars: 0, residualPixels: null, updated: null, lenses: [] } } } });
  const before = paragraphs(card.el);
  assert.ok(before.includes('Left lens: rough') && before.includes('Right lens: rough'));
  card.destroy();
});

test('the detector’s own trouble and a start that has not reported yet', async () => {
  const at = camera({ skyDetector: configured({ enabled: true }), status: { connection: 'online' } });
  const { card } = cardWith({ at, box: boxWith(PLACE) });
  await settle();
  assert.ok(visible(byClass(card.el, 'sky-status')[0]));
  assert.ok(paragraphs(card.el).includes('Starting…'), 'on, but nothing reported yet');
  assert.ok(!paragraphs(card.el).some((line) => line.startsWith('Aim')), 'no aim is claimed before the box says one');
  card.update({ ...at, status: { connection: 'online', sky: { running: false, stream: null, analysisWidth: null, picturesPerSecond: null, problem: 'The camera’s stream stopped.', aim: { quality: 'rough', planes: 0, stars: 0, residualPixels: null, lenses: [] }, learning: { ready: false, planes: 0, satellites: 0 } } } });
  assert.ok(paragraphs(card.el).includes('Not watching right now'));
  assert.deepEqual(alerts(card.el), [], 'trouble the box reports is not a refusal');
  assert.match(shown(card.el), /The camera’s stream stopped\./);
  card.destroy();
});

// MARK: In place

test('the card follows the camera in place: nothing is built again, and what is being typed stays', async () => {
  const on = camera({ skyDetector: configured({ enabled: true, tilt: 20 }), status: { connection: 'online', sky: { running: true, stream: 'main', analysisWidth: 1920, picturesPerSecond: 5, aim: { quality: 'rough', planes: 0, stars: 0, residualPixels: null, lenses: [] }, learning: { ready: false, planes: 1, satellites: 0 } } } });
  const { card, calls } = cardWith({ at: on, box: boxWith(PLACE) });
  await settle();
  const tilt = field(card.el, 'tilt');
  const north = button(card.el, 'N');
  tilt.value = '44';                                              // typed, not yet let go
  tilt.dispatchEvent({ type: 'input', target: tilt });
  card.update({ ...on, status: { ...on.status, sky: { ...on.status.sky, picturesPerSecond: 4 } } });
  assert.equal(field(card.el, 'tilt'), tilt, 'the same field');
  assert.equal(tilt.value, '44', 'what is being typed stays');
  assert.equal(button(card.el, 'N'), north);
  assert.ok(paragraphs(card.el).includes('Watching the main stream at 1920 px, 4 pictures a second'), 'the status moves');
  assert.deepEqual(calls.saves, [], 'and news from the camera saves nothing');

  // Another browser changed the camera while nothing is being typed: the card follows.
  tilt.dispatchEvent({ type: 'change', target: tilt });
  await settle();
  card.update({ ...on, skyDetector: configured({ enabled: true, facing: 180, tilt: 44 }) });
  assert.deepEqual(pressed(card.el, 'facing'), ['180']);
  card.update({ ...on, skyDetector: configured({ enabled: true, facing: 90, tilt: 50 }) });
  assert.equal(tilt.value, '50');
  assert.deepEqual(pressed(card.el, 'facing'), ['90']);
  card.destroy();
});

test('a switch flipped while the box is answering does not jump back', async () => {
  const at = camera({ skyDetector: configured(), status: { connection: 'online', mainStreamInfo: WIDE } });
  let release;
  const card = page.createSkyDetectorCard(at, {
    save: () => new Promise((resolve) => { release = resolve; }),
    saveLocation: async () => {},
    settings: async () => boxWith(PLACE),
  });
  await settle();
  flip(theSwitch(card.el), true);
  await settle();
  card.update(camera({ skyDetector: configured({ enabled: false }) }));   // news from before the change
  assert.equal(theSwitch(card.el).checked, true, 'held until the box answers');
  release();
  await settle();
  card.update(camera({ skyDetector: configured({ enabled: true }) }));
  assert.equal(theSwitch(card.el).checked, true);
  card.destroy();
});

test('a card that is gone ignores a late answer', async () => {
  let answer;
  const late = { getCurrentPosition(ok) { answer = ok; } };
  const { card } = cardWith({ geolocate: late });
  await settle();
  flip(theSwitch(card.el), true);
  button(card.el, 'Use this browser’s location').click();
  card.destroy();
  assert.doesNotThrow(() => answer({ coords: { latitude: 1, longitude: 2 } }));
  assert.equal(field(card.el, 'latitude').value, '', 'nothing written after it was gone');
});

// MARK: The camera page

test('the camera page puts the card after the AI descriptions card and routes its changes to the card', () => {
  const source = readFileSync(new URL('../web/js/screens/camera.js', import.meta.url), 'utf8');
  assert.match(source, /import \{[^}]*createSkyDetectorCard[^}]*\} from '\.\/sky-card\.js'/);
  assert.match(source, /aiHandle\.el, skyOn \? skyHandle\.el : null/, 'the card is in the right column right after the AI card, while the plugin is on');
  assert.match(source, /const skyOn = pluginOn\('sky'\)/, 'and only then: Sky Watcher is a plugin');
  assert.match(source, /skyHandle\?\.update\(detail\)/, 'it follows the camera’s news in place');
  assert.match(source, /skyHandle\?\.destroy\(\)/);
  assert.match(source, /skyDetector: null/, 'the page’s structure ignores the sky settings, so turning the switch never builds it again');
});
