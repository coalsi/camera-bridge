#!/usr/bin/env node
// Turns the files of a soak run into a verdict. Every rule is a function from the run and the thresholds to
// { id, title, pass, measured, limit, note }; the thresholds are in thresholds.json (one place to change a limit, with a reason in the commit).
//
//   node analyze.mjs --run RUN/out [--thresholds thresholds.json] [--secrets FILE,FILE]      writes RUN/out/verdict.json and RUN/out/results.md; exit 1 if any rule fails
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { Histogram, median, percentile, slope } from './stats.mjs'
import { phaseAt } from './plan.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))

function lines(file) { return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split('\n').filter(Boolean) : [] }
function jsonLines(file) { return lines(file).flatMap((l) => { try { return [JSON.parse(l)] } catch { return [] } }) }

// The values a log must never contain: the run's password and setup code, and the session's cookie and CSRF token. Read from the files the harness
// keeps them in, only here, only in memory.
export function loadSecrets(files) {
  const found = new Set()
  for (const file of files) {
    if (!fs.existsSync(file)) continue
    const text = fs.readFileSync(file, 'utf8').trim()
    let values = [text]
    try { const json = JSON.parse(text); if (json && typeof json === 'object') values = Object.values(json).flatMap((v) => String(v).split(/;\s*/).map((part) => part.split('=').pop())) } catch { /* not JSON: the whole file is the secret */ }
    for (const v of values) if (v.length >= 8) found.add(v)
  }
  return [...found]
}

export function loadRun(dir, secretFiles = []) {
  const meta = JSON.parse(fs.readFileSync(path.join(dir, 'meta.json'), 'utf8'))
  const clientRows = fs.readdirSync(dir).filter((f) => /^client-\d+\.ndjson$/.test(f)).flatMap((f) => jsonLines(path.join(dir, f)))
  const unexpected = fs.readdirSync(dir).filter((f) => /\.unexpected\.ndjson$/.test(f)).flatMap((f) => jsonLines(path.join(dir, f)))
  const verifyFile = path.join(dir, 'verify.json')
  const verify = fs.existsSync(verifyFile) ? JSON.parse(fs.readFileSync(verifyFile, 'utf8')) : null
  return { meta, clientRows, unexpected, verify, secrets: loadSecrets(secretFiles), samples: jsonLines(path.join(dir, 'samples.ndjson')), notify: jsonLines(path.join(dir, 'notify.jsonl')), logLines: lines(path.join(dir, 'daemon.log')) }
}

const fmt = (v, digits = 1) => (typeof v === 'number' && Number.isFinite(v) ? String(Math.round(v * 10 ** digits) / 10 ** digits) : String(v))
const result = (id, title, pass, measured, limit, note = '') => ({ id, title, pass: Boolean(pass), measured, limit, note })
const phaseKind = (run, t) => phaseAt(run.meta.phases, t)?.kind ?? 'off'
const phaseName = (run, t) => phaseAt(run.meta.phases, t)?.name ?? ''

// ---- the rules -----------------------------------------------------------------------------------------------------------------------

function rClients(run, th) {
  const c = th.clients
  const total = { neterr: 0, bad: 0, unexpected: 0, slow: 0, busy: 0, superseded: 0, ok: 0, retried: 0 }
  for (const row of run.clientRows) for (const k of Object.keys(total)) total[k] += row[k] ?? 0
  const first = run.unexpected.slice(0, 3).map((u) => `${u.kind} ${u.status} ${u.detail ?? ''}`.trim()).join('; ')
  return result('clients.answers', 'Every answer was right, none failed in transport', total.neterr <= c.maxNetworkErrors && total.bad <= c.maxWrongAnswers && total.unexpected + total.slow <= c.maxUnexpectedStatuses,
    `${total.neterr} transport errors, ${total.bad} wrong answers, ${total.unexpected + total.slow} unexpected statuses (${total.slow} of them 504 drive_slow); ${total.ok} good, ${total.busy} busy, ${total.superseded} dropped by the page rules, ${total.retried} sent again after a kept-alive connection had been closed`,
    `${c.maxNetworkErrors} / ${c.maxWrongAnswers} / ${c.maxUnexpectedStatuses}`, first)
}

function rStormRate(run, th) {
  const storms = run.meta.phases.filter((p) => p.kind === 'storm')
  if (storms.length === 0) return result('clients.stormRate', 'The storm really ran', true, 'no storm phase in this run', 'n/a')
  const rates = storms.map((p) => {
    const ok = run.clientRows.filter((r) => r.kind === 'key' && r.t >= p.from && r.t < p.to).reduce((s, r) => s + r.ok, 0)
    return ok / (p.to - p.from)
  })
  const worst = Math.min(...rates)
  return result('clients.stormRate', 'The storm really ran (good pictures a second, all clients)', worst >= th.clients.stormKeyPicturesPerSecondMin, rates.map((r) => fmt(r)).join(', '), `at least ${th.clients.stormKeyPicturesPerSecondMin}`)
}

