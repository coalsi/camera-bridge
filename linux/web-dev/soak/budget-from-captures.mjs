#!/usr/bin/env node
// Turns what `sh Tools/capture_stream.sh <ip> <path>` saved for a camera (streams.json and packets.csv in its capture folder) into the numbers the
// NVR budgets are built on: bitrate, keyframe interval and sizes, the size of the fragment a drag step downloads, the worst exact-frame lead-in,
// storage a day, and whether the camera's waveform will be flat. Reads two small files per camera; prints no address and no credential
// (the capture folder's name holds the camera's address, so the folder name is NOT printed: cameras are labelled by their size and codec).
//
//   node budget-from-captures.mjs CAPTURE_DIR... [--json]
//   node budget-from-captures.mjs --like CAPTURE_DIR      one JSON line { width, height, fps, gopSeconds, bitrateKbps } for load-sources.sh --like
import fs from 'node:fs'
import path from 'node:path'
import { mean, median } from './stats.mjs'

const MIB = 1024 * 1024
const FRAGMENT_SECONDS = 2.5                       // ArchiveConstants.fragmentMaximumDuration
const FRAGMENT_CAP = 16 * MIB                      // ArchiveConstants.fragmentMaximumBytes
const LEAD_IN_CAP = { single: 16 * MIB, grid: 8 * MIB }   // L7.2

function fraction(text) { const [n, d] = String(text).split('/').map(Number); return d ? n / d : n }

export function analyzeCapture(dir) {
  const streams = JSON.parse(fs.readFileSync(path.join(dir, 'streams.json'), 'utf8')).streams ?? []
  const video = streams.find((s) => s.codec_type === 'video')
  if (!video) throw new Error('streams.json has no video stream')
  const csv = path.join(dir, 'packets.csv')
  const rows = fs.existsSync(csv) ? fs.readFileSync(csv, 'utf8').split('\n').filter(Boolean).map((l) => l.split(',')) : []
  const packets = rows.map((r) => ({ size: Number(r[2]), key: /K/.test(r[3] ?? '') })).filter((p) => p.size > 0)
  const codec = video.codec_name
  const fps = fraction(video.avg_frame_rate) || fraction(video.r_frame_rate)
  const base = { codec, profile: video.profile ?? null, width: video.width, height: video.height, fps: Math.round(fps * 100) / 100, hasBFrames: (video.has_b_frames ?? 0) > 0 }
  if (packets.length < 10 || !(fps > 0)) return { ...base, usable: false, note: codec === 'hevc' ? 'H.265: capture_stream.sh converts H.264 only, so there is no packet list; Chrome without a hardware decoder and Firefox will not play H.265 recordings' : 'no packet list' }
  const seconds = packets.length / fps
  const total = packets.reduce((s, p) => s + p.size, 0)
  const keys = packets.map((p, i) => ({ ...p, i })).filter((p) => p.key)
  const deltas = packets.filter((p) => !p.key)
  const gaps = keys.slice(1).map((k, n) => (k.i - keys[n].i) / fps)
  const gopSeconds = gaps.length ? median(gaps) : seconds
  const avgKey = mean(keys.map((k) => k.size)), maxKey = Math.max(...keys.map((k) => k.size))
  const avgDelta = deltas.length ? mean(deltas.map((d) => d.size)) : 0
  const gopFrames = Math.max(1, Math.round(gopSeconds * fps))
  const keyFragmentFrames = Math.min(gopFrames, Math.floor(FRAGMENT_SECONDS * fps))
  const keyFragmentBytes = Math.round(avgKey + (keyFragmentFrames - 1) * avgDelta)
  const worstLeadInBytes = Math.round(maxKey + (gopFrames - 1) * avgDelta)
  const perSecond = []
  for (let i = 0; i + Math.floor(fps) <= packets.length; i += Math.floor(fps)) perSecond.push(packets.slice(i, i + Math.floor(fps)).filter((p) => !p.key).reduce((s, p) => s + p.size, 0))
  const cv = perSecond.length > 2 && mean(perSecond) > 0 ? Math.sqrt(mean(perSecond.map((v) => (v - mean(perSecond)) ** 2))) / mean(perSecond) : NaN
  const bitrateKbps = (total * 8) / seconds / 1000
  const mbps = bitrateKbps / 1000
  return {
    ...base, usable: true, seconds: Math.round(seconds * 10) / 10, keyframes: keys.length, bitrateKbps: Math.round(bitrateKbps), gopSeconds: Math.round(gopSeconds * 100) / 100,
    gopMaxSeconds: gaps.length ? Math.round(Math.max(...gaps) * 100) / 100 : null, avgKeyBytes: Math.round(avgKey), maxKeyBytes: maxKey, avgDeltaBytes: Math.round(avgDelta),
    keyShare: Math.round((keys.reduce((s, k) => s + k.size, 0) / total) * 1000) / 1000, keyFragmentBytes, worstLeadInBytes,
    fragmentUnderCap: keyFragmentBytes < FRAGMENT_CAP, leadInSingleOk: worstLeadInBytes <= LEAD_IN_CAP.single, leadInGridOk: worstLeadInBytes <= LEAD_IN_CAP.grid,
    longGop: gopSeconds > 4, slowScrubNote: gopSeconds > 10,
    gbPerDay: Math.round(mbps * 10.8 * 10) / 10, daysAt500GB: Math.round((500 / (mbps * 10.8)) * 10) / 10,
    dragPicturesPerSecond: { gigabit: Math.round((900e6 / 8 / keyFragmentBytes) * 10) / 10, wifi60: Math.round((60e6 / 8 / keyFragmentBytes) * 10) / 10 },
    gridStepBytes: keyFragmentBytes * 4, recorderMemoryMB: Math.round((FRAGMENT_SECONDS * bitrateKbps * 1000) / 8 / 1e6 + 20),
    nonKeyBytesPerSecond: Math.round(mean(perSecond)), waveformFlat: Number.isNaN(cv) ? null : cv < 0.15, nonKeyVariation: Number.isNaN(cv) ? null : Math.round(cv * 100) / 100,
    soakProfile: { width: video.width, height: video.height, fps: Math.round(fps), gopSeconds: Math.round(gopSeconds * 10) / 10, bitrateKbps: Math.round(bitrateKbps) },
  }
}

