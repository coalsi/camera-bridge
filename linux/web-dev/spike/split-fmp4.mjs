// Splits a fragmented MP4 (ftyp + moov, then [prft] moof mdat ...) into the pieces the browser receives from the NVR routes:
//   init.mp4          ftyp + moov                      (what GET .../fragments/:fid/init returns)
//   pNNNN.m4s         moof + mdat of fragment NNNN     (what GET .../fragments/:fid returns: no prft)
//   sNNNN.m4s         prft + moof + mdat, only with --stored and when the file has prft boxes (the stored form, before ArchiveMedia)
//   manifest.json     what the spike page needs to know about every fragment and frame
// No dependencies. Usage:
//   node split-fmp4.mjs <in.mp4> <outDir> --id bar --mime 'video/mp4; codecs="avc1.4d001f"' [--barcode-base 0] [--source synthetic|capture] [--mime-av '...'] [--stored]
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

export const FLAG = {
  tfhdBaseOffset: 0x1, tfhdSampleDescription: 0x2, tfhdDefaultDuration: 0x8, tfhdDefaultSize: 0x10, tfhdDefaultFlags: 0x20,
  trunDataOffset: 0x1, trunFirstSampleFlags: 0x4, trunDuration: 0x100, trunSize: 0x200, trunFlags: 0x400, trunCts: 0x800,
}

/** The boxes in buf[start, end): { type, start, end, body } where body is the first byte after the header. */
export function boxesIn(buf, start = 0, end = buf.length) {
  const result = []
  let p = start
  while (p < end) {
    if (p + 8 > end) throw new Error(`truncated box header at ${p}`)
    let size = buf.readUInt32BE(p)
    const type = buf.toString('latin1', p + 4, p + 8)
    let header = 8
    if (size === 1) {
      if (p + 16 > end) throw new Error(`truncated 64-bit box header at ${p}`)
      size = Number(buf.readBigUInt64BE(p + 8))
      header = 16
    } else if (size === 0) {
      size = end - p
    }
    if (size < header || p + size > end) throw new Error(`box ${type} at ${p} has size ${size}, which does not fit`)
    result.push({ type, start: p, end: p + size, body: p + header })
    p += size
  }
  return result
}

const child = (buf, box, type) => boxesIn(buf, box.body, box.end).find((b) => b.type === type)
const childrenOf = (buf, box, type) => boxesIn(buf, box.body, box.end).filter((b) => b.type === type)

/** The codecs parameter of a video sample entry, as MediaSource.isTypeSupported wants it (avc1.PPCCLL, hvc1.1.6.L93.90). */
export function codecString(buf, entry) {
  const config = boxesIn(buf, entry.body + 78, entry.end)
  const avcC = config.find((b) => b.type === 'avcC')
  if (avcC) {
    const hex = (i) => buf[avcC.body + i].toString(16).padStart(2, '0')
    return `${entry.type}.${hex(1)}${hex(2)}${hex(3)}`
  }
  const hvcC = config.find((b) => b.type === 'hvcC')
  if (hvcC) {
    const b = hvcC.body
    const space = ['', 'A', 'B', 'C'][buf[b + 1] >> 6]
    const tier = (buf[b + 1] & 0x20) === 0 ? 'L' : 'H'
    const profile = buf[b + 1] & 0x1f
    let compatibility = buf.readUInt32BE(b + 2)
    let reversed = 0
    for (let i = 0; i < 32; i++) { reversed = (reversed << 1) | (compatibility & 1); compatibility >>>= 1 }
    const constraints = [...buf.subarray(b + 6, b + 12)]
    while (constraints.length > 0 && constraints[constraints.length - 1] === 0) constraints.pop()
    const suffix = constraints.map((c) => `.${c.toString(16).toUpperCase()}`).join('')
    return `${entry.type}.${space}${profile}.${(reversed >>> 0).toString(16).toUpperCase()}.${tier}${buf[b + 12]}${suffix}`
  }
  return null
}

