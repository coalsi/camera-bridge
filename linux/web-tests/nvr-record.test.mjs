import test from 'node:test';
import assert from 'node:assert/strict';
import { ABANDON_AFTER_MS, SLOW_AFTER_MS, SLOW_TEXT, createRecorder, recordingView, sentence } from '../web/js/nvr/record.js';

const CAMERA = '5C0B8A41-6C1B-4E43-9D52-0F1F3E7A6B10';
const OTHER = '9D3F7A11-3B52-4E0B-8F6A-2A9E5C1D4B77';

class ApiFailure extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}

/** A clock the test moves by hand, and the fakes the recorder talks to. */
function harness({ patch, read, ask } = {}) {
  let now = 0;
  const timers = new Set();
  const log = { patches: [], reads: [], asks: [], applied: [], notes: [] };
  const recorder = createRecorder({
    patchCamera: patch ? (id, body, signal) => { log.patches.push({ id, body }); return patch(id, body, signal, log.patches.length); }
      : async (id, body) => { log.patches.push({ id, body }); return { id, ...body }; },
    readCamera: async (id) => { log.reads.push(id); return read ? read(id) : { id, nvrEnabled: false }; },
    chooseStorage: async (options) => { log.asks.push(options); return ask ? ask(options) : true; },
    applyCamera: (camera) => log.applied.push(camera),
    notify: (message, kind) => log.notes.push({ message, kind }),
    setTimer: (fn, ms) => { const timer = { at: now + ms, fn }; timers.add(timer); return timer; },
    clearTimer: (timer) => timers.delete(timer),
  });
  const advance = (ms) => {
    now += ms;
    for (const timer of [...timers]) if (timer.at <= now && timers.delete(timer)) timer.fn();
  };
  return { recorder, log, advance, timers };
}

const tick = () => new Promise((resolve) => setImmediate(resolve));

test('turning Record on sends one PATCH, shows the new position at once, and hands the answer to the page', async () => {
  const { recorder, log } = harness();
  const seen = [];
  recorder.onPending(CAMERA, (pending) => seen.push(pending?.enabled?.value ?? null));
  const done = recorder.setRecording(CAMERA, true);
  assert.deepEqual(recorder.pending(CAMERA), { enabled: { value: true, slow: false }, recordSound: null }, 'pending before any answer');
  assert.equal(await done, true);
  assert.deepEqual(log.patches, [{ id: CAMERA, body: { enabled: true } }]);
  assert.deepEqual(log.applied, [{ id: CAMERA, enabled: true }]);
  assert.equal(recorder.pending(CAMERA), null);
  assert.deepEqual(seen, [true, null]);
});

test('first time: 409 folder_required asks where, then says it again', async () => {
  const { recorder, log } = harness({
    patch: async (id, body, signal, n) => { if (n === 1) throw new ApiFailure(409, 'folder_required', 'Choose where to store recordings first.'); return { id, nvrEnabled: true }; },
  });
  assert.equal(await recorder.setRecording(CAMERA, true), true);
  assert.equal(log.patches.length, 2);
  assert.deepEqual(log.asks, [{ reason: 'record' }]);
  assert.deepEqual(log.applied, [{ id: CAMERA, nvrEnabled: true }]);
});

test('first time, Cancel: nothing more is sent, nothing is applied, the switch is released', async () => {
  const { recorder, log } = harness({
    patch: async () => { throw new ApiFailure(409, 'folder_required', 'Choose where to store recordings first.'); },
    ask: () => false,
  });
  assert.equal(await recorder.setRecording(CAMERA, true), false);
  assert.equal(log.patches.length, 1, 'only the request the bridge refused');
  assert.equal(log.applied.length, 0);
  assert.deepEqual(log.notes, [], 'a cancel is not an error');
  assert.equal(recorder.pending(CAMERA), null);
});

test('folder_required while turning Record off, or for sound, is an ordinary error and asks nothing', async () => {
  const { recorder, log } = harness({ patch: async () => { throw new ApiFailure(409, 'folder_required', 'Choose where to store recordings first.'); } });
  assert.equal(await recorder.setRecording(CAMERA, false), false);
  assert.equal(await recorder.setRecordSound(CAMERA, true), false);
  assert.equal(log.asks.length, 0);
  assert.equal(log.notes.length, 2);
  assert.equal(log.notes[0].kind, 'error');
});

