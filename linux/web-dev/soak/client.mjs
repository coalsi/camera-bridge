#!/usr/bin/env node
// One scripted browser for the soak (L7.2, L7.3): it drags a timeline at up to 25 pictures a second, settles on an exact frame, plays on,
// and does all of that with the page's own manners (at most 3 byte fetches and 1 JSON request in flight, the newest wish wins, nothing is
// ever aborted) or, as an "aggressive" client, ignoring Retry-After with twice the concurrency. It counts what came back, in 10 s buckets.
//
//   node client.mjs --base http://127.0.0.1:18090 --session SESSION.json --id 1 --seed 101 --style polite|aggressive \
//        --t0 EPOCH_MS --phases PHASES.json --out client-1.ndjson [--end-sec 7200] [--stop-file FILE] [--source-address 127.0.0.2] [--tolerate-slow 1]
import fs from 'node:fs'
import { performance } from 'node:perf_hooks'
import { setTimeout as sleep } from 'node:timers/promises'
import { createHttp, loadSession } from './bridge-http.mjs'
import { Histogram } from './stats.mjs'
import { mulberry32, phaseAt, newGesture, gestureTarget, TICK_MS } from './plan.mjs'
import { checkSegment, checkInit, checkPartHeader, checkPlan, checkAfter, checkCameras, checkActivity } from './checks.mjs'

const MAX_LEAD_IN_BYTES = 16 * 1024 * 1024
const OUTCOMES = ['ok', 'gap', 'gone', 'busy', 'slow', 'unexpected', 'neterr', 'bad', 'retried']

// Counts per (bucket, kind). A bucket is `bucketSec` of run time; finished buckets are appended to the file as one JSON line per kind.
class Buckets {
  constructor(file, client, bucketSec, t0Ms) {
    this.file = file; this.client = client; this.bucketMs = bucketSec * 1000; this.t0Ms = t0Ms
    this.current = new Map(); this.index = 0
    this.lagMax = 0
  }
  slot(kind) {
    const index = Math.floor((Date.now() - this.t0Ms) / this.bucketMs)
    if (index !== this.index) { this.flush(); this.index = index }
    let slot = this.current.get(kind)
    if (!slot) { slot = { n: 0, bytes: 0, superseded: 0, hist: new Histogram(), busyHist: new Histogram(), ...Object.fromEntries(OUTCOMES.map((o) => [o, 0])) }; this.current.set(kind, slot) }
    return slot
  }
  add(kind, outcome, ms, bytes) {
    const slot = this.slot(kind)
    if (outcome !== 'retried') slot.n++
    slot[outcome]++; slot.bytes += bytes ?? 0
    if (outcome === 'ok') slot.hist.add(ms)
    else if (outcome === 'busy') slot.busyHist.add(ms)
  }
  superseded(kind) { this.slot(kind).superseded++ }
  lag(ms) { if (ms > this.lagMax) this.lagMax = ms }
  flush() {
    const lines = []
    for (const [kind, s] of this.current) {
      lines.push(JSON.stringify({ t: this.index * this.bucketMs / 1000, client: this.client, kind, n: s.n, ...Object.fromEntries(OUTCOMES.map((o) => [o, s[o]])), bytes: s.bytes,
        superseded: s.superseded, lag: Math.round(this.lagMax), h: s.hist.toJSON(), hb: s.busyHist.toJSON() }))
    }
    if (lines.length) fs.appendFileSync(this.file, lines.join('\n') + '\n')
    this.current = new Map(); this.lagMax = 0
  }
}

class Slots {
  constructor(cap) { this.cap = cap; this.used = 0 }
  tryTake() { if (this.used >= this.cap) return false; this.used++; return true }
  async take(giveUpMs = 30_000) {
    const until = Date.now() + giveUpMs
    while (!this.tryTake()) { if (Date.now() > until) return false; await sleep(3) }
    return true
  }
  release() { this.used-- }
}

export function classify(kind, r, extra = {}) {
  if (r.netError) return { name: 'neterr', detail: r.netError }
  if (r.status === 200) {
    const why = checkOk(kind, r, extra)
    return why ? { name: 'bad', detail: why } : { name: 'ok' }
  }
  const code = r.json?.error
  if (r.status === 429) return r.headers['retry-after'] ? { name: 'busy' } : { name: 'bad', detail: '429 without Retry-After' }
  if (r.status === 404 && kind === 'key' && code === 'gap') return { name: 'gap' }
  if (r.status === 410 && code === 'gone') return { name: 'gone' }
  // A drive that does not answer is 504 drive_slow: expected only in the hung-volume scenario, where the clients are told to tolerate it.
  if (r.status === 504 && code === 'drive_slow' && extra.tolerateSlow) return { name: 'slow' }
  return { name: 'unexpected', detail: `${r.status} ${code ?? ''}`.trim() }
}

