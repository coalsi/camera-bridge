// A tiny fragmented-MP4 writer for the tests: one video track (and optionally one audio track), no real codec data.
// Fragment layout is the recorder's: [prft] moof{mfhd, traf{tfhd 0x020000, tfdt v1, trun 0x701}, [audio traf]} mdat.
export const u32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32BE(n >>> 0); return b }
export const u16 = (n) => { const b = Buffer.alloc(2); b.writeUInt16BE(n); return b }
export const u64 = (n) => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(n)); return b }
export const box = (type, ...payload) => {
  const body = Buffer.concat(payload)
  return Buffer.concat([u32(8 + body.length), Buffer.from(type, 'latin1'), body])
}
export const fullBox = (type, version, flags, ...payload) => box(type, u32((version << 24) | flags), ...payload)

function trak({ id, timescale, handler, entry, width = 0, height = 0, config = Buffer.alloc(0) }) {
  const visual = Buffer.concat([Buffer.alloc(6), u16(1), Buffer.alloc(16), u16(width), u16(height), Buffer.alloc(50), config])
  const sample = box(entry, handler === 'vide' ? visual : Buffer.alloc(28))
  return box('trak',
    fullBox('tkhd', 0, 3, u32(0), u32(0), u32(id), Buffer.alloc(68)),
    box('mdia',
      fullBox('mdhd', 0, 0, u32(0), u32(0), u32(timescale), u32(0), u32(0)),
      fullBox('hdlr', 0, 0, u32(0), Buffer.from(handler, 'latin1'), Buffer.alloc(12), Buffer.from([0])),
      box('minf', box('stbl', fullBox('stsd', 0, 0, u32(1), sample)))))
}

/** avcC for profile 0x4d (Main), no constraint flags, level 0x1f (3.1) by default. */
export const avcC = (profile = 0x4d, compat = 0x00, level = 0x1f) => box('avcC', Buffer.from([1, profile, compat, level, 0xff, 0xe0, 0]))
/** hvcC for Main profile, level 93 (3.1), constraint byte 0x90 (what x265 writes). */
export const hvcC = () => box('hvcC', Buffer.concat([Buffer.from([1, 0x01]), u32(0x60000000), Buffer.from([0x90, 0, 0, 0, 0, 0, 93]), Buffer.alloc(10)]))

export function initSegment({ width = 640, height = 360, audio = false, entry = 'avc1', config = avcC() } = {}) {
  const tracks = [trak({ id: 1, timescale: 90000, handler: 'vide', entry, width, height, config })]
  const trexes = [fullBox('trex', 0, 0, u32(1), u32(1), u32(0), u32(0), u32(0))]
  if (audio) {
    tracks.push(trak({ id: 2, timescale: 48000, handler: 'soun', entry: 'mp4a' }))
    trexes.push(fullBox('trex', 0, 0, u32(2), u32(1), u32(0), u32(0), u32(0)))
  }
  return Buffer.concat([
    box('ftyp', Buffer.from('isom'), u32(512), Buffer.from('isomiso6avc1')),
    box('moov', fullBox('mvhd', 0, 0, Buffer.alloc(96)), ...tracks, box('mvex', ...trexes)),
  ])
}

const KEY = 0x02000000, DELTA = 0x01010000

/** One fragment. `samples`: [{ duration, size, key, cts? }]. `audioSamples`: a count of 1024-tick AAC frames, or 0. */
export function fragment({ base, samples, prft = true, audioSamples = 0, sequence = 1 }) {
  const withCts = samples.some((s) => s.cts)
  const trunFlags = 0x701 | (withCts ? 0x800 : 0)
  const trunBody = (list, fl) => Buffer.concat([u32(list.length), u32(0), ...list.map((s) => Buffer.concat([
    u32(s.duration), u32(s.size), u32(s.key ? KEY : DELTA), ...(fl & 0x800 ? [u32(s.cts ?? 0)] : []),
  ]))])
  const video = box('traf',
    fullBox('tfhd', 0, 0x20000, u32(1)), fullBox('tfdt', 1, 0, u64(base)), fullBox('trun', 0, trunFlags, trunBody(samples, trunFlags)))
  const audioList = Array.from({ length: audioSamples }, () => ({ duration: 1024, size: 100, key: true }))
  const audio = audioSamples
    ? box('traf', fullBox('tfhd', 0, 0x20000, u32(2)), fullBox('tfdt', 1, 0, u64(0)), fullBox('trun', 0, 0x701, trunBody(audioList, 0x701)))
    : Buffer.alloc(0)
  const moof = box('moof', fullBox('mfhd', 0, 0, u32(sequence)), video, audio)
  const total = samples.reduce((n, s) => n + s.size, 0) + audioList.reduce((n, s) => n + s.size, 0)
  const mdat = box('mdat', Buffer.alloc(total, 0xab))
  const parts = prft ? [fullBox('prft', 1, 0, u32(1), u64(0), u64(base)), moof, mdat] : [moof, mdat]
  return Buffer.concat(parts)
}

/** A 20 fps file: `gops` groups of `gopFrames` frames, cut into fragments of `fragmentFrames` frames (a cut inside a GOP gives a continuation fragment). */
export function clip({ gops = 3, gopFrames = 40, fragmentFrames = 40, audio = false, prft = true, width = 640, height = 360, entry, config } = {}) {
  const chunks = [initSegment({ width, height, audio, entry, config })]
  let base = 0, sequence = 1
  for (let g = 0; g < gops; g++) {
    for (let f = 0; f < gopFrames; f += fragmentFrames) {
      const count = Math.min(fragmentFrames, gopFrames - f)
      const samples = Array.from({ length: count }, (_, i) => ({ duration: 4500, size: f + i === 0 ? 5000 : 300, key: f + i === 0 }))
      chunks.push(fragment({ base, samples, prft, audioSamples: audio ? 4 : 0, sequence: sequence++ }))
      base += count * 4500
    }
  }
  chunks.push(box('mfra', Buffer.alloc(8)))
  return Buffer.concat(chunks)
}
