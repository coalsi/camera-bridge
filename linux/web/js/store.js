// What the page knows about the bridge, kept current by the server's event stream.
import { get, patch } from './api.js';
import { orderCameras } from './camera-order.js';

export const store = {
  session: null,          // { authenticated, setupRequired, setupTokenRequired, bridgeName, csrfToken }
  bridge: { state: 'running', stateText: 'Running' },
  cameras: new Map(),     // id -> camera (configuration + status)
  notices: [],
  cameraOrder: [],        // camera ids in the order the person chose (settings.cameraOrder); empty: by name
  connected: true,        // the event stream is open
  loaded: false,          // the first snapshot arrived
};

const subscribers = new Set();

/** fn(kind, detail) runs on every change: 'camera', 'removed', 'bridge', 'notices', 'connection', 'motion', 'doorbell', 'order'. */
export function subscribe(fn) {
  subscribers.add(fn);
  return () => subscribers.delete(fn);
}

function emit(kind, detail) {
  for (const fn of [...subscribers]) {
    try { fn(kind, detail); } catch (error) { console.error(error); }
  }
}

export function cameraList() {
  return orderCameras([...store.cameras.values()], store.cameraOrder);
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

let source = null;
let retryTimer = null;
let refusals = 0;
const RETRY_MS = [3000, 6000, 12000, 30000];

export function startEvents() {
  stopEvents();
  const opened = new EventSource('/api/v1/events');
  source = opened;
  opened.addEventListener('open', () => {
    refusals = 0;
    if (!store.connected) { store.connected = true; emit('connection'); }
  });
  opened.addEventListener('error', () => {
    // The browser reconnects by itself after a drop (the server asks it to every 3 s); say so meanwhile. An answer that is not the stream (a
    // 502 or 503 while the bridge restarts) makes it give up for good (readyState CLOSED): then this opens a new one, a little later each time.
    if (store.connected) { store.connected = false; emit('connection'); }
    if (opened.readyState === 2 && source === opened && retryTimer === null) {
      retryTimer = setTimeout(() => { retryTimer = null; if (source === opened) startEvents(); }, RETRY_MS[Math.min(refusals, RETRY_MS.length - 1)]);
      refusals += 1;
    }
  });
  const on = (name, fn) => opened.addEventListener(name, (event) => {
    try { fn(JSON.parse(event.data)); } catch (error) { console.error(error); }
  });
  on('bridge', (data) => { store.bridge = data; emit('bridge'); });
  on('camera', (camera) => {
    const first = !store.loaded;
    store.cameras.set(camera.id, camera);
    emit('camera', camera);
    if (first) store.loaded = true;
  });
  on('removed', ({ id }) => { store.cameras.delete(id); emit('removed', id); });
  on('notices', (notices) => {
    store.notices = notices;
    store.loaded = true;   // the snapshot ends with the notices
    emit('notices');
  });
  on('motion', (event) => emit('motion', event));
  on('doorbell', (event) => emit('doorbell', event));
}

export function stopEvents() {
  if (retryTimer !== null) { clearTimeout(retryTimer); retryTimer = null; }
  if (source) source.close();
  source = null;
}

/** Loads the cameras once (the event stream then keeps them current). */
export async function loadCameras() {
  const { cameras } = await get('cameras');
  store.cameras = new Map(cameras.map((camera) => [camera.id, camera]));
  store.loaded = true;
  emit('camera');
  return cameras;
}

export function putCamera(camera) {
  store.cameras.set(camera.id, camera);
  emit('camera', camera);
}
