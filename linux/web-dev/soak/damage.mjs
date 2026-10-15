#!/usr/bin/env node
// Makes a recordings folder look the way a power cut leaves it, so that recovery can be tested without cutting the power. Works only on a
// folder inside a soak run (its parent holds a `.soak-run` file) and only on a copy the harness made.
//
//   node damage.mjs --root RUN/rec --variant cut-mdat|cut-moof|cut-prft|cut-boundary|zero-tail|zero-last|lose-sidecar|bad-sidecar|stale-sidecar [--seed N]
//
// Variants on the files that were OPEN when the daemon died (an mp4 with no .cbidx; the sidecar is written once, when a file closes):
//   cut-mdat       the file ends in the middle of the last fragment's mdat
//   cut-moof       ... in the middle of its moof          cut-prft   ... in the middle of its prft
//   cut-boundary   the last whole fragment is gone (the file ends exactly where the one before it ended)
//   zero-tail      1 MiB of zeros after the last fragment (a file extended before its data reached the disk)
//   zero-last      the last 200 KiB overwritten with zeros, the size unchanged (blocks that were allocated but never written)
// Variants on the newest CLOSED file of each camera (the sidecar is replaced by renaming over the old one, but a crash can still catch it):
//   lose-sidecar   the .cbidx is gone               bad-sidecar    the .cbidx is cut to 100 bytes (and, for every second camera, its magic is flipped)
//   stale-sidecar  100 bytes of junk after the mp4's end, so the sidecar's mp4Size no longer matches
// Prints one JSON line per change: { camera, file, action } (names relative to the folder, no absolute paths).
import fs from 'node:fs'
import path from 'node:path'
import { mulberry32 } from './plan.mjs'
import { scanMp4 } from './mp4scan.mjs'

const DATE = /^\d{4}-\d\d-\d\d$/
const MP4 = /^(\d\d-\d\d-\d\d)(?:-(\d+))?\.mp4$/

function recordingFiles(root) {
  const cameras = []
  for (const cameraDir of fs.readdirSync(root, { withFileTypes: true })) {
    if (!cameraDir.isDirectory() || !fs.existsSync(path.join(root, cameraDir.name, 'camera.json'))) continue
    const files = []
    for (const dateDir of fs.readdirSync(path.join(root, cameraDir.name), { withFileTypes: true })) {
      if (!dateDir.isDirectory() || !DATE.test(dateDir.name)) continue
      for (const name of fs.readdirSync(path.join(root, cameraDir.name, dateDir.name))) {
        const m = MP4.exec(name)
        if (!m) continue
        const rel = `${cameraDir.name}/${dateDir.name}/${name}`
        files.push({ rel, order: `${dateDir.name} ${m[1]} ${String(m[2] ?? 1).padStart(4, '0')}`, mp4: path.join(root, rel), cbidx: path.join(root, rel.replace(/\.mp4$/, '.cbidx')) })
      }
    }
    files.sort((a, b) => a.order.localeCompare(b.order))
    cameras.push({ camera: cameraDir.name, files })
  }
  return cameras
}

// The harness puts a `.soak-run` file in the run folder; the recordings folder is that folder, or one or two levels below it.
export function insideSoakRun(root) {
  let dir = path.resolve(root)
  for (let i = 0; i < 3; i++) { dir = path.dirname(dir); if (fs.existsSync(path.join(dir, '.soak-run'))) return true }
  return false
}

