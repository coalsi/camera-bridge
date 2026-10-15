import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { FILE_TARGET_MS, LAG_MS, VirtualArchive } from '../web-dev/lib/archive.mjs';
import { CAMERA_DEFINITIONS, DAY, HOUR } from '../web-dev/lib/cameras.mjs';
import { parseFragment, parseInit, readBoxes } from '../web-dev/lib/mp4.mjs';
import { ensureFixtures, fixtureSet, hasFfprobe } from './support/fixtures.mjs';

const fixtures = ensureFixtures();
const NOW = Date.UTC(2026, 9, 10, 12, 0, 0, 123);
const byName = (name) => CAMERA_DEFINITIONS.find((definition) => definition.name === name);
const make = (now = NOW) => {
  const clock = { now };
  const archive = new VirtualArchive({ fixtures: fixtureSet(), definitions: CAMERA_DEFINITIONS, clock: () => clock.now });
  archive.seed();
  return { archive, clock };
};
const opts = { skip: fixtures.skip };

test('seed: three days for most cameras, a stopped one and a new one', opts, () => {
  const { archive } = make();
  const cutoff = Math.ceil((NOW - 3 * DAY) / FILE_TARGET_MS) * FILE_TARGET_MS;
  const door = archive.extent(byName('Front Door').id);
  assert.equal(door.oldest, cutoff);
  assert.ok(door.newest <= NOW - LAG_MS && door.newest > NOW - LAG_MS - 2600, `newest ${NOW - door.newest} ms before now`);
  assert.equal(archive.extent(byName('Garage').id).typicalGOP, 12);
  assert.equal(archive.extent(byName('Back Yard').id).typicalGOP, 2.002);
  const shed = archive.extent(byName('Shed').id);
  assert.ok(Math.abs(shed.newest - (NOW - 6 * HOUR - LAG_MS)) <= 2600, 'Shed stopped six hours ago');
  assert.equal(archive.isRecording(byName('Shed').id), false);
  const fresh = archive.extent(byName('New Gate').id);
  assert.ok(Math.abs(fresh.oldest - (NOW - 25 * 60_000)) <= 1, 'New Gate began 25 minutes ago');
});

test('lookups: boundaries are exact, and a restart moments later gives a camera of 900 s files the same ids', opts, () => {
  const { archive } = make();
  const id = byName('Front Door').id;
  const fragment = archive.containing(id, NOW - HOUR);
  assert.ok(fragment.start <= NOW - HOUR && NOW - HOUR < fragment.end);
  assert.equal(archive.containing(id, fragment.start).id, fragment.id, 't == start is this fragment');
  assert.equal(archive.containing(id, fragment.end - 1).id, fragment.id, 't == end - 1 is this fragment');
  const next = archive.containing(id, fragment.end);
  assert.equal(next.start, fragment.end, 't == end is the next fragment');
  assert.equal(archive.startingAfter(id, fragment.start).id, next.id, 'startingAfter is strictly after');
  assert.equal(archive.startingAfter(id, fragment.end - 1).id, next.id);
  assert.equal(archive.byId(id, fragment.id).start, fragment.start);
  assert.equal(archive.byId(byName('Garage').id, fragment.id), null, 'an id of another camera is unknown');
  assert.equal(archive.byId(id, '000000000000.1'), null);
  assert.equal(archive.containing(id, NOW + HOUR), null, 'after the newest footage');
  assert.equal(archive.containing(id, archive.extent(id).oldest - 1), null, 'before the oldest footage');
  assert.equal(archive.containing('FFFFFFFF-0000-4000-8000-000000000000', NOW), null, 'an unknown camera');
  // a server that starts again 4 minutes later still has the same fragment under the same id (for files that are exactly 900 s long: the
  // first file of a run starts on the 15-minute grid, and every later one 900 s after the one before)
  const later = make(NOW + 4 * 60_000).archive;
  assert.equal(later.byId(id, fragment.id).start, fragment.start);
});

