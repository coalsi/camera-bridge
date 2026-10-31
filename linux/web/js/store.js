// What the page knows about the bridge, kept current by the server's event stream.
import { get, patch } from './api.js';
import { orderCameras } from './camera-order.js';
import { browserZone, knownZone } from './zone.js';

export const store = {
  session: null,          // { authenticated, setupRequired, setupTokenRequired, bridgeName, csrfToken }
  bridge: { state: 'running', stateText: 'Running' },
  cameras: new Map(),     // id -> camera (configuration + status)
  notices: [],
  cameraOrder: [],        // camera ids in the order the person chose (settings.cameraOrder); empty: by name
  plugins: new Map(),     // plugin id -> whether its switch is on (GET plugins); empty until the list was read
  connected: true,        // the event stream is open
  loaded: false,          // the first snapshot arrived
  timeZone: null,         // the bridge's time zone (settings.timeZone); null until the settings were read, or when the bridge has none
  version: null,          // the bridge's version when this page's code was loaded (GET system at start-up)
  newVersion: null,       // a newer version the bridge runs since: it was updated while the page was open (a reload brings its pages)
};

const subscribers = new Set();

/**
 * fn(kind, detail) runs on every change: 'camera', 'removed', 'bridge', 'notices', 'connection', 'motion', 'doorbell', 'order', 'plugins', 'zone'
 * (the bridge's time zone), 'updated' (the bridge runs a newer version than this page's code).
 */
export function subscribe(fn) {
  subscribers.add(fn);
  return () => subscribers.delete(fn);
}

function emit(kind, detail) {
  for (const fn of [...subscribers]) {
    try { fn(kind, detail); } catch (error) { console.error(error); }
  }
}

// The list as it was last sorted, and what it was made from: the Monitor asks for it many times a second, and a sort by name is not free.
let listed = { cameras: null, order: null, values: [], list: [] };

/** The cameras in the order the person chose, else by name. The same array while nothing changed: read it, do not change it. */
export function cameraList() {
  const values = [...store.cameras.values()];
  const same = listed.cameras === store.cameras && listed.order === store.cameraOrder && listed.values.length === values.length
    && values.every((camera, i) => camera === listed.values[i]);
  if (!same) listed = { cameras: store.cameras, order: store.cameraOrder, values, list: orderCameras(values, store.cameraOrder) };
  return listed.list;
}

// When the page saw each camera stop answering (this device's clock), for "Offline since 2:14 AM" on the Monitor. The bridge does not say
// since when, so a camera that was already offline when the page loaded has no time.
const offline = new Map();

function noteConnection(before, after) {
  if (!after?.id) return;
  if (after.status?.connection !== 'offline') { offline.delete(after.id); return; }
  const was = before?.status?.connection;
  if (was && was !== 'offline' && !offline.has(after.id)) offline.set(after.id, Date.now());
}

/**
 * When (epoch ms) camera `id` went offline, or null when it is not offline: the bridge's own time (`status.connectionSince`) when it says it, else
 * when this page saw it go (null for a camera that was already offline when the page loaded).
 */
export function offlineSince(id) {
  const status = store.cameras.get(id)?.status;
  if (status?.connection === 'offline' && status.connectionSince) {
    const ms = Date.parse(status.connectionSince);
    if (Number.isFinite(ms)) return ms;
  }
  return offline.get(id) ?? null;
}

/**
 * The bridge's time zone: every time on the page (the Monitor, Events, the Log, clips, storage) is said in it, as the bridge's own video label
 * and the cameras' clocks are, whichever zone the browser is in. The browser's own until the settings were read, or when the bridge has none.
 */
export function bridgeZone() {
  return store.timeZone || browserZone();
}

/** Takes the bridge's time zone (`timeZone` of GET or PATCH settings); a zone this browser does not know counts as none. */
export function setBridgeZone(zone) {
  const next = knownZone(zone) ? zone : null;
  if (next === store.timeZone) return;
  store.timeZone = next;
  emit('zone');
}

/**
 * The bridge's version as GET system says it: the first is the one this page's code came with; a different one later means the bridge was updated
 * while the page was open (its pages, loaded on demand, would no longer match the ones in memory), and 'updated' tells whoever offers a reload.
 */
export function noteVersion(version) {
  if (typeof version !== 'string' || !version) return;
  if (store.version === null) { store.version = version; return; }
  if (version === store.version || version === store.newVersion) return;
  store.newVersion = version;
  emit('updated', version);
}

/** The saved order, as the settings give it (GET /settings, `cameraOrder`). */
export function setCameraOrder(order) {
  store.cameraOrder = Array.isArray(order) ? order.filter((id) => typeof id === 'string') : [];
  emit('order');
}

/**
 * Takes a new order now and saves it with one PATCH; when the save fails the order before is back and `onError(error)` is told.
 * (The bridge sends no event for settings, so other browsers see it the next time they load.) -> whether it was saved.
 */
export async function saveCameraOrder(ids, { save = (order) => patch('settings', { cameraOrder: order }), onError = () => {} } = {}) {
  const before = store.cameraOrder;
  store.cameraOrder = ids;
  emit('order');
  try {
    await save(ids);
    return true;
  } catch (error) {
    if (store.cameraOrder === ids) { store.cameraOrder = before; emit('order'); }   // a newer move since is not undone
    onError(error);
    return false;
  }
}

