import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { damage, VARIANTS } from '../web-dev/soak/damage.mjs'
import { scanMp4, checkClosedFile } from '../web-dev/soak/mp4scan.mjs'
import { makeFile } from './soak-recording-fixture.mjs'

// Two cameras, each with one closed file (mp4 + sidecar) and one open file (mp4 only), under a run folder marked as a soak run.
function setup() {
  const run = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-damage-'))
  fs.writeFileSync(path.join(run, '.soak-run'), '')
  const root = path.join(run, 'rec')
  for (const camera of ['AAAAAAAA-0000-4000-8000-000000000001', 'AAAAAAAA-0000-4000-8000-000000000002']) {
    const day = path.join(root, camera, '2026-10-11')
    fs.mkdirSync(day, { recursive: true })
    fs.writeFileSync(path.join(root, camera, 'camera.json'), JSON.stringify({ id: camera, name: 'x' }))
    makeFile(day, '08-00-00')
    makeFile(day, '08-15-00', { fragments: 6 })
    fs.rmSync(path.join(day, '08-15-00.cbidx'))   // the second file was open when the process died
  }
  return { run, root, cameras: fs.readdirSync(root) }
}
const open = (root, camera) => path.join(root, camera, '2026-10-11', '08-15-00.mp4')
const closed = (root, camera) => [path.join(root, camera, '2026-10-11', '08-00-00.mp4'), path.join(root, camera, '2026-10-11', '08-00-00.cbidx')]

test('it refuses a folder that is not in a soak run', () => {
  const { run, root } = setup()
  try {
    fs.rmSync(path.join(run, '.soak-run'))
    assert.throws(() => damage(root, 'cut-mdat'), /not a soak run/)
    assert.throws(() => damage(root, 'weather'), /not a soak run/)
    fs.writeFileSync(path.join(run, '.soak-run'), '')
    assert.throws(() => damage(root, 'weather'), /unknown variant/)
  } finally { fs.rmSync(run, { recursive: true, force: true }) }
})

test('every cut leaves the whole fragments before it and a tail, and never touches the closed file', () => {
  for (const variant of ['cut-mdat', 'cut-moof', 'cut-prft', 'cut-boundary']) {
    for (const seed of [1, 2, 3, 4, 5]) {
      const { run, root, cameras } = setup()
      try {
        const before = scanMp4(open(root, cameras[0])).fragments.length
        const changes = damage(root, variant, { seed })
        assert.equal(changes.length, 2, variant)
        const scan = scanMp4(open(root, cameras[0]))
        assert.equal(scan.fragments.length, before - 1, `${variant}/${seed}: the last fragment is no longer whole`)
        assert.deepEqual(checkClosedFile(...closed(root, cameras[0])), [])
        if (variant === 'cut-boundary') assert.equal(scan.tail, 0)
      } finally { fs.rmSync(run, { recursive: true, force: true }) }
    }
  }
})

test('zero-tail keeps every fragment and adds a tail; zero-last keeps the size', () => {
  const { run, root, cameras } = setup()
  try {
    const size = fs.statSync(open(root, cameras[0])).size
    damage(root, 'zero-tail')
    assert.equal(fs.statSync(open(root, cameras[0])).size, size + 1024 * 1024)
    assert.equal(scanMp4(open(root, cameras[0])).fragments.length, 6)
  } finally { fs.rmSync(run, { recursive: true, force: true }) }
  const second = setup()
  try {
    const size = fs.statSync(open(second.root, second.cameras[0])).size
    damage(second.root, 'zero-last')
    assert.equal(fs.statSync(open(second.root, second.cameras[0])).size, size)
    assert.equal(scanMp4(open(second.root, second.cameras[0])).fragments.length, 5, 'the zeroed last fragment is no longer a fragment')
  } finally { fs.rmSync(second.run, { recursive: true, force: true }) }
})

test('sidecar variants change only the newest closed file of each camera', () => {
  for (const [variant, expect] of [['lose-sidecar', /sidecar: /], ['bad-sidecar', /sidecar: /], ['stale-sidecar', /sidecar says/]]) {
    const { run, root, cameras } = setup()
    try {
      const changes = damage(root, variant)
      assert.equal(changes.length, 2, variant)
      const [mp4, cbidx] = closed(root, cameras[0])
      if (variant === 'lose-sidecar') assert.ok(!fs.existsSync(cbidx))
      else assert.match(checkClosedFile(mp4, cbidx).join(), expect)
      assert.equal(scanMp4(open(root, cameras[0])).fragments.length, 6, 'open files are not touched by sidecar variants')
      assert.ok(!JSON.stringify(changes).includes(run), 'no absolute path in the report')
    } finally { fs.rmSync(run, { recursive: true, force: true }) }
  }
  assert.equal(VARIANTS.length, 9)
})
