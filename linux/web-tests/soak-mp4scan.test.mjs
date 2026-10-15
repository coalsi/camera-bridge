import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { scanMp4, readCBIndex, checkClosedFile } from '../web-dev/soak/mp4scan.mjs'
import { makeFile } from './soak-recording-fixture.mjs'

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'soak-scan-'))

test('a whole file scans into its init segment and fragments, with or without prft', () => {
  const dir = tmp()
  try {
    for (const withPrft of [true, false]) {
      const made = makeFile(dir, withPrft ? 'a' : 'b', { withPrft })
      const scan = scanMp4(path.join(dir, withPrft ? 'a.mp4' : 'b.mp4'))
      assert.equal(scan.initLength, made.initLength)
      assert.equal(scan.fragments.length, 5)
      assert.deepEqual(scan.fragments.map((f) => [f.offset, f.length]), made.records.map((r) => [r.offset, r.length]))
      assert.equal(scan.tail, 0)
      assert.deepEqual(scan.problems, [])
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a file cut inside a fragment keeps the whole fragments and reports the tail', () => {
  const dir = tmp()
  try {
    const made = makeFile(dir, 'a')
    for (const cut of [made.records[4].offset + 10, made.records[4].offset + 40, made.records[4].offset + 160, made.records[4].offset + made.records[4].length - 1, made.records[4].offset]) {
      fs.truncateSync(path.join(dir, 'a.mp4'), cut)
      const scan = scanMp4(path.join(dir, 'a.mp4'))
      assert.equal(scan.fragments.length, 4, `cut at ${cut}`)
      assert.equal(scan.tail, cut - made.records[4].offset, `cut at ${cut}`)
    }
    fs.truncateSync(path.join(dir, 'a.mp4'), 30)
    assert.match(scanMp4(path.join(dir, 'a.mp4')).problems.join(), /no ftyp and moov/)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('zero bytes after the last fragment are a tail, not a fragment', () => {
  const dir = tmp()
  try {
    makeFile(dir, 'a')
    fs.appendFileSync(path.join(dir, 'a.mp4'), Buffer.alloc(4096))
    const scan = scanMp4(path.join(dir, 'a.mp4'))
    assert.equal(scan.fragments.length, 5)
    assert.ok(scan.problems.length > 0 || scan.tail > 0)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('the sidecar is read from the spec and compared with a fresh scan', () => {
  const dir = tmp()
  try {
    const made = makeFile(dir, 'a')
    const index = readCBIndex(path.join(dir, 'a.cbidx'))
    assert.equal(index.count, 5)
    assert.deepEqual(index.records[2], made.records[2])
    assert.deepEqual(checkClosedFile(path.join(dir, 'a.mp4'), path.join(dir, 'a.cbidx')), [])
    fs.appendFileSync(path.join(dir, 'a.mp4'), Buffer.from('junk'))
    assert.match(checkClosedFile(path.join(dir, 'a.mp4'), path.join(dir, 'a.cbidx')).join(), /sidecar says/)
    fs.truncateSync(path.join(dir, 'a.cbidx'), 100)
    assert.match(checkClosedFile(path.join(dir, 'a.mp4'), path.join(dir, 'a.cbidx')).join(), /sidecar: size 100/)
    fs.writeFileSync(path.join(dir, 'a.cbidx'), Buffer.alloc(64))
    assert.match(checkClosedFile(path.join(dir, 'a.mp4'), path.join(dir, 'a.cbidx')).join(), /bad magic/)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})
