// Playback speeds on the Monitor: 1x, 2x, 3x, 5x, 10x (nvr/speed.js, the clock's rate, the session, the grid controller, the keys, the cells and the sound).
import { describe, it, test } from 'node:test';
import assert from 'node:assert/strict';
import { MUTE_ABOVE, SPEEDS, aheadFactor, nearestSpeed, soundAllowed, speedLabel, stepSpeed } from '../web/js/nvr/speed.js';
import { PlaybackClock } from '../web/js/nvr/clock.js';
import { keyAction } from '../web/js/screens/nvr-model.js';
import { createSession } from '../web/js/nvr/session.js';
import { createGridController } from '../web/js/screens/nvr-controller.js';
import { DEFAULT_POLICY } from '../web/js/nvr/planner.js';
import { createFakeTimers } from './player-fakes/fake-timers.mjs';
import { FILE_A, ORIGIN } from './player-fakes/fake-archive.mjs';
import { createRig } from './player-fakes/rig.mjs';
import { fakeTime, settle } from './nvr-grid-helpers.mjs';

describe('the steps', () => {
  it('are 1, 2, 3, 5 and 10', () => {
    assert.deepEqual(SPEEDS, [1, 2, 3, 5, 10]);
    assert.equal(speedLabel(10), '10×');
    assert.equal(speedLabel(1), '1×');
  });
  it('step up and down and stop at the ends', () => {
    assert.equal(stepSpeed(1, 1), 2);
    assert.equal(stepSpeed(3, 1), 5);
    assert.equal(stepSpeed(5, 1), 10);
    assert.equal(stepSpeed(10, 1), 10);
    assert.equal(stepSpeed(5, -1), 3);
    assert.equal(stepSpeed(1, -1), 1);
  });
  it('turn a stray number into the nearest step, and anything else into 1', () => {
    assert.equal(nearestSpeed(4), 3);
    assert.equal(nearestSpeed('5'), 5);
    assert.equal(nearestSpeed(99), 10);
    assert.equal(nearestSpeed(0), 1);
    assert.equal(nearestSpeed(undefined), 1);
    assert.equal(nearestSpeed(Number.NaN), 1);
  });
  it('allow sound up to 2×, not above', () => {
    assert.equal(MUTE_ABOVE, 2);
    assert.deepEqual(SPEEDS.map(soundAllowed), [true, true, false, false, false]);
  });
  it('fetch further ahead as the speed goes up, never less than at 1×', () => {
    assert.equal(aheadFactor(1), 1);
    assert.ok(aheadFactor(10) > aheadFactor(5) && aheadFactor(5) > aheadFactor(2));
    assert.equal(aheadFactor(undefined), 1);
  });
});

describe('the clock at a speed', () => {
  const setup = () => {
    const timers = createFakeTimers();
    const clock = new PlaybackClock({ serverNow: () => 1_760_000_000_000 + timers.now(), perf: timers.now });
    return { timers, clock };
  };

  it('runs 10 times as fast at 10×', async () => {
    const { clock, timers } = setup();
    clock.setRate(10);
    clock.play(1_759_000_000_000);
    await timers.advance(2000);
    assert.equal(clock.position(), 1_759_000_020_000);
  });

  it('keeps the position when the speed changes while playing', async () => {
    const { clock, timers } = setup();
    clock.play(1_759_000_000_000);
    await timers.advance(2000);
    clock.setRate(5);
    assert.equal(clock.position(), 1_759_000_002_000, 'no jump');
    await timers.advance(2000);
    assert.equal(clock.position(), 1_759_000_012_000);
    clock.setRate(1);
    await timers.advance(1000);
    assert.equal(clock.position(), 1_759_000_013_000);
  });

  it('keeps its speed through a pause and a new play, and goes back to 1× when it goes live', async () => {
    const { clock, timers } = setup();
    clock.setRate(3);
    clock.play(1_759_000_000_000);
    await timers.advance(1000);
    clock.pause();
    assert.equal(clock.rate, 3);
    clock.play(clock.position());
    await timers.advance(1000);
    assert.equal(clock.position(), 1_759_000_006_000);
    const seen = [];
    clock.onRate((rate) => seen.push(rate));
    clock.goLive();
    assert.equal(clock.rate, 1);
    assert.deepEqual(seen, [1]);
  });

  it('holds still for the start delay at any speed, and says when the speed changes', async () => {
    const { clock, timers } = setup();
    const seen = [];
    clock.onRate((rate) => seen.push(rate));
    clock.play(1_759_000_000_000, { startingInMs: 500 });
    clock.setRate(10);
    await timers.advance(400);
    assert.equal(clock.position(), 1_759_000_000_000);
    await timers.advance(600);
    assert.equal(clock.position(), 1_759_000_005_000, '0.5 s of running at 10×');
    clock.setRate(10);
    assert.deepEqual(seen, [10], 'the same speed again says nothing');
  });
});

test('the keys , and . step the speed down and up', () => {
  assert.deepEqual(keyAction({ key: '.' }), { action: 'speed', step: 1 });
  assert.deepEqual(keyAction({ key: ',' }), { action: 'speed', step: -1 });
  assert.equal(keyAction({ key: '.' }, { typing: true }), null);
  assert.equal(keyAction({ key: '.', ctrlKey: true }), null);
  assert.equal(keyAction({ key: '.', metaKey: true }), null);
});