test('fragments of one file tile exactly, whatever the frame rate', opts, () => {
  const { archive } = make();
  for (const name of ['Front Door', 'Back Yard', 'Garage', 'Driveway', 'Side Gate']) {
    const id = byName(name).id;
    let fragment = archive.containing(id, NOW - 2 * HOUR);
    for (let n = 0; n < 300; n += 1) {
      const next = archive.startingAfter(id, fragment.start);
      if (next.file === fragment.file) assert.equal(next.start, fragment.end, `${name}: fragment ${fragment.index} and the next`);
      assert.ok(next.start > fragment.start, `${name}: time moves forward`);
      assert.equal(archive.byId(id, next.id).start, next.start);
      fragment = next;
    }
  }
});

test('a continuation fragment names its keyframe fragment', opts, () => {
  const { archive } = make();
  const id = byName('Garage').id;
  let inside = null;
  for (let t = NOW - 5 * HOUR; !inside; t += 2500) {
    const fragment = archive.containing(id, t);
    if (fragment.backToKey === 2) inside = fragment;
  }
  const key = archive.byId(id, `${inside.file.key}.${inside.index - 2}`);
  assert.equal(key.key, true);
  assert.equal(key.backToKey, 0);
  assert.equal(archive.byId(id, `${inside.file.key}.${inside.index - 1}`).backToKey, 1);
  assert.ok(inside.end - key.start > 5000 && inside.end - key.start <= 7600, `a lead-in of ${inside.end - key.start} ms`);
});

test('gaps: a daily gap is a hole, the next recording starts where the gap ends', opts, () => {
  const { archive } = make();
  const id = byName('Driveway').id;
  const gapStart = Math.floor((NOW - DAY) / DAY) * DAY + 3 * HOUR + 40 * 60_000;
  assert.equal(archive.containing(id, gapStart + 10 * 60_000), null);
  const after = archive.startingAfter(id, gapStart + 10 * 60_000);
  assert.equal(after.start, gapStart + 20 * 60_000, 'the first fragment after the gap starts where the gap ends');
  assert.equal(after.index, 0);
  assert.ok(archive.containing(id, gapStart - 5000), 'footage right before the gap');
  assert.equal(archive.extent(id).oldest <= gapStart, true);
});

test('files meet as the camera says: exactly, 300 ms apart, or 0.4 ms overlapping', opts, () => {
  const { archive } = make();
  const expected = { 'Front Door': 0, Driveway: 300, 'Back Yard': -0.4 };
  for (const [name, adjust] of Object.entries(expected)) {
    const camera = archive.cameras.get(byName(name).id);
    const files = camera.files.filter((file) => file.run === camera.runs.at(-1)).slice(2, 12);
    for (let i = 1; i < files.length; i += 1) {
      const end = files[i - 1].start + files[i - 1].duration;
      assert.ok(Math.abs(files[i].start - (end + adjust)) < 1e-6, `${name}: file ${i} starts ${files[i].start - end} ms after the previous ends`);
    }
  }
});

test('the open file grows with the clock and the footage stops when the run is closed', opts, () => {
  const { archive, clock } = make();
  const id = byName('Front Door').id;
  const before = archive.extent(id).newest;
  clock.now += 10_000;
  const grown = archive.extent(id).newest;
  assert.ok(grown >= before + 6000 && grown <= before + 10_000, `newest moved ${grown - before} ms in 10 s`);
  const version = archive.version;
  archive.closeRun(id);
  assert.equal(archive.isRecording(id), false);
  const frozen = archive.extent(id).newest;
  clock.now += 60_000;
  assert.equal(archive.extent(id).newest, frozen, 'a closed run does not grow');
  assert.ok(archive.version > version - 1);
  archive.openRun(id, clock.now);
  clock.now += 10_000;
  assert.ok(archive.extent(id).newest > frozen + 60_000, 'a new run adds footage after the break');
  assert.equal(archive.containing(id, frozen + 30_000), null, 'the break is a gap');
  assert.equal(archive.startingAfter(id, frozen + 30_000).index, 0);
});

