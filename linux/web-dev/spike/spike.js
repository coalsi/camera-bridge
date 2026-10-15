import { CASES } from './cases/index.js'
import { h, sleep, withTimeout } from './lib/dom.js'
import { collectEnvironment } from './lib/env.js'
import { fixtureIds, loadFixture } from './lib/fixtures.js'
import { makeReadCanvas } from './lib/present.js'
import { Report } from './lib/report.js'
import { setTrace } from './lib/surface.js'

const BUILD = 'spike-1'
const CASE_TIMEOUT_MS = 240000
const params = new URLSearchParams(location.search)
const $ = (id) => document.getElementById(id)

const violations = []
const pageErrors = []
document.addEventListener('securitypolicyviolation', (event) => violations.push({ directive: event.violatedDirective, blocked: String(event.blockedURI).slice(0, 80) }))
window.addEventListener('error', (event) => pageErrors.push(`${event.message} (${String(event.filename).split('/').pop()}:${event.lineno})`))
window.addEventListener('unhandledrejection', (event) => pageErrors.push(`unhandled rejection: ${event.reason?.message ?? event.reason}`))

// A hidden tab is throttled by every browser (no frame callbacks, slow timers): results taken while it was hidden are wrong, so they are flagged.
const visibility = { hiddenMs: 0, changes: 0, hiddenSince: document.visibilityState === 'hidden' ? performance.now() : null }
document.addEventListener('visibilitychange', () => {
  visibility.changes++
  if (document.visibilityState === 'hidden') visibility.hiddenSince = performance.now()
  else if (visibility.hiddenSince !== null) { visibility.hiddenMs += performance.now() - visibility.hiddenSince; visibility.hiddenSince = null }
})
const hiddenTotal = () => visibility.hiddenMs + (visibility.hiddenSince === null ? 0 : performance.now() - visibility.hiddenSince)

const tracked = []
const logLines = []
function log(message) {
  const line = `${((performance.now() - started) / 1000).toFixed(1).padStart(6)}  ${message}`
  logLines.push(line)
  if (logLines.length > 400) logLines.shift()
  $('log').textContent = logLines.join('\n')
  $('log').scrollTop = $('log').scrollHeight
}
const started = performance.now()
setTrace((message) => log(`  ${message}`))

const context = {
  video: $('stage'),
  tiles: $('tiles'),
  canvas: makeReadCanvas(),
  params,
  violations,
  // ManagedMediaSource is what an iPhone has instead of MediaSource; ?managed=1 forces it where both exist.
  managed: params.get('managed') === '1' || (!globalThis.MediaSource && Boolean(globalThis.ManagedMediaSource)),
  attach: params.get('attach') ?? 'src',
  label: null,
  env: null,
  running: false,
  log,
  track(surface) { tracked.push(surface); return surface },
  fixture: loadFixture,
  mark: (phase) => fetch(`/mark/${context.label}/${phase}`, { method: 'POST' }).catch(() => null),
}

const results = { version: 1, build: BUILD, label: null, env: null, fixtures: {}, cases: {}, pageErrors, visibility, log: logLines, current: null, finished: false, startedAt: new Date().toISOString(), updatedAt: null }

function safeLabel(label) {
  const clean = label.toLowerCase().replace(/[^a-z0-9-]/g, '-').replace(/^-+/, '').slice(0, 40)
  return clean || 'unknown'
}

