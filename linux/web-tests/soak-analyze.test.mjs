import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { evaluate, markdown, loadRun, loadSecrets } from '../web-dev/soak/analyze.mjs'
import { buildPhases, mulberry32 } from '../web-dev/soak/plan.mjs'
import { Histogram } from '../web-dev/soak/stats.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const th = JSON.parse(fs.readFileSync(path.join(here, '../web-dev/soak/thresholds.json'), 'utf8'))
const T0 = Date.parse('2026-10-11T08:00:00Z')

// A two hour run in which everything is as it should be. A test breaks one thing and expects exactly the rule that guards it to fail.
function healthyRun({ seconds = 7200, cameras = 8, clients = 6 } = {}) {
  const rng = mulberry32(1)
  const phases = buildPhases(seconds)
  const kind = (t) => phases.find((p) => t >= p.from && t < p.to)?.kind ?? 'off'
  const meta = { runId: 'unit', target: 'mac', t0Ms: T0, endSec: seconds, cameras, seed: 1, capGB: 20, phases, recordingsRoot: '/scratch/rec' }
  const clientRows = []
  for (let c = 1; c <= clients; c++) {
    for (let t = 0; t < seconds; t += 10) {
      const k = kind(t)
      if (k === 'off') continue
      const rate = k === 'storm' ? 25 : 8
      for (const [name, share] of [['key', 1], ['fragment', 0.1], ['plan', 0.03]]) {
        const n = Math.round(rate * 10 * share)
        const h = new Histogram(), hb = new Histogram()
        for (let i = 0; i < n; i++) h.add(8 + rng() * 10)
        if (name === 'key' && k === 'storm') for (let i = 0; i < 40; i++) hb.add(1 + rng() * 2)
        clientRows.push({ t, client: c, kind: name, n, ok: n, gap: 0, gone: 0, busy: name === 'key' && k === 'storm' ? 40 : 0, unexpected: 0, neterr: 0, bad: 0, bytes: n * 1e6, superseded: 3, lag: 5, h: h.toJSON(), hb: hb.toJSON() })
      }
    }
  }
  const samples = []
  let version = 1000
  const capBytes = 20e9
  for (let t = 0; t < seconds; t++) {
    const k = kind(t)
    samples.push({ t, k: 'health', ms: 2 + rng() * (k === 'storm' ? 12 : 4), status: 200, ok: true })
    version += 3
    const cams = {}
    for (let i = 0; i < cameras; i++) cams[`cam${i}`] = { oldest: T0, newest: T0 + t * 1000, lag: 800 + rng() * 1200 + (k === 'storm' ? 100 : 0) }
    samples.push({ t, k: 'catalog', status: 200, ms: 3, serverTime: T0 + t * 1000, version, cams })
    if (t % 5 === 0) samples.push({ t, k: 'status', status: 200, nvr: Object.fromEntries(Array.from({ length: cameras }, (_, i) => [`cam${i}`, { state: 'recording', pause: null, notes: [] }])) })
    if (t % 10 === 0) samples.push({ t, k: 'events', seconds: 10, counts: t % 600 === 0 ? { camera: 1 } : {} })
    if (t % 10 === 0) {
      const used = Math.min(capBytes, t * 8e6)
      const deleted = Math.max(0, t * 8e6 - capBytes)
      samples.push({ t, k: 'storage', status: 200, state: 'ok', used, free: 90e9 - used, total: 994e9, floor: 49.7e9, effectiveMax: capBytes, oldest: T0 + deleted / 8e6 * 1000, newest: T0 + t * 1000, recording: cameras })
      samples.push({ t, k: 'proc', rssKB: 380_000 + rng() * 6000 + (k !== 'off' ? 8000 : 0), fds: 150 + Math.round(rng() * 4), threads: 40 + Math.round(rng() * 3), established: k === 'off' ? 1 : 3 + Math.round(rng() * 3), closeWait: 0 })
    }
  }
  const notify = [{ t: 0, wall: 0, msg: 'LISTENING' }, { t: 1, wall: 0, msg: 'READY=1 | STATUS=Running' }]
  for (let t = 1; t <= seconds; t += 10) notify.push({ t, wall: 0, msg: 'WATCHDOG=1' })
  const lineCount = Math.max(20, Math.round((160 * seconds) / 7200))   // about 80 lines an hour: files opening and closing
  const logLines = Array.from({ length: lineCount }, (_, i) => `${new Date(T0 + (i / lineCount) * seconds * 1000).toISOString()} INFO [Recorder] <-> opened a file`)
  meta.shutdown = { seconds: 2.4, ok: true }
  return { meta, clientRows, unexpected: [], verify: { closed: 120, open: 0, checked: 24, decoded: 6, problems: [] }, samples, notify, logLines }
}