function rClientLag(run, th) {
  const rows = run.clientRows.filter((r) => r.kind === 'key' && phaseKind(run, r.t) !== 'off')
  if (rows.length === 0) return result('clients.lag', 'The load generator kept its pace', true, 'no client rows', 'n/a')
  const late = rows.filter((r) => r.lag > th.clients.loopLagMsMax).length / rows.length
  return result('clients.lag', 'The load generator kept its pace (event loop lag)', late <= th.clients.loopLagBucketsShareMax, `${fmt(late * 100)}% of buckets above ${th.clients.loopLagMsMax} ms; worst ${fmt(Math.max(...rows.map((r) => r.lag)))} ms`, `at most ${th.clients.loopLagBucketsShareMax * 100}%`)
}

function rHealth(run, th) {
  const h = run.samples.filter((s) => s.k === 'health')
  if (h.length === 0) return result('health.latency', '/health stayed quick', false, 'no health samples', 'some')
  const good = h.filter((s) => s.status === 200 && s.ok === true && !s.err)
  const failures = h.length - good.length
  const ms = good.map((s) => s.ms)
  const p99 = percentile(ms, 99), max = Math.max(...ms, 0)
  return result('health.latency', '/health stayed quick the whole run (storms included)', failures <= th.health.failuresMax && p99 <= th.health.p99MsMax && max <= th.health.maxMsMax,
    `${h.length} samples, ${failures} failed, p99 ${fmt(p99)} ms, max ${fmt(max)} ms`, `0 failed, p99 <= ${th.health.p99MsMax} ms, max <= ${th.health.maxMsMax} ms`)
}

// p95 of a kind, merged over all clients, per window of `windowSec` inside phases of `kinds` (a window must lie in one phase kind).
function windowedP95(run, th, kind, phaseKinds, from = 0) {
  const w = th.latency.windowSec
  const windows = new Map()
  for (const r of run.clientRows) {
    if (r.kind !== kind || r.t < from || !phaseKinds.includes(phaseKind(run, r.t))) continue
    const key = Math.floor(r.t / w)
    if (!windows.has(key)) windows.set(key, new Histogram())
    windows.get(key).merge(Histogram.fromJSON(r.h))
  }
  return [...windows.entries()].sort((a, b) => a[0] - b[0]).filter(([, h]) => h.total >= th.latency.minSamplesPerWindow).map(([key, h]) => ({ key, p95: h.percentile(95), n: h.total }))
}

// The second hour of retention differs from the first hour of filling; compare windows after the first deletion.
function steadyFrom(run, th) {
  const storage = run.samples.filter((s) => s.k === 'storage' && s.oldest)
  const first = storage.find((s) => s.oldest > storage[0].oldest + 60_000)
  const settle = Math.max(...run.meta.phases.filter((p) => p.name === 'warmup').map((p) => p.to), 0)
  return Math.max(settle, first ? first.t : 0)
}

function rLatencyFlat(run, th) {
  const out = []
  const from = steadyFrom(run, th)
  for (const kind of th.latency.kinds) {
    const windows = windowedP95(run, th, kind, ['load'], from)
    if (windows.length < 4) { out.push(result(`latency.flat.${kind}`, `p95 of ${kind} requests stays flat in the load phases`, true, `only ${windows.length} usable windows of ${th.latency.windowSec} s: not judged`, 'n/a', 'run longer than 40 minutes to judge flatness')); continue }
    const k = Math.min(3, Math.floor(windows.length / 2))
    const first = median(windows.slice(0, k).map((x) => x.p95)), last = median(windows.slice(-k).map((x) => x.p95))
    out.push(result(`latency.flat.${kind}`, `p95 of ${kind} requests stays flat in the load phases`, last <= first * th.latency.maxRatio + th.latency.slackMs,
      `first ${k} windows ${fmt(first)} ms, last ${k} windows ${fmt(last)} ms (${windows.length} windows)`, `last <= ${th.latency.maxRatio} x first + ${th.latency.slackMs} ms`))
  }
  return out
}

