// surface.js: one MediaSource and SourceBuffer per tile, against a fake media stack.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_POLICY, MESSAGES, bufferSeconds, timestampOffsetSeconds } from '../web/js/nvr/planner.js';
import { MseSurface } from '../web/js/nvr/surface.js';
import { FILE_A, FILE_B, MIME, ORIGIN, createArchive } from './player-fakes/fake-archive.mjs';
import { createFakeMedia } from './player-fakes/fake-mse.mjs';
import { createFakeTimers } from './player-fakes/fake-timers.mjs';

const BASE = ORIGIN - 400 * 86_400_000;
const MIME_2 = 'video/mp4; codecs="avc1.640033"';
const MIB = 1_048_576;
// T06 chose the jump protocol abort + offset + init for every browser class; `initAfterBreak` says so in the policy. These two pin both modes.
const KEEP_INIT = Object.freeze({ ...DEFAULT_POLICY, initAfterBreak: false });
const REINIT = Object.freeze({ ...DEFAULT_POLICY, initAfterBreak: true });

function setup({ managed = false, policy, budget, canvas = true, quotaBytes = null, needInitAfterAbort = false } = {}) {
  const timers = createFakeTimers();
  const media = createFakeMedia({ timers, managed, quotaBytes, needInitAfterAbort });
  const archive = createArchive({
    timers,
    files: [{ key: FILE_A, startMs: ORIGIN, parts: 40, gop: 2 }, { key: FILE_B, startMs: ORIGIN + 200_000, parts: 10, gop: 1 }],
  });
  const surface = new MseSurface({ video: media.video, holdCanvas: canvas ? media.canvas : null, timers, scope: media.scope, policy, budgetBytes: budget });
  const drive = async (promise, ms = 200) => (await Promise.all([promise, timers.advance(ms)]))[0];
  const part = (file, index) => archive.byId(`${file}.${index}`);
  const offsetOf = (file) => timestampOffsetSeconds(archive.fileInfo(file, 'x').anchor, BASE);
  const pad = (buffer, size) => { const out = new Uint8Array(size).fill(32); out.set(new Uint8Array(buffer)); return out; };
  const feed = (file, index, { chainBreak = false, size = 0 } = {}) => {
    const p = part(file, index);
    const raw = archive.mediaBytes(p);
    return surface.append(size ? pad(raw, size) : raw, {
      timestampOffsetSec: offsetOf(file), chainBreak, startSec: bufferSeconds(p.start, BASE), endSec: bufferSeconds(p.end, BASE), key: p.key,
    });
  };
  return { timers, media, archive, surface, drive, part, offsetOf, feed, sb: () => media.sourceBuffer(), sec: (ms) => bufferSeconds(ms, BASE) };
}

async function opened(options) {
  const ctx = setup(options);
  await ctx.drive(ctx.surface.open(MIME));
  await ctx.drive(ctx.surface.appendInit(ctx.archive.initBytes(FILE_A)));
  return ctx;
}

describe('isSupported', () => {
  it('asks MediaSource, then ManagedMediaSource, and is false without either', () => {
    const only = (name) => ({ [name]: { isTypeSupported: (mime) => mime.includes('avc1') } });
    assert.equal(MseSurface.isSupported(MIME, only('MediaSource')), true);
    assert.equal(MseSurface.isSupported('video/mp4; codecs="hvc1.1.6.L93.B0"', only('MediaSource')), false);
    assert.equal(MseSurface.isSupported(MIME, only('ManagedMediaSource')), true);
    assert.equal(MseSurface.isSupported(MIME, {}), false);
    assert.equal(MseSurface.isSupported(MIME, { MediaSource: {} }), false);
  });
});