const failures = (run) => evaluate(run, th).filter((r) => !r.pass).map((r) => r.id)

test('a healthy two hour run passes every rule', () => {
  const rules = evaluate(healthyRun(), th)
  assert.deepEqual(rules.filter((r) => !r.pass).map((r) => `${r.id}: ${r.measured}`), [])
  assert.ok(rules.length >= 18)
  assert.ok(rules.every((r) => r.id && r.title && typeof r.measured === 'string'))
})

test('one transport error, one wrong answer or one unexpected status fails the run', () => {
  for (const field of ['neterr', 'bad', 'unexpected']) {
    const run = healthyRun({ seconds: 1200 })
    run.clientRows[5][field] = 1
    assert.ok(failures(run).includes('clients.answers'), field)
  }
})

test('a storm that served almost nothing, or a load generator that fell behind, is not a pass', () => {
  const quiet = healthyRun({ seconds: 1200 })
  for (const r of quiet.clientRows) if (r.kind === 'key') r.ok = 1
  assert.ok(failures(quiet).includes('clients.stormRate'))
  const slow = healthyRun({ seconds: 1200 })
  slow.clientRows.filter((r) => r.kind === 'key').forEach((r, i) => { if (i % 10 === 0) r.lag = 900 })
  assert.ok(failures(slow).includes('clients.lag'))
})

test('a 504 drive_slow in a normal soak is a failure; files left open or unsound after the stop, and a slow stop, fail', () => {
  const slow = healthyRun({ seconds: 1200 }); slow.clientRows[3].slow = 1
  assert.ok(failures(slow).includes('clients.answers'))
  const open = healthyRun({ seconds: 1200 }); open.verify.open = 2
  assert.ok(failures(open).includes('files.sound'))
  const unsound = healthyRun({ seconds: 1200 }); unsound.verify.problems = ['CAM/2026-10-11/07-00-00.mp4: sidecar says 5 bytes']
  assert.ok(failures(unsound).includes('files.sound'))
  const never = healthyRun({ seconds: 1200 }); never.verify = null
  assert.ok(failures(never).includes('files.sound'))
  const stop = healthyRun({ seconds: 1200 }); stop.meta.shutdown = { seconds: 19, ok: true }
  assert.ok(failures(stop).includes('shutdown.clean'))
  const hung = healthyRun({ seconds: 1200 }); hung.meta.shutdown = { seconds: 20, ok: false }
  assert.ok(failures(hung).includes('shutdown.clean'))
})

test('attached to a box, the files are not ours to check and the stop is not ours to time', () => {
  const run = healthyRun({ seconds: 1200 }); run.meta.target = 'attach'; run.verify = null; run.meta.shutdown = { seconds: 0, ok: true }; run.meta.systemd = { restartsBefore: 0, restartsAfter: 0 }
  assert.deepEqual(failures(run), [])
})

test('a rehearsal against the stand-in server skips only what the stand-in cannot do', () => {
  const run = healthyRun({ seconds: 1200 }); run.meta.rehearsal = true; run.notify = []; run.verify = null; run.meta.shutdown = undefined; run.samples = run.samples.filter((s) => s.k !== 'events')
  assert.deepEqual(failures(run), [])
})