const mb = (bytes) => (bytes / 1e6).toFixed(2)

export function markdown(results) {
  const head = '| Camera | Stream | Mbps | GOP s | Key KB (avg/max) | Delta B | Key share | Drag step MB | Pictures/s gigabit / Wi-Fi 60 | Worst exact lead-in MB | GB/day | Days at 500 GB | Waveform |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|'
  const rows = results.map((r, n) => {
    const name = `#${n + 1}`
    if (!r.usable) return `| ${name} | ${r.codec} ${r.width}x${r.height} | | | | | | | | | | | ${r.note} |`
    return `| ${name} | ${r.codec} ${r.profile ?? ''} ${r.width}x${r.height} ${r.fps} fps${r.hasBFrames ? ' B-frames' : ''} | ${(r.bitrateKbps / 1000).toFixed(2)} | ${r.gopSeconds} | ${Math.round(r.avgKeyBytes / 1000)} / ${Math.round(r.maxKeyBytes / 1000)} | ${r.avgDeltaBytes} | ${(r.keyShare * 100).toFixed(0)}% | ${mb(r.keyFragmentBytes)} | ${r.dragPicturesPerSecond.gigabit} / ${r.dragPicturesPerSecond.wifi60} | ${mb(r.worstLeadInBytes)}${r.leadInSingleOk ? '' : ' (over 16 MiB: coarse)'}${r.leadInSingleOk && !r.leadInGridOk ? ' (over 8 MiB: coarse in the grid)' : ''} | ${r.gbPerDay} | ${r.daysAt500GB} | ${r.waveformFlat === null ? 'n/a' : r.waveformFlat ? 'flat (constant bit rate?)' : 'varies'} |`
  })
  const notes = []
  results.forEach((r, n) => {
    if (!r.usable) return
    if (!r.fragmentUnderCap) notes.push(`#${n + 1}: a 2.5 s fragment would exceed 16 MiB (${mb(r.keyFragmentBytes)} MB): the fragment cap must change`)
    if (r.slowScrubNote) notes.push(`#${n + 1}: keyframe every ${r.gopSeconds} s: the camera page shows the "scrubbing is slow" note`)
    else if (r.longGop) notes.push(`#${n + 1}: keyframe every ${r.gopSeconds} s: the watch screen shows the "scrubbing is coarse" caption`)
    if (r.hasBFrames) notes.push(`#${n + 1}: B-frames: composition offsets are in use (trun flags 0x000F01)`)
  })
  return [head, ...rows, '', ...notes.map((n) => `- ${n}`)].join('\n') + '\n'
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2)
  if (args[0] === '--like') {
    const r = analyzeCapture(args[1])
    if (!r.usable) { console.error(`budget: ${r.note}`); process.exit(1) }
    console.log(JSON.stringify(r.soakProfile))
  } else {
    // A shell glob over Tools/captures also matches loose files and links (the repo's checkout has a `*.h264` link beside the capture folder): only
    // folders are captures. The skipped ones are counted, never named (a name may hold an address).
    const given = args.filter((a) => !a.startsWith('--'))
    const dirs = given.filter((a) => { try { return fs.statSync(a).isDirectory() } catch { return false } })
    if (dirs.length < given.length) console.error(`budget: skipped ${given.length - dirs.length} argument(s) that are not capture folders`)
    if (dirs.length === 0) { console.error('usage: budget-from-captures.mjs CAPTURE_DIR... [--json]'); process.exit(2) }
    const results = dirs.map(analyzeCapture)
    process.stdout.write(args.includes('--json') ? JSON.stringify(results, null, 2) + '\n' : markdown(results))
  }
}