describe('open', () => {
  it('builds the source, revokes the object URL after it opened, and uses segments mode', async () => {
    const { surface, media, drive } = setup();
    await drive(surface.open(MIME));
    assert.equal(media.owner.mediaSources.length, 1);
    assert.equal(media.owner.revoked.length, 1);
    assert.equal(media.owner.revoked[0], media.owner.urls.keys().next().value);
    assert.equal(media.sourceBuffer().mode, 'segments');
    assert.equal(media.sourceBuffer().mime, MIME);
    assert.deepEqual([media.video.muted, media.video.playsInline, media.video.disableRemotePlayback], [true, true, true]);
    assert.deepEqual([surface.generation, surface.mime], [0, MIME]);
    assert.equal(media.canvas.style.display, 'none');
  });

  it('opening the same codec again does nothing', async () => {
    const { surface, media, drive } = setup();
    await drive(surface.open(MIME));
    await drive(surface.open(MIME));
    assert.equal(media.owner.mediaSources.length, 1);
    assert.equal(surface.generation, 0);
  });

  it('a codec the browser cannot play is an Unsupported error that says so, and builds nothing', async () => {
    const { surface, media, drive } = setup();
    await assert.rejects(drive(surface.open('video/mp4; codecs="hvc1.1.6.L153.B0"')), (error) => {
      assert.equal(error.name, 'Unsupported');
      assert.equal(error.message, MESSAGES.cannotPlayHEVC);
      return true;
    });
    assert.equal(media.owner.mediaSources.length, 0);
  });

  it('works through ManagedMediaSource when that is all there is', async () => {
    const { surface, media, drive } = setup({ managed: true });
    await drive(surface.open(MIME));
    assert.equal(media.owner.mediaSources.length, 1);
    assert.equal(media.video.disableRemotePlayback, true);
  });

  it('gives up when the source never opens', async () => {
    const { surface, media, drive } = setup();
    media.owner.neverOpen = true;
    await assert.rejects(drive(surface.open(MIME), 3500), (error) => error.message === MESSAGES.playerFailed);
  });

  it('refuses to append before it is open', async () => {
    const { surface, drive, archive } = setup();
    await assert.rejects(drive(surface.appendInit(archive.initBytes(FILE_A))), /not open/);
  });
});