test('/health: one failure, a slow 99th percentile or one stall of a second fail', () => {
  const failed = healthyRun({ seconds: 1200 }); failed.samples.find((s) => s.k === 'health').status = 0
  assert.ok(failures(failed).includes('health.latency'))
  const slow = healthyRun({ seconds: 1200 }); slow.samples.filter((s) => s.k === 'health').forEach((s, i) => { if (i % 50 === 0) s.ms = 150 })
  assert.ok(failures(slow).includes('health.latency'))
  const stall = healthyRun({ seconds: 1200 }); stall.samples.filter((s) => s.k === 'health')[300].ms = 1500
  assert.ok(failures(stall).includes('health.latency'))
})

test('latency that creeps up over the run fails, and a worse second storm fails', () => {
  const creeping = healthyRun()
  for (const r of creeping.clientRows) if (r.kind === 'key' && r.t > 3600) { const h = new Histogram(); for (let i = 0; i < r.n; i++) h.add(25 + (r.t - 3600) / 400); r.h = h.toJSON() }
  assert.ok(failures(creeping).includes('latency.flat.key'))
  const worse = healthyRun()
  for (const r of worse.clientRows) if (r.kind === 'key' && r.t >= 5400 && r.t < 6000) { const h = new Histogram(); for (let i = 0; i < r.n; i++) h.add(30); r.h = h.toJSON() }
  assert.ok(failures(worse).includes('latency.storm'))
})

test('429 answers that took 200 ms mean a queue', () => {
  const run = healthyRun()
  for (const r of run.clientRows) if (r.hb.n) { const h = new Histogram(); for (let i = 0; i < r.hb.n; i++) h.add(200); r.hb = h.toJSON() }
  assert.ok(failures(run).includes('busy.immediate'))
})

test('memory that grows 20 MB an hour, a leak of descriptors or threads, connections that stay open', () => {
  const rss = healthyRun(); rss.samples.filter((s) => s.k === 'proc').forEach((s) => { s.rssKB += s.t / 3600 * 20 * 1024 })
  assert.ok(failures(rss).includes('rss.flat'))
  const fds = healthyRun(); fds.samples.filter((s) => s.k === 'proc').forEach((s) => { s.fds += Math.floor(s.t / 60) })
  assert.ok(failures(fds).includes('fds.flat'))
  const kept = healthyRun(); kept.samples.filter((s) => s.k === 'proc' && s.t > 6600).forEach((s) => { s.fds += 30 })   // files still open when the load has stopped
  assert.ok(failures(kept).includes('fds.flat'))
  const threads = healthyRun(); threads.samples.filter((s) => s.k === 'proc').forEach((s, i) => { if (i % 90 === 0) s.threads += 30 })
  assert.ok(failures(threads).includes('threads.flat'))
  const conns = healthyRun(); conns.samples.filter((s) => s.k === 'proc' && s.t > 6600).forEach((s) => { s.established += 6 })   // still open when everyone has gone
  assert.ok(failures(conns).includes('connections.bounded'))
  const many = healthyRun(); many.samples.filter((s) => s.k === 'proc' && s.t > 2500 && s.t < 2600).forEach((s) => { s.established = 70 })
  assert.ok(failures(many).includes('connections.bounded'))
  const closeWait = healthyRun(); closeWait.samples.filter((s) => s.k === 'proc')[40].closeWait = 30
  assert.ok(failures(closeWait).includes('connections.bounded'))
})

test('memory that stays high after a storm fails even if it is flat', () => {
  const run = healthyRun()
  run.samples.filter((s) => s.k === 'proc' && s.t >= 2400 && s.t < 5400).forEach((s) => { s.rssKB += 80_000 })
  run.samples.filter((s) => s.k === 'proc' && s.t >= 5400).forEach((s) => { s.rssKB += 80_000 })
  assert.ok(failures(run).includes('rss.flat'))
})

