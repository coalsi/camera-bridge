// Notifications on the page: the toasts that slide in and fade away (6 s, a warning up to 10 s, paused by the pointer or the keyboard, at most
// three, newest on top), shown once per thing that happened (the box hands each to one browser, once), the Notifications page (list,
// filter, read), and no banner for a notice any more. In the fake browser, timers and the bridge's answers made up.
import assert from 'node:assert/strict';
import { after, afterEach, before, beforeEach, mock, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let notifications;
let page;
let banners;
let store;
const realFetch = () => globalThis.fetch;
let savedFetch;
before(async () => {
  browser = installFakeBrowser();
  savedFetch = realFetch();
  notifications = await import('../web/js/notifications.js');
  page = await import('../web/js/screens/notifications.js');
  banners = await import('../web/js/screens/banners.js');
  store = await import('../web/js/store.js');
});
after(() => browser?.restore());
beforeEach(() => mock.timers.enable({ apis: ['setTimeout', 'Date'] }));
afterEach(() => { mock.timers.reset(); notifications.clearToasts(); globalThis.fetch = savedFetch; });

const PATIO = '0A1B2C3D-0000-4000-8000-000000000011';
const NOW = Date.parse('2026-10-22T15:00:00Z');
const entry = (overrides = {}) => ({
  id: `e-${Math.random()}`, key: 'k', noticeID: 'guard-tried', kind: 'internetGuard', category: 'security', severity: 'info',
  title: 'Patio New tried to reach the internet', detail: 'Camera Bridge blocked it. Nothing got out.', cameraID: PATIO, cameraName: 'Patio New',
  action: 'open-camera', date: new Date(NOW).toISOString(), read: false, toasted: false, ...overrides,
});

function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList.contains(name));
const buttons = (root) => all(root, (node) => node.localName === 'button');
const host = () => document.getElementById('notifications');
const shown = () => host().childNodes.filter((node) => node.tagName && !node.classList.contains('leaving'));
const settle = () => new Promise((resolve) => setImmediate(resolve));

/** A bridge that answers the notification routes; `calls` records them. */
function fakeBridge({ list = [], shown: toShow = [], unread = 0 } = {}) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const path = String(url).replace('/api/v1/', '');
    calls.push({ path, method: init.method, body: init.body ? JSON.parse(init.body) : undefined });
    const body = path === 'notifications' ? { unread, notifications: list } : path === 'notifications/shown' ? { shown: toShow.splice(0), unread } : { unread: 0 };
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => body, text: async () => JSON.stringify(body) };
  };
  return calls;
}

test('a toast fades after 6 s, a warning after 10 s; they are announced as status and alert', () => {
  notifications.showToast(entry());
  notifications.showToast(entry({ severity: 'warning', title: 'Recording Can’t Continue', action: null }));
  const [warning, info] = shown();
  assert.equal(info.getAttribute('role'), 'status');
  assert.equal(warning.getAttribute('role'), 'alert');
  mock.timers.tick(5999);
  assert.equal(shown().length, 2);
  mock.timers.tick(1);
  assert.ok(info.classList.contains('leaving'), 'it starts to fade');
  mock.timers.tick(notifications.LEAVE_MS);
  assert.equal(info.parentNode, null, 'and is gone');
  mock.timers.tick(10_000 - 6000 - notifications.LEAVE_MS - 1);
  assert.ok(warning.parentNode && !warning.classList.contains('leaving'), 'a warning stays up to 10 s');
  mock.timers.tick(1);
  assert.ok(warning.classList.contains('leaving'));
  assert.ok(notifications.WARNING_MS <= 10_000 && notifications.TOAST_MS === 6000);
});

test('the pointer or the keyboard focus pauses the timer, and leaving lets it run out', () => {
  notifications.showToast(entry());
  const [toast] = shown();
  mock.timers.tick(4000);
  toast.dispatchEvent({ type: 'mouseenter' });
  mock.timers.tick(60_000);
  assert.ok(!toast.classList.contains('leaving'), 'held while the pointer is on it');
  toast.dispatchEvent({ type: 'mouseleave' });
  mock.timers.tick(1999);
  assert.ok(!toast.classList.contains('leaving'));
  mock.timers.tick(1);
  assert.ok(toast.classList.contains('leaving'), 'the rest of its time, 2 s, ran out');

  notifications.showToast(entry());
  const focused = shown()[0];
  focused.dispatchEvent({ type: 'focusin' });
  mock.timers.tick(30_000);
  assert.ok(!focused.classList.contains('leaving'), 'held while it has the focus');
  focused.dispatchEvent({ type: 'focusout' });
  mock.timers.tick(6000);
  assert.ok(focused.classList.contains('leaving'));
});

test('at most three are on screen, the newest on top, and each has a close button', () => {
  for (const n of [1, 2, 3, 4]) notifications.showToast(entry({ title: `Notice ${n}`, action: null }));
  const titles = shown().map((node) => byClass(node, 'notif-title')[0].textContent);
  assert.deepEqual(titles, ['Notice 4', 'Notice 3', 'Notice 2'], 'the oldest made room');
  const close = buttons(shown()[0]).find((node) => node.getAttribute('aria-label') === 'Close');
  assert.ok(close, 'a close button a keyboard can reach');
  close.click();
  mock.timers.tick(notifications.LEAVE_MS);
  assert.deepEqual(shown().map((node) => byClass(node, 'notif-title')[0].textContent), ['Notice 3', 'Notice 2']);
});

