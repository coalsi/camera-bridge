// The Sky Watcher page (screens/sky-log.js and sky-grid.js): the sky log as a grid you scroll through. The summary and the conditions, the dock
// (the night's strip and the filters), the cards under the hours they began in, made as the person scrolls (a fake IntersectionObserver), the
// kind chips with their counts, With picture and the orders, the filters in the address and in this browser's memory, a card opening the clip
// player with the light's details and its correction, which changes the card and the counts at once and moves a card the filters no longer
// show out of the grid (a fade, the page keeping its place, the player staying on its light); past nights and days, a camera picker, the
// plugin and the Setup panel. In the fake browser with fake requests.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, test } from 'node:test';
import { FakeElement, installFakeBrowser, makeStorage } from './support/fake-browser.mjs';

let browser;
let mod;
let setupMod;
let store;
let setPlugins;
let ApiError;
let closeUpRect;
let thumbRect;
before(async () => {
  browser = installFakeBrowser();
  ({ ApiError } = await import('../web/js/api.js'));
  mod = await import('../web/js/screens/sky-log.js');
  ({ closeUpRect, thumbRect } = await import('../web/js/screens/sky-model.js'));
  setupMod = await import('../web/js/screens/sky-setup.js');
  ({ store, setPlugins } = await import('../web/js/store.js'));
});
after(() => browser?.restore());

const SKY = '0A1B2C3D-0000-4000-8000-000000000004';
const OTHER = '0A1B2C3D-0000-4000-8000-000000000002';
const CHICAGO = 'America/Chicago';
/** 25 October 2026, `hour:minute` in Chicago (still on daylight time), as epoch ms. */
const chicago = (hour, minute = 0, day = 25) => Date.UTC(2026, 9, day, hour + 5, minute);
const FROM = chicago(18, 32, 24);
const TO = chicago(7, 21);
const NOW = chicago(8, 10);
const WATCHING = { enabled: true, facing: 0, tilt: 20, groundPercent: 12, nightProfile: true, lensLayout: 'dual' };
const SKY_STATUS = {
  running: true, stream: 'main', analysisWidth: 1920, picturesPerSecond: 5, problem: null,
  aim: { quality: 'good', planes: 40, stars: 0, residualPixels: 5, lenses: [{ quality: 'good', planes: 23, stars: 0, residualPixels: 14 }, { quality: 'precise', planes: 30, stars: 214, residualPixels: 1.8 }] },
  learning: { ready: true, planes: 40, satellites: 12 },
};
const cameraOf = (id, name, extra = {}) => ({ id, name, skyDetector: WATCHING, status: { connection: 'online', sky: SKY_STATUS }, ...extra });
const northSky = (extra) => cameraOf(SKY, 'North Sky', extra);

