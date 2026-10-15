// Builds recorded files and their sidecars the way the recorder does (T00 B.8; Mac spec 4.2), from the spec and not from the engine's code,
// for the tests of the soak tools. Not a test file.
import fs from 'node:fs'
import path from 'node:path'

function box(type, payload) { const b = Buffer.alloc(8 + payload); b.writeUInt32BE(b.length, 0); b.write(type, 4, 'latin1'); return b }

// A recorded file and its sidecar, built from the layout in T00 B.8 and Mac spec 4.2: ftyp+moov, then prft+moof+mdat per fragment.
export function makeFile(dir, name, { fragments = 5, withPrft = true, payload = 3000 } = {}) {
  const parts = [box('ftyp', 24), box('moov', 500)]
  const initLength = parts[0].length + parts[1].length
  const records = []
  let offset = initLength
  for (let n = 0; n < fragments; n++) {
    const f = [...(withPrft ? [box('prft', 24)] : []), box('moof', 100), box('mdat', payload + n)]
    const length = f.reduce((s, b) => s + b.length, 0)
    records.push({ offset, length, wallDeltaMs: n * 2500, mediaStart: n * 225_000, durationTicks: 225_000, headerLength: 40, keyLength: 1000, nonKeyBytes: 2000, samples: 50, backToKey: 0 })
    parts.push(...f)
    offset += length
  }
  const mp4 = Buffer.concat(parts)
  const idx = Buffer.alloc(64 + records.length * 40)
  idx.write('CBNX', 0, 'latin1'); idx.writeUInt16BE(1, 4); idx.writeUInt16BE(0, 6)
  idx.writeBigInt64BE(1_760_000_000_000n, 24); idx.writeBigInt64BE(1_760_000_000_000n + BigInt(fragments * 2500), 32)
  idx.writeBigUInt64BE(BigInt(mp4.length), 40); idx.writeUInt32BE(initLength, 48); idx.writeUInt32BE(records.length, 52); idx.writeUInt16BE(0, 56)
  records.forEach((r, n) => {
    const at = 64 + n * 40
    idx.writeBigUInt64BE(BigInt(r.offset), at); idx.writeUInt32BE(r.length, at + 8); idx.writeUInt32BE(r.wallDeltaMs, at + 12); idx.writeUInt32BE(r.mediaStart, at + 16)
    idx.writeUInt32BE(r.durationTicks, at + 20); idx.writeUInt32BE(r.headerLength, at + 24); idx.writeUInt32BE(r.keyLength, at + 28); idx.writeUInt32BE(r.nonKeyBytes, at + 32)
    idx.writeUInt16BE(r.samples, at + 36); idx.writeUInt16BE(r.backToKey, at + 38)
  })
  fs.writeFileSync(path.join(dir, `${name}.mp4`), mp4)
  fs.writeFileSync(path.join(dir, `${name}.cbidx`), idx)
  return { mp4, idx, records, initLength }
}
