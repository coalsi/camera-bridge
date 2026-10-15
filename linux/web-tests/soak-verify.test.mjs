import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { verify, listTree, decodeCheck, readList, readDamaged } from '../web-dev/soak/verify-files.mjs'
import { damage } from '../web-dev/soak/damage.mjs'
import { makeFile } from './soak-recording-fixture.mjs'

function tree() {
  const run = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-verify-'))
  fs.writeFileSync(path.join(run, '.soak-run'), '')
  const root = path.join(run, 'rec')
  for (const camera of ['CAM-1', 'CAM-2']) {
    const day = path.join(root, camera, '2026-10-11')
    fs.mkdirSync(day, { recursive: true })
    fs.writeFileSync(path.join(root, camera, 'camera.json'), '{}')
    for (const name of ['07-00-00', '07-15-00', '07-30-00']) makeFile(day, name)
    makeFile(day, '07-45-00'); fs.rmSync(path.join(day, '07-45-00.cbidx'))
  }
  return { run, root }
}

test('a sound tree has nothing wrong; open files are counted, not blamed', () => {
  const { run, root } = tree()
  try {
    const found = listTree(root)
    assert.equal(found.closed.length, 6); assert.equal(found.open.length, 2); assert.deepEqual(found.strays, [])
    const result = verify(root, { sample: 0, decode: 0, allowOpen: 2 })
    assert.deepEqual(result.problems, [])
    assert.equal(result.checked, 6)
    assert.match(verify(root, { sample: 0, decode: 0, allowOpen: 1 }).problems.join(), /2 files without a sidecar, at most 1/)
  } finally { fs.rmSync(run, { recursive: true, force: true }) }
})

test('damage to a closed file or a stray file in the tree is found; repair of listed files is demanded', () => {
  const { run, root } = tree()
  try {
    fs.appendFileSync(path.join(root, 'CAM-1/2026-10-11/07-30-00.mp4'), 'junk')
    fs.writeFileSync(path.join(root, 'CAM-2/2026-10-11/07-30-00.mp4.tmp'), '')
    fs.writeFileSync(path.join(root, 'CAM-2/notes.txt'), '')
    const result = verify(root, { sample: 0, decode: 0 })
    const text = result.problems.join('\n')
    assert.match(text, /CAM-1\/2026-10-11\/07-30-00.mp4: sidecar says/)
    assert.match(text, /stray file CAM-2\/2026-10-11\/07-30-00.mp4.tmp/)
    assert.match(text, /stray file CAM-2\/notes.txt/)
    assert.match(verify(root, { sample: 0, decode: 0, mustBeClosed: ['CAM-1/2026-10-11/07-45-00.mp4'] }).problems.join(), /07-45-00.mp4: still has no sidecar after recovery/)
  } finally { fs.rmSync(run, { recursive: true, force: true }) }
})

test('after a cut the open file is not "sound" until it has a sidecar that matches what is left', () => {
  const { run, root } = tree()
  try {
    damage(root, 'cut-mdat', { seed: 4 })
    assert.equal(verify(root, { sample: 0, decode: 0, allowOpen: 2 }).problems.length, 0, 'open files are only counted')
    // What a good recovery does: write the sidecar for the whole fragments that are left. Here: rebuild the file as a shorter, sound one.
    for (const camera of ['CAM-1', 'CAM-2']) {
      const day = path.join(root, camera, '2026-10-11')
      fs.rmSync(path.join(day, '07-45-00.mp4')); makeFile(day, '07-45-00', { fragments: 4 })
    }
    assert.deepEqual(verify(root, { sample: 0, decode: 0, mustBeClosed: ['CAM-1/2026-10-11/07-45-00.mp4'] }).problems, [])
  } finally { fs.rmSync(run, { recursive: true, force: true }) }
})

test('the decode check runs ffmpeg and ffprobe and compares packet counts (stubbed)', () => {
  const calls = []
  const run = (command, args) => { calls.push(command); return command === 'ffmpeg' ? { status: 0, stderr: '', stdout: '' } : { status: 0, stdout: '50\n', stderr: '' } }
  assert.deepEqual(decodeCheck('x.mp4', 50, run), [])
  assert.deepEqual(calls, ['ffmpeg', 'ffprobe'])
  assert.match(decodeCheck('x.mp4', 60, run).join(), /50 video packets, the sidecar counts 60/)
  assert.match(decodeCheck('x.mp4', undefined, () => ({ status: 1, stderr: 'Invalid data found when processing input\n', stdout: '' })).join(), /ffmpeg: Invalid data/)
  assert.match(decodeCheck('x.mp4', 1, () => ({ error: new Error('ENOENT') })).join(), /could not run/)
})

const haveFfmpeg = spawnSync('ffmpeg', ['-version']).status === 0
test('with a real ffmpeg: a real fragmented file decodes, a cut one does not', { skip: !haveFfmpeg && 'ffmpeg is not installed' }, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-ff-'))
  try {
    const file = path.join(dir, 'real.mp4')
    const made = spawnSync('ffmpeg', ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=size=160x120:rate=25', '-t', '3', '-c:v', 'libx264', '-g', '25', '-movflags', 'frag_keyframe+empty_moov+default_base_moof', file], { encoding: 'utf8' })
    assert.equal(made.status, 0, made.stderr)
    assert.deepEqual(decodeCheck(file, 75), [])
    assert.match(decodeCheck(file, 74).join(), /75 video packets/)
    fs.truncateSync(file, Math.floor(fs.statSync(file).size * 0.6))
    assert.ok(decodeCheck(file, undefined).length > 0, 'a cut file is reported')
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('lists of files come as JSON or as lines, and a damage report names its files', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-list-'))
  try {
    fs.writeFileSync(path.join(dir, 'a.json'), '["CAM-1/2026-10-11/07-45-00.mp4"]')
    fs.writeFileSync(path.join(dir, 'b.txt'), 'CAM-1/2026-10-11/07-45-00.mp4\n\nCAM-2/2026-10-11/07-45-00.mp4\n')
    fs.writeFileSync(path.join(dir, 'c.jsonl'), '{"camera":"CAM-1","file":"CAM-1/2026-10-11/07-30-00.mp4","action":"x"}\n')
    assert.deepEqual(readList(path.join(dir, 'a.json')), ['CAM-1/2026-10-11/07-45-00.mp4'])
    assert.equal(readList(path.join(dir, 'b.txt')).length, 2)
    assert.deepEqual(readDamaged(path.join(dir, 'c.jsonl')), ['CAM-1/2026-10-11/07-30-00.mp4'])
    fs.writeFileSync(path.join(dir, 'empty.txt'), '')
    assert.deepEqual(readList(path.join(dir, 'empty.txt')), [])
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})