/** An entry as the bridge sends it (Task 5: the entry, plus `display` and `watch`). */
const raw = (id, label, start, extra = {}) => ({
  id, camera: SKY, kind: 'track', start, end: start + 4200, label, display: label, by: null, detail: null,
  path: [{ t: 0, x: 0.1, y: 0.2 }, { t: 4.2, x: 0.3, y: 0.25 }],
  measures: { azimuth: 312, elevation: 8, azimuthEnd: 330, elevationEnd: 14, duration: 4.2, speed: 3, acceleration: 0, turnRate: 0.1, maxTurn: 5, straightness: 0.99, shape: 'straight', sizeDegrees: 0.1, brightness: 100, blinks: false, blinkRate: null, focus: 1 },
  unusual: [], speedVsPlanes: null, candidate: false, alerted: false, hasStill: false, ai: null, correction: null, watch: start - 3000, ...extra,
});
const UNEXPLAINED = () => raw('u1', 'unexplained', chicago(3, 12) + 8000, {
  hasStill: true, unusual: ['faster', 'larger'], speedVsPlanes: 6.1, ai: { kind: 'drone', sentence: 'A bright light moving fast, probably a drone.', model: 'm', at: chicago(3, 13) },
  measures: { azimuth: 312, elevation: 8, azimuthEnd: 330, elevationEnd: 14, duration: 4.2, speed: 3, shape: 'curved', blinks: true, blinkRate: 1, sizeDegrees: 0.3, brightness: 900 },
});
const COUNTS = { unexplained: 1, planes: 3, satellites: 5, meteors: 1, bugsAndBirds: 2, notSure: 0, explained: 11 };
const NONE = { unexplained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 0 };
function entriesOfANight() {
  return [
    raw('p1', 'plane', chicago(20, 5, 24), { by: 'flight', detail: 'TEST123 · 35,000 ft' }),
    raw('p2', 'probablePlane', chicago(21, 40, 24), { by: 'flight', detail: 'ABC789 · 12,000 ft' }),
    raw('p3', 'plane', chicago(23, 55, 24), { by: 'flight', detail: 'N12345 · 41,000 ft' }),
    ...Array.from({ length: 5 }, (_, i) => raw(`s${i}`, 'satellite', chicago(19, 10 + i * 7, 24), { by: 'orbit', detail: i === 0 ? 'ISS (ZARYA)' : `STARLINK-${1000 + i}` })),
    raw('m1', 'meteor', chicago(1, 30), { by: 'rule', measures: { azimuth: 200, elevation: 40, azimuthEnd: 210, elevationEnd: 25, duration: 0.6, shape: 'straight' } }),
    raw('b1', 'bird', chicago(22, 10, 24), { by: 'rule' }),
    raw('g1', 'bug', chicago(22, 12, 24), { by: 'rule' }),
    UNEXPLAINED(),
  ];
}
const CONDITIONS = [
  { from: FROM, to: chicago(3), state: 'clear', cloudCover: 10 },
  { from: chicago(3), to: chicago(5), state: 'notVisible', cloudCover: 95 },
  { from: chicago(5), to: TO, state: 'clear', cloudCover: 20 },
];
const night = (extra = {}) => ({
  camera: SKY, night: '2026-10-24', view: 'night', from: FROM, to: TO, serverTime: NOW, entries: entriesOfANight(), conditions: CONDITIONS, counts: { ...COUNTS },
  aim: SKY_STATUS.aim, learning: SKY_STATUS.learning, ...extra,
});
/** A night of `n` lights of every kind spread over its hours, a still for two in three. */
function busyNight(n, extra = {}) {
  const labels = ['unexplained', 'plane', 'satellite', 'satellite', 'probablePlane', 'bird', 'bug', 'meteor', 'satelliteFlare', 'unexplained'];
  const span = TO - FROM - 60_000;
  const entries = Array.from({ length: n }, (_, i) => raw(`e${String(i).padStart(4, '0')}`, labels[i % labels.length], FROM + Math.floor((i * span) / n), {
    hasStill: i % 3 !== 0, detail: labels[i % labels.length] === 'plane' ? `AAL${i} · 30,000 ft` : null, measures: { azimuth: (i * 37) % 360, elevation: 10 + (i % 60), duration: 1 + (i % 50), speed: i % 7 === 0 ? undefined : (i % 13) + 0.5, shape: 'straight', blinks: i % 4 === 0 },
  }));
  return night({ entries, counts: undefined, ...extra });
}

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name));
const tag = (root, name) => all(root, (node) => node.localName === name);
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const button = (root, text) => all(root, (node) => node.localName === 'button' && node.textContent === text)[0];
const link = (root, text) => all(root, (node) => node.localName === 'a' && node.textContent === text)[0];
/** The text a person can read: what is not hidden (and, inside a closed details, only its summary). */
function shown(root) {
  const parts = [];
  const walk = (node, closed) => {
    if (node.hidden) return;
    if (node.data !== undefined) { if (!closed) parts.push(node.data); return; }
    const hides = closed || (node.localName === 'details' && !node.open);
    for (const child of node.childNodes ?? []) walk(child, hides && child.localName !== 'summary');
  };
  walk(root, false);
  return parts.join(' ');
}
const settle = async () => { for (let i = 0; i < 8; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
const tiles = (root) => byClass(root, 'sky-tile');
const tileOf = (root, id) => tiles(root).find((card) => card.dataset.entry === id);
const hours = (root) => byClass(root, 'sky-hour-head').map((head) => shown(head).replace(/\s+/g, ' ').trim());
/** A chip of the filters: [its words, its count, pressed]. */
const chip = (root, kind) => all(root, (node) => node.classList?.contains('sky-filter') && node.dataset.kind === kind)[0];
const chipText = (root) => byClass(root, 'sky-filter').filter(visible).map((node) => `${shown(node).replace(/\s+/g, ' ').trim()}${node.getAttribute('aria-pressed') === 'true' ? ' *' : ''}`);
const sortMenu = (root) => byClass(root, 'sky-sort-select')[0];
const picturesBox = (root) => all(byClass(root, 'sky-pictures')[0], (node) => node.localName === 'input')[0];
const pick = async (select, value) => { select.value = value; select.dispatchEvent({ type: 'change', target: select }); await settle(); };
const tick = async (box, on) => { box.checked = on; box.dispatchEvent({ type: 'change', target: box }); await settle(); };

/**
 * The grid's two IntersectionObservers, driven by hand: the near one (its blocks of cards not made yet: `scroll()` brings the next one near the
 * screen, `near(el)` a given one) and the far one (the first and last cards of each made batch: `far(cards)` says they are far from it).
 */
function fakeObserver() {
  const state = { made: 0, all: [] };
  state.create = (callback, options) => {
    const one = { callback, options, targets: new Set() };
    state.all.push(one);
    state.made += 1;
    return { observe: (el) => one.targets.add(el), unobserve: (el) => one.targets.delete(el), disconnect: () => one.targets.clear() };
  };
  const near = () => state.all.find((one) => one.options?.rootMargin === '1600px 0px');
  const far = () => state.all.find((one) => one.options?.rootMargin === '5000px 0px');
  Object.defineProperty(state, 'targets', { get: () => near()?.targets ?? new Set() });
  Object.defineProperty(state, 'options', { get: () => near()?.options });
  Object.defineProperty(state, 'ends', { get: () => far()?.targets ?? new Set() });
  state.scroll = () => {
    const next = [...state.targets][0];
    if (next) near().callback([{ target: next, isIntersecting: true }]);
    return Boolean(next);
  };
  state.near = (el) => near().callback([{ target: el, isIntersecting: true }]);
  state.away = (el) => near().callback([{ target: el, isIntersecting: false }]);
  state.far = (els, isIntersecting = false) => far().callback(els.map((target) => ({ target, isIntersecting })));
  return state;
}

/** This browser's memory of the filters, in a box the test can read. */
function memory(value = null) {
  const box = { value, writes: 0 };
  return { box, read: () => box.value, write: (next) => { box.value = JSON.parse(JSON.stringify(next)); box.writes += 1; } };
}

/**
 * The page with fake requests; `log` is the night (or a function of the request, which may return an Error), `cameras` the cameras' list,
 * `plugin` whether the Sky Watcher plugin is on (it is, unless a test says it is not), `setup` makes the Setup panel (none: the tests of the log
 * leave the box's settings out), `observer` the fake IntersectionObserver (null: every card at once), `remember` this browser's memory,
 * `scrolled(dy)` what the window does when the page scrolls it. A leaving card's fade waits in `fades` until `endFades()`; the page's
 * scrolling of the window is in `calls.scrolls`.
 */
function pageWith({ log = night(), cameras = [northSky()], query = '', cameraID = SKY, correct, zone = CHICAGO, plugin = true, setup = () => null,
  openPlayer = async () => ({ close() {} }), observer = fakeObserver(), remember = memory(), now = () => NOW, scrolled = () => {} } = {}) {
  const calls = { loads: [], corrections: [], addresses: [], notes: [], scrolls: [] };
  const fades = [];
  const listeners = new Set();
  const page = mod.createSkyLogPage({
    cameraID, query,
    load: async (request) => {
      calls.loads.push(request);
      const answer = typeof log === 'function' ? log(request) : log;
      if (answer instanceof Error) throw answer;
      return answer;
    },
    correct: correct ?? (async (request) => {
      calls.corrections.push(request);
      const found = (typeof log === 'function' ? log({}) : log).entries.find((entry) => entry.id === request.entryID);
      const own = { plane: 'plane', bird: 'bird', bug: 'bug', satellite: 'satellite', meteor: 'meteor', notSure: found.label }[request.label];
      return { ...found, correction: request.label, display: own };
    }),
    now,
    writeAddress: (address) => calls.addresses.push(address),
    cameras: () => cameras,
    onCameras: (fn) => { listeners.add(fn); return () => listeners.delete(fn); },
    zone: () => zone,
    plugin: () => plugin,
    setup,
    openPlayer,
    createObserver: observer ? observer.create : null,
    frame: () => 0,
    wait: (fn, ms) => fades.push({ fn, ms }),
    scrollBy: (dy) => { calls.scrolls.push(dy); scrolled(dy); },
    remember,
    notify: (text) => calls.notes.push(text),
  });
  return { page, calls, listeners, el: page.el, observer, remember, fades, endFades: () => { for (const { fn } of fades.splice(0)) fn(); } };
}

/** A player that remembers what it was opened with and what its title was set to, and closes as the real one does (its onClose). */
function playerSpy() {
  const opened = [];
  const state = { opened, closed: 0, whats: [] };
  state.open = async (options) => {
    opened.push(options);
    return { close: () => { state.closed += 1; options.onClose?.(); }, setWhat: (text) => state.whats.push(text) };
  };
  return state;
}

// MARK: The grid

test('the log is a grid of cards under the hours of the night, with the summary, the strip and the filters over it', async () => {
  const { page, el, calls } = pageWith();
  await settle();
  assert.deepEqual(calls.loads, [{ cameraID: SKY, night: null, view: 'night' }], 'the latest night, asked for once');
  assert.equal(tag(el, 'h1')[0].textContent, 'Sky Watcher');
  const text = shown(el);
  assert.match(text, /Sky log · North Sky/);
  assert.match(text, /Last night: 1 unexplained, 11 explained/);
  assert.match(text, /☁︎ clear until 3 AM; sky not visible 3–5 AM; clear 5–7:21 AM/);

  // In order: the summary, then the dock (the strip and the filters, which stays at the top while the grid scrolls), then the grid.
  const order = ['sky-summary', 'sky-dock', 'sky-strip', 'sky-filters', 'sky-results'].map((name) => byClass(el, name)[0]);
  assert.ok(order.every(Boolean));
  const flat = all(el, () => true);
  assert.deepEqual(order.map((node) => flat.indexOf(node)), [...order.map((node) => flat.indexOf(node))].sort((a, b) => a - b), 'in that order');
  assert.ok(byClass(el, 'sky-dock')[0].contains(byClass(el, 'sky-strip')[0]) && byClass(el, 'sky-dock')[0].contains(byClass(el, 'sky-filters')[0]));

  // The counts are the chips: All and each kind with its number, and the person's corrections.
  assert.deepEqual(chipText(el), ['All 12 *', 'Unexplained 1', 'High priority 0', 'Planes 3', 'Satellites 5', 'Meteors 1', 'Bugs & birds 2', 'Corrected by you 0']);

  // A finished night reads from dusk: the hours in order, each with its lights.
  assert.deepEqual(hours(el), ['7 PM 5 lights', '8 PM 1 light', '9 PM 1 light', '10 PM 2 lights', '11 PM 1 light', '1 AM 1 light', '3 AM 1 light']);
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['s0', 's1', 's2', 's3', 's4', 'p1', 'p2', 'b1', 'g1', 'p3', 'm1', 'u1']);
  const third = byClass(el, 'sky-hour')[2];
  assert.deepEqual(tiles(third).map((card) => card.dataset.entry), ['p2'], 'each card under its own hour');
  assert.equal(all(el, (node) => /Show more/.test(node.textContent ?? '') && node.localName === 'button').length, 0, 'no Show more anywhere');
  assert.equal(tag(el, 'details').filter((node) => node.classList.contains('sky-group-details')).length, 0, 'no groups to open');
  page.destroy();
});

test('a card has the still’s close-up, the time, the kind in its colour, how long it lasted, and its line', async () => {
  const { page, el } = pageWith({ log: night({ picture: { width: 400, height: 177 } }) });   // the dev server’s made-up stills are 400 × 177
  await settle();
  const words = (card) => [byClass(card, 'sky-tile-when')[0].textContent, byClass(card, 'sky-tile-word')[0].textContent, byClass(card, 'sky-tile-length')[0].textContent,
    byClass(card, 'sky-tile-line')[0].textContent];
  const light = tileOf(el, 'u1');
  assert.equal(light.localName, 'button', 'a card is one button');
  assert.deepEqual(words(light), ['3:12:08 AM', 'Unexplained', '4.2 s', 'Northwest, 8° up · blinks'], 'an unexplained light: where it was and how');
  assert.equal(light.dataset.kind, 'unexplained');
  assert.equal(byClass(light, 'sky-tile-kind')[0].dataset.kind, 'unexplained', 'the chip takes the strip’s colour for its kind');
  assert.equal(light.getAttribute('aria-label'), '3:12:08 AM, Unexplained, 4.2 seconds, Northwest, 8° up · blinks');
  assert.deepEqual(words(tileOf(el, 'p1')), ['8:05:00 PM', 'Plane', '4.2 s', 'TEST123 · 35,000 ft'], 'a plane: its flight');
  assert.deepEqual(words(tileOf(el, 'p2')), ['9:40:00 PM', 'Probably a plane', '4.2 s', 'ABC789 · 12,000 ft']);
  assert.deepEqual(words(tileOf(el, 's0')).slice(1), ['Satellite', '4.2 s', 'ISS (ZARYA)'], 'a satellite: its name');
  assert.deepEqual(words(tileOf(el, 'm1')).slice(1), ['Meteor', '<1 s', 'South, 40° up'], 'nothing to name it by: where it was');
  assert.deepEqual(['b1', 'g1'].map((id) => tileOf(el, id).dataset.kind), ['bugsAndBirds', 'bugsAndBirds']);

  // The still: lazy, the close-up of the light with its path once the picture is there.
  const img = tag(light, 'img')[0];
  assert.equal(img.getAttribute('src'), `/api/v1/sky/cameras/${SKY}/entries/u1/still?night=2026-10-24&size=thumb`, 'a card asks for the small picture');
  assert.equal(img.getAttribute('loading'), 'lazy');
  const pic = byClass(light, 'sky-tile-pic')[0];
  assert.equal(pic.dataset.view, 'loading');
  const overlay = byClass(light, 'sky-path')[0];
  assert.equal(tag(overlay, 'polyline').length, 0, 'nothing drawn before the picture is known');
  Object.assign(img, { naturalWidth: 400, naturalHeight: 177 });   // the picture has arrived: all of it, 400 × 177 (which the night said)
  img.dispatchEvent({ type: 'load', target: img });
  assert.equal(pic.dataset.view, 'closeup');
  assert.equal(tag(overlay, 'polyline')[0].getAttribute('points'), '40,35.4 120,44.25', 'the path in the picture’s pixels');
  assert.equal(tag(overlay, 'circle').length, 2, 'where it began and where it ended');
  const crop = closeUpRect(UNEXPLAINED().path, 400, 177);
  assert.equal(overlay.getAttribute('viewBox'), `${crop.x} ${crop.y} ${crop.width} ${crop.height}`, 'and the close-up shows the part around it');

  // No still kept: a quiet picture of its kind, nothing to load.
  const plane = tileOf(el, 'p1');
  assert.equal(tag(plane, 'img').length, 0);
  assert.equal(byClass(plane, 'sky-tile-pic')[0].dataset.view, 'none');
  assert.equal(byClass(plane, 'sky-tile-none').length, 1, 'the kind’s sign instead');
  page.destroy();
});

/** The card's picture frame, once its still (1920 × 852 unless said) has arrived. */
const arrive = (card, width = 1920, height = 852) => {
  const img = tag(card, 'img')[0];
  Object.assign(img, { naturalWidth: width, naturalHeight: height });
  img.dispatchEvent({ type: 'load', target: img });
  return byClass(card, 'sky-tile-pic')[0];
};
const one = (entry) => night({ entries: [entry], counts: { ...NONE, unexplained: 1 } });
/** The card's picture element. */
const img = (card) => tag(card, 'img')[0];

test('a card’s close-up fills its frame; a light in a corner is moved in, and one that crossed the sky is shown whole', async () => {
  const { page, el } = pageWith();
  await settle();
  const pic = arrive(tileOf(el, 'u1'));
  assert.deepEqual(closeUpRect(UNEXPLAINED().path, 1920, 852), { x: 0, y: 0, width: 768, height: 432 });
  // The picture is placed so that the crop fills the card's 16:9 frame: 1920 / 768 = 250 % of its width, moved by the crop's corner.
  assert.deepEqual(['--sky-crop-w', '--sky-crop-x', '--sky-crop-y'].map((name) => pic.style.getPropertyValue(name)), ['250', '0', '0']);
  assert.equal(byClass(pic, 'sky-path')[0].getAttribute('viewBox'), '0 0 768 432');
  // A bigger picture: the same path in its coordinates, drawn again rather than added to.
  arrive(tileOf(el, 'u1'), 4256, 1888);
  const big = closeUpRect(UNEXPLAINED().path, 4256, 1888);
  assert.equal(byClass(pic, 'sky-path')[0].getAttribute('viewBox'), `${big.x} ${big.y} ${big.width} ${big.height}`);
  assert.equal(tag(pic, 'polyline').length, 1);
  assert.equal(tag(pic, 'polyline')[0].getAttribute('points'), '425.6,377.6 1276.8,472');
  page.destroy();

  const corner = pageWith({ log: one(raw('u9', 'unexplained', chicago(2, 0), { hasStill: true, path: [{ t: 0, x: 0.98, y: 0.97 }, { t: 1, x: 0.995, y: 0.99 }] })) });
  await settle();
  const moved = arrive(tiles(corner.el)[0]);
  assert.equal(byClass(moved, 'sky-path')[0].getAttribute('viewBox'), '1760 762 160 90');
  assert.deepEqual(['--sky-crop-w', '--sky-crop-x', '--sky-crop-y'].map((name) => moved.style.getPropertyValue(name)), ['1200', '1100', '846.67']);
  corner.page.destroy();

  const across = pageWith({ log: one(raw('u8', 'unexplained', chicago(2, 0), { hasStill: true, path: [{ t: 0, x: 0.05, y: 0.1 }, { t: 9, x: 0.95, y: 0.9 }] })) });
  await settle();
  const whole = arrive(tiles(across.el)[0]);
  assert.equal(whole.dataset.view, 'whole', 'all of the picture, in the frame');
  assert.equal(byClass(whole, 'sky-path')[0].getAttribute('viewBox'), '0 0 1920 852');
  across.page.destroy();

  // A still the box no longer has: the small picture fails, and so does the whole one, and the card shows its kind instead.
  const gone = pageWith({ log: one(raw('u7', 'unexplained', chicago(2, 0), { hasStill: true })) });
  await settle();
  const img = tag(tiles(gone.el)[0], 'img')[0];
  img.dispatchEvent({ type: 'error', target: img });
  img.dispatchEvent({ type: 'error', target: img });
  assert.equal(byClass(tiles(gone.el)[0], 'sky-tile-pic')[0].dataset.view, 'none');
  assert.equal(byClass(tiles(gone.el)[0], 'sky-tile-none').length, 1);
  gone.page.destroy();
});

// MARK: The small picture

const PICTURE = { width: 1920, height: 852 };
const thumbAddress = (id) => `/api/v1/sky/cameras/${SKY}/entries/${id}/still?night=2026-10-24&size=thumb`;
const fullAddress = (id) => `/api/v1/sky/cameras/${SKY}/entries/${id}/still?night=2026-10-24`;
/** A night of one light with a still and the path given, in a picture of PICTURE's size unless said. */
const withPath = (path, extra = {}, picture = PICTURE) => pageWith({ log: night({ entries: [raw('u1', 'unexplained', chicago(3, 12), { hasStill: true, path, ...extra })], counts: { ...NONE, unexplained: 1 }, picture }) });
const FLAT = [{ t: 0, x: 0.45, y: 0.4 }, { t: 2, x: 0.5, y: 0.42 }, { t: 4, x: 0.55, y: 0.45 }];   // its close-up is { x: 768, y: 254, width: 384, height: 216 }
const ACROSS = [{ t: 0, x: 0.05, y: 0.1 }, { t: 9, x: 0.95, y: 0.9 }];                         // none: the whole picture is its view

test('every card asks for the small picture, and the player for the whole one', async () => {
  const player = playerSpy();
  const { page, el } = pageWith({ log: night({ picture: PICTURE }), openPlayer: player.open });
  await settle();
  const images = tiles(el).flatMap((card) => tag(card, 'img'));
  assert.equal(images.length, 1, 'one light has a still');
  assert.equal(images[0].getAttribute('src'), thumbAddress('u1'));
  assert.equal(images[0].getAttribute('loading'), 'lazy');
  tileOf(el, 'u1').click();
  await settle();
  assert.equal(player.opened[0].still, fullAddress('u1'), 'the player keeps the whole picture');
  page.destroy();
});

test('the close-up the box cut fills the card, and the path is drawn in the rectangle it was cut from', async () => {
  const { page, el } = withPath(FLAT);
  await settle();
  const card = tiles(el)[0];
  const pic = arrive(card, 384, 216);
  assert.equal(pic.dataset.view, 'thumb', 'the picture is the close-up: it is not moved or magnified');
  const overlay = byClass(pic, 'sky-path')[0];
  assert.equal(overlay.getAttribute('viewBox'), '768 254 384 216', 'the rectangle of the still the thumbnail shows, in the still’s pixels');
  assert.equal(overlay.getAttribute('preserveAspectRatio'), 'none', 'laid exactly over a picture that fills the frame');
  assert.equal(tag(overlay, 'polyline')[0].getAttribute('points'), '864,340.8 960,357.84 1056,383.4', 'the path, in the still’s pixels');
  assert.equal(tag(overlay, 'circle').length, 2);
  assert.equal(pic.style.getPropertyValue('--sky-crop-w'), '', 'and no crop to place');
  // The same thumbnail again (the image loaded twice) draws the same, once.
  arrive(card, 384, 216);
  assert.equal(tag(overlay, 'polyline').length, 1);
  page.destroy();
});

test('a thumbnail is as wide as the box makes it, and the rectangle is the one the page and the box agree on', async () => {
  // A close-up wider than the limit is scaled down to it: 1515 × 852 comes as 480 × 270.
  const wide = [{ t: 0, x: 0.2, y: 0.3 }, { t: 5, x: 0.7, y: 0.6 }];
  const { page, el } = withPath(wide);
  await settle();
  const pic = arrive(tiles(el)[0], 480, 270);
  const rect = thumbRect(wide, PICTURE.width, PICTURE.height);
  assert.ok(rect.width > 480, JSON.stringify(rect));
  assert.equal(pic.dataset.view, 'thumb');
  assert.equal(byClass(pic, 'sky-path')[0].getAttribute('viewBox'), `${rect.x} ${rect.y} ${rect.width} ${rect.height}`);
  page.destroy();
});

test('a light that crossed the sky has all of the picture as its thumbnail, drawn in the picture’s size', async () => {
  const { page, el } = withPath(ACROSS);
  await settle();
  const pic = arrive(tiles(el)[0], 480, 213);
  assert.equal(pic.dataset.view, 'whole');
  assert.equal(byClass(pic, 'sky-path')[0].getAttribute('viewBox'), '0 0 1920 852', 'the path is in the picture’s pixels, whatever size the thumbnail is');
  assert.equal(tag(byClass(pic, 'sky-path')[0], 'polyline')[0].getAttribute('points'), '96,85.2 1824,766.8');
  page.destroy();
});

test('the whole picture, when the box answers with it, is drawn as before: magnified to the close-up, by the picture’s own size', async () => {
  const { page, el } = withPath(FLAT);
  await settle();
  // The box could not make a thumbnail and sent the picture: 1920 × 852.
  const pic = arrive(tiles(el)[0], 1920, 852);
  assert.equal(pic.dataset.view, 'closeup');
  assert.deepEqual(['--sky-crop-w', '--sky-crop-x', '--sky-crop-y'].map((name) => pic.style.getPropertyValue(name)), ['500', '200', '117.64']);
  assert.equal(byClass(pic, 'sky-path')[0].getAttribute('viewBox'), '768 254.1 384 216');
  assert.equal(img(tiles(el)[0]).getAttribute('src'), thumbAddress('u1'), 'and it is not asked for again');
  page.destroy();
});

test('a small picture that was not cut for the light is the whole picture, magnified as the full still is', async () => {
  const { page, el } = withPath(FLAT);
  await settle();
  // The box has no close-up for it (an older box, a rule that changed): all of the picture, 480 wide.
  const pic = arrive(tiles(el)[0], 480, 213);
  assert.equal(pic.dataset.view, 'closeup', 'the close-up of the picture is shown by magnifying it');
  assert.deepEqual(['--sky-crop-w', '--sky-crop-x', '--sky-crop-y'].map((name) => pic.style.getPropertyValue(name)), ['500', '200', '117.64']);
  assert.equal(byClass(pic, 'sky-path')[0].getAttribute('viewBox'), '768 254.1 384 216', 'in the picture’s own pixels, not the small picture’s');
  page.destroy();
});

test('a small picture that fails is replaced by the whole one, and that failing by the kind’s sign', async () => {
  const { page, el } = withPath(FLAT);
  await settle();
  const card = tiles(el)[0];
  const image = img(card);
  assert.equal(image.getAttribute('src'), thumbAddress('u1'));
  image.dispatchEvent({ type: 'error', target: image });
  assert.equal(image.getAttribute('src'), fullAddress('u1'), 'the whole picture, then');
  assert.equal(byClass(card, 'sky-tile-pic')[0].dataset.view, 'loading', 'not given up on yet');
  assert.equal(byClass(card, 'sky-tile-none').length, 0);
  // It arrives: drawn as the full still always was.
  const pic = arrive(card, 1920, 852);
  assert.equal(pic.dataset.view, 'closeup');
  // A card whose whole picture fails too shows the sign.
  const { page: other, el: second } = withPath(FLAT);
  await settle();
  const again = img(tiles(second)[0]);
  again.dispatchEvent({ type: 'error', target: again });
  again.dispatchEvent({ type: 'error', target: again });
  assert.equal(byClass(tiles(second)[0], 'sky-tile-pic')[0].dataset.view, 'none');
  assert.equal(byClass(tiles(second)[0], 'sky-tile-none').length, 1);
  assert.equal(tag(tiles(second)[0], 'img').length, 0);
  page.destroy();
  other.destroy();
});

test('a small picture of another shape than the close-up or the picture is not drawn: the whole one is asked for', async () => {
  const { page, el } = withPath(FLAT);
  await settle();
  const card = tiles(el)[0];
  const pic = arrive(card, 300, 300);
  assert.equal(img(card).getAttribute('src'), fullAddress('u1'), 'the page does not know where such a picture is cut from');
  assert.equal(pic.dataset.view, 'loading');
  assert.equal(tag(byClass(pic, 'sky-path')[0], 'polyline').length, 0, 'and draws nothing over it meanwhile');
  const full = arrive(card, 1920, 852);
  assert.equal(full.dataset.view, 'closeup');
  page.destroy();
});

test('without the size of the pictures only a whole one can be drawn', async () => {
  // A bridge that does not say (an older one, or none of the night’s pictures can be read): a small picture cannot be placed.
  const { page, el } = pageWith({ log: night({ entries: [raw('u1', 'unexplained', chicago(3, 12), { hasStill: true, path: FLAT })], counts: { ...NONE, unexplained: 1 } }) });
  await settle();
  const card = tiles(el)[0];
  assert.equal(img(card).getAttribute('src'), thumbAddress('u1'), 'it is asked for all the same: an older box sends the whole picture');
  arrive(card, 384, 216);
  assert.equal(img(card).getAttribute('src'), fullAddress('u1'));
  assert.equal(byClass(card, 'sky-tile-pic')[0].dataset.view, 'loading');
  const whole = arrive(card, 1920, 852);
  assert.equal(whole.dataset.view, 'closeup');
  assert.equal(byClass(whole, 'sky-path')[0].getAttribute('viewBox'), '768 254.1 384 216');
  page.destroy();
});

test('the picture size the bridge sends is read safely', async () => {
  for (const [sent, expected] of [[{ width: 1920, height: 852 }, '1920x852'], [null, 'none'], [{ width: 0, height: 5 }, 'none'], [{ width: 'x', height: 5 }, 'none'],
    [{ width: 1920 }, 'none'], [[1920, 852], 'none'], [{ width: 1920.5, height: 852 }, 'none'], [{ width: 1e9, height: 5 }, 'none']]) {
    const { page, el } = withPath(FLAT, {}, sent);
    await settle();
    const card = tiles(el)[0];
    if (expected === 'none') {
      arrive(card, 384, 216);
      assert.equal(img(card).getAttribute('src'), fullAddress('u1'), `${JSON.stringify(sent)}: a small picture cannot be placed`);
    } else {
      assert.equal(arrive(card, 384, 216).dataset.view, 'thumb', JSON.stringify(sent));
    }
    page.destroy();
  }
});

/** A light the box joined from three it logged in pieces (seen in five), its picture its third part's, cut around that part's path. */
const JOINED = () => raw('j1', 'unexplained', chicago(3, 12), { hasStill: true, pieces: 5, parts: ['j1', 'j2', 'j3'], end: chicago(3, 12) + 30_000,
  path: [{ t: 0, x: 0.1, y: 0.2 }, { t: 30, x: 0.5, y: 0.4 }], stillPart: { id: 'j3', path: FLAT },
  measures: { azimuth: 312, elevation: 8, azimuthEnd: 330, elevationEnd: 14, duration: 30, speed: 0.6, shape: 'straight', blinks: true, blinkRate: 0.25 } });

test('a light seen in pieces is one card with its part’s picture, counted once, and its player says how many and plays the whole of it', async () => {
  const player = playerSpy();
  const log = night({ entries: [JOINED(), raw('p1', 'plane', chicago(20, 5, 24), { by: 'flight' })], counts: undefined, picture: PICTURE });
  const { page, el } = pageWith({ log, openPlayer: player.open });
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry).sort(), ['j1', 'p1'], 'one card for the light');
  assert.ok(chipText(el).includes('Unexplained 1') && chipText(el).includes('All 2 *'), `${chipText(el)}`);
  const card = tileOf(el, 'j1');
  assert.equal(img(card).getAttribute('src'), thumbAddress('j3'), 'its picture is the part’s');
  // The part's small picture is the close-up the box cut around the part's path; the whole light's path is drawn over it, in the still's pixels.
  const pic = arrive(card, 384, 216);
  assert.equal(pic.dataset.view, 'thumb');
  const overlay = byClass(pic, 'sky-path')[0];
  assert.equal(overlay.getAttribute('viewBox'), '768 254 384 216', 'the rectangle the box cut around the part’s path');
  assert.equal(tag(overlay, 'polyline')[0].getAttribute('points'), '192,170.4 960,340.8', 'the whole light’s path');
  card.click();
  await settle();
  const [options] = player.opened;
  assert.equal(options.still, fullAddress('j3'), 'the player’s picture is the part’s too');
  assert.equal(options.entry.end - options.entry.start, 30_000, 'it plays the whole of the light, with its whole path');
  assert.equal(options.entry.path.length, 2);
  const text = shown(options.details);
  assert.ok(text.includes('1 light, seen in 5 parts'), text);
  assert.ok(text.includes('Lasted 30 seconds'), text);
  page.destroy();
  // A light seen whole says nothing of parts.
  const whole = pageWith({ openPlayer: player.open });
  await settle();
  tileOf(whole.el, 'u1').click();
  await settle();
  assert.ok(!shown(player.opened[1].details).includes('seen in'));
  whole.page.destroy();
});

