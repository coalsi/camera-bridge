// Loads the fixture files make-fixtures.sh wrote and turns each into the plan the virtual archive repeats: its init segment, its
// fragments (as the engine would index them) and a few rates measured from the bytes.

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseFile, withBaseDecodeTime } from './mp4.mjs';

export const FIXTURE_NAMES = ['gop2', 'hd', 'longgop', 'ntsc', 'hevc', 'res-b', 'quiet'];
const TICKS = 90_000;

export class FixtureError extends Error {
  constructor(message) {
    super(message);
    this.name = 'FixtureError';
  }
}

/** True when every fixture and its snapshot exists in `directory`. */
export function fixturesPresent(directory) {
  return FIXTURE_NAMES.every((name) => existsSync(join(directory, `${name}.mp4`)) && existsSync(join(directory, `${name}.jpg`)));
}

/**
 * One fixture as a plan. `parts[i]` is fragment i of the file: `startTicks` (from the file's start), `ticks` (its length), `key`,
 * `backToKey` (fragments back to the one with the keyframe), `bytes` (moof + mdat, which is what the fragment route serves) and
 * `keyBytes` (the first sample when it is a keyframe). The plan repeats: fragment `n` of a long file is `parts[n % parts.length]`
 * with `startTicks` advanced by `loopTicks` for each full round.
 */
export function loadFixture(directory, name) {
  const path = join(directory, `${name}.mp4`);
  if (!existsSync(path)) throw new FixtureError(`The fixture ${name}.mp4 is missing. Run: sh linux/web-dev/make-fixtures.sh`);
  const buffer = readFileSync(path);
  const file = parseFile(buffer);
  if (file.init.timescale !== TICKS) throw new FixtureError(`${name}.mp4 has the timescale ${file.init.timescale}, not ${TICKS}. Run: sh linux/web-dev/make-fixtures.sh --force`);
  if (!file.fragments[0].key) throw new FixtureError(`${name}.mp4 does not start with a keyframe.`);
  let startTicks = 0;
  let lastKey = 0;
  const parts = file.fragments.map((fragment, index) => {
    if (fragment.key) lastKey = index;
    const part = {
      index,
      startTicks,
      ticks: fragment.duration,
      key: fragment.key,
      backToKey: index - lastKey,
      bytes: fragment.bytes,
      keyBytes: fragment.key ? fragment.firstSampleSize : 0,
      fragment,
    };
    startTicks += fragment.duration;
    return part;
  });
  const loopTicks = startTicks;
  const keyStarts = parts.filter((part) => part.key).map((part) => part.startTicks);
  const gaps = keyStarts.slice(1).map((value, i) => value - keyStarts[i]).sort((a, b) => a - b);
  const totalBytes = parts.reduce((sum, part) => sum + part.bytes, 0);
  const keyBytes = parts.reduce((sum, part) => sum + part.keyBytes, 0);
  const seconds = loopTicks / TICKS;
  return {
    name,
    buffer,
    init: file.initBytes,
    info: file.init,
    parts,
    loopTicks,
    /** The typical keyframe to keyframe time in seconds (the median gap; the loop length when there is a single keyframe). */
    gopSeconds: (gaps.length ? gaps[Math.floor(gaps.length / 2)] : loopTicks) / TICKS,
    bytesPerSecond: totalBytes / seconds,
    nonKeyBytesPerSecond: (totalBytes - keyBytes) / seconds,
    bitrateKbps: Math.round((totalBytes * 8) / seconds / 1000),
    snapshot: readFileSync(join(directory, `${name}.jpg`)),
    /** The bytes of fragment `n` of a long file whose base media decode time is `ticks`. */
    fragmentBytes(n, ticks) {
      return withBaseDecodeTime(buffer, parts[n % parts.length].fragment, ticks);
    },
  };
}

export function loadFixtures(directory, names = FIXTURE_NAMES) {
  return new Map(names.map((name) => [name, loadFixture(directory, name)]));
}