test('a refusal is shown with the bridge’s own sentence and leaves the page as it was', async () => {
  const { recorder, log } = harness({ patch: async () => { throw new ApiFailure(422, 'update_failed', 'The camera could not be updated.'); } });
  assert.equal(await recorder.setRecording(CAMERA, true), false);
  assert.deepEqual(log.notes, [{ message: 'The camera could not be updated.', kind: 'error' }]);
  assert.equal(log.applied.length, 0);
  assert.equal(recorder.pending(CAMERA), null);
});

test('a 401 says nothing: the page is already signing out', async () => {
  const { recorder, log } = harness({ patch: async () => { throw new ApiFailure(401, 'unauthorized', 'Sign in to continue.'); } });
  assert.equal(await recorder.setRecording(CAMERA, true), false);
  assert.deepEqual(log.notes, []);
});

test('requests for one camera run one after the other, in the order they were pressed', async () => {
  const gates = [];
  const { recorder, log } = harness({ patch: (id, body) => new Promise((resolve) => gates.push(() => resolve({ id, ...body }))) });
  const first = recorder.setRecording(CAMERA, true);
  const second = recorder.setRecording(CAMERA, false);
  await tick();
  assert.equal(log.patches.length, 1, 'the second waits for the first');
  assert.deepEqual(recorder.pending(CAMERA).enabled, { value: false, slow: false }, 'the switch shows the newest request');
  gates[0]();
  await tick();
  assert.equal(log.patches.length, 2);
  assert.deepEqual(recorder.pending(CAMERA).enabled, { value: false, slow: false }, 'still waiting for the second');
  gates[1]();
  assert.deepEqual(await Promise.all([first, second]), [true, true]);
  assert.deepEqual(log.patches.map((p) => p.body), [{ enabled: true }, { enabled: false }]);
  assert.equal(recorder.pending(CAMERA), null);
});

test('different cameras do not wait for each other', async () => {
  const gates = [];
  const { recorder, log } = harness({ patch: (id, body) => new Promise((resolve) => gates.push(() => resolve({ id, ...body }))) });
  const a = recorder.setRecording(CAMERA, true);
  const b = recorder.setRecording(OTHER, true);
  await tick();
  assert.equal(log.patches.length, 2);
  gates.forEach((open) => open());
  assert.deepEqual(await Promise.all([a, b]), [true, true]);
});

test('Record and Record sound for one camera share the queue and show their own pending state', async () => {
  const gates = [];
  const { recorder, log } = harness({ patch: (id, body) => new Promise((resolve) => gates.push(() => resolve({ id, ...body }))) });
  const record = recorder.setRecording(CAMERA, true);
  const sound = recorder.setRecordSound(CAMERA, true);
  assert.deepEqual(recorder.pending(CAMERA), { enabled: { value: true, slow: false }, recordSound: { value: true, slow: false } });
  await tick();
  assert.equal(log.patches.length, 1);
  gates[0]();
  await tick();
  assert.deepEqual(recorder.pending(CAMERA), { enabled: null, recordSound: { value: true, slow: false } });
  gates[1]();
  await Promise.all([record, sound]);
  assert.equal(recorder.pending(CAMERA), null);
});

test('after 3 seconds the bridge is called busy, once, and the pending state says slow; the clocks stop when it answers', async () => {
  let release;
  const { recorder, log, advance, timers } = harness({ patch: (id, body) => new Promise((resolve) => { release = () => resolve({ id, ...body }); }) });
  const done = recorder.setRecording(CAMERA, true);
  await tick();
  assert.equal(timers.size, 2);
  advance(SLOW_AFTER_MS - 1);
  assert.deepEqual(log.notes, []);
  advance(1);
  assert.deepEqual(log.notes, [{ message: SLOW_TEXT, kind: '' }]);
  assert.equal(recorder.pending(CAMERA).enabled.slow, true);
  assert.match(recordingView({ nvrEnabled: false }, recorder.pending(CAMERA)).line, /busy applying a camera change/);
  release();
  assert.equal(await done, true);
  assert.equal(timers.size, 0, 'both timers cleared');
  assert.equal(log.notes.length, 1);
});

