// The Monitor's playback controls for a precise review: pause means paused (a drag, a jump, an event, a step or a new speed never play), one
// picture forward or back, and the time-lapse that steps key pictures on a timer instead of playing (nvr/session.js, nvr/frames.js, the cells).
import { describe, it, test } from 'node:test';
import assert from 'node:assert/strict';
import { createSession } from '../web/js/nvr/session.js';
import { DEFAULT_FRAME_MS, frameDurationMs, frameStepTarget, readVideoTrack } from '../web/js/nvr/frames.js';
import { LAPSE_STEP_MS } from '../web/js/nvr/speed.js';
import { DEFAULT_POLICY } from '../web/js/nvr/planner.js';
import { createGridController } from '../web/js/screens/nvr-controller.js';
import { FILE_A, FILE_B, ORIGIN } from './player-fakes/fake-archive.mjs';
import { createRig } from './player-fakes/rig.mjs';
import { fakeTime } from './nvr-grid-helpers.mjs';

/** File A: 120 s (2 s parts, a key every 4th); a 20 s gap; file B: 40 s, a key in every part. */
const FILES = () => [
  { key: FILE_A, startMs: ORIGIN, parts: 60, gop: 4 },
  { key: FILE_B, startMs: ORIGIN + 140_000, parts: 20, gop: 1 },
];

async function make({ files = FILES(), ids = ['A'] } = {}) {
  const rig = createRig({ cameras: ids.map((id) => ({ id, files })) });
  await rig.start();
  const session = createSession({ catalog: rig.catalog, fetcher: rig.fetcher, clock: rig.clock, timers: rig.timers, tileCap: ids.length, policy: DEFAULT_POLICY, createCell: (cid) => rig.makeCell(cid) });
  session.setCameras(ids);
  return { rig, session, surface: () => rig.surface(ids[0]) };
}

const keyframes = (rig) => rig.paths('/keyframe?');
/** Fragment bytes (not inits, not the plans): what a played video fetches. */
const partBytes = (rig) => rig.requests().filter((entry) => /\/fragments\/[^/?]+$/.test(entry.path)).map((entry) => entry.path);
const playOps = (surface) => surface.log.filter((entry) => entry.op === 'play').length;

// MARK: Pause means paused

describe('held (the person paused)', () => {
  it('a drag and its release, a jump, an event, a new speed and a step all stay paused; only Play plays', async () => {
    const { rig, session, surface } = await make();
    session.play(ORIGIN + 10_000);
    await rig.timers.advance(2000);
    assert.equal(session.mode, 'playing');
    session.pause();
    assert.equal(session.holding, true);

    session.beginScrub();
    session.scrub(ORIGIN + 30_000);
    session.endScrub();
    await rig.timers.advance(1000);
    assert.equal(session.mode, 'paused', 'the release shows the picture there, paused');
    assert.equal(session.position, ORIGIN + 30_000);
    assert.equal(surface().playing, false);
    assert.ok(Math.abs(rig.base() + surface().presents().at(-1).sec * 1000 - (ORIGIN + 30_000)) <= 1, 'the exact picture at the new place');

    session.showAt(ORIGIN + 50_000);                     // an event of the list
    await rig.timers.advance(1000);
    assert.equal(session.mode, 'paused');
    assert.equal(session.position, ORIGIN + 50_000);

    session.seek(5000);
    await rig.timers.advance(1000);
    assert.equal(session.mode, 'paused');
    assert.equal(session.position, ORIGIN + 55_000);

    session.setRate(4);
    session.setRate(60);
    await rig.timers.advance(2000);
    assert.equal(session.mode, 'paused', 'a new speed waits for Play');
    assert.equal(session.position, ORIGIN + 55_000);

    session.stepFrame(1);
    await rig.timers.advance(500);
    assert.equal(session.mode, 'paused');
    assert.equal(surface().playing, false);
    const plays = playOps(surface());

    session.setRate(4);
    session.togglePlay();
    await rig.timers.advance(2500);
    assert.equal(session.mode, 'playing');
    assert.equal(session.holding, false);
    assert.ok(playOps(surface()) > plays, 'Play plays, at the speed chosen while paused');
    assert.equal(surface().rate, 4);
    session.destroy();
  });

  it('not held (the page opened at a time, paused by itself), a release plays as it always did', async () => {
    const { rig, session } = await make();
    session.scrub(ORIGIN + 20_000);            // what the controller does for #/nvr/<ms>
    assert.equal(session.holding, false);
    session.beginScrub();
    session.scrub(ORIGIN + 40_000);
    session.endScrub();
    await rig.timers.advance(2500);
    assert.equal(session.mode, 'playing');
    session.destroy();
  });

  it('going live always plays live, and ends the hold', async () => {
    const { rig, session } = await make();
    session.play(ORIGIN + 10_000);
    await rig.timers.advance(1000);
    session.pause();
    session.goLive();
    assert.equal(session.mode, 'live');
    assert.equal(session.holding, false);
    session.beginScrub();
    session.scrub(ORIGIN + 20_000);
    session.endScrub();
    await rig.timers.advance(2500);
    assert.equal(session.mode, 'playing', 'a drag back from live plays');
    session.destroy();
  });

  it('a release at the live edge goes live even while held', async () => {
    const { rig, session } = await make();
    session.play(ORIGIN + 10_000);
    await rig.timers.advance(1000);
    session.pause();
    session.beginScrub();
    session.scrub(rig.catalog.serverNow());
    session.endScrub();
    assert.equal(session.mode, 'live');
    session.destroy();
  });
});