describe('append', () => {
  it('a chain break is abort, then the offset, then the bytes; a contiguous part needs neither', async () => {
    const ctx = await opened({ policy: KEEP_INIT });
    const { sb, feed, drive, offsetOf } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    await drive(feed(FILE_A, 5));
    await drive(feed(FILE_A, 6));
    await drive(feed(FILE_A, 20, { chainBreak: true }));
    assert.deepEqual(sb().ops.map((o) => o.op === 'append' ? `append ${o.id}` : o.op), [
      'appendInit', 'abort', `append ${FILE_A}.4`, `append ${FILE_A}.5`, `append ${FILE_A}.6`, 'abort', `append ${FILE_A}.20`,
    ]);
    assert.ok(sb().ops.filter((o) => o.op === 'append').every((o) => o.offset === offsetOf(FILE_A)), 'the offset was in place at every append');
    assert.equal(sb().timestampOffset, offsetOf(FILE_A));
  });

  it('a different timestamp offset (another file) resets the parser even without chainBreak', async () => {
    const ctx = await opened({ policy: KEEP_INIT });
    const { sb, feed, drive, offsetOf, archive } = ctx;
    await drive(feed(FILE_A, 38, { chainBreak: true }));
    await drive(feed(FILE_A, 39));
    await drive(ctx.surface.appendInit(archive.initBytes(FILE_B)));
    await drive(feed(FILE_B, 0));
    assert.deepEqual(sb().ops.map((o) => o.op), ['appendInit', 'abort', 'append', 'append', 'appendInit', 'abort', 'append']);
    assert.equal(sb().timestampOffset, offsetOf(FILE_B));
    assert.notEqual(offsetOf(FILE_A), offsetOf(FILE_B));
    assert.deepEqual(sb().initFiles, [FILE_A, FILE_B]);
  });

  it('with initAfterBreak the init is appended again behind the abort and the offset, then the bytes (T06: abort + offset + init)', async () => {
    const ctx = await opened({ policy: REINIT });
    const { sb, feed, drive, offsetOf } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    await drive(feed(FILE_A, 5));
    await drive(feed(FILE_A, 20, { chainBreak: true }));
    assert.deepEqual(sb().ops.map((o) => o.op === 'append' ? `append ${o.id}` : o.op), [
      'appendInit', 'abort', 'appendInit', `append ${FILE_A}.4`, `append ${FILE_A}.5`, 'abort', 'appendInit', `append ${FILE_A}.20`,
    ]);
    const repeated = sb().ops.filter((o, i, all) => o.op === 'appendInit' && all[i - 1]?.op === 'abort');
    assert.equal(repeated.length, 2);
    assert.ok(repeated.every((o) => o.file === FILE_A && o.offset === offsetOf(FILE_A)), 'the offset was in place before each repeated init');
    assert.deepEqual(sb().initFiles, [FILE_A, FILE_A, FILE_A]);
  });

  it('with initAfterBreak a file that starts where the last one ended gets its own init once more behind the abort', async () => {
    const ctx = await opened({ policy: REINIT });
    const { sb, feed, drive, offsetOf, archive } = ctx;
    await drive(feed(FILE_A, 38, { chainBreak: true }));
    await drive(feed(FILE_A, 39));
    await drive(ctx.surface.appendInit(archive.initBytes(FILE_B)));
    await drive(feed(FILE_B, 0));
    assert.deepEqual(sb().ops.map((o) => o.op), ['appendInit', 'abort', 'appendInit', 'append', 'append', 'appendInit', 'abort', 'appendInit', 'append']);
    assert.deepEqual(sb().initFiles, [FILE_A, FILE_A, FILE_B, FILE_B]);
    assert.equal(sb().ops.at(-1).offset, offsetOf(FILE_B));
  });

  it('a browser that wants the init again after abort() fails a chain break without initAfterBreak, and plays it with it', async () => {
    const picky = await opened({ policy: KEEP_INIT, needInitAfterAbort: true });
    await picky.drive(picky.feed(FILE_A, 4, { chainBreak: true }).then(() => 'appended', (error) => error.name), 50).then((outcome) => assert.equal(outcome, 'InvalidStateError'));
    const fixed = await opened({ policy: REINIT, needInitAfterAbort: true });
    await fixed.drive(fixed.feed(FILE_A, 4, { chainBreak: true }));
    await fixed.drive(fixed.feed(FILE_A, 5));
    await fixed.drive(fixed.feed(FILE_A, 20, { chainBreak: true }));
    assert.deepEqual(fixed.sb().ranges.length, 2);
  });

  it('a rebuilt source forgets the old init: only an init appended to the new buffer is repeated behind a break', async () => {
    const ctx = await opened({ policy: REINIT });
    const { sb, surface, drive, feed, archive } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    await drive(surface.open(MIME_2));
    await drive(surface.appendInit(archive.initBytes(FILE_B)));
    await drive(feed(FILE_B, 0, { chainBreak: true }));
    assert.deepEqual(sb().ops.map((o) => o.op), ['appendInit', 'abort', 'appendInit', 'append']);
    assert.deepEqual(sb().initFiles, [FILE_B, FILE_B]);
  });

  it('a break before any init was appended repeats nothing', async () => {
    const ctx = setup({ policy: REINIT });
    await ctx.drive(ctx.surface.open(MIME));
    await ctx.drive(ctx.feed(FILE_A, 4, { chainBreak: true }));
    assert.deepEqual(ctx.sb().ops.map((o) => o.op), ['abort', 'append']);
  });

  it('puts every part on the shared time line: tfdt + offset = (epoch ms - base) / 1000', async () => {
    const ctx = await opened();
    const { sb, feed, drive, sec, part } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    await drive(feed(FILE_A, 5));
    const [range] = sb().ranges;
    assert.ok(Math.abs(range.start - sec(part(FILE_A, 4).start)) < 1e-6);
    assert.ok(Math.abs(range.end - sec(part(FILE_A, 5).end)) < 1e-6);
    assert.deepEqual(ctx.surface.held(), [range]);
  });

  it('never has two operations on the SourceBuffer at once', async () => {
    const ctx = await opened();
    const { feed, drive, sb } = ctx;
    const all = [feed(FILE_A, 4, { chainBreak: true }), feed(FILE_A, 5), feed(FILE_A, 6), feed(FILE_A, 7), ctx.surface.evict(0)];
    await drive(Promise.all(all), 500);
    assert.deepEqual(sb().ops.filter((o) => o.op === 'append').map((o) => o.id), [4, 5, 6, 7].map((i) => `${FILE_A}.${i}`));
  });

  it('a SourceBuffer error fails the append with the player sentence and the queue goes on', async () => {
    const ctx = await opened();
    const { feed, drive } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    const failing = feed(FILE_A, 5);
    const later = feed(FILE_A, 6);
    await ctx.timers.advance(0);
    ctx.sb().dispatchEvent(new Event('error'));
    await assert.rejects(drive(failing), (error) => error.message === MESSAGES.playerFailed);
    await drive(later);
  });
});

