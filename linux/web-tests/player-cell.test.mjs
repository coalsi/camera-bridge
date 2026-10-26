// cell.js: one tile, from a desire to a picture, against the real fetcher and catalog and a fake archive and surface.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError } from '../web/js/api.js';
import { DEFAULT_POLICY, MESSAGES, bufferSeconds, timestampOffsetSeconds } from '../web/js/nvr/planner.js';
import { FILE_A, FILE_B, ORIGIN } from './player-fakes/fake-archive.mjs';
import { createRig, defaultFiles, desirer, fakeElement } from './player-fakes/rig.mjs';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { drawnFrom, givePicture, planCalls, recordingCanvases, siblingAfter } from './support/fake-picture.mjs';

const PART = 2000;
const at = (index, offsetMs = 0) => ORIGIN + index * PART + offsetMs;      // inside part `index` of file A

async function ready(options = {}) {
  const { cellOptions, ...rigOptions } = options;
  const rig = createRig(rigOptions);
  await rig.start();
  const cell = rig.makeCell(undefined, cellOptions);
  const want = desirer(cell);
  const settle = (ms = 600) => rig.timers.advance(ms);
  return { rig, cell, want, settle };
}

describe('a key step', () => {
  it('fetches the key fragment and its init, appends it as a new chain, and shows the first picture', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(6, 1000), 'key');                                          // part 6; its GOP starts at part 4
    await settle();
    assert.deepEqual(rig.paths('keyframe'), [`nvr/cameras/CAM-1/keyframe?at=${at(6, 1000)}`]);
    assert.deepEqual(rig.paths('/init'), [`nvr/cameras/CAM-1/fragments/${FILE_A}.4/init`]);
    assert.deepEqual(rig.paths('fragments?'), [], 'a key step asks for no plan');
    const surface = rig.surface();
    assert.deepEqual(surface.ops(), ['open', 'appendInit', `append ${FILE_A}.4!`, 'seek', 'evict']);
    const [seek] = surface.presents();
    assert.equal(seek.sec, bufferSeconds(at(4) + 1, rig.base()));
    assert.deepEqual([cell.coverage.kind, cell.coverage.epoch, cell.coverage.playing], ['recorded', 1, false]);
  });

  it('shows the exact frame for free while the target is inside the key part, and asks for nothing more', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(4, 100), 'key');
    await settle();
    const before = rig.requests().length;
    want(at(4, 300), 'key');
    await settle();
    want(at(4, 1400), 'key');                                          // only 600 ms of the part are left: the key picture instead
    await settle();
    assert.equal(rig.requests().length, before);
    const sec = (ms) => bufferSeconds(ms, rig.base());
    assert.deepEqual(rig.surface().presents().map((p) => p.sec), [sec(at(4) + 1), sec(at(4, 300)), sec(at(4) + 1)]);
  });

  it('remembers which range a long GOP\'s key picture covers and does not ask again for it', async () => {
    const files = [{ key: FILE_A, startMs: ORIGIN, parts: 60, gop: 40 }];                  // an 80 s GOP
    const { rig, cell, want, settle } = await ready({ cameras: [{ id: 'CAM-1', files }] });
    want(at(10), 'key');
    await settle();
    want(at(20), 'key');                                                // beyond what the first answer proved: asks again
    await settle();
    want(at(15), 'key');                                                // inside [start, 20]: no request
    await settle();
    want(at(5), 'key');
    await settle();
    assert.equal(rig.paths('keyframe').length, 2);
    assert.equal(rig.surface().appends().length, 1, 'the same key part is not appended twice');
    assert.equal(rig.surface().presents().length, 4);
    assert.ok(rig.surface().presents().every((p) => p.sec === bufferSeconds(ORIGIN + 1, rig.base())));
  });

  it('a time with no recording is a gap with the next recording, and the picture stays', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(4, 100), 'key');
    await settle();
    want(ORIGIN + 130_000, 'key');
    await settle();
    assert.deepEqual([cell.coverage.kind, cell.coverage.next, cell.coverage.epoch], ['gap', ORIGIN + 140_000, 2]);
    assert.equal(rig.surface().seeks().length, 1);
  });

  it('shows the stale key picture only when the newest desire is a key step with nothing better held', async () => {
    const { rig, cell, want, settle } = await ready({ latency: (kind) => (kind === 'bytes' ? 100 : 10) });
    want(at(4, 100), 'key');
    await settle(20);
    want(at(20, 100), 'key');                                          // newer, not held: the answer in flight is still shown
    await settle(700);
    assert.equal(rig.paths('keyframe').length, 2);
    assert.equal(rig.surface().presents().length, 2);
    // now an exact desire arrives while a key request is in flight: the stale key picture is not shown
    const before = rig.surface().presents().length;
    want(at(30, 100), 'key');
    await settle(20);
    want(at(30, 100), 'exact');
    await settle(1500);
    const shown = rig.surface().presents().slice(before).map((p) => p.sec);
    assert.deepEqual(shown, [bufferSeconds(at(30, 100), rig.base())], 'only the exact frame');
  });
});

