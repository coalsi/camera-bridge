// The live video: the message reader (messages split across network chunks, several in one chunk, unknown types ignored), the request that
// keeps itself open (a new one after an end or a failure, a little later each time; one that went silent after pictures is given up), and the
// player's health (the last frame, the frames a second, the picture's size).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createLivePlayer, createParser, openLive } from '../web/js/live/mux.js';

function message(type, camera, bytes) {
  const out = new Uint8Array(6 + bytes.length);
  out[0] = type; out[1] = camera;
  const n = bytes.length;
  out[2] = (n >>> 24) & 0xff; out[3] = (n >>> 16) & 0xff; out[4] = (n >>> 8) & 0xff; out[5] = n & 0xff;
  out.set(bytes, 6);
  return out;
}

test('messages come out whole whatever the chunks', () => {
  const seen = [];
  const feed = createParser((kind, index, payload) => seen.push([kind, index, Array.from(payload)]));
  const a = message(1, 0, new TextEncoder().encode('{"mime":"x"}'));
  const b = message(4, 3, new Uint8Array(70_000).fill(9));
  const c = message(9, 1, new Uint8Array([1]));          // unknown type: skipped
  const d = message(3, 2, new Uint8Array([5, 6]));
  const all = new Uint8Array([...a, ...b, ...c, ...d]);
  for (let i = 0; i < all.length; i += 997) feed(all.subarray(i, i + 997));
  assert.deepEqual(seen.map(([kind, index, bytes]) => [kind, index, bytes.length]), [['meta', 0, 12], ['keyframe', 3, 70_000], ['delta', 2, 2]]);
  assert.deepEqual(seen[2][2], [5, 6]);
});

test('a length above 2 GB is read unsigned, and an empty payload is a message', () => {
  const seen = [];
  const feed = createParser((kind, index, payload) => seen.push([kind, index, payload.length]));
  feed(message(5, 7, new Uint8Array(0)));
  assert.deepEqual(seen, [['status', 7, 0]]);
  const big = new Uint8Array([3, 0, 0x80, 0, 0, 0]);   // claims 2 GiB: waits for more, never misreads it as negative
  feed(big);
  assert.equal(seen.length, 1);
});

// MARK: The request

/** A live answer the test feeds: `push(bytes)`, `end()`, `fail()`. Its reader rejects when the request's signal aborts. */
function fakeAnswer(signal) {
  const waiting = [];
  const chunks = [];
  let ended = false;
  let failed = null;
  const settle = () => {
    while (waiting.length && (chunks.length || ended || failed)) {
      const { resolve, reject } = waiting.shift();
      if (failed) reject(failed);
      else if (chunks.length) resolve({ value: chunks.shift(), done: false });
      else resolve({ value: undefined, done: true });
    }
  };
  signal.addEventListener('abort', () => { failed = new DOMException('The request was stopped.', 'AbortError'); settle(); });
  return {
    body: { getReader: () => ({ read: () => new Promise((resolve, reject) => { waiting.push({ resolve, reject }); settle(); }) }) },
    push(bytes) { chunks.push(bytes); settle(); },
    end() { ended = true; settle(); },
    fail() { failed = new Error('network'); settle(); },
  };
}