test('a part of a joined light named in the address shows the light, and a word on it goes to the bridge with the light’s id', async () => {
  const scrolled = [];
  FakeElement.prototype.scrollIntoView = function scrollIntoView(options) { scrolled.push([this, options]); };
  try {
    const player = playerSpy();
    const log = night({ entries: [JOINED()], counts: undefined, picture: PICTURE });
    const { page, el, calls } = pageWith({ log, query: 'entry=j2', openPlayer: player.open });
    await settle();
    assert.ok(tileOf(el, 'j1')?.classList.contains('sky-target'), 'the light j2 is part of');
    tileOf(el, 'j1').click();
    await settle();
    button(player.opened[0].details, 'Bird').click();
    await settle();
    assert.deepEqual(calls.corrections.map((request) => [request.entryID, request.label]), [['j1', 'bird']]);
    assert.ok(chipText(el).includes('Bugs & birds 1'), `${chipText(el)}`);
    page.destroy();
  } finally {
    delete FakeElement.prototype.scrollIntoView;
  }
});

test('every card of a night asks for the small picture, however many are made', async () => {
  const { page, el, observer } = pageWith({ log: busyNight(300, { picture: PICTURE }) });
  await settle();
  while (observer.scroll()) { /* make them all */ }
  const all = tiles(el).flatMap((card) => tag(card, 'img')).map((node) => node.getAttribute('src'));
  assert.ok(all.length > 100 && all.every((address) => address.endsWith('&size=thumb')), `${all.length} pictures, all of them small`);
  page.destroy();
});

// MARK: Opening a card

test('a card opens the clip player with the light, its details, its correction and the way to the Monitor; closing it leaves the grid as it was', async () => {
  const player = playerSpy();
  const { page, el, calls } = pageWith({ openPlayer: player.open });
  await settle();
  const card = tileOf(el, 'u1');
  card.click();
  await settle();
  assert.equal(player.opened.length, 1);
  const [options] = player.opened;
  assert.equal(options.camera.id, SKY);
  assert.equal(options.entry.id, 'u1');
  assert.equal(options.zone, CHICAGO);
  assert.equal(options.heading, '3:12:08 AM');
  assert.equal(options.what, 'Moving light · North Sky');
  assert.equal(options.still, `/api/v1/sky/cameras/${SKY}/entries/u1/still?night=2026-10-24`);
  assert.equal(options.watchHref, `#/camera/${SKY}/watch/${chicago(3, 12) + 8000 - 3000}`, 'Watch on the Monitor');
  // The card's full details are in the player.
  const details = options.details;
  assert.ok(details?.classList.contains('sky-details'));
  const text = shown(details);
  for (const sentence of ['Unexplained', 'Low in the northwest, 8° up', 'Lasted 4.2 seconds', 'About 6× faster across the sky than planes at that height', 'Blinks about once a second',
    'Curved', 'Looks larger than planes and satellites do there', 'A bright light moving fast, probably a drone.', 'That was a…']) assert.ok(text.includes(sentence), sentence);
  assert.deepEqual(['Plane', 'Bird', 'Bug', 'Satellite', 'Meteor', 'Not sure'].map((word) => Boolean(button(details, word))), Array(6).fill(true));
  assert.equal(link(details, 'Download clip').getAttribute('href'),
    `/api/v1/nvr/cameras/${SKY}/clip?from=${chicago(3, 12) + 8000 - 3000}&to=${chicago(3, 12) + 8000 + 4200 + 3000}&tz=America%2FChicago&part=1`);

  tileOf(el, 'p1').click();
  await settle();
  assert.equal(player.opened.length, 1, 'one player at a time');
  options.onClose();
  await settle();
  assert.ok(tileOf(el, 'u1') === card, 'the grid is not drawn again: it stays where it was');
  assert.equal(calls.loads.length, 1);

  // A plane: the player says what it was, never with a height; the flight is in its details.
  tileOf(el, 'p1').click();
  await settle();
  assert.equal(player.opened.length, 2);
  assert.equal(player.opened[1].what, 'Plane · North Sky');
  assert.equal(player.opened[1].still, null, 'no still kept');
  assert.match(shown(player.opened[1].details), /TEST123 · 35,000 ft/);
  // Leaving the page closes the player.
  page.destroy();
  assert.equal(player.closed, 1);
});

test('a player that cannot be loaded says so, and the card opens again', async () => {
  let tries = 0;
  const openPlayer = async () => { tries += 1; throw new TypeError('Failed to fetch dynamically imported module'); };
  const { page, el, calls } = pageWith({ openPlayer });
  await settle();
  tileOf(el, 'u1').click();
  await settle();
  assert.deepEqual(calls.notes, ['The player couldn’t open. Try again in a moment.'], 'never the script’s own words');
  assert.equal(tileOf(el, 'u1').getAttribute('aria-busy'), null);
  tileOf(el, 'u1').click();
  await settle();
  assert.equal(tries, 2);
  page.destroy();
});

// MARK: Corrections

test('a correction from the player changes the card, the chips, the summary and the strip in place', async () => {
  const player = playerSpy();
  const { page, el, calls } = pageWith({ openPlayer: player.open });
  await settle();
  const card = tileOf(el, 'u1');
  const summary = byClass(el, 'sky-summary')[0];
  card.click();
  await settle();
  const details = player.opened[0].details;
  button(details, 'Bird').click();
  await settle();
  assert.deepEqual(calls.corrections, [{ cameraID: SKY, entryID: 'u1', night: '2026-10-24', label: 'bird' }]);
  assert.match(shown(details), /You said: bird\. Camera Bridge learns from this\./);
  assert.equal(button(details, 'Bird').getAttribute('aria-pressed'), 'true');
  assert.equal(button(details, 'Plane').getAttribute('aria-pressed'), 'false');
  assert.equal(byClass(details, 'sky-kind-chip')[0].dataset.kind, 'bugsAndBirds', 'the player says what it is now');
  // The card: the same element, where it was, now a bird the person named.
  assert.ok(tileOf(el, 'u1') === card, 'nothing jumped');
  assert.equal(card.dataset.kind, 'bugsAndBirds');
  assert.equal(byClass(card, 'sky-tile-word')[0].textContent, 'Bird');
  assert.equal(byClass(card, 'sky-tile-yours')[0].hidden, false, 'marked as the person’s');
  assert.match(card.getAttribute('aria-label'), /Bird.*You said what this was/);
  // The counts: the chips and the summary.
  assert.deepEqual(chipText(el), ['All 12 *', 'Unexplained 0', 'High priority 0', 'Planes 3', 'Satellites 5', 'Meteors 1', 'Bugs & birds 3', 'Corrected by you 1']);
  assert.ok(byClass(el, 'sky-summary')[0] === summary, 'the same summary, drawn again in place');
  assert.match(shown(summary), /Last night: 0 unexplained, 12 explained/, 'one less to look at');
  assert.equal(byClass(el, 'sky-dot').filter((dot) => dot.className.includes('sky-dot--unexplained')).length, 0, 'and its dot is not unexplained any more');
  assert.equal(calls.loads.length, 1, 'the page is not loaded again');

  // Another tap changes its mind; "Not sure" reads as it says.
  button(details, 'Not sure').click();
  await settle();
  assert.equal(calls.corrections.at(-1).label, 'notSure');
  assert.match(shown(details), /You said: not sure\. Camera Bridge learns from this\./);
  assert.equal(card.dataset.kind, 'unexplained', 'an unexplained light the person doubted is unexplained still');
  page.destroy();
});

test('a correction the filters no longer show: the card takes its new kind, fades and leaves the grid at once, and the counts follow', async () => {
  const player = playerSpy();
  const { page, el, calls, fades, endFades } = pageWith({ openPlayer: player.open, query: 'kinds=unexplained,meteors' });
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['m1', 'u1']);
  assert.deepEqual(hours(el), ['1 AM 1 light', '3 AM 1 light']);
  const meteor = tileOf(el, 'm1');
  const card = tileOf(el, 'u1');
  card.click();
  await settle();
  button(player.opened[0].details, 'Plane').click();
  await settle();
  // At once: the card's new kind and colour, the chips' counts, the summary, and the fade.
  assert.equal(card.dataset.kind, 'planes', 'its colour');
  assert.equal(byClass(card, 'sky-tile-word')[0].textContent, 'Plane', 'its chip');
  assert.deepEqual(chipText(el), ['All 12', 'Unexplained 0 *', 'High priority 0', 'Planes 4', 'Satellites 5', 'Meteors 1 *', 'Bugs & birds 2', 'Corrected by you 1']);
  assert.match(shown(byClass(el, 'sky-summary')[0]), /0 unexplained, 12 explained/);
  assert.equal(card.dataset.leaving, 'true', 'fading out');
  assert.equal(card.getAttribute('aria-hidden'), 'true', 'and out of reach while it fades');
  assert.deepEqual(fades.map(({ ms }) => ms), [200], 'a short fade');
  endFades();
  assert.deepEqual(tiles(el).map((node) => node.dataset.entry), ['m1'], 'then gone from the grid, without a refresh');
  assert.equal(card.parentNode, null);
  assert.equal(tileOf(el, 'm1'), meteor, 'the rest of the grid as it was');
  assert.deepEqual(hours(el), ['1 AM 1 light'], 'its hour went with its only light');
  assert.equal(calls.loads.length, 1, 'nothing asked of the bridge again');
  assert.deepEqual(calls.scrolls, [], 'the page stays where it is');
  assert.equal(player.closed, 0, 'the player stays open on its light');
  const css = readFileSync(new URL('../web/sky.css', import.meta.url), 'utf8');
  assert.match(css, /\.sky-tile\[data-leaving="true"\] \{ opacity: 0;[^}]*pointer-events: none; transition: opacity 0\.2s/, 'the fade');

  // The filters' own Clear brings it back with every other light, as before.
  player.opened[0].onClose();
  chip(el, 'all').click();
  await settle();
  assert.equal(tiles(el).length, 12);
  assert.equal(tileOf(el, 'u1').dataset.kind, 'planes');
  page.destroy();
});

test('a correction the filters still show: the card stays where it is, in its new kind', async () => {
  const player = playerSpy();
  const { page, el, fades } = pageWith({ openPlayer: player.open, query: 'kinds=unexplained,bugs' });
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['b1', 'g1', 'u1']);
  const card = tileOf(el, 'u1');
  card.click();
  await settle();
  button(player.opened[0].details, 'Bird').click();
  await settle();
  assert.deepEqual(tiles(el).map((node) => node.dataset.entry), ['b1', 'g1', 'u1'], 'it stays');
  assert.equal(tileOf(el, 'u1'), card, 'the same card');
  assert.equal(card.dataset.kind, 'bugsAndBirds');
  assert.equal(card.dataset.leaving, undefined);
  assert.deepEqual(fades, []);
  assert.deepEqual(chipText(el).filter((text) => /Unexplained|Bugs/.test(text)), ['Unexplained 0 *', 'Bugs & birds 3 *']);
  page.destroy();
});

