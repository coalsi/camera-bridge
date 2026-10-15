#!/usr/bin/env node
// The evidence and the verdicts of the fault scenarios (kill -9, crash images, a hung volume, a start with a hung volume). The shell code in
// run-soak.sh kills and starts the daemon; this file asks the archive what it still has and judges the answers.
//
//   node scenario-check.mjs snapshot  --base U --session S --out before.json
//   node scenario-check.mjs recovery  --base U --session S --before before.json --kill-wall MS --out recovery.json [--recover-sec 60]
//   node scenario-check.mjs hang-drive --flag FILE --t0 MS --hang-start SEC --hang-end SEC --base U --session S --out hang.json
//   node scenario-check.mjs hang-check --run OUT [--hang hang.json]
//   node scenario-check.mjs startup   --base U --session S --flag FILE --start-wall MS --run OUT --hang-sec 45 --out startup.json
// Every verdict is a list of { id, title, pass, measured, limit } like the soak's rules; the exit status is 1 if any fails.
import fs from 'node:fs'
import path from 'node:path'
import { setTimeout as sleep } from 'node:timers/promises'
import { cameraList, createHttp, loadSession } from './bridge-http.mjs'
import { Histogram, median, percentile } from './stats.mjs'

const check = (id, title, pass, measured, limit) => ({ id, title, pass: Boolean(pass), measured: String(measured), limit: String(limit) })
const fmt = (v, d = 1) => (Number.isFinite(v) ? String(Math.round(v * 10 ** d) / 10 ** d) : String(v))

async function getJSON(http, p) { const r = await http.request('GET', p, { collect: 'json' }); return { status: r.status, json: r.json, ms: r.ms, headers: r.headers } }

// ---- kill -9 and crash images: remember what was there, ask again after the restart -----------------------------------------------------

export async function snapshot({ base, session }) {
  const http = createHttp({ base, session, maxSockets: 2, timeoutMs: 30_000 })
  try {
    const cams = await getJSON(http, '/api/v1/nvr/cameras')
    if (cams.status !== 200) throw new Error(`nvr/cameras answered ${cams.status}`)
    const out = { wallMs: Date.now(), serverTime: cams.json.serverTime, cameras: {} }
    for (const c of cams.json.cameras) {
      const parts = []
      for (const at of [c.newest - 20_000, c.oldest + 8_000]) {
        if (at < c.oldest || at > c.newest) continue
        const plan = await getJSON(http, `/api/v1/nvr/cameras/${c.id}/fragments?at=${at}&ahead=3`)
        if (plan.status === 200 && plan.json.found) for (const p of plan.json.parts) if (!parts.some((q) => q.id === p.id)) parts.push(p)
      }
      out.cameras[c.id] = { oldest: c.oldest, newest: c.newest, parts }
    }
    return out
  } finally { http.close() }
}

