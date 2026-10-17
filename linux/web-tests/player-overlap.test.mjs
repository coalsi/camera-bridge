// A camera's files that overlap on disk: the next file starts inside the last part of the one before (Patio on the box: its camera's
// timestamps went back and the new file starts 741 ms before the end of the old one). The bridge plays the later file there; a playing tile
// must cross into it and keep playing, never go back into what it has just played.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { FILE_A, FILE_B, MIME, ORIGIN } from './player-fakes/fake-archive.mjs';
import { createRig, desirer } from './player-fakes/rig.mjs';

const HEVC = 'video/mp4; codecs="hvc1.1.6.L153.B0"';
const OVERLAP_MS = 741;

async function playAcross({ mime }) {
  const files = [
    { key: FILE_A, startMs: ORIGIN, parts: 10, gop: 1 },                                  // 0 to 20 s
    { key: FILE_B, startMs: ORIGIN + 20_000 - OVERLAP_MS, parts: 10, gop: 1, mime },      // 19.259 s on
  ];
  const rig = createRig({ cameras: [{ id: 'CAM-1', files }] });
  await rig.start();
  const cell = rig.makeCell();
  const ask = desirer(cell);
  rig.clock.scrub(ORIGIN + 14_000);
  ask(ORIGIN + 14_000, 'exact', true);
  await rig.timers.advance(300);
  rig.clock.play(ORIGIN + 14_000);
  const seconds = (sec) => sec - (ORIGIN - rig.base()) / 1000;           // buffer seconds -> seconds after ORIGIN
  const positions = [];
  for (let step = 0; step < 100; step += 1) {
    await rig.timers.advance(100);
    positions.push(seconds(rig.surface().currentTime()));
  }
  const result = {
    rig, cell,
    videoSec: positions.at(-1),
    clockSec: (rig.clock.position() - ORIGIN) / 1000,
    backwards: positions.filter((at, i) => i > 0 && at < positions[i - 1] - 0.05).length,
    seeksIntoTheOverlap: rig.surface().log.filter((entry) => entry.op === 'seek' && seconds(entry.sec) > 19.2 && seconds(entry.sec) < 20).length,
  };
  cell.destroy();
  rig.catalog.stop();
  return result;
}

describe('a file that starts inside the one before', () => {
  it('in the same codec: plays across into it without a plan, a jump back or a stall', async () => {
    const { rig, cell, videoSec, clockSec, backwards } = await playAcross({ mime: MIME });
    assert.equal(cell.coverage.kind, 'recorded');
    assert.equal(rig.paths('fragments?at=').length, 1, 'only the first plan');
    assert.equal(backwards, 0);
    assert.ok(Math.abs(videoSec - clockSec) < 0.5, `the picture (${videoSec}) is at the clock (${clockSec})`);
    assert.equal(rig.surface().stalledMs, 0);
  });

  it('in another codec: crosses into it once and plays on, instead of playing the end of the old file again and again', async () => {
    const { rig, cell, videoSec, clockSec, backwards, seeksIntoTheOverlap } = await playAcross({ mime: HEVC });
    assert.equal(cell.coverage.kind, 'recorded');
    assert.equal(rig.surface().mime, HEVC, 'the new file plays');
    assert.ok(Math.abs(videoSec - clockSec) < 1, `the picture (${videoSec}) is at the clock (${clockSec})`);
    assert.equal(backwards, 0, 'never back into what was played');
    assert.ok(seeksIntoTheOverlap <= 1, `${seeksIntoTheOverlap} seeks into the last second of the old file`);
  });
});
