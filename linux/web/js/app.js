// Camera Bridge: the page. Starts by asking who is there (first run, signed out, signed in), then shows the shell and routes screens.
import { get, onAuthChange, patch, setCSRFToken } from './api.js';
import { h, replace, spinner, toast } from './dom.js';
import { icon } from './icons.js';
import { askToPowerOff, powerOff } from './power.js';
import { THEME_EVENT, THEME_INFO, applyTheme, currentTheme, nextTheme, setTheme } from './theme.js';
import { store, startEvents, stopEvents, subscribe, loadCameras, loadPlugins, noteVersion, pluginOn, setBridgeZone, setCameraOrder } from './store.js';
import { onUnread, startNotifications, unreadCount } from './notifications.js';
import { renderSetup, renderLogin } from './screens/auth.js';
import { renderCameras } from './screens/cameras.js';
import { renderAdd } from './screens/add.js';
import { CAMERA_ROUTE, renderCamera, renderCameraPairing, renderSensorsPairing } from './screens/camera.js';
import { renderSettings } from './screens/settings.js';
import { renderLogs } from './screens/logs.js';
import { renderSystem } from './screens/system.js';
import { renderAbout } from './screens/about.js';
import { renderEufyPlugin, renderPlugins, renderWyzePlugin } from './screens/plugins.js';
import { SKY_ROUTE, SKY_TEXT } from './screens/sky-model.js';
import { PAIR_ROUTE, isPairPath } from './screens/viewers-card.js';
import { versionLabel, whatsNewNotice } from './whats-new.js';

const root = document.getElementById('app');
let screen = null;          // { el, destroy }
let shell = null;           // { main, nav, ... } while signed in
let unsubscribe = null;
let stopNotifications = null;
let stopUnread = null;

/** Whether the Sky Watcher plugin is on (Plugins): the menu shows its item only then, whatever the cameras are set to. */
const skyIsOn = () => pluginOn('sky');

// `phone`: the items a phone's tab bar shows itself; the others are under its More button (a phone is too narrow for ten).
const NAV = [
  { href: '#/', label: 'Monitor', icon: 'monitor', match: (p) => p === '' || p === 'monitor' || p === 'nvr' || p.startsWith('nvr/'), phone: true },
  { href: '#/events', label: 'Events', icon: 'clock', match: (p) => p === 'events' || p.startsWith('events?'), phone: true },
  { href: '#/notifications', label: 'Notifications', icon: 'bell', match: (p) => p === 'notifications', phone: true },
  // Sky Watcher's morning log (#/sky, #/sky/<camera>): in the menu, and so in a phone's tab bar, only while the Sky Watcher plugin is on (showSkyMenu).
  { href: '#/sky', label: SKY_TEXT.menu, icon: 'moon', match: (p) => p === 'sky' || p.startsWith('sky/') || p.startsWith('sky?'), when: skyIsOn, phone: true },
  { href: '#/cameras', label: 'Cameras', icon: 'camera', match: (p) => p === 'cameras' || p.startsWith('camera/') || p === 'add' || (p.startsWith('pair') && !isPairPath(p)), phone: true },
  { href: '#/plugins', label: 'Plugins', icon: 'plugin', match: (p) => p === 'plugins' || p.startsWith('plugins/') },
  { href: '#/logs', label: 'Log', icon: 'list', match: (p) => p === 'logs' },
  { href: '#/system', label: 'System', icon: 'server', match: (p) => p === 'system' },
  { href: '#/settings', label: 'Settings', icon: 'sliders', match: (p) => p === 'settings' || p.startsWith('settings/') || isPairPath(p) },
  { href: '#/about', label: 'About', icon: 'info', match: (p) => p === 'about' },
];

/**
 * A screen whose code is fetched when it is first opened: a spinner meanwhile, then the screen, or a plain card if its code could not be
 * loaded. Nothing else on the page depends on it, so a broken file there cannot stop the sign-in page or the camera list.
 */