export async function recovery({ before, killWallMs, base, session, recoverSec = 60, tailLossMaxSec = 6 }) {
  const http = createHttp({ base, session, maxSockets: 2, timeoutMs: 30_000 })
  const checks = []
  try {
    const ids = Object.keys(before.cameras)
    // 1. recorders come back
    const started = Date.now()
    let all = false, lastStates = ''
    while (Date.now() - started < recoverSec * 1000) {
      const list = await getJSON(http, '/api/v1/cameras')
      const known = cameraList(list.json)
      const states = known ? ids.map((id) => known.find((c) => c.id === id)?.status?.nvr?.state) : []
      lastStates = [...new Set(states)].join(',')
      if (states.length === ids.length && states.every((s) => s === 'recording')) { all = true; break }
      await sleep(1000)
    }
    checks.push(check('recovery.recording', 'Every recorder is recording again', all, all ? `${fmt((Date.now() - started) / 1000)} s after the check began` : `states: ${lastStates}`, `within ${recoverSec} s`))
    // 2. ids and sizes of everything that was safely on disk are unchanged
    let missing = 0, changed = 0, compared = 0, tail = 0
    for (const id of ids) {
      for (const p of before.cameras[id].parts) {
        if (p.end > killWallMs - 5000) { tail++; continue }
        compared++
        const plan = await getJSON(http, `/api/v1/nvr/cameras/${id}/fragments?at=${p.start + 1000}&ahead=0`)
        const found = plan.status === 200 && plan.json.found ? plan.json.parts[plan.json.targetIndex] : null
        if (!found) missing++
        else if (found.id !== p.id || found.bytes !== p.bytes || found.start !== p.start || found.end !== p.end) changed++
      }
    }
    checks.push(check('recovery.ids', 'Every fragment that was on disk before the kill is still there, with the same id and size', compared > 0 && missing === 0 && changed === 0,
      `${compared} fragments compared (${tail} too close to the kill to count): ${missing} missing, ${changed} changed`, 'none missing, none changed (id, size, start and end)'))
    // 3. how much of the tail was lost
    let worst = 0
    for (const id of ids) {
      const plan = await getJSON(http, `/api/v1/nvr/cameras/${id}/fragments?at=${killWallMs - 8000}&ahead=0`)
      if (!(plan.status === 200 && plan.json.found)) { worst = Infinity; continue }
      let last = plan.json.parts[plan.json.targetIndex], guard = 0
      while (guard++ < 12) {
        const next = await getJSON(http, `/api/v1/nvr/cameras/${id}/fragments?after=${last.id}&limit=8`)
        const usable = next.status === 200 ? next.json.parts.filter((p) => p.start < killWallMs) : []
        if (usable.length === 0) break
        last = usable.at(-1)
      }
      worst = Math.max(worst, Math.max(0, killWallMs - last.end) / 1000)
    }
    checks.push(check('recovery.tail', 'Only the last moments before the kill were lost', worst <= tailLossMaxSec, `${fmt(worst)} s lost in the worst camera`, `<= ${tailLossMaxSec} s`))
    // 4. new footage after the kill (the first new fragment is a few seconds behind the recorders' restart: ask until it is there)
    let newer = 0
    const until = Date.now() + recoverSec * 1000
    while (true) {
      const cams = await getJSON(http, '/api/v1/nvr/cameras')
      newer = cams.status === 200 ? cams.json.cameras.filter((c) => ids.includes(c.id) && c.newest > killWallMs).length : 0
      if (newer === ids.length || Date.now() > until) break
      await sleep(1000)
    }
    checks.push(check('recovery.newFootage', 'New footage is being recorded after the restart', newer === ids.length, `${newer} of ${ids.length} cameras have footage newer than the kill`, 'all'))
  } finally { http.close() }
  return checks
}

// ---- a hung volume ------------------------------------------------------------------------------------------------------------------------

// Creates the flag at hangStart and removes it at hangEnd (seconds since t0), asks for the locations once while hung, writes the times.
export async function hangDrive({ flag, t0Ms, hangStartSec, hangEndSec, base, session, out }) {
  const wait = async (sec) => { while (Date.now() < t0Ms + sec * 1000) await sleep(Math.min(500, t0Ms + sec * 1000 - Date.now())) }
  const http = createHttp({ base, session, maxSockets: 1, timeoutMs: 40_000 })
  const record = { hangStartSec, hangEndSec, flag: null }
  try {
    await wait(hangStartSec)
    fs.writeFileSync(flag, '')
    record.startedAt = (Date.now() - t0Ms) / 1000
    await wait(hangStartSec + 8)
    const r = await getJSON(http, '/api/v1/nvr/storage/locations')
    record.locations = { status: r.status, seconds: r.ms / 1000, problem: r.json?.locations?.[0]?.problem ?? null }
    await wait(hangEndSec)
    fs.rmSync(flag, { force: true })
    record.endedAt = (Date.now() - t0Ms) / 1000
  } finally { fs.rmSync(flag, { force: true }); http.close() }
  fs.writeFileSync(out, JSON.stringify(record, null, 2))
  return record
}

function jsonLines(file) { return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).flatMap((l) => { try { return [JSON.parse(l)] } catch { return [] } }) : [] }