describe('an exact step', () => {
  it('plans, appends the key part up to the target and one part ahead as one chain, and shows the frame', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(6, 500));
    await settle();
    assert.deepEqual(rig.paths('fragments?'), [`nvr/cameras/CAM-1/fragments?at=${at(6, 500)}&ahead=1`]);
    assert.deepEqual(rig.paths('/init'), [`nvr/cameras/CAM-1/fragments/${FILE_A}.4/init`]);
    const surface = rig.surface();
    assert.deepEqual(surface.ops(), ['open', 'appendInit', `append ${FILE_A}.4!`, `append ${FILE_A}.5`, `append ${FILE_A}.6`, `append ${FILE_A}.7`, 'seek', 'evict']);
    assert.equal(surface.presents()[0].sec, bufferSeconds(at(6, 500), rig.base()));
    assert.deepEqual([cell.coverage.kind, cell.coverage.epoch], ['recorded', 1]);
  });

  it('after a key picture it fetches only what follows the key part, with no new init and no chain break', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(4, 100), 'key');
    await settle();
    want(at(6, 500), 'exact');
    await settle();
    assert.deepEqual(rig.paths('/init').length, 1);
    assert.deepEqual(rig.surface().ops().slice(-6), ['pause', `append ${FILE_A}.5`, `append ${FILE_A}.6`, `append ${FILE_A}.7`, 'seek', 'evict']);
    assert.deepEqual(rig.surface().appends().map((a) => [a.id.split('.')[1], a.chainBreak]), [['4', true], ['5', false], ['6', false], ['7', false]]);
    assert.equal(rig.surface().presents().at(-1).sec, bufferSeconds(at(6, 500), rig.base()));
  });

  it('seeks straight into held data when 700 ms of it follow the target', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(6, 500));
    await settle();
    const before = rig.requests().length;
    want(at(5, 700));
    await settle();
    assert.equal(rig.requests().length, before, 'no request at all');
    assert.equal(rig.surface().presents().at(-1).sec, bufferSeconds(at(5, 700), rig.base()));
  });

  it('extends the chain before seeking when the target is in the last 700 ms of what is held', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(6, 500));
    await settle();                                                   // parts 4..7 held; part 7 ends at ORIGIN + 16 s
    const seeksBefore = rig.surface().seeks().length;
    want(at(7, 1500));                                                // 500 ms before the end of the chain
    await settle();
    const log = rig.surface().ops();
    assert.ok(log.lastIndexOf(`append ${FILE_A}.8`) < log.lastIndexOf('seek'), 'part 8 is appended before the seek');
    assert.equal(rig.surface().seeks().length, seeksBefore + 1);
    assert.equal(rig.surface().presents().at(-1).sec, bufferSeconds(at(7, 1500), rig.base()));
    assert.ok(rig.surface().seeks().every((s) => s.presented), 'no seek ever failed the hold-back rule');
  });

  it('continuing a chain after appending somewhere else starts its GOP over from the key part, because MSE drops delta parts that follow a jump', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(4, 100), 'key');
    await settle();
    want(at(20, 100), 'key');                                         // the part appended last is now elsewhere
    await settle();
    want(at(6, 500), 'exact');
    await settle();
    const appends = rig.surface().appends().map((a) => `${a.id.split('.')[1]}${a.chainBreak ? '!' : ''}`);
    assert.deepEqual(appends, ['4!', '20!', '4!', '5', '6', '7']);
    assert.equal(rig.surface().presents().at(-1).sec, bufferSeconds(at(6, 500), rig.base()));
  });

  it('at the very end of the recordings it shows the last picture a decoder will release, 720 ms before the end', async () => {
    const files = [{ key: FILE_A, startMs: ORIGIN, parts: 10, gop: 4 }];
    const { rig, cell, want, settle } = await ready({ cameras: [{ id: 'CAM-1', files }] });
    want(at(9, 1900));
    await settle();
    assert.equal(cell.coverage.kind, 'recorded');
    assert.equal(rig.surface().presents().at(-1).sec, bufferSeconds(ORIGIN + 20_000 - 720, rig.base()));
    assert.ok(rig.surface().seeks().every((seek) => seek.presented));
  });

  it('is coarse when the lead-in is too large: the key picture only, with the key start to snap to', async () => {
    const files = [{ key: FILE_A, startMs: ORIGIN, parts: 60, gop: 40 }];                  // keyBytes 700 kB, deltaBytes 100 kB
    const { rig, cell, want, settle } = await ready({ cameras: [{ id: 'CAM-1', files }], leadLimitBytes: 2_000_000 });
    want(at(30, 500));                                                // 700 kB + 30 x 100 kB of lead-in
    await settle();
    assert.deepEqual([cell.coverage.kind, cell.coverage.snapMs], ['coarse', ORIGIN]);
    assert.deepEqual(rig.surface().appends().map((a) => a.id), [`${FILE_A}.0`]);
    assert.equal(rig.surface().presents().at(-1).sec, bufferSeconds(ORIGIN + 1, rig.base()));
    const exactEnough = await ready({ cameras: [{ id: 'CAM-1', files }], leadLimitBytes: 16 * 1_048_576 });
    exactEnough.want(at(30, 500));
    await exactEnough.settle(2000);
    assert.equal(exactEnough.cell.coverage.kind, 'recorded');
    assert.equal(exactEnough.rig.surface().appends().length, 32);
  });

  it('a target before the oldest recording shows the oldest, and says so', async () => {
    const { rig, cell, want, settle } = await ready();
    want(ORIGIN - 50_000);
    await settle();
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['recorded', MESSAGES.oldest]);
    assert.equal(rig.surface().presents().at(-1).sec, bufferSeconds(ORIGIN + 1, rig.base()), 'the oldest frame');
  });

  it('a gap holds the picture and reports where the next recording starts', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(6, 500));
    await settle();
    want(ORIGIN + 125_000);
    await settle();
    assert.deepEqual([cell.coverage.kind, cell.coverage.next], ['gap', ORIGIN + 140_000]);
    assert.equal(rig.surface().presents().length, 1);
  });

  it('a stretch on an archive drive that is unplugged says so and where the next recording on the box starts', async () => {
    const { rig, cell, want, settle } = await ready();
    rig.archive.setAway({ fromMs: ORIGIN + 120_000, toMs: ORIGIN + 140_000 });
    want(ORIGIN + 125_000);
    await settle();
    assert.deepEqual([cell.coverage.kind, cell.coverage.away, cell.coverage.message, cell.coverage.next], ['gap', true, MESSAGES.archiveAway, ORIGIN + 140_000]);
    assert.equal(rig.surface(), undefined, 'no surface was built: nothing there plays now');
  });

  it('a camera with nothing recorded says so', async () => {
    const { rig, cell, want, settle } = await ready({ cameras: [{ id: 'CAM-1', files: defaultFiles() }, { id: 'CAM-2', files: [] }] });
    const other = rig.makeCell('CAM-2');
    desirer(other)(ORIGIN + 1000);
    await settle();
    assert.deepEqual([other.coverage.kind, other.coverage.message, other.coverage.next], ['gap', MESSAGES.empty, null]);
    assert.equal(rig.surface('CAM-2'), undefined, 'no surface was built for it');
  });
});

