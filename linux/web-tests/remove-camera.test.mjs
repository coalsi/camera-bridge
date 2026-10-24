// Removing a camera keeps its Apple Home pairing for 30 days: the remove dialog says so.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

test('the remove dialog says the Apple Home pairing is kept for 30 days', () => {
  const source = readFileSync(new URL('../web/js/screens/camera.js', import.meta.url), 'utf8');
  assert.ok(source.includes('Its Apple Home pairing is kept for 30 days: add the same camera again within that time and Home keeps it.'));
  assert.ok(!source.includes('deletes its saved password. Remove it from the Home app as well.'), 'no longer tells everyone to remove it from Home');
});
