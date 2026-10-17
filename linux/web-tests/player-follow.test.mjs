// cell.js and session.js while the wall plays, on decoders that behave as measured on the owner's Mac (Chrome, 8 cameras, 2026-10-17):
// a tile that stopped at a hole plays again when the shared clock gets to its next recording, a hole under a second never stops a tile, and a
// buffer that ends a little before the index says (a file with sound) is not planned and fetched again and again.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_POLICY, MESSAGES } from '../web/js/nvr/planner.js';
import { createSession } from '../web/js/nvr/session.js';
import { FILE_A, FILE_B, ORIGIN } from './player-fakes/fake-archive.mjs';
import { createRig, desirer } from './player-fakes/rig.mjs';

const HOLD_BACK = { stallBeforeEndMs: 590 };           // Patio's picture stood 590 ms before the end of what its video held
const OTHER = 'c0ffee000001';                          // the continuously recording camera's one file
const MIME_2 = 'video/mp4; codecs="avc1.640033"';

/** A rig and a real session over `cameras` ({ id, files }), the first camera the main tile. */
async function wall(cameras, { surfaceOptions = HOLD_BACK, latency } = {}) {
  const rig = createRig({ cameras, surfaceOptions, latency });
  await rig.start();
  const session = createSession({
    catalog: rig.catalog, fetcher: rig.fetcher, clock: rig.clock, timers: rig.timers, tileCap: cameras.length, policy: DEFAULT_POLICY,
    createCell: (id) => rig.makeCell(id),
  });
  session.setCameras(cameras.map((camera) => camera.id));
  return { rig, session };
}

/** Every coverage a cell reports, with where the clock stood when it did. */
function record(rig, cell) {
  const seen = [];
  cell.onChange((coverage) => seen.push({ ...coverage, clockMs: rig.clock.position() }));
  return seen;
}

/** Lets `ms` pass in small steps and measures the longest time the tile's picture stood still while the clock played. */
async function watch(rig, id, ms, stepMs = 50) {
  let still = 0;
  let longest = 0;
  let last = null;
  for (let passed = 0; passed < ms; passed += stepMs) {
    await rig.timers.advance(stepMs);
    const video = rig.surface(id)?.currentTime() ?? null;
    if (rig.clock.mode === 'playing' && video !== null && video === last) { still += stepMs; longest = Math.max(longest, still); } else still = 0;
    last = video;
  }
  return longest;
}

/** How far the tile's picture is behind the clock, in ms. */
const lag = (rig, id) => rig.clock.position() - (rig.base() + rig.surface(id).currentTime() * 1000);