describe('seek', () => {
  it('resolves presented when a frame near the target is shown', async () => {
    const ctx = await opened();
    const { feed, drive, surface, sec, part, media } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    const target = sec(part(FILE_A, 4).start + 1);
    const result = await drive(surface.seek(target));
    assert.equal(result.presented, true);
    assert.equal(result.via, 'frame-callback');
    assert.equal(media.video.currentTime, target);
    assert.ok(Math.abs(result.mediaTime - target) < 1e-9);
  });

  it('ignores a frame far from the target and waits for the right one', async () => {
    const ctx = await opened();
    const { feed, drive, surface, sec, part, media, timers } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    media.video.autoPresent = false;
    const target = sec(part(FILE_A, 4).start + 1);
    let result = null;
    surface.seek(target).then((value) => { result = value; });
    await timers.advance(20);
    media.video.presentFrame(target - 40);                           // the old picture
    await timers.advance(1);
    assert.equal(result, null);
    media.video.presentFrame(target + 0.04);
    await timers.advance(1);
    assert.equal(result.presented, true);
  });

  it('fails after 1.5 s without a frame (the target is not in the buffer, so the video never has data)', async () => {
    const ctx = await opened();
    const { feed, drive, surface, sec, part, media, timers } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    media.video.autoPresent = false;
    let result = null;
    surface.seek(sec(part(FILE_A, 30).start + 1)).then((value) => { result = value; });
    await timers.advance(1499);
    assert.equal(result, null);
    await timers.advance(1);
    assert.deepEqual(result, { presented: false, mediaTime: null, via: 'timeout' });
  });

  it('when no frame callback comes after `seeked` (the same frame was already shown) it counts once the video has data', async () => {
    const ctx = await opened();
    const { feed, drive, surface, sec, part, media, timers } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    media.video.autoPresent = false;
    let result = null;
    surface.seek(sec(part(FILE_A, 4).start + 1)).then((value) => { result = value; });
    await timers.advance(100);
    assert.equal(result, null, 'seeked fired at 5 ms; the fallback waits 250 ms');
    await timers.advance(200);
    assert.equal(result.presented, true);
    assert.equal(result.via, 'seeked');
  });

  it('without requestVideoFrameCallback it waits for `seeked` and two animation frames', async () => {
    const ctx = await opened();
    const { feed, drive, surface, sec, part, media, timers } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    media.video.requestVideoFrameCallback = undefined;
    let result = null;
    surface.seek(sec(part(FILE_A, 4).start + 1)).then((value) => { result = value; });
    await timers.advance(5 + 16);
    assert.equal(result, null);
    await timers.advance(16);
    assert.equal(result.presented, true);
  });

  it('pulls a target just before a held range into it', async () => {
    const ctx = await opened();
    const { feed, drive, surface, sec, part, media } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    const start = sec(part(FILE_A, 4).start);
    await drive(surface.seek(start - 0.1));
    assert.ok(Math.abs(media.video.currentTime - (start + 0.001)) < 1e-6);
    await drive(surface.seek(start - 0.4), 2000);
    assert.ok(Math.abs(media.video.currentTime - (start - 0.4)) < 1e-6, 'farther than 250 ms is left alone');
  });
});

describe('play', () => {
  it('resolves when the first frame after the start was shown', async () => {
    const ctx = await opened();
    const { feed, drive, surface, sec, part, media } = ctx;
    await drive(feed(FILE_A, 4, { chainBreak: true }));
    await drive(surface.seek(sec(part(FILE_A, 4).start + 1)));
    const result = await drive(surface.play());
    assert.equal(result.presented, true);
    assert.equal(media.video.paused, false);
    surface.pause();
    assert.equal(media.video.paused, true);
  });

  it('rejects when the browser refuses to play', async () => {
    const ctx = await opened();
    ctx.media.owner.playError = Object.assign(new Error('blocked'), { name: 'NotAllowedError' });
    await assert.rejects(ctx.drive(ctx.surface.play()), (error) => error.name === 'NotAllowedError');
  });
});