/** openLive with a fake network and hand-driven timers: `answers` are the live answers in order; `tick(ms)` runs the timers due. */
function liveHarness(options = {}) {
  const answers = [];
  const states = [];
  const messages = [];
  let clock = 0;
  const timers = new Map();
  let nextTimer = 1;
  const setTimer = (fn, ms) => { const id = nextTimer++; timers.set(id, { at: clock + ms, fn }); return id; };
  const clearTimer = (id) => timers.delete(id);
  const settle = async () => { for (let i = 0; i < 20; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
  const live = openLive(['A', 'B'], {
    stream: 'automatic', width: 640, ...options,
    onMessage: (index, message) => messages.push([index, message.kind]),
    onState: (state) => states.push(state),
    open: async (path, { signal }) => { const answer = fakeAnswer(signal); answer.path = path; answers.push(answer); return answer.body; },
    setTimer, clearTimer, wait: (ms) => new Promise((resolve) => setTimer(resolve, ms)),
  });
  return {
    live, answers, states, messages, settle,
    async tick(ms) {
      const until = clock + ms;
      for (;;) {
        const due = [...timers.entries()].filter(([, t]) => t.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
        if (!due) break;
        clock = due[1].at;
        timers.delete(due[0]);
        due[1].fn();
        await settle();
      }
      clock = until;
      await settle();
    },
  };
}

test('the live request asks for the cameras, the stream and the width, and opens again after it ends, a little later each failure', async () => {
  const t = liveHarness();
  await t.settle();
  assert.equal(t.answers.length, 1);
  assert.equal(t.answers[0].path, 'live?cameras=A,B&stream=automatic&width=640');
  t.answers[0].push(message(1, 0, new TextEncoder().encode('{"mime":"video/mp4","width":640,"height":360,"stream":"sub"}')));
  t.answers[0].push(message(4, 0, new Uint8Array([1, 2, 3])));
  await t.settle();
  assert.deepEqual(t.messages, [[0, 'meta'], [0, 'keyframe']]);
  t.answers[0].end();
  await t.settle();
  await t.tick(999);
  assert.equal(t.answers.length, 1, 'a short wait first');
  await t.tick(1);
  assert.equal(t.answers.length, 2, 'then a new request');
  t.answers[1].fail();
  await t.settle();
  await t.tick(1999);
  assert.equal(t.answers.length, 2, 'a failure waits longer');
  await t.tick(1);
  assert.equal(t.answers.length, 3);
  t.live.close();
});

test('a request that brought pictures and then nothing for 10 s is given up and opened again; one that never brought a picture is left open', async () => {
  const t = liveHarness();
  await t.settle();
  t.answers[0].push(message(5, 0, new TextEncoder().encode('{"state":"waiting"}')));
  await t.tick(60_000);
  assert.equal(t.answers.length, 1, 'cameras that are all away send nothing: not taken for dead');
  t.answers[0].push(message(3, 1, new Uint8Array([9])));
  await t.settle();
  await t.tick(9_999);
  t.answers[0].push(message(3, 1, new Uint8Array([9])));
  await t.settle();
  await t.tick(9_999);
  assert.equal(t.answers.length, 1, 'every chunk counts');
  await t.tick(1);
  assert.ok(t.states.includes('silent'), 'the box went silent');
  await t.tick(2_000);
  assert.equal(t.answers.length, 2, 'a new request after the usual wait');
  t.live.close();
  await t.tick(60_000);
  assert.equal(t.answers.length, 2, 'closed: nothing more');
});

// MARK: The player's health

test('the player tells when its last frame came, how many come a second, and the picture’s size and stream', () => {
  let now = 1000;
  const video = { addEventListener() {}, removeEventListener() {}, removeAttribute() {}, load() {}, muted: false };
  const player = createLivePlayer(video, { now: () => now });
  assert.deepEqual(player.health(), { lastFrameAt: null, fps: null, width: null, height: null, stream: null });
  player.meta({ mime: 'video/mp4; codecs="avc1.640028"', width: 1920, height: 1080, stream: 'main' });
  for (let i = 0; i < 31; i += 1) { player.media(new Uint8Array([1]), i === 0); now += 100; }
  const health = player.health();
  assert.equal(health.lastFrameAt, 4000);
  assert.equal(health.fps, 10);
  assert.deepEqual([health.width, health.height, health.stream], [1920, 1080, 'main']);
  now += 6000;
  assert.equal(player.health().fps, null, 'no frames lately: no rate');
  assert.equal(player.health().lastFrameAt, 4000);
  player.destroy();
});
