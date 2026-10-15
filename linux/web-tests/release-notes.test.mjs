import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RELEASE_NOTES, compareVersions, notesFor } from '../web/js/release-notes.js';

test('versions compare part by part, not as text', () => {
  assert.equal(compareVersions('0.1.101', '0.2.0'), -1);
  assert.equal(compareVersions('0.10', '0.9'), 1);
  assert.equal(compareVersions('1.0', '1.0.0'), 0);
});

test('the notes are newest first, each with a date and lines', () => {
  for (let i = 1; i < RELEASE_NOTES.length; i += 1) assert.equal(compareVersions(RELEASE_NOTES[i - 1].version, RELEASE_NOTES[i].version), 1);
  for (const entry of RELEASE_NOTES) {
    assert.match(entry.date, /^\d{4}-\d{2}-\d{2}$/);
    assert.ok(entry.items.length > 0);
  }
  assert.equal(notesFor(RELEASE_NOTES[0].version), RELEASE_NOTES[0]);
  assert.equal(notesFor('0.0.1'), null);
});