describe('a tile that stopped at a hole of a second or more', () => {
  const NEXT = ORIGIN + 64_588;                          // Patio: 4.6 s without a recording after ORIGIN + 60 s, then a new file
  const patio = { id: 'PATIO', files: [{ key: FILE_A, startMs: ORIGIN, parts: 30, gop: 1 }, { key: FILE_B, startMs: NEXT, parts: 30, gop: 1 }] };
  const backyard = { id: 'BACKYARD', files: [{ key: OTHER, startMs: ORIGIN, parts: 90, gop: 1 }] };

  it('plays again by itself when the wall\'s clock gets to its next recording, and the other tiles play on meanwhile', async () => {
    const { rig, session } = await wall([backyard, patio]);
    session.play(ORIGIN + 50_000);
    await rig.timers.advance(12_000);                                  // the clock is well inside Patio's hole
    const cell = session.cell('PATIO');
    assert.equal(rig.clock.mode, 'playing');
    assert.deepEqual([cell.coverage.kind, cell.coverage.next], ['gap', NEXT], 'it says when its next recording starts');
    assert.deepEqual([session.cell('BACKYARD').coverage.kind, session.cell('BACKYARD').coverage.playing], ['recorded', true]);
    await rig.timers.advance(4000);                                    // the clock is 1.4 s past Patio's next recording
    assert.equal(rig.clock.mode, 'playing');
    assert.deepEqual([cell.coverage.kind, cell.coverage.playing], ['recorded', true]);
    assert.equal(rig.surface('PATIO').playing, true);
    assert.ok(Math.abs(lag(rig, 'PATIO')) < 500, `Patio plays with the clock (${lag(rig, 'PATIO')} ms behind)`);
    assert.ok(rig.surface('PATIO').seeks().every((seek) => seek.presented));
  });

  it('the main tile at a hole leaves the clock to the others and joins it at its next recording', async () => {
    const { rig, session } = await wall([patio, backyard]);
    session.play(ORIGIN + 58_000);
    await rig.timers.advance(5000);
    assert.equal(session.cell('PATIO').coverage.kind, 'gap');
    assert.equal(rig.clock.mode, 'playing', 'the clock plays on: the other tile has video');
    await rig.timers.advance(4000);
    assert.deepEqual([session.cell('PATIO').coverage.kind, session.cell('PATIO').coverage.playing], ['recorded', true]);
    assert.deepEqual([session.cell('BACKYARD').coverage.kind, session.cell('BACKYARD').coverage.playing], ['recorded', true]);
  });

  it('a play that starts inside the main tile\'s hole starts the clock with the other tiles, and the main tile joins at its next recording', async () => {
    const { rig, session } = await wall([patio, backyard]);
    session.play(ORIGIN + 62_000);                                    // the Events list: play the wall from a time Patio has no recording for
    await rig.timers.advance(1000);
    assert.deepEqual([session.cell('PATIO').coverage.kind, session.cell('PATIO').coverage.next], ['gap', NEXT]);
    assert.deepEqual([rig.clock.mode, session.mode], ['playing', 'playing'], 'the clock plays: Backyard has video');
    assert.deepEqual([session.cell('BACKYARD').coverage.kind, session.cell('BACKYARD').coverage.playing], ['recorded', true]);
    const backyardSeeks = rig.surface('BACKYARD').seeks().length;
    await rig.timers.advance(4000);
    assert.equal(rig.surface('BACKYARD').seeks().length, backyardSeeks, 'Backyard plays on without being sent back');
    assert.deepEqual([session.cell('PATIO').coverage.kind, session.cell('PATIO').coverage.playing], ['recorded', true]);
    assert.ok(Math.abs(lag(rig, 'PATIO')) < 500, `Patio plays with the clock (${lag(rig, 'PATIO')} ms behind)`);
  });

  it('a play that starts where no tile has a recording stays paused there, as before', async () => {
    const quiet = { id: 'BACKYARD', files: [{ key: OTHER, startMs: ORIGIN, parts: 30, gop: 1 }, { key: 'c0ffee000002', startMs: ORIGIN + 70_000, parts: 10, gop: 1 }] };
    const { rig, session } = await wall([patio, quiet]);
    session.play(ORIGIN + 62_000);
    await rig.timers.advance(3000);
    assert.deepEqual([rig.clock.mode, rig.clock.position()], ['paused', ORIGIN + 62_000]);
    assert.equal(session.cell('PATIO').coverage.kind, 'gap');
    assert.equal(session.cell('BACKYARD').coverage.kind, 'gap');
  });

  it('plays at the clock at once when the clock has passed the next recording by the time the tile hears of it, and never names a time behind the clock', async () => {
    const short = { id: 'PATIO', files: [{ key: FILE_A, startMs: ORIGIN, parts: 30, gop: 1 }, { key: FILE_B, startMs: ORIGIN + 61_500, parts: 30, gop: 1 }] };
    const slowPlans = (kind, path) => (path.includes('fragments?at=') ? 1500 : kind === 'bytes' ? 25 : 10);
    const { rig, session } = await wall([backyard, short], { latency: slowPlans });
    const seen = record(rig, session.cell('PATIO'));
    session.play(ORIGIN + 60_100);                                    // inside Patio's 1.5 s hole; its plan answers 1.5 s later
    await rig.timers.advance(8000);
    const gaps = seen.filter((coverage) => coverage.kind === 'gap');
    assert.ok(gaps.every((coverage) => coverage.next === null || coverage.next > coverage.clockMs), `a gap named a next recording behind the clock: ${JSON.stringify(gaps)}`);
    assert.deepEqual([session.cell('PATIO').coverage.kind, session.cell('PATIO').coverage.playing], ['recorded', true]);
    assert.ok(Math.abs(lag(rig, 'PATIO')) < 500, `Patio plays with the clock (${lag(rig, 'PATIO')} ms behind)`);
  });

  it('a camera with nothing recorded after the playhead plays once it records again and the clock gets there', async () => {
    const eufy = { id: 'EUFY', files: [{ key: FILE_A, startMs: ORIGIN, parts: 5, gop: 1 }] };
    const { rig, session } = await wall([backyard, eufy]);
    session.play(ORIGIN + 20_000);
    await rig.timers.advance(2000);
    assert.deepEqual([session.cell('EUFY').coverage.kind, session.cell('EUFY').coverage.next], ['gap', null]);
    rig.archives[1].addFile({ key: FILE_B, startMs: ORIGIN + 30_000, parts: 10, gop: 1 });      // the battery camera woke up: a new file
    await rig.timers.advance(6000);
    assert.equal(session.cell('EUFY').coverage.kind, 'gap', 'not before the clock gets there');
    await rig.timers.advance(4000);
    assert.deepEqual([session.cell('EUFY').coverage.kind, session.cell('EUFY').coverage.playing], ['recorded', true]);
  });

  it('pausing, scrubbing and going live while a tile waits for its next recording are what they always were', async () => {
    const { rig, session } = await wall([backyard, patio]);
    session.play(ORIGIN + 58_000);
    await rig.timers.advance(4000);
    assert.equal(session.cell('PATIO').coverage.kind, 'gap');
    session.pause();
    await rig.timers.advance(1000);
    const asked = rig.paths('PATIO').length;
    await rig.timers.advance(20_000);
    assert.equal(rig.paths('PATIO').length, asked, 'paused: the waiting tile asks for nothing');
    assert.equal(rig.surface('PATIO').playing, false);
    session.beginScrub();
    session.scrub(ORIGIN + 30_000);
    session.scrub(ORIGIN + 70_000);
    await rig.timers.advance(1000);
    assert.deepEqual([session.cell('PATIO').coverage.kind, session.cell('PATIO').coverage.playing], ['recorded', false]);
    session.goLive();
    await rig.timers.advance(5000);
    assert.equal(rig.clock.mode, 'live');
    assert.equal(rig.surface('PATIO').playing, false);
  });
});

