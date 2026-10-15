#!/usr/bin/env node
// Watches the daemon while the soak runs: /health every second (the starvation canary), the recorders' edge lag and the catalog version
// every second, the cameras' recording states every 5 s, the storage numbers and the process (RSS, descriptors, threads, connections)
// every 10 s, and the server-sent event stream the page keeps open (how many `camera` and `notices` events it carries: the status must change rarely).
// One JSON line per sample in samples.ndjson, with `t` in seconds since the start of the run.
//
//   node sampler.mjs --base URL --session SESSION.json --t0 EPOCH_MS --end-sec N --out samples.ndjson --pid PID --port PORT --platform darwin|linux \
//        --probe-script Tools/nvr-soak/probe.sh [--probe-cmd "docker exec -i NAME"] [--stop-file FILE]
import fs from 'node:fs'
import nodeHttp from 'node:http'
import { spawn } from 'node:child_process'
import { setTimeout as sleep } from 'node:timers/promises'
import { cameraList, createHttp, loadSession } from './bridge-http.mjs'

export async function runSampler(o) {
  const session = o.session ?? loadSession(o.sessionFile)
  const http = createHttp({ base: o.base, session, maxSockets: 3, timeoutMs: 20_000 })
  const every = { health: 1000, catalog: 1000, status: 5000, storage: 10_000, proc: 10_000, ...(o.intervals ?? {}) }
  const elapsed = () => (Date.now() - o.t0Ms) / 1000
  const finished = () => elapsed() >= o.endSec || (o.stopFile && fs.existsSync(o.stopFile))
  const write = (row) => fs.appendFileSync(o.outFile, JSON.stringify({ t: Math.round(elapsed() * 1000) / 1000, ...row }) + '\n')
  const probeScript = o.probeScript ? fs.readFileSync(o.probeScript, 'utf8') : null

  async function loop(name, work) {
    let next = Date.now()
    while (!finished()) {
      try { await work() } catch (error) { write({ k: name, err: String(error.message ?? error) }) }
      next += every[name]
      if (next < Date.now()) next = Date.now()
      while (!finished() && Date.now() < next) await sleep(Math.min(250, next - Date.now()))   // wakes up to notice the end of the run
    }
  }

  const health = () => loop('health', async () => {
    const r = await http.request('GET', '/api/v1/health', { collect: 'json' })
    write({ k: 'health', ms: Math.round(r.ms * 100) / 100, status: r.status, ok: r.json?.ok === true, ...(r.netError ? { err: r.netError } : {}) })
  })

  const catalog = () => loop('catalog', async () => {
    const r = await http.request('GET', '/api/v1/nvr/cameras', { collect: 'json' })
    if (r.status !== 200 || !r.json) return write({ k: 'catalog', status: r.status, ms: Math.round(r.ms), ...(r.netError ? { err: r.netError } : {}) })
    const cams = {}
    for (const c of r.json.cameras) cams[c.id] = { oldest: c.oldest, newest: c.newest, lag: r.json.serverTime - c.newest }
    write({ k: 'catalog', status: 200, ms: Math.round(r.ms), serverTime: r.json.serverTime, version: r.json.catalogVersion, cams })
  })

  const status = () => loop('status', async () => {
    const r = await http.request('GET', '/api/v1/cameras', { collect: 'json' })
    const list = cameraList(r.json)
    if (r.status !== 200 || !list) return write({ k: 'status', status: r.status })
    const nvr = {}
    for (const c of list) if (c.nvrEnabled) nvr[c.id] = { state: c.status?.nvr?.state ?? 'unknown', pause: c.status?.nvr?.pause ?? null, notes: (c.status?.nvr?.notes ?? []).map((n) => n.id) }
    write({ k: 'status', status: 200, nvr })
  })

  const storage = () => loop('storage', async () => {
    const r = await http.request('GET', '/api/v1/nvr/storage', { collect: 'json' })
    if (r.status !== 200 || !r.json) return write({ k: 'storage', status: r.status, ms: Math.round(r.ms) })
    const s = r.json
    write({ k: 'storage', status: 200, ms: Math.round(r.ms), state: s.state, used: s.usedBytes, free: s.freeBytes, total: s.totalBytes, floor: s.floorBytes, effectiveMax: s.effectiveMaxBytes,
      oldest: s.oldest, newest: s.newest, recording: s.recordingCameras })
  })

  const proc = () => loop('proc', async () => {
    if (!probeScript) return
    const [command, ...prefix] = (o.probeCommand ?? 'sh').split(/\s+/)
    const args = [...prefix, ...(command === 'sh' && prefix.length === 0 ? [] : ['sh']), '-s', '--', o.platform, String(o.pid), String(o.port)]
    const out = await new Promise((resolve) => {
      const child = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'] })
      let text = ''
      const timer = setTimeout(() => child.kill('SIGKILL'), 20_000)
      child.stdout.on('data', (d) => { text += d })
      child.on('close', (code) => { clearTimeout(timer); resolve(code === 0 ? text.trim() : null) })
      child.on('error', () => { clearTimeout(timer); resolve(null) })
      child.stdin.end(probeScript)
    })
    const parts = out?.split(/\s+/).map(Number)
    // Five numbers from a probe that does not know the process's own memory, six from one that does (memKB, 0 when the system does not say).
    if (!parts || (parts.length !== 5 && parts.length !== 6) || parts.some(Number.isNaN)) return write({ k: 'proc', err: 'the probe gave no numbers (is the process gone?)' })
    const [rssKB, fds, threads, established, closeWait, memKB] = parts
    write({ k: 'proc', rssKB, fds, threads, established, closeWait, ...(memKB > 0 ? { memKB } : {}) })
  })

  // The event stream: counts events by name per 10 s. The snapshot a new listener gets first (one event per camera) is not counted: it is not news.
  const events = async () => {
    const url = new URL(o.base)
    const counts = {}
    let flushedAt = Date.now(), connectedAt = 0, request = null
    // `camera` counts every camera event; `cameraNvr` only those in which the camera's `status.nvr` differs from the camera's previous event (the NVR must
    // change rarely, T00 B.3); `changed` says which fields of the camera status changed, as dotted paths (the evidence when the stream is busy).
    const previous = new Map(), changed = {}
    let event = null
    const flat = (value, prefix, out) => {
      if (value && typeof value === 'object' && !Array.isArray(value)) for (const [key, inner] of Object.entries(value)) flat(inner, prefix ? `${prefix}.${key}` : key, out)
      else out[prefix] = JSON.stringify(value)
      return out
    }
    const cameraData = (text) => {
      let json
      try { json = JSON.parse(text) } catch { return }
      const id = json?.id ?? json?.camera?.id
      if (typeof id !== 'string' || !json.status || typeof json.status !== 'object') return
      const now = flat(json.status, 'status', {}), before = previous.get(id)
      previous.set(id, now)
      if (!before || Date.now() - connectedAt <= 3000) return
      let nvrChanged = false
      for (const key of new Set([...Object.keys(now), ...Object.keys(before)])) {
        if (now[key] === before[key]) continue
        changed[key] = (changed[key] ?? 0) + 1
        if (key === 'status.nvr' || key.startsWith('status.nvr.')) nvrChanged = true
      }
      if (nvrChanged) counts.cameraNvr = (counts.cameraNvr ?? 0) + 1
    }
    const flush = () => {
      const seconds = (Date.now() - flushedAt) / 1000; flushedAt = Date.now()
      const row = { k: 'events', seconds: Math.round(seconds * 10) / 10, counts: { cameraNvr: 0, ...counts } }
      if (Object.keys(changed).length) row.changed = { ...changed }
      write(row)
      for (const key of Object.keys(counts)) delete counts[key]
      for (const key of Object.keys(changed)) delete changed[key]
    }
    const ticker = setInterval(flush, 10_000)
    try {
      while (!finished()) {
        await new Promise((resolve) => {
          let buffer = ''
          request = nodeHttp.get({ host: url.hostname, port: url.port, path: '/api/v1/events', headers: { cookie: session.cookie, accept: 'text/event-stream' } }, (res) => {
            connectedAt = Date.now()
            res.setEncoding('utf8')
            res.on('data', (chunk) => {
              buffer += chunk
              let at
              while ((at = buffer.indexOf('\n')) >= 0) {
                const line = buffer.slice(0, at); buffer = buffer.slice(at + 1)
                const m = /^event: (\w+)/.exec(line)
                if (m) event = m[1]
                if (m && Date.now() - connectedAt > 3000) counts[m[1]] = (counts[m[1]] ?? 0) + 1
                if (event === 'camera' && line.startsWith('data: ')) cameraData(line.slice(6))
              }
            })
            res.on('end', resolve); res.on('error', resolve); res.on('close', resolve)
          })
          request.on('error', resolve)
          const watch = setInterval(() => { if (finished()) { request.destroy(); clearInterval(watch); resolve() } }, 250)
          request.on('close', () => clearInterval(watch))
        })
        if (!finished()) { write({ k: 'events', reconnect: true }); await sleep(3000) }
      }
    } finally { clearInterval(ticker); flush(); request?.destroy() }
  }

  try { await Promise.all([health(), catalog(), status(), storage(), proc(), events()]) } finally { http.close() }
}

function parseArgs(argv) {
  const o = {}
  for (let i = 0; i < argv.length; i += 2) o[argv[i].replace(/^--/, '').replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = argv[i + 1]
  return o
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const a = parseArgs(process.argv.slice(2))
  await runSampler({ base: a.base, sessionFile: a.session, t0Ms: Number(a.t0), endSec: Number(a.endSec), outFile: a.out, pid: a.pid, port: a.port, platform: a.platform,
    probeScript: a.probeScript, probeCommand: a.probeCmd, stopFile: a.stopFile })
}