describe('held and events', () => {
  it('held() is empty before the first append, lists ranges after, and is empty after destroy', async () => {
    const ctx = await opened();
    assert.deepEqual(ctx.surface.held(), []);
    await ctx.drive(ctx.feed(FILE_A, 4, { chainBreak: true }));
    assert.equal(ctx.surface.held().length, 1);
    ctx.surface.destroy();
    assert.deepEqual(ctx.surface.held(), []);
  });

  it('forwards waiting, ended and error from the video, and the unsubscribe works', async () => {
    const ctx = await opened();
    const seen = [];
    const off = ctx.surface.onEvent((event) => seen.push(event.type));
    for (const type of ['waiting', 'ended', 'error']) ctx.media.video.dispatchEvent(new Event(type));
    off();
    ctx.media.video.dispatchEvent(new Event('waiting'));
    assert.deepEqual(seen, ['waiting', 'ended', 'error']);
  });

  it('currentTime() is the video position', async () => {
    const ctx = await opened();
    ctx.media.video.currentTime = 12.5;
    assert.equal(ctx.surface.currentTime(), 12.5);
  });
});

describe('memory', () => {
  it('evict() removes whole GOP units, farthest first, never the one under the playhead', async () => {
    const ctx = await opened({ budget: 3 * MIB });
    const { feed, drive, surface, sb, sec, part } = ctx;
    await drive(feed(FILE_A, 0, { chainBreak: true, size: MIB }));
    for (let i = 1; i < 6; i += 1) await drive(feed(FILE_A, i, { size: MIB }));
    // gop = 2: the units are (0,1) (2,3) (4,5) with 2 MiB each; 6 MiB are held, the budget is 3 MiB, the playhead is in part 2.
    await drive(surface.evict(sec(part(FILE_A, 2).start + 500)));
    const unit = (first) => ({ start: sec(part(FILE_A, first).start) - 0.001, end: sec(part(FILE_A, first + 1).end) - 0.001 });
    const near = (a, b) => Math.abs(a - b) < 1e-6;
    const removed = sb().removed;
    assert.equal(removed.length, 2, 'two units must go to get from 6 MiB to 3 MiB or less');
    assert.ok(near(removed[0].start, unit(4).start) && near(removed[0].end, unit(4).end), 'unit (4,5) is the farthest');
    assert.ok(near(removed[1].start, unit(0).start) && near(removed[1].end, unit(0).end), 'then unit (0,1)');
    assert.equal(sb().heldBytes, 2 * MIB);
    assert.equal(surface.held().length, 1);
    await drive(surface.evict(sec(part(FILE_A, 2).start + 500)));
    assert.equal(sb().removed.length, 2, 'under the budget: nothing more');
  });

  it('never removes the unit under the playhead, even when it alone is over the budget', async () => {
    const ctx = await opened({ budget: MIB });
    const { feed, drive, surface, sb, sec, part } = ctx;
    await drive(feed(FILE_A, 0, { chainBreak: true, size: MIB }));
    await drive(feed(FILE_A, 1, { size: MIB }));
    await drive(surface.evict(sec(part(FILE_A, 1).start + 100)));
    assert.deepEqual(sb().removed, []);
  });

  it('forgets what the browser evicted by itself', async () => {
    const ctx = await opened({ budget: 2 * MIB });
    const { feed, drive, surface, sb, sec, part } = ctx;
    await drive(feed(FILE_A, 0, { chainBreak: true, size: MIB }));
    await drive(feed(FILE_A, 1, { size: MIB }));
    await drive(feed(FILE_A, 2, { size: MIB }));
    await drive(feed(FILE_A, 3, { size: MIB }));
    sb().evictByBrowser(sec(part(FILE_A, 0).start), sec(part(FILE_A, 1).end));
    await drive(surface.evict(sec(part(FILE_A, 2).start + 500)));
    assert.deepEqual(sb().removed, [], 'unit (0,1) is gone already and the rest fits');
  });

  it('on QuotaExceededError it makes room around the playhead and tries once more', async () => {
    const ctx = await opened({ budget: 4 * MIB, quotaBytes: 3 * MIB });
    const { feed, drive, sb } = ctx;
    await drive(feed(FILE_A, 0, { chainBreak: true, size: MIB }));
    await drive(feed(FILE_A, 1, { size: MIB }));
    await drive(feed(FILE_A, 2, { size: MIB }));
    await drive(feed(FILE_A, 3, { size: MIB }), 500);
    assert.ok(sb().removed.length >= 1);
    assert.ok(sb().ops.some((o) => o.op === 'append' && o.id === `${FILE_A}.3`));
  });

  it('a second quota error in a row is the caller\'s problem', async () => {
    const ctx = await opened({ budget: 4 * MIB, quotaBytes: 1 });
    await assert.rejects(ctx.drive(ctx.feed(FILE_A, 0, { chainBreak: true, size: MIB }), 500), (error) => error.name === 'QuotaExceededError');
  });
});

