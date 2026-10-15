import assert from 'node:assert/strict';
import test from 'node:test';
import { fileKey, fnv1a64, fragmentId, parseFragmentId, segmentName } from '../web-dev/lib/identity.mjs';

// The expected values were computed by the engine's own code (ArchiveIdentity.swift, compiled and run on these strings), so JS and Swift
// agree on every id: the page and the daemon never exchange a path, only these.
const VECTORS = [
  ['', 'cbf29ce48422'],
  ['a', 'af63dc4c8601'],
  ['0A1B2C3D-0000-4000-8000-000000000001/2026-10-10/13-24-05', '3eae26aad220'],
  ['0A1B2C3D-0000-4000-8000-000000000001/2026-10-10/13-24-05-2', 'bfac07efed3c'],
  ['Kamera Küche/2026-10-10/00-00-00', '92edf76b0035'],
  ['00000000-0000-4000-8000-000000000048/2026-10-10/00-00-00', '001f6fa07674'], // the hash starts with two zero digits: no digit may be lost
];

test('fileKey is the high 48 bits of FNV-1a-64 as 12 lowercase hex digits', () => {
  for (const [segment, key] of VECTORS) assert.equal(fileKey(segment), key, segment);
});

test('fnv1a64 reproduces the published test vectors', () => {
  assert.equal(fnv1a64('').toString(16), 'cbf29ce484222325');
  assert.equal(fnv1a64('a').toString(16), 'af63dc4c8601ec8c');
  assert.equal(fnv1a64('foobar').toString(16), '85944171f73967e8');
});

test('fragment ids are <fileKey>.<index> and parse back', () => {
  assert.equal(fragmentId('3eae26aad220', 17), '3eae26aad220.17');
  assert.deepEqual(parseFragmentId('3eae26aad220.17'), { fileKey: '3eae26aad220', index: 17 });
  assert.deepEqual(parseFragmentId('3eae26aad220.0'), { fileKey: '3eae26aad220', index: 0 });
  assert.deepEqual(parseFragmentId('3eae26aad220.9999999'), { fileKey: '3eae26aad220', index: 9999999 });
});

test('parseFragmentId refuses everything else', () => {
  for (const bad of ['', '3eae26aad220', '3eae26aad220.', '3eae26aad220.01', '3eae26aad220.-1', '3eae26aad220.10000000', '3EAE26AAD220.1', '3eae26aad22.1', '3eae26aad2200.1', '3eae26aad220.1 ', ' 3eae26aad220.1', '../etc.1', '3eae26aad220.1/../x']) {
    assert.equal(parseFragmentId(bad), null, JSON.stringify(bad));
  }
});

test('segmentName follows the folder layout, in UTC, with -N for a second file in one second', () => {
  const start = Date.UTC(2026, 9, 10, 13, 24, 5, 678);
  assert.equal(segmentName('0A1B2C3D-0000-4000-8000-000000000001', start), '0A1B2C3D-0000-4000-8000-000000000001/2026-10-10/13-24-05');
  assert.equal(segmentName('cam', start, 1), 'cam/2026-10-10/13-24-05');
  assert.equal(segmentName('cam', start, 2), 'cam/2026-10-10/13-24-05-2');
  assert.equal(segmentName('cam', Date.UTC(2026, 0, 1, 0, 0, 0)), 'cam/2026-01-01/00-00-00');
});
