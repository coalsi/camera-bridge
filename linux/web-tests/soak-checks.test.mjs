import test from 'node:test'
import assert from 'node:assert/strict'
import { topBoxes, checkSegment, checkInit, checkPartHeader, checkPlan, checkAfter, checkCameras, checkActivity } from '../web-dev/soak/checks.mjs'

function box(type, payloadBytes) {
  const b = Buffer.alloc(8 + payloadBytes)
  b.writeUInt32BE(b.length, 0)
  b.write(type, 4, 'latin1')
  return b
}

test('a moof and an mdat that fill the answer pass; every other shape says why not', () => {
  const good = Buffer.concat([box('moof', 1000), box('mdat', 5000)])
  assert.equal(checkSegment(good.subarray(0, 4096), good.length), null)
  assert.match(checkSegment(Buffer.concat([box('prft', 24), box('moof', 100), box('mdat', 100)]), 8 + 24 + 108 + 108), /wanted moof,mdat/)
  assert.match(checkSegment(good.subarray(0, 4096), good.length - 1), /is not/)
  assert.match(checkSegment(Buffer.concat([box('moof', 1000), box('mdat', 0)]), 1008 + 8), /empty mdat/)
  assert.match(checkSegment(Buffer.alloc(0), 3), /only 3 bytes/)
  const huge = Buffer.concat([box('moof', 8000), box('mdat', 100)])
  assert.match(checkSegment(huge.subarray(0, 4096), huge.length), /larger than the part kept/)
})

test('a box that claims less than its header is an error, and a 64-bit size is read', () => {
  const broken = Buffer.alloc(32); broken.writeUInt32BE(4, 0); broken.write('moof', 4, 'latin1')
  assert.match(topBoxes(broken, 32).error, /claims 4 bytes/)
  const big = Buffer.alloc(16); big.writeUInt32BE(1, 0); big.write('mdat', 4, 'latin1'); big.writeBigUInt64BE(40n, 8)
  assert.equal(topBoxes(big, 40).boxes[0].size, 40)
})

test('an init segment is ftyp then moov', () => {
  const good = Buffer.concat([box('ftyp', 12), box('moov', 600)])
  assert.equal(checkInit(good, good.length), null)
  assert.match(checkInit(Buffer.concat([box('moov', 600), box('ftyp', 12)]), 640), /wanted ftyp,moov/)
})

const part = { id: 'a1b2c3d4e5f6.17', file: 'a1b2c3d4e5f6', start: 1_760_000_000_000, end: 1_760_000_002_500, mime: 'video/mp4; codecs="avc1.4d0032"', width: 2688, height: 1520, anchor: 1760099000000.25, initId: 'a1b2c3d4e5f6.17' }

test('the X-CB-Part header', () => {
  assert.equal(checkPartHeader(JSON.stringify(part)), null)
  assert.match(checkPartHeader('{'), /not JSON/)
  assert.match(checkPartHeader(JSON.stringify({ ...part, end: part.start })), /start\/end/)
  assert.match(checkPartHeader(JSON.stringify({ ...part, id: 'zz.1' })), /fragment ids/)
  assert.match(checkPartHeader(JSON.stringify({ ...part, mime: 'audio/mp4' })), /mime/)
  const { anchor, ...missing } = part
  assert.match(checkPartHeader(JSON.stringify(missing)), /no anchor/)
})

const files = { a1b2c3d4e5f6: { mime: 'video/mp4; codecs="avc1.4d0032"', width: 2688, height: 1520, anchor: 1, initId: 'a1b2c3d4e5f6.0', sound: false } }
const p = (i, start) => ({ id: `a1b2c3d4e5f6.${i}`, file: 'a1b2c3d4e5f6', start, end: start + 2500, bytes: 1000, key: i === 0 })

test('a plan, found or not', () => {
  const plan = { serverTime: 1, found: true, at: 5, exact: true, targetIndex: 1, parts: [p(0, 0), p(1, 2500)], files }
  assert.equal(checkPlan(plan), null)
  assert.equal(checkPlan({ serverTime: 1, found: false, at: 5, reason: 'gap', next: 9, newest: 20 }), null)
  assert.match(checkPlan({ serverTime: 1, found: false, reason: 'weather' }), /reason/)
  assert.match(checkPlan({ ...plan, targetIndex: 2 }), /targetIndex/)
  assert.match(checkPlan({ ...plan, files: {} }), /no file info/)
  assert.match(checkPlan({ ...plan, parts: [p(1, 2500), p(0, 0)] }), /overlap/)
  assert.match(checkPlan({ ...plan, parts: [] }), /empty/)
})

test('an after answer may be empty; cameras and activity', () => {
  assert.equal(checkAfter({ serverTime: 1, parts: [], files: {} }), null)
  assert.match(checkAfter({ serverTime: 1, parts: [{ ...p(1, 0), id: 'x' }], files }), /bad part id/)
  assert.equal(checkCameras({ serverTime: 1, catalogVersion: 3, cameras: [{ id: 'A', oldest: 1, newest: 2, typicalGOP: null }] }), null)
  assert.match(checkCameras({ serverTime: 1, catalogVersion: 3, cameras: [{ id: 'A', oldest: 5, newest: 2 }] }), /bad extent/)
  assert.equal(checkActivity({ bins: 2, byCamera: { A: { typical: null, complete: true, coverage: [0, 1], level: [0, 5] } } }, 2), null)
  assert.match(checkActivity({ bins: 2, byCamera: { A: { coverage: [0], level: [0, 5] } } }, 2), /not 2 long/)
})