function rLatencyStorm(run, th) {
  const storms = run.meta.phases.filter((p) => p.kind === 'storm')
  if (storms.length < 2) return result('latency.storm', 'p95 of key pictures in the second storm is not worse than in the first', true, 'fewer than two storms: not judged', 'n/a')
  const p95 = (p) => { const h = new Histogram(); for (const r of run.clientRows) if (r.kind === 'key' && r.t >= p.from && r.t < p.to) h.merge(Histogram.fromJSON(r.h)); return h.total >= th.latency.minSamplesPerWindow ? h.percentile(95) : NaN }
  const first = p95(storms[0]), last = p95(storms.at(-1))
  if (Number.isNaN(first) || Number.isNaN(last)) return result('latency.storm', 'p95 of key pictures in the second storm is not worse than in the first', false, 'a storm served too few pictures to judge', `at least ${th.latency.minSamplesPerWindow}`)
  return result('latency.storm', 'p95 of key pictures in the second storm is not worse than in the first', last <= first * th.latency.maxRatio + th.latency.slackMs,
    `${fmt(first)} ms then ${fmt(last)} ms`, `second <= ${th.latency.maxRatio} x first + ${th.latency.slackMs} ms`)
}

function rBusy(run, th) {
  const h = new Histogram()
  for (const r of run.clientRows) h.merge(Histogram.fromJSON(r.hb))
  if (h.total < th.latency.busyMinSamples) return result('busy.immediate', '429 answers come at once (no queueing)', true, `${h.total} busy answers: not judged`, 'n/a')
  return result('busy.immediate', '429 answers come at once (no queueing)', h.percentile(99) <= th.latency.busyP99MsMax, `${h.total} busy answers, p99 ${fmt(h.percentile(99))} ms`, `p99 <= ${th.latency.busyP99MsMax} ms`)
}

function procSeries(run, field) { return run.samples.filter((s) => s.k === 'proc' && typeof s[field] === 'number').map((s) => ({ t: s.t, v: s[field] })) }

// Value some time after each storm ends compared with just before it began.
function afterStorm(run, series, withinSec) {
  const out = []
  for (const p of run.meta.phases.filter((x) => x.kind === 'storm')) {
    if (p.to + withinSec + 120 > run.meta.endSec) continue   // the window after this storm does not fit in the run: not judged
    const before = series.filter((s) => s.t < p.from && s.t >= p.from - 300).map((s) => s.v)
    const after = series.filter((s) => s.t >= p.to + withinSec && s.t < p.to + withinSec + 120).map((s) => s.v)
    if (before.length && after.length) out.push({ storm: p.name, before: median(before), after: median(after) })
  }
  return out
}

// The value once everything is quiet again: the median of the last `off` phase from `afterSec` into it, against the median of the first `off` phase (the
// warmup, from its second minute). Clients idle, the server has closed their connections, so what is left is the daemon's own. null when a phase is too short.
function coolDown(run, series, afterSec) {
  const offs = run.meta.phases.filter((p) => p.kind === 'off')
  const warm = offs[0], cool = offs.at(-1)
  if (!warm || !cool || warm === cool) return null
  const before = series.filter((s) => s.t >= warm.from + 60 && s.t < warm.to).map((s) => s.v)
  const after = series.filter((s) => s.t >= cool.from + afterSec && s.t < cool.to).map((s) => s.v)
  return before.length >= 3 && after.length >= 3 ? { before: median(before), after: median(after) } : null
}

function rRss(run, th) {
  const r = th.rss
  // What counts as the daemon's memory: its physical footprint on the Mac (`footprint`) and its anonymous memory on Linux (RssAnon), which the probe reports as
  // memKB. The resident size that ps and VmRSS give (rssKB) also counts pages the system can take back at any time: the allocator's emptied regions (measured
  // 260 MB of 820 MB resident on the Mac after a storm, 33 MB of them dirty) and the program's own text. Samples from a probe that does not report memKB are
  // judged on rssKB, as before.
  const procRows = run.samples.filter((s) => s.k === 'proc' && typeof s.rssKB === 'number')
  const useMem = procRows.length > 0 && procRows.filter((s) => typeof s.memKB === 'number' && s.memKB > 0).length >= procRows.length * 0.9
  const field = useMem ? 'memKB' : 'rssKB'
  const label = useMem ? 'Memory (footprint)' : 'Resident memory'
  const series = procSeries(run, field)
  if (series.length < 10) return result('rss.flat', `${label} is flat`, false, `${series.length} samples`, 'at least 10')
  const loadStart = Math.max(...run.meta.phases.filter((p) => p.name === 'warmup').map((p) => p.to), 0)
  const from = Math.max(loadStart + r.settleSec, steadyFrom(run, th))
  // A storm needs memory for its readers and gives it back within minutes (the after-storm check below judges that): the slope and the creep are taken on
  // the samples outside the storms and the minutes after them.
  const storms = run.meta.phases.filter((p) => p.kind === 'storm')
  const quiet = (t) => !storms.some((p) => t >= p.from && t < p.to + r.afterStormWithinSec)
  const late = series.filter((s) => s.t >= from && quiet(s.t))
  const span = late.length ? late.at(-1).t - late[0].t : 0
  if (late.length < 120 || span < 1200) return result('rss.flat', `${label} is flat after warm-up and returns after each storm`, true, `${late.length} quiet samples in ${fmt(span / 60, 0)} minutes after the first ${r.settleSec / 60} minutes of load: not judged`, 'n/a', 'run longer than 40 minutes to judge memory')
  const perHour = slope(late.map((s) => [s.t / 3600, s.v / 1024]))
  // Creep: the median of the last quarter of an hour of quiet samples against the first quarter of an hour.
  const firstWindow = late.filter((s) => s.t < late[0].t + 900).map((s) => s.v), lastWindow = late.filter((s) => s.t >= late.at(-1).t - 900).map((s) => s.v)
  const creep = median(lastWindow) / median(firstWindow)
  const afterStorms = afterStorm(run, series, r.afterStormWithinSec)
  const stormOk = afterStorms.every((s) => s.after <= s.before * r.afterStormRatioMax)
  const rssNote = useMem ? `; resident size (ps) median ${fmt(median(procSeries(run, 'rssKB').map((s) => s.v)) / 1024, 0)} MB, not judged` : ''
  return result('rss.flat', `${label} is flat after warm-up and returns after each storm`,
    perHour <= r.maxSlopeMBPerHour && creep <= r.maxGrowthRatio && stormOk,
    `growth ${fmt(perHour)} MB/h over ${late.length} quiet samples (${fmt(span / 60, 0)} min), last quarter hour ${fmt(creep, 2)} x the first; ${fmt(median(series.map((s) => s.v)) / 1024, 0)} MB median; after storms ${afterStorms.map((s) => `${s.storm} ${fmt(s.after / s.before, 2)}x`).join(', ') || 'n/a'}${rssNote}`,
    `growth <= ${r.maxSlopeMBPerHour} MB/h, creep <= ${r.maxGrowthRatio} x, after storm <= ${r.afterStormRatioMax} x`)
}