test('clicking a toast does its action and puts it away; a swipe to the side dismisses it', () => {
  location.hash = '#/cameras';
  notifications.showToast(entry());
  const [toast] = shown();
  const open = buttons(toast).find((node) => node.classList.contains('notif-body'));
  assert.match(open.textContent, /See its Security card/);
  open.click();
  assert.equal(location.hash, `#/camera/${PATIO}/security`);
  assert.ok(toast.classList.contains('leaving'));

  notifications.showToast(entry({ action: null }));
  const swiped = shown()[0];
  swiped.dispatchEvent({ type: 'pointerdown', clientX: 300, pointerId: 1 });
  swiped.dispatchEvent({ type: 'pointermove', clientX: 340, pointerId: 1 });
  assert.match(swiped.style.transform, /translateX\(40px\)/);
  swiped.dispatchEvent({ type: 'pointerup', clientX: 340, pointerId: 1 });
  assert.ok(!swiped.classList.contains('leaving'), 'a short drag springs back');
  swiped.dispatchEvent({ type: 'pointerdown', clientX: 300, pointerId: 1 });
  swiped.dispatchEvent({ type: 'pointermove', clientX: 420, pointerId: 1 });
  swiped.dispatchEvent({ type: 'pointerup', clientX: 420, pointerId: 1 });
  assert.ok(swiped.classList.contains('leaving'), 'a long one dismisses it');
});

test('a toast shows only once: the box hands each notice to one browser, and nothing comes back on reload', async () => {
  const calls = fakeBridge({ shown: [entry({ title: 'First' })], unread: 1 });
  await notifications.checkNotifications();
  assert.deepEqual(shown().map((node) => byClass(node, 'notif-title')[0].textContent), ['First']);
  assert.equal(calls[0].path, 'notifications/shown');
  assert.equal(notifications.unreadCount(), 1);
  notifications.clearToasts();
  await notifications.checkNotifications();   // a reload, another page, another browser: the box has nothing new to hand out
  assert.equal(shown().length, 0);
});

test('nothing is claimed while the page is hidden; it is claimed when it is shown again', async () => {
  const calls = fakeBridge({ shown: [entry()] });
  document.visibilityState = 'hidden';
  try {
    await notifications.checkNotifications();
    assert.equal(calls.length, 0);
  } finally {
    document.visibilityState = 'visible';
  }
  await notifications.checkNotifications();
  assert.equal(shown().length, 1);
});

test('the Notifications page lists newest first, filters by section, and opening it marks what it shows as read', async () => {
  const list = [
    entry({ id: 'a', category: 'security', title: 'Patio New tried to reach the internet' }),
    entry({ id: 'b', category: 'recording', severity: 'warning', title: 'Recording Storage Almost Full', action: 'open-settings', cameraID: null }),
    entry({ id: 'c', category: 'system', title: 'Old one', read: true, action: null }),
  ];
  const calls = fakeBridge({ list, unread: 2 });
  const screen = page.renderNotifications({ params: [], navigate() {}, setTitle() {} });
  await settle(); await settle();
  const titles = () => byClass(screen.el, 'notif-title').map((node) => node.textContent);
  assert.deepEqual(titles(), ['Patio New tried to reach the internet', 'Recording Storage Almost Full', 'Old one']);
  assert.deepEqual(buttons(screen.el).filter((node) => node.classList.contains('chip')).map((node) => node.textContent), ['All', 'Security', 'Recording', 'Cameras', 'System']);
  const read = calls.find((call) => call.path === 'notifications/read');
  assert.deepEqual(read.body, { ids: ['a', 'b'] }, 'the unread ones it shows are marked read');
  assert.equal(notifications.unreadCount(), 0);
  assert.equal(byClass(screen.el, 'unread').length, 2, 'they still look new while the page is open');

  buttons(screen.el).find((node) => node.textContent === 'Recording').click();
  assert.deepEqual(titles(), ['Recording Storage Almost Full']);
  assert.deepEqual(buttons(screen.el).filter((node) => node.classList.contains('btn')).map((node) => node.textContent).sort(), ['Mark all as read', 'Open Recording settings']);
  buttons(screen.el).find((node) => node.textContent === 'Mark all as read').click();
  await settle();
  assert.deepEqual(calls.at(-1), { path: 'notifications/read', method: 'POST', body: {} });
  screen.destroy();
});

test('an empty Notifications page says so', async () => {
  fakeBridge({ list: [] });
  const screen = page.renderNotifications({ params: [], navigate() {}, setTitle() {} });
  await settle(); await settle();
  assert.match(screen.el.textContent, /Nothing yet/);
  screen.destroy();
});

test('relative times read now, minutes, hours and days', () => {
  const at = (ms) => notifications.relativeTime(new Date(NOW - ms).toISOString(), NOW);
  assert.deepEqual([at(5_000), at(2 * 60_000), at(3 * 3600_000), at(26 * 3600_000), at(5 * 86_400_000)], ['now', '2 min ago', '3 h ago', 'Yesterday', '5 days ago']);
});

test('there are no banners for notices any more: only the bridge’s own state is a status line', () => {
  assert.equal(banners.noticeBanner, undefined);
  assert.equal(banners.noticeHidden, undefined);
  store.store.notices = [{ id: 'nvr-storage', kind: 'nvrStorage', severity: 'warning', title: 'Recording Can’t Continue', detail: 'd', action: 'open-settings' }];
  store.store.bridge = { state: 'running', stateText: 'Running' };
  const running = banners.banners();
  assert.equal(running.childNodes.length, 0, 'a running bridge has no line, whatever notices there are');
  store.store.bridge = { state: 'paused', stateText: 'Paused' };
  const paused = banners.banners();
  assert.match(paused.textContent, /The bridge is paused/);
  assert.equal(byClass(paused, 'banner').length, 1);
  running.destroy(); paused.destroy();
  store.store.notices = [];
  store.store.bridge = { state: 'running', stateText: 'Running' };
});