describe('failures', () => {
  it('a part retention removed meanwhile (410) makes it plan again once', async () => {
    const { rig, cell, want, settle } = await ready();
    rig.api.failWhen(`fragments/${FILE_A}.5`, () => new ApiError(410, 'gone', 'Removed.'), { times: 1 });
    want(at(6, 500));
    await settle(1500);
    assert.equal(rig.paths('fragments?').length, 2, 'planned twice');
    assert.deepEqual([cell.coverage.kind, cell.coverage.epoch], ['recorded', 1]);
  });

  it('a second 410 for the same desire is an unreadable part', async () => {
    const { rig, cell, want, settle } = await ready();
    rig.api.failWhen(`fragments/${FILE_A}.5`, () => new ApiError(410, 'gone', 'Removed.'), { times: 2 });
    want(at(6, 500));
    await settle(1500);
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['unreadable', MESSAGES.unreadable]);
  });

  it('a drive that does not answer (504) says the recordings drive is not connected', async () => {
    const { rig, cell, want, settle } = await ready();
    rig.api.failWhen('keyframe', () => new ApiError(504, 'drive_slow', 'Slow.', null, { retryAfter: 0 }), { times: 10 });
    want(at(6, 500), 'key');
    await settle(1000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['driveMissing', MESSAGES.driveMissing]);
  });

  it('a 410 while the bridge says the recordings folder is gone is the drive, not a removed part: no second plan', async () => {
    const { rig, cell, want, settle } = await ready({ cellOptions: { getPause: () => 'folderMissing' } });
    rig.api.failWhen(`fragments/${FILE_A}.5`, () => new ApiError(410, 'gone', 'Removed.'), { times: 100 });
    want(at(6, 500));
    await settle(1500);
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['driveMissing', MESSAGES.driveMissing]);
    assert.equal(rig.paths('fragments?').length, 1, 'planned once: a plan is a memory lookup and would list the same parts again');
  });

  it('a 502 while the bridge says the recordings folder is gone is the drive too: a read of an open file on a vanished volume fails with EIO, which the bridge calls unreadable (T13, real unmount)', async () => {
    const { rig, cell, want, settle } = await ready({ cellOptions: { getPause: () => 'folderMissing' } });
    rig.api.failWhen(`fragments/${FILE_A}.5`, () => new ApiError(502, 'unreadable', 'Cannot be read.'), { times: 100 });
    want(at(6, 500));
    await settle(1500);
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['driveMissing', MESSAGES.driveMissing]);
  });

  it('a 502 with the recorder healthy is still an unreadable part, not the drive', async () => {
    const { rig, cell, want, settle } = await ready({ cellOptions: { getPause: () => null } });
    rig.api.failWhen(`fragments/${FILE_A}.5`, () => new ApiError(502, 'unreadable', 'Cannot be read.'), { times: 100 });
    want(at(6, 500));
    await settle(1500);
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['unreadable', MESSAGES.unreadable]);
  });

  it('with the drive gone the tile keeps its picture, probes every 5 s with one keyframe read, and shows the playhead again once the drive answers', async () => {
    const pause = { value: 'folderMissing' };
    const { rig, cell, want, settle } = await ready({ cellOptions: { getPause: () => pause.value } });
    want(at(6, 500));
    await settle();
    assert.equal(cell.coverage.kind, 'recorded');
    const shown = rig.surface().presents().length;
    rig.clock.scrub(at(20, 500));                                        // the playhead stands in recorded time (the probe reads there)
    rig.api.failWhen(`fragments/${FILE_A}.20`, () => new ApiError(410, 'gone', 'Removed.'), { times: 1 });
    rig.api.failWhen('keyframe', () => new ApiError(410, 'gone', 'Removed.'), { times: 2 });
    want(at(20, 500));
    await settle(1000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['driveMissing', MESSAGES.driveMissing]);
    assert.equal(rig.surface().presents().length, shown, 'the last picture stays; nothing new is shown');
    assert.equal(rig.paths('keyframe').length, 0, 'the first look comes after the probe period');
    await settle(5000);
    assert.deepEqual([rig.paths('keyframe').length, cell.coverage.kind], [1, 'driveMissing']);
    assert.equal(rig.paths('keyframe')[0], `nvr/cameras/CAM-1/keyframe?at=${at(20, 500)}`);
    await settle(5000);
    assert.deepEqual([rig.paths('keyframe').length, cell.coverage.kind], [2, 'driveMissing']);
    await settle(5000);                                                  // the third probe is answered: the drive is back
    assert.equal(rig.paths('keyframe').length, 3);
    assert.deepEqual([cell.coverage.kind, cell.coverage.playing], ['recorded', false]);
    assert.equal(rig.surface().presents().length, shown + 1, 'the playhead is shown again, paused');
    await settle(20_000);
    assert.equal(rig.paths('keyframe').length, 3, 'no more probing once the drive is back');
  });

  it('a newer desire ends the probing: a picture that is held needs no disk', async () => {
    const { rig, cell, want, settle } = await ready({ cellOptions: { getPause: () => 'folderMissing' } });
    want(at(6, 500));
    await settle();
    rig.api.failWhen(`fragments/${FILE_A}.20`, () => new ApiError(410, 'gone', 'Removed.'), { times: 100 });
    want(at(20, 500));
    await settle(1000);
    assert.equal(cell.coverage.kind, 'driveMissing');
    want(at(6, 700));                                                    // inside what is held: no request at all
    await settle(1000);
    assert.equal(cell.coverage.kind, 'recorded');
    const before = rig.requests().length;
    await settle(30_000);
    assert.equal(rig.requests().length, before, 'the probe timer was cancelled by the newer desire');
  });

  it('a corrupt part (502) is unreadable and the neighbours still play when asked for', async () => {
    const { rig, cell, want, settle } = await ready();
    rig.api.failWhen(`fragments/${FILE_A}.5`, () => new ApiError(502, 'unreadable', 'Corrupt.'), { times: 1 });
    want(at(6, 500));
    await settle();
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['unreadable', MESSAGES.unreadable]);
    want(at(20, 500));
    await settle();
    assert.equal(cell.coverage.kind, 'recorded');
  });

  it('overload (429) shows Loading and tries again later instead of an error', async () => {
    const { rig, cell, want, settle } = await ready();
    rig.api.failWhen('keyframe', () => new ApiError(429, 'busy', 'Busy.', null, { retryAfter: 0 }), { times: 4 });
    want(at(6, 500), 'key');
    await settle(300);
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['loading', MESSAGES.busy]);
    await settle(3000);
    assert.equal(cell.coverage.kind, 'recorded');
    assert.equal(rig.paths('keyframe').length, 5);
  });

  it('keeps asking only a bounded number of times while overloaded, then gives up with the busy sentence', async () => {
    const { rig, cell, want, settle } = await ready();
    rig.api.failWhen('keyframe', () => new ApiError(429, 'busy', 'Busy.', null, { retryAfter: 0 }), { times: 1000 });
    want(at(6, 500), 'key');
    await settle(30_000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['unreadable', MESSAGES.busy]);
    assert.equal(rig.paths('keyframe').length, 16, '4 tries x (1 + 3 later attempts)');
  });

  it('a lost connection or a stuck request is the sentence about the bridge, not a crash', async () => {
    const { rig, cell, want, settle } = await ready();
    rig.api.failWhen('keyframe', () => new ApiError(0, 'timeout', 'Too long.'), { times: 1 });
    want(at(6, 500), 'key');
    await settle();
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['unreadable', MESSAGES.network]);
  });

  it('a codec this browser cannot play is an unsupported tile that says why', async () => {
    const files = [{ key: FILE_A, startMs: ORIGIN, parts: 20, gop: 4, mime: 'video/mp4; codecs="hvc1.1.6.L153.B0"' }];
    const rig = createRig({ cameras: [{ id: 'CAM-1', files }], surfaceOptions: { unsupported: (mime) => mime.includes('hvc1') } });
    await rig.start();
    const cell = rig.makeCell();
    desirer(cell)(at(6, 500), 'key');
    await rig.timers.advance(600);
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['unsupported', MESSAGES.cannotPlayHEVC]);
  });

  it('a 401 is left to the page (it signs out) and leaves the tile as it was', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(6, 500));
    await settle();
    rig.api.failWhen('keyframe', () => new ApiError(401, 'unauthorized', 'Sign in.'), { times: 1 });
    want(at(30, 500), 'key');
    await settle();
    assert.notEqual(cell.coverage.kind, 'unreadable', 'no error sentence: the page is already signing out');
    assert.equal(rig.surface().presents().length, 1);
  });

  it('a seek that shows nothing rebuilds the buffer once and starts over; the second time it is unreadable', async () => {
    const { rig, cell, want, settle } = await ready({ surfaceOptions: { holdBackMs: 100_000 } });      // no seek can ever show a picture
    want(at(6, 500));
    await settle(3000);
    const surface = rig.surface();
    assert.equal(surface.log.filter((entry) => entry.op === 'reset').length, 1);
    assert.deepEqual([cell.coverage.kind, cell.coverage.message], ['unreadable', MESSAGES.unreadable]);
  });
});