function rFds(run, th) {
  const r = th.fds, series = procSeries(run, 'fds')
  if (series.length < 10) return result('fds.flat', 'Open files are flat', false, `${series.length} samples`, 'at least 10')
  const values = series.map((s) => s.v), med = median(values), spread = Math.max(...values) - Math.min(...values)
  // The daemon's descriptors include one per connection of the scripted browsers (4 at rest, 22 under load), which come and go with the load and are judged by
  // connections.bounded. The spread is therefore taken over the descriptors that are not connections, when the samples say how many connections there were.
  const connections = new Map(run.samples.filter((s) => s.k === 'proc' && typeof s.established === 'number').map((s) => [s.t, s.established + (s.closeWait ?? 0)]))
  const own = series.map((s) => s.v - (connections.get(s.t) ?? 0)), ownSpread = Math.max(...own) - Math.min(...own)
  const judged = connections.size > 0 ? ownSpread : spread
  // A slope over a few minutes is noise scaled up to an hour: judged only over at least 20 minutes. It starts when the load has settled (the same 15 minutes
  // after the warm-up as the memory rule): the step from the warm-up to the load is the connections and the first readers' handles, not growth.
  const loadStart = Math.max(...run.meta.phases.filter((p) => p.name === 'warmup').map((p) => p.to), 0)
  const lastOff = run.meta.phases.filter((p) => p.kind === 'off').at(-1)
  const loadEnd = lastOff && lastOff.from > loadStart ? lastOff.from : Infinity   // the cool-down is judged on its own, below
  const steady = series.filter((s) => s.t >= loadStart + th.rss.settleSec && s.t < loadEnd)
  const judgeSlope = steady.length > 1 && steady.at(-1).t - steady[0].t >= 1200
  const perHour = judgeSlope ? slope(steady.map((s) => [s.t / 3600, s.v])) : 0
  const cool = coolDown(run, series, r.cooldownAfterSec)
  return result('fds.flat', 'Open files are flat and come back when the load stops', judged <= Math.max(r.spreadAbsMax, r.spreadShareMax * med) && Math.abs(perHour) <= r.maxSlopePerHour && (!cool || cool.after <= cool.before + r.cooldownExtraMax),
    `median ${fmt(med, 0)}, spread ${spread}${connections.size > 0 ? ` (${ownSpread} without the connections)` : ''}, slope ${judgeSlope ? `${fmt(perHour)}/h` : 'not judged (under 20 minutes after the first 15 of load)'}; cool-down ${cool ? `${fmt(cool.after, 0)} against ${fmt(cool.before, 0)} at the start` : 'not judged'}`,
    `spread without connections <= max(${r.spreadAbsMax}, ${r.spreadShareMax * 100}%), |slope| <= ${r.maxSlopePerHour}/h, cool-down <= start + ${r.cooldownExtraMax} (the read-handle cache may keep 16 files open)`)
}

