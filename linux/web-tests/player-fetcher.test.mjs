// fetcher.js: at most 3 media and 1 JSON request in flight, latest wins per key, no abort, Retry-After.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError } from '../web/js/api.js';
import { STUCK_MS, createFetcher } from '../web/js/nvr/fetcher.js';
import { createFakeTimers } from './player-fakes/fake-timers.mjs';

/** get / getBytes whose answers the test controls: every call waits until `.resolve(value)` or `.reject(error)`. */
function controlled() {
  const calls = [];
  const make = (kind) => (path, options) => new Promise((resolve, reject) => {
    const call = { kind, path, options, resolve, reject, settled: false };
    call.signal = options.signal;
    calls.push(call);
  });
  return { calls, get: make('json'), getBytes: make('bytes') };
}

function setup(caps) {
  const timers = createFakeTimers();
  const server = controlled();
  const fetcher = createFetcher({ get: server.get, getBytes: server.getBytes, sleep: timers.sleep, caps });
  return { timers, server, fetcher, calls: server.calls };
}

const bytesOf = (n) => ({ data: new ArrayBuffer(n), headers: new Headers() });
const tick = () => new Promise((resolve) => setImmediate(resolve));

describe('caps', () => {
  it('runs at most 3 media requests and 1 JSON request, and starts the next as one finishes', async () => {
    const { fetcher, calls } = setup();
    const media = Array.from({ length: 8 }, (_, i) => fetcher.bytes(`nvr/cameras/C/fragments/f.${i}`, { key: `tile:${i}` }));
    const json = Array.from({ length: 3 }, (_, i) => fetcher.json(`nvr/cameras/C/fragments?at=${i}`, { key: `plan:${i}` }));
    await tick();
    assert.deepEqual(fetcher.stats(), { bytesInFlight: 3, jsonInFlight: 1, queued: 7 });
    assert.deepEqual(calls.map((c) => c.path), ['nvr/cameras/C/fragments/f.0', 'nvr/cameras/C/fragments/f.1', 'nvr/cameras/C/fragments/f.2', 'nvr/cameras/C/fragments?at=0']);
    calls[0].resolve(bytesOf(1));
    await media[0];
    await tick();
    assert.deepEqual(fetcher.stats(), { bytesInFlight: 3, jsonInFlight: 1, queued: 6 });
    assert.equal(calls[4].path, 'nvr/cameras/C/fragments/f.3');
    calls[3].resolve({ ok: 1 });
    await json[0];
    await tick();
    assert.equal(calls[5].path, 'nvr/cameras/C/fragments?at=1');
    for (let guard = 0; guard < 100 && calls.some((c) => !c.settled) ; guard += 1) {
      for (const call of calls) if (!call.settled) { call.settled = true; call.resolve(call.kind === 'bytes' ? bytesOf(1) : {}); }
      await tick();
    }
    await Promise.all([...media, ...json]);
    assert.deepEqual(fetcher.stats(), { bytesInFlight: 0, jsonInFlight: 0, queued: 0 });
  });

  it('never exceeds the caps over a long random run', async () => {
    const { fetcher, calls } = setup();
    let seed = 12345;
    const random = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 2 ** 32; };
    let worstBytes = 0;
    let worstJson = 0;
    const done = [];
    for (let i = 0; i < 400; i += 1) {
      const wrap = (p) => p.catch((error) => { if (error.name !== 'Superseded') throw error; });
      done.push(wrap(random() < 0.7 ? fetcher.bytes(`b${i}`, { key: `k${i % 7}` }) : fetcher.json(`j${i}`, { key: `p${i % 3}` })));
      const stats = fetcher.stats();
      worstBytes = Math.max(worstBytes, stats.bytesInFlight);
      worstJson = Math.max(worstJson, stats.jsonInFlight);
      if (random() < 0.6) {
        const open = calls.filter((c) => !c.settled);
        const pick = open[Math.floor(random() * open.length)];
        if (pick) { pick.settled = true; pick.resolve(pick.kind === 'bytes' ? bytesOf(1) : {}); }
      }
      await tick();
    }
    for (let guard = 0; guard < 2000 && fetcher.stats().queued + fetcher.stats().bytesInFlight + fetcher.stats().jsonInFlight > 0; guard += 1) {
      for (const call of calls) if (!call.settled) { call.settled = true; call.resolve(call.kind === 'bytes' ? bytesOf(1) : {}); }
      await tick();
    }
    await Promise.all(done);
    assert.ok(worstBytes <= 3, `bytes in flight reached ${worstBytes}`);
    assert.ok(worstJson <= 1, `json in flight reached ${worstJson}`);
    assert.ok(calls.every((c) => c.signal.aborted === false), 'nothing was aborted');
  });

  it('honours custom caps', async () => {
    const { fetcher } = setup({ bytes: 1, json: 2 });
    fetcher.bytes('a'); fetcher.bytes('b'); fetcher.json('c'); fetcher.json('d'); fetcher.json('e');
    await tick();
    assert.deepEqual(fetcher.stats(), { bytesInFlight: 1, jsonInFlight: 2, queued: 2 });
  });
});

