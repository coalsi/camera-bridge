import test from 'node:test';
import assert from 'node:assert/strict';
import {
  BYTES_PER_KBPS_DAY, KEEP_DAY_CHOICES, MAX_SIZE_CHOICES_GB, capacityCaption, dailyRate, deleteSentence, describeLocation, describeStorage,
  keepLabel, sizeLabel, sizeText, withCurrent,
} from '../web/js/nvr/storage-info.js';

const GB = 1e9;
const HOUR = 3_600_000;
const DAY = 86_400_000;

/** The answer of GET nvr/storage (T00 contract R1) with a few values replaced. */
function storage(overrides = {}) {
  return {
    location: 'builtin', label: 'This box’s storage', state: 'ok', message: null, recordingCameras: 2, keepDays: 7, maxSizeGB: 500,
    limits: { keepDays: [1, 365], maxSizeGB: [10, 100000] },
    usedBytes: 120 * GB, freeBytes: 260 * GB, totalBytes: 460 * GB, floorBytes: 23 * GB, roomBytes: 357 * GB, effectiveMaxBytes: 414 * GB,
    oldest: 1_760_000_000_000, newest: 1_760_000_000_000 + 2 * DAY, ...overrides,
  };
}

test('menus: a stored value outside the list is added in its place', () => {
  assert.deepEqual(withCurrent(KEEP_DAY_CHOICES, 7), [1, 3, 7, 14, 30, 90]);
  assert.deepEqual(withCurrent(KEEP_DAY_CHOICES, 10), [1, 3, 7, 10, 14, 30, 90]);
  assert.deepEqual(withCurrent(MAX_SIZE_CHOICES_GB, 750), [100, 250, 500, 750, 1000, 2000, 4000, 8000]);
  assert.deepEqual(withCurrent([1, 2], undefined), [1, 2]);
});

test('labels use decimal units, like the bridge', () => {
  assert.equal(keepLabel(1), '1 day');
  assert.equal(keepLabel(14), '14 days');
  assert.equal(sizeLabel(500), '500 GB');
  assert.equal(sizeLabel(1000), '1 TB');
  assert.equal(sizeLabel(4000), '4 TB');
  assert.equal(sizeLabel(1500), '1.5 TB');
  assert.equal(sizeLabel(1050), '1050 GB');
});

test('sizeText: decimal units, one decimal below 10, whole numbers from 10', () => {
  assert.equal(sizeText(0), '0 B');
  assert.equal(sizeText(999), '999 B');
  assert.equal(sizeText(1500), '1.5 KB');
  assert.equal(sizeText(9.9 * GB), '9.9 GB');
  assert.equal(sizeText(10 * GB), '10 GB');
  assert.equal(sizeText(43.2 * GB), '43 GB');
  assert.equal(sizeText(460 * GB), '460 GB');
  assert.equal(sizeText(1.2e12), '1.2 TB');
  assert.equal(sizeText(12e12), '12 TB');
});

test('the daily rate is measured once an hour is recorded, else worked out from the cameras’ bit rates', () => {
  const cameras = [
    { id: 'a', nvrEnabled: true, status: { mainStreamInfo: { bitrateKbps: 4000 } } },
    { id: 'b', nvrEnabled: true, status: { mainStreamInfo: { bitrateKbps: 2000 } } },
    { id: 'c', nvrEnabled: false, status: { mainStreamInfo: { bitrateKbps: 8000 } } },
    { id: 'd', nvrEnabled: true, status: {} },
  ];
  assert.equal(BYTES_PER_KBPS_DAY, 10_800_000);
  assert.equal(4000 * BYTES_PER_KBPS_DAY, 43.2 * GB, '4 Mbps is 43.2 GB a day');
  const none = { usedBytes: 0, oldest: null, newest: null };
  assert.deepEqual(dailyRate(storage(none), cameras), { perDay: 6000 * BYTES_PER_KBPS_DAY, measured: false }, 'only cameras that record count');
  const shortSpan = dailyRate(storage({ oldest: 1_760_000_000_000, newest: 1_760_000_000_000 + HOUR - 1 }), cameras);
  assert.equal(shortSpan.measured, false, 'under an hour is not measured');
  const measured = dailyRate(storage({ usedBytes: 100 * GB, oldest: 1_760_000_000_000, newest: 1_760_000_000_000 + 2 * DAY }), cameras);
  assert.deepEqual(measured, { perDay: 50 * GB, measured: true });
  assert.equal(dailyRate(storage(none), [{ id: 'z', nvrEnabled: false }]), null);
});