test('retention removes whole closed files and never the open one', opts, () => {
  const { archive } = make();
  const id = byName('Front Door').id;
  const old = archive.containing(id, NOW - 2.5 * DAY);
  const recent = archive.containing(id, NOW - 3600_000);
  const used = archive.usedBytes();
  assert.ok(archive.dropEndedBefore(NOW - 2 * DAY) > 0);
  assert.equal(archive.byId(id, old.id), null, 'a removed fragment is gone');
  assert.ok(archive.byId(id, recent.id), 'a recent one stays');
  assert.ok(archive.usedBytes() < used);
  assert.ok(archive.extent(id).oldest >= NOW - 2 * DAY - 15 * 60_000, 'the oldest footage moved up');
  archive.dropOldestUntil(0);
  assert.ok(archive.extent(id), 'the open file of a recording camera stays');
  assert.ok(archive.isRecording(id));
  assert.equal(archive.cameras.get(id).files.length, 1);
});

test('activity: coverage and levels per bin, aligned, typical only with 30 minutes of footage', opts, () => {
  const { archive } = make();
  const driveway = byName('Driveway').id;
  const from = Math.floor((NOW - 2 * DAY) / HOUR) * HOUR;
  const answer = archive.activity(driveway, from, 60_000, 1440);
  assert.equal(answer.coverage.length, 1440);
  assert.equal(answer.level.length, 1440);
  assert.ok(answer.coverage.every((value) => Number.isInteger(value) && value >= 0 && value <= 100));
  assert.ok(answer.level.every((value) => value >= 0));
  assert.ok(answer.level.every((value, i) => answer.coverage[i] > 0 || answer.level[i] === 0 || answer.coverage[i] === 0), 'a level without any footage');
  const gapMinute = (Math.floor((NOW - DAY) / DAY) * DAY + 3 * HOUR + 50 * 60_000 - from) / 60_000;
  if (gapMinute >= 0 && gapMinute < 1440) assert.equal(answer.coverage[gapMinute], 0, 'the daily gap has no coverage');
  assert.ok(answer.coverage.filter((value) => value === 100).length > 1000);
  assert.ok(answer.typical > 0);
  assert.equal(archive.activity(byName('New Gate').id, from, 60_000, 10).typical, null, 'under 30 minutes of footage');
  const fresh = archive.activity(byName('New Gate').id, NOW - 20 * 60_000, 60_000, 20).coverage;
  assert.ok(fresh.slice(0, -1).every((value) => value === 100), 'every full minute of the new camera is covered');
  assert.ok(fresh.at(-1) >= 90 && fresh.at(-1) < 100, `the minute at the live edge is covered up to the last whole fragment (${fresh.at(-1)} %)`);
  assert.deepEqual(archive.activity(byName('Front Door').id, from, 60_000, 5), archive.activity(byName('Front Door').id, from, 60_000, 5), 'the same question, the same answer');
});

test('activity: sub-minute bins carry texture, wide bins average it', opts, () => {
  const { archive } = make();
  const id = byName('Front Door').id;
  const fine = archive.activity(id, NOW - 3 * HOUR, 2000, 100);
  assert.ok(new Set(fine.level).size > 50, 'fine bins differ from each other');
  const wide = archive.activity(id, Math.floor((NOW - DAY) / HOUR) * HOUR, HOUR, 20);
  const spread = Math.max(...wide.level) / Math.min(...wide.level.filter((value) => value > 0));
  assert.ok(spread > 1 && spread < 20, `hourly levels vary by ${spread}`);
});

test('served bytes: the fragment and the init are what the plan says they are', opts, () => {
  const { archive } = make();
  const id = byName('Garage').id;
  const fragment = archive.containing(id, NOW - 90 * 60_000);
  const init = parseInit(archive.readInit(fragment));
  const info = archive.fileInfo(fragment.file);
  assert.equal(init.mime, info.mime);
  assert.deepEqual([init.width, init.height], [info.width, info.height]);
  const bytes = archive.readFragment(fragment);
  const boxes = readBoxes(bytes);
  assert.deepEqual(boxes.map((b) => b.type), ['moof', 'mdat']);
  assert.equal(bytes.length, fragment.bytes);
  const parsed = parseFragment(bytes, boxes[0], boxes[1], init.defaults);
  assert.equal(parsed.baseDecodeTime, fragment.mediaTicks);
  assert.equal(parsed.key, fragment.key);
  assert.ok(Math.abs(info.anchor + parsed.baseDecodeTime / 90 - fragment.start) <= 1, 'start = anchor + tfdt / 90');
  assert.ok(Math.abs(parsed.duration / 90 - (fragment.end - fragment.start)) <= 1, 'the length in the bytes is the length in the plan');
});

