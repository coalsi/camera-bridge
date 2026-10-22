// Notifications on the page. The bridge keeps a log of everything that was a notice (GET notifications, the Notifications page); this file
// shows each new one once as a toast that slides in at the top right and fades away (6 s, a warning up to 10 s; the pointer or the keyboard
// focus holds it), and counts the ones not read for the menu. "Once": the bridge hands each notice to one browser (POST notifications/shown),
// so it does not come back on a reload, on another page, or in another browser. Nothing is kept in this browser.
import { post } from './api.js';
import { h, toast } from './dom.js';
import { icon } from './icons.js';
import { loadNVR } from './nvr/lite.js';
import { subscribe } from './store.js';

export const TOAST_MS = 6000;
export const WARNING_MS = 10_000;
export const LEAVE_MS = 300;
export const MAX_TOASTS = 3;
/** A drag this far to the side puts a toast away. */
const SWIPE_PX = 80;

// ---- the camera's Security card ---------------------------------------------------------------------------------------------------

/** Asks the camera page on screen to bring its Security card into view again: `detail` is the camera's id (camera.js listens on window). */
export const SHOW_SECURITY_EVENT = 'cb-show-security';

/** The address of a camera's page opened at its Security card (app.js routes it to camera.js, which scrolls to the card). */
export function securityAddress(id) {
  return `#/camera/${id}/security`;
}

const CAMERA_ID = /^[0-9A-Fa-f-]{36}$/;

/**
 * Opens camera `id`'s page at its Security card. When that camera's page is already on screen (with or without the card in its address),
 * the page is asked to show the card again instead (`SHOW_SECURITY_EVENT`), so nothing on it is built again.
 */
export function openCameraSecurity(id) {
  const shownNow = /^#\/?camera\/([0-9A-Fa-f-]{36})(?:\/security)?\/?$/.exec(location.hash);
  if (shownNow && shownNow[1].toLowerCase() === String(id).toLowerCase()) {
    window.dispatchEvent(new CustomEvent(SHOW_SECURITY_EVENT, { detail: shownNow[1] }));
    return;
  }
  location.hash = securityAddress(id);
}

// ---- what a notification can do ---------------------------------------------------------------------------------------------------

async function chooseFolder() {
  const nvr = await loadNVR();
  if (!nvr) {
    toast('The recording settings could not load. Reload the page and try again.', 'error');
    return;
  }
  if (await nvr.chooseStorage({ reason: 'banner' })) toast('Saved. Recording starts again in a moment.', 'ok');
}

/**
 * The buttons of a notification (`entry.action`, set by the bridge), each { label, run }; an action this page does not know gets none.
 * "open-camera" opens the camera's page (the Internet guard's: at its Security card).
 */
export function notificationActions(entry) {
  const camera = typeof entry.cameraID === 'string' && CAMERA_ID.test(entry.cameraID) ? entry.cameraID : null;
  const name = typeof entry.cameraName === 'string' && entry.cameraName.trim() ? entry.cameraName.trim() : 'this camera';
  switch (entry.action) {
    case 'choose-folder': return [{ label: 'Choose where to record', run: chooseFolder }];
    case 'open-settings': return [{ label: 'Open Recording settings', run: () => { location.hash = '#/settings/recording'; } }];
    case 'open-camera':
      if (!camera) return [];
      return entry.kind === 'internetGuard'
        ? [{ label: 'See its Security card', run: () => openCameraSecurity(camera) }]
        : [{ label: `Open ${name}`, run: () => { location.hash = `#/camera/${camera}`; } }];
    default: return [];
  }
}

/** "now", "2 min ago", "3 h ago", "Yesterday", "5 days ago". */
export function relativeTime(iso, now = Date.now()) {
  const then = Date.parse(iso);
  if (!Number.isFinite(then)) return '';
  const seconds = Math.max(0, Math.round((now - then) / 1000));
  if (seconds < 60) return 'now';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.floor(hours / 24);
  return days === 1 ? 'Yesterday' : `${days} days ago`;
}

/** The icon of a notification: its kind, or a warning sign. */
export function notificationIcon(entry) {
  if (entry.severity === 'warning') return 'alert';
  return entry.category === 'security' ? 'shield' : entry.category === 'recording' ? 'camera' : 'info';
}

// ---- toasts -----------------------------------------------------------------------------------------------------------------------

const layers = new Set();

function toastHost() {
  return typeof document === 'undefined' ? null : document.getElementById('notifications');
}

function leave(toastEl) {
  if (toastEl.classList.contains('leaving')) return;
  toastEl.classList.add('leaving');
  setTimeout(() => toastEl.remove(), LEAVE_MS);
}