test('the player stays on a light whose card left, its title saying the new kind; closing it puts the focus where the card was', async () => {
  const player = playerSpy();
  const { page, el, endFades } = pageWith({ openPlayer: player.open, query: 'kinds=planes' });
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['p1', 'p2', 'p3']);
  const focused = [];
  for (const card of tiles(el)) card.focus = () => focused.push(card.dataset.entry);
  tileOf(el, 'p2').click();
  await settle();
  const [options] = player.opened;
  assert.equal(options.what, 'Probably a plane · North Sky');
  const details = options.details;
  button(details, 'Bird').click();
  await settle();
  endFades();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['p1', 'p3'], 'the card left');
  assert.equal(player.closed, 0, 'the player did not close');
  assert.equal(byClass(details, 'sky-kind-chip')[0].dataset.kind, 'bugsAndBirds', 'it shows its new kind');
  assert.match(shown(details), /You said: bird\./);
  assert.equal(player.whats.at(-1), 'Bird · North Sky', 'its title too');

  // A change of mind in the same player: a plane again, so the card comes back to its place.
  button(details, 'Plane').click();
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['p1', 'p2', 'p3'], 'back in its place');
  assert.equal(tileOf(el, 'p2').dataset.kind, 'planes');
  assert.equal(player.whats.at(-1), 'Plane · North Sky');
  button(details, 'Meteor').click();
  await settle();
  endFades();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['p1', 'p3']);
  for (const card of tiles(el)) card.focus = () => focused.push(card.dataset.entry);
  options.onClose();
  assert.deepEqual(focused, ['p3'], 'the focus on the card that took its place');
  page.destroy();
});

/**
 * Lays the grid out as a browser would, in the window's coordinates with the page scrolled `view.y` down: each hour's heading 40 px tall, then
 * its cards four to a row, 100 px a row (a block not made yet a whole row, as tall as its style says), 20 px between hours; everything else as
 * the fake browser has it. -> restore()
 */
function layOut(el, view, { cols = 4, row = 100, head = 40, gap = 20 } = {}) {
  const real = FakeElement.prototype.getBoundingClientRect;
  function boxes() {
    const found = new Map();
    let y = 0;
    for (const section of byClass(el, 'sky-hour')) {
      const top = y;
      const heading = byClass(section, 'sky-hour-head')[0];
      if (heading) { found.set(heading, [y, y + head]); y += head; }
      const grid = byClass(section, 'sky-tiles')[0];
      const gridTop = y;
      let col = 0;
      for (const item of grid.children) {
        if (item.classList.contains('sky-pending')) {
          if (col) { y += row; col = 0; }
          const tall = Number.parseFloat(item.style.height) || 360;
          found.set(item, [y, y + tall]);
          y += tall;
          continue;
        }
        found.set(item, [y, y + row]);
        col += 1;
        if (col === cols) { col = 0; y += row; }
      }
      if (col) y += row;
      found.set(grid, [gridTop, y]);
      found.set(section, [top, y]);
      y += gap;
    }
    return found;
  }
  FakeElement.prototype.getBoundingClientRect = function box() {
    const known = boxes().get(this);
    if (!known) return real.call(this);
    const [top, bottom] = known;
    return { x: 0, y: top - view.y, left: 0, right: 800, width: 800, top: top - view.y, bottom: bottom - view.y, height: bottom - top };
  };
  return () => { FakeElement.prototype.getBoundingClientRect = real; };
}

test('a card leaving the grid never moves the page: what is on the screen stays where it is, above or below the card', async () => {
  const view = { y: 0 };
  const player = playerSpy();
  const { page, el, calls, endFades } = pageWith({ openPlayer: player.open, query: 'kinds=satellites,planes', scrolled: (dy) => { view.y += dy; } });
  const restore = layOut(el, view);
  const jumps = [];
  FakeElement.prototype.scrollIntoView = function jump() { jumps.push(this.className); };
  try {
    await settle();
    // 7 PM: five satellites in two rows; 8, 9 and 11 PM: a plane each.
    assert.deepEqual(hours(el), ['7 PM 5 lights', '8 PM 1 light', '9 PM 1 light', '11 PM 1 light']);
    const heading = (name) => byClass(el, 'sky-hour-head').find((node) => shown(node).startsWith(name));
    const before = new Map(tiles(el).map((card) => [card.dataset.entry, card]));

    // On the screen: the page at its top, a plane at 9 PM leaves. Nothing above it moves, so the page does not scroll.
    tileOf(el, 'p2').click();
    await settle();
    button(player.opened[0].details, 'Bird').click();
    await settle();
    endFades();
    player.opened[0].onClose();
    assert.deepEqual(hours(el), ['7 PM 5 lights', '8 PM 1 light', '11 PM 1 light']);
    assert.deepEqual(calls.scrolls, [], 'not scrolled');
    assert.equal(heading('7 PM').getBoundingClientRect().top, 0);

    // Above the screen: the person is at 8 PM when a satellite of 7 PM leaves (its player was still saying so). Its hour is a row shorter, so
    // the page scrolls up by that row and 8 PM stays exactly where it was.
    tileOf(el, 's4').click();
    await settle();
    view.y = heading('8 PM').getBoundingClientRect().top + view.y;
    assert.equal(heading('8 PM').getBoundingClientRect().top, 0, '8 PM at the top of the screen');
    button(player.opened[1].details, 'Meteor').click();
    await settle();
    endFades();
    assert.deepEqual(hours(el), ['7 PM 4 lights', '8 PM 1 light', '11 PM 1 light'], 'one light less at 7 PM');
    assert.deepEqual(calls.scrolls, [-100], 'up by the row 7 PM lost');
    assert.equal(heading('8 PM').getBoundingClientRect().top, 0, '8 PM still at the top of the screen');
    assert.equal(tileOf(el, 'p1').getBoundingClientRect().top, 40, 'and its plane under it');
    assert.deepEqual(jumps, [], 'no jump to an hour or to the top');
    for (const id of ['s0', 's1', 's2', 's3', 'p1', 'p3']) assert.equal(tileOf(el, id), before.get(id), `${id}: the same card, not the grid drawn again`);
  } finally {
    delete FakeElement.prototype.scrollIntoView;
    restore();
    page.destroy();
  }
});

test('with less motion asked for, a card leaves at once, without a fade', async () => {
  const realMatch = globalThis.matchMedia;
  globalThis.matchMedia = (query) => ({ matches: query === '(prefers-reduced-motion: reduce)', addEventListener() {}, removeEventListener() {} });
  try {
    const player = playerSpy();
    const { page, el, fades } = pageWith({ openPlayer: player.open, query: 'kinds=unexplained,meteors' });
    await settle();
    tileOf(el, 'u1').click();
    await settle();
    button(player.opened[0].details, 'Satellite').click();
    await settle();
    assert.deepEqual(fades, [], 'no fade to wait for');
    assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['m1']);
    page.destroy();
  } finally {
    if (realMatch === undefined) delete globalThis.matchMedia;
    else globalThis.matchMedia = realMatch;
  }
});

test('the last card to leave leaves the filters’ friendly line and Clear filters', async () => {
  const player = playerSpy();
  const { page, el, endFades } = pageWith({ openPlayer: player.open, query: 'kinds=unexplained' });
  await settle();
  tileOf(el, 'u1').click();
  await settle();
  button(player.opened[0].details, 'Plane').click();
  await settle();
  endFades();
  assert.equal(tiles(el).length, 0);
  assert.match(shown(el), /Nothing unexplained/);
  assert.ok(button(el, 'Clear filters'));
  // Not sure brings an unexplained light back: unexplained it is.
  button(player.opened[0].details, 'Not sure').click();
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['u1']);
  assert.equal(tileOf(el, 'u1').dataset.kind, 'unexplained');
  page.destroy();
});

test('a correction the bridge could not take says so in the player and changes nothing', async () => {
  const player = playerSpy();
  const { page, el } = pageWith({ openPlayer: player.open, correct: async () => { throw new ApiError(400, 'invalid', 'Sky Watcher doesn’t know that label.'); } });
  await settle();
  tileOf(el, 'u1').click();
  await settle();
  const details = player.opened[0].details;
  button(details, 'Plane').click();
  await settle();
  assert.match(shown(details), /Sky Watcher doesn’t know that label\./);
  assert.doesNotMatch(shown(details), /You said/);
  assert.equal(button(details, 'Plane').getAttribute('aria-pressed'), 'false');
  assert.equal(tileOf(el, 'u1').dataset.kind, 'unexplained');
  assert.match(shown(byClass(el, 'sky-summary')[0]), /1 unexplained, 11 explained/);
  page.destroy();
  // A script error never shows its own words.
  const broken = pageWith({ openPlayer: player.open, correct: async () => { throw new TypeError('x is undefined'); } });
  await settle();
  tileOf(broken.el, 'u1').click();
  await settle();
  const again = player.opened.at(-1).details;
  button(again, 'Plane').click();
  await settle();
  assert.match(shown(again), /That didn’t save\. Try again in a moment\./);
  assert.doesNotMatch(shown(again), /undefined/);
  broken.page.destroy();
});

test('the correction goes to the bridge as POST sky/cameras/:id/entries/:eid/correction {night, label}', async () => {
  const sent = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    sent.push({ url, method: init.method, body: init.body ? JSON.parse(init.body) : null });
    const body = { ...UNEXPLAINED(), correction: 'bird', display: 'bird' };
    return { status: 200, ok: true, json: async () => body, text: async () => JSON.stringify(body), headers: { get: () => 'application/json' } };
  };
  try {
    const player = playerSpy();
    const page = mod.createSkyLogPage({ cameraID: SKY, load: async () => night(), now: () => NOW, cameras: () => [northSky()], onCameras: () => () => {}, zone: () => CHICAGO,
      plugin: () => true, setup: () => null, openPlayer: player.open, createObserver: null, frame: () => 0, remember: memory() });
    await settle();
    tileOf(page.el, 'u1').click();
    await settle();
    button(player.opened[0].details, 'Bird').click();
    await settle();
    assert.deepEqual(sent, [{ url: `/api/v1/sky/cameras/${SKY}/entries/u1/correction`, method: 'POST', body: { night: '2026-10-24', label: 'bird' } }]);
    assert.match(shown(player.opened[0].details), /You said: bird\./);
    page.destroy();
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('a light that is not a moving track reads as what it is', async () => {
  const flash = raw('f1', 'unexplained', chicago(1, 0), { kind: 'flash', path: [{ t: 0, x: 0.5, y: 0.3 }], measures: { azimuth: 10, elevation: 6, duration: 0.4, blinks: true, blinkRate: 2, shape: 'straight', speed: 0 } });
  const rising = raw('n1', 'unexplained', chicago(2, 0), { kind: 'newLight', path: [{ t: 0, x: 0.5, y: 0.3 }], measures: { azimuth: 350, elevation: 22, duration: 9, blinks: false, shape: 'curved', speed: 0 } });
  const player = playerSpy();
  const { page, el } = pageWith({ log: night({ entries: [flash, rising], counts: { ...NONE, unexplained: 2 } }), openPlayer: player.open });
  await settle();
  assert.deepEqual(tiles(el).map((card) => byClass(card, 'sky-tile-line')[0].textContent), ['North, 6° up · blinks', 'North, 22° up · new light']);
  tileOf(el, 'f1').click();
  await settle();
  const a = shown(player.opened[0].details);
  player.opened[0].onClose();
  tileOf(el, 'n1').click();
  await settle();
  const b = shown(player.opened[1].details);
  assert.equal(player.opened[0].what, 'Flash · North Sky');
  assert.equal(player.opened[1].what, 'New light · North Sky');
  assert.match(a, /Blinks about 2 times a second/);
  assert.match(a, /under a second/);
  assert.match(b, /9 seconds/);
  assert.doesNotMatch(`${a} ${b}`, /Curved|Straight/, 'no path shape for a light that does not move');
  assert.doesNotMatch(`${a} ${b}`, /faster|slower/, 'and no speed');
  page.destroy();
});

// MARK: The strip

test('the night is a strip from sunset to sunrise with a dot for each light, the unexplained larger and glowing, and its hours to tap', async () => {
  const { page, el } = pageWith();
  await settle();
  const strip = byClass(el, 'sky-strip')[0];
  assert.equal(tag(strip, 'svg').length, 1);
  assert.match(tag(strip, 'svg')[0].getAttribute('aria-label'), /1 unexplained, 3 planes, 5 satellites, 1 meteor, 2 bugs and birds/);
  const dots = byClass(strip, 'sky-dot');
  assert.equal(dots.length, 12, 'one for each entry');
  const kinds = (kind) => dots.filter((dot) => dot.className.includes(`sky-dot--${kind}`));
  assert.deepEqual(['unexplained', 'planes', 'satellites', 'meteors', 'bugsAndBirds'].map((kind) => kinds(kind).length), [1, 3, 5, 1, 2]);
  assert.ok(Number(kinds('unexplained')[0].getAttribute('r')) > Number(kinds('planes')[0].getAttribute('r')), 'larger');
  assert.equal(byClass(strip, 'sky-halo').length, 1, 'and one glowing');
  const x = (dot) => Number(dot.getAttribute('cx'));
  assert.ok(x(kinds('satellites')[0]) < x(kinds('unexplained')[0]), 'time runs left to right');
  assert.equal(byClass(strip, 'sky-band--notVisible').length, 1, 'the sky not visible is shaded');
  assert.equal(byClass(strip, 'sky-band--clear').length, 0, 'a clear sky is not');
  const ticks = byClass(el, 'sky-tick');
  assert.deepEqual(ticks.map((node) => node.textContent), ['10 PM', '12 AM', '2 AM', '4 AM'], 'the hours in the box’s zone');
  assert.ok(ticks.every((node) => node.localName === 'button'), 'each a button: a tap (or a key) goes there');
  assert.equal(ticks[0].getAttribute('aria-label'), 'Go to 10 PM');
  assert.match(shown(byClass(el, 'sky-ends')[0]), /6:32 PM.*7:21 AM/);
  // The filters fade what they leave out of the strip too.
  chip(el, 'unexplained').click();
  await settle();
  assert.equal(byClass(strip, 'sky-dot').filter((dot) => dot.classList.contains('is-out')).length, 11);
  assert.equal(byClass(strip, 'sky-dot').length, 12, 'every light is still there');
  page.destroy();
});

test('tapping a time on the strip brings its hour into view, its cards made', async () => {
  const scrolled = [];
  FakeElement.prototype.scrollIntoView = function scrollIntoView(options) { scrolled.push([this, options]); };
  try {
    const { page, el, observer } = pageWith({ log: busyNight(900) });
    await settle();
    const sections = byClass(el, 'sky-hour');
    const twoAM = sections.find((section) => shown(byClass(section, 'sky-hour-head')[0]).startsWith('2 AM'));
    assert.ok(twoAM, 'there is a 2 AM');
    assert.equal(tiles(twoAM).length, 0, 'not made before it is needed');
    assert.ok(tiles(el).length <= 60, 'only the first cards of the night');
    button(el, '2 AM').click();
    await settle();
    assert.ok(tiles(twoAM).length > 0, 'its cards are made');
    assert.equal(tiles(twoAM).length, Math.min(60, Number(/(\d+) lights/.exec(shown(twoAM))[1])));
    assert.ok(scrolled.at(-1)?.[0] === twoAM, 'and it is brought to the top, under the dock');
    assert.deepEqual(scrolled.at(-1)[1], { block: 'start', behavior: 'auto' });
    assert.ok(observer.targets.size > 0, 'the rest come as the person scrolls');
    page.destroy();

    // In an order that is not by time there are no hours: a tap goes back to the night's own order and to that hour.
    const flat = pageWith({ log: busyNight(300), query: 'sort=longest' });
    await settle();
    assert.equal(byClass(flat.el, 'sky-hour-head').length, 0);
    button(flat.el, '2 AM').click();
    await settle();
    assert.equal(sortMenu(flat.el).value, 'oldest');
    assert.ok(byClass(flat.el, 'sky-hour-head').length > 0);
    assert.equal(flat.calls.addresses.at(-1), `sky/${SKY}`, 'the night’s own order says nothing in the address');
    flat.page.destroy();
  } finally {
    delete FakeElement.prototype.scrollIntoView;
  }
});

test('an hour with more lights than the box logs says so at its heading', async () => {
  const capped = [{ hour: chicago(22, 0, 24), count: 212 }, { hour: chicago(5, 0), count: 1 }];
  const { page, el } = pageWith({ log: night({ capped }) });
  await settle();
  const ten = byClass(el, 'sky-hour').find((section) => shown(section).startsWith('10 PM'));
  assert.equal(byClass(ten, 'sky-hour-note')[0].textContent, '212 more lights weren’t logged (busy hour)');
  assert.equal(byClass(el, 'sky-hour-note').length, 1, 'an hour with no light shown has no heading to say it at');
  // An order with no hours: the notes over the grid, with their hours.
  await pick(sortMenu(el), 'longest');
  assert.deepEqual(byClass(el, 'sky-capped-hour').map((node) => node.textContent),
    ['10 PM: 212 more lights weren’t logged (busy hour)', '5 AM: 1 more light wasn’t logged (busy hour)']);
  page.destroy();
  for (const extra of [{ capped: [] }, {}]) {
    const plain = pageWith({ log: night(extra) });
    await settle();
    assert.equal(byClass(plain.el, 'sky-hour-note').length + byClass(plain.el, 'sky-capped').length, 0, 'a night without one, and a bridge from before, say nothing');
    plain.page.destroy();
  }
});

// MARK: Made as the person scrolls

test('the grid makes its first sixty cards, then sixty more each time the person scrolls near them, until every light is there', async () => {
  const { page, el, observer } = pageWith({ log: busyNight(330) });
  await settle();
  assert.equal(observer.made, 2, 'one observer to make the cards near the screen, one to give back those far from it');
  assert.equal(observer.options.rootMargin, '1600px 0px', 'made well before they come on the screen');
  const first = tiles(el).length;
  assert.ok(first > 0 && first <= 60, `a first batch of sixty at most: ${first}`);
  assert.ok(byClass(el, 'sky-pending').length > 0, 'the rest hold their place');
  const counts = [first];
  while (observer.scroll()) {
    await settle();
    counts.push(tiles(el).length);
  }
  assert.equal(tiles(el).length, 330, 'every one in the end');
  assert.ok(counts.slice(1).every((value, i) => value > counts[i] && value - counts[i] <= 60), `no more than sixty at a time: ${counts}`);
  assert.equal(byClass(el, 'sky-pending').length, 0);
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), Array.from({ length: 330 }, (_, i) => `e${String(i).padStart(4, '0')}`), 'in the night’s order');
  assert.equal(all(el, (node) => node.localName === 'button' && /Show more/.test(node.textContent)).length, 0, 'and no Show more');
  // A block that goes away again before it was made is not made.
  const second = pageWith({ log: busyNight(200) });
  await settle();
  const holder = [...second.observer.targets][0];
  const before = tiles(second.el).length;
  second.observer.away(holder);
  assert.equal(tiles(second.el).length, before);
  second.page.destroy();
  page.destroy();
});