/** Tracks and trex defaults from a moov box. */
export function parseMoov(buf, moov) {
  const tracks = []
  for (const trak of childrenOf(buf, moov, 'trak')) {
    const tkhd = child(buf, trak, 'tkhd')
    const mdia = child(buf, trak, 'mdia')
    const mdhd = child(buf, mdia, 'mdhd')
    const hdlr = child(buf, mdia, 'hdlr')
    const stsd = child(buf, child(buf, child(buf, mdia, 'minf'), 'stbl'), 'stsd')
    const entry = boxesIn(buf, stsd.body + 8, stsd.end)[0]
    const trackId = buf.readUInt32BE(tkhd.body + (buf[tkhd.body] === 1 ? 20 : 12))
    const timescale = buf.readUInt32BE(mdhd.body + (buf[mdhd.body] === 1 ? 20 : 12))
    const handler = buf.toString('latin1', hdlr.body + 8, hdlr.body + 12)
    const track = { trackId, timescale, handler, entry: entry.type }
    if (handler === 'vide') {
      track.width = buf.readUInt16BE(entry.body + 24)
      track.height = buf.readUInt16BE(entry.body + 26)
      track.codec = codecString(buf, entry)
    }
    tracks.push(track)
  }
  const trex = {}
  const mvex = child(buf, moov, 'mvex')
  if (mvex) {
    for (const box of childrenOf(buf, mvex, 'trex')) {
      trex[buf.readUInt32BE(box.body + 4)] = {
        duration: buf.readUInt32BE(box.body + 12), size: buf.readUInt32BE(box.body + 16), flags: buf.readUInt32BE(box.body + 20),
      }
    }
  }
  return { tracks, trex }
}

/** The samples of one traf: [{ dts, pts, duration, size, key }] in decode order (ticks of the track timescale). */
export function parseTraf(buf, traf, trexDefaults) {
  const tfhd = child(buf, traf, 'tfhd')
  const tfdt = child(buf, traf, 'tfdt')
  const flags = buf.readUInt32BE(tfhd.body) & 0xffffff
  const trackId = buf.readUInt32BE(tfhd.body + 4)
  let p = tfhd.body + 8
  if (flags & FLAG.tfhdBaseOffset) p += 8
  if (flags & FLAG.tfhdSampleDescription) p += 4
  const defaults = { ...(trexDefaults[trackId] ?? { duration: 0, size: 0, flags: 0 }) }
  if (flags & FLAG.tfhdDefaultDuration) { defaults.duration = buf.readUInt32BE(p); p += 4 }
  if (flags & FLAG.tfhdDefaultSize) { defaults.size = buf.readUInt32BE(p); p += 4 }
  if (flags & FLAG.tfhdDefaultFlags) { defaults.flags = buf.readUInt32BE(p); p += 4 }
  const base = buf[tfdt.body] === 1 ? Number(buf.readBigUInt64BE(tfdt.body + 4)) : buf.readUInt32BE(tfdt.body + 4)
  const samples = []
  let dts = base
  for (const trun of childrenOf(buf, traf, 'trun')) {
    const version = buf[trun.body]
    const tflags = buf.readUInt32BE(trun.body) & 0xffffff
    const count = buf.readUInt32BE(trun.body + 4)
    let q = trun.body + 8
    if (tflags & FLAG.trunDataOffset) q += 4
    let firstFlags = null
    if (tflags & FLAG.trunFirstSampleFlags) { firstFlags = buf.readUInt32BE(q); q += 4 }
    for (let i = 0; i < count; i++) {
      let duration = defaults.duration, size = defaults.size, sampleFlags = defaults.flags, cts = 0
      if (tflags & FLAG.trunDuration) { duration = buf.readUInt32BE(q); q += 4 }
      if (tflags & FLAG.trunSize) { size = buf.readUInt32BE(q); q += 4 }
      if (tflags & FLAG.trunFlags) { sampleFlags = buf.readUInt32BE(q); q += 4 } else if (i === 0 && firstFlags !== null) sampleFlags = firstFlags
      if (tflags & FLAG.trunCts) { cts = version === 1 ? buf.readInt32BE(q) : buf.readUInt32BE(q); q += 4 }
      samples.push({ dts, pts: dts + cts, duration, size, key: (sampleFlags & 0x10000) === 0 })
      dts += duration
    }
  }
  return { trackId, base, samples }
}