describe('a hole under a second', () => {
  const twoFiles = (holeMs, mime) => [
    { key: FILE_A, startMs: ORIGIN, parts: 10, gop: 1 },
    { key: FILE_B, startMs: ORIGIN + 20_000 + holeMs, parts: 20, gop: 1, ...(mime ? { mime } : {}) },
  ];

  it('between two files never stops the tile, even when the decoder stops before the end of what it holds', async () => {
    const { rig, session } = await wall([{ id: 'WYZE', files: twoFiles(100) }]);
    const seen = record(rig, session.cell('WYZE'));
    session.play(ORIGIN + 14_000);
    const longest = await watch(rig, 'WYZE', 15_000);
    assert.ok(longest < 600, `the picture stood still for ${longest} ms`);
    assert.equal(seen.some((coverage) => coverage.kind === 'gap'), false, 'no gap was reported');
    assert.equal(rig.paths('fragments?at=').length, 1, 'planned once: the hole is stepped over with what is held');
    assert.ok(Math.abs(lag(rig, 'WYZE')) < 500, `it plays with the clock (${lag(rig, 'WYZE')} ms behind)`);
  });

  it('before a file in another codec (sound in one file, none in the next) the tile goes on in the new codec', async () => {
    const { rig, session } = await wall([{ id: 'WYZE', files: twoFiles(100, MIME_2) }]);
    const seen = record(rig, session.cell('WYZE'));
    session.play(ORIGIN + 14_000);
    const longest = await watch(rig, 'WYZE', 15_000);
    assert.ok(longest < 1000, `the picture stood still for ${longest} ms`);
    assert.equal(seen.some((coverage) => coverage.kind === 'gap'), false, 'no gap was reported');
    assert.equal(rig.surface('WYZE').mime, MIME_2);
    assert.deepEqual([session.cell('WYZE').coverage.kind, session.cell('WYZE').coverage.playing], ['recorded', true]);
    assert.ok(Math.abs(lag(rig, 'WYZE')) < 500, `it plays with the clock (${lag(rig, 'WYZE')} ms behind)`);
  });
});