describe('changing the codec', () => {
  async function shown(options) {
    const ctx = await opened(options);
    await ctx.drive(ctx.feed(FILE_A, 4, { chainBreak: true }));
    await ctx.drive(ctx.surface.seek(ctx.sec(ctx.part(FILE_A, 4).start + 1)));
    return ctx;
  }

  it('recreate: holds the last frame on the canvas, builds a new source, releases the hold when a frame shows', async () => {
    const ctx = await shown();
    const { surface, media, drive, feed, sec, part, archive } = ctx;
    await drive(surface.open(MIME_2));
    assert.equal(surface.generation, 1);
    assert.equal(surface.mime, MIME_2);
    assert.equal(media.owner.mediaSources.length, 2);
    assert.deepEqual(media.canvas.draws.map((d) => [d.width, d.height]), [[2688, 1520]]);
    assert.equal(media.canvas.style.display, '', 'the held picture is on screen');
    assert.ok(media.video.log.some((entry) => entry.op === 'removeSrc'));
    assert.deepEqual(surface.held(), []);
    await drive(surface.appendInit(archive.initBytes(FILE_B)));
    await drive(feed(FILE_B, 0, { chainBreak: true }));
    await drive(surface.seek(sec(part(FILE_B, 0).start + 1)));
    assert.equal(media.canvas.style.display, 'none');
    assert.equal(media.canvas.width, 0);
  });

  it('recreate without a canvas still works', async () => {
    const ctx = await shown({ canvas: false });
    await ctx.drive(ctx.surface.open(MIME_2));
    assert.equal(ctx.surface.generation, 1);
  });

  it('changeType: keeps the source and the buffer', async () => {
    const ctx = await shown({ policy: { ...DEFAULT_POLICY, mimeChange: 'changeType' } });
    await ctx.drive(ctx.surface.open(MIME_2));
    assert.equal(ctx.surface.generation, 0);
    assert.equal(ctx.media.owner.mediaSources.length, 1);
    assert.ok(ctx.sb().ops.some((o) => o.op === 'changeType' && o.mime === MIME_2));
    assert.equal(ctx.surface.mime, MIME_2);
    assert.equal(ctx.surface.held().length, 1);
    assert.equal(ctx.media.canvas.draws.length, 0);
  });

  it('reset() rebuilds for the same codec behind the held picture', async () => {
    const ctx = await shown();
    await ctx.drive(ctx.surface.reset());
    assert.equal(ctx.surface.generation, 1);
    assert.equal(ctx.surface.mime, MIME);
    assert.equal(ctx.media.canvas.draws.length, 1);
    assert.deepEqual(ctx.surface.held(), []);
  });
});

describe('destroy', () => {
  it('detaches the video, hides the canvas, and refuses everything after', async () => {
    const ctx = await opened();
    await ctx.drive(ctx.feed(FILE_A, 4, { chainBreak: true }));
    ctx.surface.destroy();
    assert.ok(ctx.media.video.log.some((entry) => entry.op === 'removeSrc'));
    assert.ok(ctx.media.video.log.some((entry) => entry.op === 'load'));
    assert.equal(ctx.media.canvas.style.display, 'none');
    await assert.rejects(ctx.surface.open(MIME), (error) => error.name === 'AbortError');
    await assert.rejects(ctx.surface.seek(1), (error) => error.name === 'AbortError');
    ctx.surface.destroy();
  });
});
