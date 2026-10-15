import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { parseFragmented, splitFile } from '../split-fmp4.mjs'
import { avcC, clip, hvcC } from './fmp4-builder.mjs'
import { codecString } from '../split-fmp4.mjs'

test('a 2 s GOP cut at keyframes gives one key fragment per GOP', () => {
  const parsed = parseFragmented(clip({ gops: 3, gopFrames: 40, fragmentFrames: 40 }))
  assert.equal(parsed.parts.length, 3)
  assert.deepEqual(parsed.parts.map((p) => p.key), [true, true, true])
  assert.deepEqual(parsed.parts.map((p) => p.backToKey), [0, 0, 0])
  assert.deepEqual(parsed.parts.map((p) => p.startTick), [0, 180000, 360000])
  assert.equal(parsed.frames.length, 120)
  assert.deepEqual(parsed.frames[0], [0, 1])
  assert.deepEqual(parsed.frames[1], [4500, 0])
  assert.equal(parsed.video.width, 640)
  assert.equal(parsed.video.height, 360)
  assert.equal(parsed.video.timescale, 90000)
})

test('continuation fragments count back to the fragment with the keyframe', () => {
  // 2 GOPs of 100 frames cut every 50 frames: key, cont, key, cont
  const parsed = parseFragmented(clip({ gops: 2, gopFrames: 100, fragmentFrames: 50 }))
  assert.deepEqual(parsed.parts.map((p) => p.key), [true, false, true, false])
  assert.deepEqual(parsed.parts.map((p) => p.backToKey), [0, 1, 0, 1])
  assert.deepEqual(parsed.parts.map((p) => p.frameFirst), [0, 50, 100, 150])
})

test('the served form has no prft and the stored form has one', () => {
  const buffer = clip({ gops: 1, gopFrames: 40, fragmentFrames: 40 })
  const dir = mkdtempSync(join(tmpdir(), 'cb-split-'))
  try {
    const input = join(dir, 'in.mp4')
    writeFileSync(input, buffer)
    const manifest = splitFile(input, join(dir, 'out'), { id: 't', mime: 'video/mp4; codecs="avc1.4d001f"', stored: true })
    const served = readFileSync(join(dir, 'out', manifest.parts[0].file))
    const stored = readFileSync(join(dir, 'out', manifest.parts[0].stored))
    assert.equal(served.toString('latin1', 4, 8), 'moof')
    assert.equal(stored.toString('latin1', 4, 8), 'prft')
    assert.equal(stored.length, served.length + 32)
    assert.equal(manifest.parts[0].bytes, served.length)
    const init = readFileSync(join(dir, 'out', 'init.mp4'))
    assert.equal(init.toString('latin1', 4, 8), 'ftyp')
    assert.equal(manifest.init.bytes, init.length)
    assert.equal(manifest.mime, 'video/mp4; codecs="avc1.4d001f"')
    assert.equal(manifest.hasAudio, false)
  } finally { rmSync(dir, { recursive: true, force: true }) }
})

test('an audio traf is detected and the video samples are still read', () => {
  const parsed = parseFragmented(clip({ gops: 2, gopFrames: 40, fragmentFrames: 40, audio: true }))
  assert.equal(parsed.parts.length, 2)
  assert.equal(parsed.parts[0].hasAudio, true)
  assert.equal(parsed.tracks.some((t) => t.handler === 'soun'), true)
  assert.equal(parsed.frames.length, 80)
})

test('a file without prft splits too', () => {
  const parsed = parseFragmented(clip({ gops: 2, gopFrames: 40, fragmentFrames: 40, prft: false }))
  assert.equal(parsed.parts.length, 2)
  assert.equal(parsed.parts[0].hasPrft, false)
})

test('the codec string comes from avcC and hvcC', () => {
  assert.equal(parseFragmented(clip({})).video.codec, 'avc1.4d001f')
  assert.equal(parseFragmented(clip({ config: avcC(0x64, 0x00, 0x33) })).video.codec, 'avc1.640033')
  assert.equal(parseFragmented(clip({ entry: 'hvc1', config: hvcC() })).video.codec, 'hvc1.1.6.L93.90')
  assert.equal(typeof codecString, 'function')
})

test('truncated and malformed input throws instead of reading past the end', () => {
  const good = clip({ gops: 1 })
  assert.throws(() => parseFragmented(good.subarray(0, good.length - 40)))
  assert.throws(() => parseFragmented(Buffer.from('not an mp4 at all, just text')))
  const noFragments = good.subarray(0, good.indexOf(Buffer.from('prft')) - 4)
  assert.throws(() => parseFragmented(noFragments), /no fragment/)
})

// Integration with ffmpeg, skipped when ffmpeg is not installed.
const haveFfmpeg = spawnSync('ffmpeg', ['-version']).status === 0
test('ffmpeg output: keyframe fragments, and a 2.5 s cut inside a long GOP', { skip: !haveFfmpeg }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'cb-split-ff-'))
  try {
    const input = join(dir, 'long.mp4')
    execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=20', '-t', '12',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-g', '120', '-keyint_min', '120', '-x264-params', 'scenecut=0:bframes=0',
      '-video_track_timescale', '90000', '-movflags', 'frag_keyframe+empty_moov+default_base_moof', '-frag_duration', '2500000',
      '-write_prft', 'pts', input])
    const parsed = parseFragmented(readFileSync(input))
    // 6 s GOPs cut every 2.5 s: key(2.5 s) cont(2.5 s) cont(1 s) key ...
    assert.equal(parsed.parts[0].key, true)
    assert.equal(parsed.parts[1].key, false)
    assert.equal(parsed.parts[1].backToKey, 1)
    assert.equal(parsed.parts[0].hasPrft, true)
    assert.equal(parsed.frames.length, 240)
    assert.equal(parsed.frames.every(([pts], i) => pts === i * 4500), true)
  } finally { rmSync(dir, { recursive: true, force: true }) }
})