describe('the grid controller', () => {
  const T0 = 1760099000000;
  const id = '00000000-0000-4000-8000-000000000001';
  function make() {
    const time = fakeTime(0);
    const session = {
      mode: 'paused', position: T0, rate: 1, holding: false, calls: [],
      setCameras() {}, cell() { return undefined; }, focus() {}, suspend() {}, resume() {}, destroy() {}, setRate() {},
      play(ms) { this.calls.push(['play', ms]); }, showAt(ms) { this.calls.push(['showAt', ms]); }, seek(ms) { this.calls.push(['seek', ms]); },
      stepFrame(direction) { this.calls.push(['stepFrame', direction]); },
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

  it('an event clicked while held shows its time paused; not held, it plays from there', async () => {
    const { session, controller, ready } = await make();
    await ready();
    session.holding = true;
    assert.equal(controller.view().transport.holding, true);
    assert.equal(controller.playAt(T0 - 60_000), true);
    assert.deepEqual(session.calls.at(-1), ['showAt', T0 - 60_000]);
    session.holding = false;
    controller.playAt(T0 - 30_000);
    assert.deepEqual(session.calls.at(-1), ['play', T0 - 30_000]);
    controller.destroy();
  });

  it('← and → step a picture while paused and seek a second while playing; Shift is a minute', async () => {
    const { session, controller, ready } = await make();
    await ready();
    controller.key({ action: 'nudge', direction: 1, deltaMs: 1000 });
    assert.deepEqual(session.calls.at(-1), ['stepFrame', 1]);
    controller.key({ action: 'nudge', direction: -1, deltaMs: -1000 });
    assert.deepEqual(session.calls.at(-1), ['stepFrame', -1]);
    session.mode = 'playing';
    controller.key({ action: 'nudge', direction: -1, deltaMs: -1000 });
    assert.deepEqual(session.calls.at(-1), ['seek', -1000]);
    controller.key({ action: 'seek', deltaMs: 60_000 });
    assert.deepEqual(session.calls.at(-1), ['seek', 60_000]);
    assert.equal(controller.view().transport.canStep, true);
    session.mode = 'live';
    assert.equal(controller.view().transport.canStep, false, 'live has no pictures to step');
    controller.destroy();
  });
});

// MARK: Frame by frame

/** An MP4 box: size, type, payload. */
function box(type, ...payload) {
  const body = payload.flatMap((part) => [...part]);
  const size = 8 + body.length;
  return new Uint8Array([size >>> 24, (size >>> 16) & 255, (size >>> 8) & 255, size & 255, ...[...type].map((c) => c.charCodeAt(0)), ...body]);
}
const u32 = (n) => new Uint8Array([n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);
const zeros = (n) => new Uint8Array(n);
const fullBox = (type, flags, ...payload) => box(type, u32(flags & 0xffffff), ...payload);

/** An init segment with a sound track (id 1) and a video track (id 2) at `timescale`; trex gives track 2 `trexDuration`. */
function initSegment({ timescale = 90_000, trexDuration = 0 } = {}) {
  const trak = (trackId, handler, scale) => box('trak',
    fullBox('tkhd', 0, zeros(8), u32(trackId), zeros(68)),
    box('mdia', fullBox('mdhd', 0, zeros(8), u32(scale), zeros(8)), fullBox('hdlr', 0, zeros(4), new TextEncoder().encode(handler), zeros(13))));
  return box('moov', zeros(0), trak(1, 'soun', 48_000), trak(2, 'vide', timescale),
    box('mvex', fullBox('trex', 0, u32(2), u32(1), u32(trexDuration), zeros(8))));
}

/** A fragment of track 2: per-sample durations, or a tfhd default. */
function fragment({ durations = null, tfhdDefault = null, count = 4 } = {}) {
  const tfhd = tfhdDefault === null ? fullBox('tfhd', 0x020000, u32(2)) : fullBox('tfhd', 0x020008, u32(2), u32(tfhdDefault));
  const trun = durations
    ? fullBox('trun', 0x000301, u32(durations.length), u32(0), ...durations.flatMap((d) => [u32(d), u32(100)]))
    : fullBox('trun', 0x000201, u32(count), u32(0), ...Array.from({ length: count }, () => u32(100)));
  return box('moof', fullBox('mfhd', 0, u32(1)), box('traf', tfhd, trun));
}

describe('a picture’s length', () => {
  it('comes from the samples of the video track, whichever box says it', () => {
    assert.deepEqual(readVideoTrack(initSegment()), { trackId: 2, timescale: 90_000, defaultDuration: 0 });
    assert.equal(frameDurationMs(initSegment(), fragment({ durations: [4500, 4500, 4500, 4500] })), 50, '20 pictures a second, per sample (the bridge)');
    assert.equal(frameDurationMs(initSegment(), fragment({ durations: [3000, 3003, 3003, 6000, 3003] })), 3003 / 90, 'the middle one: a late picture changes nothing');
    assert.equal(frameDurationMs(initSegment(), fragment({ tfhdDefault: 3600 })), 40, 'a tfhd default (ffmpeg)');
    assert.equal(frameDurationMs(initSegment({ trexDuration: 3000 }), fragment()), 3000 / 90, 'the init’s trex');
  });
  it('is unknown for bytes that are not an MP4, or say nothing plausible', () => {
    assert.equal(frameDurationMs(new TextEncoder().encode('{"kind":"media"}'), new Uint8Array(10)), null);
    assert.equal(frameDurationMs(null, null), null);
    assert.equal(frameDurationMs(initSegment(), fragment()), null, 'no duration anywhere');
    assert.equal(frameDurationMs(initSegment(), fragment({ durations: [9_000_000] })), null, 'a picture of 100 s');
  });
});

test('a step lands in the middle of the next or previous picture', () => {
  // The browser said the picture on screen starts at 1000 (a 40 ms picture): the next one is 1040 to 1080, the one before 960 to 1000.
  assert.equal(frameStepTarget({ positionMs: 1020, shownMs: 1000, frameMs: 40, direction: 1 }), 1060);
  assert.equal(frameStepTarget({ positionMs: 1020, shownMs: 1000, frameMs: 40, direction: -1 }), 980);
  // Without it the playhead is taken as the middle of the picture on screen.
  assert.equal(frameStepTarget({ positionMs: 1020, frameMs: 40, direction: 1 }), 1060);
  assert.equal(frameStepTarget({ positionMs: 1020, frameMs: 40, direction: -1 }), 980);
  // A shown picture far from the playhead is an old one; a frame length that is not a number is the default.
  assert.equal(frameStepTarget({ positionMs: 5000, shownMs: 1000, frameMs: 40, direction: 1 }), 5040);
  assert.equal(frameStepTarget({ positionMs: 5000, frameMs: Number.NaN, direction: 1 }), 5000 + DEFAULT_FRAME_MS);
  // Ten steps forward and ten back come home.
  let at = 1020;
  for (let i = 0; i < 10; i += 1) at = frameStepTarget({ positionMs: at, frameMs: 40, direction: 1 });
  assert.equal(at, 1420);
  for (let i = 0; i < 10; i += 1) at = frameStepTarget({ positionMs: at, frameMs: 40, direction: -1 });
  assert.equal(at, 1020);
});

describe('stepping', () => {
  it('pauses a playing page first, moves one picture at a time and never plays', async () => {
    const { rig, session, surface } = await make();
    session.play(ORIGIN + 10_000);
    await rig.timers.advance(2000);
    session.stepFrame(1);
    await rig.timers.advance(300);
    assert.equal(session.mode, 'paused');
    assert.equal(session.holding, true);
    const at = session.position;
    session.stepFrame(1);
    session.stepFrame(1);
    assert.equal(session.position, at + 2 * DEFAULT_FRAME_MS, 'the fake parts say no frame time: 20 a second');
    session.stepFrame(-1);
    await rig.timers.advance(500);
    assert.equal(session.position, at + DEFAULT_FRAME_MS);
    assert.equal(surface().playing, false);
    assert.ok(Math.abs(rig.base() + surface().presents().at(-1).sec * 1000 - session.position) <= 1, 'the picture at the new time is on screen');
    session.destroy();
  });

  it('back across the start of a part loads the part before', async () => {
    const { rig, session, surface } = await make();
    const start = ORIGIN + 140_000 + 4000;                          // the start of B's third part (a key in every part)
    session.showAt(start + 10);
    session.pause();
    await rig.timers.advance(1000);
    const before = rig.paths(`${FILE_B}.1`).length;
    session.stepFrame(-1);
    await rig.timers.advance(1000);
    assert.equal(session.position, start + 10 - DEFAULT_FRAME_MS);
    assert.ok(rig.paths(`${FILE_B}.1`).length > before, 'B.1 was fetched');
    assert.ok(Math.abs(rig.base() + surface().presents().at(-1).sec * 1000 - session.position) <= 1);
    assert.equal(session.mode, 'paused');
    session.destroy();
  });
});

// MARK: Time-lapse

describe('a time-lapse', () => {
  it('shows the key picture at the clock on a timer: no video plays and no part is fetched in full', async () => {
    const { rig, session, surface } = await make();
    session.setRate(30);
    session.play(ORIGIN + 2000);
    assert.equal(session.mode, 'playing');
    assert.equal(session.lapsing, true);
    const kinds = [];
    session.onChange((event) => { if (event.kind === 'coverage') kinds.push(event.coverage.kind); });
    await rig.timers.advance(3000);
    assert.equal(session.position, ORIGIN + 2000 + 3000 * 30, 'the clock runs at 30×');
    const asked = keyframes(rig).length;
    assert.ok(asked >= 3000 / LAPSE_STEP_MS - 1 && asked <= 3000 / LAPSE_STEP_MS + 2, `one key picture a step (${asked})`);
    assert.equal(partBytes(rig).length, 0, 'no part is fetched as video');
    assert.equal(playOps(surface()), 0, 'the video never plays');
    assert.ok(!kinds.slice(1).includes('loading'), 'the picture on screen stays while the next one comes');
    session.pause();
    const paused = keyframes(rig).length;
    await rig.timers.advance(3000);
    assert.equal(session.lapsing, false);
    assert.ok(keyframes(rig).length <= paused + 1, 'paused, it asks for nothing more');
    session.destroy();
  });

  it('jumps a gap to the next recording, and goes live after the last', async () => {
    const { rig, session } = await make();
    session.setRate(30);
    session.play(ORIGIN + 120_500);                              // in the gap after A, B at +140 s
    await rig.timers.advance(1200);
    assert.ok(keyframes(rig).some((path) => path.includes(`at=${ORIGIN + 140_000}`)), 'the next step was B’s start');
    assert.equal(session.cell('A').coverage.kind, 'recorded');
    session.setRate(300);
    for (let i = 0; i < 40 && session.mode !== 'live'; i += 1) await rig.timers.advance(500);
    assert.equal(session.mode, 'live', 'nothing after B: live');
    assert.equal(session.rate, 1);
    session.destroy();
  });

  it('from 4× into 60× steps key pictures, and back to 4× plays the video again', async () => {
    const { rig, session, surface } = await make();
    session.setRate(4);
    session.play(ORIGIN + 2000);
    await rig.timers.advance(2000);
    assert.equal(surface().playing, true);
    session.setRate(60);
    await rig.timers.advance(1500);
    assert.equal(session.lapsing, true);
    assert.equal(surface().playing, false, 'the video stands at the key picture');
    const plays = playOps(surface());
    session.setRate(4);
    await rig.timers.advance(2500);
    assert.equal(session.lapsing, false);
    assert.ok(playOps(surface()) > plays && surface().playing, 'played again');
    assert.equal(surface().rate, 4);
    session.destroy();
  });
});
