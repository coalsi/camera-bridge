// The archive drive on the page: its card on the System page and the words it shares with the Recording card in Settings (both in
// screens/archive-drive-card.js), and a tile or the watch screen inside recordings that are on an archive drive while it is not connected.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { ARCHIVE_PURPOSE, describeArchive } from '../web/js/screens/archive-drive-card.js';
import { TEXT, tileState } from '../web/js/screens/nvr-model.js';
import { makeTimeFormatter, stageState } from '../web/js/screens/watch-state.js';

let browser;
before(() => { browser = installFakeBrowser(); });
after(() => browser?.restore());

const text = (node) => (node.childNodes ?? []).map((child) => (child.tagName ? text(child) : child.data ?? child.textContent ?? '')).join('');
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const buttons = (root) => all(root, (node) => node.localName === 'button');
const labels = (root) => buttons(root).map((button) => text(button).trim());

const GB = 1e9;
const CONNECTED = {
  state: 'connected', message: null, usedBytes: 900 * GB, freeBytes: 2_700 * GB, totalBytes: 4_000 * GB, floorBytes: 2 * 1024 ** 3,
  oldest: Date.UTC(2026, 9, 3, 8, 0), newest: Date.UTC(2026, 9, 18, 8, 0),
  moving: { cameraID: 'CAM-1', cameraName: 'Porch', start: Date.UTC(2026, 9, 19, 13, 0), bytes: 400_000_000, doneBytes: 100_000_000 },
  waitingFiles: 3, waitingBytes: 1_200_000_000, movedFiles: 12, movedBytes: 5_400_000_000,
};
const AWAY = { ...CONNECTED, state: 'notConnected', message: 'The archive drive isn’t connected. Its recordings play again when it is plugged back in.', freeBytes: 0, totalBytes: 0, moving: null, waitingFiles: 0, movedFiles: 0 };
const when = (ms) => new Date(ms).toISOString().slice(0, 16);

// MARK: The words

test('a connected archive drive says what it holds, how far back it goes and what moves now', () => {
  const view = describeArchive(CONNECTED, { when });
  assert.equal(view.status, 'Connected');
  assert.equal(view.used, '900 GB');
  assert.equal(view.free, '2.7 TB of 4.0 TB');
  assert.equal(view.oldest, '2026-10-03T08:00');
  assert.equal(view.moving, 'Moving Porch’s recording from 2026-10-19T13:00 (25%)');
  assert.equal(view.waiting, '3 more recordings wait to move (1.2 GB)');
  assert.equal(view.moved, '12 recordings (5.4 GB) moved here since the bridge started');
  assert.equal(describeArchive({ ...CONNECTED, moving: null, waitingFiles: 0, movedFiles: 0 }, { when }).moving, 'Nothing right now');
  assert.equal(describeArchive({ ...CONNECTED, waitingFiles: 1, waitingBytes: 400_000_000 }, { when }).waiting, '1 more recording waits to move (400 MB)');
});

test('an archive drive that is away says so, and what it holds is still counted', () => {
  const view = describeArchive(AWAY, { when });
  assert.equal(view.status, 'Not connected');
  assert.equal(view.message, AWAY.message);
  assert.equal(view.used, '900 GB', 'what it holds is known from the box’s list');
  assert.equal(view.free, '—');
  assert.equal(view.moving, '—');
  assert.equal(describeArchive({ ...AWAY, state: 'notAnswering' }).status, 'Not answering');
  assert.equal(describeArchive({ ...AWAY, state: 'failing' }).status, 'Not working');
  assert.equal(describeArchive({ ...CONNECTED, oldest: null }, { when }).oldest, 'Nothing moved here yet');
});

test('a bridge without an archive drive has nothing to say about one', () => {
  assert.equal(describeArchive(null), null);
  assert.equal(describeArchive(undefined), null);
});

// MARK: The card

const DRIVES = {
  state: 'none', message: 'No archive drive is chosen.',
  drives: [
    { id: 'sdb', name: 'sdb', model: 'Expansion HDD', sizeBytes: 4_000_787_030_016, eligible: true, problems: [], phrase: 'ERASE ALL DATA ON sdb', isArchiveDrive: true, inUse: false },
    { id: 'sdc', name: 'sdc', model: 'Portable SSD', sizeBytes: 500_000_000_000, eligible: true, problems: [], phrase: 'ERASE ALL DATA ON sdc', isArchiveDrive: false, inUse: false },
    { id: 'sda', name: 'sda', model: 'SATA SSD', sizeBytes: 476_000_000_000, eligible: false, problems: ['this is the disk the system is running from'], phrase: 'ERASE ALL DATA ON sda' },
  ],
};

