import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RELEASE_NOTES, compareVersions, isBeta, notesByDay, notesFor, notesSince } from '../web/js/release-notes.js';

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

test('a version before 1.0 is a beta; 1.0 and later are numbered releases', () => {
  for (const version of ['0.1.108', '0.2.0', '0.1', '0']) assert.equal(isBeta(version), true, version);
  for (const version of ['1.0', '1.0.0', '1.2.3', '10.0', '2']) assert.equal(isBeta(version), false, version);
  for (const version of [undefined, null, '', 'beta', '.1']) assert.equal(isBeta(version), false, String(version));
});

// Made-up notes, out of order on purpose: two days of betas, then 1.0.
const NOTES = [
  { version: '1.0.0', date: '2026-11-02', title: 'One', items: ['a'] },
  { version: '0.1.110', date: '2026-10-18', title: 'Ten', items: ['a'] },
  { version: '0.1.108', date: '2026-10-17', title: 'Eight', items: ['a'] },
  { version: '0.1.109', date: '2026-10-17', title: 'Nine', items: ['a'] },
  { version: '0.1.107', date: '2026-10-16', title: 'Seven', items: ['a'] },
];

test('the notes group by day, newest day first and each day newest build first', () => {
  const days = notesByDay(NOTES.filter((entry) => isBeta(entry.version)));
  assert.deepEqual(days.map((day) => day.date), ['2026-10-18', '2026-10-17', '2026-10-16']);
  assert.deepEqual(days.map((day) => day.entries.map((entry) => entry.version)), [['0.1.110'], ['0.1.109', '0.1.108'], ['0.1.107']]);
});

test('the real notes group by day with every entry kept once', () => {
  const days = notesByDay();
  assert.equal(days.flatMap((day) => day.entries).length, RELEASE_NOTES.length);
  for (let i = 1; i < days.length; i += 1) assert.ok(days[i - 1].date > days[i].date);
  for (const day of days) for (const entry of day.entries) assert.equal(entry.date, day.date);
});

test('what is new since the last version seen: every entry after it, up to the version running', () => {
  const versions = (seen, running) => notesSince(seen, running, NOTES).map((entry) => entry.version);
  assert.deepEqual(versions('0.1.107', '0.1.110'), ['0.1.110', '0.1.109', '0.1.108']);
  assert.deepEqual(versions('0.1.108', '0.1.109'), ['0.1.109'], 'an entry newer than the running version is not news yet');
  assert.deepEqual(versions('0.1.109', '1.0.0'), ['1.0.0', '0.1.110'], 'from the beta to 1.0');
  assert.deepEqual(versions('0.1.110', '0.1.110'), []);
  assert.deepEqual(versions('0.1.110', '0.1.109'), [], 'after a rollback nothing is new');
  assert.deepEqual(versions('0.1.108.5', '0.1.110'), ['0.1.110', '0.1.109'], 'a version without notes of its own still counts as seen');
});

test('a last-seen version that is missing, not a version, or older than every entry gives the newest entry only', () => {
  const versions = (seen, running) => notesSince(seen, running, NOTES).map((entry) => entry.version);
  for (const seen of [null, undefined, '', '  ', 'garbage', '0.0-dev']) assert.deepEqual(versions(seen, '0.1.110'), ['0.1.110'], String(seen));
  assert.deepEqual(versions('0.0.1', '0.1.110'), ['0.1.110']);
  assert.deepEqual(versions('0.1.100', '0.1.109'), ['0.1.109'], 'the newest up to the running version');
  assert.deepEqual(versions('0.0.1', '0.0.5'), [], 'nothing is as old as the running version');
  assert.deepEqual(notesSince('0.1.1', '0.1.2', []), []);
});