describe('the grid controller', () => {
  const T0 = 1760099000000;
  const id = '00000000-0000-4000-8000-000000000001';
  function make() {
    const time = fakeTime(0);
    const session = {
      mode: 'paused', position: T0, rate: 1, calls: [], onRequest: () => {},
      setCameras() {}, cell() { return undefined; }, focus() {}, suspend() {}, resume() {}, destroy() {},
      setRate(r) { this.calls.push(['setRate', r]); this.rate = r; },
    };
    const listeners = new Set();
    const catalog = {
      baseMs: Number.NaN, extent: () => null, onChange: (fn) => { listeners.add(fn); return () => listeners.delete(fn); },
      answer() { this.baseMs = T0 - 400 * 86_400_000; for (const fn of [...listeners]) fn({ kind: 'extents' }); },
    };
    const controller = createGridController({
      session, catalog, listCameras: () => [{ id, name: 'Front', isEnabled: true, nvrEnabled: true, status: { connection: 'online', nvr: { state: 'recording', notes: [] } } }],
      subscribeCameras: () => () => {}, perPage: 4, initialMs: null, initialPage: 0, initialFocus: null, playable: true, catalogTimeoutMs: 1000,
      navigate() {}, replaceHash() {}, remember() {}, formatTime: String, now: time.now,
      setWaveformCameras() {}, setSnapshotIds() {}, pokeSnapshots() {},
      setTimer: time.setTimer, clearTimer: time.clearTimer, setTick: () => ({}), clearTick() {},
    });
    const ready = async () => { const started = controller.start(); catalog.answer(); await started; controller.noteRequest(); };
    return { session, controller, ready };
  }

  it('shows the speed in its transport and changes it by a step or by a key', async () => {
    const { session, controller, ready } = make();
    await ready();
    assert.equal(controller.view().transport.rate, 1);
    session.mode = 'playing';
    controller.setSpeed(5);
    assert.deepEqual(session.calls.at(-1), ['setRate', 5]);
    assert.equal(controller.view().transport.rate, 5);
    controller.key({ action: 'speed', step: 1 });
    assert.equal(session.rate, 10);
    controller.key({ action: 'speed', step: 1 });
    assert.equal(session.rate, 10, 'the top step stays');
    controller.key({ action: 'speed', step: -1 });
    assert.equal(session.rate, 5);
    controller.destroy();
  });

  it('offers speeds only while a recording plays or stands, not live', async () => {
    const { session, controller, ready } = make();
    await ready();
    session.mode = 'live';
    assert.equal(controller.view().transport.canSpeed, false);
    session.mode = 'paused';
    assert.equal(controller.view().transport.canSpeed, true);
    controller.destroy();
  });
});

describe('the session', () => {
  it('passes the speed to the clock and tells its listeners; live brings 1× back', async () => {
    const rig = createRig({ cameras: [{ id: 'A', files: [{ key: FILE_A, startMs: ORIGIN, parts: 60, gop: 2 }] }] });
    await rig.start();
    const session = createSession({ catalog: rig.catalog, fetcher: rig.fetcher, clock: rig.clock, timers: rig.timers, tileCap: 1, policy: DEFAULT_POLICY, createCell: (cid) => rig.makeCell(cid) });
    session.setCameras(['A']);
    const seen = [];
    session.onChange((event) => { if (event.kind === 'rate') seen.push(event.rate); });
    session.play(ORIGIN + 10_000);
    session.setRate(4);
    assert.equal(session.rate, 3, 'a stray number becomes the nearest step');
    session.setRate(10);
    assert.equal(rig.clock.rate, 10);
    session.goLive();
    assert.equal(session.rate, 1);
    assert.deepEqual(seen, [3, 10, 1]);
    session.destroy();
  });

  it('plays a tile at 10× in step with the clock, and keeps fetching ahead of it', async () => {
    const rig = createRig({ cameras: [{ id: 'A', files: [{ key: FILE_A, startMs: ORIGIN, parts: 90, gop: 1 }] }] });
    await rig.start();
    const session = createSession({ catalog: rig.catalog, fetcher: rig.fetcher, clock: rig.clock, timers: rig.timers, tileCap: 1, policy: DEFAULT_POLICY, createCell: (cid) => rig.makeCell(cid) });
    session.setCameras(['A']);
    session.setRate(10);
    session.play(ORIGIN + 1000);
    await rig.timers.advance(1500);
    assert.equal(rig.surface('A').rate, 10, 'the video plays at the clock’s speed');
    for (let i = 0; i < 12; i += 1) {
      await rig.timers.advance(500);
      const lag = rig.clock.position() - (rig.base() + rig.surface('A').currentTime() * 1000);
      assert.ok(Math.abs(lag) < 1500, `the picture stays with the clock (${lag} ms off at step ${i})`);
    }
    assert.equal(session.cell('A').coverage.kind, 'recorded');
    session.setRate(1);
    await rig.timers.advance(600);
    assert.equal(rig.surface('A').rate, 1);
    session.destroy();
  });
});
