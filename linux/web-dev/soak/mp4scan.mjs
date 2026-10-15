// Reads the structure of a recorded file the way the archive's recovery scanner has to: ftyp, moov, then fragments of (prft) moof mdat. Reads
// only box headers, so a 2 GiB file costs a few thousand small reads. Also reads and checks a .cbidx sidecar (T00 B.8) from the spec alone,
// so the tests that use it do not depend on the engine's own codec.
import fs from 'node:fs'

// { size, initLength, fragments: [{ offset, length }], problems: [string] }. A fragment starts at its prft if it has one, else at its moof,
// and ends at the end of its mdat. A tail that is not a whole fragment is reported in `tail` (bytes) and is not a problem for a file
// that was open when the process died.
export function scanMp4(file) {
  const fd = fs.openSync(file, 'r')
  try {
    const size = fs.fstatSync(fd).size
    const header = Buffer.alloc(16)
    const problems = []
    const boxes = []
    let offset = 0
    while (offset + 8 <= size) {
      fs.readSync(fd, header, 0, 16, offset)
      let boxSize = header.readUInt32BE(0)
      const type = header.toString('latin1', 4, 8)
      if (boxSize === 1) boxSize = Number(header.readBigUInt64BE(8))
      else if (boxSize === 0) boxSize = size - offset
      if (boxSize < 8 || !/^[\x20-\x7e]{4}$/.test(type)) { problems.push(`not a box at ${offset}`); break }
      if (offset + boxSize > size) { boxes.push({ type, offset, size: boxSize, truncated: true }); break }
      boxes.push({ type, offset, size: boxSize })
      offset += boxSize
    }
    const fragments = []
    let initLength = 0
    let i = 0
    if (boxes[0]?.type === 'ftyp' && boxes[1]?.type === 'moov' && !boxes[1].truncated) { initLength = boxes[1].offset + boxes[1].size; i = 2 } else problems.push('no ftyp and moov at the start')
    let tail = 0
    while (i < boxes.length) {
      const start = boxes[i]
      let j = i
      if (boxes[j].type === 'prft') j++
      if (boxes[j]?.type === 'moof' && boxes[j + 1]?.type === 'mdat' && !boxes[j].truncated && !boxes[j + 1].truncated) {
        fragments.push({ offset: start.offset, length: boxes[j + 1].offset + boxes[j + 1].size - start.offset })
        i = j + 2
      } else {
        tail = size - start.offset
        break
      }
    }
    if (i >= boxes.length && boxes.length) tail = 0
    return { size, initLength, fragments, problems, tail }
  } finally { fs.closeSync(fd) }
}

// ---- the .cbidx v1 sidecar -----------------------------------------------------------------------------------------------------------
export const CBIDX = { header: 64, rollup: 12, record: 40 }

export function readCBIndex(file) {
  const data = fs.readFileSync(file)
  if (data.length < CBIDX.header) return { error: `only ${data.length} bytes` }
  if (data.toString('latin1', 0, 4) !== 'CBNX') return { error: 'bad magic' }
  const version = data.readUInt16BE(4)
  if (version !== 1) return { error: `version ${version}` }
  const index = {
    flags: data.readUInt16BE(6), startWallMs: Number(data.readBigInt64BE(24)), endWallMs: Number(data.readBigInt64BE(32)), mp4Size: Number(data.readBigUInt64BE(40)),
    initLength: data.readUInt32BE(48), count: data.readUInt32BE(52), rollupCount: data.readUInt16BE(56),
  }
  const expected = CBIDX.header + index.rollupCount * CBIDX.rollup + index.count * CBIDX.record
  if (data.length !== expected) return { error: `size ${data.length}, expected ${expected}` }
  index.records = []
  let at = CBIDX.header + index.rollupCount * CBIDX.rollup
  for (let n = 0; n < index.count; n++, at += CBIDX.record) {
    index.records.push({ offset: Number(data.readBigUInt64BE(at)), length: data.readUInt32BE(at + 8), wallDeltaMs: data.readUInt32BE(at + 12), mediaStart: data.readUInt32BE(at + 16),
      durationTicks: data.readUInt32BE(at + 20), headerLength: data.readUInt32BE(at + 24), keyLength: data.readUInt32BE(at + 28), nonKeyBytes: data.readUInt32BE(at + 32),
      samples: data.readUInt16BE(at + 36), backToKey: data.readUInt16BE(at + 38) })
  }
  return index
}

// What is wrong with a closed file, comparing its sidecar with a fresh scan of the mp4. [] when it is sound.
export function checkClosedFile(mp4File, cbidxFile) {
  const problems = []
  const scan = scanMp4(mp4File)
  problems.push(...scan.problems)
  if (scan.tail !== 0) problems.push(`${scan.tail} bytes after the last whole fragment`)
  const index = readCBIndex(cbidxFile)
  if (index.error) return [...problems, `sidecar: ${index.error}`]
  if (index.mp4Size !== scan.size) problems.push(`sidecar says ${index.mp4Size} bytes, the file has ${scan.size}`)
  if (index.initLength !== scan.initLength) problems.push(`sidecar initLength ${index.initLength}, scan ${scan.initLength}`)
  if (index.count !== scan.fragments.length) problems.push(`sidecar has ${index.count} fragments, the scan found ${scan.fragments.length}`)
  else index.records.forEach((r, n) => { if (r.offset !== scan.fragments[n].offset || r.length !== scan.fragments[n].length) problems.push(`fragment ${n}: sidecar ${r.offset}+${r.length}, scan ${scan.fragments[n].offset}+${scan.fragments[n].length}`) })
  for (let n = 1; n < index.records.length; n++) {
    if (index.records[n].wallDeltaMs < index.records[n - 1].wallDeltaMs || index.records[n].mediaStart < index.records[n - 1].mediaStart) { problems.push(`fragment ${n} goes back in time`); break }
  }
  return problems.slice(0, 10)
}
