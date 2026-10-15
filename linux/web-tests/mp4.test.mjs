import assert from 'node:assert/strict';
import test from 'node:test';
import { avcCodecString, hevcCodecString, Mp4Error, parseFile, parseFragment, parseInit, readBoxes, withBaseDecodeTime } from '../web-dev/lib/mp4.mjs';
import { ensureFixtures, fixtureSet } from './support/fixtures.mjs';

const fixtures = ensureFixtures();
const u32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };
const box = (type, body = Buffer.alloc(0)) => Buffer.concat([u32(8 + body.length), Buffer.from(type, 'latin1'), body]);

test('readBoxes walks boxes with 32-bit, 64-bit and run-to-the-end sizes', () => {
  const wide = Buffer.concat([u32(1), Buffer.from('wide'), Buffer.from([0, 0, 0, 0, 0, 0, 0, 20]), Buffer.alloc(4)]);
  const toEnd = Buffer.concat([u32(0), Buffer.from('last'), Buffer.alloc(5)]);
  const boxes = readBoxes(Buffer.concat([box('ftyp', Buffer.alloc(4)), wide, toEnd]));
  assert.deepEqual(boxes.map((b) => [b.type, b.start, b.size, b.bodyStart]), [['ftyp', 0, 12, 8], ['wide', 12, 20, 28], ['last', 32, 13, 40]]);
});

test('readBoxes refuses a box that does not fit', () => {
  assert.throws(() => readBoxes(Buffer.from([0, 0, 0, 3, 0x66, 0x72, 0x65, 0x65])), Mp4Error); // smaller than its own header
  assert.throws(() => readBoxes(Buffer.concat([u32(100), Buffer.from('free')])), Mp4Error); // longer than the data
  assert.throws(() => readBoxes(Buffer.from([0, 0, 0, 8, 0x66])), Mp4Error); // a header cut off
});

test('codec strings: avc1 from the avcC record, hvc1 per ISO 14496-15 annex E', () => {
  assert.equal(avcCodecString(Buffer.from([1, 0x4d, 0x00, 0x32, 0xff])), 'avc1.4d0032'); // the repo's capture of a Tapo camera: Main, level 5.0
  assert.equal(avcCodecString(Buffer.from([1, 0x64, 0x00, 0x1f])), 'avc1.64001f');
  const hvcC = Buffer.from([1, 0x01, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 0x3f]);
  assert.equal(hevcCodecString(hvcC), 'hvc1.1.6.L63.90');
  assert.equal(hevcCodecString(hvcC, 'hev1'), 'hev1.1.6.L63.90');
  const high = Buffer.from([1, 0x22, 0x20, 0, 0, 0, 0x80, 0x12, 0, 0, 0, 0, 0x5d]); // Main 10 (profile 2), high tier, level 93, two constraint bytes
  assert.equal(hevcCodecString(high), 'hvc1.2.4.H93.80.12');
});

test('fixtures: init facts and the fragments of every clip', { skip: fixtures.skip }, () => {
  const expected = {
    gop2: { mime: /^video\/mp4; codecs="avc1\.4d401e"$/, size: [640, 360], fragments: 30, keys: 30, loop: 5_400_000 },
    hd: { mime: /^video\/mp4; codecs="avc1\.64001f"$/, size: [1280, 720], fragments: 20, keys: 20, loop: 3_600_000 },
    longgop: { mime: /^video\/mp4; codecs="avc1\.4d401e"$/, size: [640, 360], fragments: 25, keys: 5, loop: 5_400_000 },
    ntsc: { mime: /^video\/mp4; codecs="avc1\.4d401e"$/, size: [640, 360], fragments: 30, keys: 30, loop: 5_405_400 },
    hevc: { mime: /^video\/mp4; codecs="hvc1\.1\.6\.L\d+\.[0-9A-F]{2}"$/, size: [640, 360], fragments: 10, keys: 10, loop: 1_800_000 },
    'res-b': { mime: /^video\/mp4; codecs="avc1\.4d401f"$/, size: [960, 540], fragments: 15, keys: 15, loop: 2_700_000 },
    quiet: { mime: /^video\/mp4; codecs="avc1\.[0-9a-f]{6}"$/, size: [320, 180], fragments: 15, keys: 15, loop: 2_700_000 },
  };
  for (const [name, fixture] of fixtureSet()) {
    const want = expected[name];
    assert.match(fixture.info.mime, want.mime, name);
    assert.deepEqual([fixture.info.width, fixture.info.height], want.size, name);
    assert.equal(fixture.info.timescale, 90_000, `${name} time scale`);
    assert.equal(fixture.info.hasAudio, false, `${name} has no audio`);
    assert.equal(fixture.parts.length, want.fragments, `${name} fragments`);
    assert.equal(fixture.parts.filter((part) => part.key).length, want.keys, `${name} keyframe fragments`);
    assert.equal(fixture.loopTicks, want.loop, `${name} length in ticks`);
    assert.equal(fixture.parts[0].key, true, `${name} starts with a keyframe`);
  }
});