test('the caption says how long the storage holds, and when the size limit decides instead of the days', () => {
  assert.equal(capacityCaption(storage(), { perDay: 40 * GB, measured: true }), 'About 40 GB a day. Keeping 7 days takes about 280 GB, which fits.');
  assert.equal(capacityCaption(storage(), { perDay: 150 * GB, measured: true }),
    'About 150 GB a day. This storage holds about 2.3 days, fewer than the 7 days you chose, so older recordings are deleted sooner.');
  assert.match(capacityCaption(storage(), { perDay: 43.2 * GB, measured: false }), /^About 43 GB a day \(worked out from the cameras’ bit rates\)\./);
  assert.match(capacityCaption(storage({ keepDays: 1, roomBytes: 30 * GB, effectiveMaxBytes: 30 * GB }), { perDay: 60 * GB, measured: true }),
    /This storage holds less than a day, fewer than the 1 day you chose/);
  assert.match(capacityCaption(storage({ keepDays: 7, roomBytes: 413 * GB, effectiveMaxBytes: 414 * GB }), { perDay: 59.5 * GB, measured: true }),
    /holds about 6\.9 days, fewer than the 7 days/, 'rounded down: never reads as equal to the days chosen');
  assert.equal(capacityCaption(storage(), null), null);
  assert.equal(capacityCaption(storage({ totalBytes: 0 }), { perDay: 1, measured: true }), null, 'the drive has not been measured yet');
});

test('the confirmation text drops the instruction meant for API clients', () => {
  assert.equal(deleteSentence('This will delete about 40 GB of the oldest recordings. Send confirm to continue.'), 'This will delete about 40 GB of the oldest recordings.');
  assert.equal(deleteSentence('This will delete about 3 GB of the oldest recordings.'), 'This will delete about 3 GB of the oldest recordings.');
  assert.equal(deleteSentence(''), 'This will delete the oldest recordings.');
  assert.equal(deleteSentence(undefined), 'This will delete the oldest recordings.');
});

test('a location row says what is free and what the drive has room for', () => {
  assert.equal(describeLocation({ freeBytes: 260 * GB, totalBytes: 460 * GB, roomBytes: 240 * GB }), '260 GB free of 460 GB · room for about 240 GB of recordings');
  assert.equal(describeLocation({ freeBytes: 260 * GB, totalBytes: 460 * GB, roomBytes: null }), '260 GB free of 460 GB');
  assert.equal(describeLocation({ freeBytes: null, totalBytes: null, roomBytes: null }), '');
});

test('describeStorage: no folder chosen yet', () => {
  const view = describeStorage(storage({
    location: null, label: null, state: 'noFolder', message: 'Choose where to store recordings.', recordingCameras: 0,
    usedBytes: 0, freeBytes: 0, totalBytes: 0, floorBytes: 0, roomBytes: 0, effectiveMaxBytes: 0, oldest: null, newest: null,
  }), []);
  assert.equal(view.hasFolder, false);
  assert.equal(view.problem, null, 'the empty state says it; no warning on top');
  assert.equal(view.caption, null);
});

test('describeStorage: a missing drive shows the bridge’s sentence and keeps the numbers', () => {
  const view = describeStorage(storage({ state: 'folderMissing', message: 'The recordings folder isn’t available. Reconnect the drive or choose another folder.' }), []);
  assert.equal(view.hasFolder, true);
  assert.equal(view.problem, 'The recordings folder isn’t available. Reconnect the drive or choose another folder.');
  assert.equal(view.used, '120 GB');
  assert.equal(view.free, '260 GB of 460 GB');
  assert.equal(view.barLabel, 'Recordings use 120 GB of this 460 GB drive; 260 GB is free.');
  assert.ok(Math.abs(view.usedFraction - 120 / 460) < 1e-9);
  assert.equal(view.reserved, 'Camera Bridge keeps 23 GB free for updates and settings, and pauses recording below that.');
});

test('describeStorage: the real limit is said when the drive is smaller than the size chosen', () => {
  const small = describeStorage(storage({ totalBytes: 64 * GB, freeBytes: 40 * GB, usedBytes: 4 * GB, floorBytes: 8 * GB, roomBytes: 36 * GB, effectiveMaxBytes: 48 * GB }), []);
  assert.equal(small.effective, 'This drive can hold only 48 GB of recordings, less than the 500 GB you chose, so that is the limit.');
  const roomy = describeStorage(storage({ effectiveMaxBytes: 500 * GB }), []);
  assert.equal(roomy.effective, null);
});
