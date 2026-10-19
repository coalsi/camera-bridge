// The Internet guard's notice on the page (screens/banners.js): a button for each camera that tried, most first and at most three, each
// opening that camera's page at its Security card (#/camera/<id>/security, screens/camera.js), or, when that camera's page is already on
// screen, bringing the card into view there without building the page again; a notice from an older bridge (only cameraID) still gets its
// one button. In the fake browser, with made-up cameras.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { FakeElement, installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let banners;
let cameraPage;
let store;
before(async () => {
  browser = installFakeBrowser();
  banners = await import('../web/js/screens/banners.js');
  cameraPage = await import('../web/js/screens/camera.js');
  store = await import('../web/js/store.js');
});
after(() => browser?.restore());

const PATIO = '0A1B2C3D-0000-4000-8000-000000000011';
const DOOR = '0A1B2C3D-0000-4000-8000-000000000012';
const GARAGE = '0A1B2C3D-0000-4000-8000-000000000013';
const SHED = '0A1B2C3D-0000-4000-8000-000000000014';
const NOW = Date.parse('2026-10-18T15:00:00Z');

const guardNotice = (overrides = {}) => ({
  id: 'internet-guard', kind: 'internetGuard', severity: 'info', title: 'Cameras Tried to Reach the Internet',
  detail: 'Internet guard blocked 15 lookups from 4 cameras today. Patio New tried 9 times, Doorbell 3 times, Garage 2 times, and 1 more camera.',
  cameraID: PATIO, cameraName: 'Patio New', date: new Date(NOW).toISOString(), action: 'open-camera',
  cameras: [
    { id: PATIO, name: 'Patio New', today: 9, mostAsked: '*.p2p.example.com' },
    { id: DOOR, name: 'Doorbell', today: 3, mostAsked: null },
    { id: GARAGE, name: 'Garage', today: 2, mostAsked: 'time.example.org' },
    { id: SHED, name: 'Shed', today: 1, mostAsked: null },
  ],
  ...overrides,
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

test('the guard’s notice gives a button for each camera that tried, most first and at most three, the first one primary', () => {
  const banner = banners.noticeBanner(guardNotice());
  assert.match(banner.textContent, /Patio New tried 9 times, Doorbell 3 times, Garage 2 times, and 1 more camera\./, 'the bridge’s text says who');
  const shown = buttons(banner);
  assert.deepEqual(shown.map((node) => node.textContent), ['See what Patio New tried', 'See what Doorbell tried', 'See what Garage tried']);
  assert.deepEqual(shown.map((node) => node.className), ['btn small primary', 'btn small', 'btn small']);
  assert.deepEqual(shown.map((node) => node.getAttribute('title')), ['Most asked: *.p2p.example.com', null, 'Most asked: time.example.org'],
    'each button’s tooltip is the name it asked for most, as the bridge shows it (none when the box listed none)');
  assert.ok(shown.every((node) => node.getAttribute('type') === 'button'));
  assert.equal(banners.NOTICE_CAMERA_BUTTONS, 3);
});

test('a button opens that camera’s page at its Security card', () => {
  location.hash = '#/cameras';
  const shown = buttons(banners.noticeBanner(guardNotice()));
  shown[1].click();
  assert.equal(location.hash, `#/camera/${DOOR}/security`);
  assert.equal(banners.securityAddress(GARAGE), `#/camera/${GARAGE}/security`);
  location.hash = `#/camera/${PATIO}/watch`;   // the recordings of another camera: a page of its own
  shown[2].click();
  assert.equal(location.hash, `#/camera/${GARAGE}/security`);
});

test('on that camera’s page already, the page is asked to show the card instead, and the address stays', () => {
  const requests = watchRequests();
  try {
    const shown = buttons(banners.noticeBanner(guardNotice()));
    for (const hash of [`#/camera/${DOOR}`, `#/camera/${DOOR}/security`, `#/camera/${DOOR.toLowerCase()}`]) {
      location.hash = hash;
      shown[1].click();
      assert.equal(location.hash, hash, hash);
    }
    assert.deepEqual(requests.asked, [DOOR, DOOR, DOOR.toLowerCase()]);
    location.hash = `#/camera/${PATIO}`;
    shown[1].click();
    assert.equal(location.hash, `#/camera/${DOOR}/security`, 'another camera’s page: go to this one');
    assert.equal(requests.asked.length, 3);
  } finally {
    requests.stop();
  }
});

test('a notice from an older bridge (no cameras list) still opens the camera that tried most; odd entries get no button', () => {
  store.store.cameras.set(GARAGE, { id: GARAGE, name: 'Garage (store)' });
  try {
    const old = guardNotice({ cameras: undefined, detail: 'Internet guard blocked 15 lookups from 4 cameras today.' });
    assert.deepEqual(buttons(banners.noticeBanner(old)).map((node) => node.textContent), ['See what Patio New tried']);
    const odd = guardNotice({ cameras: [null, { id: 'not-an-id', name: 'X' }, { id: GARAGE, name: '' }, { id: DOOR, name: 'Doorbell' }] });
    assert.deepEqual(buttons(banners.noticeBanner(odd)).map((node) => node.textContent), ['See what Garage (store) tried', 'See what Doorbell tried'],
      'a camera without a name takes the page’s');
    assert.equal(buttons(banners.noticeBanner(guardNotice({ cameras: [], cameraID: null }))).length, 0);
    for (const cameras of [[], [null, { id: 'nope', name: 'X' }]]) {
      assert.deepEqual(buttons(banners.noticeBanner(guardNotice({ cameras }))).map((node) => node.textContent), ['See what Patio New tried'],
        'an empty or unusable list falls back to the camera that tried most');
    }
    assert.equal(buttons(banners.noticeBanner(guardNotice({ action: null }))).length, 0);
  } finally {
    store.store.cameras.clear();
  }
});

test('the other actions keep their one button; an action the page does not know gets none', () => {
  const storage = { id: 'nvr-storage', kind: 'nvrStorage', severity: 'warning', title: 'Recording Can’t Continue', detail: 'd', date: '', action: 'open-settings' };
  const shown = buttons(banners.noticeBanner(storage));
  assert.deepEqual(shown.map((node) => [node.textContent, node.className]), [['Open Recording settings', 'btn small primary']]);
  shown[0].click();
  assert.equal(location.hash, '#/settings/recording');
  assert.equal(buttons(banners.noticeBanner({ ...storage, action: 'choose-folder' }))[0].textContent, 'Choose where to record');
  for (const action of ['open-door', 'toString', 'constructor']) assert.equal(buttons(banners.noticeBanner({ ...storage, action })).length, 0, action);
  const other = { id: 'x', kind: 'liveViewNotReceived', severity: 'warning', title: 't', detail: 'd', cameraID: PATIO, cameraName: 'Patio New', action: 'open-camera' };
  const open = buttons(banners.noticeBanner(other));
  assert.deepEqual(open.map((node) => node.textContent), ['Open Patio New'], 'another notice that opens a camera opens its page');
  open[0].click();
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
    assert.match(card.textContent, /\*\.p2p\.example\.com3 times · first .* · last .*Likely .* cloud or phone-app connection\./, 'what it tried is explained there');

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

test('the camera page at #/camera/<id> stays at the top until the banner asks for the card', async () => {
  globalThis.Image = class { set src(value) { this.value = value; } get src() { return this.value; } };
  const watch = watchScrolling();
  store.store.notices = [guardNotice()];
  const page = await cameraOnPage([DOOR, undefined]);
  try {
    await settle();
    await settle();
    assert.equal(watch.scrolled.length, 0);
    location.hash = `#/camera/${DOOR}`;
    const button = buttons(page.el).find((node) => node.textContent === 'See what Doorbell tried');
    assert.ok(button, 'the banner on the camera page has the button');
    button.click();
    assert.equal(location.hash, `#/camera/${DOOR}`, 'the page is not built again');
    assert.equal(watch.scrolled.length, 1);
    assert.ok(watch.scrolled[0].el === byClass(page.el, 'sec-card')[0], 'to the Security card');
  } finally {
    page.destroy();
    watch.restore();
    store.store.cameras.clear();
    store.store.notices = [];
    delete globalThis.Image;
  }
});