describe('keys', () => {
  it('a newer request replaces an older one that has not started', async () => {
    const { fetcher, calls } = setup({ bytes: 1, json: 1 });
    const first = fetcher.bytes('first', { key: 'other' });
    const old = fetcher.bytes('old', { key: 'tile' }).catch((error) => error);
    const fresh = fetcher.bytes('fresh', { key: 'tile' });
    await tick();
    assert.equal((await old).name, 'Superseded');
    assert.equal(fetcher.stats().queued, 1);
    calls[0].resolve(bytesOf(1));
    await first;
    await tick();
    assert.equal(calls[1].path, 'fresh');
    calls[1].resolve(bytesOf(2));
    assert.equal((await fresh).data.byteLength, 2);
    assert.ok(calls.every((c) => !c.signal.aborted));
  });

  it('a request that has started is never aborted or replaced, and the next one with its key waits for it', async () => {
    const { fetcher, calls } = setup();
    const running = fetcher.bytes('running', { key: 'tile' });
    await tick();
    const next = fetcher.bytes('next', { key: 'tile' });
    await tick();
    assert.equal(calls.length, 1, 'one request in flight per key');
    assert.equal(calls[0].signal.aborted, false);
    assert.deepEqual(fetcher.stats(), { bytesInFlight: 1, jsonInFlight: 0, queued: 1 });
    calls[0].resolve(bytesOf(1));
    await running;
    await tick();
    assert.equal(calls.length, 2);
    assert.equal(calls[1].path, 'next');
    calls[1].resolve(bytesOf(1));
    await next;
  });

  it('keys are separate for media and JSON', async () => {
    const { fetcher, calls } = setup();
    fetcher.bytes('media', { key: 'cell:1' });
    fetcher.json('plan', { key: 'cell:1' });
    await tick();
    assert.equal(calls.length, 2);
  });

  it('supersede(key) rejects queued requests with that key and leaves running ones alone', async () => {
    const { fetcher, calls } = setup({ bytes: 1, json: 1 });
    const running = fetcher.bytes('running', { key: 'tile' });
    const queued = fetcher.bytes('queued', { key: 'tile' });
    const unrelated = fetcher.bytes('unrelated', { key: 'other' });
    await tick();
    fetcher.supersede('tile');
    await assert.rejects(queued, (error) => error.name === 'Superseded');
    assert.equal(fetcher.stats().queued, 1);
    assert.equal(calls[0].signal.aborted, false);
    calls[0].resolve(bytesOf(1));
    await running;
    await tick();
    assert.equal(calls[1].path, 'unrelated');
    calls[1].resolve(bytesOf(1));
    await unrelated;
  });

  it('requests without a key never replace each other', async () => {
    const { fetcher, calls } = setup({ bytes: 1, json: 1 });
    const a = fetcher.json('a');
    const b = fetcher.json('b');
    await tick();
    calls[0].resolve(1);
    await a;
    await tick();
    calls[1].resolve(2);
    assert.equal(await b, 2);
  });

  it('higher priority first, then the oldest', async () => {
    const { fetcher, calls } = setup({ bytes: 1, json: 1 });
    const blocker = fetcher.bytes('blocker', { key: 'x' });
    fetcher.bytes('low-1', { key: 'a', priority: 0 });
    fetcher.bytes('high', { key: 'b', priority: 5 });
    fetcher.bytes('low-2', { key: 'c', priority: 0 });
    await tick();
    const order = [];
    for (let i = 0; i < 4; i += 1) {
      calls[i].resolve(bytesOf(1));
      await tick();
      order.push(calls[i].path);
    }
    await blocker;
    assert.deepEqual(order, ['blocker', 'high', 'low-1', 'low-2']);
  });
});