function lazy(importer, exportName) {
  return (context) => {
    const host = h('div', null, h('div', { class: 'checking' }, spinner()));
    let inner = null;
    let destroyed = false;
    Promise.resolve().then(importer).then((loaded) => {
      if (destroyed) return;
      inner = loaded[exportName](context);
      replace(host, inner.el);
    }).catch((error) => {
      console.error(error);
      if (destroyed) return;
      replace(host, h('div', { class: 'empty' }, h('h2', null, 'This page didn’t load'),
        h('p', null, 'Part of Camera Bridge could not be loaded. Reload the page to try again.'),
        h('button', { class: 'btn primary', type: 'button', onclick: () => location.reload() }, 'Reload')));
    });
    return { el: host, destroy() { destroyed = true; inner?.destroy?.(); } };
  };
}

const ROUTES = [
  // page: 'monitor' marks the shell for the Monitor (style.css: black beside the menu, the window's height from 900 px).
  { pattern: /^$/, title: 'Monitor', page: 'monitor', render: lazy(() => import('./screens/nvr.js'), 'renderNVR') },
  // The Events page keeps its filters in the address: #/events?cameras=<ids>&type=Person&saw=person&concern=notable&range=7d
  { pattern: /^events(?:\?(.*))?$/, title: 'Events', render: lazy(() => import('./screens/events.js'), 'renderEvents') },
  { pattern: /^notifications$/, title: 'Notifications', render: lazy(() => import('./screens/notifications.js'), 'renderNotifications') },
  // #/sky and #/sky/<camera>?night=yyyy-MM-dd&view=night|day&entry=<id>: the sky log (the Sky Watcher notification opens an entry).
  { pattern: SKY_ROUTE, title: SKY_TEXT.page, render: lazy(() => import('./screens/sky-log.js'), 'renderSkyLog') },
  { pattern: /^cameras$/, title: 'Cameras', render: renderCameras },
  { pattern: /^add$/, title: 'Add a camera', render: renderAdd },
  // #/camera/<id>, and #/camera/<id>/security at its Security card (the Internet guard's notice opens that).
  { pattern: CAMERA_ROUTE, title: 'Camera', render: renderCamera },
  { pattern: /^camera\/([0-9A-Fa-f-]{36})\/pair$/, title: 'Add to Apple Home', render: renderCameraPairing },
  { pattern: /^camera\/([0-9A-Fa-f-]{36})\/watch(?:\/(\d{12,13}))?$/, title: 'Recordings', render: lazy(() => import('./screens/watch.js'), 'renderWatch') },
  // The Monitor writes #/nvr/<epoch ms> while you look back in the recordings; #/monitor is its old address.
  // `?camera=<id>&play=1` comes from the Events page: that camera leads and the wall plays from the time.
  { pattern: /^nvr(?:\/(\d{12,13}))?(?:\?(.*))?$/, title: 'NVR', page: 'monitor', render: lazy(() => import('./screens/nvr.js'), 'renderNVR') },
  { pattern: /^monitor$/, title: 'Monitor', page: 'monitor', render: lazy(() => import('./screens/nvr.js'), 'renderNVR') },
  { pattern: /^pair\/sensors$/, title: 'Sensors bridge', render: renderSensorsPairing },
  // #/pair/<code> is the address in the QR code an Apple TV or iPhone shows (the iPhone's approve button opens it in Safari): Settings at the Apple TV and iPhone card, the code filled in. It adds nothing by itself.
  { pattern: PAIR_ROUTE, title: 'Settings', render: (context) => renderSettings({ ...context, params: ['apple-tv', context.params[0]] }) },
  { pattern: /^logs$/, title: 'Log', render: renderLogs },
  { pattern: /^system$/, title: 'System', render: renderSystem },
  { pattern: /^settings(?:\/(recording|ai|away))?$/, title: 'Settings', render: renderSettings },
  { pattern: /^about$/, title: 'About', render: renderAbout },
  { pattern: /^plugins$/, title: 'Plugins', render: renderPlugins },
  { pattern: /^plugins\/wyze$/, title: 'Wyze', render: renderWyzePlugin },
  { pattern: /^plugins\/eufy$/, title: 'eufy', render: renderEufyPlugin },
];

