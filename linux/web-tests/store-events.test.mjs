// store.js: the page's event stream (GET /api/v1/events) and the "Lost contact with the bridge. Trying again…" notice it drives (app.js).
import { afterEach, beforeEach, describe, it, mock } from 'node:test';
import assert from 'node:assert/strict';

const CONNECTING = 0;
const OPEN = 1;
const CLOSED = 2;

/** An EventSource the test drives: `open()`, `drop()` (the browser reconnects by itself) and `refuse()` (it gave up: readyState CLOSED). */
class FakeEventSource {
  static made = [];
  constructor(url) {
    this.url = url;
    this.readyState = CONNECTING;
    this.listeners = new Map();
    this.closed = false;
    FakeEventSource.made.push(this);
  }
  addEventListener(type, fn) { if (!this.listeners.has(type)) this.listeners.set(type, []); this.listeners.get(type).push(fn); }
  close() { this.closed = true; this.readyState = CLOSED; }
  fire(type, event = {}) { for (const fn of this.listeners.get(type) ?? []) fn(event); }
  send(type, data) { this.fire(type, { data: JSON.stringify(data) }); }
  open() { this.readyState = OPEN; this.fire('open'); }
  drop() { this.readyState = CONNECTING; this.fire('error'); }
  refuse() { this.readyState = CLOSED; this.fire('error'); }
}

const asked = [];
let systemVersion = '0.1.130';

