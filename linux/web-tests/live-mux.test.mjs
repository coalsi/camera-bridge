// The live video's message reader: messages split across network chunks, several in one chunk, unknown types ignored.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createParser } from '../web/js/live/mux.js';

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