async function card(options) {
  const { archiveCardFor } = await import('../web/js/screens/archive-drive-card.js');
  const calls = [];
  const el = archiveCardFor({ load: () => calls.push('load'), use: (disk, keep) => calls.push(`use ${disk.id} ${keep}`), forget: () => calls.push('forget'), ...options });
  return { el, calls };
}

test('the card says what the archive drive is for and offers to find drives', async () => {
  const { el, calls } = await card({});
  const words = text(el);
  assert.match(words, /Archive drive/);
  assert.ok(words.includes(ARCHIVE_PURPOSE), words);
  assert.deepEqual(labels(el), ['Find drives']);
  buttons(el)[0].click();
  assert.deepEqual(calls, ['load']);
});

test('each usable drive has its button: an archive drive is used as it is, another one is erased with the typed sentence', async () => {
  const { el, calls } = await card({ archives: DRIVES });
  const words = text(el);
  assert.match(words, /a Camera Bridge archive drive/);
  assert.match(words, /this is the disk the system is running from/);
  assert.deepEqual(labels(el), ['Use as archive', 'Erase and use as archive…', 'Use as archive…', 'Look again']);
  for (const button of buttons(el)) button.click();
  assert.deepEqual(calls, ['use sdb true', 'use sdb false', 'use sdc false', 'load']);
  const { archivePhrase } = await import('../web/js/screens/archive-drive-card.js');
  assert.equal(archivePhrase(DRIVES.drives[1]), 'ERASE ALL DATA ON sdc', 'the same sentence as the recording drive’s erase');
  assert.equal(archivePhrase({ name: 'nvme0n1' }), 'ERASE ALL DATA ON nvme0n1');
});

test('the drive in use is named, and it can be let go', async () => {
  const chosen = { state: 'mounted', message: 'Older recordings move to the archive drive.', drives: [{ ...DRIVES.drives[0], inUse: true }] };
  const { el, calls } = await card({ archives: chosen, storage: { archive: CONNECTED } });
  const words = text(el);
  assert.match(words, /the archive drive now/);
  assert.match(words, /The archive drive is in place\./);
  assert.match(words, /Connected/);
  assert.match(words, /Moving Porch’s recording from/);
  assert.match(words, /3 more recordings wait to move/);
  assert.deepEqual(labels(el), ['Look again', 'Stop using the archive drive…']);
  buttons(el)[1].click();
  assert.deepEqual(calls, ['forget']);
});

test('while the drive is unplugged the card says so plainly', async () => {
  const { el } = await card({ archives: { state: 'missing', message: '', drives: [] }, storage: { archive: AWAY } });
  const words = text(el);
  assert.match(words, /Not connected/);
  assert.match(words, /isn’t plugged in\. Its recordings play again when it is back/);
  assert.match(words, /No other drive was found/);
});

test('every button waits while the page is busy', async () => {
  const { el } = await card({ archives: DRIVES, busy: 'archive' });
  assert.ok(buttons(el).every((button) => button.disabled));
});

// MARK: The player

const T0 = Date.UTC(2026, 9, 14, 20, 0, 0);
const camera = { id: 'CAM-1', name: 'Porch', isEnabled: true, nvrEnabled: true, status: { connection: 'online', nvr: { state: 'recording', notes: [] } } };

test('a tile inside recordings on an unplugged archive drive says so, not "No recording"', () => {
  const tile = tileState({ camera, extent: { oldest: T0 - 86_400_000, newest: T0 }, coverage: { kind: 'gap', away: true, next: T0 - 3_600_000 }, started: true, position: T0 - 7_200_000,
    formatTime: (ms) => `t${ms - T0}` });
  assert.equal(tile.state, 'gap');
  assert.equal(tile.note.title, TEXT.archiveAway);
  assert.equal(tile.note.detail, 'Plays again when the drive is back. Next recording on this box at t-3600000');
  const last = tileState({ camera, extent: { oldest: T0 - 86_400_000, newest: T0 }, coverage: { kind: 'gap', away: true, next: null }, started: true, position: T0 });
  assert.equal(last.note.detail, 'Plays again when the drive is plugged back in.');
});

test('the watch screen says the same, with the way to the next recording on the box', () => {
  const format = makeTimeFormatter({ timeZone: 'UTC', locale: 'en-US' });
  const state = stageState({ mode: 'paused', nvrEnabled: true, nvrState: 'recording', extent: { oldest: T0 - 86_400_000, newest: T0, typicalGOP: 2 }, serverNowMs: T0,
    positionMs: T0 - 7_200_000, cell: { kind: 'gap', away: true, next: T0 - 3_600_000 }, presented: true, catalogPhase: 'ready', playable: true, formatTime: format });
  assert.equal(state.overlay.title, 'On the archive drive (not connected)');
  assert.match(state.overlay.body, /plays again when the archive drive is plugged back in\. Next recording on this box at/);
  assert.deepEqual(state.overlay.actions.map((action) => action.id), ['jump']);
});