describe('the event stream', () => {
  let store;
  let saved;
  beforeEach(async () => {
    saved = globalThis.EventSource;
    globalThis.EventSource = FakeEventSource;
    FakeEventSource.made = [];
    mock.timers.enable({ apis: ['setTimeout'] });
    store = await import('../web/js/store.js');
    asked.length = 0;
    globalThis.fetch = async (url) => {
      asked.push(String(url));
      return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => ({ version: systemVersion }), text: async () => '' };
    };
  });
  afterEach(() => {
    store.stopEvents();
    mock.timers.reset();
    globalThis.EventSource = saved;
  });

  it('says it lost contact on a drop and is back on the next open (the browser reconnects by itself)', () => {
    const changes = [];
    const off = store.subscribe((kind) => { if (kind === 'connection') changes.push(store.store.connected); });
    store.startEvents();
    const source = FakeEventSource.made.at(-1);
    source.open();
    source.drop();
    assert.equal(store.store.connected, false);
    mock.timers.tick(60_000);
    assert.equal(FakeEventSource.made.length, 1, 'the browser reconnects this one: no second stream');
    source.open();
    assert.equal(store.store.connected, true);
    assert.deepEqual(changes, [false, true]);
    off();
  });

  it('opens the stream again when the browser gave up on it (an answer that was not the stream), so "Trying again" is true', () => {
    store.startEvents();
    const first = FakeEventSource.made.at(-1);
    first.open();
    first.refuse();                                   // e.g. a 503 while the bridge restarts: the browser never tries again by itself
    assert.equal(store.store.connected, false);
    mock.timers.tick(2_999);
    assert.equal(FakeEventSource.made.length, 1);
    mock.timers.tick(1);
    assert.equal(FakeEventSource.made.length, 2, 'a new stream after 3 s');
    assert.equal(first.closed, true);
    const second = FakeEventSource.made.at(-1);
    second.refuse();
    mock.timers.tick(5_999);
    assert.equal(FakeEventSource.made.length, 2, 'then a little longer each time');
    mock.timers.tick(1);
    assert.equal(FakeEventSource.made.length, 3);
    FakeEventSource.made.at(-1).open();
    assert.equal(store.store.connected, true);
  });

  it('stopEvents() cancels a pending new try', () => {
    store.startEvents();
    FakeEventSource.made.at(-1).refuse();
    store.stopEvents();
    mock.timers.tick(60_000);
    assert.equal(FakeEventSource.made.length, 1);
  });

  it('takes a stream that has gone silent for 40 s for dead once the bridge is known to send pings, and opens a new one', () => {
    store.store.connected = true;
    const changes = [];
    const off = store.subscribe((kind) => { if (kind === 'connection') changes.push(store.store.connected); });
    store.startEvents();
    const source = FakeEventSource.made.at(-1);
    source.open();
    mock.timers.tick(120_000);
    assert.equal(FakeEventSource.made.length, 1, 'a bridge that sends only comments is never taken for dead');
    source.send('ping', {});
    mock.timers.tick(15_000);
    source.send('ping', {});
    mock.timers.tick(15_000);
    source.send('camera', { id: 'A', name: 'Porch' });
    mock.timers.tick(39_999);
    assert.equal(FakeEventSource.made.length, 1, 'every message counts as a sign of life');
    assert.equal(store.store.connected, true);
    mock.timers.tick(1);
    assert.equal(store.store.connected, false, '"Lost contact" shows');
    assert.equal(source.closed, true);
    assert.equal(FakeEventSource.made.length, 2, 'and a new stream opens');
    FakeEventSource.made.at(-1).open();
    assert.equal(store.store.connected, true);
    mock.timers.tick(40_000);
    assert.equal(FakeEventSource.made.length, 3, 'the new stream is watched too, before its first ping');
    assert.deepEqual(changes, [false, true, false]);
    off();
  });

  it('removes a camera that was removed while the stream was down: the next snapshot does not name it', () => {
    store.store.cameras = new Map([['A', { id: 'A', name: 'Porch' }], ['B', { id: 'B', name: 'Garage' }]]);
    const removed = [];
    const off = store.subscribe((kind, detail) => { if (kind === 'removed') removed.push(detail); });
    store.startEvents();
    const source = FakeEventSource.made.at(-1);
    source.open();
    source.send('bridge', { state: 'running' });
    source.send('camera', { id: 'A', name: 'Porch' });
    assert.equal(store.store.cameras.has('B'), true, 'not before the snapshot ends');
    source.send('notices', []);
    assert.deepEqual(removed, ['B']);
    assert.deepEqual([...store.store.cameras.keys()], ['A']);
    // Later notices are not a snapshot: a camera that arrives live is kept.
    source.send('camera', { id: 'C', name: 'Side' });
    source.send('notices', []);
    assert.deepEqual([...store.store.cameras.keys()], ['A', 'C']);
    off();
    store.store.cameras = new Map();
  });

  it('asks for the bridge’s version after contact was lost, and says when it is newer than the page’s', async () => {
    store.store.version = null;
    store.store.newVersion = null;
    systemVersion = '0.1.129';
    const updates = [];
    const off = store.subscribe((kind, detail) => { if (kind === 'updated') updates.push(detail); });
    store.noteVersion('0.1.129');
    store.startEvents();
    const source = FakeEventSource.made.at(-1);
    source.open();
    for (let i = 0; i < 5; i += 1) await new Promise((resolve) => setImmediate(resolve));
    const before = asked.length;
    assert.equal(updates.length, 0, 'the same version');
    source.drop();
    systemVersion = '0.1.130';
    source.open();
    for (let i = 0; i < 5; i += 1) await new Promise((resolve) => setImmediate(resolve));
    assert.ok(asked.length > before);
    assert.deepEqual(asked.slice(-1), ['/api/v1/system']);
    assert.deepEqual(updates, ['0.1.130']);
    assert.equal(store.store.newVersion, '0.1.130');
    store.noteVersion('0.1.130');
    assert.equal(updates.length, 1, 'told once');
    off();
  });
});

describe('when a camera went offline', () => {
  it('is the bridge\'s own time when it says it, so a page opened later still knows', async () => {
    const store = await import('../web/js/store.js');
    const id = 'C0FFEE00-0000-4000-8000-000000000001';
    store.store.cameras.set(id, { id, name: 'Driveway', status: { connection: 'offline', connectionSince: '2026-10-31T09:14:00Z' } });
    assert.equal(store.offlineSince(id), Date.parse('2026-10-31T09:14:00Z'));
    store.store.cameras.set(id, { id, name: 'Driveway', status: { connection: 'online', connectionSince: '2026-10-31T09:20:00Z' } });
    assert.equal(store.offlineSince(id), null, 'back online');
    store.store.cameras.delete(id);
  });
});
