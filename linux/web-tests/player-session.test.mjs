// session.js: what a person does becomes desires for the cells, with fake cells and fake timers.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { PlaybackClock } from '../web/js/nvr/clock.js';
import { DEFAULT_POLICY, choosePolicy } from '../web/js/nvr/planner.js';
import { createSession } from '../web/js/nvr/session.js';
import { ORIGIN } from './player-fakes/fake-archive.mjs';
import { createFakeTimers } from './player-fakes/fake-timers.mjs';

const SERVER_AT_ZERO = ORIGIN + 3_600_000;
const IDLE = { kind: 'idle', next: null, message: null, epoch: 0, playing: false, snapMs: null };

function fakeCell(id) {
  const listeners = new Set();
  const cell = {
    id, requests: [], destroyed: false, suspendCalls: 0, resumeCalls: 0, coverage: IDLE,
    request(desire) { cell.requests.push(desire); },
    onChange(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    suspend() { cell.suspendCalls += 1; },
    resume() { cell.resumeCalls += 1; },
    destroy() { cell.destroyed = true; },
    /** The cell reports what it shows (for the epoch of its newest request unless told otherwise). */
    report(patch) {
      cell.coverage = { ...cell.coverage, epoch: cell.requests.at(-1)?.epoch ?? 0, ...patch };
      for (const fn of [...listeners]) fn(cell.coverage);
    },
    last: () => cell.requests.at(-1),
  };
  return cell;
}

function setup({ tileCap, policy = DEFAULT_POLICY, extents = {}, idleMs, settleMs, startWaitMs } = {}) {
  const timers = createFakeTimers();
  const catalog = { serverNow: () => SERVER_AT_ZERO + timers.now(), extent: (id) => extents[id] ?? null };
  const clock = new PlaybackClock({ serverNow: catalog.serverNow, perf: timers.now });
  const made = new Map();
  const session = createSession({
    catalog, fetcher: {}, clock, timers, policy, tileCap, settleMs, idleMs, startWaitMs,
    createCell: (id) => { const cell = fakeCell(id); made.set(id, cell); return cell; },
  });
  const events = [];
  session.onChange((event) => events.push(event));
  return { timers, catalog, clock, session, made, events };
}

const T = ORIGIN + 600_000;                       // somewhere well before the server's now (SERVER_AT_ZERO = ORIGIN + 3,600,000)

describe('cameras', () => {
  it('keeps at most tileCap cells, in order, without duplicates, and destroys the ones that leave', () => {
    const { session, made, events } = setup({ tileCap: 3 });
    session.setCameras(['A', 'B', 'B', 'C', 'D']);
    assert.deepEqual(session.cameras, ['A', 'B', 'C']);
    assert.deepEqual([...made.keys()], ['A', 'B', 'C']);
    assert.equal(session.cell('B'), made.get('B'));
    assert.equal(session.cell('D'), undefined);
    session.setCameras(['C', 'D']);
    assert.deepEqual(session.cameras, ['C', 'D']);
    assert.deepEqual([made.get('A').destroyed, made.get('B').destroyed, made.get('C').destroyed], [true, true, false]);
    assert.deepEqual(events.filter((e) => e.kind === 'cameras').map((e) => e.ids), [['A', 'B', 'C'], ['C', 'D']]);
  });

  it('the browser\'s tile limit lowers the cap', () => {
    const phone = choosePolicy({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) Safari/604.1', hasManagedMediaSource: true });
    const { session } = setup({ tileCap: 9, policy: phone });
    session.setCameras(['A', 'B', 'C']);
    assert.deepEqual(session.cameras, ['A', 'B']);
    const none = setup({ tileCap: 0 });
    none.session.setCameras(['A', 'B']);
    assert.deepEqual(none.session.cameras, ['A'], 'at least one');
  });

  it('asks nothing of a cell until the first scrub, play or go live', () => {
    const { session, made } = setup();
    session.setCameras(['A', 'B']);
    session.focus('A');
    assert.deepEqual([made.get('A').requests.length, made.get('B').requests.length], [0, 0]);
  });

  it('a camera added to a playing session joins at the playhead, and one added while the clock waits joins the start', async () => {
    const { session, made, clock, timers } = setup();
    session.setCameras(['A']);
    session.play(T);
    session.setCameras(['A', 'B']);
    const early = made.get('B').last();
    assert.deepEqual([early.precision, early.playing, early.targetMs, early.epoch], ['exact', true, T, made.get('A').last().epoch]);
    made.get('A').report({ kind: 'recorded', playing: true });
    await timers.advance(2000);
    session.setCameras(['A', 'B', 'C']);
    const joined = made.get('C').last();
    assert.deepEqual([joined.precision, joined.playing, joined.targetMs], ['exact', true, clock.position()]);
    assert.ok(joined.epoch > made.get('B').last().epoch);
  });
});

describe('scrubbing', () => {
  it('is O(1): the target goes to every cell with a new epoch, the playhead moves, nothing else happens', () => {
    const { session, made, clock } = setup({ policy: { ...DEFAULT_POLICY, keySteps: true } });
    session.setCameras(['A', 'B']);
    session.beginScrub();
    session.scrub(T);
    session.scrub(T + 500);
    for (const id of ['A', 'B']) {
      const [first, second] = made.get(id).requests;
      assert.deepEqual([first.targetMs, first.precision, first.playing], [T, 'key', false]);
      assert.deepEqual([second.targetMs, second.precision, second.playing], [T + 500, 'key', false]);
      assert.ok(second.epoch > first.epoch);
    }
    assert.equal(clock.mode, 'paused');
    assert.equal(clock.position(), T + 500);
    assert.equal(session.position, T + 500);
  });

  it('never targets later than the server\'s now', () => {
    const { session, made, timers } = setup();
    session.setCameras(['A']);
    session.scrub(SERVER_AT_ZERO + 99_999_999);
    assert.equal(made.get('A').last().targetMs, SERVER_AT_ZERO + timers.now());
  });

  it('after 80 ms without a move the main tile gets the exact frame, the others after 500 ms', async () => {
    const { session, made, timers } = setup();
    session.setCameras(['A', 'B', 'C']);
    session.focus('B');
    session.scrub(T);
    await timers.advance(79);
    assert.equal(made.get('B').requests.length, 1);
    await timers.advance(1);
    assert.deepEqual(made.get('B').last(), { targetMs: T, precision: 'exact', playing: false, epoch: made.get('B').last().epoch, priority: 1 });
    assert.equal(made.get('A').requests.length, 1);
    await timers.advance(420);
    assert.equal(made.get('A').last().precision, 'exact');
    assert.equal(made.get('C').last().precision, 'exact');
    assert.equal(made.get('A').last().priority, 0);
    assert.equal(made.get('B').requests.length, 2, 'the main tile is not asked twice');
  });

  it('every move restarts the timers: no exact frame while the pointer keeps moving', async () => {
    const { session, made, timers } = setup();
    session.setCameras(['A', 'B']);
    for (let i = 0; i < 50; i += 1) {
      session.scrub(T + i * 100);
      await timers.advance(79);
    }
    assert.ok(made.get('A').requests.every((r) => r.precision === 'key'));
    assert.ok(made.get('B').requests.every((r) => r.precision === 'key'));
  });

  it('without key steps (the settle-based floor) a drag asks nothing until the pointer rests', async () => {
    const { session, made, timers } = setup({ policy: { ...DEFAULT_POLICY, keySteps: false } });
    session.setCameras(['A']);
    for (let i = 0; i < 10; i += 1) { session.scrub(T + i * 100); await timers.advance(30); }
    assert.equal(made.get('A').requests.length, 0);
    await timers.advance(80);
    assert.deepEqual([made.get('A').last().precision, made.get('A').last().targetMs], ['exact', T + 900]);
  });

  it('epochs only rise, per cell', () => {
    const { session, made } = setup();
    session.setCameras(['A']);
    session.scrub(T);
    session.endScrub();
    session.pause();
    session.seek(1000);
    session.goLive();
    const epochs = made.get('A').requests.map((r) => r.epoch);
    assert.deepEqual(epochs, [...epochs].sort((a, b) => a - b));
    assert.equal(new Set(epochs).size, epochs.length);
  });
});

describe('the recordings drive', () => {
  it('a tile that loses the drive while the clock plays stops the clock at the playhead, and playing starts again from there when the drive is back', async () => {
    const { session, made, clock, timers, events } = setup();
    session.setCameras(['A', 'B']);
    session.play(T);
    made.get('A').report({ kind: 'recorded', playing: true });
    made.get('B').report({ kind: 'recorded', playing: true });
    await timers.advance(10_000);
    assert.deepEqual([clock.mode, clock.position()], ['playing', T + 10_000]);
    made.get('B').report({ kind: 'driveMissing', message: 'x' });
    assert.deepEqual([clock.mode, clock.position(), session.mode], ['paused', T + 10_000, 'paused']);
    const held = made.get('A').last();
    assert.deepEqual([held.precision, held.playing, held.targetMs], ['exact', false, T + 10_000], 'the tile that still has video holds a paused frame');
    assert.equal(made.get('B').requests.length, 1, 'the tile that lost the drive is left alone: it probes by itself');
    await timers.advance(30_000);
    assert.equal(clock.position(), T + 10_000, 'the clock stands still while the drive is gone');
    made.get('B').report({ kind: 'recorded', playing: false });                // the probe found the drive
    const again = made.get('A').last();
    assert.deepEqual([again.precision, again.playing, again.targetMs], ['exact', true, T + 10_000]);
    assert.deepEqual(made.get('B').last().epoch, again.epoch, 'every tile is asked together');
    made.get('A').report({ kind: 'recorded', playing: true });
    assert.deepEqual([clock.mode, clock.position(), session.mode], ['playing', T + 10_000, 'playing']);
    assert.deepEqual(events.filter((e) => e.kind === 'mode').map((e) => e.mode), ['playing', 'paused', 'playing']);
  });

  it('a person who acts while the drive is gone cancels the hold: pausing, moving or going live is not undone when the drive returns', async () => {
    for (const act of [(s) => s.pause(), (s) => s.seek(-5000), (s) => s.goLive(), (s) => s.scrub(T - 30_000), (s) => s.play(T - 60_000)]) {
      const { session, made, clock, timers } = setup();
      session.setCameras(['A', 'B']);
      session.play(T);
      made.get('A').report({ kind: 'recorded', playing: true });
      await timers.advance(5000);
      made.get('B').report({ kind: 'driveMissing', message: 'x' });
      assert.equal(clock.mode, 'paused');
      act(session);
      const requests = made.get('A').requests.length;
      const modeAfter = clock.mode;
      made.get('B').report({ kind: 'recorded', playing: false });                // the drive is back
      assert.equal(made.get('A').requests.length, requests, 'no automatic start after a person acted');
      assert.equal(clock.mode, modeAfter);
    }
  });

  it('a drive that is missing while the clock is paused or live changes nothing in the session', async () => {
    const paused = setup();
    paused.session.setCameras(['A']);
    paused.session.scrub(T);                                                     // the clock is paused at T
    const before = paused.made.get('A').requests.length;
    paused.made.get('A').report({ kind: 'driveMissing', message: 'x' });
    assert.deepEqual([paused.clock.mode, paused.made.get('A').requests.length], ['paused', before]);
    const live = setup();
    live.session.setCameras(['A']);
    live.session.goLive();
    const requests = live.made.get('A').requests.length;
    live.made.get('A').report({ kind: 'driveMissing', message: 'x' });
    assert.deepEqual([live.clock.mode, live.made.get('A').requests.length], ['live', requests]);
  });
});

describe('release', () => {
  it('pauses at the target, asks for the exact frame and to play, and starts the clock when the main tile plays', () => {
    const { session, made, clock, events } = setup();
    session.setCameras(['A', 'B']);
    session.beginScrub();
    session.scrub(T);
    session.endScrub();
    assert.equal(clock.mode, 'paused');
    const request = made.get('A').last();
    assert.deepEqual([request.targetMs, request.precision, request.playing], [T, 'exact', true]);
    assert.deepEqual(made.get('B').last().epoch, request.epoch);
    made.get('B').report({ kind: 'recorded', playing: true });                 // the other tile does not start the clock
    assert.equal(clock.mode, 'paused');
    made.get('A').report({ kind: 'recorded', playing: false });
    assert.equal(clock.mode, 'paused');
    made.get('A').report({ kind: 'recorded', playing: true, epoch: request.epoch - 1 });      // an old epoch does not either
    assert.equal(clock.mode, 'paused');
    made.get('A').report({ kind: 'recorded', playing: true });
    assert.equal(clock.mode, 'playing');
    assert.equal(clock.position(), T);
    assert.ok(events.some((e) => e.kind === 'mode' && e.mode === 'playing'));
  });

  it('starts the clock after 1.5 s even when the main tile has not shown a frame', async () => {
    const { session, clock, timers } = setup();
    session.setCameras(['A']);
    session.play(T);
    await timers.advance(1499);
    assert.equal(clock.mode, 'paused');
    await timers.advance(1);
    assert.deepEqual([clock.mode, clock.position()], ['playing', T]);
  });

  it('a gap, an unreadable part or an unsupported browser on the main tile cancel the start', async () => {
    for (const kind of ['unreadable', 'driveMissing', 'unsupported']) {
      const { session, made, clock, timers } = setup();
      session.setCameras(['A']);
      session.play(T);
      made.get('A').report({ kind, message: 'x' });
      await timers.advance(5000);
      assert.deepEqual([kind, clock.mode, clock.position()], [kind, 'paused', T]);
    }
  });

  it('a release within five seconds of now goes live', () => {
    const { session, made, clock, timers } = setup();
    session.setCameras(['A']);
    session.beginScrub();
    session.scrub(SERVER_AT_ZERO + timers.now() - 3000);
    session.endScrub();
    assert.equal(clock.mode, 'live');
    const request = made.get('A').last();
    assert.deepEqual([request.precision, request.playing, request.targetMs], ['exact', false, clock.position()], 'live holds the picture: the screen shows snapshots');
  });

  it('a release before the oldest recording starts the clock at the oldest while the cells hear the real target', () => {
    const { session, made, clock } = setup({ extents: { A: { oldest: ORIGIN, newest: ORIGIN + 100_000, typicalGOP: 2 }, B: { oldest: ORIGIN + 50_000, newest: ORIGIN + 100_000, typicalGOP: 2 } } });
    session.setCameras(['A', 'B']);
    session.beginScrub();
    session.scrub(ORIGIN - 30_000);
    assert.equal(clock.position(), ORIGIN);
    session.endScrub();
    assert.equal(made.get('A').last().targetMs, ORIGIN - 30_000, 'the cell says "this is the oldest recording"');
    made.get('A').report({ kind: 'recorded', playing: true });
    assert.equal(clock.position(), ORIGIN);
  });

  it('a coarse picture snaps the playhead to the key start and plays from there', () => {
    const { session, made, clock } = setup();
    session.setCameras(['A']);
    session.beginScrub();
    session.scrub(T);
    session.endScrub();
    const first = made.get('A').last();
    made.get('A').report({ kind: 'coarse', snapMs: T - 20_000, playing: false });
    const second = made.get('A').last();
    assert.ok(second.epoch > first.epoch);
    assert.deepEqual([second.targetMs, second.precision, second.playing], [T - 20_000, 'exact', true]);
    assert.equal(clock.position(), T - 20_000);
    made.get('A').report({ kind: 'recorded', playing: true });
    assert.equal(clock.mode, 'playing');
    assert.equal(clock.position(), T - 20_000);
  });

  it('a stray endScrub does nothing', () => {
    const { session, made } = setup();
    session.setCameras(['A']);
    session.endScrub();
    assert.equal(made.get('A').requests.length, 0);
  });
});

describe('gaps', () => {
  async function playing(options) {
    const ctx = setup(options);
    ctx.session.setCameras(['A', 'B']);
    ctx.session.play(T);
    ctx.made.get('A').report({ kind: 'recorded', playing: true });
    ctx.made.get('B').report({ kind: 'recorded', playing: true });
    await ctx.timers.advance(1000);
    return ctx;
  }

  it('when every tile reached a gap the clock jumps to the earliest next recording', async () => {
    const { made, clock } = await playing();
    const before = made.get('A').last().epoch;
    made.get('A').report({ kind: 'gap', next: T + 90_000, playing: false });
    assert.equal(made.get('A').last().epoch, before, 'tile B still shows video: no jump yet');
    made.get('B').report({ kind: 'gap', next: T + 60_000, playing: false });
    const jump = made.get('A').last();
    assert.ok(jump.epoch > before);
    assert.deepEqual([jump.targetMs, jump.precision, jump.playing], [T + 60_000, 'exact', true]);
    assert.equal(made.get('B').last().epoch, jump.epoch);
    assert.equal(clock.position(), T + 60_000);
  });

  it('when nothing follows it goes live', async () => {
    const { made, clock } = await playing();
    made.get('A').report({ kind: 'gap', next: null, playing: false });
    made.get('B').report({ kind: 'gap', next: null, playing: false });
    assert.equal(clock.mode, 'live');
  });

  it('a tile whose answer is older than the last dispatch counts as still working', async () => {
    const { made, clock } = await playing();
    const e = made.get('A').last().epoch;
    made.get('A').report({ kind: 'gap', next: T + 1000, playing: false });
    made.get('B').report({ kind: 'gap', next: T + 2000, epoch: e - 1, playing: false });
    assert.equal(clock.mode, 'playing');
  });

  it('is ignored while live, while scrubbing and while paused', async () => {
    const live = setup();
    live.session.setCameras(['A']);
    live.session.goLive();
    const before = live.made.get('A').requests.length;
    live.made.get('A').report({ kind: 'gap', next: null });
    assert.equal(live.made.get('A').requests.length, before);

    const dragging = setup();
    dragging.session.setCameras(['A']);
    dragging.session.beginScrub();
    dragging.session.scrub(T);
    const asked = dragging.made.get('A').requests.length;
    dragging.made.get('A').report({ kind: 'gap', next: T + 5000 });
    assert.equal(dragging.made.get('A').requests.length, asked);

    const paused = setup();
    paused.session.setCameras(['A']);
    paused.session.seek(0);
    paused.made.get('A').report({ kind: 'gap', next: T + 5000 });
    assert.equal(paused.made.get('A').requests.length, 1);
  });
});

describe('transport', () => {
  it('play(ms) jumps and plays; play() resumes a paused playhead; within five seconds of now it goes live', () => {
    const { session, made, clock, timers } = setup();
    session.setCameras(['A']);
    session.play(T);
    assert.deepEqual([made.get('A').last().targetMs, made.get('A').last().playing], [T, true]);
    made.get('A').report({ kind: 'recorded', playing: true });
    assert.equal(clock.mode, 'playing');
    session.pause();
    assert.equal(clock.mode, 'paused');
    assert.deepEqual([made.get('A').last().precision, made.get('A').last().playing], ['exact', false]);
    const paused = clock.position();
    session.play();
    assert.deepEqual([made.get('A').last().targetMs, made.get('A').last().playing], [paused, true]);
    session.play(SERVER_AT_ZERO + timers.now() - 1000);
    assert.equal(clock.mode, 'live');
  });

  it('togglePlay flips between playing and paused', () => {
    const { session, made, clock } = setup();
    session.setCameras(['A']);
    session.play(T);
    made.get('A').report({ kind: 'recorded', playing: true });
    session.togglePlay();
    assert.equal(clock.mode, 'paused');
    session.togglePlay();
    assert.equal(made.get('A').last().playing, true);
  });

  it('goLive follows the server and asks the cells for the live frame, not to play it', () => {
    const { session, made, clock } = setup();
    session.setCameras(['A']);
    session.goLive();
    assert.equal(clock.mode, 'live');
    const request = made.get('A').last();
    assert.deepEqual([request.precision, request.playing, request.targetMs], ['exact', false, clock.position()]);
  });

  it('seek(delta) keeps playing if it was playing and stays paused if it was paused', () => {
    const { session, made, clock } = setup();
    session.setCameras(['A']);
    session.seek(-1000);                                              // from live: leaves live, plays
    assert.equal(made.get('A').last().playing, true);
    assert.ok(made.get('A').last().targetMs < clock.position() + 1);
    session.beginScrub();
    session.scrub(T);
    session.endScrub();
    made.get('A').report({ kind: 'recorded', playing: true });
    session.pause();
    const at = clock.position();
    session.seek(+10_000);
    assert.deepEqual([made.get('A').last().targetMs, made.get('A').last().playing, clock.mode], [at + 10_000, false, 'paused']);
    session.seek(-1000);
    assert.equal(clock.position(), at + 9000);
  });

  it('seek to within five seconds of now while playing goes live', () => {
    const { session, made, clock, timers } = setup();
    session.setCameras(['A']);
    session.play(T);
    made.get('A').report({ kind: 'recorded', playing: true });
    session.seek(SERVER_AT_ZERO + timers.now() - T - 2000);
    assert.equal(clock.mode, 'live');
  });
});

describe('the mode the page shows', () => {
  it('is playing as soon as playing was asked for, even while the clock waits for the first frame, and never flickers', async () => {
    const { session, made, events, clock } = setup();
    session.setCameras(['A']);
    const modes = () => events.filter((e) => e.kind === 'mode').map((e) => e.mode);
    assert.equal(session.mode, 'live');
    session.beginScrub();
    session.scrub(T);
    session.endScrub();
    assert.equal(clock.mode, 'paused', 'the clock itself is waiting');
    assert.equal(session.mode, 'playing');
    made.get('A').report({ kind: 'recorded', playing: true });
    assert.equal(session.mode, 'playing');
    session.seek(0);                                                  // keeps the mode
    session.seek(+5000);
    made.get('A').report({ kind: 'recorded', playing: true });
    assert.deepEqual(modes(), ['paused', 'playing'], 'live, then paused by the drag, then playing: nothing else');
  });

  it('falls back to paused when the start is cancelled by an unreadable part', () => {
    const { session, made, events } = setup();
    session.setCameras(['A']);
    session.play(T);
    assert.equal(session.mode, 'playing');
    made.get('A').report({ kind: 'unreadable', message: 'x' });
    assert.equal(session.mode, 'paused');
    assert.deepEqual(events.filter((e) => e.kind === 'mode').map((e) => e.mode), ['playing', 'paused']);
  });

  it('pause during the wait pauses at once', () => {
    const { session, clock } = setup();
    session.setCameras(['A']);
    session.play(T);
    session.pause();
    assert.deepEqual([session.mode, clock.mode, clock.position()], ['paused', 'paused', T]);
  });

  it('seek(0) from live stays live; a negative seek leaves it', () => {
    const { session, made } = setup();
    session.setCameras(['A']);
    session.goLive();
    session.seek(0);
    assert.equal(session.mode, 'live');
    assert.equal(made.get('A').last().playing, false, 'live: the players hold, the screen shows snapshots');
    session.seek(-30_000);
    assert.equal(session.mode, 'playing');
  });
});

describe('suspend and resume', () => {
  it('suspend freezes the playhead and the cells; resume plays again from the same spot', () => {
    const { session, made, clock, timers } = setup();
    session.setCameras(['A']);
    session.play(T);
    made.get('A').report({ kind: 'recorded', playing: true });
    timers.advance(3000);
    session.suspend();
    assert.equal(made.get('A').suspendCalls, 1);
    const frozen = clock.position();
    assert.equal(clock.mode, 'paused');
    session.scrub(T + 99_000);
    assert.equal(clock.position(), frozen, 'a suspended session ignores input');
    session.resume();
    assert.equal(made.get('A').resumeCalls, 1);
    assert.deepEqual([made.get('A').last().targetMs, made.get('A').last().playing], [frozen, true]);
  });

  it('a session that was live is live again after resume; one that never started stays quiet', () => {
    const live = setup();
    live.session.setCameras(['A']);
    live.session.goLive();
    live.session.suspend();
    live.session.resume();
    assert.equal(live.clock.mode, 'live');
    const idle = setup();
    idle.session.setCameras(['A']);
    idle.session.suspend();
    idle.session.resume();
    assert.equal(idle.made.get('A').requests.length, 0);
  });
});

describe('destroy', () => {
  it('destroys the cells, stops the timers and ignores everything after', async () => {
    const { session, made, clock, timers, events } = setup();
    session.setCameras(['A', 'B']);
    session.scrub(T);
    session.destroy();
    assert.deepEqual([made.get('A').destroyed, made.get('B').destroyed], [true, true]);
    const asked = made.get('A').requests.length;
    await timers.advance(2000);
    assert.equal(made.get('A').requests.length, asked, 'the settle timer was cleared');
    session.scrub(T + 1);
    session.play(T);
    session.setCameras(['C']);
    assert.equal(made.get('A').requests.length, asked);
    assert.equal(made.has('C'), false);
    const heard = events.length;
    clock.goLive();
    assert.equal(events.length, heard, 'no longer listening to the clock');
    session.destroy();
  });
});

describe('a long random drag', () => {
  function random(seed) {
    let state = seed >>> 0;
    return () => { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state / 2 ** 32; };
  }

  it('10,000 scrubs: the last desire of every cell is the exact frame at the last target, and epochs never repeat or fall', async () => {
    const next = random(20261010);
    const { session, made, timers } = setup({ tileCap: 4 });
    session.setCameras(['A', 'B', 'C', 'D']);
    session.focus('B');
    session.beginScrub();
    let last = T;
    for (let i = 0; i < 10_000; i += 1) {
      last = T + Math.floor(next() * 3_000_000);
      session.scrub(last);
      if (next() < 0.05) session.focus(['A', 'B', 'C', 'D'][Math.floor(next() * 4)]);
      await timers.advance(Math.floor(next() * 40));
    }
    session.endScrub();
    await timers.advance(2000);
    for (const id of ['A', 'B', 'C', 'D']) {
      const requests = made.get(id).requests;
      const epochs = requests.map((r) => r.epoch);
      assert.ok(epochs.every((epoch, index) => index === 0 || epoch > epochs[index - 1]), `${id}: epochs rise`);
      const final = requests.at(-1);
      assert.deepEqual([final.targetMs, final.precision, final.playing], [last, 'exact', true], id);
    }
  });
});
