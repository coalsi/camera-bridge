// clock.js: the shared playhead.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { LIVE_BEHIND_MS, LIVE_SNAP_MS, PlaybackClock, realTimers } from '../web/js/nvr/clock.js';
import { createFakeTimers } from './player-fakes/fake-timers.mjs';

const SERVER_EPOCH = 1_760_000_000_000;

function setup() {
  const timers = createFakeTimers();
  const serverNow = () => SERVER_EPOCH + timers.now();
  const clock = new PlaybackClock({ serverNow, perf: timers.now });
  return { timers, serverNow, clock };
}

describe('constants', () => {
  it('are the specified numbers', () => {
    assert.equal(LIVE_BEHIND_MS, 6000);
    assert.equal(LIVE_SNAP_MS, 5000);
  });

  it('realTimers has a monotonic now and working timeouts', async () => {
    const before = realTimers.now();
    await new Promise((resolve) => realTimers.setTimeout(resolve, 5));
    assert.ok(realTimers.now() >= before);
    const id = realTimers.setTimeout(() => assert.fail('cleared timers must not fire'), 5);
    realTimers.clearTimeout(id);
    await new Promise((resolve) => setTimeout(resolve, 15));
  });
});

describe('PlaybackClock', () => {
  it('starts live, six seconds behind the server', async () => {
    const { clock, timers, serverNow } = setup();
    assert.equal(clock.mode, 'live');
    assert.equal(clock.position(), SERVER_EPOCH - 6000);
    await timers.advance(1500);
    assert.equal(clock.position(), serverNow() - 6000);
    assert.equal(clock.position(), SERVER_EPOCH + 1500 - 6000);
  });

  it('scrub stands still at the given time', async () => {
    const { clock, timers } = setup();
    clock.scrub(SERVER_EPOCH - 90_000);
    assert.equal(clock.mode, 'paused');
    await timers.advance(5000);
    assert.equal(clock.position(), SERVER_EPOCH - 90_000);
  });

  it('plays from an anchor at the speed of the monotonic clock', async () => {
    const { clock, timers } = setup();
    clock.play(SERVER_EPOCH - 60_000);
    assert.equal(clock.mode, 'playing');
    assert.equal(clock.position(), SERVER_EPOCH - 60_000);
    await timers.advance(2500);
    assert.equal(clock.position(), SERVER_EPOCH - 57_500);
  });

  it('holds still for startingInMs and then runs', async () => {
    const { clock, timers } = setup();
    clock.play(SERVER_EPOCH - 60_000, { startingInMs: 100 });
    await timers.advance(60);
    assert.equal(clock.position(), SERVER_EPOCH - 60_000);
    await timers.advance(140);
    assert.equal(clock.position(), SERVER_EPOCH - 60_000 + 100);
  });

  it('pause freezes where the playhead is, from playing and from live', async () => {
    const { clock, timers } = setup();
    clock.play(SERVER_EPOCH - 60_000);
    await timers.advance(3000);
    clock.pause();
    assert.equal(clock.mode, 'paused');
    await timers.advance(10_000);
    assert.equal(clock.position(), SERVER_EPOCH - 57_000);
    clock.goLive();
    await timers.advance(1000);
    const live = clock.position();
    clock.pause();
    await timers.advance(5000);
    assert.equal(clock.position(), live);
  });

  it('scrub while playing pauses at the new time', async () => {
    const { clock, timers } = setup();
    clock.play(SERVER_EPOCH - 60_000);
    await timers.advance(1000);
    clock.scrub(SERVER_EPOCH - 120_000);
    assert.equal(clock.mode, 'paused');
    assert.equal(clock.position(), SERVER_EPOCH - 120_000);
  });

  it('goLive follows the server again', async () => {
    const { clock, timers, serverNow } = setup();
    clock.scrub(SERVER_EPOCH - 90_000);
    clock.goLive();
    assert.equal(clock.mode, 'live');
    await timers.advance(4000);
    assert.equal(clock.position(), serverNow() - 6000);
  });

  it('shouldGoLive is true within five seconds of now or later', async () => {
    const { clock, serverNow } = setup();
    assert.equal(clock.shouldGoLive(serverNow() - 5001), false);
    assert.equal(clock.shouldGoLive(serverNow() - 5000), true);
    assert.equal(clock.shouldGoLive(serverNow()), true);
    assert.equal(clock.shouldGoLive(serverNow() + 60_000), true);
    assert.equal(clock.shouldGoLive(serverNow() - 600_000), false);
  });

  it('onChange reports mode changes only, and the unsubscribe works', async () => {
    const { clock } = setup();
    const seen = [];
    const off = clock.onChange((mode) => seen.push(mode));
    clock.scrub(SERVER_EPOCH - 90_000);       // live -> paused
    clock.scrub(SERVER_EPOCH - 80_000);       // paused -> paused: no event
    clock.play(SERVER_EPOCH - 80_000);        // -> playing
    clock.play(SERVER_EPOCH - 70_000);        // playing -> playing: no event
    clock.pause();                            // -> paused
    clock.goLive();                           // -> live
    off();
    clock.pause();
    assert.deepEqual(seen, ['paused', 'playing', 'paused', 'live']);
  });
});