export function hangCheck({ samples, notify, clientRows, shimLog, hang, cameras, th = {} }) {
  const { pauseWithinSec = 45, recoverWithinSec = 90, healthP99Ms = 100, healthMaxMs = 1000, threadsExtra = 30, threadsBackExtra = 8, locationsMaxSec = 12 } = th
  const during = (s) => s.t >= hang.startedAt && s.t < hang.endedAt
  const checks = []
  const health = samples.filter((s) => s.k === 'health' && during(s))
  const failed = health.filter((s) => s.status !== 200 || !s.ok).length
  const ms = health.filter((s) => s.status === 200).map((s) => s.ms)
  checks.push(check('hang.health', '/health stayed quick while the volume hung', health.length > 20 && failed === 0 && percentile(ms, 99) <= healthP99Ms && Math.max(...ms) <= healthMaxMs,
    `${health.length} samples, ${failed} failed, p99 ${fmt(percentile(ms, 99))} ms, max ${fmt(Math.max(...ms))} ms`, `0 failed, p99 <= ${healthP99Ms} ms, max <= ${healthMaxMs} ms`))
  const pingWalls = notify.filter((n) => n.msg === 'WATCHDOG=1').map((n) => n.wall).sort((a, b) => a - b)
  let gap = 0
  for (let i = 1; i < pingWalls.length; i++) gap = Math.max(gap, pingWalls[i] - pingWalls[i - 1])
  const readyCount = notify.filter((n) => /^READY=1/.test(n.msg)).length
  checks.push(check('hang.watchdog', 'The watchdog kept being answered and the daemon was not restarted', readyCount === 1 && gap <= 20 && pingWalls.length > 5, `${pingWalls.length} pings, longest silence ${fmt(gap)} s, ${readyCount} READY`, 'one READY, silence <= 20 s'))
  const status = samples.filter((s) => s.k === 'status' && s.status === 200)
  const paused = status.find((s) => s.t >= hang.startedAt && Object.keys(s.nvr).length >= cameras && Object.values(s.nvr).every((n) => n.state === 'paused'))
  checks.push(check('hang.paused', 'Every recorder paused with a sentence instead of blocking', Boolean(paused) && paused.t - hang.startedAt <= pauseWithinSec,
    paused ? `all ${cameras} paused (${[...new Set(Object.values(paused.nvr).map((n) => n.pause))].join(',')}) after ${fmt(paused.t - hang.startedAt)} s` : 'they did not all pause', `all ${cameras} within ${pauseWithinSec} s`))
  const storage = samples.filter((s) => s.k === 'storage' && s.status === 200 && s.t > hang.startedAt + pauseWithinSec && s.t < hang.endedAt)
  checks.push(check('hang.storage', 'GET nvr/storage says the drive is the problem, and answers at once', storage.length > 0 && storage.every((s) => s.state !== 'ok' && s.ms <= 100),
    `${storage.length} samples, states ${[...new Set(storage.map((s) => s.state))].join(',')}, slowest ${fmt(Math.max(0, ...storage.map((s) => s.ms)))} ms`, 'not ok, <= 100 ms'))
  const proc = samples.filter((s) => s.k === 'proc')
  const base = median(proc.filter((s) => s.t < hang.startedAt && s.t > 30).map((s) => s.threads))
  const peak = Math.max(...proc.filter(during).map((s) => s.threads))
  checks.push(check('hang.threads', 'Blocked calls did not pile up threads', peak <= base + threadsExtra, `${base} before, ${peak} at most while hung`, `<= +${threadsExtra}`))
  const after = proc.filter((s) => s.t >= hang.endedAt + recoverWithinSec - 20 && s.t <= hang.endedAt + recoverWithinSec + 30)
  checks.push(check('hang.threadsBack', 'Threads went back after the drive answered again', after.length > 0 && Math.max(...after.map((s) => s.threads)) <= base + threadsBackExtra, `${after.length ? Math.max(...after.map((s) => s.threads)) : 'no samples'} against ${base} before`, `<= +${threadsBackExtra}`))
  // The banner: the event stream carries a `notices` event when the drive stops answering, and another when it answers again (rows are flushed every 10 s: some slack).
  const noticeCount = (from, to) => samples.filter((s) => s.k === 'events' && s.counts && s.t >= from && s.t <= to).reduce((sum, s) => sum + (s.counts.notices ?? 0), 0)
  const appeared = noticeCount(hang.startedAt, hang.startedAt + pauseWithinSec + 30), cleared = noticeCount(hang.endedAt, hang.endedAt + recoverWithinSec + 10)
  checks.push(check('hang.notice', 'The page was told: a notices event when the drive stopped answering and another when it came back', appeared >= 1 && cleared >= 1, `${appeared} notices events after the hang began, ${cleared} after it ended`, 'at least one each'))
  const blocked = shimLog.filter((l) => / blocked /.test(l))
  checks.push(check('hang.shim', 'The fault injector really blocked calls (positive control)', blocked.length > 0, `${blocked.length} functions blocked: ${blocked.map((l) => l.split(' ').pop()).join(', ')}`, 'at least one'))
  const bad = clientRows.reduce((s, r) => s + (r.neterr ?? 0) + (r.bad ?? 0) + (r.unexpected ?? 0), 0)
  const slow = clientRows.reduce((s, r) => s + (r.slow ?? 0), 0)
  checks.push(check('hang.clients', 'Readers got clean answers (504 drive_slow allowed), no transport errors', bad === 0, `${bad} failures, ${slow} slow-drive answers`, '0 failures'))
  if (hang.locations) checks.push(check('hang.locations', 'The location check on a hung drive answered within its deadline', [200, 504].includes(hang.locations.status) && hang.locations.seconds <= locationsMaxSec,
    `HTTP ${hang.locations.status} after ${fmt(hang.locations.seconds)} s${hang.locations.problem ? ` (${hang.locations.problem})` : ''}`, `200 or 504 within ${locationsMaxSec} s`))
  const resumed = status.find((s) => s.t >= hang.endedAt && Object.keys(s.nvr).length >= cameras && Object.values(s.nvr).every((n) => n.state === 'recording'))
  checks.push(check('hang.recovery', 'Recording resumed on its own after the drive answered again', Boolean(resumed) && resumed.t - hang.endedAt <= recoverWithinSec, resumed ? `all recording ${fmt(resumed.t - hang.endedAt)} s after release` : 'they did not all resume', `within ${recoverWithinSec} s`))
  const versions = samples.filter((s) => s.k === 'catalog' && s.status === 200)
  const vAtEnd = versions.find((s) => s.t >= hang.endedAt)?.version, vLater = versions.at(-1)?.version
  checks.push(check('hang.catalog', 'The catalog advanced again', vLater > vAtEnd, `${vAtEnd} then ${vLater}`, 'increasing'))
  return checks
}

