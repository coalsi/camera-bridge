// What the page knows about the bridge, kept current by the server's event stream.
import { get } from './api.js';

export const store = {
  session: null,          // { authenticated, setupRequired, setupTokenRequired, bridgeName, csrfToken }
  bridge: { state: 'running', stateText: 'Running' },
  cameras: new Map(),     // id -> camera (configuration + status)
  notices: [],
  connected: true,        // the event stream is open
  loaded: false,          // the first snapshot arrived
};

const subscribers = new Set();

/** fn(kind, detail) runs on every change: 'camera', 'removed', 'bridge', 'notices', 'connection', 'motion', 'doorbell'. */
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
  return [...store.cameras.values()].sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' }));
}

let source = null;

export function startEvents() {
  stopEvents();
  source = new EventSource('/api/v1/events');
  source.addEventListener('open', () => {
    if (!store.connected) { store.connected = true; emit('connection'); }
  });
  source.addEventListener('error', () => {
    // The browser reconnects by itself (the server asks it to every 3 s); say so meanwhile.
    if (store.connected) { store.connected = false; emit('connection'); }
  });
  const on = (name, fn) => source.addEventListener(name, (event) => {
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