test('cards far from the screen are given back to a block as tall as they were, and made again when the person comes back', async () => {
  // The cards measured as a browser would lay them out: six columns of 200 × 180 px with 12 px between them. (Elements are compared by their
  // ids below: a failed comparison of two elements would print the whole page.)
  const realStyle = globalThis.getComputedStyle;
  const realBox = FakeElement.prototype.getBoundingClientRect;
  globalThis.getComputedStyle = () => ({ columnGap: '12px', rowGap: '12px', position: 'static' });
  FakeElement.prototype.getBoundingClientRect = function box() {
    if (this.classList?.contains('sky-tile')) return { x: 0, y: 0, left: 0, top: 0, right: 200, bottom: 180, width: 200, height: 180 };
    if (this.classList?.contains('sky-tiles')) return { x: 0, y: 0, left: 0, top: 0, right: 1272, bottom: 900, width: 1272, height: 900 };
    return realBox.call(this);
  };
  const focusTo = (target) => Object.defineProperty(document, 'activeElement', { value: target, configurable: true });
  const player = playerSpy();
  const { page, el, observer } = pageWith({ log: busyNight(400), openPlayer: player.open });
  document.append(el);   // on the page: the cards can be measured
  try {
    await settle();
    for (let i = 0; i < 40 && observer.scroll(); i += 1) await settle();
    assert.equal(tiles(el).length, 400);
    const [first, last] = [...observer.ends].slice(0, 2);
    const ids = tiles(el).slice(tiles(el).indexOf(first), tiles(el).indexOf(last) + 1).map((card) => card.dataset.entry);
    assert.ok(ids.length > 1, 'the first batch’s first and last cards are watched');

    // The focus is on one of its cards (a player was closed on it): it is kept.
    focusTo(first);
    observer.far([first, last]);
    assert.equal(tileOf(el, ids[0])?.dataset.entry, ids[0], 'not while it has the focus');
    focusTo(document.body);
    observer.far([first, last]);
    assert.equal(Boolean(tileOf(el, ids[0])), false, 'given back');
    assert.equal(tiles(el).length, 400 - ids.length);
    const holder = byClass(el, 'sky-pending')[0];
    assert.equal(holder?.style.height, `${Math.ceil(ids.length / 6) * 192 - 12}px`, 'a block exactly as tall as its rows were');
    assert.equal(observer.targets.has(holder), true, 'made again when it comes near');
    assert.equal(observer.ends.has(first), false, 'no longer watched');
    assert.equal(byClass(el, 'sky-tiles')[0].childNodes.indexOf(holder), 0, 'in its own place');

    // The person comes back: the same lights, in the same place.
    observer.near(holder);
    await settle();
    assert.deepEqual(tiles(el).slice(0, ids.length).map((card) => card.dataset.entry), ids);
    assert.equal(tiles(el).length, 400);
    assert.equal(byClass(el, 'sky-pending').length, 0);
    assert.equal(observer.ends.has(tileOf(el, ids[0])), true, 'and watched again');
  } finally {
    globalThis.getComputedStyle = realStyle;
    FakeElement.prototype.getBoundingClientRect = realBox;
    delete document.activeElement;
    el.remove();
    page.destroy();
  }
});

test('a night of 2,600 lights draws its first cards at once and no more, quickly', async () => {
  const log = busyNight(2600);
  const started = performance.now();
  const { page, el, observer } = pageWith({ log });
  await settle();
  const took = performance.now() - started;
  assert.equal(tiles(el).length, 60, 'sixty cards, not 2,600');
  assert.ok(byClass(el, 'sky-hour').length >= 12, 'every hour has its heading at once');
  assert.ok(observer.targets.size >= 40, 'the rest wait for the person');
  assert.ok(took < 1500, `drawn in ${Math.round(took)} ms`);
  assert.deepEqual(chipText(el).slice(0, 2), ['All 2,600 *', 'Unexplained 520']);
  assert.match(shown(byClass(el, 'sky-summary')[0]), /Last night: 520 unexplained, 2,080 explained/);
  page.destroy();
});

test('the hours are the box’s own: newest first while the night is still going, and a day’s hours in the day view', async () => {
  // At 1:50 AM the night is still going: the newest first.
  const going = night({ serverTime: chicago(1, 50), entries: entriesOfANight().filter((entry) => entry.start < chicago(1, 50)) });
  const { page, el } = pageWith({ log: going, now: () => chicago(1, 50) });
  await settle();
  assert.match(shown(el), /Tonight so far/);
  assert.equal(sortMenu(el).value, 'newest');
  assert.deepEqual(hours(el).map((head) => head.split(' ').slice(0, 2).join(' ')), ['1 AM', '11 PM', '10 PM', '9 PM', '8 PM', '7 PM']);
  assert.deepEqual(tiles(byClass(el, 'sky-hour')[2]).map((card) => card.dataset.entry), ['g1', 'b1'], 'the newest first inside an hour too');
  page.destroy();

  const day = (request) => night({ view: 'day', night: '2026-10-24', from: chicago(0, 0, 24), to: chicago(0, 0, 25), serverTime: NOW,
    entries: [raw('d1', 'plane', chicago(9, 15, 24), { detail: 'AAL1 · 30,000 ft' }), raw('d2', 'bird', chicago(14, 40, 24)), raw('d3', 'plane', chicago(14, 5, 24))],
    counts: { ...NONE, planes: 2, bugsAndBirds: 1, explained: 3 } });
  const daily = pageWith({ log: day, query: 'view=day' });
  await settle();
  assert.deepEqual(hours(daily.el), ['9 AM 1 light', '2 PM 2 lights'], 'a past day reads from its morning');
  daily.page.destroy();
});

// MARK: The filters

test('kind chips: several at once, each with its count; Corrected by you; All clears them', async () => {
  const entries = [...entriesOfANight(), raw('c1', 'plane', chicago(0, 20), { correction: 'notSure', detail: 'XYZ1 · 30,000 ft' }), raw('c2', 'unexplained', chicago(4, 2), { correction: 'bird', display: 'bird' })];
  const { page, el, calls } = pageWith({ log: night({ entries, counts: undefined }) });
  await settle();
  assert.deepEqual(chipText(el), ['All 14 *', 'Unexplained 1', 'High priority 0', 'Planes 3', 'Satellites 5', 'Meteors 1', 'Bugs & birds 3', 'Corrected by you 2']);
  chip(el, 'planes').click();
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['p1', 'p2', 'p3'], 'planes, the probable one with them');
  assert.equal(chip(el, 'all').getAttribute('aria-pressed'), 'false');
  chip(el, 'satellites').click();
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['s0', 's1', 's2', 's3', 's4', 'p1', 'p2', 'p3'], 'several at once: any of them');
  assert.deepEqual(chipText(el), ['All 14', 'Unexplained 1', 'High priority 0', 'Planes 3 *', 'Satellites 5 *', 'Meteors 1', 'Bugs & birds 3', 'Corrected by you 2'],
    'the counts are the night’s');
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?kinds=planes,satellites`);
  chip(el, 'planes').click();
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['s0', 's1', 's2', 's3', 's4'], 'a second tap turns a chip off');
  chip(el, 'all').click();
  await settle();
  assert.equal(tiles(el).length, 14, 'All clears them');
  assert.equal(chip(el, 'all').getAttribute('aria-pressed'), 'true');
  chip(el, 'corrected').click();
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['c1', 'c2'], 'what the person said something about');
  assert.deepEqual(tiles(el).map((card) => byClass(card, 'sky-tile-yours')[0].hidden), [false, false]);
  assert.deepEqual(tiles(el).map((card) => byClass(card, 'sky-tile-word')[0].textContent), ['Not sure', 'Bird']);
  chip(el, 'bugs').click();
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['b1', 'g1', 'c1', 'c2'], 'bugs and birds with the corrected ones');
  page.destroy();
});

// MARK: The guide to the unexplained

/** A night with the guide: unexplained lights ranked high, medium and low, three that moved together, one logged before the guide, a probable
 * satellite and a plane. */
function guidedNight() {
  const why = (priority, reasons, extra = {}) => ({ priority, reasons, ...extra });
  const entries = [
    raw('l1', 'unexplained', chicago(20, 0, 24), why('low', ['Too short to tell a plane from a satellite'])),
    raw('h1', 'unexplained', chicago(21, 0, 24), why('high', ['Fast across the sky (about 6× a plane at that height)', 'Looks larger than typical planes'])),
    raw('m1', 'unexplained', chicago(22, 0, 24), why('medium', ['Long, low and steady, but not like a plane or a satellite'])),
    raw('g1', 'unexplained', chicago(23, 0, 24), why('high', ['Several lights moving together', 'Stopped suddenly'], { group: 'g-g1' })),
    raw('g2', 'unexplained', chicago(23, 0, 24) + 4000, why('high', ['Several lights moving together'], { group: 'g-g1' })),
    raw('g3', 'unexplained', chicago(23, 0, 24) + 9000, why('high', ['Several lights moving together'], { group: 'g-g1' })),
    raw('o1', 'unexplained', chicago(0, 30)),
    raw('ps', 'probableSatellite', chicago(19, 0, 24), { by: 'rule', detail: 'Probable satellite: a steady light at a steady speed (no orbit check yet)' }),
    raw('p1', 'plane', chicago(1, 0), { by: 'flight', detail: 'TEST123 · 35,000 ft' }),
  ];
  return night({ entries, counts: undefined });
}

test('an unexplained card shows its priority, High glowing in the unexplained colour, and its first reason; an explained one shows none', async () => {
  const { page, el } = pageWith({ log: guidedNight() });
  await settle();
  const badge = (id) => byClass(tileOf(el, id), 'sky-tile-priority')[0];
  const line = (id) => byClass(tileOf(el, id), 'sky-tile-line')[0].textContent;
  assert.deepEqual(['h1', 'm1', 'l1'].map((id) => [badge(id).dataset.priority, badge(id).textContent, badge(id).hidden]),
    [['high', 'High', false], ['medium', 'Medium', false], ['low', 'Low', false]]);
  assert.equal(line('h1'), 'Fast across the sky (about 6× a plane at that height)', 'its first reason');
  assert.equal(line('g2'), '2 of 3 moving together', 'a light that moved with others: which of them');
  assert.equal(tileOf(el, 'h1').getAttribute('aria-label'), '9:00:00 PM, Unexplained, High priority, 4.2 seconds, Fast across the sky (about 6× a plane at that height)');
  assert.ok(badge('o1').hidden && badge('p1').hidden && badge('ps').hidden, 'a light logged before the guide, and an explained one: no badge');
  assert.equal(line('o1'), 'Northwest, 8° up · straight', 'logged before the guide: where it was and how');
  assert.equal(byClass(tileOf(el, 'ps'), 'sky-tile-word')[0].textContent, 'Probable satellite');
  assert.equal(tileOf(el, 'ps').dataset.kind, 'satellites', 'in the satellites’ colour');
  // The badge's colours (sky.css): High in the unexplained colour, glowing as the strip's dots do; Medium plain; Low quiet.
  const css = readFileSync(new URL('../web/sky.css', import.meta.url), 'utf8');
  assert.match(css, /\.sky-tile-priority\[data-priority="high"\][^}]*var\(--sky-unexplained\)[^}]*box-shadow/);
  assert.match(css, /\.sky-tile-priority\[data-priority="low"\]/);
  // A correction to a bird takes its badge away; a correction back to not sure brings it back.
  page.destroy();
});

test('High priority is a chip and Priority an order; inside Unexplained the night opens by priority, then the newest', async () => {
  const { page, el, calls } = pageWith({ log: guidedNight() });
  await settle();
  const ids = () => tiles(el).map((card) => card.dataset.entry);
  assert.deepEqual(chipText(el).slice(0, 3), ['All 9 *', 'Unexplained 7', 'High priority 4']);
  chip(el, 'high').click();
  await settle();
  assert.deepEqual(ids(), ['g3', 'g2', 'g1', 'h1'], 'the high ones, by priority then the newest first');
  assert.equal(sortMenu(el).value, 'priority');
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?kinds=high`, 'the order is the filter’s own: not written');
  chip(el, 'high').click();
  await settle();
  chip(el, 'unexplained').click();
  await settle();
  assert.deepEqual(ids(), ['g3', 'g2', 'g1', 'h1', 'm1', 'l1', 'o1'], 'high, medium, low, then a light logged before the guide');
  assert.equal(byClass(el, 'sky-hour-head').length, 0, 'one grid, with no hours');
  await pick(sortMenu(el), 'oldest');
  assert.deepEqual(ids(), ['l1', 'h1', 'm1', 'g1', 'g2', 'g3', 'o1'], 'an order chosen wins');
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?kinds=unexplained&sort=oldest`);
  await pick(sortMenu(el), 'priority');
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?kinds=unexplained`, 'back to the filter’s own order: none chosen');
  // With every kind, Priority is an order like the others.
  chip(el, 'all').click();
  await settle();
  await pick(sortMenu(el), 'priority');
  assert.deepEqual(ids(), ['g3', 'g2', 'g1', 'h1', 'm1', 'l1', 'p1', 'o1', 'ps']);
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?sort=priority`);
  page.destroy();
});

test('a light the rules sorted later says so in the player, quietly, and nowhere else', async () => {
  const player = playerSpy();
  const sorted = raw('o2', 'probableSatellite', chicago(19, 30, 24), {
    by: 'rule', detail: 'Probable satellite: a steady light at a steady speed (no orbit check yet)', sortedLater: true });
  const ranked = raw('o3', 'unexplained', chicago(20, 30, 24), { priority: 'low', reasons: ['Too short to tell a plane from a satellite'], sortedLater: true });
  const { page, el } = pageWith({ log: night({ entries: [...guidedNight().entries, sorted, ranked], counts: undefined }), openPlayer: player.open });
  await settle();
  assert.equal(byClass(el, 'sky-sorted-later').length, 0, 'not on the cards');
  assert.equal(byClass(tileOf(el, 'o2'), 'sky-tile-word')[0].textContent, 'Probable satellite', 'the card shows what the rules say, as if logged so');
  tileOf(el, 'o2').click();
  await settle();
  const hint = byClass(player.opened[0].details, 'sky-sorted-later');
  assert.equal(hint.length, 1);
  assert.equal(hint[0].textContent, 'Sorted later');
  assert.match(hint[0].getAttribute('title'), /Logged before the rules/);
  assert.ok(hint[0].className.includes('small'), 'tiny');
  player.opened[0].onClose();
  await settle();
  tileOf(el, 'o3').click();
  await settle();
  assert.equal(byClass(player.opened[1].details, 'sky-sorted-later').length, 1, 'an unexplained one too');
  player.opened[1].onClose();
  await settle();
  tileOf(el, 'h1').click();
  await settle();
  assert.equal(byClass(player.opened[2].details, 'sky-sorted-later').length, 0, 'one the box logged with the rules says nothing of it');
  page.destroy();
});

test('the player lists every reason; a light that moved with others shows which of them it was, and a tap shows only them', async () => {
  const player = playerSpy();
  const { page, el, calls } = pageWith({ log: guidedNight(), openPlayer: player.open });
  await settle();
  tileOf(el, 'h1').click();
  await settle();
  const details = player.opened[0].details;
  const reasons = byClass(details, 'sky-reasons')[0];
  assert.match(shown(reasons), /High priority/);
  assert.deepEqual(tag(reasons, 'li').map((item) => item.textContent), ['Fast across the sky (about 6× a plane at that height)', 'Looks larger than typical planes']);
  player.opened[0].onClose();
  await settle();
  tileOf(el, 'g1').click();
  await settle();
  const groupDetails = player.opened[1].details;
  assert.deepEqual(tag(byClass(groupDetails, 'sky-reasons')[0], 'li').map((item) => shown(item).trim()), ['1 of 3 moving together', 'Stopped suddenly']);
  const together = byClass(groupDetails, 'sky-group-show')[0];
  assert.equal(together.localName, 'button');
  assert.equal(together.textContent, '1 of 3 moving together');
  together.click();
  await settle();
  assert.equal(player.closed, 1, 'the player closes');
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['g1', 'g2', 'g3'], 'only the lights that moved together');
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?group=g-g1`);
  const groupChip = chip(el, 'group');
  assert.ok(visible(groupChip) && groupChip.getAttribute('aria-pressed') === 'true');
  assert.match(shown(groupChip), /Moving together 3/);
  groupChip.click();
  await settle();
  assert.equal(tiles(el).length, 9, 'its chip takes it away again');
  assert.ok(!visible(chip(el, 'group')));
  assert.equal(calls.addresses.at(-1), `sky/${SKY}`);
  page.destroy();
  // Opened from an address with the group in it: only them.
  const again = pageWith({ log: guidedNight(), query: 'group=g-g1' });
  await settle();
  assert.deepEqual(tiles(again.el).map((card) => card.dataset.entry), ['g1', 'g2', 'g3']);
  chip(again.el, 'all').click();
  await settle();
  assert.equal(tiles(again.el).length, 9, 'All clears it too');
  again.page.destroy();
});