describe('a stop at the end of what is held that the end can do nothing about', () => {
  it('half a second of recording after a short hole, then a long hole: the tile is not stuck, it plays the file after', async () => {
    const files = [
      { key: FILE_A, startMs: ORIGIN, parts: 10, gop: 1 },
      { key: FILE_B, startMs: ORIGIN + 20_200, parts: 1, partMs: 500, gop: 1 },             // too short for a decoder to show a picture from
      { key: 'c3d4e5f6a1b2', startMs: ORIGIN + 26_000, parts: 10, gop: 1 },
    ];
    const backyard = { id: 'BACKYARD', files: [{ key: OTHER, startMs: ORIGIN, parts: 90, gop: 1 }] };
    const { rig, session } = await wall([backyard, { id: 'WYZE', files }]);
    session.play(ORIGIN + 16_000);
    await rig.timers.advance(8000);
    assert.deepEqual([session.cell('WYZE').coverage.kind, session.cell('WYZE').coverage.next], ['gap', ORIGIN + 26_000]);
    await rig.timers.advance(4000);
    assert.equal(rig.clock.mode, 'playing');
    assert.deepEqual([session.cell('WYZE').coverage.kind, session.cell('WYZE').coverage.playing], ['recorded', true]);
    assert.ok(Math.abs(lag(rig, 'WYZE')) < 500, `it plays with the clock (${lag(rig, 'WYZE')} ms behind)`);
  });
});

describe('a file with sound', () => {
  it('a buffer that ends a frame before its parts do is not planned and fetched again and again (Doorbell)', async () => {
    const files = [{ key: FILE_A, startMs: ORIGIN, parts: 60, gop: 1 }];
    const { rig, session } = await wall([{ id: 'DOORBELL', files }], { surfaceOptions: { audioShortMs: 64 } });
    session.play(ORIGIN + 10_500);
    const longest = await watch(rig, 'DOORBELL', 20_000);
    const plans = rig.paths('fragments?at=');
    const parts = rig.paths('/fragments/').filter((path) => !path.endsWith('/init'));
    assert.equal(plans.length, 1, `planned ${plans.length} times in 20 s`);
    assert.equal(new Set(parts).size, parts.length, 'every part fetched once');
    assert.equal(rig.surface('DOORBELL').seeks().length, 1, 'one seek: the first picture');
    assert.ok(longest < 300, `the picture stood still for ${longest} ms`);
    assert.ok(Math.abs(lag(rig, 'DOORBELL')) < 100, `it plays with the clock (${lag(rig, 'DOORBELL')} ms behind)`);
  });

  it('a tile that decodes a little slower than the clock is sent forward now and then, and keeps its buffer', async () => {
    const files = [{ key: FILE_A, startMs: ORIGIN, parts: 60, gop: 1 }];
    const { rig, session } = await wall([{ id: 'DOORBELL', files }], { surfaceOptions: { audioShortMs: 64, rate: 0.95 } });
    session.play(ORIGIN + 10_500);
    await watch(rig, 'DOORBELL', 20_000);
    assert.equal(rig.paths('fragments?at=').length, 1, 'planned once: a seek forward inside what is held needs no plan');
    const parts = rig.paths('/fragments/').filter((path) => !path.endsWith('/init'));
    assert.equal(new Set(parts).size, parts.length, 'every part fetched once');
    assert.ok(Math.abs(lag(rig, 'DOORBELL')) < 1000, `it stays near the clock (${lag(rig, 'DOORBELL')} ms behind)`);
  });

  it('the same with the decoder that stops before the end of what it holds', async () => {
    const files = [{ key: FILE_A, startMs: ORIGIN, parts: 60, gop: 1 }];
    const { rig, session } = await wall([{ id: 'DOORBELL', files }], { surfaceOptions: { audioShortMs: 64, ...HOLD_BACK } });
    session.play(ORIGIN + 10_500);
    await watch(rig, 'DOORBELL', 20_000);
    assert.equal(rig.paths('fragments?at=').length, 1);
    const parts = rig.paths('/fragments/').filter((path) => !path.endsWith('/init'));
    assert.equal(new Set(parts).size, parts.length, 'every part fetched once');
  });
});