async function send() {
  results.updatedAt = new Date().toISOString()
  try {
    const response = await fetch(`/results/${context.label}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(results) })
    $('status').textContent = response.ok ? `results sent (${context.label})` : `sending failed: HTTP ${response.status}`
    return response.ok
  } catch (error) {
    $('status').textContent = `sending failed: ${error.message}`
    return false
  }
}

function renderEnvironment(env) {
  const rows = [
    ['visibility now', document.visibilityState, document.visibilityState !== 'visible'],
    ['label / class', `${env.label} / ${env.class}${env.simulatorLabel ? ' (simulator)' : ''}`],
    ['origin', `${env.origin} (${env.hostKind})`],
    ['isSecureContext', String(env.isSecureContext), env.isSecureContext && env.hostKind !== 'loopback'],
    ['typeof VideoDecoder', env.typeofVideoDecoder],
    ['MSE here', `${env.mseKind} (MediaSource ${env.typeofMediaSource}, ManagedMediaSource ${env.typeofManagedMediaSource})`],
    ['requestVideoFrameCallback', String(env.requestVideoFrameCallback)],
    ['changeType', String(env.changeType)],
    ['link to the server', env.linkMbps === null ? 'unknown' : `${env.linkMbps} Mbit/s`],
    ['user agent', env.userAgent],
    ['screen / cores / memory', `${env.screen} / ${env.hardwareConcurrency} / ${env.deviceMemory ?? 'n/a'}`],
  ]
  const table = $('env')
  table.replaceChildren(...rows.map(([name, value, bad]) => h('tr', {}, h('th', {}, name), h('td', { class: bad ? 'bad' : '' }, value))))
  if (env.hostKind === 'loopback') {
    table.append(h('tr', {}, h('th', {}, 'warning'), h('td', { class: 'bad' }, 'Loopback is a secure context: WebCodecs exist here but not on the box. Open the page by the LAN name for the real test.')))
  }
}

const badges = new Map()
const details = new Map()

function renderCases() {
  const list = $('cases')
  list.replaceChildren()
  for (const c of CASES) {
    const badge = h('span', { class: 'badge' }, 'idle')
    const pre = h('pre', {}, '')
    badges.set(c.id, badge)
    details.set(c.id, pre)
    list.append(h('li', {},
      h('div', { class: 'row' }, h('span', {}, c.id), h('span', { class: 'title' }, c.title), badge, h('button', { type: 'button', onclick: () => runSelected([c.id]) }, 'Run')),
      h('details', {}, h('summary', {}, 'result'), pre)))
  }
}

function show(c, json) {
  const badge = badges.get(c.id)
  badge.className = `badge ${json.verdict}`
  badge.textContent = json.verdict
  details.get(c.id).textContent = JSON.stringify(json, null, 1)
}

async function runCase(c) {
  const badge = badges.get(c.id)
  badge.className = 'badge running'
  badge.textContent = 'running'
  log(`${c.id} start`)
  results.current = c.id
  const report = new Report(c.id, c.title)
  violations.length = 0
  const hiddenBefore = hiddenTotal()
  const available = await fixtureIds().catch(() => [])
  const missing = (c.needs ?? []).filter((id) => !available.includes(id))
  if (missing.length) {
    report.skip(`missing fixtures: ${missing.join(', ')} (run make-fixtures.sh)`)
  } else {
    try {
      await withTimeout(c.run(context, report), CASE_TIMEOUT_MS, c.id)
    } catch (error) {
      report.error = `${error.name}: ${error.message}`
      log(`${c.id} error: ${report.error}`)
    }
  }
  while (tracked.length) { try { tracked.pop().destroy() } catch { /* already gone */ } }
  const hiddenDuring = Math.round(hiddenTotal() - hiddenBefore)
  if (!report.skipReason) report.check('the tab stayed visible while the case ran (a hidden tab is throttled and gives wrong results)', hiddenDuring < 500, `hidden for ${hiddenDuring} ms`)
  const json = report.toJSON()
  results.cases[c.id] = json
  for (const id of c.needs ?? []) {
    if (available.includes(id)) {
      const fx = await loadFixture(id)
      results.fixtures[id] = { source: fx.source, mime: fx.mime, width: fx.width, height: fx.height, parts: fx.parts.length, frames: fx.frames.length }
    }
  }
  show(c, json)
  log(`${c.id} ${json.verdict} in ${json.ms} ms`)
  await send()
  await sleep(200)
}

async function runSelected(ids) {
  if (context.running) return
  context.running = true
  $('run-all').disabled = true
  const only = params.get('only')?.split(',')
  const selected = CASES.filter((c) => ids.includes(c.id) && (!only || only.includes(c.id)))
  $('status').textContent = 'running...'
  const heartbeat = setInterval(send, 4000)      // the log reaches the server while a case runs, so a stuck case can be seen from outside
  for (const c of selected) await runCase(c)
  results.finished = selected.length === CASES.length      // a run restricted with ?only= or one case is never "finished"
  results.current = null
  clearInterval(heartbeat)
  await send()
  $('status').textContent = results.finished ? `finished (${context.label})` : `done (${context.label})`
  $('run-all').disabled = false
  context.running = false
  log('done')
}

function download() {
  const link = $('download')
  if (link.href.startsWith('blob:')) URL.revokeObjectURL(link.href)
  link.href = URL.createObjectURL(new Blob([JSON.stringify(results, null, 1)], { type: 'application/json' }))
  link.download = `${context.label}.json`
}

async function main() {
  $('build').textContent = BUILD
  context.env = await collectEnvironment(params)
  context.label = safeLabel(context.env.label)
  results.label = context.label
  results.env = context.env
  renderEnvironment(context.env)
  renderCases()
  $('run-all').addEventListener('click', () => runSelected(CASES.map((c) => c.id)))
  $('send').addEventListener('click', send)
  $('download').addEventListener('click', download)
  log(`ready: ${context.env.class}, secure=${context.env.isSecureContext}, VideoDecoder=${context.env.typeofVideoDecoder}`)
  if (params.get('auto') === '1') runSelected(CASES.map((c) => c.id))
}

main().catch((error) => { $('status').textContent = `startup failed: ${error.message}`; log(`startup failed: ${error.stack ?? error}`) })