describe('failures and retries', () => {
  const busy = (retryAfter) => new ApiError(429, 'busy', 'Busy.', null, { retryAfter });

  it('retries a 429 after Retry-After seconds', async () => {
    const { fetcher, calls, timers } = setup();
    const result = fetcher.bytes('p', { key: 'k' });
    await tick();
    calls[0].reject(busy(2));
    await tick();
    assert.equal(calls.length, 1);
    await timers.advance(1999);
    assert.equal(calls.length, 1);
    await timers.advance(1);
    assert.equal(calls.length, 2);
    calls[1].resolve(bytesOf(3));
    assert.equal((await result).data.byteLength, 3);
  });

  it('without Retry-After it waits 1, 2 and 4 seconds, then gives up with the last error', async () => {
    const { fetcher, calls, timers } = setup();
    const result = fetcher.json('p', { key: 'k' });
    const outcome = result.then(() => 'resolved', (error) => error);
    await tick();
    const waits = [];
    for (let attempt = 0; attempt < 4; attempt += 1) {
      assert.equal(calls.length, attempt + 1);
      calls[attempt].reject(new ApiError(503, 'archive_unavailable', 'Loading.'));
      await tick();
      if (attempt === 3) break;
      const before = timers.now();
      while (calls.length === attempt + 1) await timers.advance(100);
      waits.push(timers.now() - before);
    }
    const error = await outcome;
    assert.equal(error.code, 'archive_unavailable');
    assert.deepEqual(waits, [1000, 2000, 4000]);
    assert.equal(calls.length, 4);
  });

  it('retries 504 and a lost connection, but not a timeout', async () => {
    const { fetcher, calls, timers } = setup();
    const slow = fetcher.bytes('slow', { key: 'a' });
    await tick();
    calls[0].reject(new ApiError(504, 'drive_slow', 'Slow.', null, { retryAfter: 2 }));
    await timers.advance(2000);
    assert.equal(calls.length, 2);
    calls[1].resolve(bytesOf(1));
    await slow;

    const lost = fetcher.bytes('lost', { key: 'b' });
    await tick();
    calls[2].reject(new ApiError(0, 'network', 'Gone.'));
    await timers.advance(1000);
    assert.equal(calls.length, 4);
    calls[3].resolve(bytesOf(1));
    await lost;

    const stuck = fetcher.bytes('stuck', { key: 'c' });
    await tick();
    calls[4].reject(new ApiError(0, 'timeout', 'Too long.'));
    await assert.rejects(stuck, (error) => error.code === 'timeout');
    assert.equal(calls.length, 5);
  });

  it('410 rejects at once with the code gone', async () => {
    const { fetcher, calls } = setup();
    const gone = fetcher.bytes('p', { key: 'a' });
    await tick();
    calls[0].reject(new ApiError(410, 'error', 'Removed.'));
    await assert.rejects(gone, (error) => error.status === 410 && error.code === 'gone');
    assert.equal(calls.length, 1);
  });

  it('other errors (400, 404, 502) reject at once without a retry', async () => {
    const { fetcher, calls } = setup();
    for (const [status, code] of [[400, 'invalid'], [404, 'gap'], [502, 'unreadable']]) {
      const request = fetcher.bytes(`p${status}`, { key: `k${status}` });
      await tick();
      calls.at(-1).reject(new ApiError(status, code, 'No.'));
      await assert.rejects(request, (error) => error.code === code);
    }
    assert.equal(calls.length, 3);
  });

  it('a request waiting to retry does not hold a slot, and a newer request with its key replaces it', async () => {
    const { fetcher, calls, timers } = setup({ bytes: 1, json: 1 });
    const first = fetcher.bytes('first', { key: 'tile' }).catch((error) => error);
    const other = fetcher.bytes('other', { key: 'other' });
    await tick();
    calls[0].reject(busy(4));
    await tick();
    assert.equal(calls.length, 2, 'the other request used the free slot');
    assert.equal(calls[1].path, 'other');
    const newer = fetcher.bytes('newer', { key: 'tile' });
    assert.equal((await first).name, 'Superseded');
    calls[1].resolve(bytesOf(1));
    await other;
    await tick();
    assert.equal(calls[2].path, 'newer');
    calls[2].resolve(bytesOf(7));
    assert.equal((await newer).data.byteLength, 7);
    await timers.advance(5000);
    assert.equal(calls.length, 3, 'the replaced request never retried');
  });

  it('a retry queues behind a higher priority request but keeps the free slot count right', async () => {
    const { fetcher, calls, timers } = setup({ bytes: 1, json: 1 });
    const retried = fetcher.bytes('retried', { key: 'a', priority: 0 });
    await tick();
    calls[0].reject(busy(1));
    await tick();
    const urgent = fetcher.bytes('urgent', { key: 'b', priority: 9 });
    await tick();
    assert.equal(calls[1].path, 'urgent');
    await timers.advance(1000);
    assert.equal(calls.length, 2, 'still waiting for the slot');
    calls[1].resolve(bytesOf(1));
    await urgent;
    await tick();
    assert.equal(calls[2].path, 'retried');
    calls[2].resolve(bytesOf(1));
    await retried;
  });
});