test('With picture shows only the lights with a still', async () => {
  const { page, el, calls } = pageWith({ log: busyNight(30) });
  await settle();
  assert.equal(tiles(el).length, 30);
  await tick(picturesBox(el), true);
  assert.equal(tiles(el).length, 20);
  assert.ok(tiles(el).every((card) => tag(card, 'img').length === 1), 'each with its picture');
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?pictures=1`);
  chip(el, 'unexplained').click();
  await settle();
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['e0009', 'e0010', 'e0019', 'e0020', 'e0029'].filter((id) => Number(id.slice(1)) % 3 !== 0), 'and with the chips');
  await tick(picturesBox(el), false);
  assert.equal(tiles(el).length, 6);
  page.destroy();
});

test('each order: the newest or the oldest first under their hours, and the longest or the fastest in one grid', async () => {
  const entries = [
    raw('a', 'plane', chicago(20, 5, 24), { measures: { azimuth: 10, elevation: 30, duration: 40, speed: 1.2 } }),
    raw('b', 'unexplained', chicago(3, 12), { measures: { azimuth: 312, elevation: 8, duration: 4.2, speed: 6 } }),
    raw('c', 'satellite', chicago(19, 30, 24), { end: chicago(19, 30, 24) + 95_000, measures: { azimuth: 300, elevation: 40, speed: 0.5 } }),
    raw('d', 'meteor', chicago(1, 30), { measures: { azimuth: 200, elevation: 40, duration: 0.6 } }),
    raw('e', 'bug', chicago(22, 10, 24), { measures: { azimuth: 100, elevation: 20, duration: 2, speed: 6 } }),
  ];
  const { page, el, calls } = pageWith({ log: night({ entries, counts: undefined }) });
  await settle();
  const ids = () => tiles(el).map((card) => card.dataset.entry);
  assert.equal(sortMenu(el).value, 'oldest', 'a finished night reads from dusk');
  assert.deepEqual(all(sortMenu(el), (node) => node.localName === 'option').map((node) => node.textContent),
    ['Newest first', 'Oldest first', 'Priority', 'Longest', 'Fastest across the sky']);
  assert.deepEqual(ids(), ['c', 'a', 'e', 'd', 'b']);
  await pick(sortMenu(el), 'newest');
  assert.deepEqual(ids(), ['b', 'd', 'e', 'a', 'c']);
  assert.deepEqual(hours(el).map((head) => head.split(' ').slice(0, 2).join(' ')), ['3 AM', '1 AM', '10 PM', '8 PM', '7 PM']);
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?sort=newest`);
  await pick(sortMenu(el), 'longest');
  assert.deepEqual(ids(), ['c', 'a', 'b', 'e', 'd'], 'the longest first');
  assert.equal(byClass(el, 'sky-hour-head').length, 0, 'one grid, with no hours');
  await pick(sortMenu(el), 'fastest');
  assert.deepEqual(ids(), ['e', 'b', 'a', 'c', 'd'], 'the fastest across the sky first (a tie by time); the meteor has no speed: last');
  assert.equal(byClass(el, 'sky-hour-head').length, 0);
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?sort=fastest`);
  // Back to the night's own order: kept as none chosen, so a night still going opens with its newest first.
  await pick(sortMenu(el), 'oldest');
  assert.equal(calls.addresses.at(-1), `sky/${SKY}`);
  assert.deepEqual(ids(), ['c', 'a', 'e', 'd', 'b']);
  page.destroy();
});

test('the filters and the order are kept in the address, and a page opened from it has them again', async () => {
  const { page, el, calls, remember } = pageWith({ log: busyNight(40) });
  await settle();
  chip(el, 'unexplained').click();
  await settle();
  chip(el, 'planes').click();
  await settle();
  await pick(sortMenu(el), 'fastest');
  await tick(picturesBox(el), true);
  const address = calls.addresses.at(-1);
  assert.equal(address, `sky/${SKY}?kinds=unexplained,planes&sort=fastest&pictures=1`);
  assert.deepEqual(remember.box.value, { kinds: ['unexplained', 'planes'], sort: 'fastest', pictures: true }, 'and in this browser');
  const shownBefore = tiles(el).map((card) => card.dataset.entry);
  page.destroy();

  // A reload, or Back to it: the address has them.
  const again = pageWith({ log: busyNight(40), query: address.split('?')[1] });
  await settle();
  assert.deepEqual(chipText(again.el).filter((text) => text.endsWith('*')).map((text) => text.split(' ')[0]), ['Unexplained', 'Planes']);
  assert.equal(sortMenu(again.el).value, 'fastest');
  assert.equal(picturesBox(again.el).checked, true);
  assert.deepEqual(tiles(again.el).map((card) => card.dataset.entry), shownBefore);
  assert.equal(again.calls.addresses[0], address, 'the address stays as it was');
  again.page.destroy();

  // An address with a night: its filters come with it.
  const dated = pageWith({ log: busyNight(40), query: 'night=2026-10-22&view=day&kinds=meteors' });
  await settle();
  assert.deepEqual(dated.calls.loads, [{ cameraID: SKY, night: '2026-10-22', view: 'day' }]);
  assert.equal(dated.calls.addresses[0], `sky/${SKY}?night=2026-10-22&view=day&kinds=meteors`);
  assert.ok(tiles(dated.el).every((card) => card.dataset.kind === 'meteors'));
  dated.page.destroy();
});

test('this browser remembers the filters: a page opened with none in its address has them, and the address says so', async () => {
  const kept = memory({ kinds: ['satellites'], sort: 'newest', pictures: false });
  const { page, el, calls } = pageWith({ remember: kept });
  await settle();
  assert.equal(calls.addresses[0], `sky/${SKY}?kinds=satellites&sort=newest`);
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['s4', 's3', 's2', 's1', 's0']);
  page.destroy();
  // The address wins over the memory.
  const told = pageWith({ remember: kept, query: 'kinds=meteors' });
  await settle();
  assert.deepEqual(tiles(told.el).map((card) => card.dataset.entry), ['m1']);
  told.page.destroy();
  // A memory that is not one is nothing.
  const odd = pageWith({ remember: memory({ kinds: 'lots', sort: 'sideways', pictures: 'yes' }) });
  await settle();
  assert.equal(odd.calls.addresses[0], `sky/${SKY}`);
  assert.equal(tiles(odd.el).length, 12);
  odd.page.destroy();
});

test('the memory is this browser’s localStorage, and a browser that keeps nothing still works', async () => {
  const realStorage = globalThis.localStorage;
  const base = { cameraID: SKY, load: async () => night(), now: () => NOW, cameras: () => [northSky()], onCameras: () => () => {}, zone: () => CHICAGO, plugin: () => true,
    setup: () => null, createObserver: null, frame: () => 0 };
  try {
    globalThis.localStorage = makeStorage();
    const page = mod.createSkyLogPage(base);
    await settle();
    chip(page.el, 'meteors').click();
    await settle();
    assert.deepEqual(JSON.parse(globalThis.localStorage.getItem('cb.sky.grid')), { kinds: ['meteors'], sort: null, pictures: false });
    page.destroy();
    const next = mod.createSkyLogPage(base);
    await settle();
    assert.deepEqual(tiles(next.el).map((card) => card.dataset.entry), ['m1'], 'the next visit opens as it was left');
    next.destroy();

    globalThis.localStorage = makeStorage({ broken: true });
    const blocked = mod.createSkyLogPage(base);
    await settle();
    assert.equal(tiles(blocked.el).length, 12);
    chip(blocked.el, 'planes').click();
    await settle();
    assert.equal(tiles(blocked.el).length, 3, 'the filters work without it');
    blocked.destroy();
  } finally {
    globalThis.localStorage = realStorage;
  }
});

test('nothing left after the filters: a friendly line and Clear filters, which brings every light back', async () => {
  const calm = night({ entries: entriesOfANight().filter((entry) => entry.label !== 'unexplained'), counts: { ...COUNTS, unexplained: 0 } });
  const { page, el, calls } = pageWith({ log: calm, query: 'kinds=unexplained' });
  await settle();
  assert.equal(tiles(el).length, 0);
  assert.match(shown(el), /Nothing unexplained\. Everything that crossed the sky was a plane, a satellite, a meteor, a bug or a bird\./);
  const clear = button(el, 'Clear filters');
  assert.ok(clear && visible(clear));
  clear.click();
  await settle();
  assert.equal(tiles(el).length, 11, 'every light again');
  assert.equal(chip(el, 'all').getAttribute('aria-pressed'), 'true');
  assert.equal(calls.addresses.at(-1), `sky/${SKY}`);
  chip(el, 'meteors').click();
  await settle();
  await tick(picturesBox(el), true);
  assert.match(shown(byClass(el, 'sky-results')[0]), /No lights match these filters\./);
  assert.ok(button(el, 'Clear filters'));
  chip(el, 'all').click();
  await settle();
  assert.match(shown(byClass(el, 'sky-results')[0]), /None of these lights has a picture\./);
  button(el, 'Clear filters').click();
  await settle();
  assert.equal(picturesBox(el).checked, false);
  assert.equal(tiles(el).length, 11);
  page.destroy();
});

test('the page fits a phone: two columns at 375 px, the dock under the page’s own bar, and nothing wider than the window (sky.css)', () => {
  const css = readFileSync(new URL('../web/sky.css', import.meta.url), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
  /** The rules of a block: '@media (max-width: 640px)' blocks joined, or the top level. */
  const blocks = (head) => {
    const out = [];
    for (let at = css.indexOf(head); at >= 0; at = css.indexOf(head, at + 1)) {
      let depth = 0;
      let i = css.indexOf('{', at);
      const start = i + 1;
      for (; i < css.length; i += 1) { if (css[i] === '{') depth += 1; else if (css[i] === '}' && --depth === 0) break; }
      out.push(css.slice(start, i));
    }
    return out.join('\n');
  };
  const phone = blocks('@media (max-width: 640px)');
  const rule = (text, selector) => new RegExp(`(?:^|[}\\s])${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^}]*)\\}`).exec(text)?.[1] ?? '';
  // 375 px: the gutter is 16 px each side, so 343 px for two columns of cards that can be as narrow as they need.
  assert.match(rule(phone, '.sky-tiles'), /grid-template-columns:\s*repeat\(2,\s*minmax\(0,\s*1fr\)\)/);
  // On a desktop: columns of at least 200 px, never more than six (sixty cards a batch fill whole rows).
  assert.match(rule(css, '.sky-tiles'), /grid-template-columns:\s*repeat\(auto-fill,\s*minmax\(max\(200px,\s*calc\(\(100% - 60px\) \/ 6\)\),\s*1fr\)\)/);
  assert.match(rule(css, '.sky-tiles'), /gap:\s*12px/);
  assert.match(rule(css, '.sky-page'), /max-width:\s*1440px/);
  // A card never makes its column wider: its words are cut with an ellipsis, its picture is 16:9 inside it.
  assert.match(rule(css, '.sky-tile'), /min-width:\s*0/);
  assert.match(rule(css, '.sky-tile-when, .sky-tile-line'), /white-space:\s*nowrap;[^}]*text-overflow:\s*ellipsis/);
  assert.match(rule(css, '.sky-tile-pic'), /aspect-ratio:\s*16 \/ 9/);
  // The chips scroll sideways inside their own row (the page does not), and the dock reaches only across the page's own margins.
  assert.match(rule(phone, '.sky-chip-row'), /flex-wrap:\s*nowrap;\s*overflow-x:\s*auto/);
  assert.match(rule(phone, '.sky-page'), /--sky-bleed:\s*var\(--gutter\)/);
  assert.match(rule(css, '.sky-dock'), /position:\s*sticky;\s*top:\s*var\(--sky-top,\s*0px\)/);
  assert.match(rule(css, '.sky-dock'), /margin:\s*0 calc\(-1 \* var\(--sky-bleed\)\);\s*padding:\s*10px var\(--sky-bleed\)/);
  assert.doesNotMatch(css, /\b100vw\b/, 'nothing as wide as the window plus its scroll bar');
  for (const [, selector, width] of css.matchAll(/([.\w-]+)\s*\{[^}]*?\bmin-width:\s*(\d+)px/g)) {
    if (selector.startsWith('.sky-') && !selector.startsWith('.sky-player')) assert.ok(Number(width) <= 343, `${selector} is at most as wide as a phone’s page (${width} px)`);
  }
  // The path over a still has its own look (a card's and the player's): its line, where it began and where it ended.
  for (const selector of ['.sky-path', '.sky-path-line', '.sky-mark', '.sky-mark--end']) assert.ok(rule(css, selector), `${selector} is styled`);
  assert.match(rule(css, '.sky-mark'), /fill:\s*none;\s*stroke:\s*#fff/);
  // The hours and a jump stop under the dock.
  assert.match(rule(css, '.sky-hour'), /scroll-margin-top:\s*calc\(var\(--sky-top, 0px\) \+ var\(--sky-dock-h, 0px\) \+ 4px\)/);
});

// MARK: Past nights, days and cameras

test('past nights and days are a tap away: Earlier, Later, Night and Day', async () => {
  const log = (request) => {
    const date = request.night ?? '2026-10-24';
    const offset = (Date.parse(`${date}T00:00:00Z`) - Date.parse('2026-10-24T00:00:00Z'));
    return night({ night: date, view: request.view, from: FROM + offset, to: TO + offset, serverTime: NOW, entries: [], counts: { ...NONE } });
  };
  const { page, el, calls } = pageWith({ log });
  await settle();
  assert.match(shown(el), /Last night: 0 unexplained, 0 explained/);
  assert.match(shown(el), /Nothing crossed the sky in this time\./);
  assert.equal(byClass(el, 'sky-filters')[0].hidden, true, 'no filters for a night with nothing');
  assert.equal(button(el, 'Later').getAttribute('aria-disabled'), 'true', 'nothing after the latest night');
  assert.equal(button(el, 'Night').getAttribute('aria-pressed'), 'true');
  assert.equal(button(el, 'Day').getAttribute('aria-pressed'), 'false');
  assert.match(shown(byClass(el, 'sky-when')[0]), /Night of Sat, Oct 24/);

  button(el, 'Earlier').click();
  await settle();
  assert.deepEqual(calls.loads.at(-1), { cameraID: SKY, night: '2026-10-23', view: 'night' });
  assert.deepEqual(calls.addresses.at(-1), `sky/${SKY}?night=2026-10-23`);
  assert.match(shown(el), /Night of Fri, Oct 23: 0 unexplained, 0 explained/, 'not “last night” any more');
  assert.equal(button(el, 'Later').getAttribute('aria-disabled'), null, 'and there is a later one');
  button(el, 'Earlier').click();
  await settle();
  assert.deepEqual(calls.loads.at(-1), { cameraID: SKY, night: '2026-10-22', view: 'night' });

  button(el, 'Later').click();
  await settle();
  button(el, 'Later').click();
  await settle();
  assert.deepEqual(calls.loads.at(-1), { cameraID: SKY, night: '2026-10-24', view: 'night' });
  assert.match(shown(el), /Last night:/, 'back on the latest');
  assert.equal(calls.addresses.at(-1), `sky/${SKY}`, 'the address is plain again');

  // The day view: the same date, then the latest again.
  button(el, 'Day').click();
  await settle();
  assert.deepEqual(calls.loads.at(-1), { cameraID: SKY, night: null, view: 'day' });
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?view=day`);
  assert.equal(button(el, 'Day').getAttribute('aria-pressed'), 'true');
  button(el, 'Earlier').click();
  await settle();
  assert.deepEqual(calls.loads.at(-1), { cameraID: SKY, night: '2026-10-23', view: 'day' });
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?night=2026-10-23&view=day`);
  assert.match(shown(el), /Fri, Oct 23: 0 unexplained, 0 explained/);
  button(el, 'Night').click();
  await settle();
  assert.deepEqual(calls.loads.at(-1), { cameraID: SKY, night: '2026-10-23', view: 'night' }, 'the same date in the night view');
  page.destroy();
});

test('another night keeps the filters and the order', async () => {
  const log = (request) => night({ night: request.night ?? '2026-10-24' });
  const { page, el, calls } = pageWith({ log });
  await settle();
  chip(el, 'satellites').click();
  await settle();
  await pick(sortMenu(el), 'newest');
  button(el, 'Earlier').click();
  await settle();
  assert.equal(calls.addresses.at(-1), `sky/${SKY}?night=2026-10-23&kinds=satellites&sort=newest`);
  assert.deepEqual(tiles(el).map((card) => card.dataset.entry), ['s4', 's3', 's2', 's1', 's0']);
  page.destroy();
});

test('the address names the night, the view and the entry', async () => {
  const { page, calls } = pageWith({ query: 'night=2026-10-22&view=day' });
  await settle();
  assert.deepEqual(calls.loads, [{ cameraID: SKY, night: '2026-10-22', view: 'day' }]);
  page.destroy();
  const junk = pageWith({ query: 'night=yesterday&view=week&entry=' });
  await settle();
  assert.deepEqual(junk.calls.loads, [{ cameraID: SKY, night: null, view: 'night' }], 'what is not a night or a view is the latest night');
  junk.page.destroy();
});

test('an entry named in the address is made, marked and brought into view, even when the filters would leave it out', async () => {
  const scrolled = [];
  FakeElement.prototype.scrollIntoView = function scrollIntoView(options) { scrolled.push([this, options]); };
  try {
    const { page, el, calls } = pageWith({ log: busyNight(600), query: 'entry=e0500' });
    await settle();
    await new Promise((resolve) => setTimeout(resolve, 5));
    const card = tileOf(el, 'e0500');
    assert.ok(card, 'its card is made, far down the night');
    assert.ok(card.classList.contains('sky-target'));
    assert.ok(scrolled.at(-1)?.[0] === card, 'brought into view');
    assert.deepEqual(scrolled.at(-1)[1], { block: 'center' });
    assert.equal(calls.addresses.at(-1), `sky/${SKY}`, 'the address no longer names it');
    page.destroy();

    const hidden = pageWith({ query: 'entry=u1', remember: memory({ kinds: ['planes'], sort: null, pictures: true }) });
    await settle();
    assert.ok(tileOf(hidden.el, 'u1')?.classList.contains('sky-target'), 'the filters are cleared to show it');
    assert.equal(chip(hidden.el, 'all').getAttribute('aria-pressed'), 'true');
    assert.equal(hidden.calls.addresses.at(-1), `sky/${SKY}`);
    hidden.page.destroy();
  } finally {
    delete FakeElement.prototype.scrollIntoView;
  }
});

test('a camera picker only when more than one camera watches the sky', async () => {
  const other = cameraOf(OTHER, 'Garden Sky');
  const quiet = cameraOf('0A1B2C3D-0000-4000-8000-000000000009', 'Porch', { skyDetector: { enabled: false } });
  const single = pageWith({ cameras: [northSky(), quiet] });
  await settle();
  assert.ok(all(single.el, (node) => node.localName === 'select' && !node.classList.contains('sky-sort-select')).every((select) => !visible(select)), 'one camera: nothing to pick');
  single.page.destroy();

  const { page, el, calls, listeners } = pageWith({ cameras: [northSky(), other, quiet], log: (request) => night({ camera: request.cameraID }) });
  await settle();
  const picker = all(el, (node) => node.localName === 'select')[0];
  assert.equal(picker.getAttribute('aria-label'), 'Camera');
  assert.deepEqual(all(picker, (node) => node.localName === 'option').map((option) => option.textContent), ['North Sky', 'Garden Sky'], 'those that watch the sky');
  assert.equal(picker.value, SKY);
  picker.value = OTHER;
  picker.dispatchEvent({ type: 'change', target: picker });
  await settle();
  assert.deepEqual(calls.loads.at(-1), { cameraID: OTHER, night: null, view: 'night' });
  assert.equal(calls.addresses.at(-1), `sky/${OTHER}`);
  assert.match(shown(el), /Sky log · Garden Sky/);
  assert.ok(listeners.size === 1, 'it listens for cameras that change');
  page.destroy();
  assert.equal(listeners.size, 0, 'and stops when the page goes');
});

test('with no camera in the address, the first that watches the sky is shown', async () => {
  const { page, el, calls } = pageWith({ cameraID: null, cameras: [cameraOf('0A1B2C3D-0000-4000-8000-000000000009', 'Porch', { skyDetector: { enabled: false } }), northSky()] });
  await settle();
  assert.deepEqual(calls.loads, [{ cameraID: SKY, night: null, view: 'night' }]);
  assert.match(shown(el), /Sky log · North Sky/);
  page.destroy();
});

// MARK: Learning, status, trouble

test('the box still learning is said at the top; the aim by lens and the stream are in the status, folded', async () => {
  const learning = { ready: false, planes: 12, satellites: 0 };
  const rough = { quality: 'rough', planes: 0, stars: 0, residualPixels: null, lenses: [], note: null };
  const { page, el } = pageWith({ log: night({ learning, aim: rough }), cameras: [northSky({ status: { connection: 'online', sky: { ...SKY_STATUS, aim: rough, learning } } })] });
  await settle();
  assert.match(shown(el), /Still learning this sky: 12 of 30 planes matched\. No alerts until then\./);
  const box = byClass(el, 'sky-status')[0];
  assert.equal(box.localName, 'details');
  assert.equal(box.open, false, 'folded, under the summary');
  assert.equal(shown(box).trim(), 'Status');
  box.open = true;
  const status = shown(box);
  assert.match(status, /Left lens: rough/);
  assert.match(status, /Right lens: rough/);
  assert.match(status, /Flight matching is loose until the aim is good\./);
  assert.match(status, /Watching the main stream at 1920 px, 5 pictures a second/);
  page.destroy();

  const ready = pageWith();
  await settle();
  assert.doesNotMatch(shown(ready.el), /Still learning/);
  const good = byClass(ready.el, 'sky-status')[0];
  good.open = true;
  assert.match(shown(good), /Left lens: good, 23 planes matched, 14 px/);
  assert.match(shown(good), /Right lens: precise, 214 stars matched, 1.8 px/);
  assert.doesNotMatch(shown(good), /Flight matching is loose/);
  ready.page.destroy();
});

test('Sky Watcher off for the camera is said, with the way to turn it on; its past nights can still be read', async () => {
  const { page, el } = pageWith({ cameras: [northSky({ skyDetector: { ...WATCHING, enabled: false } }), cameraOf(OTHER, 'Garden Sky')] });
  await settle();
  assert.match(shown(el), /Sky Watcher is off for this camera\./);
  assert.equal(link(el, 'Turn it on').getAttribute('href'), `#/camera/${SKY}`);
  assert.match(shown(el), /Last night: 1 unexplained, 11 explained/, 'the log is there');
  assert.equal(tiles(el).length, 12);
  page.destroy();
});

