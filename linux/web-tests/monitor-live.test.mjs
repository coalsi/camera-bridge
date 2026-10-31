// The Monitor's live video (screens/nvr.js): Auto quality asks the bridge to pick each camera's stream for the tile's size; a tab nobody sees
// streams nothing; a live tile whose frames stop goes back to pictures and says "No picture for N s"; a camera the page saw stop answering says
// since when; the arrow keys on the pan/tilt pad turn the camera instead of moving the timeline. The Monitor runs in the fake browser with a
// bridge that answers the catalog, keeps the live request open and sends what the test pushes.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { installFakeBrowser, makeStorage } from './support/fake-browser.mjs';

const PORCH = 'AAAAAAAA-0000-4000-8000-00000000000A';
const GARAGE = 'BBBBBBBB-0000-4000-8000-00000000000B';
const camera = (id, name, status = { connection: 'online' }) => ({ id, name, isEnabled: true, status });

const reply = (status, data) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});

function elementsUnder(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}

async function until(check, what = 'it never happened', tries = 300) {
  for (let i = 0; i < tries; i += 1) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(what);
}

function message(type, index, bytes) {
  const out = new Uint8Array(6 + bytes.length);
  out[0] = type; out[1] = index;
  const n = bytes.length;
  out[2] = (n >>> 24) & 0xff; out[3] = (n >>> 16) & 0xff; out[4] = (n >>> 8) & 0xff; out[5] = n & 0xff;
  out.set(bytes, 6);
  return out;
}
const meta = (index, json) => message(1, index, new TextEncoder().encode(JSON.stringify(json)));
const frame = (index) => message(4, index, new Uint8Array([0, 0, 0, 1]));

/** The Monitor on `cameras`, with `stored` in this browser's storage. `lives` are the live requests: { url, push(bytes), aborted }. */
async function openMonitor(cameras, { stored = {} } = {}) {
  const storage = makeStorage();
  for (const [key, value] of Object.entries(stored)) storage.setItem(key, value);
  const browser = installFakeBrowser(globalThis, { storage });
  const create = browser.document.createElement;
  browser.document.createElement = (tag) => {
    const el = create(tag);
    let src = '';
    if (tag === 'img') Object.defineProperty(el, 'src', { get: () => src, set: (value) => { src = value; queueMicrotask(() => el.onerror?.()); } });
    return el;
  };
  globalThis.ResizeObserver = class { observe() {} disconnect() {} };
  window.MediaSource = class { static isTypeSupported() { return true; } };
  const lives = [];
  globalThis.fetch = async (url, init = {}) => {
    if (url === '/api/v1/nvr/cameras') return reply(200, { serverTime: Date.now(), catalogVersion: 1, cameras: [] });
    if (url.startsWith('/api/v1/live?')) {
      const waiting = [];
      const chunks = [];
      const live = { url, aborted: false, push(bytes) { chunks.push(bytes); settle(); } };
      const settle = () => {
        while (waiting.length && (chunks.length || live.aborted)) {
          const next = waiting.shift();
          if (live.aborted) next.reject(new DOMException('The request was stopped.', 'AbortError'));
          else next.resolve({ value: chunks.shift(), done: false });
        }
      };
      init.signal?.addEventListener('abort', () => { live.aborted = true; settle(); });
      lives.push(live);
      return { ok: true, status: 200, headers: { get: () => 'application/octet-stream' },
        body: { getReader: () => ({ read: () => new Promise((resolve, reject) => { waiting.push({ resolve, reject }); settle(); }) }) } };
    }
    return reply(404, { error: 'not_found', message: 'There is nothing here.' });
  };
  const { store, putCamera } = await import('../web/js/store.js');
  const { renderNVR } = await import('../web/js/screens/nvr.js');
  store.cameras = new Map(cameras.map((c) => [c.id, c]));
  const page = renderNVR({ params: [], navigate() {}, setTitle() {} });
  browser.document.body.append(page.el);
  const tile = (id) => elementsUnder(page.el, (node) => node.localName === 'article' && node.dataset.id === id)[0] ?? null;
  await until(() => cameras.every((c) => tile(c.id)), 'the tiles were never drawn');
  await until(() => lives.length > 0, 'the wall never asked for live video');
  return {
    page, tile, lives, store, browser,
    update: (id, change) => putCamera({ ...store.cameras.get(id), ...change }),
    part: (id, cls) => elementsUnder(tile(id), (node) => node.classList?.contains(cls))[0],
    close() {
      page.destroy();
      store.cameras = new Map();
      delete globalThis.ResizeObserver;
      browser.restore();
    },
  };
}

