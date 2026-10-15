import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TEXT, recordChip, tileState, tileSummary } from '../web/js/screens/nvr-model.js';

const id = (n) => `00000000-0000-4000-8000-00000000000${n}`;
const T0 = 1760099000000;

function camera(overrides = {}) {
  return {
    id: id(1), name: 'Front door', isEnabled: true, nvrEnabled: true,
    status: { connection: 'online', connectionReason: null, nvr: { state: 'recording', detail: null, pause: null, notes: [] } },
    ...overrides,
  };
}

// MARK: tiles

test('the Record chip follows status.nvr.state, and nvrEnabled when the status has none', () => {
  assert.deepEqual(recordChip(camera()), { text: 'REC', tone: 'recording' });
  assert.deepEqual(recordChip(camera({ status: { connection: 'online', nvr: { state: 'paused' } } })), { text: 'Paused', tone: 'warning' });
  assert.deepEqual(recordChip(camera({ status: { connection: 'online', nvr: { state: 'waiting' } } })), { text: 'Waiting', tone: 'idle' });
  assert.deepEqual(recordChip(camera({ status: { connection: 'online', nvr: { state: 'off' } }, nvrEnabled: false })), { text: 'Record off', tone: 'idle' });
  assert.deepEqual(recordChip(camera({ status: undefined })), { text: 'Waiting', tone: 'idle' });
  assert.deepEqual(recordChip(camera({ status: undefined, nvrEnabled: false })), { text: 'Record off', tone: 'idle' });
});

const extent = { oldest: T0 - 86_400_000, newest: T0 };
const hhmmss = (ms) => `t${ms - T0}`;

// One row per state the page can show: the facts in, the tile out. Every state of the table in the plan appears here.
const TILE_CASES = [
  ['snapshot (nothing started)', { camera: camera(), extent, coverage: { kind: 'idle' }, started: false },
    { state: 'snapshot', video: false, snapshot: true, refresh: true, busy: false, caption: 'live', note: null }],
  ['snapshot (nothing recorded, nothing started)', { camera: camera({ nvrEnabled: false, status: { connection: 'online', nvr: { state: 'off' } } }), extent: null, coverage: { kind: 'idle' }, started: false },
    { state: 'snapshot', video: false, snapshot: true, caption: 'live', note: null }],
  ['cameraOff', { camera: camera({ isEnabled: false, status: { connection: 'disabled', nvr: { state: 'off' } } }), extent, coverage: { kind: 'idle' }, started: false },
    { state: 'cameraOff', snapshot: false, refresh: false, note: { title: TEXT.cameraOff, detail: null, tone: 'normal', action: null } }],
  ['cameraOffline', { camera: camera({ status: { connection: 'offline', connectionReason: 'No route to host', nvr: { state: 'waiting' } } }), extent, coverage: { kind: 'idle' }, started: false },
    { state: 'cameraOffline', snapshot: false, note: { title: TEXT.cameraOffline, detail: 'No route to host', tone: 'warning', action: null } }],
  ['cameraConnecting', { camera: camera({ status: { connection: 'connecting', nvr: { state: 'waiting' } } }), extent, coverage: { kind: 'idle' }, started: false },
    { state: 'cameraConnecting', snapshot: false, note: { title: TEXT.cameraConnecting, detail: null, tone: 'normal', action: null } }],
  ['loading (cell asked)', { camera: camera(), extent, coverage: { kind: 'loading' }, started: true },
    { state: 'loading', busy: true, video: false, snapshot: true, refresh: false, note: null }],
  ['loading (started, cell not asked yet)', { camera: camera(), extent, coverage: { kind: 'idle' }, started: true },
    { state: 'loading', busy: true, note: null }],
  ['recorded', { camera: camera(), extent, coverage: { kind: 'recorded' }, started: true },
    { state: 'recorded', video: true, snapshot: false, refresh: false, busy: false, caption: null, note: null }],
  ['live', { camera: camera(), extent, coverage: { kind: 'live' }, started: true },
    { state: 'live', video: true, snapshot: false, caption: null }],
  ['coarse', { camera: camera(), extent, coverage: { kind: 'coarse' }, started: true },
    { state: 'coarse', video: true, snapshot: false, caption: 'coarse' }],
  ['gap with a next recording', { camera: camera(), extent, coverage: { kind: 'gap', next: T0 + 30_000 }, started: true, position: T0 - 5_000, formatTime: hhmmss },
    { state: 'gap', refresh: false, note: { title: 'No recording at t-5000', detail: 'Next recording at t30000', tone: 'normal', action: null } }],
  ['gap with nothing after', { camera: camera(), extent, coverage: { kind: 'gap', next: null }, started: true, position: T0, formatTime: hhmmss },
    { state: 'gap', note: { title: 'No recording at t0', detail: null, tone: 'normal', action: null } }],
  ['gap while Record is off', { camera: camera({ nvrEnabled: false, status: { connection: 'online', nvr: { state: 'off' } } }), extent, coverage: { kind: 'gap', next: null }, started: true, position: T0 },
    { state: 'recordingOff', note: { title: TEXT.recordingOff, detail: null, tone: 'normal', action: null } }],
  ['recordingOff (started, no recordings)', { camera: camera({ nvrEnabled: false, status: { connection: 'online', nvr: { state: 'off' } } }), extent: null, coverage: { kind: 'idle' }, started: true },
    { state: 'recordingOff', video: false, note: { title: TEXT.recordingOff, detail: null, tone: 'normal', action: null } }],
  ['nothingRecorded (started, Record on, no recordings yet)', { camera: camera(), extent: null, coverage: { kind: 'idle' }, started: true },
    { state: 'nothingRecorded', note: { title: TEXT.nothingRecorded, detail: null, tone: 'normal', action: null } }],
  ['driveMissing', { camera: camera(), extent, coverage: { kind: 'driveMissing' }, started: true },
    { state: 'driveMissing', refresh: false, note: { title: TEXT.driveMissing, detail: null, tone: 'error', action: null } }],
  ['unreadable', { camera: camera(), extent, coverage: { kind: 'unreadable', message: 'The file is damaged.' }, started: true },
    { state: 'unreadable', note: { title: TEXT.unreadable, detail: 'The file is damaged.', tone: 'error', action: { id: 'retry', label: 'Try again' } } }],
  ['unreadable (the cell repeats the title)', { camera: camera(), extent, coverage: { kind: 'unreadable', message: TEXT.unreadable }, started: true },
    { state: 'unreadable', note: { title: TEXT.unreadable, detail: null, tone: 'error', action: { id: 'retry', label: 'Try again' } } }],
  ['unsupported (the cell names the codec)', { camera: camera(), extent, coverage: { kind: 'unsupported', message: 'This browser can’t play H.265 recordings. Safari, or Chrome on a Mac, can.' }, started: true },
    { state: 'unsupported', video: false, snapshot: true, refresh: true, note: { title: 'This browser can’t play H.265 recordings. Safari, or Chrome on a Mac, can.', detail: null, tone: 'warning', action: null } }],
  ['unsupported (no MediaSource at all)', { camera: camera(), extent, coverage: { kind: 'idle' }, started: true, playable: false },
    { state: 'unsupported', note: { title: TEXT.unsupported, detail: null, tone: 'warning', action: null } }],
];