test('no camera watching the sky, a camera that was removed, a night with nothing, and a log that would not load', async () => {
  const none = pageWith({ cameraID: null, cameras: [cameraOf(OTHER, 'Garden Sky', { skyDetector: { enabled: false } })] });
  await settle();
  assert.equal(none.calls.loads.length, 0, 'nothing to ask for');
  assert.match(shown(none.el), /Turn on Sky Watcher in a camera’s settings/);
  assert.equal(link(none.el, 'Garden Sky').getAttribute('href'), `#/camera/${OTHER}`);
  none.page.destroy();

  const gone = pageWith({ cameraID: '0A1B2C3D-0000-4000-8000-0000000000FF', cameras: [northSky()] });
  await settle();
  assert.match(shown(gone.el), /This camera was removed/);
  assert.equal(gone.calls.loads.length, 0);
  gone.page.destroy();

  const empty = pageWith({ log: night({ entries: [], counts: { ...NONE }, conditions: [] }) });
  await settle();
  assert.match(shown(empty.el), /Last night: 0 unexplained, 0 explained/);
  assert.match(shown(empty.el), /Nothing crossed the sky in this time\./);
  assert.equal(button(empty.el, 'Clear filters'), undefined, 'nothing to clear');
  empty.page.destroy();

  let fail = true;
  const failing = pageWith({ log: () => (fail ? new ApiError(503, 'archive_unavailable', 'The recordings are still loading. Try again in a moment.') : night()) });
  await settle();
  assert.match(shown(failing.el), /The recordings are still loading\. Try again in a moment\./);
  fail = false;
  button(failing.el, 'Try again').click();
  await settle();
  assert.match(shown(failing.el), /Last night: 1 unexplained, 11 explained/);
  assert.equal(failing.calls.loads.length, 2);
  failing.page.destroy();
});

test('a picture the box made later from the recording is shown the next time the log is read', async () => {
  let reads = 0;
  const log = (request) => {
    reads += 1;
    // The box logged the light without a picture (no room then); by the next read it made one from the recording, and its log says so.
    const light = raw('u2', 'unexplained', chicago(2, 0), { hasStill: reads > 1 });
    return night({ night: request.night ?? '2026-10-24', entries: [light], counts: { ...NONE, unexplained: 1 } });
  };
  const { page, el } = pageWith({ log });
  await settle();
  assert.equal(tag(tiles(el)[0], 'img').length, 0);
  assert.equal(byClass(tiles(el)[0], 'sky-tile-pic')[0].dataset.view, 'none');
  button(el, 'Earlier').click();
  await settle();
  button(el, 'Later').click();
  await settle();
  assert.equal(tag(tiles(el)[0], 'img')[0]?.getAttribute('src'), `/api/v1/sky/cameras/${SKY}/entries/u2/still?night=2026-10-24&size=thumb`);
  page.destroy();
});