describe('a last part that a file break cut short, in a file with sound', () => {
  const backyard = { id: 'BACKYARD', files: [{ key: OTHER, startMs: ORIGIN, parts: 90, gop: 1 }] };
  const SHORT = 'd4e5f6a1b2c3';
  const SOUND = { audioShortMs: 64, ...HOLD_BACK };                    // the sound ends 64 ms before the picture, and the decoder holds back
  const files = (lastMs, next) => [
    { key: FILE_A, startMs: ORIGIN, parts: 10, gop: 1 },                                         // 0 to 20 s
    { key: SHORT, startMs: ORIGIN + 20_000, parts: 1, partMs: lastMs, gop: 1 },                  // one short part, then a file break
    { ...next, startMs: ORIGIN + 20_000 + lastMs + next.holeMs },
  ];
  const plans = (rig) => rig.paths('cameras/WYZE/fragments?at=');
  const partsFetched = (rig) => rig.paths('cameras/WYZE/fragments/').filter((path) => !path.endsWith('/init'));

  for (const [name, next] of [
    ['the next file in another codec right after it', { key: FILE_B, parts: 20, gop: 1, mime: MIME_2, holeMs: 0 }],
    ['the next file after a 3 s hole', { key: FILE_B, parts: 20, gop: 1, holeMs: 3000 }],
  ]) {
    it(`150 ms long: planned once more at most, every part fetched once, and the tile plays on (${name})`, async () => {
      const { rig, session } = await wall([backyard, { id: 'WYZE', files: files(150, next) }], { surfaceOptions: SOUND });
      session.play(ORIGIN + 14_000);
      await rig.timers.advance(30_000);
      assert.ok(plans(rig).length <= 2, `planned ${plans(rig).length} times in 30 s`);
      assert.equal(new Set(partsFetched(rig)).size, partsFetched(rig).length, 'every part fetched once');
      assert.deepEqual([session.cell('WYZE').coverage.kind, session.cell('WYZE').coverage.playing], ['recorded', true]);
      assert.ok(Math.abs(lag(rig, 'WYZE')) < 500, `it plays with the clock (${lag(rig, 'WYZE')} ms behind)`);
    });
  }

  it('shorter than its sound\'s shortfall (so no buffered range reaches into it): planned a few times, never again and again', async () => {
    const next = { key: FILE_B, parts: 20, gop: 1, mime: MIME_2, holeMs: 0 };
    const { rig, session } = await wall([backyard, { id: 'WYZE', files: files(50, next) }], { surfaceOptions: SOUND });
    session.play(ORIGIN + 14_000);
    await rig.timers.advance(30_000);
    assert.ok(plans(rig).length <= 5, `planned ${plans(rig).length} times in 30 s`);
    assert.ok(partsFetched(rig).length <= 30, `${partsFetched(rig).length} parts fetched for 22 parts played`);
    assert.equal(rig.surface('WYZE').mime, MIME_2, 'the next file plays');
    assert.deepEqual([session.cell('WYZE').coverage.kind, session.cell('WYZE').coverage.playing], ['recorded', true]);
    assert.ok(Math.abs(lag(rig, 'WYZE')) < 500, `it plays with the clock (${lag(rig, 'WYZE')} ms behind)`);
  });
});

describe('a camera whose first recording is after the clock', () => {
  const backyard = { id: 'BACKYARD', files: [{ key: OTHER, startMs: ORIGIN, parts: 90, gop: 1 }] };

  it('waits for the clock to get there and then plays with it, instead of playing its first recording early again and again', async () => {
    const late = { id: 'LATE', files: [{ key: FILE_B, startMs: ORIGIN + 30_000, parts: 10, gop: 1 }] };
    const { rig, session } = await wall([backyard, late]);
    const cell = session.cell('LATE');
    session.play(ORIGIN + 10_000);
    await rig.timers.advance(5000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.next], ['gap', ORIGIN + 30_000], 'it says when its first recording starts');
    assert.equal(rig.surface('LATE')?.presents().length ?? 0, 0, 'no picture from 20 s after the clock');
    assert.deepEqual([session.cell('BACKYARD').coverage.kind, session.cell('BACKYARD').coverage.playing], ['recorded', true]);
    await rig.timers.advance(17_000);                                  // the clock is 2 s into LATE's first recording
    assert.deepEqual([cell.coverage.kind, cell.coverage.playing], ['recorded', true]);
    assert.ok(Math.abs(lag(rig, 'LATE')) < 500, `it plays with the clock (${lag(rig, 'LATE')} ms behind)`);
    assert.ok(rig.surface('LATE').seeks().length <= 2, `${rig.surface('LATE').seeks().length} seeks`);
  });

  it('a camera with nothing recorded that records while the wall plays waits for the clock to get to its first recording', async () => {
    const eufy = { id: 'EUFY', files: [] };
    const { rig, session } = await wall([backyard, eufy]);
    const cell = session.cell('EUFY');
    session.play(ORIGIN + 10_000);
    await rig.timers.advance(2000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.next, cell.coverage.message], ['gap', null, MESSAGES.empty]);
    rig.archives[1].addFile({ key: FILE_B, startMs: ORIGIN + 30_000, parts: 10, gop: 1 });      // the battery camera woke up
    await rig.timers.advance(5000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.next], ['gap', ORIGIN + 30_000]);
    assert.equal(rig.surface('EUFY')?.presents().length ?? 0, 0, 'no picture from after the clock');
    await rig.timers.advance(16_000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.playing], ['recorded', true]);
    assert.ok(Math.abs(lag(rig, 'EUFY')) < 500, `it plays with the clock (${lag(rig, 'EUFY')} ms behind)`);
  });

  it('paused before its first recording, a tile still shows that recording\'s first picture, and says so', async () => {
    const late = { id: 'LATE', files: [{ key: FILE_B, startMs: ORIGIN + 30_000, parts: 10, gop: 1 }] };
    const { rig, session } = await wall([backyard, late]);
    session.beginScrub();
    session.scrub(ORIGIN + 10_000);
    session.endScrub();
    session.pause();
    await rig.timers.advance(2000);
    assert.deepEqual([session.cell('LATE').coverage.kind, session.cell('LATE').coverage.message], ['recorded', MESSAGES.oldest]);
  });
});