// ---- a start with a hung volume ------------------------------------------------------------------------------------------------------------

export async function startupDrive({ base, session, flag, startWallMs, runOut, hangSec = 45, readySec = 90, cameras }) {
  const http = createHttp({ base, session, maxSockets: 2, timeoutMs: 30_000 })
  const probes = []
  const probe = async (label, p) => { const r = await getJSON(http, p); probes.push({ label, status: r.status, ms: r.ms, retryAfter: r.headers?.['retry-after'] ?? null, error: r.json?.error ?? null, wall: Date.now() }); return r }
  try {
    const begin = Date.now()
    while (Date.now() - begin < hangSec * 1000) {
      await probe('status', '/api/v1/status'); await probe('health', '/api/v1/health'); await probe('nvrCameras', '/api/v1/nvr/cameras'); await probe('storage', '/api/v1/nvr/storage')
      await sleep(2000)
    }
    fs.rmSync(flag, { force: true })
    const released = Date.now()
    let readyAt = null, recordingAt = null
    while (Date.now() - released < readySec * 1000 && !recordingAt) {
      const cams = await probe('nvrCamerasAfter', '/api/v1/nvr/cameras')
      if (cams.status === 200 && !readyAt) readyAt = Date.now()
      const list = await getJSON(http, '/api/v1/cameras')
      if (readyAt && (cameraList(list.json) ?? []).filter((c) => c.status?.nvr?.state === 'recording').length >= cameras) recordingAt = Date.now()
      await sleep(1000)
    }
    const notify = jsonLines(path.join(runOut, 'notify.jsonl')).filter((n) => n.wall * 1000 >= startWallMs - 2000)
    return startupCheck({ probes, notify, startWallMs, releasedMs: released, readyAt, recordingAt, hangSec })
  } finally { fs.rmSync(flag, { force: true }); http.close() }
}

