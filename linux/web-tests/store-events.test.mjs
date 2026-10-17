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
  open() { this.readyState = OPEN; this.fire('open'); }
  drop() { this.readyState = CONNECTING; this.fire('error'); }
  refuse() { this.readyState = CLOSED; this.fire('error'); }
}

describe('the event stream', () => {
  let store;
  let saved;
  beforeEach(async () => {
    saved = globalThis.EventSource;
    globalThis.EventSource = FakeEventSource;
    FakeEventSource.made = [];
    mock.timers.enable({ apis: ['setTimeout'] });
    store = await import('../web/js/store.js');
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
});