describe('loading', () => {
  it('says Loading after 300 ms without a picture, then shows the picture', async () => {
    const { rig, cell, want, settle } = await ready({ latency: (kind) => (kind === 'bytes' ? 400 : 10) });
    const seen = [];
    cell.onChange((coverage) => seen.push(coverage.kind));
    want(at(6, 500), 'key');
    await settle(250);
    assert.deepEqual(seen, []);
    await settle(100);
    assert.deepEqual(seen, ['loading']);
    await settle(1500);
    assert.deepEqual(seen, ['loading', 'recorded']);
  });

  it('never says Loading during a quick drag', async () => {
    const { rig, cell, want, settle } = await ready();
    const seen = [];
    cell.onChange((coverage) => seen.push(coverage.kind));
    for (let i = 0; i < 40; i += 1) {
      want(at(i % 50, 500), 'key');
      await settle(40);
    }
    assert.ok(!seen.includes('loading'));
  });
});

describe('playing', () => {
  it('plays after the exact frame, then keeps the buffer fed with the parts that follow', async () => {
    const { rig, cell, want, settle } = await ready();
    const target = at(6, 500);
    rig.clock.scrub(target);
    want(target, 'exact', true);
    await settle(600);
    const surface = rig.surface();
    assert.equal(surface.playing, true);
    assert.deepEqual([cell.coverage.kind, cell.coverage.playing], ['recorded', true]);
    rig.clock.play(target);
    await settle(60_000);                                              // a minute of playing
    assert.equal(surface.stalledMs, 0, 'the buffer never ran dry');
    assert.ok(surface.seeks().every((s) => s.presented));
    const ids = surface.appends().map((a) => Number(a.id.split('.')[1]));
    assert.deepEqual(ids, ids.map((_, i) => ids[0] + i), 'every part once, in order');
    assert.ok(surface.appends().slice(1).every((a) => a.chainBreak === false), 'one chain, no breaks');
    assert.ok(ids.at(-1) >= 6 + 30, 'it kept up with a minute of video');
    assert.equal(rig.paths('fragments?after').every((p) => p.endsWith('&limit=4')), true);
  });

  it('plays across a gap of a second or more by reporting it, so the page can jump', async () => {
    const { rig, cell, want, settle } = await ready();
    const target = ORIGIN + 112_000;                                   // 8 s before the end of file A
    rig.clock.scrub(target);
    want(target, 'exact', true);
    await settle(600);
    rig.clock.play(target);
    await settle(20_000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.next], ['gap', ORIGIN + 140_000]);
    const surface = rig.surface();
    const nextFile = surface.appends().filter((a) => a.id.startsWith(FILE_B));
    assert.ok(nextFile.length > 0, 'file B was prefetched as a new chain');
    assert.equal(nextFile[0].chainBreak, true);
    assert.equal(nextFile[0].key, true);
  });

  it('a waiting event while seconds are still buffered is not the end of the recording', async () => {
    const { rig, cell, want, settle } = await ready();
    const target = ORIGIN + 114_000;                                   // 6 s before the end of file A; file B is prefetched as a second chain
    rig.clock.scrub(target);
    want(target, 'exact', true);
    await settle(600);
    rig.clock.play(target);
    await settle(3000);
    rig.surface().emit('waiting');
    rig.surface().emit('waiting');
    await settle(1500);
    assert.deepEqual([cell.coverage.kind, cell.coverage.playing], ['recorded', true], 'the playhead is 3 s from the end of what is held');
    await settle(10_000);
    assert.deepEqual([cell.coverage.kind, cell.coverage.next], ['gap', ORIGIN + 140_000], 'at the end of file A it is a gap');
  });

  describe('another codec string in the next file', () => {
    const MIME_2 = 'video/mp4; codecs="avc1.640033"';
    const twoCodecs = (gapMs) => [
      { key: FILE_A, startMs: ORIGIN, parts: 10, gop: 4 },
      { key: FILE_B, startMs: ORIGIN + 20_000 + gapMs, parts: 10, gop: 1, mime: MIME_2 },
    ];

    it('is not opened while the old one still plays; the cell restarts at the next recording when the playhead gets there', async () => {
      const { rig, cell, want, settle } = await ready({ cameras: [{ id: 'CAM-1', files: twoCodecs(0) }] });
      const target = ORIGIN + 14_000;                                    // 6 s before the end of file A
      rig.clock.scrub(target);
      want(target, 'exact', true);
      await settle(600);
      rig.clock.play(target);
      await settle(3000);
      const surface = rig.surface();
      assert.equal(surface.generation, 0, 'the MediaSource is still the one that plays file A');
      assert.equal(surface.appends().some((a) => a.id.startsWith(FILE_B)), false);
      await settle(6000);
      assert.equal(surface.generation, 1, 'rebuilt at the boundary');
      assert.equal(surface.mime, MIME_2);
      assert.ok(surface.appends().some((a) => a.id === `${FILE_B}.0` && a.chainBreak && a.key));
      assert.deepEqual([cell.coverage.kind, cell.coverage.playing], ['recorded', true]);
      assert.ok(surface.seeks().every((seek) => seek.presented));
    });

    it('a hole before the new codec is reported as a gap, with the next recording, and nothing is rebuilt', async () => {
      const { rig, cell, want, settle } = await ready({ cameras: [{ id: 'CAM-1', files: twoCodecs(5000) }] });
      const target = ORIGIN + 14_000;
      rig.clock.scrub(target);
      want(target, 'exact', true);
      await settle(600);
      rig.clock.play(target);
      await settle(9000);
      assert.deepEqual([cell.coverage.kind, cell.coverage.next], ['gap', ORIGIN + 25_000]);
      assert.equal(rig.surface().generation, 0);
      rig.clock.play(ORIGIN + 25_000);                                   // what the session does next: the clock jumps and the cell is asked again
      want(ORIGIN + 25_000, 'exact', true);
      await settle(1500);
      assert.equal(rig.surface().generation, 1);
      assert.equal(cell.coverage.kind, 'recorded');
    });

    it('an exact step does not append look-ahead in another codec', async () => {
      const { rig, cell, want, settle } = await ready({ cameras: [{ id: 'CAM-1', files: twoCodecs(0) }] });
      want(ORIGIN + 19_900);
      await settle();
      const surface = rig.surface();
      assert.equal(surface.generation, 0);
      assert.equal(surface.appends().some((a) => a.id.startsWith(FILE_B)), false);
      assert.equal(cell.coverage.kind, 'recorded');
      assert.ok(surface.seeks().every((seek) => seek.presented));
    });
  });

  it('bridges a hole under a second at the end of a buffered range', async () => {
    const files = [{ key: FILE_A, startMs: ORIGIN, parts: 10, gop: 4 }, { key: FILE_B, startMs: ORIGIN + 20_500, parts: 10, gop: 1 }];
    const { rig, cell, want, settle } = await ready({ cameras: [{ id: 'CAM-1', files }] });
    const target = ORIGIN + 14_000;
    rig.clock.scrub(target);
    want(target, 'exact', true);
    await settle(600);
    rig.clock.play(target);
    await settle(12_000);
    const surface = rig.surface();
    assert.ok(surface.appends().some((a) => a.id.startsWith(FILE_B)), 'the next file was appended');
    const nudges = surface.seeks().filter((s) => s.sec > bufferSeconds(ORIGIN + 20_000, rig.base()));
    assert.ok(nudges.length >= 1, 'the playhead was moved over the hole');
    assert.notEqual(cell.coverage.kind, 'gap');
  });

  it('seeks again when the video drifts from the clock by more than 400 ms', async () => {
    const { rig, cell, want, settle } = await ready();
    const target = at(6, 500);
    rig.clock.scrub(target);
    want(target, 'exact', true);
    await settle(600);
    rig.clock.play(target + 10_000);                                   // the clock jumped ahead of the video
    await settle(2500);
    const last = rig.surface().presents().at(-1);
    assert.ok(Math.abs(last.sec - bufferSeconds(rig.clock.position(), rig.base())) < 2.5, `the picture follows the clock (${last.sec})`);
    assert.ok(rig.surface().presents().length >= 2);
  });

  it('a newer desire stops the follow loop and its requests', async () => {
    const { rig, cell, want, settle } = await ready();
    rig.clock.scrub(at(6, 500));
    want(at(6, 500), 'exact', true);
    await settle(600);
    want(at(30, 500), 'exact', false);
    await settle(600);
    const before = rig.requests().length;
    await settle(30_000);
    assert.equal(rig.requests().length, before, 'paused: nothing more is fetched');
    assert.equal(rig.surface().playing, false);
  });
});