test('a file adds up: its bytes are the bytes of its fragments', opts, () => {
  const { archive } = make();
  const id = byName('Driveway').id;
  const file = archive.cameras.get(id).files[100];
  let sum = 0;
  for (let n = 0; n < archive.visible(file); n += 1) sum += archive.byId(id, `${file.key}.${n}`).bytes;
  assert.equal(archive.fileBytes(file), sum);
  assert.equal(archive.visible(file), 450);
});

test('two sizes: the living room alternates between two encodings every two hours', opts, () => {
  const { archive } = make();
  const id = byName('Living Room').id;
  const seen = new Set();
  for (let t = NOW - 6 * HOUR; t < NOW - HOUR; t += 20 * 60_000) {
    const fragment = archive.containing(id, t);
    if (fragment) seen.add(archive.fileInfo(fragment.file).mime);
  }
  assert.deepEqual([...seen].sort(), ['video/mp4; codecs="avc1.4d401e"', 'video/mp4; codecs="avc1.4d401f"']);
});

test('decodes: an init and the parts of a plan make a clip ffprobe reads to the end', { skip: fixtures.skip || (!hasFfprobe && 'ffprobe is not installed') }, () => {
  const { archive } = make();
  const directory = mkdtempSync(join(tmpdir(), 'cb-archive-'));
  try {
    for (const name of ['Front Door', 'Garage', 'Back Yard', 'Side Gate', 'Driveway']) {
      const id = byName(name).id;
      // 400 s into a file, so that the parts are one file (a clip made of two files would have its time start again at 0)
      const fragment = archive.containing(id, archive.cameras.get(id).files.at(-100).start + 400_000.5);
      const key = archive.byId(id, `${fragment.file.key}.${fragment.index - fragment.backToKey}`);
      const parts = [key];
      for (let n = 0; n < 5; n += 1) parts.push(archive.startingAfter(id, parts.at(-1).start));
      const chunks = [archive.readInit(key), ...parts.map((part) => archive.readFragment(part))];
      const path = join(directory, `${name.replace(/ /g, '-')}.mp4`);
      writeFileSync(path, Buffer.concat(chunks));
      const out = execFileSync('ffprobe', ['-v', 'error', '-count_frames', '-select_streams', 'v:0', '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0', path], { encoding: 'utf8' }).trim();
      const frames = parts.reduce((sum, part) => sum + part.file.fixture.parts[part.index % part.file.shape.count].fragment.samples, 0);
      assert.equal(Number(out), frames, `${name}: frames decoded`);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('performance: three days of nine cameras, lookups and a day of waveform in a blink', opts, () => {
  const started = performance.now();
  const { archive } = make();
  const seeded = performance.now() - started;
  const id = byName('Driveway').id;
  const lookups = performance.now();
  for (let n = 0; n < 2000; n += 1) archive.containing(id, NOW - 3 * HOUR - n * 100_000 % (2 * DAY));
  const perLookup = (performance.now() - lookups) / 2000;
  const wave = performance.now();
  for (const camera of CAMERA_DEFINITIONS) archive.activity(camera.id, Math.floor((NOW - 31 * DAY) / HOUR) * HOUR, HOUR, 744);
  const waveMs = performance.now() - wave;
  assert.ok(seeded < 500, `seeding took ${seeded.toFixed(0)} ms`);
  assert.ok(perLookup < 1, `a lookup took ${perLookup.toFixed(3)} ms`);
  assert.ok(waveMs < 3000, `nine cameras x 744 hourly bins took ${waveMs.toFixed(0)} ms`);
});
