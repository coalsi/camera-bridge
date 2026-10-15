import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { analyzeCapture, markdown } from '../web-dev/soak/budget-from-captures.mjs'

// The repo's one real capture (a 2688x1520 camera, 6 key frames of 635,674 bytes in 208 packets) is not committed (Tools/captures is ignored): look for it, by what
// it holds and not by its folder name, in this checkout's Tools/captures, then in the main checkout of the repository (a worktree has none of its own), then
// in CB_CAPTURE_DIR.
function findRepoCapture() {
  const here = path.dirname(fileURLToPath(import.meta.url))
  const roots = [process.env.CB_CAPTURE_DIR, path.resolve(here, '../../Tools/captures')]
  const common = spawnSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: here, encoding: 'utf8' })
  if (common.status === 0) roots.push(path.join(common.stdout.trim().replace(/\/\.git$/, ''), 'Tools/captures'))
  for (const root of roots.filter(Boolean)) {
    const folders = fs.existsSync(path.join(root, 'packets.csv')) ? [root] : fs.existsSync(root) ? fs.readdirSync(root).map((n) => path.join(root, n)) : []
    for (const folder of folders) {
      try {
        const r = analyzeCapture(folder)
        if (r.usable && r.keyframes === 6 && r.avgKeyBytes === 635_674 && r.width === 2688) return folder
      } catch { /* not a capture folder */ }
    }
  }
  return undefined
}
const repoCapture = findRepoCapture()

// A capture folder as capture_stream.sh writes it: ffprobe's streams.json and a packets.csv of "packet,pts_time,size,flags".
function capture({ codec = 'h264', width = 2688, height = 1520, fps = 20, gop = 40, frames = 208, key = 635_674, delta = 1_280, jitter = 0, b = 0, burst = false } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-capture-'))
  fs.writeFileSync(path.join(dir, 'streams.json'), JSON.stringify({ streams: [{ index: 0, codec_name: codec, profile: 'Main', width, height, r_frame_rate: `${fps * 2}/1`, avg_frame_rate: `${fps}/1`, has_b_frames: b, codec_type: 'video' },
    { index: 1, codec_name: 'pcm_alaw', codec_type: 'audio' }] }))
  const rows = []
  // `burst`: one second in five carries ten times the data, like a person walking through the picture.
  const size = (i) => (i % gop === 0 ? key : burst ? (Math.floor(i / fps) % 5 === 0 ? delta * 10 : delta) : delta + (jitter ? (i * 7919) % jitter : 0))
  for (let i = 0; i < frames; i++) rows.push(`packet,N/A,${size(i)},${i % gop === 0 ? 'K__' : '___'}`)
  fs.writeFileSync(path.join(dir, 'packets.csv'), rows.join('\n') + '\n')
  return dir
}