function rThreads(run, th) {
  const series = procSeries(run, 'threads')
  if (series.length < 10) return result('threads.flat', 'Threads are flat', false, `${series.length} samples`, 'at least 10')
  const values = series.map((s) => s.v), spread = Math.max(...values) - Math.min(...values)
  return result('threads.flat', 'Threads are flat', spread <= th.threads.spreadMax, `${Math.min(...values)} to ${Math.max(...values)}`, `spread <= ${th.threads.spreadMax}`)
}

function rConnections(run, th) {
  const r = th.connections, est = procSeries(run, 'established'), cw = procSeries(run, 'closeWait')
  if (est.length < 10) return result('connections.bounded', 'Connections stay bounded and close when the load stops', false, `${est.length} samples`, 'at least 10')
  const cool = coolDown(run, est, r.cooldownAfterSec)
  const maxCW = Math.max(0, ...cw.map((s) => s.v)), peak = Math.max(...est.map((s) => s.v))
  return result('connections.bounded', 'Connections stay bounded and close when the load stops', peak <= r.establishedMax && maxCW <= r.closeWaitMax && (!cool || cool.after <= cool.before + r.cooldownExtraMax),
    `established max ${peak}, close-wait max ${maxCW}; cool-down ${cool ? `${fmt(cool.after, 0)} against ${fmt(cool.before, 0)} at the start` : 'not judged'}`,
    `established <= ${r.establishedMax}, close-wait <= ${r.closeWaitMax}, cool-down <= start + ${r.cooldownExtraMax}`)
}

function rRecorder(run, th) {
  const r = th.recorder, out = []
  const status = run.samples.filter((s) => s.k === 'status' && s.status === 200 && s.t >= r.graceSec)
  const ids = [...new Set(status.flatMap((s) => Object.keys(s.nvr)))]
  // When a file rolls (every 15 minutes) the recorder closes it and the status says `waiting` for about two seconds, until the next file is opened at the next
  // key picture; the footage itself is continuous (measured on 14 boundaries: -15 to +10 ms between one file's end and the next one's start). A status sample taken
  // in those seconds is not counted for or against the camera; the daemon's log says when each camera rolled (its first 8 hex digits are in the line).
  const rolls = new Map()
  for (const line of run.logLines) {
    const m = /^(\d{4}-\d\d-\d\dT[\d:.]+Z) .*\[NVR\] <([0-9A-F]{8})> Closed a recording file \(roll\)/.exec(line)
    if (m) (rolls.get(m[2]) ?? rolls.set(m[2], []).get(m[2])).push((Date.parse(m[1]) - run.meta.t0Ms) / 1000)
  }
  const afterRoll = (id, t) => (rolls.get(id.slice(0, 8).toUpperCase()) ?? []).some((rolled) => t - rolled >= -0.5 && t - rolled <= r.rollWaitSec)
  let excused = 0
  const perCamera = ids.map((id) => {
    const rows = status.filter((s) => s.nvr[id]).map((s) => ({ ...s.nvr[id], t: s.t }))
    const counted = rows.filter((x) => { const skip = x.state === 'waiting' && afterRoll(id, x.t); if (skip) excused++; return !skip })
    return { id, share: counted.filter((x) => x.state === 'recording').length / Math.max(1, counted.length), paused: rows.filter((x) => x.state === 'paused').length, rows: rows.length }
  })
  const worst = perCamera.length ? Math.min(...perCamera.map((c) => c.share)) : 0
  out.push(result('recorder.recording', 'Every recorder stayed in the recording state (never paused)', perCamera.length === run.meta.cameras && worst >= r.recordingShareMin && perCamera.every((c) => c.paused === 0),
    `${perCamera.length} of ${run.meta.cameras} cameras seen; worst share ${fmt(worst * 100, 2)}%; paused samples ${perCamera.reduce((s, c) => s + c.paused, 0)}; ${excused} waiting samples right after a file roll not counted`, `all cameras, >= ${r.recordingShareMin * 100}%, no paused`))

  const catalog = run.samples.filter((s) => s.k === 'catalog' && s.status === 200 && s.t >= r.graceSec)
  let stall = 0, last = null, since = 0
  for (const s of catalog) { if (s.version !== last) { last = s.version; since = s.t } else stall = Math.max(stall, s.t - since) }
  out.push(result('recorder.catalog', 'The catalog version kept advancing', catalog.length > 0 && stall <= r.catalogStallSecMax, `longest stall ${fmt(stall)} s over ${catalog.length} samples`, `<= ${r.catalogStallSecMax} s`))

  const lags = (pred) => catalog.filter((s) => pred(s.t)).flatMap((s) => Object.values(s.cams).map((c) => c.lag / 1000))
  const all = lags(() => true), base = lags((t) => phaseKind(run, t) === 'off'), storm = lags((t) => phaseKind(run, t) === 'storm')
  const p99 = percentile(all, 99)
  const stormExtra = storm.length && base.length ? percentile(storm, 95) - percentile(base, 95) : 0
  out.push(result('recorder.edgeLag', 'Recorder edge lag stays small and is not made worse by the storms', all.length > 0 && p99 <= r.edgeLagP99SecMax && stormExtra <= r.edgeLagStormExtraSecMax,
    `p99 ${fmt(p99, 2)} s, storm p95 minus baseline p95 ${fmt(stormExtra, 2)} s`, `p99 <= ${r.edgeLagP99SecMax} s, storm extra <= ${r.edgeLagStormExtraSecMax} s`))
  return out
}

