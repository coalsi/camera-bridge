// The Internet guard's notification on the page (notifications.js): its button opens the camera's page at its Security card
// (#/camera/<id>/security, screens/camera.js), or, when that camera's page is already on screen, brings the card into view there without
// building the page again. The other actions keep their one button. In the fake browser, with made-up cameras.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { FakeElement, installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let banners;
let notifications;
let cameraPage;
let store;
before(async () => {
  browser = installFakeBrowser();
  banners = await import('../web/js/notifications.js');
  notifications = banners;
  cameraPage = await import('../web/js/screens/camera.js');
  store = await import('../web/js/store.js');
});
after(() => browser?.restore());

const PATIO = '0A1B2C3D-0000-4000-8000-000000000011';
const DOOR = '0A1B2C3D-0000-4000-8000-000000000012';
const GARAGE = '0A1B2C3D-0000-4000-8000-000000000013';
const SHED = '0A1B2C3D-0000-4000-8000-000000000014';
const NOW = Date.parse('2026-10-18T15:00:00Z');

/** A notification of the Internet guard (the bridge's log entry): a camera seen trying the internet, blocked. */
const guardEntry = (overrides = {}) => ({
  id: 'e1', key: 'k', noticeID: `guard-tried-${PATIO}`, kind: 'internetGuard', category: 'security', severity: 'info', title: 'Patio New tried to reach the internet',
  detail: 'Camera Bridge blocked it. Nothing got out.', cameraID: PATIO, cameraName: 'Patio New', date: new Date(NOW).toISOString(), action: 'open-camera',
  read: false, toasted: false, ...overrides,
});

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList.contains(name));
const buttons = (root) => all(root, (node) => node.localName === 'button');
const settle = () => new Promise((resolve) => setImmediate(resolve));

/** Records what the page scrolls into view and focuses (the fake browser lays nothing out). */
function watchScrolling() {
  const scrolled = [];
  const focused = [];
  const saved = { scrollIntoView: FakeElement.prototype.scrollIntoView, focus: FakeElement.prototype.focus };
  FakeElement.prototype.scrollIntoView = function scrollIntoView(options) { scrolled.push({ el: this, options }); };
  FakeElement.prototype.focus = function focus(options) { focused.push({ el: this, options }); };
  return { scrolled, focused, restore() { Object.assign(FakeElement.prototype, saved); } };
}

/** Listens for the page's "show the Security card" request on window. */
function watchRequests() {
  const asked = [];
  const listener = (event) => asked.push(event.detail);
  window.addEventListener(banners.SHOW_SECURITY_EVENT, listener);
  return { asked, stop: () => window.removeEventListener(banners.SHOW_SECURITY_EVENT, listener) };
}

const open = (entry) => notifications.notificationActions(entry);

test('the guard’s notification has one button, to the camera’s Security card', () => {
  assert.deepEqual(open(guardEntry()).map((action) => action.label), ['See its Security card']);
  location.hash = '#/cameras';
  open(guardEntry({ cameraID: DOOR }))[0].run();
  assert.equal(location.hash, `#/camera/${DOOR}/security`);
  assert.equal(banners.securityAddress(GARAGE), `#/camera/${GARAGE}/security`);
  location.hash = `#/camera/${PATIO}/watch`;   // the recordings of another camera: a page of its own
  open(guardEntry({ cameraID: GARAGE }))[0].run();
  assert.equal(location.hash, `#/camera/${GARAGE}/security`);
});

test('on that camera’s page already, the page is asked to show the card instead, and the address stays', () => {
  const requests = watchRequests();
  try {
    const run = open(guardEntry({ cameraID: DOOR }))[0].run;
    for (const hash of [`#/camera/${DOOR}`, `#/camera/${DOOR}/security`, `#/camera/${DOOR.toLowerCase()}`]) {
      location.hash = hash;
      run();
      assert.equal(location.hash, hash, hash);
    }
    assert.deepEqual(requests.asked, [DOOR, DOOR, DOOR.toLowerCase()]);
    location.hash = `#/camera/${PATIO}`;
    run();
    assert.equal(location.hash, `#/camera/${DOOR}/security`, 'another camera’s page: go to this one');
    assert.equal(requests.asked.length, 3);
  } finally {
    requests.stop();
  }
});

test('an entry without a usable camera gets no button; the other actions keep theirs; an unknown action gets none', () => {
  assert.deepEqual(open(guardEntry({ cameraID: null })), []);
  assert.deepEqual(open(guardEntry({ cameraID: 'not-an-id' })), []);
  assert.deepEqual(open(guardEntry({ action: null })), []);
  const storage = { id: 'nvr-storage', kind: 'nvrStorage', severity: 'warning', title: 'Recording Can’t Continue', detail: 'd', date: '', action: 'open-settings' };
  const shown = open(storage);
  assert.deepEqual(shown.map((action) => action.label), ['Open Recording settings']);
  shown[0].run();
  assert.equal(location.hash, '#/settings/recording');
  assert.equal(open({ ...storage, action: 'choose-folder' })[0].label, 'Choose where to record');
  for (const action of ['open-door', 'toString', 'constructor']) assert.equal(open({ ...storage, action }).length, 0, action);
  const other = { id: 'x', kind: 'liveViewNotReceived', severity: 'warning', title: 't', detail: 'd', cameraID: PATIO, cameraName: 'Patio New', action: 'open-camera' };
  const opens = open(other);
  assert.deepEqual(opens.map((action) => action.label), ['Open Patio New'], 'another notice that opens a camera opens its page');
  opens[0].run();
  assert.equal(location.hash, `#/camera/${PATIO}`);
});