test('the memory rule judges the daemon\'s own memory and lets a storm\'s working set go', () => {
  // Measured on the Mac (six storms, 75 minutes): ps rss about 600 MB all the time, footprint 180 MB between storms and up to 420 MB in them.
  const shape = (run, own) => {
    const storms = run.meta.phases.filter((p) => p.kind === 'storm')
    for (const s of run.samples.filter((x) => x.k === 'proc')) {
      const storm = storms.find((p) => s.t >= p.from && s.t < p.to + 240)
      s.rssKB = 600_000 + (storm ? 80_000 : 0)
      s.memKB = 180_000 + (storm ? 150_000 * Math.exp(-Math.max(0, s.t - storm.to) / 120) : 0) + own(s)
    }
    return run
  }
  const flat = shape(healthyRun(), () => 0)
  const rule = evaluate(flat, th).find((r) => r.id === 'rss.flat')
  assert.ok(rule.pass, JSON.stringify(rule))
  assert.match(rule.measured, /resident size \(ps\) median 5\d\d MB, not judged/)
  const leak = shape(healthyRun(), (s) => (s.t / 3600) * 30_000)   // 30 MB an hour
  assert.ok(failures(leak).includes('rss.flat'))
  const step = shape(healthyRun(), (s) => (s.t > 4000 ? 60_000 : 0))   // 60 MB more for the last 53 minutes, flat
  assert.ok(failures(step).includes('rss.flat'))
  const kept = shape(healthyRun(), (s) => (s.t >= 2400 ? 40_000 : 0))   // 40 MB kept after the first storm: more than 1.15 x of 180 MB 5 minutes later
  assert.ok(failures(kept).includes('rss.flat'))
  const old = healthyRun()   // samples from a probe that reports only the resident size are judged on it, as before
  assert.ok(!failures(old).includes('rss.flat'))
  assert.match(evaluate(old, th).find((r) => r.id === 'rss.flat').title, /Resident memory/)
})

test('recorders: a paused camera, a missing camera, a stalled catalog and a growing edge lag each fail', () => {
  const paused = healthyRun(); paused.samples.filter((s) => s.k === 'status').slice(100, 104).forEach((s) => { s.nvr.cam3 = { state: 'paused', pause: 'notWritable', notes: [] } })
  assert.ok(failures(paused).includes('recorder.recording'))
  const missing = healthyRun({ cameras: 8 }); missing.meta.cameras = 9
  assert.ok(failures(missing).includes('recorder.recording'))
  const stalled = healthyRun(); stalled.samples.filter((s) => s.k === 'catalog' && s.t > 3000 && s.t < 3020).forEach((s) => { s.version = 777 })
  assert.ok(failures(stalled).includes('recorder.catalog'))
  const lag = healthyRun(); lag.samples.filter((s) => s.k === 'catalog' && s.t >= 5400 && s.t < 6000).forEach((s) => { for (const c of Object.values(s.cams)) c.lag = 3300 })
  assert.ok(failures(lag).includes('recorder.edgeLag'))
})

test('storage: a pause, a near-full disk, or growth past the cap fail; retention that never deletes fails', () => {
  const state = healthyRun(); state.samples.filter((s) => s.k === 'storage')[50].state = 'notWritable'
  assert.ok(failures(state).includes('storage.state'))
  const near = healthyRun(); near.samples.filter((s) => s.k === 'storage')[50].free = near.samples.filter((s) => s.k === 'storage')[50].floor + 3e9
  assert.ok(failures(near).includes('storage.state'))
  const over = healthyRun(); over.samples.filter((s) => s.k === 'storage')[200].used = 40e9
  assert.ok(failures(over).includes('storage.cap'))
  const keeps = healthyRun(); keeps.samples.filter((s) => s.k === 'storage').forEach((s) => { s.oldest = T0 })
  assert.ok(failures(keeps).includes('storage.retention'))
  const short = healthyRun({ seconds: 600 })
  const rule = evaluate(short, th).find((r) => r.id === 'storage.retention')
  assert.ok(rule.pass && /not exercised/.test(rule.measured))
})