function checkOk(kind, r, extra) {
  if (kind === 'key' || kind === 'fragment' || kind === 'init') {
    if (!/^video\/mp4/.test(r.headers['content-type'] ?? '')) return `content-type ${r.headers['content-type']}`
    if (!/no-store/.test(r.headers['cache-control'] ?? '')) return 'no Cache-Control: no-store'
    if (Number(r.headers['content-length']) !== r.bytes) return `content-length ${r.headers['content-length']} but ${r.bytes} bytes arrived`
    if (kind === 'key') { const why = checkPartHeader(r.headers['x-cb-part'] ?? ''); if (why) return why }
    return kind === 'init' ? checkInit(r.head, r.bytes) : checkSegment(r.head, r.bytes)
  }
  if (r.jsonError || r.json === undefined) return 'the answer is not JSON'
  switch (kind) {
    case 'plan': return checkPlan(r.json)
    case 'after': return checkAfter(r.json)
    case 'cameras': return checkCameras(r.json)
    case 'activity': return checkActivity(r.json, extra.bins)
    default: return null
  }
}

export async function runClient(o) {
  const { base, clientId, seed, t0Ms, phases, outFile, tickMs = TICK_MS, bucketSec = 10 } = o
  const session = o.session ?? loadSession(o.sessionFile)
  const polite = o.style !== 'aggressive'
  const bytesSlots = new Slots(polite ? 3 : 6), jsonSlots = new Slots(polite ? 1 : 2)
  const client = createHttp({ base, session, maxSockets: (polite ? 4 : 8) + 1, localAddress: o.sourceAddress })
  const rng = mulberry32(seed)
  const buckets = new Buckets(outFile, clientId, bucketSec, t0Ms)
  const unexpectedFile = outFile.replace(/\.ndjson$/, '') + '.unexpected.ndjson'
  let unexpectedLogged = 0
  const inflight = new Set()
  const initSeen = new Set()
  let extents = []
  let busyUntil = 0
  const endSec = o.endSec ?? phases.at(-1).to
  const elapsed = () => (Date.now() - t0Ms) / 1000
  const finished = () => elapsed() >= endSec || (o.stopFile && fs.existsSync(o.stopFile))
  // A pause that ends early when the run does, or when a storm begins (`calm`: the pause only lasts while the phase is not a storm).
  const nap = async (ms, calm = false) => { const until = Date.now() + ms; while (!finished() && Date.now() < until && !(calm && stormNow())) await sleep(Math.min(100, Math.max(1, until - Date.now()))) }
  const stormNow = () => phaseAt(phases, elapsed())?.kind === 'storm'

  async function call(kind, path, { collect = 'json', slots, extra } = {}) {
    const r = await client.request('GET', path, { collect })
    const outcome = classify(kind, r, { ...extra, tolerateSlow: o.tolerateSlow })
    buckets.add(kind, outcome.name, r.ms, r.bytes)
    if (r.retried) buckets.add(kind, 'retried', 0, 0)      // counted on the side: the request itself is counted once above
    if (outcome.name === 'busy' && polite) busyUntil = Math.max(busyUntil, Date.now() + Math.min(4, Number(r.headers['retry-after']) || 1) * 1000)
    if ((outcome.name === 'unexpected' || outcome.name === 'bad' || outcome.name === 'neterr') && unexpectedLogged < 50) {
      unexpectedLogged++
      fs.appendFileSync(unexpectedFile, JSON.stringify({ t: Math.round(elapsed()), kind, path: path.replace(/^\/api\/v1\//, ''), status: r.status, outcome: outcome.name, detail: outcome.detail }) + '\n')
    }
    return { r, outcome }
  }
  async function withSlot(slots, kind, work) {
    if (!(await slots.take())) { buckets.superseded(kind); return null }
    try { return await work() } finally { slots.release() }
  }
  const camPath = (id, rest) => `/api/v1/nvr/cameras/${id}/${rest}`

  async function refreshExtents() {
    const out = await withSlot(jsonSlots, 'cameras', () => call('cameras', '/api/v1/nvr/cameras'))
    if (out?.outcome.name === 'ok') extents = out.r.json.cameras
  }

  // The newest wish wins: a tick that finds every byte slot busy is dropped (and counted), as the page's fetcher drops stale requests.
  function issueKey(camera, at) {
    if (polite && Date.now() < busyUntil) { buckets.superseded('key'); return }
    if (!bytesSlots.tryTake()) { buckets.superseded('key'); return }
    const work = call('key', camPath(camera, `keyframe?at=${at}`), { collect: 'media' }).finally(() => { bytesSlots.release(); inflight.delete(work) })
    inflight.add(work)
  }

  async function fetchParts(camera, parts, files) {
    const jobs = []
    for (const part of parts) {
      const info = files[part.file]
      if (info && (!initSeen.has(part.file) || rng() < 0.05)) {
        initSeen.add(part.file)
        jobs.push(() => call('init', camPath(camera, `fragments/${info.initId}/init`), { collect: 'media' }))
      }
      jobs.push(() => call('fragment', camPath(camera, `fragments/${part.id}`), { collect: 'media' }))
    }
    let gone = false
    for (let i = 0; i < jobs.length && !gone; i += 3) {
      const results = await Promise.all(jobs.slice(i, i + 3).map((job) => withSlot(bytesSlots, 'fragment', job)))
      gone = results.some((x) => x?.outcome.name === 'gone')
    }
    return !gone
  }

  async function settle(camera, at) {
    await sleep(80)
    const out = await withSlot(jsonSlots, 'plan', () => call('plan', camPath(camera, `fragments?at=${at}&ahead=1`)))
    if (!out || out.outcome.name !== 'ok' || !out.r.json.found) return null
    const plan = out.r.json
    const leadIn = plan.parts.slice(0, plan.targetIndex + 1).reduce((sum, p) => sum + p.bytes, 0)
    if (leadIn > MAX_LEAD_IN_BYTES) return null
    await fetchParts(camera, plan.parts, plan.files)
    return plan.parts.at(-1).id
  }

  async function play(camera, lastId, seconds) {
    const until = Date.now() + seconds * 1000
    let id = lastId
    while (id && Date.now() < until && !finished() && !stormNow()) {
      await nap(2500, true)
      if (finished() || stormNow()) return
      const out = await withSlot(jsonSlots, 'after', () => call('after', camPath(camera, `fragments?after=${id}&limit=4`)))
      if (!out || out.outcome.name !== 'ok') return
      if (out.r.json.parts.length === 0) continue
      if (!(await fetchParts(camera, out.r.json.parts, out.r.json.files))) return
      id = out.r.json.parts.at(-1).id
    }
  }

  async function drag(gesture, extent) {
    const started = performance.now()
    let last = gesture.startMs
    for (let i = 0; i < gesture.ticks && !finished(); i++) {
      const due = started + i * tickMs
      const wait = due - performance.now()
      if (wait > 1) await sleep(wait)
      buckets.lag(Math.max(0, performance.now() - due))
      last = gestureTarget(gesture, extent, i)
      issueKey(gesture.camera, last)
    }
    return last
  }

  const background = (async () => {
    let last = 0
    while (!finished()) {
      await sleep(250)
      const phase = phaseAt(phases, elapsed())
      if (!phase || phase.kind === 'off') continue
      if (Date.now() - last >= 1000) { last = Date.now(); if (!(polite && Date.now() < busyUntil)) await refreshExtents() }
    }
  })()

  try {
    while (!finished()) {
      if (elapsed() < 0) { await nap(100); continue }      // the run's clock starts a few seconds after the clients
      const phase = phaseAt(phases, elapsed())
      if (!phase) break
      if (phase.kind === 'off') { await nap(500); continue }
      const gesture = extents.length ? newGesture(rng, extents, { tickMs }) : null
      if (!gesture) { await nap(250); continue }
      const extent = extents.find((e) => e.id === gesture.camera)
      const last = await drag(gesture, extent)
      while (inflight.size) await Promise.race([...inflight])
      const lastId = await settle(gesture.camera, last)
      if (phase.kind === 'load') {
        await play(gesture.camera, lastId, 5 + rng() * 15)
        if (rng() < 0.2) {
          const ids = extents.map((e) => e.id).slice(0, 16).join(',')
          const from = Math.floor((Date.now() - 6 * 3600_000) / 60_000) * 60_000
          await withSlot(jsonSlots, 'activity', () => call('activity', `/api/v1/nvr/activity?cameras=${ids}&from=${from}&binMs=60000&bins=120`, { extra: { bins: 120 } }))
        }
        await nap(rng() * 5000, true)
      }
    }
  } finally {
    while (inflight.size) await Promise.race([...inflight])
    await background
    buckets.flush()
    client.close()
  }
}

function parseArgs(argv) {
  const o = {}
  for (let i = 0; i < argv.length; i += 2) o[argv[i].replace(/^--/, '').replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = argv[i + 1]
  return o
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const a = parseArgs(process.argv.slice(2))
  const phases = JSON.parse(fs.readFileSync(a.phases, 'utf8'))
  await runClient({ base: a.base, sessionFile: a.session, clientId: Number(a.id), seed: Number(a.seed), style: a.style, t0Ms: Number(a.t0), phases, outFile: a.out,
    endSec: a.endSec ? Number(a.endSec) : undefined, stopFile: a.stopFile, sourceAddress: a.sourceAddress, tolerateSlow: a.tolerateSlow === '1' })
}
