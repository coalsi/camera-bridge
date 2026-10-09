// Camera Bridge: the page. Starts by asking who is there (first run, signed out, signed in), then shows the shell and routes screens.
import { get, onAuthChange, setCSRFToken } from './api.js';
import { h, replace, toast } from './dom.js';
import { icon } from './icons.js';
import { store, startEvents, stopEvents, subscribe, loadCameras } from './store.js';
import { renderSetup, renderLogin } from './screens/auth.js';
import { renderCameras } from './screens/cameras.js';
import { renderAdd } from './screens/add.js';
import { renderCamera, renderCameraPairing, renderSensorsPairing } from './screens/camera.js';
import { renderSettings } from './screens/settings.js';
import { renderLogs } from './screens/logs.js';
import { renderSystem } from './screens/system.js';

const root = document.getElementById('app');
let screen = null;          // { el, destroy }
let shell = null;           // { main, nav, ... } while signed in
let unsubscribe = null;

const NAV = [
  { href: '#/', label: 'Cameras', icon: 'camera', match: (p) => p === '' || p.startsWith('camera') || p === 'add' || p.startsWith('pair') },
  { href: '#/logs', label: 'Log', icon: 'list', match: (p) => p === 'logs' },
  { href: '#/system', label: 'System', icon: 'server', match: (p) => p === 'system' },
  { href: '#/settings', label: 'Settings', icon: 'sliders', match: (p) => p === 'settings' },
];

const ROUTES = [
  { pattern: /^$/, title: 'Cameras', render: renderCameras },
  { pattern: /^add$/, title: 'Add a camera', render: renderAdd },
  { pattern: /^camera\/([0-9A-Fa-f-]{36})$/, title: 'Camera', render: renderCamera },
  { pattern: /^camera\/([0-9A-Fa-f-]{36})\/pair$/, title: 'Add to Apple Home', render: renderCameraPairing },
  { pattern: /^pair\/sensors$/, title: 'Sensors bridge', render: renderSensorsPairing },
  { pattern: /^logs$/, title: 'Log', render: renderLogs },
  { pattern: /^system$/, title: 'System', render: renderSystem },
  { pattern: /^settings$/, title: 'Settings', render: renderSettings },
];

export function navigate(path) {
  if (location.hash === `#${path}`) route();
  else location.hash = path;
}

function currentPath() {
  return decodeURIComponent(location.hash.replace(/^#\/?/, '')).replace(/\/+$/, '');
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
    screen = candidate.render({ params: match.slice(1), navigate, setTitle: (t) => setTitle(t || candidate.title) });
    setTitle(candidate.title);
    replace(shell.content, screen.el);
    markNav(path);
    shell.main.focus({ preventScroll: true });
    window.scrollTo(0, 0);
    return;
  }
  replace(shell.content, h('div', { class: 'empty' }, h('h2', null, 'That page doesn’t exist'), h('p', null, 'It may have moved.'),
    h('a', { class: 'btn primary', href: '#/' }, 'Back to your cameras')));
  setTitle('Not found');
  markNav(path);
}

function markNav(path) {
  for (const link of shell.nav.querySelectorAll('a')) {
    const item = NAV.find((n) => n.href === link.getAttribute('href'));
    if (item?.match(path)) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  }
}

function buildShell() {
  const name = h('span', null, store.session.bridgeName);
  const nav = h('nav', { class: 'nav', 'aria-label': 'Main' },
    NAV.map((item) => h('a', { href: item.href }, icon(item.icon), h('span', null, item.label))));
  const content = h('div');
  const main = h('main', { id: 'main', class: 'main', tabindex: '-1' }, content);
  const reconnect = h('div', { class: 'reconnect', role: 'status', hidden: true }, 'Lost contact with the bridge. Trying again…');
  const version = h('div', { class: 'footer' });
  replace(root, h('header', { class: 'topbar' }, h('div', { class: 'topbar-inner' },
    h('a', { class: 'brand', href: '#/' }, h('img', { src: '/mark.svg', alt: '', width: 30, height: 30 }), name), nav)),
  reconnect, main, version);
  shell = { nav, content, main, name, reconnect, version };
  get('status').then((s) => { version.textContent = `${s.product} ${s.version}`; }).catch(() => {});
}

async function showApp() {
  stopEvents();
  buildShell();
  unsubscribe?.();
  unsubscribe = subscribe((kind) => {
    if (kind === 'connection' && shell) shell.reconnect.hidden = store.connected;
  });
  try { await loadCameras(); } catch (error) { toast(error.message, 'error'); }
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
  shell = null;
  screen?.destroy?.();
  screen = null;
  document.title = 'Sign in · Camera Bridge';
  replace(root, renderLogin({ bridgeName: store.session?.bridgeName || 'Camera Bridge', onSignedIn: showSignedIn }));
}

function showSetup() {
  stopEvents();
  shell = null;
  document.title = 'Set up · Camera Bridge';
  replace(root, renderSetup({ session: store.session, onDone: showSignedIn }));
}

async function boot() {
  try {
    store.session = await get('session');
  } catch (error) {
    replace(root, h('div', { class: 'center-page' }, h('div', { class: 'card center-card' },
      h('h1', null, 'Can’t reach the bridge'), h('p', { class: 'lede' }, error.message),
      h('button', { class: 'btn primary', onclick: () => location.reload() }, 'Try again'))));
    return;
  }
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
boot();

