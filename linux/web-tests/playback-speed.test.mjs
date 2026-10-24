// Playback speeds on the Monitor: ¼× to 8× played, 30× to 300× stepped (nvr/speed.js, the clock's rate, the session, the grid controller, the keys, the cells and the sound).
import { describe, it, test } from 'node:test';
import assert from 'node:assert/strict';
import { LAPSE_SPEEDS, SPEEDS, SPEED_GROUPS, aheadFactor, isTimelapse, nearestSpeed, soundAllowed, speedDescription, speedGroup, speedLabel, stepSpeed } from '../web/js/nvr/speed.js';
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
  it('are slow motion, normal, fast and time-lapse, in that order', () => {
    assert.deepEqual(SPEED_GROUPS.map((group) => [group.label, [...group.speeds]]), [
      ['Slow', [0.25, 0.5]], ['Normal', [1]], ['Fast', [2, 4, 8]], ['Time-lapse', [30, 60, 120, 300]],
    ]);
    assert.deepEqual([...SPEEDS], [0.25, 0.5, 1, 2, 4, 8, 30, 60, 120, 300]);
    assert.deepEqual([...LAPSE_SPEEDS], [30, 60, 120, 300]);
    assert.deepEqual(SPEEDS.map(speedGroup), ['slow', 'slow', 'normal', 'fast', 'fast', 'fast', 'lapse', 'lapse', 'lapse', 'lapse']);
    assert.equal(speedLabel(0.25), '¼×');
    assert.equal(speedLabel(0.5), '½×');
    assert.equal(speedLabel(300), '300×');
  });
  it('are time-lapse from 30× on, and only those', () => {
    assert.deepEqual(SPEEDS.filter(isTimelapse), [30, 60, 120, 300]);
  });
  it('say what a time-lapse does with a minute and an hour', () => {
    assert.equal(speedDescription(30), 'Time-lapse: 1 min = 2 s, 1 hour = 2 min');
    assert.equal(speedDescription(60), 'Time-lapse: 1 min = 1 s, 1 hour = 1 min');
    assert.equal(speedDescription(120), 'Time-lapse: 2 min = 1 s, 1 hour = 30 s');
    assert.equal(speedDescription(300), 'Time-lapse: 5 min = 1 s, 1 hour = 12 s');
    assert.match(speedDescription(0.25), /Slow motion/);
    assert.match(speedDescription(1), /sound/);
  });
  it('step up and down across the groups and stop at the ends', () => {
    assert.equal(stepSpeed(1, 1), 2);
    assert.equal(stepSpeed(8, 1), 30);
    assert.equal(stepSpeed(300, 1), 300);
    assert.equal(stepSpeed(1, -1), 0.5);
    assert.equal(stepSpeed(0.25, -1), 0.25);
    assert.equal(stepSpeed(30, -1), 8);
  });
  it('turn a stray number into the nearest step by ratio, and anything else into 1', () => {
    assert.equal(nearestSpeed(5), 4);
    assert.equal(nearestSpeed(10), 8);
    assert.equal(nearestSpeed('60'), 60);
    assert.equal(nearestSpeed(999), 300);
    assert.equal(nearestSpeed(0.3), 0.25);
    assert.equal(nearestSpeed(0), 1);
    assert.equal(nearestSpeed(undefined), 1);
    assert.equal(nearestSpeed(Number.NaN), 1);
  });
  it('allow sound at 1× only: slow motion and every faster speed are silent', () => {
    assert.deepEqual(SPEEDS.map(soundAllowed), [false, false, true, false, false, false, false, false, false, false]);
  });
  it('fetch further ahead as the speed goes up, never less than at 1×', () => {
    assert.equal(aheadFactor(1), 1);
    assert.equal(aheadFactor(0.25), 1);
    assert.ok(aheadFactor(8) > aheadFactor(4) && aheadFactor(4) > aheadFactor(2));
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
    controller.setSpeed(4);
    assert.deepEqual(session.calls.at(-1), ['setRate', 4]);
    assert.equal(controller.view().transport.rate, 4);
    assert.equal(controller.view().transport.lapse, false);
    controller.key({ action: 'speed', step: 1 });
    assert.equal(session.rate, 8);
    controller.key({ action: 'speed', step: 1 });
    assert.equal(session.rate, 30, 'fast steps on into time-lapse');
    assert.equal(controller.view().transport.lapse, true);
    controller.setSpeed(300);
    controller.key({ action: 'speed', step: 1 });
    assert.equal(session.rate, 300, 'the top step stays');
    controller.key({ action: 'speed', step: -1 });
    assert.equal(session.rate, 120);
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
    session.setRate(5);
    assert.equal(session.rate, 4, 'a stray number becomes the nearest step');
    session.setRate(10);
    assert.equal(rig.clock.rate, 8);
    session.goLive();
    assert.equal(session.rate, 1);
    assert.deepEqual(seen, [4, 8, 1]);
    session.destroy();
  });

  it('plays a tile at 8× in step with the clock, and keeps fetching ahead of it', async () => {
    const rig = createRig({ cameras: [{ id: 'A', files: [{ key: FILE_A, startMs: ORIGIN, parts: 90, gop: 1 }] }] });
    await rig.start();
    const session = createSession({ catalog: rig.catalog, fetcher: rig.fetcher, clock: rig.clock, timers: rig.timers, tileCap: 1, policy: DEFAULT_POLICY, createCell: (cid) => rig.makeCell(cid) });
    session.setCameras(['A']);
    session.setRate(8);
    session.play(ORIGIN + 1000);
    await rig.timers.advance(1500);
    assert.equal(rig.surface('A').rate, 8, 'the video plays at the clock’s speed');
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
