// The whole player under a scrub storm: the real session, cells, catalog and fetcher over a fake archive and fake surfaces.
// The fake surface throws when a rule MSE needs is broken, so a green run also proves: every chain starts at a key part, every continuation
// is contiguous and has its init, every append lands where the plan says, and no seek ever came within 700 ms of the end of a held range.
import { afterEach, beforeEach, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError } from '../web/js/api.js';
import { DEFAULT_POLICY, bufferSeconds } from '../web/js/nvr/planner.js';
import { createSession } from '../web/js/nvr/session.js';
import { FILE_A, FILE_B, ORIGIN } from './player-fakes/fake-archive.mjs';
import { createRig } from './player-fakes/rig.mjs';

function random(seed) {
  let state = seed >>> 0;
  return () => { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state / 2 ** 32; };
}

const IDS = ['CAM-1', 'CAM-2', 'CAM-3', 'CAM-4'];
const MIME_2 = 'video/mp4; codecs="avc1.640033"';
const files = ({ twoCodecs = false } = {}) => [
  { key: FILE_A, startMs: ORIGIN, parts: 60, gop: 4 },
  { key: FILE_B, startMs: ORIGIN + 140_000, parts: 20, gop: 1, ...(twoCodecs ? { mime: MIME_2 } : {}) },
];

/** A time well inside file A, so that playing for a few seconds after the release does not reach a gap. */
const safeTime = (next) => ORIGIN + 1000 + Math.floor(next() * 98_000);

/** A recorded time: anywhere in file A or file B, including their last seconds. */
function recordedTime(next) {
  return next() < 0.75 ? ORIGIN + 1000 + Math.floor(next() * 118_000) : ORIGIN + 141_000 + Math.floor(next() * 38_000);
}

let errors;
const realError = console.error;
beforeEach(() => { errors = []; console.error = (...args) => errors.push(args); });
afterEach(() => { console.error = realError; });

async function build({ cameras, seed, tileCap, latency, leadLimitBytes, twoCodecs = false }) {
  const next = random(seed);
  const rig = createRig({
    cameras: cameras.map((id) => ({ id, files: files({ twoCodecs }) })),
    latency: latency ? () => latency(next) : undefined,
    leadLimitBytes,
  });
  await rig.start();
  const session = createSession({
    catalog: rig.catalog, fetcher: rig.fetcher, clock: rig.clock, timers: rig.timers, tileCap, policy: { ...DEFAULT_POLICY, keySteps: true },
    createCell: (id) => rig.makeCell(id, { leadLimitBytes: leadLimitBytes ?? 16 * 1_048_576 }),
  });
  session.setCameras(cameras);
  return { rig, session, next };
}

function assertSound(rig, cameras) {
  assert.deepEqual(errors, [], `a cell reported an error: ${JSON.stringify(errors.map((e) => String(e[0]?.message ?? e[0])))}`);
  const stats = rig.api.stats();
  assert.ok(stats.worst.bytes <= 3, `${stats.worst.bytes} media requests at once`);
  assert.ok(stats.worst.json <= 1, `${stats.worst.json} JSON requests at once`);
  for (const id of cameras) assert.ok((stats.perCamera.get(id) ?? 0) <= 1, `${id}: ${stats.perCamera.get(id)} requests at once for one tile`);
  assert.ok(rig.api.log.every((entry) => entry.aborted === false && entry.signalAbortedAtStart === false), 'no request was aborted');
  for (const id of cameras) {
    const surface = rig.surface(id);
    assert.ok(surface.worstBusy <= 1, `${id}: two operations on one surface at once`);
    assert.ok(surface.seeks().every((seek) => seek.presented), `${id}: a seek showed nothing`);
    for (const append of surface.appends()) {
      if (append.chainBreak) assert.equal(append.key, true, `${id}: ${append.id} started a chain without a key`);
    }
  }
}