function rStorage(run, th) {
  const rows = run.samples.filter((s) => s.k === 'storage' && s.status === 200 && s.total > 0)   // zeros are "not measured yet"
  if (rows.length === 0) return [result('storage.state', 'Storage stayed healthy and inside its cap', false, 'no storage samples', 'some')]
  const out = []
  const notOk = rows.filter((s) => s.state !== 'ok')
  const lowest = Math.min(...rows.map((s) => s.free - s.floor))
  out.push(result('storage.state', 'Storage stayed ok (never paused, never near the floor)', notOk.length === 0 && lowest >= th.storage.lowSpaceMarginBytes,
    `${notOk.length} samples not ok${notOk[0] ? ` (${notOk[0].state})` : ''}; least free-above-floor ${fmt(lowest / 1e9)} GB`, `all ok, free above floor >= ${fmt(th.storage.lowSpaceMarginBytes / 1e9)} GB`))
  const overs = rows.map((s) => s.used - (s.effectiveMax + th.storage.slackBytesPerCamera * run.meta.cameras))
  out.push(result('storage.cap', 'Used bytes stayed inside the cap plus the open files', Math.max(...overs) <= 0, `most over the cap + open files: ${fmt(Math.max(...overs) / 1e9)} GB; used peak ${fmt(Math.max(...rows.map((s) => s.used)) / 1e9)} GB of ${fmt(rows[0].effectiveMax / 1e9)} GB`, 'not over'))
  const peak = Math.max(...rows.map((s) => s.used)), cap = rows[0].effectiveMax
  const reached = rows.find((s) => s.used >= cap * 0.95)
  if (reached && run.meta.endSec - reached.t < th.storage.retentionJudgedAfterSec) {
    // The oldest recording of the archive is the oldest of any camera: it moves only when retention has deleted the first file of every camera, one file at a
    // time (a pass every two minutes), so about 16 minutes after the cap for eight cameras.
    out.push(result('storage.retention', 'Retention deleted oldest files once the cap was reached', true, `the cap was reached only ${fmt((run.meta.endSec - reached.t) / 60, 0)} minutes before the end: not judged`, 'n/a', `needs ${fmt(th.storage.retentionJudgedAfterSec / 60, 0)} minutes after the cap`))
  } else if (peak >= cap * 0.95) {
    const oldestAdvanced = rows.at(-1).oldest - rows[0].oldest
    out.push(result('storage.retention', 'Retention deleted oldest files once the cap was reached', oldestAdvanced > 60_000, `oldest moved ${fmt(oldestAdvanced / 60_000, 0)} min`, 'the oldest recording moves forward'))
  } else {
    out.push(result('storage.retention', 'Retention deleted oldest files once the cap was reached', true, `the cap (${fmt(cap / 1e9)} GB) was not reached (peak ${fmt(peak / 1e9)} GB): retention was not exercised`, 'n/a', 'set a smaller cap or run longer'))
  }
  return out
}

function rWatchdog(run, th) {
  const w = th.watchdog
  if (run.meta.systemd) {   // a box: systemd itself counts the restarts; there is no notify socket to listen to
    const { restartsBefore, restartsAfter } = run.meta.systemd
    return result('watchdog.continuous', 'systemd never restarted the daemon (watchdog included)', Number.isInteger(restartsBefore) && restartsAfter === restartsBefore,
      `NRestarts ${restartsBefore} before, ${restartsAfter} after`, 'unchanged')
  }
  if (run.meta.rehearsal) return result('watchdog.continuous', 'The daemon never missed its watchdog and was never restarted', true, 'rehearsal: the stand-in server does not speak to systemd', 'n/a')
  const ready = run.notify.filter((n) => /^READY=1/.test(n.msg)).length
  const pings = run.notify.filter((n) => n.msg === 'WATCHDOG=1').map((n) => n.t)
  const end = run.meta.endSec + (run.meta.settleAfterSec ?? 0)
  let gap = 0
  const readyAt = run.notify.find((n) => /^READY=1/.test(n.msg))?.t ?? 0
  const marks = [readyAt, ...pings, Math.min(end, run.notify.at(-1)?.t ?? end)]
  for (let i = 1; i < marks.length; i++) gap = Math.max(gap, marks[i] - marks[i - 1])
  return result('watchdog.continuous', 'The daemon never missed its watchdog and was never restarted', ready === w.readyCount && gap <= w.maxGapSec && pings.length > 0,
    `${ready} READY, ${pings.length} WATCHDOG pings, longest silence ${fmt(gap)} s`, `exactly ${w.readyCount} READY, silence <= ${w.maxGapSec} s (systemd kills at 30 s)`)
}

