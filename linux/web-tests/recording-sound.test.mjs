// The recordings' sound (nvr/sound.js): a speaker moved to another tile while the sound's MediaSource opens must not wedge it. The old source
// never opens (its <audio> was given up); after SOURCE_OPEN_TIMEOUT_MS the next tick makes a new one, and the sound plays for the new camera.
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { SOURCE_OPEN_TIMEOUT_MS, createRecordingSound } from '../web/js/nvr/sound.js';

test('a source that never opens is given up after 3 s, and the next camera’s sound starts', async () => {
  const made = [];
  class FakeSource {
    constructor() { this.listeners = new Map(); this.readyState = 'closed'; this.buffers = []; made.push(this); }
    addEventListener(type, fn) { this.listeners.set(type, fn); }
    open() { this.readyState = 'open'; this.listeners.get('sourceopen')?.(); }
    addSourceBuffer(mime) { const buffer = { mime, updating: false, addEventListener() {} }; this.buffers.push(buffer); return buffer; }
    endOfStream() { this.readyState = 'ended'; }
  }
  const savedSource = globalThis.MediaSource;
  const savedCreate = URL.createObjectURL;
  const savedRevoke = URL.revokeObjectURL;
  globalThis.MediaSource = FakeSource;
  URL.createObjectURL = () => 'blob:sound';
  URL.revokeObjectURL = () => {};
  mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  const audio = { hidden: false, paused: true, buffered: { length: 0 }, pause() {}, load() {}, removeAttribute() {}, remove() {}, play: async () => {} };
  const doc = { createElement: () => audio, body: { append() {} } };
  const clock = { mode: 'playing', rate: 1, position: () => 1_760_000_000_000 };
  const catalog = {
    baseMs: 1_760_000_000_000 - 400 * 86_400_000,
    plan: async () => ({ found: false }), after: async () => ({ found: false }), file: () => null,
  };
  const flush = async () => { for (let i = 0; i < 10; i += 1) await Promise.resolve(); };
  const sound = createRecordingSound({ catalog, fetcher: { bytes: async () => ({ data: new ArrayBuffer(0) }) }, clock, doc });
  try {
    sound.setCamera('A');
    await flush();
    assert.equal(made.length, 1, 'a source for camera A');
    sound.setCamera('B');            // moved while it opens: A's source is let go and will never open
    await flush();
    mock.timers.tick(400 * 5);
    await flush();
    assert.equal(made.length, 1, 'still waiting on the first');
    mock.timers.tick(SOURCE_OPEN_TIMEOUT_MS);
    await flush();
    mock.timers.tick(400);
    await flush();
    assert.equal(made.length, 2, 'a new source after the deadline: not wedged');
    made[1].open();
    await flush();
    assert.equal(made[1].buffers.length, 1, 'and it is used');
    assert.equal(made[0].buffers.length, 0);
  } finally {
    sound.destroy();
    mock.timers.reset();
    globalThis.MediaSource = savedSource;
    URL.createObjectURL = savedCreate;
    URL.revokeObjectURL = savedRevoke;
  }
});