export function navigate(path) {
  if (location.hash === `#${path}`) route();
  else location.hash = path;
}

function currentPath() {
  const raw = location.hash.replace(/^#\/?/, '');
  // A mangled address (a stray "%" in a link, #/%) cannot be decoded: it is matched as it is, so it draws "That page doesn't exist" instead of
  // throwing before anything is drawn.
  let path;
  try { path = decodeURIComponent(raw); } catch { path = raw; }
  return path.replace(/\/+$/, '');
}

/** Marks the shell with the screen's kind (`data-page`), or clears it: style.css lays out the Monitor's route on its own. */
function markPage(page) {
  if (page) root.dataset.page = page;
  else delete root.dataset.page;
}

function setTitle(title) {
  document.title = title ? `${title} · ${store.session?.bridgeName || 'Camera Bridge'}` : 'Camera Bridge';
}

function route() {
  if (!shell) return;
  const path = currentPath();
  if (screen?.destroy) screen.destroy();
  screen = null;
  for (const candidate of ROUTES) {
    const match = path.match(candidate.pattern);
    if (!match) continue;
    markPage(candidate.page);
    screen = candidate.render({ params: match.slice(1), navigate, setTitle: (t) => setTitle(t || candidate.title) });
    setTitle(candidate.title);
    replace(shell.content, screen.el);
    markNav(path);
    shell.main.focus({ preventScroll: true });
    window.scrollTo(0, 0);
    return;
  }
  replace(shell.content, h('div', { class: 'empty' }, h('h2', null, 'That page doesn’t exist'), h('p', null, 'It may have moved.'),
    h('a', { class: 'btn primary', href: '#/cameras' }, 'Back to your cameras')));
  markPage(null);
  setTitle('Not found');
  markNav(path);
}

function markNav(path) {
  for (const [index, link] of shell.links.entries()) {
    if (NAV[index].match(path)) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  }
  // On a phone, the More button is marked while the page shown is one of its items, and it closes when a page opens.
  shell.more.dataset.current = String(NAV.some((item) => !item.phone && item.match(path)));
  showMore(false);
}

/** Opens or closes the phone's More list (the tab bar's items that do not fit). */
function showMore(open) {
  if (!shell) return;
  shell.nav.dataset.more = open ? 'open' : '';
  shell.more.setAttribute('aria-expanded', String(open));
}

function buildShell() {
  const name = h('span', null, store.session.bridgeName);
  const links = NAV.map((item) => h('a', { href: item.href, title: item.label, hidden: item.when ? !item.when() : false }, icon(item.icon), h('span', null, item.label),
    item.href === '#/notifications' ? h('span', { class: 'nav-badge', id: 'nav-unread', hidden: true }) : null));
  // A phone's tab bar shows the first items and a More button; the rest open above it as a list (style.css). Wider, the list is just the
  // rest of the menu and the button is not there.
  const more = h('button', { class: 'nav-more', type: 'button', 'aria-expanded': 'false', 'aria-controls': 'nav-overflow',
    onclick: () => showMore(nav.dataset.more !== 'open') }, icon('more'), h('span', null, 'More'));
  const overflow = h('div', { class: 'nav-overflow', id: 'nav-overflow' }, links.filter((_, i) => !NAV[i].phone));
  const nav = h('nav', { class: 'nav', 'aria-label': 'Main', onkeydown: (event) => { if (event.key === 'Escape' && nav.dataset.more === 'open') { showMore(false); more.focus(); } } },
    links.filter((_, i) => NAV[i].phone), overflow, more);
  const content = h('div');
  const main = h('main', { id: 'main', class: 'main', tabindex: '-1' }, content);
  const reconnect = h('div', { class: 'reconnect', role: 'status', hidden: true }, 'Lost contact with the bridge. Trying again…');
  // The bridge was updated while this page was open: its pages no longer match the ones loaded here (the Monitor reloads by itself when idle).
  const updated = h('div', { class: 'update-bar', role: 'status', hidden: true }, h('span', null, 'Camera Bridge was updated.'),
    h('button', { class: 'btn small', type: 'button', onclick: () => location.reload() }, icon('refresh'), 'Reload'));
  // The system's version (Camera Bridge OS beta · build 0.1.108, or Camera Bridge OS 1.0.0); a click opens About and its notes.
  const notice = h('div', { class: 'notice-host' });
  const version = h('a', { class: 'version', href: '#/about', title: 'About this version' });
  // Auto → Light → Dark (js/theme.js); showTheme() fills it in.
  const theme = h('button', { class: 'side-btn theme-btn', type: 'button', onclick: () => setTheme(nextTheme(currentTheme())) });
  // Shown once the bridge says it can power the machine off (Camera Bridge OS), not for a bridge running as a program.
  const power = h('button', { class: 'side-btn power-btn', type: 'button', title: 'Power off the bridge', hidden: true,
    onclick: async () => {
      if (!(await askToPowerOff())) return;
      try { await powerOff(); } catch (error) { toast(error.message, 'error'); }
    } }, icon('power'), h('span', { class: 'side-label' }, 'Power off'));
  root.classList.add('signed-in');
  replace(root,
    h('aside', { class: 'sidebar' },
      h('a', { class: 'brand', href: '#/', title: store.session.bridgeName }, h('img', { src: '/mark-small.svg?v=3', alt: '', width: 30, height: 30 }), name),
      nav,
      h('div', { class: 'sidebar-foot' }, theme, power, version)),
    h('div', { class: 'app-main' }, reconnect, updated, notice, main));
  shell = { nav, links, more, content, main, name, reconnect, updated, version, theme, sky: links[NAV.findIndex((item) => item.href === '#/sky')] };
  updated.hidden = store.newVersion === null;
  showTheme();
  stopUnread?.();
  stopUnread = onUnread(showUnread);
  showUnread(unreadCount());
  get('system').then((s) => {
    noteVersion(s.version);
    power.hidden = !s.canManage;
    version.textContent = versionLabel(s.product, s.version);
    const news = whatsNewNotice(s.version);
    if (news) notice.append(news);
  }).catch(() => {});
}

/** Sky Watcher's item in the menu: there while its plugin is on, gone while it is off. */
function showSkyMenu() {
  if (shell?.sky) shell.sky.hidden = !skyIsOn();
}

/** The count of notifications not read, in the menu: a number beside the bell, and said in the link's name. */
function showUnread(count) {
  const link = shell?.nav.querySelector('a[href="#/notifications"]');
  const badge = link?.querySelector('.nav-badge');
  if (!link || !badge) return;
  badge.hidden = count === 0;
  badge.textContent = count > 99 ? '99+' : String(count);
  link.setAttribute('aria-label', count ? `Notifications, ${count} unread` : 'Notifications');
}

/** The appearance button: the icon of the appearance in use, and what a click switches to. */
function showTheme() {
  if (!shell) return;
  const now = THEME_INFO[currentTheme()];
  const next = THEME_INFO[nextTheme(currentTheme())].label;
  replace(shell.theme, icon(now.icon), h('span', { class: 'side-label' }, `Appearance: ${now.label}`));
  shell.theme.title = `Appearance: ${now.label}. Click for ${next}.`;
  shell.theme.setAttribute('aria-label', `Appearance: ${now.label}. Switch to ${next}`);
}

async function showApp() {
  stopEvents();
  buildShell();
  unsubscribe?.();
  unsubscribe = subscribe((kind) => {
    if (kind === 'connection' && shell) shell.reconnect.hidden = store.connected;
    if (kind === 'plugins' && shell) showSkyMenu();
    if (kind === 'updated' && shell) shell.updated.hidden = false;
  });
  // Which plugins are on is asked at the same time as the cameras; the Sky Watcher's menu item and card wait for it (without it they stay out).
  const plugins = loadPlugins().catch(() => {});
  try { await loadCameras(); } catch (error) { toast(error.message, 'error'); }
  await plugins;
  // A bridge without a time zone of its own (Camera Bridge OS runs in UTC) takes the zone of the browser that signs in: the timestamp it draws
  // and the clocks it sets on cameras are then local time.
  // The settings also give the cameras' order: read before the first screen so the wall does not reshuffle.
  try {
    const settings = await get('settings');
    setCameraOrder(settings.cameraOrder);
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    // Every time on the page is said in the bridge's zone (store.js bridgeZone), the one its own label and the cameras' clocks use.
    setBridgeZone(settings.timeZone || zone);
    if (!settings.timeZone && zone) patch('settings', { timeZone: zone }).catch(() => {});
  } catch { /* the cameras are by name until the next load */ }
  stopNotifications?.();
  stopNotifications = startNotifications();
  startEvents();
  if (!location.hash) location.hash = '#/';
  route();
}

export async function showSignedIn(info) {
  store.session = { ...store.session, ...info, authenticated: true };
  if (info.csrfToken) setCSRFToken(info.csrfToken);
  await showApp();
}

function showSignedOut() {
  stopEvents();
  stopNotifications?.();
  stopNotifications = null;
  shell = null;
  root.classList.remove('signed-in');
  markPage(null);
  screen?.destroy?.();
  screen = null;
  document.title = 'Sign in · Camera Bridge';
  replace(root, renderLogin({ bridgeName: store.session?.bridgeName || 'Camera Bridge', onSignedIn: showSignedIn }));
}

function showSetup() {
  stopEvents();
  shell = null;
  root.classList.remove('signed-in');
  markPage(null);
  document.title = 'Set up · Camera Bridge';
  replace(root, renderSetup({ session: store.session, onDone: showSignedIn }));
}

// A bridge that does not answer at start-up (the box is still starting after a power cut, or its address is not up yet): the page asks again by
// itself, a little later each time, so a wall display comes back without anyone at it.
const BOOT_RETRY_MS = [5000, 10000, 20000, 30000];
let bootTries = 0;
let bootTimer = null;

async function boot() {
  clearTimeout(bootTimer);
  bootTimer = null;
  try {
    store.session = await get('session');
  } catch (error) {
    const wait = BOOT_RETRY_MS[Math.min(bootTries, BOOT_RETRY_MS.length - 1)];
    bootTries += 1;
    bootTimer = setTimeout(boot, wait);
    replace(root, h('div', { class: 'center-page' }, h('div', { class: 'card center-card' },
      h('h1', null, 'Can’t reach the bridge'), h('p', { class: 'lede' }, error.message),
      h('p', { class: 'muted small', role: 'status' }, 'Trying again by itself…'),
      h('button', { class: 'btn primary', type: 'button', onclick: () => boot() }, 'Try again'))));
    return;
  }
  bootTries = 0;
  if (store.session.setupRequired) return showSetup();
  if (!store.session.authenticated) return showSignedOut();
  setCSRFToken(store.session.csrfToken);
  await showApp();
}

onAuthChange(async (kind) => {
  if (kind === 'setup') { store.session = await get('session').catch(() => store.session); showSetup(); }
  if (kind === 'unauthorized' && shell) { store.session = { ...store.session, authenticated: false }; showSignedOut(); }
});
window.addEventListener('hashchange', route);
// A tap anywhere else closes the phone's More list.
document.addEventListener('click', (event) => { if (shell?.nav.dataset.more === 'open' && !shell.nav.contains(event.target)) showMore(false); });
document.addEventListener(THEME_EVENT, showTheme);
// Another tab of this browser chose an appearance.
window.addEventListener('storage', (event) => { if (event.key === null || event.key === 'cb-theme') applyTheme(currentTheme()); });
boot();