test('a storage sample from before the first measurement (all zeros) is not a failure', () => {
  const run = healthyRun({ seconds: 1200 })
  run.samples.unshift({ t: 0.5, k: 'storage', status: 200, state: 'ok', used: 0, free: 0, total: 0, floor: 0, effectiveMax: 0, oldest: null, newest: null, recording: 0 })
  assert.deepEqual(failures(run), [])
})

test('watchdog: a restart (second READY), a 25 s silence, or no pings fail', () => {
  const restart = healthyRun(); restart.notify.push({ t: 3000, wall: 0, msg: 'READY=1 | STATUS=Running' })
  assert.ok(failures(restart).includes('watchdog.continuous'))
  const silent = healthyRun(); silent.notify = silent.notify.filter((n) => !(n.t > 3000 && n.t < 3025))
  assert.ok(failures(silent).includes('watchdog.continuous'))
  const none = healthyRun(); none.notify = none.notify.filter((n) => n.msg !== 'WATCHDOG=1')
  assert.ok(failures(none).includes('watchdog.continuous'))
})

test('a status that changes all the time floods the event stream and fails', () => {
  const run = healthyRun()
  for (const s of run.samples) if (s.k === 'events') s.counts = { camera: 60, notices: 1 }   // six events a second
  assert.ok(failures(run).includes('events.quiet'))
  const none = healthyRun({ seconds: 1200 }); none.samples = none.samples.filter((s) => s.k !== 'events')
  assert.ok(failures(none).includes('events.quiet'))
})

test('descriptors that are the scripted browsers\' own connections do not count as growth, a leak still does', () => {
  // Measured on the Mac (smoke run): 43 descriptors with 4 connections at rest, 69 with 22 connections under load, flat from then on.
  const followConnections = (run, extra = () => 0) => { for (const s of run.samples.filter((x) => x.k === 'proc')) { const load = s.established > 1; s.established = load ? 22 : 4; s.fds = 39 + s.established + (load ? 8 : 0) + extra(s) } return run }
  const run = followConnections(healthyRun())
  const spread = (r) => { const v = r.samples.filter((s) => s.k === 'proc').map((s) => s.fds); return Math.max(...v) - Math.min(...v) }
  assert.ok(spread(run) > 20, 'the raw spread is above the limit of 20: it is the connections')
  assert.ok(!failures(run).includes('fds.flat'), JSON.stringify(evaluate(run, th).find((r) => r.id === 'fds.flat')))
  assert.match(evaluate(run, th).find((r) => r.id === 'fds.flat').measured, /without the connections/)
  const leak = followConnections(healthyRun(), (s) => Math.floor(s.t / 60))
  assert.ok(failures(leak).includes('fds.flat'))
  const stuck = followConnections(healthyRun(), (s) => (s.t > 6600 ? 30 : 0))   // files still open when the load has stopped
  assert.ok(failures(stuck).includes('fds.flat'))
  const jump = followConnections(healthyRun(), (s) => (s.t > 3000 && s.t < 3600 ? 25 : 0))   // 25 descriptors more for ten minutes, connections unchanged
  assert.ok(failures(jump).includes('fds.flat'))
})

