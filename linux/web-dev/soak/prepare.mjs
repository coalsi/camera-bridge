#!/usr/bin/env node
// Gets a freshly started throwaway daemon ready for a soak (the load cameras use no motion detection of the engine's own, so the log and the CPU show the NVR
// and not a test pattern's "motion"): signs in (sets the password on a new bridge), adds the load cameras, chooses
// the built-in recordings location with the soak's cap, turns Record on for every camera and waits until every camera has a recording.
// Writes SESSION (0600: cookie and CSRF token, never printed) and cameras.json beside it. The password comes from a file, never from the
// command line or the environment, and appears in no output.
//
//   node prepare.mjs --base URL --password-file F [--setup-token-file F] --out DIR --cameras 8 --url-template 'rtsp://127.0.0.1:18554/load{n}' \
//        --cap-gb 20 [--keep-days 7] [--login-only] [--wait-sec 180]
import fs from 'node:fs'
import path from 'node:path'
import { setTimeout as sleep } from 'node:timers/promises'
import { cameraList, createHttp, signIn } from './bridge-http.mjs'

function fail(message) { console.error(`prepare: ${message}`); process.exit(1) }

export async function prepare(o) {
  const password = fs.readFileSync(o.passwordFile, 'utf8').trim()
  const setupToken = o.setupTokenFile ? fs.readFileSync(o.setupTokenFile, 'utf8').trim() : undefined
  const deadline = Date.now() + (o.waitSec ?? 180) * 1000
  const probe = createHttp({ base: o.base, session: null, maxSockets: 1, timeoutMs: 5000 })
  try {
    while (true) {
      const r = await probe.request('GET', '/api/v1/health')
      if (r.status === 200) break
      if (Date.now() > deadline) throw new Error(`the daemon did not answer /health within ${o.waitSec ?? 180} s`)
      await sleep(500)
    }
    const info = await probe.request('GET', '/api/v1/session')
    var needsSetup = info.json?.setupRequired === true
  } finally { probe.close() }

  const session = await signIn(o.base, { password, setupToken, setup: needsSetup })
  fs.mkdirSync(o.outDir, { recursive: true })
  const sessionFile = path.join(o.outDir, 'session.json')
  fs.writeFileSync(sessionFile, JSON.stringify(session), { mode: 0o600 })
  fs.chmodSync(sessionFile, 0o600)
  const http = createHttp({ base: o.base, session, maxSockets: 2, timeoutMs: 60_000 })
  try {
    let cameras
    if (o.loginOnly) {
      const list = await http.request('GET', '/api/v1/cameras')
      cameras = (cameraList(list.json) ?? []).filter((c) => c.nvrEnabled).map((c) => ({ id: c.id, name: c.name }))
    } else {
      cameras = []
      for (let n = 1; n <= o.cameras; n++) {
        const r = await http.request('POST', '/api/v1/cameras', { body: { type: 'rtspURL', name: `Soak ${n}`, mainStreamURL: o.urlTemplate.replace('{n}', String(n)), motionSource: 'webhook', audioEnabled: false } })
        if (r.status !== 201) throw new Error(`adding camera ${n} failed: HTTP ${r.status || r.netError} ${r.json?.error ?? ''} ${r.json?.message ?? ''}`)
        cameras.push({ id: r.json.id, name: r.json.name })
      }
      const storage = await http.request('PATCH', '/api/v1/nvr/storage', { body: { location: 'builtin', keepDays: o.keepDays ?? 7, maxSizeGB: o.capGB, confirm: true } })
      if (storage.status !== 200) throw new Error(`choosing the recordings location failed: HTTP ${storage.status} ${storage.json?.error ?? ''} ${storage.json?.message ?? ''}`)
      // The daemon knows the floor it will pause at; the soak must fit between that floor and the free space, with the cap and a margin to spare.
      // The numbers are zero until the daemon has measured the folder (at most every 5 s): ask until it has.
      let room
      for (const until = Date.now() + 30_000; ; await sleep(1000)) {
        room = await http.request('GET', '/api/v1/nvr/storage')
        if (room.status !== 200) throw new Error(`reading the storage numbers failed: HTTP ${room.status}`)
        if (room.json.totalBytes > 0 || Date.now() > until) break
      }
      if (!(room.json.totalBytes > 0)) throw new Error('the daemon has not measured the recordings folder 30 s after it was chosen')
      const spare = room.json.freeBytes - room.json.floorBytes, wanted = o.capGB * 1e9 + (o.marginGB ?? 8) * 1e9
      if (!Number.isFinite(spare)) throw new Error('GET nvr/storage did not report freeBytes and floorBytes')
      if (spare < wanted) throw new Error(`not enough room: ${Math.round(spare / 1e9)} GB are free above the daemon's floor (free ${Math.round(room.json.freeBytes / 1e9)} GB, floor ${Math.round(room.json.floorBytes / 1e9)} GB), the soak needs ${Math.round(wanted / 1e9)} GB (cap ${o.capGB} GB + ${o.marginGB ?? 8} GB for the files being written). Free disk space or lower --cap-gb (10 is the least the daemon accepts)`)
      for (const camera of cameras) {
        const r = await http.request('PATCH', `/api/v1/cameras/${camera.id}/nvr`, { body: { enabled: true } })
        if (r.status !== 200) throw new Error(`turning Record on for ${camera.name} failed: HTTP ${r.status} ${r.json?.error ?? ''}`)
      }
    }
    fs.writeFileSync(path.join(o.outDir, 'cameras.json'), JSON.stringify(cameras, null, 2))
    // Every camera must have a recording before the clock starts: a camera that never records is a failure to report now, not after two hours.
    while (true) {
      const r = await http.request('GET', '/api/v1/nvr/cameras')
      const have = new Set((r.json?.cameras ?? []).map((c) => c.id))
      if (r.status === 200 && cameras.every((c) => have.has(c.id))) return { cameras, sessionFile }
      if (Date.now() > deadline) throw new Error(`only ${have.size} of ${cameras.length} cameras have a recording after ${o.waitSec ?? 180} s (HTTP ${r.status})`)
      await sleep(1000)
    }
  } finally { http.close() }
}

function parseArgs(argv) {
  const o = {}
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i].replace(/^--/, '').replace(/-([a-z])/g, (_, c) => c.toUpperCase())
    if (key === 'loginOnly') { o.loginOnly = true; continue }
    o[key] = argv[++i]
  }
  return o
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const a = parseArgs(process.argv.slice(2))
  if (!a.base || !a.passwordFile || !a.out) fail('usage: prepare.mjs --base URL --password-file F --out DIR --cameras N --url-template T --cap-gb G')
  try {
    const { cameras } = await prepare({ base: a.base, passwordFile: a.passwordFile, setupTokenFile: a.setupTokenFile, outDir: a.out, cameras: Number(a.cameras ?? 8), urlTemplate: a.urlTemplate,
      capGB: Number(a.capGb ?? 20), keepDays: a.keepDays ? Number(a.keepDays) : undefined, loginOnly: a.loginOnly, waitSec: a.waitSec ? Number(a.waitSec) : undefined })
    console.log(`prepare: ${cameras.length} cameras recording`)
  } catch (error) { fail(error.message) }
}