function rLog(run, th) {
  const l = th.log
  // Start-up lines (cameras added, accessories created) should not decide a short run: at least half an hour's budget.
  const hours = Math.max(run.meta.endSec / 3600, 0.5)
  // Only what the daemon wrote while the run was observed counts towards the rate: the lines of its start and of adding the cameras (about a hundred, and more
  // where the container has no mDNS) come before the first sample and happen once, not every hour.
  const seconds = (x) => { const m = /^(\d{4}-\d\d-\d\dT[\d:.]+Z)/.exec(x); return m ? (Date.parse(m[1]) - run.meta.t0Ms) / 1000 : null }
  const observed = run.logLines.filter((x) => { const t = seconds(x); return t === null || (t >= 0 && t <= run.meta.endSec) })
  const perHour = observed.length / hours
  const limit = l.maxLinesPerHourBase + l.maxLinesPerHourPerCamera * run.meta.cameras
  const secret = new RegExp(l.secretPatterns.join('|'), 'i')
  const leaks = run.logLines.filter((x) => secret.test(x) || (run.secrets ?? []).some((v) => x.includes(v)) || /\/api\/v1\/nvr/.test(x) || (run.meta.recordingsRoot && x.includes(run.meta.recordingsRoot)))
  const linesBetween = (from, to) => run.logLines.filter((x) => { const m = /^(\d{4}-\d\d-\d\dT[\d:.]+Z)/.exec(x); if (!m) return false; const t = (Date.parse(m[1]) - run.meta.t0Ms) / 1000; return t >= from && t < to }).length
  const stormLines = (p) => linesBetween(p.from, p.to)
  const storms = run.meta.phases.filter((p) => p.kind === 'storm')
  // What a storm adds is judged against the busiest stretch of the same length outside any storm: the log also carries what the daemon does on its own clock
  // (a file closing and opening every 15 minutes on every camera, retention saying what it deleted every two minutes), and a storm may happen to contain one
  // of those. A warm-up of ten minutes holds neither, so the warm-up's rate is only the reference when the run has no quiet stretch that long.
  const quietMax = (length) => {
    let most = null
    for (const phase of run.meta.phases.filter((p) => p.kind !== 'storm')) for (let from = phase.from; from + length <= phase.to + 1e-6; from += length) most = Math.max(most ?? 0, linesBetween(from, from + length))
    return most
  }
  const base = run.meta.phases.find((p) => p.name === 'warmup')
  const baseRate = base ? stormLines(base) / (base.to - base.from) : 0
  const extra = storms.map((p) => Math.max(0, stormLines(p) - (quietMax(p.to - p.from) ?? baseRate * (p.to - p.from))))
  return result('log.budget', 'The log stayed short and said nothing it must not', perHour <= limit && leaks.length === 0 && extra.every((x) => x <= l.stormExtraLinesMax),
    `${run.logLines.length} lines (${run.logLines.length - observed.length} of them before the first sample), ${fmt(perHour, 0)} an hour; ${leaks.length} lines with a secret, a path or a request; storm extra lines ${extra.map((x) => fmt(x, 0)).join(', ') || 'n/a'} (against the busiest quiet stretch of the same length)`,
    `<= ${limit} an hour, no secret, no recordings path, no /api/v1/nvr, storm extra <= ${l.stormExtraLinesMax}`, leaks[0] ? `first: ${leaks[0].slice(0, 120)}` : '')
}