/** Whether the plugin with this id is switched on (false for one that is off, unknown, or not read yet). */
export function pluginOn(id) {
  return store.plugins.get(id) === true;
}

/**
 * Takes the plugins' switches from `GET plugins` (`[{ id, enabled, … }]`) and tells whoever shows a plugin's things (the menu's Sky Watcher item,
 * the camera page's Sky Watcher card). Anything that is not a list switches nothing on. (The bridge sends no event for plugins, so another browser
 * sees a change the next time the page reads the list.)
 */
export function setPlugins(list) {
  store.plugins = new Map((Array.isArray(list) ? list : []).filter((plugin) => typeof plugin?.id === 'string').map((plugin) => [plugin.id, plugin.enabled === true]));
  emit('plugins');
}

/** Reads the plugins' switches (GET plugins) into the store; resolves the plugins' list. */
export async function loadPlugins() {
  const { plugins } = await get('plugins');
  setPlugins(plugins);
  return plugins;
}

let source = null;
let retryTimer = null;
let refusals = 0;
const RETRY_MS = [3000, 6000, 12000, 30000];
/**
 * The bridge sends a `ping` event every 15 s. Once one has come, a stream silent for this long is taken for dead (the box lost power or its cable,
 * and no word of it reaches the browser, which would wait minutes for the connection to time out): "Lost contact" shows and a new stream opens.
 */
export const SILENCE_MS = 40_000;
let pingsSeen = false;          // a bridge that sends pings (an older one only sends comments, which the page never sees)
let silenceTimer = null;
let lostContact = false;        // the stream dropped since it last opened: the next open asks for the bridge's version

/** Every message is a sign of life: the silence check starts again from it. */
function alive(opened) {
  if (silenceTimer !== null) clearTimeout(silenceTimer);
  silenceTimer = null;
  if (!pingsSeen || source !== opened) return;
  silenceTimer = setTimeout(() => {
    silenceTimer = null;
    if (source !== opened) return;
    lostContact = true;
    if (store.connected) { store.connected = false; emit('connection'); }
    startEvents();
  }, SILENCE_MS);
}

export function startEvents() {
  stopEvents();
  const opened = new EventSource('/api/v1/events');
  source = opened;
  // The cameras the snapshot names, from the stream's open to its first `notices`: one that is not among them was removed while the page
  // was not listening (the bridge says `removed` only to those who listen at the time).
  let snapshot = null;
  opened.addEventListener('open', () => {
    refusals = 0;
    snapshot = new Set();
    alive(opened);
    if (!store.connected) { store.connected = true; emit('connection'); }
    if (lostContact) {
      lostContact = false;
      get('system').then((system) => noteVersion(system?.version)).catch(() => {});
    }
  });
  opened.addEventListener('error', () => {
    // The browser reconnects by itself after a drop (the server asks it to every 3 s); say so meanwhile. An answer that is not the stream (a
    // 502 or 503 while the bridge restarts) makes it give up for good (readyState CLOSED): then this opens a new one, a little later each time.
    lostContact = true;
    snapshot = null;
    if (store.connected) { store.connected = false; emit('connection'); }
    if (opened.readyState === 2 && source === opened && retryTimer === null) {
      retryTimer = setTimeout(() => { retryTimer = null; if (source === opened) startEvents(); }, RETRY_MS[Math.min(refusals, RETRY_MS.length - 1)]);
      refusals += 1;
    }
  });
  const on = (name, fn) => opened.addEventListener(name, (event) => {
    alive(opened);
    try { fn(JSON.parse(event.data)); } catch (error) { console.error(error); }
  });
  on('ping', () => { if (!pingsSeen) { pingsSeen = true; alive(opened); } });
  on('bridge', (data) => { store.bridge = data; emit('bridge'); });
  on('camera', (camera) => {
    const first = !store.loaded;
    snapshot?.add(camera.id);
    noteConnection(store.cameras.get(camera.id), camera);
    store.cameras.set(camera.id, camera);
    emit('camera', camera);
    if (first) store.loaded = true;
  });
  on('removed', ({ id }) => { store.cameras.delete(id); emit('removed', id); });
  on('notices', (notices) => {
    if (snapshot) {
      for (const id of [...store.cameras.keys()]) if (!snapshot.has(id)) { store.cameras.delete(id); emit('removed', id); }
      snapshot = null;
    }
    store.notices = notices;
    store.loaded = true;   // the snapshot ends with the notices
    emit('notices');
  });
  on('motion', (event) => emit('motion', event));
  on('doorbell', (event) => emit('doorbell', event));
}

export function stopEvents() {
  if (retryTimer !== null) { clearTimeout(retryTimer); retryTimer = null; }
  if (silenceTimer !== null) { clearTimeout(silenceTimer); silenceTimer = null; }
  if (source) source.close();
  source = null;
}

/** Loads the cameras once (the event stream then keeps them current). */
export async function loadCameras() {
  const { cameras } = await get('cameras');
  for (const camera of cameras) noteConnection(store.cameras.get(camera.id), camera);
  store.cameras = new Map(cameras.map((camera) => [camera.id, camera]));
  store.loaded = true;
  emit('camera');
  return cameras;
}

export function putCamera(camera) {
  noteConnection(store.cameras.get(camera.id), camera);
  store.cameras.set(camera.id, camera);
  emit('camera', camera);
}
