#!/usr/bin/env node
// Looks at the recordings on disk after a soak or a recovery, without asking the daemon: every closed file's sidecar must equal a fresh scan
// of its mp4, a sample of files must decode to the end, and no stray file may lie in the tree.
//
//   node verify-files.mjs --root RUN/rec [--sample 24] [--decode 6] [--seed 3] [--allow-open N] [--must-be-closed LIST.json] [--json]
//
//   --sample N        check the sidecar of N random closed files (default 24; 0 = all)
//   --decode M        decode M of those files from start to end with ffmpeg and compare the packet count with the sidecar (default 6; 0 = skip)
//   --allow-open N    at most N files without a sidecar (the files being written now, one per recording camera)
//   --must-be-closed  a file listing relative mp4 paths that were open before a crash (a JSON array, or one path a line): each must have a sidecar now and be sound
//   --damaged         the output of damage.mjs (one JSON object a line): every file it names is added to that list
// Exit status 0 when nothing is wrong, 1 otherwise.
import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { mulberry32 } from './plan.mjs'
import { checkClosedFile, readCBIndex, scanMp4 } from './mp4scan.mjs'

const DATE = /^\d{4}-\d\d-\d\d$/
const MP4 = /^\d\d-\d\d-\d\d(-[1-9]\d{0,2})?\.mp4$/
const SIDECAR = /^\d\d-\d\d-\d\d(-[1-9]\d{0,2})?\.cbidx$/

export function listTree(root) {
  const closed = [], open = [], strays = []
  for (const cam of fs.readdirSync(root, { withFileTypes: true })) {
    const camPath = path.join(root, cam.name)
    if (!cam.isDirectory()) { strays.push(cam.name); continue }
    for (const entry of fs.readdirSync(camPath, { withFileTypes: true })) {
      if (entry.isFile() && entry.name === 'camera.json') continue
      if (!entry.isDirectory() || !DATE.test(entry.name)) { strays.push(`${cam.name}/${entry.name}`); continue }
      for (const name of fs.readdirSync(path.join(camPath, entry.name))) {
        const rel = `${cam.name}/${entry.name}/${name}`
        if (MP4.test(name)) (fs.existsSync(path.join(root, rel.replace(/\.mp4$/, '.cbidx'))) ? closed : open).push(rel)
        else if (SIDECAR.test(name)) { if (!fs.existsSync(path.join(root, rel.replace(/\.cbidx$/, '.mp4')))) strays.push(rel) }
        else strays.push(rel)
      }
    }
  }
  return { closed: closed.sort(), open: open.sort(), strays }
}

// Decodes the whole file and counts video packets. Returns [] when sound, else the reasons.
export function decodeCheck(mp4, expectedPackets, run = spawnSync) {
  const decode = run('ffmpeg', ['-v', 'error', '-xerror', '-i', mp4, '-f', 'null', '-'], { encoding: 'utf8', timeout: 300_000 })
  if (decode.error) return [`ffmpeg could not run: ${decode.error.message}`]
  const problems = []
  if (decode.status !== 0 || decode.stderr.trim()) problems.push(`ffmpeg: ${decode.stderr.trim().split('\n')[0] || `exit ${decode.status}`}`)
  if (expectedPackets !== undefined) {
    const probe = run('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-count_packets', '-show_entries', 'stream=nb_read_packets', '-of', 'csv=p=0', mp4], { encoding: 'utf8', timeout: 300_000 })
    const packets = Number(probe.stdout?.trim())
    if (probe.status !== 0 || Number.isNaN(packets)) problems.push('ffprobe gave no packet count')
    else if (packets !== expectedPackets) problems.push(`${packets} video packets, the sidecar counts ${expectedPackets} samples`)
  }
  return problems
}

// A list file: a JSON array, or one relative path a line.
export function readList(file) {
  const text = fs.readFileSync(file, 'utf8').trim()
  if (!text) return []
  return text.startsWith('[') ? JSON.parse(text) : text.split('\n').map((l) => l.trim()).filter(Boolean)
}

export function readDamaged(file) {
  return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l).file)
}

export function verify(root, { sample = 24, decode = 6, seed = 3, allowOpen = Infinity, mustBeClosed = [], run } = {}) {
  const tree = listTree(root)
  const rng = mulberry32(seed)
  const problems = []
  const pick = tree.closed.length <= sample || sample === 0 ? [...tree.closed] : [...tree.closed].sort(() => rng() - 0.5).slice(0, sample)
  for (const rel of new Set([...pick, ...mustBeClosed])) {
    if (!tree.closed.includes(rel)) { if (mustBeClosed.includes(rel)) problems.push(`${rel}: still has no sidecar after recovery`); continue }
    for (const p of checkClosedFile(path.join(root, rel), path.join(root, rel.replace(/\.mp4$/, '.cbidx')))) problems.push(`${rel}: ${p}`)
  }
  const decoded = []
  if (decode > 0) {
    for (const rel of [...mustBeClosed.filter((r) => tree.closed.includes(r)), ...pick].slice(0, decode)) {
      const index = readCBIndex(path.join(root, rel.replace(/\.mp4$/, '.cbidx')))
      const samples = index.error ? undefined : index.records.reduce((s, r) => s + r.samples, 0)
      decoded.push(rel)
      for (const p of decodeCheck(path.join(root, rel), samples, run)) problems.push(`${rel}: ${p}`)
    }
  }
  if (tree.open.length > allowOpen) problems.push(`${tree.open.length} files without a sidecar, at most ${allowOpen} may be open`)
  for (const s of tree.strays.slice(0, 10)) problems.push(`stray file ${s}`)
  return { closed: tree.closed.length, open: tree.open.length, checked: pick.length + mustBeClosed.length, decoded: decoded.length, problems }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2)
  const get = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined }
  if (!get('--root')) { console.error('usage: verify-files.mjs --root RUN/rec [--sample 24] [--decode 6] [--allow-open N] [--must-be-closed LIST.json]'); process.exit(2) }
  const result = verify(get('--root'), { sample: Number(get('--sample') ?? 24), decode: Number(get('--decode') ?? 6), seed: Number(get('--seed') ?? 3),
    allowOpen: get('--allow-open') !== undefined ? Number(get('--allow-open')) : Infinity, mustBeClosed: [...new Set([...(get('--must-be-closed') ? readList(get('--must-be-closed')) : []), ...(get('--damaged') ? readDamaged(get('--damaged')) : [])])] })
  console.log(args.includes('--json') ? JSON.stringify(result) : `${result.closed} closed files, ${result.open} open, ${result.checked} checked, ${result.decoded} decoded; ${result.problems.length === 0 ? 'no problems' : `${result.problems.length} problems:\n  ${result.problems.join('\n  ')}`}`)
  process.exit(result.problems.length === 0 ? 0 : 1)
}