test('#/camera/<id>/security is the camera page, with the card asked for; the camera’s other pages are not', () => {
  const route = cameraPage.CAMERA_ROUTE;
  assert.deepEqual(route.exec(`camera/${DOOR}`).slice(1), [DOOR, undefined]);
  assert.deepEqual(route.exec(banners.securityAddress(DOOR).replace(/^#\//, '')).slice(1), [DOOR, 'security']);
  for (const path of [`camera/${DOOR}/pair`, `camera/${DOOR}/watch`, `camera/${DOOR}/securityx`, 'camera/nope/security']) assert.equal(route.exec(path), null, path);
});

// MARK: The camera page

const guardSecurity = () => ({
  level: 'yellow', title: 'Needs work', summary: 'Nothing Camera Bridge read opens this camera to the outside, but something needs work.',
  checkedAt: new Date(NOW - 30 * 60_000).toISOString(), findings: [],
  guard: { watched: true, today: 3, last24h: 3, names: [{ name: '*.p2p.example.com', count: 3, first: new Date(NOW - 3_600_000).toISOString(), last: new Date(NOW - 60_000).toISOString() }] },
});

async function cameraOnPage(params) {
  const { CAMERA_DEFINITIONS, cameraConfiguration } = await import('../web-dev/lib/cameras.mjs');
  const start = { ...cameraConfiguration(CAMERA_DEFINITIONS[1]), id: DOOR, name: 'Doorbell', vendorName: 'ONVIF',
    status: { connection: 'online', summary: 'Live', recentEvents: [], security: guardSecurity(), nvr: { state: 'off', detail: null, pause: null, notes: [] } } };
  store.store.cameras.set(DOOR, start);
  const page = cameraPage.renderCamera({ params, navigate() {}, setTitle() {} });
  browser.document.append(page.el);   // on screen, as app.js puts it (only a card on the page can be scrolled to)
  return { el: page.el, destroy() { page.destroy(); page.el.remove(); } };
}

test('the camera page at #/camera/<id>/security scrolls its Security card into view once it is there and gives its heading the focus', async () => {
  globalThis.Image = class { set src(value) { this.value = value; } get src() { return this.value; } };   // the preview's snapshots
  const watch = watchScrolling();
  const page = await cameraOnPage([DOOR, 'security']);
  try {
    await settle();
    await settle();
    const card = byClass(page.el, 'sec-card')[0];
    assert.ok(card, 'the Security card is on the page');
    assert.equal(watch.scrolled.length, 1, 'scrolled once');
    assert.ok(watch.scrolled[0].el === card, 'to the Security card');
    assert.deepEqual(watch.scrolled[0].options, { block: 'start' });
    const heading = all(card, (node) => node.localName === 'h2')[0];
    assert.equal(heading.textContent, 'Security');
    assert.equal(heading.getAttribute('tabindex'), '-1', 'the heading can take the focus');
    assert.deepEqual(watch.focused.filter((entry) => entry.el === heading).map((entry) => entry.options), [{ preventScroll: true }]);
    assert.match(card.textContent, /\*\.p2p\.example\.com3 times(?: · first .*)? · last .*Likely .* cloud or phone-app connection\./, 'what it tried is explained there');

    // The banner's button on this page: the card comes into view again, nothing is built again.
    window.dispatchEvent(new CustomEvent(banners.SHOW_SECURITY_EVENT, { detail: DOOR }));
    assert.equal(watch.scrolled.length, 2);
    assert.ok(watch.scrolled[1].el === card, 'the same card');
    window.dispatchEvent(new CustomEvent(banners.SHOW_SECURITY_EVENT, { detail: PATIO }));
    assert.equal(watch.scrolled.length, 2, 'another camera’s request is not this page’s');
  } finally {
    page.destroy();
    watch.restore();
    store.store.cameras.clear();
    delete globalThis.Image;
  }
  const after = watchScrolling();
  try {
    window.dispatchEvent(new CustomEvent(banners.SHOW_SECURITY_EVENT, { detail: DOOR }));
    assert.equal(after.scrolled.length, 0, 'a page that went away no longer listens');
  } finally {
    after.restore();
  }
});

test('the camera page at #/camera/<id> stays at the top until a notification asks for the card', async () => {
  globalThis.Image = class { set src(value) { this.value = value; } get src() { return this.value; } };
  const watch = watchScrolling();
  const page = await cameraOnPage([DOOR, undefined]);
  try {
    await settle();
    await settle();
    assert.equal(watch.scrolled.length, 0);
    location.hash = `#/camera/${DOOR}`;
    open(guardEntry({ cameraID: DOOR }))[0].run();
    assert.equal(location.hash, `#/camera/${DOOR}`, 'the page is not built again');
    assert.equal(watch.scrolled.length, 1);
    assert.ok(watch.scrolled[0].el === byClass(page.el, 'sec-card')[0], 'to the Security card');
  } finally {
    page.destroy();
    watch.restore();
    store.store.cameras.clear();
    delete globalThis.Image;
  }
});
