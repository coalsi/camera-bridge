// The stand-in server as a process, for REHEARSING the soak scripts before there is a daemon to point them at (run-soak.sh --rehearsal).
// It speaks the routes of soak-fixture-server.mjs and keeps real recordings on disk in the archive's layout, so that kill -9, crash images and the
// file checks have something to work on: when Record is turned on for a camera it writes two closed files and one open file; on start it
// repairs open files the way the engine must (cut to the last whole fragment, write the sidecar), and on SIGTERM it closes them.
// The verdict of a rehearsal never counts: it proves that the scripts are wired together, nothing about the daemon.
//   node soak-fixture-main.mjs --data DIR --port N
import fs from 'node:fs'
import path from 'node:path'
import { startFixture } from './soak-fixture-server.mjs'
import { makeFile } from './soak-recording-fixture.mjs'
import { scanMp4, checkClosedFile } from '../web-dev/soak/mp4scan.mjs'

const a = {}
for (let i = 2; i < process.argv.length; i += 2) a[process.argv[i].replace(/^--/, '')] = process.argv[i + 1]
const data = a.data, recordings = path.join(data, 'recordings'), stateFile = path.join(data, 'fixture-state.json')
fs.mkdirSync(recordings, { recursive: true, mode: 0o700 })
const state = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, 'utf8')) : { startedAt: Date.now() - 1_800_000, cameras: [] }
const save = () => fs.writeFileSync(stateFile, JSON.stringify(state))
save()

function sidecarFrom(mp4, camera) {
  const scan = scanMp4(mp4)
  fs.truncateSync(mp4, scan.fragments.length ? scan.fragments.at(-1).offset + scan.fragments.at(-1).length : scan.initLength)
  const records = scan.fragments
  const idx = Buffer.alloc(64 + records.length * 40)
  idx.write('CBNX', 0, 'latin1'); idx.writeUInt16BE(1, 4)
  idx.writeBigInt64BE(BigInt(state.startedAt), 24); idx.writeBigInt64BE(BigInt(state.startedAt + records.length * 2500), 32)
  idx.writeBigUInt64BE(BigInt(fs.statSync(mp4).size), 40); idx.writeUInt32BE(scan.initLength, 48); idx.writeUInt32BE(records.length, 52)
  records.forEach((r, n) => {
    const at = 64 + n * 40
    idx.writeBigUInt64BE(BigInt(r.offset), at); idx.writeUInt32BE(r.length, at + 8); idx.writeUInt32BE(n * 2500, at + 12); idx.writeUInt32BE(n * 225_000, at + 16); idx.writeUInt32BE(225_000, at + 20)
    idx.writeUInt32BE(40, at + 24); idx.writeUInt32BE(1000, at + 28); idx.writeUInt32BE(2000, at + 32); idx.writeUInt16BE(50, at + 36)
  })
  fs.writeFileSync(mp4.replace(/\.mp4$/, '.cbidx'), idx)
}

// Files that need the repair: no sidecar (they were open), or a sidecar that does not match the file (cut, stale or damaged).
function eachFileNeedingRepair(fn) {
  eachOpenFile(fn)
  for (const cam of fs.readdirSync(recordings, { withFileTypes: true })) {
    if (!cam.isDirectory()) continue
    for (const day of fs.readdirSync(path.join(recordings, cam.name))) {
      const dayDir = path.join(recordings, cam.name, day)
      if (!/^\d{4}-\d\d-\d\d$/.test(day)) continue
      for (const f of fs.readdirSync(dayDir)) {
        const side = path.join(dayDir, f.replace(/\.mp4$/, '.cbidx'))
        if (/\.mp4$/.test(f) && fs.existsSync(side) && checkClosedFile(path.join(dayDir, f), side).length > 0) fn(path.join(dayDir, f), cam.name)
      }
    }
  }
}

function eachOpenFile(fn) {
  for (const cam of fs.readdirSync(recordings, { withFileTypes: true })) {
    if (!cam.isDirectory()) continue
    for (const day of fs.readdirSync(path.join(recordings, cam.name))) {
      const dayDir = path.join(recordings, cam.name, day)
      if (!/^\d{4}-\d\d-\d\d$/.test(day)) continue
      for (const f of fs.readdirSync(dayDir)) if (/^\d\d-\d\d-\d\d(-\d+)?\.mp4$/.test(f) && !fs.existsSync(path.join(dayDir, f.replace(/\.mp4$/, '.cbidx')))) fn(path.join(dayDir, f), cam.name)
    }
  }
}
function openNewFile(cameraId) {
  const now = new Date(), pad = (n) => String(n).padStart(2, '0')
  const day = path.join(recordings, cameraId, `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`)
  fs.mkdirSync(day, { recursive: true, mode: 0o700 })
  let base = `${pad(now.getHours())}-${pad(now.getMinutes())}-${pad(now.getSeconds())}`, n = 1
  while (fs.existsSync(path.join(day, `${base}.mp4`))) base = `${pad(now.getHours())}-${pad(now.getMinutes())}-${pad(now.getSeconds())}-${++n}`
  makeFile(day, base, { fragments: 6 })
  fs.rmSync(path.join(day, `${base}.cbidx`))
}

eachFileNeedingRepair((mp4, camera) => { sidecarFrom(mp4, camera) })   // the repair a restart has to do

const fixture = await startFixture({ port: Number(a.port), cameras: 0, startedAt: state.startedAt, footageMs: 1_800_000 })
for (const c of state.cameras) fixture.cameras.push(c)
for (const c of fixture.cameras) if (c.nvrEnabled) openNewFile(c.id)   // recording resumes in a new file
const known = new Set(state.cameras.map((c) => c.id))
setInterval(() => {
  for (const c of fixture.cameras) {
    if (c.nvrEnabled && !known.has(c.id)) {
      known.add(c.id)
      fs.mkdirSync(path.join(recordings, c.id), { recursive: true, mode: 0o700 })
      fs.writeFileSync(path.join(recordings, c.id, 'camera.json'), JSON.stringify({ id: c.id, name: c.name }))
      const day = path.join(recordings, c.id, '2026-10-01'); fs.mkdirSync(day, { recursive: true })
      makeFile(day, '08-00-00'); makeFile(day, '08-15-00')
      openNewFile(c.id)
    }
  }
  state.cameras = fixture.cameras.map((c) => ({ id: c.id, name: c.name, nvrEnabled: c.nvrEnabled }))
  save()
}, 300)

process.on('SIGTERM', async () => { eachOpenFile((mp4, camera) => sidecarFrom(mp4, camera)); await fixture.close(); process.exit(0) })
console.log(`fixture listening on ${fixture.port}`)