for (const [name, input, expected] of TILE_CASES) {
  test(`tileState: ${name}`, () => {
    const tile = tileState(input);
    for (const [key, value] of Object.entries(expected)) assert.deepEqual(tile[key], value, `${name}: ${key}`);
  });
}

test('tileState covers every state name once or more, and the snapshot is only refreshed for an online camera', () => {
  const names = new Set(TILE_CASES.map(([, input]) => tileState(input).state));
  for (const state of ['snapshot', 'loading', 'recorded', 'live', 'coarse', 'gap', 'recordingOff', 'nothingRecorded', 'driveMissing', 'unreadable', 'unsupported',
    'cameraOff', 'cameraOffline', 'cameraConnecting']) {
    assert.ok(names.has(state), state);
  }
  const offline = tileState({ camera: camera({ status: { connection: 'offline', nvr: { state: 'waiting' } } }), extent, coverage: { kind: 'recorded' }, started: true });
  assert.equal(offline.state, 'recorded', 'recorded footage needs no connection');
  assert.equal(offline.snapshot, false);
  const offlineGap = tileState({ camera: camera({ status: { connection: 'offline', nvr: { state: 'waiting' } } }), extent, coverage: { kind: 'gap', next: null }, started: true, position: T0 });
  assert.equal(offlineGap.snapshot, false);
});

test('only a tile that expects no player picture fetches its snapshot again', () => {
  const refreshed = new Set(TILE_CASES.filter(([, input]) => tileState(input).refresh).map(([, input]) => tileState(input).state));
  assert.deepEqual([...refreshed].sort(), ['nothingRecorded', 'recordingOff', 'snapshot', 'unsupported']);
  for (const [name, input] of TILE_CASES) {
    const look = tileState(input);
    if (['loading', 'recorded', 'live', 'coarse', 'gap', 'driveMissing', 'unreadable'].includes(look.state)) assert.equal(look.refresh, false, name);
    if (!look.snapshot) assert.equal(look.refresh, false, `${name}: nothing to refresh when no snapshot is wanted`);
  }
});

test('tileSummary reads as one sentence list for a screen reader', () => {
  const tile = tileState({ camera: camera(), extent, coverage: { kind: 'gap', next: T0 + 30_000 }, started: true, position: T0, formatTime: hhmmss });
  assert.equal(tileSummary(camera(), tile), 'Front door. recording. No recording at t0. Next recording at t30000.');
  const plain = tileState({ camera: camera({ nvrEnabled: false, status: { connection: 'online', nvr: { state: 'off' } } }), extent, coverage: { kind: 'idle' }, started: false });
  assert.equal(tileSummary(camera({ nvrEnabled: false, status: { connection: 'online', nvr: { state: 'off' } } }), plain), 'Front door. not recording.');
});