test('after 30 seconds the request is given up: aborted, the camera re-read, and the person told it may still apply', async () => {
  let signalSeen;
  const { recorder, log, advance } = harness({
    patch: (id, body, signal) => new Promise((resolve, reject) => {
      signalSeen = signal;
      signal.addEventListener('abort', () => { const error = new Error('aborted'); error.name = 'AbortError'; reject(error); });
    }),
    read: (id) => ({ id, nvrEnabled: false, fresh: true }),
  });
  const done = recorder.setRecording(CAMERA, true);
  await tick();
  advance(SLOW_AFTER_MS);
  advance(ABANDON_AFTER_MS - SLOW_AFTER_MS);
  assert.equal(signalSeen.aborted, true);
  assert.equal(await done, false);
  assert.deepEqual(log.reads, [CAMERA]);
  assert.deepEqual(log.applied, [{ id: CAMERA, nvrEnabled: false, fresh: true }]);
  assert.equal(log.notes.length, 2);
  assert.match(log.notes[1].message, /Record may still turn on/);
  assert.equal(recorder.pending(CAMERA), null);
});

test('a listener can be removed, and a listener that throws does not stop the others', async () => {
  const { recorder } = harness();
  const a = [];
  const b = [];
  const stopA = recorder.onPending(CAMERA, (p) => a.push(p));
  recorder.onPending(CAMERA, () => { throw new Error('bad listener'); });
  recorder.onPending(CAMERA, (p) => b.push(p));
  const originalError = console.error;
  console.error = () => {};
  try {
    await recorder.setRecording(CAMERA, true);
    stopA();
    await recorder.setRecording(CAMERA, false);
  } finally {
    console.error = originalError;
  }
  assert.equal(a.length, 2, 'two changes before it was removed');
  assert.equal(b.length, 4);
});

test('recordingView: what the switch and chip say in every state', () => {
  const off = { nvrEnabled: false, status: { nvr: { state: 'off', detail: null, pause: null, notes: [] } } };
  assert.deepEqual(recordingView(off), { on: false, busy: false, slow: false, kind: 'off', chip: 'Record', line: 'Off', detail: null, help: 'Record is off' });
  const rec = { nvrEnabled: true, status: { nvr: { state: 'recording', detail: null, pause: null, notes: [] } } };
  assert.equal(recordingView(rec).chip, 'REC');
  assert.equal(recordingView(rec).kind, 'rec');
  assert.equal(recordingView(rec).on, true);
  const waiting = { nvrEnabled: true, status: { nvr: { state: 'waiting', detail: 'waiting for the camera', pause: null, notes: [] } } };
  assert.equal(recordingView(waiting).chip, 'Waiting');
  assert.equal(recordingView(waiting).detail, 'Waiting for the camera.');
  const paused = { nvrEnabled: true, status: { nvr: { state: 'paused', detail: 'There isn’t enough free space on the recordings drive.', pause: 'diskFull', notes: [] } } };
  assert.equal(recordingView(paused).chip, 'Paused');
  assert.equal(recordingView(paused).kind, 'paused');
  assert.equal(recordingView(paused).line, 'There isn’t enough free space on the recordings drive.');
  // Record on, but the bridge has not sent a status yet: waiting, not recording.
  assert.equal(recordingView({ nvrEnabled: true }).chip, 'Waiting');
  // Switched off while a stale status still says recording: the switch is the authority.
  assert.equal(recordingView({ nvrEnabled: false, status: { nvr: { state: 'recording', detail: null, notes: [] } } }).kind, 'off');
  // A request in flight shows the position being asked for.
  const turningOn = recordingView(off, { enabled: { value: true, slow: false }, recordSound: null });
  assert.deepEqual([turningOn.on, turningOn.busy, turningOn.chip], [true, true, 'Starting…']);
  const turningOff = recordingView(rec, { enabled: { value: false, slow: false }, recordSound: null });
  assert.deepEqual([turningOff.on, turningOff.busy, turningOff.chip], [false, true, 'Stopping…']);
});

test('sentence capitalises and ends with a full stop', () => {
  assert.equal(sentence('waiting for the camera'), 'Waiting for the camera.');
  assert.equal(sentence('Keyframe every 12 s: scrubbing is slow'), 'Keyframe every 12 s: scrubbing is slow.');
  assert.equal(sentence('The drive isn’t answering.'), 'The drive isn’t answering.');
  assert.equal(sentence(''), '');
  assert.equal(sentence(null), '');
});