export function damage(root, variant, { seed = 1 } = {}) {
  if (!insideSoakRun(root)) throw new Error('refusing: no .soak-run marker within three folders above the recordings folder, so this is not a soak run')
  const rng = mulberry32(seed)
  const changes = []
  const log = (camera, file, action) => changes.push({ camera, file, action })
  const between = (a, b) => a + Math.floor(rng() * Math.max(1, b - a))
  let cameraNumber = 0
  for (const { camera, files } of recordingFiles(root)) {
    cameraNumber++
    const open = files.filter((f) => !fs.existsSync(f.cbidx))
    const closed = files.filter((f) => fs.existsSync(f.cbidx))
    if (['cut-mdat', 'cut-moof', 'cut-prft', 'cut-boundary', 'zero-tail', 'zero-last'].includes(variant)) {
      for (const file of open) {
        const scan = scanMp4(file.mp4)
        if (scan.fragments.length < 2) continue
        const last = scan.fragments.at(-1), before = scan.fragments.at(-2)
        const lastEnd = last.offset + last.length
        // The box layout of the last fragment: prft (32 bytes) + moof (about 1.1 KB) + mdat.
        const prftEnd = last.offset + 32, moofEnd = last.offset + Math.min(1200, last.length / 2)
        switch (variant) {
          case 'cut-mdat': { const at = between(moofEnd + 16, lastEnd - 1); fs.truncateSync(file.mp4, at); log(camera, file.rel, `cut at ${at - last.offset} bytes into the last fragment (mdat)`); break }
          case 'cut-moof': { const at = between(prftEnd + 8, moofEnd); fs.truncateSync(file.mp4, at); log(camera, file.rel, `cut at ${at - last.offset} bytes into the last fragment (moof)`); break }
          case 'cut-prft': { const at = between(last.offset + 1, prftEnd); fs.truncateSync(file.mp4, at); log(camera, file.rel, `cut at ${at - last.offset} bytes into the last fragment (prft)`); break }
          case 'cut-boundary': fs.truncateSync(file.mp4, before.offset + before.length); log(camera, file.rel, 'cut at the end of the second last fragment'); break
          case 'zero-tail': fs.appendFileSync(file.mp4, Buffer.alloc(1024 * 1024)); log(camera, file.rel, 'appended 1 MiB of zeros'); break
          case 'zero-last': {
            const length = Math.min(200 * 1024, lastEnd - last.offset), fd = fs.openSync(file.mp4, 'r+')
            fs.writeSync(fd, Buffer.alloc(length), 0, length, lastEnd - length); fs.closeSync(fd)
            log(camera, file.rel, `zeroed the last ${length} bytes`); break
          }
        }
      }
    } else if (['lose-sidecar', 'bad-sidecar', 'stale-sidecar'].includes(variant)) {
      const file = closed.at(-1)
      if (!file) continue
      if (variant === 'lose-sidecar') { fs.rmSync(file.cbidx); log(camera, file.rel, 'removed the sidecar') }
      if (variant === 'bad-sidecar') {
        fs.truncateSync(file.cbidx, 100)
        if (cameraNumber % 2 === 0) { const fd = fs.openSync(file.cbidx, 'r+'); fs.writeSync(fd, Buffer.from('X'), 0, 1, 0); fs.closeSync(fd) }
        log(camera, file.rel, cameraNumber % 2 === 0 ? 'cut the sidecar to 100 bytes and flipped its magic' : 'cut the sidecar to 100 bytes')
      }
      if (variant === 'stale-sidecar') { fs.appendFileSync(file.mp4, Buffer.alloc(100, 0x41)); log(camera, file.rel, 'appended 100 bytes after the end the sidecar knows') }
    } else throw new Error(`unknown variant ${variant}`)
  }
  return changes
}

export const VARIANTS = ['cut-mdat', 'cut-moof', 'cut-prft', 'cut-boundary', 'zero-tail', 'zero-last', 'lose-sidecar', 'bad-sidecar', 'stale-sidecar']

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2)
  const get = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined }
  if (!get('--root') || !get('--variant')) { console.error('usage: damage.mjs --root RUN/rec --variant <name> [--seed N]'); process.exit(2) }
  try { for (const change of damage(get('--root'), get('--variant'), { seed: Number(get('--seed') ?? 1) })) console.log(JSON.stringify(change)) }
  catch (error) { console.error(`damage: ${error.message}`); process.exit(1) }
}