/** Shows `entry` as a toast at the top of the stack: { el, close }. */
export function showToast(entry) {
  const host = toastHost();
  if (!host) return null;
  const warning = entry.severity === 'warning';
  const actions = notificationActions(entry);
  let remaining = warning ? WARNING_MS : TOAST_MS;
  let timer = null;
  let startedAt = 0;
  let moved = false;
  let dragFrom = null;
  const start = () => {
    if (timer !== null) return;
    startedAt = Date.now();
    timer = setTimeout(() => { timer = null; leave(el); }, remaining);
  };
  const pause = () => {
    if (timer === null) return;
    clearTimeout(timer);
    timer = null;
    remaining = Math.max(1000, remaining - (Date.now() - startedAt));
  };
  const close = () => { pause(); leave(el); };
  const text = [h('span', { class: 'notif-title' }, entry.title), h('span', { class: 'notif-detail' }, entry.detail)];
  const body = actions.length
    ? h('button', { class: 'notif-body', type: 'button', onclick: () => { if (moved) { moved = false; return; } actions[0].run(); close(); } },
      text, h('span', { class: 'notif-act' }, actions[0].label))
    : h('div', { class: 'notif-body' }, text);
  const el = h('div', { class: `notif ${warning ? 'warning' : 'info'}`, role: warning ? 'alert' : 'status' },
    icon(notificationIcon(entry)), body,
    h('span', { class: 'notif-time' }, relativeTime(entry.date)),
    h('button', { class: 'notif-close', type: 'button', 'aria-label': 'Close', onclick: close }, icon('x')));
  for (const type of ['mouseenter', 'focusin']) el.addEventListener(type, pause);
  for (const type of ['mouseleave', 'focusout']) el.addEventListener(type, start);
  el.addEventListener('pointerdown', (event) => { dragFrom = event.clientX; moved = false; pause(); });
  el.addEventListener('pointermove', (event) => {
    if (dragFrom === null) return;
    const dx = event.clientX - dragFrom;
    if (Math.abs(dx) > 6) moved = true;
    el.style.transform = `translateX(${dx}px)`;
    el.style.opacity = String(Math.max(0.2, 1 - Math.abs(dx) / 240));
  });
  const release = (event) => {
    if (dragFrom === null) return;
    const dx = event.clientX - dragFrom;
    dragFrom = null;
    if (Math.abs(dx) >= SWIPE_PX) { leave(el); return; }
    el.style.transform = '';
    el.style.opacity = '';
    start();
  };
  el.addEventListener('pointerup', release);
  el.addEventListener('pointercancel', release);
  if (host.firstChild) host.insertBefore(el, host.firstChild);
  else host.append(el);
  layers.add(host);
  const live = [...host.children].filter((node) => !node.classList.contains('leaving'));
  for (const old of live.slice(MAX_TOASTS)) old.remove();
  start();
  return { el, close };
}

/** Takes every toast off the page (a test, or signing out). */
export function clearToasts() {
  for (const host of layers) while (host.firstChild) host.removeChild(host.firstChild);
}

// ---- unread, and the once-only check ----------------------------------------------------------------------------------------------

let unread = 0;
const unreadListeners = new Set();

export function unreadCount() { return unread; }

export function setUnread(value) {
  const next = Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
  if (next === unread) return;
  unread = next;
  for (const fn of [...unreadListeners]) fn(unread);
}

/** fn(count) runs whenever the count of notifications not read changes; returns the way to stop. */
export function onUnread(fn) {
  unreadListeners.add(fn);
  return () => unreadListeners.delete(fn);
}

let checking = null;
let again = false;

/**
 * Asks the bridge for the notices not yet shown as a toast (it marks them shown, so no other browser shows them) and shows them, oldest
 * first so the newest is on top. A page nobody can see claims nothing.
 */
export function checkNotifications() {
  if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return Promise.resolve();
  if (checking) { again = true; return checking; }
  checking = (async () => {
    try {
      const answer = await post('notifications/shown');
      setUnread(answer?.unread);
      for (const entry of [...(Array.isArray(answer?.shown) ? answer.shown : [])].reverse()) showToast(entry);
    } catch (error) {
      console.error(error);
    } finally {
      checking = null;
      if (again) { again = false; checkNotifications(); }
    }
  })();
  return checking;
}

/** Starts showing notifications as the bridge reports them (when the notices change, and when the page is shown again); returns the way to stop. */
export function startNotifications() {
  const stop = subscribe((kind) => { if (kind === 'notices') checkNotifications(); });
  const visible = () => { if (document.visibilityState !== 'hidden') checkNotifications(); };
  document.addEventListener('visibilitychange', visible);
  return () => { stop(); document.removeEventListener('visibilitychange', visible); clearToasts(); };
}