describe('suspend, resume, destroy', () => {
  it('suspend pauses and stops requests; resume does the current desire again', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(6, 500));
    await settle();
    cell.suspend();
    assert.equal(rig.surface().playing, false);
    want(at(30, 500));
    await settle();
    assert.equal(rig.surface().presents().length, 1, 'suspended: the new desire waits');
    cell.resume();
    await settle();
    assert.equal(rig.surface().presents().length, 2);
    assert.equal(rig.surface().presents().at(-1).sec, bufferSeconds(at(30, 500), rig.base()));
  });

  it('destroy destroys the surface, stops the worker and ignores later requests', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(6, 500));
    await settle();
    const requests = rig.requests().length;
    cell.destroy();
    assert.ok(rig.surface().destroyed);
    want(at(30, 500));
    await settle(5000);
    assert.equal(rig.requests().length, requests);
    cell.destroy();
  });

  it('a cell that never got a desire never builds a surface or touches its stage', async () => {
    const { rig, cell } = await ready();
    assert.deepEqual(rig.stages.get('CAM-1').children, []);
    cell.destroy();
    assert.equal(rig.surfaces.size, 0);
    assert.deepEqual(rig.stages.get('CAM-1').children, []);
  });
});

describe('the stage', () => {
  it('on its first request the cell puts a muted video and a hold canvas in the stage, and gives the surface exactly those and holdFrom', async () => {
    const { rig, cell, want, settle } = await ready();
    const stage = rig.stages.get('CAM-1');
    want(at(6, 500), 'key');
    await settle();
    assert.deepEqual(stage.children.map((child) => child.tag), ['video', 'canvas']);
    const [video, canvas] = stage.children;
    assert.deepEqual([video.muted, video.playsInline, video.attributes.playsinline], [true, true, '']);
    assert.deepEqual(Object.keys(rig.surface().elements).sort(), ['holdCanvas', 'holdFrom', 'video']);
    assert.equal(rig.surface().elements.holdFrom(), null, 'a picture that is not straightened: the hold is the video’s own frame');
    assert.equal(rig.surface().elements.video, video);
    assert.equal(rig.surface().elements.holdCanvas, canvas);
    want(at(8, 500), 'key');
    await settle();
    assert.equal(stage.children.length, 2, 'one pair of elements for the life of the cell');
  });

  it('a stage that is { video, holdCanvas } is used as it is and left in place', async () => {
    const { rig, settle } = await ready();
    const own = { video: fakeElement('video'), holdCanvas: fakeElement('canvas') };
    const mine = rig.makeCell('CAM-1', { stage: own });
    desirer(mine)(at(6, 500), 'key');
    await settle();
    assert.equal(rig.surface().elements.video, own.video);
    assert.equal(rig.surface().elements.holdCanvas, own.holdCanvas);
    assert.equal(rig.stages.get('CAM-1').children.length, 0, 'nothing was appended anywhere');
    mine.destroy();
    assert.deepEqual([own.video.removed, own.holdCanvas.removed], [false, false]);
  });

  it('destroy removes them again', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(6, 500), 'key');
    await settle();
    cell.destroy();
    assert.deepEqual(rig.stages.get('CAM-1').children, []);
  });
});