test('a busy camera event stream is fine while the NVR status stays quiet, and the NVR status changing all the time is not', () => {
  const busy = healthyRun()
  for (const s of busy.samples) if (s.k === 'events') { s.counts = { cameraNvr: 0, camera: 60 }; s.changed = { 'status.mainStreamInfo.fps': 60 } }   // six events a second, none about the NVR
  const rule = evaluate(busy, th).find((r) => r.id === 'events.quiet')
  assert.ok(rule.pass, JSON.stringify(rule))
  assert.match(rule.measured, /camera events of any kind: [\d,.]+ per camera per hour \(fields that changed most: status\.mainStreamInfo\.fps/)
  const nvr = healthyRun()
  for (const s of nvr.samples) if (s.k === 'events') s.counts = { cameraNvr: 60, camera: 60 }
  assert.ok(failures(nvr).includes('events.quiet'))
  const unknown = healthyRun()   // samples of a sampler that could not tell the events apart: every camera event counts
  for (const s of unknown.samples) if (s.k === 'events') s.counts = { camera: 60 }
  assert.ok(failures(unknown).includes('events.quiet'))
})

test('on a box the watchdog rule is systemd\'s own restart counter', () => {
  const ok = healthyRun({ seconds: 1200 }); ok.meta.systemd = { restartsBefore: 0, restartsAfter: 0 }; ok.notify = []
  assert.ok(!failures(ok).includes('watchdog.continuous'))
  const restarted = healthyRun({ seconds: 1200 }); restarted.meta.systemd = { restartsBefore: 0, restartsAfter: 1 }
  assert.ok(failures(restarted).includes('watchdog.continuous'))
  const unknown = healthyRun({ seconds: 1200 }); unknown.meta.systemd = {}
  assert.ok(failures(unknown).includes('watchdog.continuous'))
})

test('a camera waiting for two seconds after its file rolled is not a gap, a camera waiting for longer is', () => {
  // Measured: a roll closes the file and the next opens at the next key picture, 2.0 to 2.5 s later; the footage is continuous across it (+-15 ms).
  const tag = 'ABCD1234'
  const withIds = (run) => { for (const s of run.samples.filter((x) => x.k === 'status')) { s.nvr = Object.fromEntries(Object.entries(s.nvr).map(([id, v]) => [id === 'cam3' ? `${tag}-0000-4000-8000-000000000001` : id, v])) } return run }
  const run = withIds(healthyRun({ seconds: 1800 }))
  const id = `${tag}-0000-4000-8000-000000000001`
  const statuses = run.samples.filter((s) => s.k === 'status' && s.t >= 100)
  const hits = [statuses[3], statuses[40]]   // two samples, each taken two seconds after a roll of that camera
  for (const s of hits) { s.nvr[id] = { state: 'waiting', pause: null, notes: [] }; run.logLines.push(`${new Date(T0 + (s.t - 2) * 1000).toISOString()} INFO [NVR] <${tag}> Closed a recording file (roll); 450 fragments`) }
  const rule = evaluate(run, th).find((r) => r.id === 'recorder.recording')
  assert.ok(rule.pass, JSON.stringify(rule))
  assert.match(rule.measured, /2 waiting samples right after a file roll not counted/)
  const unexplained = withIds(healthyRun({ seconds: 1800 }))
  for (const s of unexplained.samples.filter((x) => x.k === 'status' && x.t >= 100).slice(3, 8)) s.nvr[id] = { state: 'waiting', pause: null, notes: [] }   // 25 s, no roll
  assert.ok(failures(unexplained).includes('recorder.recording'))
  const long = withIds(healthyRun({ seconds: 1800 }))
  const waiting = long.samples.filter((x) => x.k === 'status' && x.t >= 100).slice(3, 13)   // 50 s: a roll explains the first sample only
  for (const s of waiting) long.samples[long.samples.indexOf(s)].nvr[id] = { state: 'waiting', pause: null, notes: [] }
  long.logLines.push(`${new Date(T0 + (waiting[0].t - 2) * 1000).toISOString()} INFO [NVR] <${tag}> Closed a recording file (roll); 450 fragments`)
  assert.ok(failures(long).includes('recorder.recording'))
})

test('log: too many lines, a secret, a request path or the recordings folder fail', () => {
  const noisy = healthyRun({ seconds: 1200 }); noisy.logLines = Array.from({ length: 5000 }, () => '2026-10-11T08:01:00.000Z INFO [x] <-> noise')
  assert.ok(failures(noisy).includes('log.budget'))
  for (const line of ['2026-10-11T08:01:00.000Z INFO cookie cb_session=abc', '2026-10-11T08:01:00.000Z DEBUG GET /api/v1/nvr/cameras', '2026-10-11T08:01:00.000Z INFO opened /scratch/rec/CAM/2026-10-11/08-00-00.mp4']) {
    const run = healthyRun({ seconds: 1200 }); run.logLines.push(line)
    assert.ok(failures(run).includes('log.budget'), line)
  }
})

test('the word "password" in a log line is fine; the run\'s own password, setup code, cookie or CSRF token is not', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-secrets-'))
  try {
    fs.writeFileSync(path.join(dir, 'pw'), 'f3a91c07d2b84e55aa\n')
    fs.writeFileSync(path.join(dir, 'token'), '9b2e47d1c80a6f33\n')
    fs.writeFileSync(path.join(dir, 'session.json'), JSON.stringify({ cookie: 'cb_session=Zm9vYmFyYmF6cXV4; other=abc', csrf: 'csrf-value-0123456789' }))
    const secrets = loadSecrets([path.join(dir, 'pw'), path.join(dir, 'token'), path.join(dir, 'session.json'), path.join(dir, 'missing')])
    assert.deepEqual(secrets.sort(), ['9b2e47d1c80a6f33', 'Zm9vYmFyYmF6cXV4', 'csrf-value-0123456789', 'f3a91c07d2b84e55aa'].sort())
    const fine = healthyRun({ seconds: 1200 }); fine.secrets = secrets
    fine.logLines.push('2026-10-11T08:01:00.000Z NOTICE [web] <-> the administrator password was set')
    assert.ok(!failures(fine).includes('log.budget'))
    for (const value of secrets) {
      const run = healthyRun({ seconds: 1200 }); run.secrets = secrets
      run.logLines.push(`2026-10-11T08:01:00.000Z INFO something ${value} something`)
      assert.ok(failures(run).includes('log.budget'), value)
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('lines the daemon writes on its own clock do not count as what a storm added, lines about requests do', () => {
  // Measured on the Mac: retention says "Deleted 1 old recordings" every two minutes once the cap is reached (after the first storm, before the second), and
  // the second storm had six of those lines more than the warm-up, which has none.
  const run = healthyRun()
  const second = run.meta.phases.find((p) => p.name === 'storm2')
  for (let t = 2700; t < 7200; t += 60) run.logLines.push(`${new Date(T0 + t * 1000).toISOString()} INFO [NVR] <-> Deleted 1 old recordings`)
  const inStorm = run.logLines.filter((x) => { const t = (Date.parse(x.slice(0, 24)) - T0) / 1000; return t >= second.from && t < second.to && /Deleted/.test(x) }).length
  assert.ok(inStorm >= 9, `retention lines inside the second storm: ${inStorm}`)
  const rule = evaluate(run, th).find((r) => r.id === 'log.budget')
  assert.ok(rule.pass, JSON.stringify(rule))
  for (let i = 0; i < 40; i++) run.logLines.push(`${new Date(T0 + (second.from + 10 + i) * 1000).toISOString()} WARNING [web] <-> something about a request`)
  assert.ok(failures(run).includes('log.budget'))
})

test('the lines of the daemon\'s start and of adding the cameras do not count towards the hourly rate of a short run', () => {
  // Measured in the container: 111 lines before the first sample (the cameras, and one error each from the missing mDNS) and 85 in the 30 minutes after it.
  const run = healthyRun({ seconds: 1800 })
  for (let i = 0; i < 111; i++) run.logLines.push(`${new Date(T0 - 300_000 + i * 1000).toISOString()} INFO [Engine] <-> Added camera or an accessory`)
  const rule = evaluate(run, th).find((r) => r.id === 'log.budget')
  assert.ok(rule.pass, JSON.stringify(rule))
  assert.match(rule.measured, /111 of them before the first sample/)
  const noisy = healthyRun({ seconds: 1800 })
  for (let i = 0; i < 400; i++) noisy.logLines.push(`${new Date(T0 + 100_000 + i * 1000).toISOString()} INFO [x] <-> noise while it runs`)
  assert.ok(failures(noisy).includes('log.budget'))
})

test('retention is judged once it has had time to move the oldest recording of every camera, not before', () => {
  const run = healthyRun({ seconds: 1800 })
  // used grows 8 MB a second to the 20 GB cap at 2,500 s in the healthy run, so give this short run a cap it reaches at 1,500 s
  for (const s of run.samples.filter((x) => x.k === 'storage')) { s.effectiveMax = 12e9; s.used = Math.min(12e9, s.t * 8e6); s.oldest = T0 }
  const rule = evaluate(run, th).find((r) => r.id === 'storage.retention')
  assert.ok(rule.pass, JSON.stringify(rule))
  assert.match(rule.measured, /not judged/)
  const long = healthyRun({ seconds: 7200 })   // cap at 2,500 s, 78 minutes before the end: judged
  for (const s of long.samples.filter((x) => x.k === 'storage')) s.oldest = T0   // and the oldest never moves
  assert.ok(failures(long).includes('storage.retention'))
})

test('the step from the warm-up to the load and the fall in the cool-down are not a slope of descriptors', () => {
  const run = healthyRun({ seconds: 3600 })   // warm-up 300 s, 15 minutes of settling, 19 minutes judged
  const shape = (r, extra) => r.samples.filter((s) => s.k === 'proc').forEach((s) => { const load = s.t >= 300 && s.t < 3300; s.established = load ? 22 : 4; s.fds = 39 + s.established + extra(s) })
  shape(run, (s) => (s.t < 300 ? 0 : Math.min(16, Math.floor((s.t - 300) / 30))))   // the first readers fill the 16 read handles during the first eight minutes
  const rule = evaluate(run, th).find((r) => r.id === 'fds.flat')
  assert.match(rule.measured, /slope 0\/h/, rule.measured)
  assert.ok(rule.pass, JSON.stringify(rule))
  const leak = healthyRun({ seconds: 7200 })
  shape(leak, (s) => 8 + Math.floor(Math.max(0, s.t - 1500) / 120))   // one more descriptor every two minutes after the settling: 30 an hour
  assert.ok(failures(leak).includes('fds.flat'))
})

test('a storm that makes the log talk fails even when the total is small', () => {
  const run = healthyRun()
  const storm = run.meta.phases.find((p) => p.name === 'storm1')
  for (let i = 0; i < 40; i++) run.logLines.push(`${new Date(T0 + (storm.from + 10 + i) * 1000).toISOString()} WARNING [web] <-> something about a request`)
  assert.ok(failures(run).includes('log.budget'))
})

test('the files of a run are read back and the report is written', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-run-'))
  try {
    const run = healthyRun({ seconds: 600 })
    fs.writeFileSync(path.join(dir, 'meta.json'), JSON.stringify(run.meta))
    fs.writeFileSync(path.join(dir, 'client-1.ndjson'), run.clientRows.slice(0, 50).map((r) => JSON.stringify(r)).join('\n') + '\n')
    fs.writeFileSync(path.join(dir, 'samples.ndjson'), run.samples.map((r) => JSON.stringify(r)).join('\n') + '\n')
    fs.writeFileSync(path.join(dir, 'notify.jsonl'), run.notify.map((r) => JSON.stringify(r)).join('\n') + '\n')
    fs.writeFileSync(path.join(dir, 'daemon.log'), run.logLines.join('\n') + '\n')
    const loaded = loadRun(dir)
    assert.equal(loaded.clientRows.length, 50)
    assert.equal(loaded.samples.length, run.samples.length)
    const text = markdown(loaded, evaluate(loaded, th))
    assert.match(text, /^# Soak unit: /)
    assert.match(text, /\| Result \| Rule \|/)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})