describe('one tile', () => {
  it('10,000 randomized scrubs end on the picture of the last target', async () => {
    const { rig, session, next } = await build({ cameras: ['CAM-1'], seed: 7, tileCap: 1, latency: (n) => 5 + Math.floor(n() * 70) });
    session.beginScrub();
    let last = ORIGIN + 30_000;
    for (let i = 0; i < 10_000; i += 1) {
      last = recordedTime(next);
      session.scrub(last);
      await rig.timers.advance(Math.floor(next() * 30));
      if (next() < 0.002) await rig.timers.advance(200 + Math.floor(next() * 300));        // the pointer rests now and then: exact frames happen
    }
    last = safeTime(next);
    session.scrub(last);
    session.endScrub();
    await rig.timers.advance(4000);
    assertSound(rig, ['CAM-1']);
    const surface = rig.surface('CAM-1');
    assert.ok(surface.presents().length > 100, 'pictures were shown during the drag');
    const target = bufferSeconds(last, rig.catalog.baseMs);
    const end = surface.held().find((r) => target >= r.start && target < r.end)?.end ?? target;
    const expected = Math.min(target, end - 0.7);
    const exactFrames = surface.presents().filter((p) => Math.abs(p.sec - expected) < 0.002);
    assert.ok(exactFrames.length >= 1, `the final target ${last} was never shown (last picture ${surface.presents().at(-1).sec}, expected ${expected})`);
    assert.equal(rig.clock.mode, 'playing');
    assert.equal(session.cell('CAM-1').coverage.kind, 'recorded');
    assert.equal(session.cell('CAM-1').coverage.playing, true);
  });

  it('a target that moves every 8 ms into video it has not got, with every answer taking 40 ms, still gets a picture every 50 ms or so', async () => {
    const next = random(11);
    const rig = createRig({ cameras: [{ id: 'CAM-1', files: [{ key: FILE_A, startMs: ORIGIN, parts: 1200, gop: 1 }] }], latency: () => 40 });
    await rig.start();
    const session = createSession({
      catalog: rig.catalog, fetcher: rig.fetcher, clock: rig.clock, timers: rig.timers, tileCap: 1, policy: { ...DEFAULT_POLICY, keySteps: true },
      createCell: (id) => rig.makeCell(id),
    });
    session.setCameras(['CAM-1']);
    session.beginScrub();
    const begun = rig.timers.now();
    for (let i = 0; i < 250; i += 1) {                                // two seconds of dragging, a new key part every time
      session.scrub(ORIGIN + 5000 + i * 2500 + Math.floor(next() * 400));
      await rig.timers.advance(8);
    }
    const shown = rig.surface('CAM-1').presents().map((p) => p.at - begun);
    assert.ok(shown.length >= 30, `only ${shown.length} pictures in 2 s`);
    const gaps = shown.slice(1).map((at, i) => at - shown[i]);
    assert.ok(Math.max(...gaps) <= 100, `the longest wait for a picture was ${Math.max(...gaps)} ms`);
    session.endScrub();
    await rig.timers.advance(5000);
    assertSound(rig, ['CAM-1']);
  });

  it('with answers failing at random while dragging (busy, slow drive, removed, lost) it still ends on the last target', async () => {
    const { rig, session, next } = await build({ cameras: ['CAM-1'], seed: 23, tileCap: 1, latency: (n) => 5 + Math.floor(n() * 50) });
    const errorsToThrow = [
      () => new ApiError(429, 'busy', 'Busy.', null, { retryAfter: 0 }),
      () => new ApiError(504, 'drive_slow', 'Slow.', null, { retryAfter: 0 }),
      () => new ApiError(410, 'gone', 'Removed.'),
      () => new ApiError(0, 'network', 'Lost.'),
    ];
    rig.api.failWhen((path) => path !== 'nvr/cameras' && next() < 0.08, () => errorsToThrow[Math.floor(next() * errorsToThrow.length)](), { times: Infinity });
    session.beginScrub();
    let last = ORIGIN + 30_000;
    for (let i = 0; i < 1500; i += 1) {
      last = recordedTime(next);
      session.scrub(last);
      await rig.timers.advance(Math.floor(next() * 30));
    }
    rig.api.clearFailures();
    last = safeTime(next);
    session.scrub(last);
    session.endScrub();
    await rig.timers.advance(8000);
    const surface = rig.surface('CAM-1');
    const target = bufferSeconds(last, rig.catalog.baseMs);
    const end = surface.held().find((r) => target >= r.start && target < r.end)?.end ?? target;
    assert.ok(surface.presents().some((p) => Math.abs(p.sec - Math.min(target, end - 0.7)) < 0.002), 'the final target was shown');
    assert.equal(session.cell('CAM-1').coverage.playing, true);
    assert.ok(rig.api.log.every((entry) => entry.aborted === false));
  });
});