describe('time arithmetic end to end', () => {
  it('every append lands where the plan says: the fake surface checks tfdt + timestampOffset against the cell\'s own idea of each part', async () => {
    const { rig, cell, want, settle } = await ready();
    want(at(6, 500));
    await settle();
    want(at(36, 500));
    await settle();
    want(ORIGIN + 150_000);
    await settle();
    assert.equal(rig.surface().appends().length > 6, true);
    const info = rig.archive.fileInfo(FILE_A, 'x');
    assert.equal(timestampOffsetSeconds(info.anchor, rig.base()) > 0, true);
  });
});

describe('the init after a break', () => {
  it('is left to the surface: the cell appends an init only when the file changes, whatever initAfterBreak says', async () => {
    const { rig, cell, want, settle } = await ready({ cellOptions: { policy: { ...DEFAULT_POLICY, initAfterBreak: true } } });
    want(at(4, 100), 'key');
    await settle();
    want(at(20, 100), 'key');                                         // a chain far away: a break
    await settle();
    want(at(6, 500), 'exact');                                        // the first GOP starts over: another break
    await settle();
    assert.deepEqual(rig.surface().ops().filter((op) => op === 'appendInit'), ['appendInit'], 'one init for the one file');
    assert.deepEqual(rig.surface().appends().map((a) => `${a.id.split('.')[1]}${a.chainBreak ? '!' : ''}`), ['4!', '20!', '4!', '5', '6', '7']);
    assert.equal(cell.coverage.kind, 'recorded');
  });
});