test('a camera like the repo capture gives the numbers in the addendum (L1)', () => {
  const dir = capture()
  try {
    const r = analyzeCapture(dir)
    assert.equal(r.usable, true)
    assert.equal(r.keyframes, 6)
    assert.equal(r.avgKeyBytes, 635_674)
    assert.equal(r.avgDeltaBytes, 1_280)
    assert.equal(r.gopSeconds, 2)
    assert.equal(r.seconds, 10.4)
    assert.ok(r.bitrateKbps > 3000 && r.bitrateKbps < 3200, String(r.bitrateKbps))
    assert.ok(r.keyShare > 0.9 && r.keyShare < 0.95)
    assert.ok(r.keyFragmentBytes > 650_000 && r.keyFragmentBytes < 750_000, String(r.keyFragmentBytes))
    assert.equal(r.fragmentUnderCap && r.leadInSingleOk && r.leadInGridOk, true)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('the real repo capture, when it is there, reproduces 6 keyframes of 635,674 bytes and 4,072,600 bytes in 10.4 s', { skip: !repoCapture && 'Tools/captures is not committed' }, () => {
  const r = analyzeCapture(repoCapture)
  assert.equal(r.keyframes, 6); assert.equal(r.avgKeyBytes, 635_674); assert.equal(r.maxKeyBytes, 670_271); assert.equal(r.avgDeltaBytes, 1_280); assert.equal(r.seconds, 10.4)
})

test('a long GOP is flagged by what it does to scrubbing, and a huge one by what it does to the lead-in', () => {
  const dirs = [capture({ fps: 25, gop: 300, frames: 900, key: 400_000, delta: 20_000 }), capture({ fps: 25, gop: 1500, frames: 3000, key: 400_000, delta: 30_000 })]
  try {
    const [a, b] = dirs.map(analyzeCapture)
    assert.equal(a.gopSeconds, 12); assert.equal(a.longGop, true); assert.equal(a.slowScrubNote, true)
    assert.equal(a.leadInSingleOk, true)
    assert.equal(b.gopSeconds, 60); assert.equal(b.leadInSingleOk, false); assert.equal(b.leadInGridOk, false)
    assert.equal(b.keyFragmentBytes, Math.round(400_000 + 61 * 30_000))
    const text = markdown([a, b])
    assert.match(text, /over 16 MiB: coarse/)
    assert.match(text, /scrubbing is slow/)
  } finally { for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }) }
})

test('an 8 Mbps camera: storage, days, and a fragment that fits the cap', () => {
  const dir = capture({ fps: 25, gop: 50, frames: 500, key: 230_000, delta: 36_000 })
  try {
    const r = analyzeCapture(dir)
    assert.ok(Math.abs(r.bitrateKbps - 8000) < 400, String(r.bitrateKbps))
    assert.ok(Math.abs(r.gbPerDay - 86.4) < 4, String(r.gbPerDay))
    assert.ok(r.daysAt500GB > 5 && r.daysAt500GB < 6.5)
    assert.equal(r.fragmentUnderCap, true)
    assert.deepEqual(Object.keys(r.soakProfile), ['width', 'height', 'fps', 'gopSeconds', 'bitrateKbps'])
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a constant bit rate camera is said to draw a flat waveform; a varying one is not', () => {
  const flat = capture({ fps: 25, gop: 50, frames: 500, key: 230_000, delta: 36_000, jitter: 1 }), varying = capture({ fps: 25, gop: 50, frames: 500, key: 230_000, delta: 4_000, burst: true })
  try {
    assert.equal(analyzeCapture(flat).waveformFlat, true)
    assert.equal(analyzeCapture(varying).waveformFlat, false)
  } finally { for (const d of [flat, varying]) fs.rmSync(d, { recursive: true, force: true }) }
})

test('an H.265 camera has no packet list and the report says what that means; the folder name never appears', () => {
  const dir = capture({ codec: 'hevc', frames: 0 })
  try {
    const r = analyzeCapture(dir)
    assert.equal(r.usable, false)
    const text = markdown([r])
    assert.match(text, /H\.265/)
    assert.ok(!text.includes(path.basename(dir)))
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

// Added in T15 step 7 (not in the plan's block): the plan's own command `node budget-from-captures.mjs Tools/captures/*` crashed on the loose link
// that the repo's checkout keeps beside the capture folder.
test('the command line skips loose files and links in a glob, counts them without naming them, and still reports the capture folders', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-capture-glob-'))
  const dir = capture({ fps: 25, gop: 50, frames: 500, key: 230_000, delta: 36_000 })
  try {
    const folder = path.join(root, 'cam-1'); fs.renameSync(dir, folder)
    fs.writeFileSync(path.join(root, 'loose.h264'), 'x'); fs.symlinkSync(path.join(folder, 'packets.csv'), path.join(root, 'link.h264'))
    const tool = path.join(path.dirname(fileURLToPath(import.meta.url)), '../web-dev/soak/budget-from-captures.mjs')
    const run = spawnSync('node', [tool, folder, path.join(root, 'loose.h264'), path.join(root, 'link.h264')], { encoding: 'utf8' })
    assert.equal(run.status, 0, run.stderr)
    assert.match(run.stderr, /skipped 2 argument\(s\)/)
    assert.ok(!run.stderr.includes('loose') && !run.stderr.includes('link.h264') && !run.stdout.includes('cam-1'))
    assert.match(run.stdout, /2560x1440|1520/)
    const none = spawnSync('node', [tool, path.join(root, 'loose.h264')], { encoding: 'utf8' })
    assert.equal(none.status, 2)
  } finally { fs.rmSync(root, { recursive: true, force: true }) }
})