describe('a grid of four', () => {
  it('10,000 randomized scrubs end on the last target in every tile, within the page-wide caps', async () => {
    const { rig, session, next } = await build({ cameras: IDS, seed: 99, tileCap: 4, latency: (n) => 5 + Math.floor(n() * 70) });
    session.focus('CAM-2');
    session.beginScrub();
    let last = ORIGIN + 30_000;
    for (let i = 0; i < 10_000; i += 1) {
      last = recordedTime(next);
      session.scrub(last);
      if (next() < 0.01) session.focus(IDS[Math.floor(next() * 4)]);
      await rig.timers.advance(Math.floor(next() * 30));
    }
    last = safeTime(next);
    session.scrub(last);
    session.endScrub();
    await rig.timers.advance(4000);
    assertSound(rig, IDS);
    const target = bufferSeconds(last, rig.catalog.baseMs);
    for (const id of IDS) {
      const surface = rig.surface(id);
      const end = surface.held().find((r) => target >= r.start && target < r.end)?.end ?? target;
      const expected = Math.min(target, end - 0.7);
      assert.ok(surface.presents().some((p) => Math.abs(p.sec - expected) < 0.002), `${id}: the final target was never shown`);
      assert.equal(session.cell(id).coverage.kind, 'recorded', id);
    }
    assert.equal(rig.clock.mode, 'playing');
  });
});

describe('two codec strings (every jump between the files rebuilds the surface)', () => {
  it('3,000 randomized scrubs over one tile still end on the last target', async () => {
    const { rig, session, next } = await build({ cameras: ['CAM-1'], seed: 31, tileCap: 1, twoCodecs: true, latency: (n) => 5 + Math.floor(n() * 70) });
    session.beginScrub();
    for (let i = 0; i < 3000; i += 1) {
      session.scrub(recordedTime(next));
      await rig.timers.advance(Math.floor(next() * 30));
    }
    const last = safeTime(next);
    session.scrub(last);
    session.endScrub();
    await rig.timers.advance(4000);
    assertSound(rig, ['CAM-1']);
    const surface = rig.surface('CAM-1');
    assert.ok(surface.generation > 100, `only ${surface.generation} rebuilds: the files were not crossed often enough`);
    assert.ok(surface.presents().some((p) => Math.abs(p.sec - bufferSeconds(last, rig.catalog.baseMs)) < 0.002), 'the final target was shown');
    assert.equal(session.cell('CAM-1').coverage.playing, true);
  });

  it('3,000 randomized scrubs over a grid of four', async () => {
    const { rig, session, next } = await build({ cameras: IDS, seed: 47, tileCap: 4, twoCodecs: true, latency: (n) => 5 + Math.floor(n() * 70) });
    session.focus('CAM-3');
    session.beginScrub();
    for (let i = 0; i < 3000; i += 1) {
      session.scrub(recordedTime(next));
      await rig.timers.advance(Math.floor(next() * 30));
    }
    const last = safeTime(next);
    session.scrub(last);
    session.endScrub();
    await rig.timers.advance(4000);
    assertSound(rig, IDS);
    for (const id of IDS) {
      assert.ok(rig.surface(id).presents().some((p) => Math.abs(p.sec - bufferSeconds(last, rig.catalog.baseMs)) < 0.002), `${id}: the final target was shown`);
    }
  });
});

describe('the bytes of a drag', () => {
  it('a drag across one GOP asks the server once, not once per move', async () => {
    const { rig, session } = await build({ cameras: ['CAM-1'], seed: 1, tileCap: 1 });
    session.beginScrub();
    for (let i = 0; i < 50; i += 1) {
      session.scrub(ORIGIN + 8100 + i * 20);                          // part 4 of file A: [8 s, 10 s)
      await rig.timers.advance(10);
    }
    assert.equal(rig.paths('keyframe').length, 1);
    session.endScrub();
    await rig.timers.advance(3000);
    assertSound(rig, ['CAM-1']);
  });
});