export function startupCheck({ probes, notify, startWallMs, releasedMs, readyAt, recordingAt, hangSec }) {
  const checks = []
  const ready = notify.find((n) => /^READY=1/.test(n.msg))
  const readySec = ready ? ready.wall - startWallMs / 1000 : Infinity
  checks.push(check('startup.ready', 'READY=1 came at once although the recordings folder hangs', readySec <= 10, ready ? `${fmt(readySec)} s after the process started` : 'never', '<= 10 s (the unit allows 120)'))
  const quick = (label) => probes.filter((p) => p.label === label)
  for (const [label, title] of [['status', 'GET /status'], ['health', 'GET /health'], ['storage', 'GET nvr/storage']]) {
    const rows = quick(label)
    checks.push(check(`startup.${label}`, `${title} answers quickly while the folder hangs`, rows.length > 3 && rows.every((p) => p.status === 200 && p.ms <= 100), `${rows.length} probes, slowest ${fmt(Math.max(0, ...rows.map((p) => p.ms)))} ms, statuses ${[...new Set(rows.map((p) => p.status))].join(',')}`, 'all 200, <= 100 ms'))
  }
  const cams = quick('nvrCameras')
  checks.push(check('startup.loading', 'The archive says "loading" (503 with Retry-After) instead of hanging', cams.length > 3 && cams.every((p) => p.ms <= 100 && (p.status === 200 || (p.status === 503 && p.error === 'archive_unavailable' && p.retryAfter === '2'))),
    `${cams.length} probes, statuses ${[...new Set(cams.map((p) => p.status))].join(',')}, slowest ${fmt(Math.max(0, ...cams.map((p) => p.ms)))} ms`, '200, or 503 archive_unavailable with Retry-After 2; <= 100 ms'))
  const pings = notify.filter((n) => n.msg === 'WATCHDOG=1').map((n) => n.wall).sort((a, b) => a - b)
  let gap = 0
  for (let i = 1; i < pings.length; i++) gap = Math.max(gap, pings[i] - pings[i - 1])
  checks.push(check('startup.watchdog', 'The watchdog was answered all along', pings.length >= Math.floor(hangSec / 10) && gap <= 20, `${pings.length} pings, longest silence ${fmt(gap)} s`, 'silence <= 20 s'))
  checks.push(check('startup.catalog', 'The archive became ready after the folder answered again', Boolean(readyAt), readyAt ? `${fmt((readyAt - releasedMs) / 1000)} s after release` : 'never ready', 'within 90 s'))
  checks.push(check('startup.recording', 'Every camera recorded again', Boolean(recordingAt), recordingAt ? `${fmt((recordingAt - releasedMs) / 1000)} s after release` : 'they did not', 'within 90 s'))
  return checks
}

// ---- command line --------------------------------------------------------------------------------------------------------------------------

function report(checks) {
  for (const c of checks) console.log(`${c.pass ? 'pass' : 'FAIL'}  ${c.id}: ${c.title}\n        measured ${c.measured}; limit ${c.limit}`)
  return checks.every((c) => c.pass)
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [command, ...rest] = process.argv.slice(2)
  const a = {}
  for (let i = 0; i < rest.length; i += 2) a[rest[i].replace(/^--/, '')] = rest[i + 1]
  const session = a.session ? loadSession(a.session) : null
  let checks = null
  if (command === 'snapshot') fs.writeFileSync(a.out, JSON.stringify(await snapshot({ base: a.base, session }), null, 2))
  else if (command === 'recovery') {
    checks = await recovery({ before: JSON.parse(fs.readFileSync(a.before, 'utf8')), killWallMs: Number(a['kill-wall']), base: a.base, session, recoverSec: Number(a['recover-sec'] ?? 60) })
    fs.writeFileSync(a.out, JSON.stringify(checks, null, 2))
  } else if (command === 'hang-drive') {
    await hangDrive({ flag: a.flag, t0Ms: Number(a.t0), hangStartSec: Number(a['hang-start']), hangEndSec: Number(a['hang-end']), base: a.base, session, out: a.out })
  } else if (command === 'hang-check') {
    const run = a.run
    const hang = JSON.parse(fs.readFileSync(a.hang ?? path.join(run, 'hang.json'), 'utf8'))
    const meta = JSON.parse(fs.readFileSync(path.join(run, 'meta.json'), 'utf8'))
    const clientRows = fs.readdirSync(run).filter((f) => /^client-\d+\.ndjson$/.test(f)).flatMap((f) => jsonLines(path.join(run, f)))
    const shimLog = fs.existsSync(path.join(run, 'shim.log')) ? fs.readFileSync(path.join(run, 'shim.log'), 'utf8').split('\n').filter(Boolean) : []
    checks = hangCheck({ samples: jsonLines(path.join(run, 'samples.ndjson')), notify: jsonLines(path.join(run, 'notify.jsonl')), clientRows, shimLog, hang, cameras: meta.cameras })
    fs.writeFileSync(path.join(run, 'hang-verdict.json'), JSON.stringify(checks, null, 2))
  } else if (command === 'startup') {
    checks = await startupDrive({ base: a.base, session, flag: a.flag, startWallMs: Number(a['start-wall']), runOut: a.run, hangSec: Number(a['hang-sec'] ?? 45), cameras: Number(a.cameras) })
    fs.writeFileSync(a.out, JSON.stringify(checks, null, 2))
  } else { console.error('usage: scenario-check.mjs snapshot|recovery|hang-drive|hang-check|startup ...'); process.exit(2) }
  if (checks) process.exit(report(checks) ? 0 : 1)
}