test('fixtures: the long-GOP clip has continuation fragments with the right backToKey', { skip: fixtures.skip }, () => {
  const { parts } = fixtureSet().get('longgop');
  assert.deepEqual(parts.slice(0, 6).map((part) => [part.key, part.backToKey]), [[true, 0], [false, 1], [false, 2], [false, 3], [false, 4], [true, 0]]);
  assert.equal(fixtureSet().get('longgop').gopSeconds, 12);
  assert.ok(parts.every((part) => part.ticks <= 2.55 * 90_000), 'a fragment longer than the recorder cuts');
});

test('fixtures: every fragment is moof + mdat of one traf whose tfdt follows the one before', { skip: fixtures.skip }, () => {
  for (const [name, fixture] of fixtureSet()) {
    const file = parseFile(fixture.buffer);
    let expected = 0;
    for (const fragment of file.fragments) {
      assert.equal(fragment.baseDecodeTime, expected, `${name} tfdt`);
      expected += fragment.duration;
    }
    assert.deepEqual(readBoxes(fixture.buffer).map((b) => b.type).filter((type) => !['moof', 'mdat'].includes(type)), ['ftyp', 'moov'], `${name}: no prft, styp, sidx or mfra`);
  }
});

test('withBaseDecodeTime copies one fragment and changes only its tfdt', { skip: fixtures.skip }, () => {
  const fixture = fixtureSet().get('gop2');
  const fragment = fixture.parts[3].fragment;
  const original = Buffer.from(fixture.buffer);
  const copy = withBaseDecodeTime(fixture.buffer, fragment, 123_456_789);
  assert.equal(copy.length, fragment.end - fragment.moofStart);
  assert.deepEqual(fixture.buffer, original, 'the fixture bytes are untouched');
  const patched = parseFragment(copy, ...readBoxes(copy), fixture.info.defaults);
  assert.equal(patched.baseDecodeTime, 123_456_789);
  assert.equal(patched.duration, fragment.duration);
  const at = fragment.tfdtOffset - fragment.moofStart;
  const same = Buffer.from(copy);
  same.set(original.subarray(fragment.tfdtOffset, fragment.tfdtOffset + 8), at);
  assert.deepEqual(same, original.subarray(fragment.moofStart, fragment.end), 'nothing but the 8 bytes of the tfdt changed');
});

test('fragments patched to the times of a long file read back in order', { skip: fixtures.skip }, () => {
  const fixture = fixtureSet().get('longgop');
  const chunks = [fixture.init];
  for (let n = 0; n < 12; n += 1) chunks.push(fixture.fragmentBytes(n, Math.floor(n / fixture.parts.length) * fixture.loopTicks + fixture.parts[n % fixture.parts.length].startTicks));
  const file = parseFile(Buffer.concat(chunks));
  assert.equal(file.fragments.length, 12);
  assert.equal(file.fragments[11].baseDecodeTime, Math.floor(11 / 25) * fixture.loopTicks + fixture.parts[11].startTicks);
});

test('malformed input is an Mp4Error, never a RangeError or a hang', { skip: fixtures.skip }, () => {
  const fixture = fixtureSet().get('hevc');
  const good = fixture.buffer.subarray(0, fixture.parts[1].fragment.end);
  let seed = 12345;
  const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 2 ** 32; };
  let refused = 0;
  for (let round = 0; round < 400; round += 1) {
    const bytes = Buffer.from(good);
    for (let flips = 1 + Math.floor(random() * 3); flips > 0; flips -= 1) bytes[Math.floor(random() * bytes.length)] ^= 1 << Math.floor(random() * 8);
    const cut = random() < 0.3 ? bytes.subarray(0, Math.floor(random() * bytes.length)) : bytes;
    try {
      parseFile(cut);
    } catch (error) {
      assert.ok(error instanceof Mp4Error, `round ${round}: ${error.name}: ${error.message}`);
      refused += 1;
    }
  }
  assert.ok(refused > 20, `only ${refused} of 400 damaged inputs were refused: the corruption does not reach the parser`);
  for (let length = 0; length < 200; length += 7) assert.throws(() => parseInit(good.subarray(0, length)), Mp4Error, `a ${length} byte prefix`);
});