function rEvents(run, th) {
  const e = th.events
  const rows = run.samples.filter((s) => s.k === 'events' && s.counts && s.t >= e.graceSec)
  if (rows.length === 0) return result('events.quiet', 'The event stream carries few events', Boolean(run.meta.rehearsal), 'no event samples', 'some')
  const hours = rows.reduce((sum, r) => sum + r.seconds, 0) / 3600
  const total = (name) => rows.reduce((sum, r) => sum + (r.counts[name] ?? 0), 0)
  const all = total('camera') / hours / run.meta.cameras, notices = total('notices') / hours
  // The rule guards the NVR's own status (T00 B.3: `status.nvr` changes rarely). A camera event also carries the engine's other status fields (the measured
  // frame rate of the stream changes in its last decimals all the time), so when the sampler told the events apart only those in which `status.nvr` changed count;
  // samples without that information (an older sampler, a stand-in server) are judged on every camera event.
  const knowsNvr = rows.some((r) => 'cameraNvr' in r.counts)
  const camera = knowsNvr ? total('cameraNvr') / hours / run.meta.cameras : all
  const fields = {}
  for (const r of rows) for (const [name, n] of Object.entries(r.changed ?? {})) fields[name] = (fields[name] ?? 0) + n
  const top = Object.entries(fields).sort((a, b) => b[1] - a[1]).slice(0, 3).map(([name, n]) => `${name} ${n}`).join(', ')
  const others = knowsNvr ? `; camera events of any kind: ${fmt(all)} per camera per hour${top ? ` (fields that changed most: ${top})` : ''}` : ''
  return result('events.quiet', 'The event stream carries few events (the NVR status of a camera changes rarely)', camera <= e.cameraPerCameraPerHourMax && notices <= e.noticesPerHourMax,
    `${fmt(camera)} ${knowsNvr ? 'status.nvr changes' : 'camera events'} per camera per hour, ${fmt(notices)} notices per hour over ${fmt(hours * 60, 0)} minutes${others}`, `<= ${e.cameraPerCameraPerHourMax} and <= ${e.noticesPerHourMax}`)
}

function rFiles(run) {
  if (run.meta.target === 'attach') return result('files.sound', 'The recordings on disk are sound and decode', true, 'attach: the files are on the other machine (run Tools/nvr-soak/verify-files.sh there)', 'n/a')
  if (run.meta.rehearsal && !run.verify) return result('files.sound', 'The recordings on disk are sound and decode', true, 'rehearsal: not checked', 'n/a')
  if (!run.verify) return result('files.sound', 'The recordings on disk are sound and decode', false, 'verify-files.mjs did not run', 'ran')
  const v = run.verify
  return result('files.sound', 'After a clean stop every recording is closed, sound, and a sample decodes', v.problems.length === 0 && v.open === 0,
    `${v.closed} closed files, ${v.open} left open, ${v.checked} checked, ${v.decoded} decoded, ${v.problems.length} problems`, 'no problems, none left open', v.problems.slice(0, 3).join('; '))
}

function rShutdown(run) {
  const s = run.meta.shutdown
  if (!s) return result('shutdown.clean', 'A clean stop finishes quickly', Boolean(run.meta.rehearsal), 'no stop was timed', 'timed')
  return result('shutdown.clean', 'A clean stop finishes within 12 s (the unit allows 30)', s.ok && s.seconds <= 12, `${s.seconds} s${s.ok ? '' : ', it did not stop'}`, '<= 12 s')
}

export function evaluate(run, th) {
  return [rClients(run, th), rStormRate(run, th), rClientLag(run, th), rHealth(run, th), ...rLatencyFlat(run, th), rLatencyStorm(run, th), rBusy(run, th), rRss(run, th), rFds(run, th),
    rThreads(run, th), rConnections(run, th), ...rRecorder(run, th), ...rStorage(run, th), rWatchdog(run, th), rLog(run, th), rEvents(run, th), rFiles(run), rShutdown(run)]
}

export function markdown(run, rules) {
  const rows = rules.map((r) => `| ${r.pass ? 'pass' : '**FAIL**'} | ${r.id} | ${r.title} | ${r.measured.replace(/\|/g, '/')} | ${String(r.limit).replace(/\|/g, '/')} |`)
  const failed = rules.filter((r) => !r.pass)
  return [`# Soak ${run.meta.runId}: ${failed.length === 0 ? 'PASS' : `FAIL (${failed.length} rules)`}`, '',
    `Target ${run.meta.target}, ${run.meta.cameras} cameras, ${run.meta.endSec} s, seed ${run.meta.seed}, cap ${run.meta.capGB} GB.`, '',
    '| Result | Rule | What | Measured | Limit |', '|---|---|---|---|---|', ...rows, '',
    ...failed.map((r) => `- ${r.id}: ${r.note || r.measured}`)].join('\n') + '\n'
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2)
  const get = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined }
  const dir = get('--run')
  if (!dir) { console.error('usage: analyze.mjs --run RUN/out [--thresholds FILE] [--secrets FILE,FILE]'); process.exit(2) }
  const th = JSON.parse(fs.readFileSync(get('--thresholds') ?? path.join(here, 'thresholds.json'), 'utf8'))
  const run = loadRun(dir, (get('--secrets') ?? '').split(',').filter(Boolean))
  const rules = evaluate(run, th)
  fs.writeFileSync(path.join(dir, 'verdict.json'), JSON.stringify({ pass: rules.every((r) => r.pass), rules }, null, 2))
  fs.writeFileSync(path.join(dir, 'results.md'), markdown(run, rules))
  process.stdout.write(markdown(run, rules))
  process.exit(rules.every((r) => r.pass) ? 0 : 1)
}