// MARK: Straightened pictures

describe('straightening', () => {
  const BACKYARD = { straighten: 0.4, level: 0.15 };
  const OFF = { straighten: 0, level: 0 };
  const tags = (stage) => stage.children.map((child) => `${child.localName}${child.className ? `.${child.className.split(' ').join('.')}` : ''}`);

  /** The rig in a fake browser whose canvases record what is drawn on them (no WebGL: a view draws through the strip plan). */
  async function inBrowser(run) {
    const browser = installFakeBrowser();
    recordingCanvases(browser.document);
    try {
      await run(await ready());
    } finally {
      browser.restore();
    }
  }

  it('a playback cell of a corrected camera straightens its video and its hold picture', () => inBrowser(async ({ rig, settle }) => {
    // the hold canvas is drawn from the straightened canvas, not the raw video
    const stage = document.createElement('div');
    const asked = [];
    const cell = rig.makeCell('CAM-1', { stage, getCorrection: (id) => { asked.push(id); return BACKYARD; } });
    desirer(cell)(at(6, 500), 'key');
    await settle();
    assert.deepEqual(asked, ['CAM-1'], 'the correction is read when the video is made');
    assert.deepEqual(tags(stage), ['video.straighten-source', 'canvas.straightened', 'canvas'], 'the straightened canvas over the video, under the hold');
    const [video, canvas, holdCanvas] = stage.children;
    assert.equal(rig.surface().elements.holdCanvas, holdCanvas);
    givePicture(video);

    // What the surface copies when it builds its buffer again: the straightened canvas, drawn that moment (a WebGL canvas can only be
    // copied right after a draw), so the tile never shows the bent picture while it waits.
    const { holdFrom } = rig.surface().elements;
    let from = canvas.getContext('2d').draws.length;
    assert.equal(holdFrom(), canvas);
    assert.deepEqual(drawnFrom(canvas, video, from), planCalls(BACKYARD, 640, 284));

    // The camera's correction changes (saved on its page): the same canvas follows it.
    const moved = { straighten: -0.2, level: 0.1 };
    from = canvas.getContext('2d').draws.length;
    cell.setCorrection(moved);
    assert.equal(siblingAfter(video), canvas);
    assert.deepEqual(drawnFrom(canvas, video, from), planCalls(moved, 640, 284));

    cell.setCorrection(OFF);
    assert.deepEqual(tags(stage), ['video', 'canvas'], 'off: the video as it is');
    assert.equal(holdFrom(), null, 'and the hold copies the video');
    cell.setCorrection(BACKYARD);
    assert.deepEqual(tags(stage), ['video.straighten-source', 'canvas.straightened', 'canvas'], 'on again, under the hold');
    assert.equal(holdFrom(), stage.children[1]);

    cell.destroy();
    assert.deepEqual(stage.children, [], 'the cell takes everything away with it');
    cell.setCorrection(moved);
    assert.deepEqual(stage.children, []);
  }));

  it('a camera that is not straightened gets nothing over its video, and a caller’s own video is the caller’s to straighten', () => inBrowser(async ({ rig, settle }) => {
    const stage = document.createElement('div');
    const plain = rig.makeCell('CAM-1', { stage, getCorrection: () => null });
    desirer(plain)(at(6, 500), 'key');
    await settle();
    assert.deepEqual(tags(stage), ['video', 'canvas']);
    assert.equal(rig.surface().elements.holdFrom(), null);
    plain.destroy();

    const own = { video: document.createElement('video'), holdCanvas: document.createElement('canvas') };
    stage.append(own.video, own.holdCanvas);
    const theirs = rig.makeCell('CAM-1', { stage: own, getCorrection: () => BACKYARD });
    desirer(theirs)(at(6, 500), 'key');
    await settle();
    assert.equal(rig.surface().elements.video, own.video);
    assert.deepEqual(tags(stage), ['video', 'canvas'], 'the watch screen layers its own picture');
    theirs.destroy();
  }));

  it('the watch screen straightens a corrected camera\'s recording', async () => {
    const browser = installFakeBrowser();
    recordingCanvases(browser.document);
    globalThis.ResizeObserver = class { observe() {} disconnect() {} };      // the timeline's
    globalThis.Image = class { set src(value) { this.value = value; } get src() { return this.value; } };     // the preview's snapshots
    const { store, putCamera } = await import('../web/js/store.js');
    const { renderWatch } = await import('../web/js/screens/watch.js');
    const id = 'AAAAAAAA-0000-4000-8000-00000000000A';
    store.cameras.set(id, { id, name: 'Backyard', isEnabled: true, nvrEnabled: true, status: { connection: 'online' }, pictureCorrection: BACKYARD });
    const page = renderWatch({ params: [id], navigate() {}, setTitle() {} });
    try {
      const stage = page.el.childNodes.find((node) => node.classList?.contains('watch-stage'));
      const video = stage.childNodes.find((node) => node.localName === 'video');
      const canvas = siblingAfter(video);
      assert.equal(canvas.localName, 'canvas');
      assert.equal(canvas.className, 'watch-video straightened', 'the video’s classes: the stage’s layers show it as they show the video');
      assert.ok(video.classList.contains('straighten-source'));
      assert.ok(siblingAfter(canvas).classList.contains('watch-hold'), 'under the hold picture');

      givePicture(video);
      const moved = { straighten: -0.2, level: 0.1 };
      let from = canvas.getContext('2d').draws.length;
      putCamera({ ...store.cameras.get(id), pictureCorrection: moved });      // saved on the camera's page
      assert.equal(siblingAfter(video), canvas, 'the same canvas');
      assert.deepEqual(drawnFrom(canvas, video, from).slice(0, planCalls(moved, 640, 284).length), planCalls(moved, 640, 284), 'drawn at once with it');
      from = canvas.getContext('2d').draws.length;
      putCamera({ ...store.cameras.get(id), status: { connection: 'online', summary: 'Recording' } });     // news that is not about it
      assert.equal(canvas.getContext('2d').draws.length, from, 'news that leaves the correction alone draws nothing');

      putCamera({ ...store.cameras.get(id), pictureCorrection: OFF });
      assert.notEqual(siblingAfter(video)?.className, 'watch-video straightened', 'off: no canvas');
      assert.equal(video.classList.contains('straighten-source'), false);
      putCamera({ ...store.cameras.get(id), pictureCorrection: BACKYARD });
      assert.equal(siblingAfter(video).className, 'watch-video straightened', 'on again');
    } finally {
      page.destroy();
      store.cameras.delete(id);
      delete globalThis.ResizeObserver;
      delete globalThis.Image;
      browser.restore();
    }
    const stage = page.el.childNodes.find((node) => node.classList?.contains('watch-stage'));
    assert.deepEqual(stage.children.filter((node) => node.classList.contains('straightened')), [], 'leaving the screen takes it away');
  });
});
