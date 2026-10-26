// The Sky Watcher page (screens/sky-log.js): the morning sky log in layout A. The summary and the counts first, the conditions, the night as a
// strip with a dot for each light, the unexplained ones with their stills, paths and measures, the explained ones collapsed by kind, one-tap
// corrections that change the page in place, past nights and days, and a camera picker; in the fake browser with fake requests.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let mod;
let setupMod;
let store;
let setPlugins;
let ApiError;
let closeUpRect;
before(async () => {
  browser = installFakeBrowser();
  ({ ApiError } = await import('../web/js/api.js'));
  mod = await import('../web/js/screens/sky-log.js');
  ({ closeUpRect } = await import('../web/js/screens/sky-model.js'));
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
function entriesOfANight() {
  return [
    raw('p1', 'plane', chicago(20, 5, 24), { by: 'flight', detail: 'TEST123 · 35,000 ft' }),
    raw('p2', 'probablePlane', chicago(21, 40, 24), { by: 'flight', detail: 'ABC789 · 12,000 ft' }),
    raw('p3', 'plane', chicago(23, 55, 24), { by: 'flight', detail: 'N12345 · 41,000 ft' }),
    ...Array.from({ length: 5 }, (_, i) => raw(`s${i}`, i === 0 ? 'satellite' : 'satellite', chicago(19, 10 + i * 7, 24), { by: 'orbit', detail: i === 0 ? 'ISS (ZARYA)' : `STARLINK-${1000 + i}` })),
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
const open = async (details) => { details.open = true; details.dispatchEvent({ type: 'toggle', target: details }); await settle(); };
const detailsOf = (root, group) => all(root, (node) => node.localName === 'details' && node.dataset?.group === group)[0];

/**
 * The page with fake requests; `log` is the night (or a function of the request, which may return an Error), `cameras` the cameras' list,
 * `plugin` whether the Sky Watcher plugin is on (it is, unless a test says it is not) and `setup` makes the Setup panel (none: the tests of the
 * log leave the box's settings out).
 */
function pageWith({ log = night(), cameras = [northSky()], query = '', cameraID = SKY, correct, zone = CHICAGO, plugin = true, setup = () => null, openPlayer = async () => ({ close() {} }) } = {}) {
  const calls = { loads: [], corrections: [], addresses: [] };
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
    now: () => NOW,
    writeAddress: (address) => calls.addresses.push(address),
    cameras: () => cameras,
    onCameras: (fn) => { listeners.add(fn); return () => listeners.delete(fn); },
    zone: () => zone,
    plugin: () => plugin,
    setup,
    openPlayer,
  });
  return { page, calls, listeners, el: page.el };
}

// MARK: Layout A

test('the log lists the unexplained first, the explained grouped and collapsed', async () => {
  const { page, el, calls } = pageWith();
  await settle();
  assert.deepEqual(calls.loads, [{ cameraID: SKY, night: null, view: 'night' }], 'the latest night, asked for once');
  assert.equal(tag(el, 'h1')[0].textContent, 'Sky Watcher');
  const text = shown(el);
  assert.match(text, /Sky log · North Sky/);
  assert.match(text, /Last night: 1 unexplained, 11 explained/);
  assert.match(text, /☁︎ clear until 3 AM; sky not visible 3–5 AM; clear 5–7:21 AM/);

  // The counts: unexplained, planes, satellites, meteors, bugs and birds.
  const counts = byClass(el, 'sky-counts')[0];
  assert.deepEqual(tag(counts, 'li').map((li) => li.textContent.replace(/\s+/g, ' ').trim()), ['1 unexplained', '3 planes', '5 satellites', '1 meteor', '2 bugs and birds']);

  // The order on the page: summary, strip, the unexplained, then the explained.
  const order = ['sky-summary', 'sky-strip', 'sky-unexplained', 'sky-explained'].map((name) => byClass(el, name)[0]);
  assert.ok(order.every(Boolean));
  const flat = all(el, () => true);
  assert.deepEqual(order.map((node) => flat.indexOf(node)), [...order.map((node) => flat.indexOf(node))].sort((a, b) => a - b), 'in that order');

  // The unexplained one: its words.
  const cards = byClass(el, 'sky-entry');
  assert.equal(cards.length, 1);
  const card = shown(cards[0]);
  for (const sentence of ['3:12:08 AM', 'Low in the northwest, 8° up', 'Lasted 4.2 seconds', 'About 6× faster across the sky than planes at that height', 'Blinks about once a second',
    'Curved', 'Looks larger than planes and satellites do there', 'A bright light moving fast, probably a drone.', 'That was a…']) assert.match(card, new RegExp(sentence.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), sentence);
  assert.ok(button(cards[0], 'Play'), 'its recording plays on this page');
  assert.equal(link(cards[0], 'Watch'), undefined, 'the Monitor is a second way, inside the player');
  const clip = link(cards[0], 'Download clip').getAttribute('href');
  assert.equal(clip, `/api/v1/nvr/cameras/${SKY}/clip?from=${chicago(3, 12) + 8000 - 3000}&to=${chicago(3, 12) + 8000 + 4200 + 3000}&tz=America%2FChicago&part=1`);
  assert.deepEqual(['Plane', 'Bird', 'Bug', 'Satellite', 'Meteor', 'Not sure'].map((word) => Boolean(button(cards[0], word))), Array(6).fill(true));

  // The explained: one closed group each, in order, with no rows built yet.
  const groups = byClass(el, 'sky-group-details');
  assert.deepEqual(groups.map((group) => group.dataset.group), ['planes', 'satellites', 'meteors', 'bugsAndBirds']);
  assert.deepEqual(groups.map((group) => group.open), [false, false, false, false], 'collapsed by default');
  assert.deepEqual(groups.map((group) => shown(tag(group, 'summary')[0]).replace(/\s+/g, ' ').trim()), ['Planes 3', 'Satellites 5', 'Meteors 1', 'Bugs and birds 2'], 'each says its kind and how many');
  assert.equal(byClass(el, 'sky-row').length, 0, 'nothing is built for a group nobody opened');
  assert.doesNotMatch(text, /TEST123/);

  await open(detailsOf(el, 'planes'));
  const planes = shown(detailsOf(el, 'planes'));
  assert.match(planes, /TEST123 · 35,000 ft/);
  assert.match(planes, /ABC789 · 12,000 ft/);
  assert.match(planes, /probably a plane/i, 'a plane matched while the aim is rough says so');
  await open(detailsOf(el, 'satellites'));
  assert.match(shown(detailsOf(el, 'satellites')), /ISS \(ZARYA\)/);
  assert.match(shown(detailsOf(el, 'satellites')), /STARLINK-1001/);
  assert.equal(byClass(detailsOf(el, 'planes'), 'sky-row').length, 3);
  assert.equal(byClass(detailsOf(el, 'satellites'), 'sky-row').length, 5);
  page.destroy();
});

test('the still has the path drawn over it in the picture’s own coordinates', async () => {
  const { page, el } = pageWith();
  await settle();
  const card = byClass(el, 'sky-entry')[0];
  const img = tag(card, 'img')[0];
  assert.equal(img.getAttribute('src'), `/api/v1/sky/cameras/${SKY}/entries/u1/still?night=2026-10-24`);
  assert.equal(img.getAttribute('loading'), 'lazy');
  const overlay = byClass(card, 'sky-path')[0];
  assert.ok(overlay, 'an overlay on the still');
  assert.equal(all(overlay, (node) => node.localName === 'polyline').length, 0, 'nothing drawn before the picture is known');

  Object.assign(img, { naturalWidth: 400, naturalHeight: 177 });   // the still has arrived: 400 × 177
  img.dispatchEvent({ type: 'load', target: img });
  const line = all(overlay, (node) => node.localName === 'polyline')[0];
  assert.equal(line.getAttribute('points'), '40,35.4 120,44.25', 'the path in the picture’s pixels');
  const marks = all(overlay, (node) => node.localName === 'circle');
  assert.equal(marks.length, 2, 'where it began and where it ended');
  assert.equal(marks[0].getAttribute('cx'), '40');
  assert.equal(marks[1].getAttribute('cy'), '44.25');
  const crop = closeUpRect(UNEXPLAINED().path, 400, 177);
  assert.equal(overlay.getAttribute('viewBox'), `${crop.x} ${crop.y} ${crop.width} ${crop.height}`, 'and the close-up shows the part around it');

  // A bigger picture: the same path in its coordinates.
  Object.assign(img, { naturalWidth: 4256, naturalHeight: 1888 });
  img.dispatchEvent({ type: 'load', target: img });
  const big = closeUpRect(UNEXPLAINED().path, 4256, 1888);
  assert.equal(overlay.getAttribute('viewBox'), `${big.x} ${big.y} ${big.width} ${big.height}`);
  assert.equal(all(overlay, (node) => node.localName === 'polyline')[0].getAttribute('points'), '425.6,377.6 1276.8,472');
  assert.equal(all(overlay, (node) => node.localName === 'polyline').length, 1, 'drawn again, not added to');
  page.destroy();
});

// MARK: Close-ups

/** The close-up of a card or a row: the button that holds its still. */
const stillOf = (root) => byClass(root, 'sky-still').find((node) => node.localName === 'button');
const arrive = (root, width = 1920, height = 852) => {
  const img = tag(root, 'img')[0];
  Object.assign(img, { naturalWidth: width, naturalHeight: height });
  img.dispatchEvent({ type: 'load', target: img });
  return img;
};

test('a still shows a close-up of the light; a tap shows the whole picture, and another tap or Escape the close-up again', async () => {
  const { page, el } = pageWith();
  await settle();
  const card = byClass(el, 'sky-entry')[0];
  const still = stillOf(card);
  assert.ok(still, 'the still is something to tap');
  assert.equal(still.dataset.view, 'loading', 'nothing to crop before the picture is known');
  arrive(card);
  const crop = closeUpRect(UNEXPLAINED().path, 1920, 852);
  assert.deepEqual(crop, { x: 0, y: 0, width: 768, height: 432 });
  assert.equal(still.dataset.view, 'closeup');
  // The picture is placed so that the crop fills the close-up's 16:9 frame: 1920 / 768 = 250 % of its width, moved by the crop's corner.
  assert.equal(still.style.getPropertyValue('--sky-crop-w'), '250');
  assert.equal(still.style.getPropertyValue('--sky-crop-x'), '0');
  assert.equal(still.style.getPropertyValue('--sky-crop-y'), '0');
  const overlay = byClass(card, 'sky-path')[0];
  assert.equal(overlay.getAttribute('viewBox'), '0 0 768 432');
  assert.equal(still.getAttribute('aria-pressed'), 'false');
  assert.match(still.getAttribute('aria-label'), /Whole picture/);

  still.click();
  assert.equal(still.dataset.view, 'whole', 'the whole picture, with the path');
  assert.equal(overlay.getAttribute('viewBox'), '0 0 1920 852');
  assert.equal(still.getAttribute('aria-pressed'), 'true');
  still.click();
  assert.equal(still.dataset.view, 'closeup', 'another tap goes back');
  still.click();
  document.dispatchEvent({ type: 'keydown', key: 'Escape', target: document.body, preventDefault() {} });
  assert.equal(still.dataset.view, 'closeup', 'and so does Escape');
  assert.equal(overlay.getAttribute('viewBox'), '0 0 768 432');

  // A light in the corner of the picture: its close-up is moved in, never cut.
  const corner = raw('u9', 'unexplained', chicago(2, 0), { hasStill: true, path: [{ t: 0, x: 0.98, y: 0.97 }, { t: 1, x: 0.995, y: 0.99 }] });
  const other = pageWith({ log: night({ entries: [corner], counts: { ...COUNTS, unexplained: 1, explained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0 } }) });
  await settle();
  arrive(byClass(other.el, 'sky-entry')[0]);
  assert.equal(byClass(other.el, 'sky-path')[0].getAttribute('viewBox'), '1760 762 160 90');
  const s = stillOf(byClass(other.el, 'sky-entry')[0]);
  assert.equal(s.style.getPropertyValue('--sky-crop-w'), '1200');
  assert.equal(s.style.getPropertyValue('--sky-crop-x'), '1100');
  assert.equal(s.style.getPropertyValue('--sky-crop-y'), '846.67');

  // A light that crossed the whole sky is shown whole: there is no close-up of it to give.
  const across = raw('u8', 'unexplained', chicago(2, 0), { hasStill: true, path: [{ t: 0, x: 0.05, y: 0.1 }, { t: 9, x: 0.95, y: 0.9 }] });
  const wide = pageWith({ log: night({ entries: [across], counts: { ...COUNTS, unexplained: 1, explained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0 } }) });
  await settle();
  arrive(byClass(wide.el, 'sky-entry')[0]);
  const whole = byClass(wide.el, 'sky-still')[0];
  assert.equal(whole.dataset.view, 'whole');
  assert.equal(whole.getAttribute('aria-disabled'), 'true', 'and nothing to tap');
  page.destroy();
  other.page.destroy();
  wide.page.destroy();
});

test('an unexplained card shows its detail under the line that says what it is', async () => {
  const detailed = { ...UNEXPLAINED(), detail: 'Closest flight: none within the view' };
  const { page, el } = pageWith({ log: night({ entries: [detailed], counts: { ...COUNTS, unexplained: 1, explained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0 } }) });
  await settle();
  const card = byClass(el, 'sky-entry')[0];
  const detail = byClass(card, 'sky-detail')[0];
  assert.ok(detail && visible(detail));
  assert.equal(detail.textContent, 'Closest flight: none within the view');
  const body = byClass(card, 'sky-entry-body')[0];
  const order = body.childNodes.filter((node) => node.tagName);
  assert.equal(order.indexOf(detail), order.indexOf(byClass(card, 'sky-entry-head')[0]) + 1, 'right under it');
  page.destroy();
  // None to show: no line.
  const plain = pageWith();
  await settle();
  assert.equal(byClass(plain.el, 'sky-detail').length, 0);
  plain.page.destroy();
});

test('an explained row shows its still small, as a close-up, and every row can play its recording', async () => {
  const meteor = raw('m1', 'meteor', chicago(1, 30), { by: 'rule', hasStill: true, path: [{ t: 0, x: 0.4, y: 0.2 }, { t: 0.6, x: 0.45, y: 0.3 }] });
  const plane = raw('p1', 'plane', chicago(20, 5, 24), { by: 'flight', detail: 'TEST123 · 35,000 ft' });
  const { page, el } = pageWith({ log: night({ entries: [meteor, plane], counts: { unexplained: 0, planes: 1, satellites: 0, meteors: 1, bugsAndBirds: 0, notSure: 0, explained: 2 } }) });
  await settle();
  await open(detailsOf(el, 'meteors'));
  const row = byClass(detailsOf(el, 'meteors'), 'sky-row')[0];
  const still = stillOf(row);
  assert.ok(still, 'the meteor’s still');
  assert.ok(still.classList.contains('sky-still--small'), 'small');
  assert.equal(tag(row, 'img')[0].getAttribute('src'), `/api/v1/sky/cameras/${SKY}/entries/m1/still?night=2026-10-24`);
  arrive(row);
  assert.equal(still.dataset.view, 'closeup');
  const crop = closeUpRect(meteor.path, 1920, 852);
  assert.equal(byClass(row, 'sky-path')[0].getAttribute('viewBox'), `${crop.x} ${crop.y} ${crop.width} ${crop.height}`);
  assert.ok(button(row, 'Play'), 'its recording');
  await open(detailsOf(el, 'planes'));
  const planeRow = byClass(detailsOf(el, 'planes'), 'sky-row')[0];
  assert.equal(stillOf(planeRow), undefined, 'a row with no still has no picture');
  assert.equal(tag(planeRow, 'img').length, 0);
  assert.ok(button(planeRow, 'Play'), 'and plays all the same');
  page.destroy();
});

test('Play opens the clip player on this page with the entry, the camera and the way to the Monitor; closing it leaves the log as it was', async () => {
  const opened = [];
  let closePlayer = null;
  const openPlayer = async (options) => {
    opened.push(options);
    return { close: () => { closePlayer = 'closed'; options.onClose?.(); } };
  };
  const { page, el, calls } = pageWith({ openPlayer });
  await settle();
  const card = byClass(el, 'sky-entry')[0];
  const play = button(card, 'Play');
  assert.match(play.getAttribute('aria-label'), /Play the recording of 3:12:08 AM/);
  play.click();
  await settle();
  assert.equal(opened.length, 1);
  const [options] = opened;
  assert.equal(options.camera.id, SKY);
  assert.equal(options.entry.id, 'u1');
  assert.equal(options.entry.start, chicago(3, 12) + 8000);
  assert.equal(options.zone, CHICAGO);
  assert.equal(options.heading, '3:12:08 AM');
  assert.equal(options.what, 'Moving light · North Sky');
  assert.equal(options.still, `/api/v1/sky/cameras/${SKY}/entries/u1/still?night=2026-10-24`);
  assert.equal(options.watchHref, `#/camera/${SKY}/watch/${chicago(3, 12) + 8000 - 3000}`);
  play.click();
  await settle();
  assert.equal(opened.length, 1, 'one player at a time');
  options.onClose();
  await settle();
  assert.equal(byClass(el, 'sky-entry')[0], card, 'the log is not drawn again: it stays where it was');
  assert.equal(calls.loads.length, 1);

  // A row's Play: the player says what it was, never with a size or a distance.
  await open(detailsOf(el, 'planes'));
  button(byClass(detailsOf(el, 'planes'), 'sky-row')[0], 'Play').click();
  await settle();
  assert.equal(opened.length, 2);
  assert.equal(opened[1].what, 'Plane · North Sky', 'the flight’s height stays in the row');
  assert.equal(opened[1].still, null, 'no still kept');

  // Leaving the page closes the player.
  page.destroy();
  assert.equal(closePlayer, 'closed');
});

test('a player that cannot be loaded says so, and Play works again', async () => {
  let tries = 0;
  const openPlayer = async () => { tries += 1; throw new TypeError('Failed to fetch dynamically imported module'); };
  const { page, el } = pageWith({ openPlayer });
  await settle();
  const card = byClass(el, 'sky-entry')[0];
  button(card, 'Play').click();
  await settle();
  assert.match(shown(card), /The player couldn’t open\. Try again in a moment\./);
  assert.doesNotMatch(shown(card), /dynamically/, 'never the script’s own words');
  button(card, 'Play').click();
  await settle();
  assert.equal(tries, 2);
  page.destroy();
});

test('an entry with no kept picture says so and still has its facts and corrections', async () => {
  const bare = raw('u2', 'unexplained', chicago(2, 0), { hasStill: false, path: [] });
  const { page, el } = pageWith({ log: night({ entries: [bare], counts: { ...COUNTS, unexplained: 1, explained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0 } }) });
  await settle();
  const card = byClass(el, 'sky-entry')[0];
  assert.equal(tag(card, 'img').length, 0);
  assert.match(shown(card), /No picture kept/);
  assert.match(shown(card), /Low in the northwest, 8° up/);
  assert.ok(button(card, 'Bird'));
  assert.ok(button(card, 'Play'), 'its moment is still in the recordings');
  page.destroy();
});

test('a picture the box made later from the recording is shown the next time the log is read', async () => {
  let reads = 0;
  const log = (request) => {
    reads += 1;
    // The box logged the light without a picture (no room then); by the next read it made one from the recording, and its log says so.
    const light = raw('u2', 'unexplained', chicago(2, 0), { hasStill: reads > 1 });
    return night({ night: request.night ?? '2026-10-24', entries: [light], counts: { ...COUNTS, unexplained: 1, explained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0 } });
  };
  const { page, el } = pageWith({ log });
  await settle();
  const before = byClass(el, 'sky-entry')[0];
  assert.equal(tag(before, 'img').length, 0);
  assert.match(shown(before), /No picture kept/);
  button(el, 'Earlier').click();
  await settle();
  button(el, 'Later').click();
  await settle();
  const after = byClass(el, 'sky-entry')[0];
  assert.equal(tag(after, 'img')[0]?.getAttribute('src'), `/api/v1/sky/cameras/${SKY}/entries/u2/still?night=2026-10-24`);
  assert.doesNotMatch(shown(after), /No picture kept/);
  page.destroy();
});

test('an hour with more lights than the box logs says so under the strip', async () => {
  const capped = [{ hour: chicago(22, 0, 24), count: 212 }, { hour: chicago(5, 0), count: 1 }];
  const { page, el } = pageWith({ log: night({ capped }) });
  await settle();
  const notes = byClass(el, 'sky-capped');
  assert.equal(notes.length, 1);
  assert.deepEqual(byClass(notes[0], 'sky-capped-hour').map((node) => node.textContent),
    ['10 PM: 212 more lights weren’t logged (busy hour)', '5 AM: 1 more light wasn’t logged (busy hour)']);
  const children = [...byClass(el, 'sky-body')[0].childNodes];
  assert.equal(children.indexOf(notes[0]), children.indexOf(byClass(el, 'sky-strip')[0]) + 1, 'right under the strip');
  page.destroy();
  // A night without one, and a bridge from before that sends none, have no note.
  for (const extra of [{ capped: [] }, {}]) {
    const plain = pageWith({ log: night(extra) });
    await settle();
    assert.equal(byClass(plain.el, 'sky-capped').length, 0);
    plain.page.destroy();
  }
});

test('a light that is not a moving track reads as what it is', async () => {
  const flash = raw('f1', 'unexplained', chicago(1, 0), { kind: 'flash', path: [{ t: 0, x: 0.5, y: 0.3 }], measures: { azimuth: 10, elevation: 6, duration: 0.4, blinks: true, blinkRate: 2, shape: 'straight', speed: 0 } });
  const rising = raw('n1', 'unexplained', chicago(2, 0), { kind: 'newLight', path: [{ t: 0, x: 0.5, y: 0.3 }], measures: { azimuth: 350, elevation: 22, duration: 9, blinks: false, shape: 'curved', speed: 0 } });
  const { page, el } = pageWith({ log: night({ entries: [flash, rising], counts: { unexplained: 2, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 0 } }) });
  await settle();
  const [a, b] = byClass(el, 'sky-entry').map((card) => shown(card));
  assert.match(a, /Flash/);
  assert.match(a, /Blinks about 2 times a second/);
  assert.match(a, /under a second/);
  assert.match(b, /New light/);
  assert.match(b, /9 seconds/);
  assert.doesNotMatch(`${a} ${b}`, /Curved|Straight/, 'no path shape for a light that does not move');
  assert.doesNotMatch(`${a} ${b}`, /faster|slower/, 'and no speed');
  page.destroy();
});

// MARK: Corrections

test('a correction is sent and shown in place', async () => {
  const { page, el, calls } = pageWith();
  await settle();
  const card = byClass(el, 'sky-entry')[0];
  const summary = byClass(el, 'sky-summary')[0];
  const counts = byClass(el, 'sky-counts')[0];
  button(card, 'Bird').click();
  await settle();
  assert.deepEqual(calls.corrections, [{ cameraID: SKY, entryID: 'u1', night: '2026-10-24', label: 'bird' }]);
  assert.match(shown(card), /You said: bird\. Camera Bridge learns from this\./);
  assert.equal(button(card, 'Bird').getAttribute('aria-pressed'), 'true');
  assert.equal(button(card, 'Plane').getAttribute('aria-pressed'), 'false');
  assert.equal(calls.loads.length, 1, 'the page is not loaded again');
  assert.equal(byClass(el, 'sky-entry')[0], card, 'and its entry is the same element: nothing jumped');
  assert.equal(byClass(el, 'sky-summary')[0], summary);
  assert.match(shown(summary), /Last night: 0 unexplained, 12 explained/, 'one less to look at');
  const headings = byClass(el, 'sky-count').filter((node) => visible(node)).map((node) => node.textContent);
  assert.deepEqual([headings[0], headings[1]], ['0', '12'], 'and the two headings say the same');
  assert.deepEqual(tag(counts, 'li').map((li) => li.textContent.replace(/\s+/g, ' ').trim()), ['0 unexplained', '3 planes', '5 satellites', '1 meteor', '3 bugs and birds']);
  assert.equal(byClass(el, 'sky-dot').filter((dot) => dot.className.includes('sky-dot--unexplained')).length, 0, 'and its dot is not unexplained any more');

  // Another tap changes its mind; “Not sure” reads as it says.
  button(card, 'Not sure').click();
  await settle();
  assert.equal(calls.corrections.at(-1).label, 'notSure');
  assert.match(shown(card), /You said: not sure\. Camera Bridge learns from this\./);
  assert.doesNotMatch(shown(card), /You said: bird/);
  page.destroy();
});

test('a correction of an explained entry is shown in its row, and moves only the counts', async () => {
  const { page, el, calls } = pageWith();
  await settle();
  await open(detailsOf(el, 'planes'));
  const row = byClass(detailsOf(el, 'planes'), 'sky-row').find((node) => shown(node).includes('TEST123'));
  button(row, 'Bug').click();
  await settle();
  assert.deepEqual(calls.corrections.at(-1), { cameraID: SKY, entryID: 'p1', night: '2026-10-24', label: 'bug' });
  assert.match(shown(row), /You said: bug\. Camera Bridge learns from this\./);
  assert.deepEqual(tag(byClass(el, 'sky-counts')[0], 'li').map((li) => li.textContent.replace(/\s+/g, ' ').trim()), ['1 unexplained', '2 planes', '5 satellites', '1 meteor', '3 bugs and birds']);
  assert.match(shown(byClass(el, 'sky-summary')[0]), /Last night: 1 unexplained, 11 explained/);
  assert.ok(row.parentNode, 'the row stays where it was, to be read');
  page.destroy();
});

test('a correction the bridge could not take says so in the row and changes nothing', async () => {
  const { page, el } = pageWith({ correct: async () => { throw new ApiError(400, 'invalid', 'Sky Watcher doesn’t know that label.'); } });
  await settle();
  const card = byClass(el, 'sky-entry')[0];
  button(card, 'Plane').click();
  await settle();
  assert.match(shown(card), /Sky Watcher doesn’t know that label\./);
  assert.doesNotMatch(shown(card), /You said/);
  assert.equal(button(card, 'Plane').getAttribute('aria-pressed'), 'false');
  assert.match(shown(byClass(el, 'sky-summary')[0]), /1 unexplained, 11 explained/);
  // A script error never shows its own words.
  const broken = pageWith({ correct: async () => { throw new TypeError('x is undefined'); } });
  await settle();
  button(byClass(broken.el, 'sky-entry')[0], 'Plane').click();
  await settle();
  assert.match(shown(byClass(broken.el, 'sky-entry')[0]), /That didn’t save\. Try again in a moment\./);
  assert.doesNotMatch(shown(byClass(broken.el, 'sky-entry')[0]), /undefined/);
  page.destroy();
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
    const calls = [];
    const page = mod.createSkyLogPage({ cameraID: SKY, load: async () => night(), now: () => NOW, cameras: () => [northSky()], onCameras: () => () => {}, zone: () => CHICAGO, writeAddress: (a) => calls.push(a), plugin: () => true, setup: () => null });
    await settle();
    button(byClass(page.el, 'sky-entry')[0], 'Bird').click();
    await settle();
    assert.deepEqual(sent, [{ url: `/api/v1/sky/cameras/${SKY}/entries/u1/correction`, method: 'POST', body: { night: '2026-10-24', label: 'bird' } }]);
    assert.match(shown(page.el), /You said: bird\./);
    page.destroy();
  } finally {
    globalThis.fetch = realFetch;
  }
});

// MARK: The strip

test('the night is a strip from sunset to sunrise with a dot for each light, the unexplained larger and glowing', async () => {
  const { page, el } = pageWith();
  await settle();
  const strip = byClass(el, 'sky-strip')[0];
  assert.equal(tag(strip, 'svg').length, 1);
  assert.match(tag(strip, 'svg')[0].getAttribute('aria-label'), /1 unexplained, 3 planes, 5 satellites, 1 meteor, 2 bugs and birds/);
  const dots = byClass(strip, 'sky-dot');
  assert.equal(dots.length, 12, 'one for each entry');
  const kinds = (kind) => dots.filter((dot) => dot.className.includes(`sky-dot--${kind}`));
  assert.deepEqual(['unexplained', 'planes', 'satellites', 'meteors', 'bugsAndBirds'].map((kind) => kinds(kind).length), [1, 3, 5, 1, 2]);
  const big = Number(kinds('unexplained')[0].getAttribute('r'));
  assert.ok(big > Number(kinds('planes')[0].getAttribute('r')), 'larger');
  assert.equal(byClass(strip, 'sky-halo').length, 1, 'and one glowing');
  // Time runs left to right: the 7:10 PM satellite is left of the 3:12 AM light.
  const x = (dot) => Number(dot.getAttribute('cx'));
  assert.ok(x(kinds('satellites')[0]) < x(kinds('unexplained')[0]));
  // The conditions shade the strip where the sky was not visible, and the hours are marked in the box’s zone.
  assert.equal(byClass(strip, 'sky-band--notVisible').length, 1);
  assert.equal(byClass(strip, 'sky-band--clear').length, 0, 'a clear sky is not shaded');
  const ticks = byClass(el, 'sky-tick').map((node) => node.textContent);
  assert.deepEqual(ticks, ['10 PM', '12 AM', '2 AM', '4 AM']);
  assert.match(shown(byClass(el, 'sky-ends')[0]), /6:32 PM.*7:21 AM/);
  page.destroy();
});

// MARK: A busy night

test('a night of dozens of planes and hundreds of satellites reads well: counts first, the explained collapsed and paged', async () => {
  const entries = [UNEXPLAINED()];
  for (let i = 0; i < 48; i += 1) entries.push(raw(`pl${i}`, 'plane', FROM + 600_000 + i * 700_000, { by: 'flight', detail: `AAL${100 + i} · ${20 + (i % 20)},000 ft` }));
  for (let i = 0; i < 230; i += 1) entries.push(raw(`sa${i}`, 'satellite', FROM + 300_000 + i * 150_000, { by: 'orbit', detail: `STARLINK-${2000 + i}` }));
  for (let i = 0; i < 40; i += 1) entries.push(raw(`fl${i}`, 'probablePlane', FROM + 900_000 + i * 900_000, { kind: 'flash', by: 'flight' }));
  const counts = { unexplained: 1, planes: 88, satellites: 230, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 318 };
  const { page, el } = pageWith({ log: night({ entries, counts }) });
  await settle();
  const text = shown(el);
  assert.match(text, /Last night: 1 unexplained, 318 explained/);
  assert.deepEqual(tag(byClass(el, 'sky-counts')[0], 'li').map((li) => li.textContent.replace(/\s+/g, ' ').trim()), ['1 unexplained', '88 planes', '230 satellites', '0 meteors', '0 bugs and birds']);
  assert.equal(byClass(el, 'sky-entry').length, 1, 'only the unexplained one has a card');
  assert.equal(byClass(el, 'sky-row').length, 0, 'and 318 explained ones have nothing built until a group is opened');
  assert.equal(byClass(el, 'sky-dot').length, 319, 'every one is in the strip');
  assert.ok(byClass(el, 'sky-group-details').every((group) => !group.open));

  await open(detailsOf(el, 'satellites'));
  const group = detailsOf(el, 'satellites');
  assert.equal(byClass(group, 'sky-row').length, 50, 'the first fifty');
  const more = button(group, 'Show more');
  assert.ok(more, 'and the rest on request');
  assert.match(more.getAttribute('aria-label') ?? more.textContent, /180 left|Show more/);
  more.click();
  await settle();
  assert.equal(byClass(group, 'sky-row').length, 100);
  for (let taps = 0; taps < 10 && button(group, 'Show more') && visible(button(group, 'Show more')); taps += 1) { button(group, 'Show more').click(); await settle(); }
  assert.equal(byClass(group, 'sky-row').length, 230, 'all of them in the end');
  page.destroy();
});

test('a night with many unexplained lights builds twenty cards at a time, and groups start closed on another night', async () => {
  const entries = [];
  for (let i = 0; i < 45; i += 1) entries.push(raw(`u${String(i).padStart(2, '0')}`, 'unexplained', FROM + 600_000 + i * 600_000, { hasStill: i % 2 === 0, kind: i % 3 === 0 ? 'newLight' : 'track' }));
  entries.push(raw('s9', 'satellite', FROM + 500_000, { by: 'orbit', detail: 'ISS (ZARYA)' }));
  const counts = { unexplained: 45, planes: 0, satellites: 1, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 1 };
  const { page, el, calls } = pageWith({ log: night({ entries, counts }) });
  await settle();
  assert.equal(byClass(el, 'sky-entry').length, 20);
  assert.match(shown(el).replace(/\s+/g, ' '), /Unexplained 45/);
  const more = button(el, 'Show more');
  assert.ok(more && visible(more));
  more.click();
  await settle();
  assert.equal(byClass(el, 'sky-entry').length, 40);
  button(el, 'Show more').click();
  await settle();
  assert.equal(byClass(el, 'sky-entry').length, 45);
  assert.ok(!visible(button(el, 'Show more')), 'all of them: nothing more to show');

  await open(detailsOf(el, 'satellites'));
  assert.equal(byClass(el, 'sky-row').length, 1);
  button(el, 'Earlier').click();
  await settle();
  assert.equal(calls.loads.length, 2);
  assert.equal(detailsOf(el, 'satellites').open, false, 'the next night’s groups start closed');
  page.destroy();
});

test('no text ever claims a real size or speed', async () => {
  const entries = [
    UNEXPLAINED(),
    raw('u2', 'unexplained', chicago(1, 0), { kind: 'newLight', measures: { azimuth: 0, elevation: 80, duration: 30, blinks: true, blinkRate: 0.2, shape: 'suddenStop' }, speedVsPlanes: 0.4, unusual: ['brighter', 'suddenStop'] }),
    raw('u3', 'unexplained', chicago(2, 0), { kind: 'flash', measures: { azimuth: 90, elevation: 3, duration: 0.2, blinks: true, blinkRate: 2.5, shape: 'sharpTurn' }, speedVsPlanes: 1 }),
    raw('p1', 'plane', chicago(20, 5, 24), { by: 'flight', detail: 'TEST123 · 35,000 ft' }),
    raw('p2', 'probablePlane', chicago(21, 40, 24)),
    raw('s1', 'satellite', chicago(19, 10, 24), { by: 'orbit', detail: 'ISS (ZARYA)' }),
    raw('s2', 'satelliteFlare', chicago(19, 30, 24), { by: 'orbit' }),
    raw('m1', 'meteor', chicago(1, 30)),
    raw('b1', 'bird', chicago(22, 10, 24)),
    raw('g1', 'bug', chicago(22, 12, 24)),
    raw('n1', 'plane', chicago(23, 0, 24), { correction: 'notSure' }),
  ];
  const counts = { unexplained: 3, planes: 2, satellites: 2, meteors: 1, bugsAndBirds: 2, notSure: 1, explained: 8 };
  const { page, el } = pageWith({ log: night({ entries, counts }), cameras: [northSky({ status: { connection: 'online', sky: { ...SKY_STATUS, aim: { quality: 'rough', planes: 0, stars: 0, residualPixels: null, lenses: [] }, learning: { ready: false, planes: 12, satellites: 0 } } } })] });
  await settle();
  for (const group of byClass(el, 'sky-group-details')) await open(group);
  const text = shown(el);
  assert.match(text, /Not sure/, 'every kind is on the page');
  assert.match(text, /Satellite flare/);
  assert.doesNotMatch(text, /km\/h|mph|metres|meters|feet tall|miles|\bkm\b|\bm\/s\b|knots|kilomet/i);
  assert.doesNotMatch(text, /Sky detector/i);
  page.destroy();
});

// MARK: Past nights, days and cameras

test('past nights and days are a tap away: Earlier, Later, Night and Day', async () => {
  const log = (request) => {
    const date = request.night ?? '2026-10-24';
    const offset = (Date.parse(`${date}T00:00:00Z`) - Date.parse('2026-10-24T00:00:00Z'));
    return night({ night: date, view: request.view, from: FROM + offset, to: TO + offset, serverTime: NOW, entries: [], counts: { unexplained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 0 } });
  };
  const { page, el, calls } = pageWith({ log });
  await settle();
  assert.match(shown(el), /Last night: 0 unexplained, 0 explained/);
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

test('an entry named in the address opens its group and is marked', async () => {
  const { page, el } = pageWith({ query: 'entry=s2' });
  await settle();
  assert.equal(detailsOf(el, 'satellites').open, true, 'its group is open');
  assert.equal(detailsOf(el, 'planes').open, false, 'and the others are not');
  const row = byClass(el, 'sky-row').find((node) => node.dataset.entry === 's2');
  assert.ok(row);
  assert.ok(row.classList.contains('sky-target'));
  page.destroy();

  const direct = pageWith({ query: 'entry=u1' });
  await settle();
  assert.ok(byClass(direct.el, 'sky-entry')[0].classList.contains('sky-target'), 'an unexplained one is marked in place');
  direct.page.destroy();
});

test('a camera picker only when more than one camera watches the sky', async () => {
  const other = cameraOf(OTHER, 'Garden Sky');
  const quiet = cameraOf('0A1B2C3D-0000-4000-8000-000000000009', 'Porch', { skyDetector: { enabled: false } });
  const one = pageWith({ cameras: [northSky(), quiet] });
  await settle();
  assert.ok(all(one.el, (node) => node.localName === 'select').every((select) => !visible(select)), 'one camera: nothing to pick');
  one.page.destroy();

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

test('the box still learning is said at the top; the aim by lens and the stream are in the status', async () => {
  const learning = { ready: false, planes: 12, satellites: 0 };
  const rough = { quality: 'rough', planes: 0, stars: 0, residualPixels: null, lenses: [], note: null };
  const { page, el } = pageWith({ log: night({ learning, aim: rough }), cameras: [northSky({ status: { connection: 'online', sky: { ...SKY_STATUS, aim: rough, learning } } })] });
  await settle();
  const text = shown(el);
  assert.match(text, /Still learning this sky: 12 of 30 planes matched\. No alerts until then\./);
  const status = shown(byClass(el, 'sky-status')[0]);
  assert.match(status, /Left lens: rough/);
  assert.match(status, /Right lens: rough/);
  assert.match(status, /Flight matching is loose until the aim is good\./);
  assert.match(status, /Watching the main stream at 1920 px, 5 pictures a second/);
  page.destroy();

  const ready = pageWith();
  await settle();
  assert.doesNotMatch(shown(ready.el), /Still learning/);
  const good = shown(byClass(ready.el, 'sky-status')[0]);
  assert.match(good, /Left lens: good, 23 planes matched, 14 px/);
  assert.match(good, /Right lens: precise, 214 stars matched, 1.8 px/);
  assert.doesNotMatch(good, /Flight matching is loose/);
  ready.page.destroy();
});

test('Sky Watcher off for the camera is said, with the way to turn it on; its past nights can still be read', async () => {
  const { page, el } = pageWith({ cameras: [northSky({ skyDetector: { ...WATCHING, enabled: false } }), cameraOf(OTHER, 'Garden Sky')] });
  await settle();
  assert.match(shown(el), /Sky Watcher is off for this camera\./);
  assert.equal(link(el, 'Turn it on').getAttribute('href'), `#/camera/${SKY}`);
  assert.match(shown(el), /Last night: 1 unexplained, 11 explained/, 'the log is there');
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

  const empty = pageWith({ log: night({ entries: [], counts: { unexplained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 0 }, conditions: [] }) });
  await settle();
  assert.match(shown(empty.el), /Last night: 0 unexplained, 0 explained/);
  assert.match(shown(empty.el), /Nothing crossed the sky in this time\./);
  empty.page.destroy();

  const calm = pageWith({ log: night({ entries: entriesOfANight().filter((entry) => entry.label !== 'unexplained'), counts: { ...COUNTS, unexplained: 0 } }) });
  await settle();
  assert.match(shown(calm.el), /Nothing unexplained\. Everything that crossed the sky was a plane, a satellite, a meteor, a bug or a bird\./);
  calm.page.destroy();

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
  const newer = night({ night: '2026-10-22', entries: [], counts: { unexplained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 0 } });
  const older = night({ night: '2026-10-23', entries: [], counts: { unexplained: 5, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 0 } });
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
    const route = mod.renderSkyLog({ params: [SKY, 'view=day'], setTitle: (title) => titles.push(title) });
    assert.deepEqual(titles, ['Sky Watcher']);
    assert.equal(typeof route.destroy, 'function');
    assert.ok(route.el);
    route.destroy();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.ok(mod.SKY_ROUTE.test(`sky/${SKY}?entry=abc`));
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