/** Splits a whole fragmented file. Returns { init, tracks, parts, frames } with byte ranges into buf. */
export function parseFragmented(buf) {
  const top = boxesIn(buf)
  const firstFragment = top.findIndex((b) => b.type === 'moof' || b.type === 'prft')
  if (firstFragment < 1) throw new Error('no fragment found after the initialization segment')
  const moov = top.find((b) => b.type === 'moov')
  if (!moov) throw new Error('no moov box')
  const { tracks, trex } = parseMoov(buf, moov)
  const video = tracks.find((t) => t.handler === 'vide')
  if (!video) throw new Error('no video track')
  const init = { start: 0, end: top[firstFragment].start }
  const parts = []
  const frames = []
  let lastKeyPart = -1
  for (let i = firstFragment; i < top.length; i++) {
    let prft = null
    if (top[i].type === 'prft') { prft = top[i]; i++ }
    if (!top[i] || top[i].type !== 'moof') {
      if (top[i] && (top[i].type === 'mfra' || top[i].type === 'free' || top[i].type === 'sidx')) continue
      throw new Error(`expected moof at box ${i}, found ${top[i]?.type}`)
    }
    const moof = top[i]
    const mdat = top[i + 1]
    if (!mdat || mdat.type !== 'mdat') throw new Error(`moof at ${moof.start} is not followed by mdat`)
    i++
    let videoSamples = null
    for (const traf of childrenOf(buf, moof, 'traf')) {
      const parsed = parseTraf(buf, traf, trex)
      if (parsed.trackId === video.trackId) videoSamples = parsed
    }
    if (!videoSamples || videoSamples.samples.length === 0) throw new Error(`fragment at ${moof.start} has no video samples`)
    const samples = videoSamples.samples
    const key = samples[0].key
    const index = parts.length
    if (key) lastKeyPart = index
    const midKey = samples.slice(1).some((s) => s.key)
    const durTicks = samples.reduce((sum, s) => sum + s.duration, 0)
    parts.push({
      i: index,
      servedRange: [moof.start, mdat.end],
      storedRange: [prft ? prft.start : moof.start, mdat.end],
      hasPrft: prft !== null,
      startTick: videoSamples.base,
      durTicks,
      key,
      midKey,
      backToKey: lastKeyPart < 0 ? 0 : index - lastKeyPart,
      frameFirst: frames.length,
      frameCount: samples.length,
      hasAudio: childrenOf(buf, moof, 'traf').length > 1,
    })
    for (const s of samples) frames.push([s.pts, s.key ? 1 : 0])
  }
  return { init, tracks, video, parts, frames }
}

export function splitFile(inputPath, outDir, options = {}) {
  const buf = readFileSync(inputPath)
  const parsed = parseFragmented(buf)
  mkdirSync(outDir, { recursive: true })
  writeFileSync(join(outDir, 'init.mp4'), buf.subarray(parsed.init.start, parsed.init.end))
  const pad = (n) => String(n).padStart(4, '0')
  const parts = parsed.parts.map((part) => {
    const served = buf.subarray(part.servedRange[0], part.servedRange[1])
    writeFileSync(join(outDir, `p${pad(part.i)}.m4s`), served)
    const entry = {
      i: part.i, file: `p${pad(part.i)}.m4s`, bytes: served.length, startTick: part.startTick, durTicks: part.durTicks,
      key: part.key, backToKey: part.backToKey, frameFirst: part.frameFirst, frameCount: part.frameCount,
    }
    if (part.hasPrft && options.stored) {
      const stored = buf.subarray(part.storedRange[0], part.storedRange[1])
      writeFileSync(join(outDir, `s${pad(part.i)}.m4s`), stored)
      entry.stored = `s${pad(part.i)}.m4s`
      entry.storedBytes = stored.length
    }
    if (part.hasAudio) entry.hasAudio = true
    if (part.midKey) entry.midKey = true
    return entry
  })
  const mime = options.mime ?? (parsed.video.codec ? `video/mp4; codecs="${parsed.video.codec}"` : null)
  const hasAudio = parsed.tracks.some((t) => t.handler === 'soun')
  const manifest = {
    id: options.id ?? 'fixture',
    source: options.source ?? 'synthetic',
    mime,
    mimeAV: options.mimeAV ?? (hasAudio && mime ? mime.replace(/"$/, ',mp4a.40.2"') : null),
    width: parsed.video.width,
    height: parsed.video.height,
    timescale: parsed.video.timescale,
    hasAudio,
    barcodeBase: options.barcodeBase ?? null,
    init: { file: 'init.mp4', bytes: parsed.init.end - parsed.init.start },
    durationTicks: parsed.parts.reduce((sum, p) => sum + p.durTicks, 0),
    parts,
    frames: parsed.frames,
  }
  writeFileSync(join(outDir, 'manifest.json'), JSON.stringify(manifest))
  return manifest
}

function cli(argv) {
  const positional = []
  const flags = {}
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--stored') flags.stored = true
    else if (argv[i].startsWith('--')) flags[argv[i].slice(2)] = argv[++i]
    else positional.push(argv[i])
  }
  if (positional.length !== 2 || !flags.id) {
    console.error("usage: node split-fmp4.mjs <in.mp4> <outDir> --id ID [--mime MIME] [--mime-av MIME] [--barcode-base N] [--source synthetic|capture] [--stored]")
    process.exit(2)
  }
  const manifest = splitFile(positional[0], positional[1], {
    id: flags.id, mime: flags.mime, mimeAV: flags['mime-av'], source: flags.source, stored: flags.stored === true,
    barcodeBase: flags['barcode-base'] === undefined ? null : Number(flags['barcode-base']),
  })
  console.log(`${manifest.id}: ${manifest.width}x${manifest.height}, ${manifest.parts.length} fragments, ${manifest.frames.length} frames, ` +
    `${(manifest.durationTicks / manifest.timescale).toFixed(2)} s${manifest.hasAudio ? ', with audio' : ''}`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) cli(process.argv.slice(2))