test('Auto quality is the default: the wall asks the bridge to pick each camera’s stream; Full quality chosen on this browser asks for the main stream', async () => {
  let monitor = await openMonitor([camera(PORCH, 'Porch'), camera(GARAGE, 'Garage')]);
  try {
    assert.match(monitor.lives[0].url, /[?&]stream=automatic(&|$)/);
    assert.match(monitor.lives[0].url, new RegExp(`cameras=${GARAGE},${PORCH}`), 'every camera on the wall, in the wall’s order');
    const quality = elementsUnder(monitor.page.el, (node) => node.localName === 'select' && node.getAttribute('aria-label') === 'Live quality')[0];
    assert.deepEqual(quality.childNodes.map((option) => option.textContent), ['Auto quality', 'Full quality', 'Smooth']);
  } finally {
    monitor.close();
  }
  monitor = await openMonitor([camera(PORCH, 'Porch')], { stored: { 'cb.monitor.quality': 'main' } });
  try {
    assert.match(monitor.lives[0].url, /[?&]stream=main(&|$)/);
    assert.doesNotMatch(monitor.lives[0].url, /width=/);
  } finally {
    monitor.close();
  }
});

test('a hidden tab streams nothing, and the wall starts again when it shows', async () => {
  const monitor = await openMonitor([camera(PORCH, 'Porch')]);
  try {
    monitor.browser.document.hidden = true;
    monitor.browser.document.dispatchEvent({ type: 'visibilitychange' });
    assert.equal(monitor.lives[0].aborted, true, 'the live request is closed');
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(monitor.lives.length, 1, 'and none opens while hidden');
    monitor.browser.document.hidden = false;
    monitor.browser.document.dispatchEvent({ type: 'visibilitychange' });
    await until(() => monitor.lives.length === 2, 'the wall never started again');
  } finally {
    monitor.close();
  }
});

test('live frames that stop: the tile goes back to pictures and says "No picture for N s"; the next frame brings it back; the tooltip has the size and rate', async () => {
  const monitor = await openMonitor([camera(PORCH, 'Porch')]);
  const real = performance.now.bind(performance);
  let ahead = 0;
  Object.defineProperty(performance, 'now', { value: () => real() + ahead, configurable: true, writable: true });
  try {
    const live = monitor.lives[0];
    const tile = monitor.tile(PORCH);
    const video = elementsUnder(tile, (node) => node.localName === 'video')[0];
    live.push(meta(0, { mime: 'video/mp4; codecs="avc1.640028"', width: 1920, height: 1080, stream: 'main' }));
    for (let i = 0; i < 3; i += 1) live.push(frame(0));
    video.dispatchEvent({ type: 'playing' });
    assert.equal(tile.dataset.livevideo, 'true');
    await until(() => (monitor.part(PORCH, 'nvr-media').getAttribute('title') ?? '').startsWith('1920 × 1080'), 'no tooltip');
    assert.match(monitor.part(PORCH, 'nvr-media').getAttribute('title'), /main stream$/);
    const stall = monitor.part(PORCH, 'mon-stall');
    assert.equal(stall.hidden, true);

    ahead = 6500;      // no frame for 6.5 s
    await until(() => tile.dataset.livevideo === 'false', 'the frozen picture stayed up', 300);
    await until(() => !stall.hidden, 'no badge');
    assert.match(stall.textContent, /^No picture for \d+ s$/);
    assert.ok(Number(stall.textContent.match(/\d+/)[0]) >= 6, 'counted from the last frame');

    live.push(frame(0));
    await until(() => tile.dataset.livevideo === 'true' && stall.hidden, 'the picture never came back');
  } finally {
    Object.defineProperty(performance, 'now', { value: real, configurable: true, writable: true });
    delete performance.now;
    monitor.close();
  }
});

test('a camera the page saw stop answering says since when, in the bridge’s time', async () => {
  const monitor = await openMonitor([camera(PORCH, 'Porch'), camera(GARAGE, 'Garage')]);
  try {
    monitor.update(GARAGE, { status: { connection: 'offline', connectionReason: 'No answer from the camera.' } });
    const detail = () => monitor.part(GARAGE, 'nvr-tile-note-detail');
    await until(() => /Offline since/.test(detail()?.textContent ?? ''), 'no "Offline since"');
    assert.match(detail().textContent, /^No answer from the camera\. · Offline since \d{1,2}:\d{2}/);
    monitor.update(GARAGE, { status: { connection: 'online' } });
    monitor.update(GARAGE, { status: { connection: 'offline' } });
    await until(() => /^Offline since/.test(detail()?.textContent ?? ''), 'a new time');
  } finally {
    monitor.close();
  }
});

test('the arrow keys on the pan/tilt pad are the pad’s: the Monitor does not take them for the timeline', async () => {
  const monitor = await openMonitor([camera(PORCH, 'Porch')]);
  try {
    const { FakeElement } = await import('./support/fake-browser.mjs');
    const inPad = new FakeElement('button');
    inPad.closest = (selector) => (selector === '.mon-ptz' ? {} : null);
    const elsewhere = new FakeElement('div');
    elsewhere.closest = () => null;
    const press = (target) => {
      let prevented = false;
      monitor.browser.document.dispatchEvent({ type: 'keydown', key: 'ArrowLeft', target, preventDefault() { prevented = true; }, stopImmediatePropagation() {} });
      return prevented;
    };
    await new Promise((resolve) => setTimeout(resolve, 50));    // the catalog has answered: the timeline takes keys
    assert.equal(press(inPad), false, 'left to the pad');
    assert.equal(press(elsewhere), true, 'elsewhere it moves the timeline');
  } finally {
    monitor.close();
  }
});