test('no text ever claims a real size or speed', async () => {
  const entries = [
    UNEXPLAINED(),
    raw('u2', 'unexplained', chicago(1, 0), { kind: 'newLight', measures: { azimuth: 0, elevation: 80, duration: 30, blinks: true, blinkRate: 0.2, shape: 'suddenStop' }, speedVsPlanes: 0.4, unusual: ['brighter', 'suddenStop'] }),
    raw('u3', 'unexplained', chicago(2, 0), { kind: 'flash', measures: { azimuth: 90, elevation: 3, duration: 0.2, blinks: true, blinkRate: 2.5, shape: 'sharpTurn' }, speedVsPlanes: 1 }),
    raw('p1', 'plane', chicago(20, 5, 24), { by: 'flight', detail: 'TEST123' }),
    raw('p2', 'probablePlane', chicago(21, 40, 24)),
    raw('s1', 'satellite', chicago(19, 10, 24), { by: 'orbit', detail: 'ISS (ZARYA)' }),
    raw('s2', 'satelliteFlare', chicago(19, 30, 24), { by: 'orbit' }),
    raw('m1', 'meteor', chicago(1, 30)),
    raw('b1', 'bird', chicago(22, 10, 24)),
    raw('g1', 'bug', chicago(22, 12, 24)),
    raw('n1', 'plane', chicago(23, 0, 24), { correction: 'notSure' }),
  ];
  const counts = { unexplained: 3, planes: 2, satellites: 2, meteors: 1, bugsAndBirds: 2, notSure: 1, explained: 8 };
  const player = playerSpy();
  const { page, el } = pageWith({ log: night({ entries, counts }), openPlayer: player.open,
    cameras: [northSky({ status: { connection: 'online', sky: { ...SKY_STATUS, aim: { quality: 'rough', planes: 0, stars: 0, residualPixels: null, lenses: [] }, learning: { ready: false, planes: 12, satellites: 0 } } } })] });
  await settle();
  const texts = [shown(el)];
  for (const card of tiles(el)) {
    card.click();
    await settle();
    texts.push(shown(player.opened.at(-1).details), player.opened.at(-1).what, card.getAttribute('aria-label'));
    player.opened.at(-1).onClose();
  }
  const text = texts.join(' ');
  assert.match(text, /Not sure/, 'every kind is on the page');
  assert.match(text, /Satellite flare/);
  assert.doesNotMatch(text, /km\/h|mph|metres|meters|feet tall|miles|\bkm\b|\bm\/s\b|knots|kilomet/i);
  assert.doesNotMatch(text, /Sky detector/i);
  page.destroy();
});

test('the log asks the bridge for the night, and a late answer for another night is not shown', async () => {
  const requests = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    requests.push(url);
    const body = url.includes('/settings') ? { timeZone: 'America/Chicago' } : night();
    return { status: 200, ok: true, json: async () => body, text: async () => JSON.stringify(body), headers: { get: () => 'application/json' } };
  };
  store.cameras.set(SKY, northSky());
  setPlugins([{ id: 'sky', enabled: true }]);
  try {
    const page = mod.renderSkyLog({ params: [SKY, 'night=2026-10-24&view=day'], setTitle() {} });
    await settle();
    assert.ok(requests.includes(`/api/v1/sky/cameras/${SKY}/night?date=2026-10-24&view=day`), requests.join(', '));
    page.destroy();
    requests.length = 0;
    const latest = mod.renderSkyLog({ params: [SKY, undefined], setTitle() {} });
    await settle();
    assert.ok(requests.includes(`/api/v1/sky/cameras/${SKY}/night?view=night`), requests.join(', '));
    latest.destroy();
  } finally {
    globalThis.fetch = realFetch;
    store.cameras.clear();
    setPlugins([]);
  }

  // Two quick taps on Earlier: only the newest answer is drawn, however late the first comes.
  const answers = [];
  const { page, el } = pageWith({ log: (request) => (request.night ? new Promise((resolve) => answers.push({ request, resolve })) : night()) });
  await settle();
  button(el, 'Earlier').click();
  button(el, 'Earlier').click();
  await settle();
  assert.equal(answers.length, 2);
  const newer = night({ night: '2026-10-22', entries: [], counts: { ...NONE } });
  const older = night({ night: '2026-10-23', entries: [], counts: { ...NONE, unexplained: 5 } });
  answers[1].resolve(newer);
  await settle();
  answers[0].resolve(older);
  await settle();
  assert.match(shown(el), /Night of Thu, Oct 22: 0 unexplained/);
  assert.doesNotMatch(shown(el), /5 unexplained/, 'the late answer is dropped');
  page.destroy();
});

test('the route reads the camera and the query from the address, and the page names itself Sky Watcher', async () => {
  const titles = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ status: 404, ok: false, json: async () => ({ error: 'not_found', message: 'nothing' }), text: async () => '', headers: { get: () => 'application/json' } });
  try {
    const route = mod.renderSkyLog({ params: [SKY, 'view=day&kinds=planes'], setTitle: (title) => titles.push(title) });
    assert.deepEqual(titles, ['Sky Watcher']);
    assert.equal(typeof route.destroy, 'function');
    assert.ok(route.el);
    route.destroy();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.ok(mod.SKY_ROUTE.test(`sky/${SKY}?entry=abc`));
  assert.ok(mod.SKY_ROUTE.test(`sky/${SKY}?kinds=unexplained,planes&sort=fastest&pictures=1`));
});

// MARK: The plugin

test('while the Sky Watcher plugin is off the page says so, with the way to Plugins, and asks the bridge for nothing', async () => {
  const off = pageWith({ plugin: false, cameras: [northSky()], setup: () => { throw new Error('no Setup panel while the plugin is off'); } });
  await settle();
  assert.equal(off.calls.loads.length, 0, 'no log is asked for');
  assert.equal(tag(off.el, 'h1')[0].textContent, 'Sky Watcher');
  const text = shown(off.el);
  assert.match(text, /Sky Watcher is off/);
  assert.match(text, /Switch it on in Plugins, then turn it on for a camera that looks at the sky\./);
  const toPlugins = link(off.el, 'Go to Plugins');
  assert.equal(toPlugins.getAttribute('href'), '#/plugins');
  assert.ok(toPlugins.classList.contains('btn'));
  assert.equal(visible(byClass(off.el, 'sky-toolbar')[0]), false, 'no Night and Day, no Earlier and Later');
  assert.equal(visible(byClass(off.el, 'sky-picker')[0]), false, 'and no camera picker');
  assert.equal(byClass(off.el, 'sky-settings-card').length, 0, 'the box’s setup is not here either');
  assert.doesNotMatch(text, /Turn on Sky Watcher in a camera/);
  // The cameras coming and going change nothing: it is the plugin that is off.
  const watching = pageWith({ plugin: false, cameras: [northSky()] });
  watching.listeners.forEach((listener) => listener());
  await settle();
  assert.match(shown(watching.el), /Sky Watcher is off/);
  assert.equal(watching.calls.loads.length, 0);
  off.page.destroy();
  watching.page.destroy();
});

test('the page follows the store’s plugin switch when nothing else is given', async () => {
  const realFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url) => {
    requests.push(url);
    const body = url.includes('/settings') ? { timeZone: 'America/Chicago', sky: { location: { latitude: 40, longitude: -100, heightMeters: 0 }, flightFeedURL: null, aiDailyLimit: 50 } } : night();
    return { status: 200, ok: true, json: async () => body, text: async () => JSON.stringify(body), headers: { get: () => 'application/json' } };
  };
  store.cameras.set(SKY, northSky());
  try {
    setPlugins([]);
    const off = mod.renderSkyLog({ params: [], setTitle() {} });
    await settle();
    assert.match(shown(off.el), /Sky Watcher is off/);
    assert.deepEqual(requests, [], 'off: nothing is asked of the bridge');
    off.destroy();

    setPlugins([{ id: 'sky', enabled: true }]);
    const on = mod.renderSkyLog({ params: [], setTitle() {} });
    await settle();
    assert.match(shown(on.el), /Last night: 1 unexplained, 11 explained/);
    assert.ok(requests.includes('/api/v1/settings'), 'the Setup panel read the box’s settings');
    assert.equal(byClass(on.el, 'sky-settings-card').length, 1);
    on.destroy();
  } finally {
    globalThis.fetch = realFetch;
    store.cameras.clear();
    setPlugins([]);
  }
});

test('with the plugin on and no camera watching the sky yet, the page says where to turn it on and links every camera', async () => {
  const cameras = [cameraOf(OTHER, 'Garden Sky', { skyDetector: { enabled: false } }), { id: '0A1B2C3D-0000-4000-8000-000000000009', name: 'Front Door', status: { connection: 'online' } }];
  const none = pageWith({ cameraID: null, cameras });
  await settle();
  assert.equal(none.calls.loads.length, 0, 'there is no night to ask for');
  const empty = byClass(none.el, 'sky-empty')[0];
  assert.ok(empty, 'a friendly empty state');
  assert.equal(tag(empty, 'h2')[0].textContent, 'Turn on Sky Watcher in a camera’s settings');
  assert.match(shown(empty), /Open the camera that looks at the sky and switch on “Watch the sky”\./);
  assert.deepEqual(tag(empty, 'a').map((a) => [a.textContent, a.getAttribute('href')]), [['Garden Sky', `#/camera/${OTHER}`], ['Front Door', '#/camera/0A1B2C3D-0000-4000-8000-000000000009']],
    'a link to each camera’s page');
  assert.equal(visible(byClass(none.el, 'sky-toolbar')[0]), false);
  assert.doesNotMatch(shown(none.el), /Sky Watcher is off/, 'the plugin is on: this is not the off page');

  // A camera that turns it on brings the log; one that is added shows up in the list.
  const withCameras = [...cameras];
  const live = pageWith({ cameraID: null, cameras: withCameras });
  await settle();
  withCameras.push(cameraOf(SKY, 'Roof', { skyDetector: { enabled: false } }));
  live.listeners.forEach((listener) => listener());
  await settle();
  assert.deepEqual(tag(byClass(live.el, 'sky-empty')[0], 'a').map((a) => a.textContent), ['Garden Sky', 'Front Door', 'Roof']);
  withCameras[2] = northSky();
  live.listeners.forEach((listener) => listener());
  await settle();
  assert.equal(live.calls.loads.length, 1, 'once a camera watches the sky, its night is asked for');
  assert.match(shown(live.el), /Sky log · North Sky/);
  assert.equal(byClass(live.el, 'sky-empty').length, 0);
  none.page.destroy();
  live.page.destroy();
});

test('with the plugin on and no camera at all, the page says to add one first', async () => {
  const none = pageWith({ cameraID: null, cameras: [] });
  await settle();
  const empty = byClass(none.el, 'sky-empty')[0];
  assert.equal(tag(empty, 'h2')[0].textContent, 'Turn on Sky Watcher in a camera’s settings');
  assert.match(shown(empty), /Add the camera that looks at the sky first\./);
  assert.equal(link(empty, 'Add a camera').getAttribute('href'), '#/add');
  none.page.destroy();
});

// MARK: The Setup panel

const boxSettings = (location) => ({ bridgeName: 'Bridge', timeZone: 'America/Chicago', sky: { location, flightFeedURL: null, aiDailyLimit: 50 } });
const PLACE = { latitude: 40, longitude: -100, heightMeters: 0 };
const panelOf = (settings, options = {}) => () => setupMod.createSkySetupPanel({ settings: async () => settings, ...options });

test('the Setup panel is at the top of the page, open until the box has a place', async () => {
  const { page, el } = pageWith({ setup: panelOf(boxSettings(null)) });
  await settle();
  const panel = byClass(el, 'sky-settings-card')[0];
  assert.ok(panel, 'the panel is on the page');
  assert.equal(panel.localName, 'details');
  assert.equal(panel.open, true, 'no place yet: open');
  assert.equal(all(panel, (node) => node.localName === 'summary')[0].textContent.startsWith('Setup'), true, 'it is called Setup');
  assert.equal(all(panel, (node) => node.localName === 'h2')[0].textContent, 'Setup');
  const flat = all(el, () => true);
  assert.ok(flat.indexOf(panel) < flat.indexOf(byClass(el, 'sky-toolbar')[0]), 'above the toolbar and the log');
  assert.ok(flat.indexOf(panel) < flat.indexOf(byClass(el, 'sky-summary')[0]));
  // The box’s settings that moved here: where the box is, the flight feed with its Find button, the AI’s daily limit.
  const text = shown(panel);
  assert.match(text, /Where the box is/);
  assert.match(text, /Flight feed/);
  assert.ok(button(panel, 'Find a feed'));
  assert.ok(button(panel, 'Use this browser’s location'));
  assert.ok(all(panel, (node) => node.dataset?.field === 'limit')[0], 'the AI’s daily limit');
  page.destroy();
});

test('with a place set the Setup panel can be folded away, and opened again', async () => {
  const { page, el } = pageWith({ setup: panelOf(boxSettings(PLACE)) });
  await settle();
  const panel = byClass(el, 'sky-settings-card')[0];
  assert.equal(panel.localName, 'details');
  assert.equal(panel.open, false, 'a place is set: folded, with the log in view');
  assert.match(shown(panel), /^Setup/, 'its title is still there');
  assert.doesNotMatch(shown(panel), /Flight feed/, 'and its fields are folded away');
  panel.open = true;
  assert.match(shown(panel), /Flight feed/);
  assert.equal(all(panel, (node) => node.dataset?.field === 'latitude')[0].value, '40', 'the place is in its fields');
  panel.open = false;
  assert.doesNotMatch(shown(panel), /Flight feed/);
  // The log under it is as always.
  assert.match(shown(el), /Last night: 1 unexplained, 11 explained/);
  page.destroy();
});

test('the Setup panel is there for an empty page too, so the first thing to do is at hand', async () => {
  const none = pageWith({ cameraID: null, cameras: [], setup: panelOf(boxSettings(null)) });
  await settle();
  assert.equal(byClass(none.el, 'sky-settings-card')[0].open, true);
  assert.match(shown(none.el), /Turn on Sky Watcher in a camera’s settings/);
  none.page.destroy();
  const gone = pageWith({ cameraID: '0A1B2C3D-0000-4000-8000-0000000000FF', setup: panelOf(boxSettings(null)) });
  await settle();
  assert.match(shown(gone.el), /This camera was removed/);
  assert.equal(byClass(gone.el, 'sky-settings-card').length, 1);
  gone.page.destroy();
});

test('a place saved in the Setup panel goes to the bridge as PATCH settings {sky}, and the panel stays open to say so', async () => {
  const saves = [];
  const { page, el } = pageWith({
    setup: panelOf(boxSettings(null), { save: async (partial) => { saves.push(partial); return boxSettings({ ...partial.location, heightMeters: 0 }); } }),
  });
  await settle();
  const panel = byClass(el, 'sky-settings-card')[0];
  const type = (name, value) => { const input = all(panel, (node) => node.dataset?.field === name)[0]; input.value = value; input.dispatchEvent({ type: 'input', target: input }); };
  type('latitude', '41.5');
  type('longitude', '-100.25');
  button(panel, 'Save the location').click();
  await settle();
  assert.deepEqual(saves, [{ location: { latitude: 41.5, longitude: -100.25 } }]);
  assert.match(shown(panel), /The location is saved on this box\./);
  assert.equal(panel.open, true, 'it does not fold itself away under the person’s hand');
  page.destroy();
});

test('when the box’s settings cannot be read the panel says so and tries again on request', async () => {
  let fail = true;
  const asked = [];
  const { page, el } = pageWith({
    setup: () => setupMod.createSkySetupPanel({ settings: async () => { asked.push(1); if (fail) throw new ApiError(0, 'network', 'The bridge didn’t answer. Check that it is on and that this device is on the same network.'); return boxSettings(PLACE); } }),
  });
  await settle();
  const host = byClass(el, 'sky-setup-host')[0];
  assert.match(shown(host), /Setup/);
  assert.match(shown(host), /The bridge didn’t answer\./);
  assert.match(shown(el), /Last night: 1 unexplained, 11 explained/, 'the log is there all the same');
  fail = false;
  button(host, 'Try again').click();
  await settle();
  assert.equal(asked.length, 2);
  assert.equal(byClass(host, 'sky-settings-card')[0].open, false);
  page.destroy();
  // A panel taken down before its settings arrive draws nothing and says nothing.
  let release;
  const slow = pageWith({ setup: () => setupMod.createSkySetupPanel({ settings: () => new Promise((resolve) => { release = resolve; }) }) });
  await settle();
  slow.page.destroy();
  release(boxSettings(null));
  await settle();
  assert.equal(byClass(slow.el, 'sky-settings-card').length, 0);
});