describe('a recording too short to show between two holes', () => {
  it('a tile that resumes into it waits through it and joins at the file after it, without saying it cannot read it', async () => {
    const files = [
      { key: FILE_A, startMs: ORIGIN, parts: 10, gop: 1 },                                        // 0 to 20 s
      { key: FILE_B, startMs: ORIGIN + 24_000, parts: 1, partMs: 640, gop: 1 },                    // Patio's 640 ms between two file breaks
      { key: 'c3d4e5f6a1b2', startMs: ORIGIN + 29_000, parts: 10, gop: 1 },
    ];
    const backyard = { id: 'BACKYARD', files: [{ key: OTHER, startMs: ORIGIN, parts: 90, gop: 1 }] };
    const { rig, session } = await wall([backyard, { id: 'PATIO', files }]);
    const cell = session.cell('PATIO');
    const seen = record(rig, cell);
    session.play(ORIGIN + 16_000);
    await rig.timers.advance(6000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.next], ['gap', ORIGIN + 24_000]);
    await rig.timers.advance(3000);                                    // the clock is past the short recording
    assert.deepEqual([cell.coverage.kind, cell.coverage.next], ['gap', ORIGIN + 29_000], 'it waits for the file after it');
    await rig.timers.advance(6000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.playing], ['recorded', true]);
    assert.ok(Math.abs(lag(rig, 'PATIO')) < 500, `it plays with the clock (${lag(rig, 'PATIO')} ms behind)`);
    assert.equal(seen.some((coverage) => coverage.kind === 'unreadable'), false, `it said: ${JSON.stringify(seen.filter((c) => c.kind === 'unreadable'))}`);
    assert.equal(rig.surface('PATIO').log.filter((entry) => entry.op === 'reset').length, 0, 'the buffer was never thrown away');
  });
});

describe('a single cell', () => {
  it('a desire that is not playing never resumes by itself at a gap', async () => {
    const files = [{ key: FILE_A, startMs: ORIGIN, parts: 10, gop: 1 }, { key: FILE_B, startMs: ORIGIN + 25_000, parts: 10, gop: 1 }];
    const rig = createRig({ cameras: [{ id: 'CAM-1', files }], surfaceOptions: HOLD_BACK });
    await rig.start();
    const cell = rig.makeCell();
    rig.clock.play(ORIGIN + 21_000);
    desirer(cell)(ORIGIN + 21_000, 'exact', false);
    await rig.timers.advance(10_000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.next], ['gap', ORIGIN + 25_000]);
    assert.equal(rig.surface(), undefined, 'nothing was shown');
  });

  it('an answer whose next recording is not after the time asked for is not asked again and again', async () => {
    const files = [{ key: FILE_A, startMs: ORIGIN, parts: 10, gop: 1 }, { key: FILE_B, startMs: ORIGIN + 25_000, parts: 10, gop: 1 }];
    const rig = createRig({ cameras: [{ id: 'CAM-1', files }] });
    await rig.start();
    const plan = rig.catalog.plan;
    rig.catalog.plan = async (id, atMs, options) => ({ ...(await plan(id, atMs, options)), next: atMs });     // a server that contradicts itself
    const cell = rig.makeCell();
    rig.clock.play(ORIGIN + 21_000);
    desirer(cell)(ORIGIN + 21_000, 'exact', true);
    await rig.timers.advance(5000);
    assert.equal(rig.paths('fragments?at=').length, 1);
    assert.equal(cell.coverage.kind, 'gap');
  });
});