describe('what it passes to get and getBytes', () => {
  it('gives every request the shared signal and the stuck timeout', async () => {
    const { fetcher, calls } = setup();
    fetcher.json('a');
    fetcher.bytes('b');
    await tick();
    assert.equal(STUCK_MS, 8000);
    for (const call of calls) {
      assert.equal(call.options.timeoutMs, 8000);
      assert.ok(call.signal instanceof AbortSignal);
    }
    assert.equal(calls[0].signal, calls[1].signal);
  });
});

describe('destroy', () => {
  it('aborts what runs, rejects what waits, and refuses new requests', async () => {
    const { fetcher, calls } = setup({ bytes: 1, json: 1 });
    const running = fetcher.bytes('running', { key: 'a' });
    const waiting = fetcher.bytes('waiting', { key: 'b' });
    await tick();
    fetcher.destroy();
    assert.equal(calls[0].signal.aborted, true);
    await assert.rejects(waiting, (error) => error.name === 'AbortError');
    calls[0].reject(Object.assign(new Error('aborted'), { name: 'AbortError' }));
    await assert.rejects(running, (error) => error.name === 'AbortError');
    await assert.rejects(fetcher.json('late'), (error) => error.name === 'AbortError');
    assert.equal(calls.length, 1);
    fetcher.destroy();
  });

  it('a request waiting to retry is rejected too and never fires', async () => {
    const { fetcher, calls, timers } = setup();
    const request = fetcher.bytes('p', { key: 'a' });
    await tick();
    calls[0].reject(new ApiError(429, 'busy', 'Busy.', null, { retryAfter: 1 }));
    await tick();
    fetcher.destroy();
    await assert.rejects(request, (error) => error.name === 'AbortError');
    await timers.advance(5000);
    assert.equal(calls.length, 1);
  });
});
