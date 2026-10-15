// Turns results/*.json (one file per browser run, written by the spike page) into RESULTS.md (the tables) and DECISION.json (the decision
// the player tasks read). The rules are in decide(); every value comes with the reason it got.
//   node summarize.mjs [--results DIR] [--overrides FILE] [--write | --record]
// Without --write the markdown goes to stdout. With --write RESULTS.md and DECISION.json are written next to this file. --record prints the
// few lines the plan's decision record takes.
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { classOfLabel } from './lib/pure.js'

const HERE = dirname(fileURLToPath(import.meta.url))

export const CLASSES = ['chrome-mac', 'safari-mac', 'firefox-mac', 'ipad-safari', 'iphone-safari']
export const GATE = ['chrome-mac', 'safari-mac']                          // the two browsers the first test must work in
export const DEFAULT_TILES = { 'chrome-mac': 4, 'safari-mac': 4, 'firefox-mac': 4, 'ipad-safari': 4, 'iphone-safari': 2, default: 4 }   // addendum L2, L3
export const PROTOCOLS = ['offset', 'abort+offset', 'offset+init', 'abort+offset+init']              // simplest first
const CONSERVATIVE_PROTOCOL = 'abort+offset+init'
const DRAG_LIMIT_MS = 500            // p95 of one key step (fetch, append, present) on the spike server
const MIN_CORRECT_PCT = 95

// The class and the simulator mark come from the label (the page's own guess is not trusted: a label such as iphone-safari-sim2 must count as a simulator).
const classOf = (run) => classOfLabel(run.env.label).class
const tierOf = (run) => (classOfLabel(run.env.label).simulator ? 'simulator' : 'device')
const hiddenMs = (run) => Math.round(run.visibility?.hiddenMs ?? 0)
const HIDDEN_LIMIT_MS = 2000      // a run whose tab was hidden longer was throttled by the browser and says nothing
const isHeadless = (run) => /Headless/i.test(run.env.userAgent ?? '')

const CASE_IDS = Array.from({ length: 12 }, (_, i) => `c${String(i + 1).padStart(2, '0')}`)
const isComplete = (run) => run?.finished === true && CASE_IDS.every((id) => run.cases?.[id])

/** One run per class: complete runs (all twelve cases) whose tab stayed visible, a device run before a simulator run, then the latest start. */
export function selectRuns(runs) {
  const byClass = new Map()
  for (const run of runs) {
    if (!run?.env || !isComplete(run) || hiddenMs(run) > HIDDEN_LIMIT_MS) continue
    const rank = (r) => [tierOf(r) === 'device' ? 1 : 0, r.env.startedAt ?? '']
    const current = byClass.get(classOf(run))
    if (!current) { byClass.set(classOf(run), run); continue }
    const [a, b] = [rank(run), rank(current)]
    if (a[0] > b[0] || (a[0] === b[0] && a[1] > b[1])) byClass.set(classOf(run), run)
  }
  return [...byClass.values()].sort((a, b) => CLASSES.indexOf(classOf(a)) - CLASSES.indexOf(classOf(b)))
}

function bestDrag(run) {
  const drag = run.cases.c01?.metrics?.drag
  const table = drag?.cap ?? drag?.bar
  if (!table) return null
  return Object.values(table).sort((a, b) => b.correctPct - a.correctPct || a.totalP95 - b.totalP95)[0] ?? null
}

function keyStepFor(run) {
  if (!run) return { value: 'off', reason: 'no run for this browser class' }
  if (tierOf(run) === 'simulator') return { value: 'off', reason: 'simulator evidence only: speed and memory need a device (the functional cases are in the table)' }
  const c = run.cases
  const problems = []
  if (!((c.c01?.metrics?.correctPct ?? 0) >= MIN_CORRECT_PCT)) problems.push('key pictures wrong or late')
  const drag = bestDrag(run)
  if (!drag || !(drag.correctPct >= MIN_CORRECT_PCT)) problems.push('drag pictures wrong')
  else if (!(drag.totalP95 <= DRAG_LIMIT_MS)) problems.push(`a drag step is too slow (p95 ${drag.totalP95} ms, limit ${DRAG_LIMIT_MS})`)
  if (c.c03?.verdict !== 'pass') problems.push('chain extension failed')
  if (!((c.c04?.metrics?.passing?.length ?? 0) > 0)) problems.push('no jump protocol works')
  return problems.length ? { value: 'off', reason: problems.join('; ') } : { value: 'on', reason: `key pictures right, best drag step p95 ${drag.totalP95} ms` }
}

function tileCapFor(cls, run) {
  const fallback = DEFAULT_TILES[cls]
  if (!run) return { value: fallback, reason: 'no run: the addendum default' }
  if (tierOf(run) === 'simulator') return { value: fallback, reason: 'simulator: the addendum default (decode speed means nothing there)' }
  if (isHeadless(run)) return { value: fallback, reason: 'headless run: the addendum default (a headless browser does not paint)' }
  const results = run.cases.c12?.metrics?.results
  const big = results ? Object.entries(results).filter(([key]) => key.startsWith('big_')).map(([, r]) => r) : []
  if (big.length === 0) return { value: fallback, reason: 'no 8 MP measurement: the addendum default' }
  if (big.some((r) => r.visible === false)) return { value: fallback, reason: 'the tab was not visible during the measurement: the addendum default' }
  const passing = big.filter((r) => r.pass).map((r) => r.tiles)
  return passing.length
    ? { value: Math.max(...passing), reason: `8 MP tiles that held 16 fps: ${passing.join(', ')}` }
    : { value: 1, reason: 'not even one 8 MP tile held 16 fps' }
}

/** The decision. `runs` come from selectRuns(). `overrides` is { overrides: {...}, reason } from a person who looked at the evidence. */
export function decide(runs, overrides = null) {
  const byClass = Object.fromEntries(runs.map((r) => [classOf(r), r]))
  const evidence = Object.fromEntries(CLASSES.map((c) => [c, byClass[c] ? tierOf(byClass[c]) : 'none']))
  const reasons = Object.fromEntries(CLASSES.map((c) => [c, {}]))

  const keyStep = { default: 'off' }
  const tileCap = { default: DEFAULT_TILES.default }
  // Does the element keep its picture when the range under the playhead is removed? When not (WebKit), the page must draw the last picture to a
  // canvas before it removes or recreates anything. Without a measurement the answer is yes, keep the canvas.
  const holdCanvas = { default: true }
  for (const cls of CLASSES) {
    const removal = byClass[cls]?.cases.c03?.metrics?.removeUnderPlayhead
    holdCanvas[cls] = removal ? removal.keepsPicture === false : true
    reasons[cls].holdCanvas = removal ? (removal.keepsPicture ? 'the element keeps its picture after its range is removed' : 'the element loses its picture when its range is removed') : 'not measured: keep the canvas'
    const key = keyStepFor(byClass[cls])
    keyStep[cls] = key.value
    reasons[cls].keyStep = key.reason
    const tiles = tileCapFor(cls, byClass[cls])
    tileCap[cls] = tiles.value
    reasons[cls].tileCap = tiles.reason
  }

  const gateOnDevices = GATE.every((c) => evidence[c] === 'device')
  const tested = runs.filter((r) => r.cases.c04)
  const common = PROTOCOLS.filter((p) => tested.length > 0 && tested.every((r) => (r.cases.c04.metrics?.passing ?? []).includes(p)))
  const jumpProtocol = gateOnDevices && common.length ? common[0] : CONSERVATIVE_PROTOCOL

  const mimeTested = runs.filter((r) => r.cases.c05)
  const mimeChange = gateOnDevices && mimeTested.length > 0 && mimeTested.every((r) => r.cases.c05.metrics?.mimeChangeAdvice === 'changeType') ? 'changeType' : 'recreate'

  let seekMarginMs = 700
  for (const run of runs) {
    const c11 = run.cases.c11
    if (!c11 || c11.verdict === 'skip') continue
    const minimal = c11.metrics?.minReliableAfterTargetMs
    seekMarginMs = Math.max(seekMarginMs, minimal === null || minimal === undefined ? 1500 : minimal + 300)
  }

  const phone = byClass['iphone-safari']
  const phoneWorks = Boolean(phone) && (phone.cases.c01?.metrics?.correctPct ?? 0) >= MIN_CORRECT_PCT && phone.cases.c10?.verdict === 'pass'
  const iphone = phoneWorks ? 'managed-mse' : 'cannot-play'
  reasons['iphone-safari'].iphone = !phone ? 'no run' : phoneWorks ? `ManagedMediaSource plays (${evidence['iphone-safari']} evidence)` : 'key pictures or ManagedMediaSource failed'

  const decision = {
    version: 1,
    decidedAt: new Date().toISOString(),
    go: false,
    floor: true,
    floorFor: [],
    evidence,
    keyStep,
    iphone,
    tileCap,
    holdCanvas,
    mimeChange,
    jumpProtocol,
    seekMarginMs,
    reasons,
  }

  if (overrides?.overrides) {
    const applied = {}
    for (const [key, value] of Object.entries(overrides.overrides)) {
      if (value !== null && typeof value === 'object') {
        for (const [inner, innerValue] of Object.entries(value)) { decision[key][inner] = innerValue; applied[`${key}.${inner}`] = innerValue }
      } else {
        decision[key] = value
        applied[key] = value
      }
    }
    decision.overrides = { reason: overrides.reason ?? '', applied }
  }
  const on = CLASSES.filter((c) => decision.keyStep[c] === 'on')
  decision.go = on.length > 0
  decision.floor = on.length === 0
  decision.floorFor = CLASSES.filter((c) => decision.keyStep[c] !== 'on')
  return decision
}

const SYMBOL = { pass: 'pass', fail: 'FAIL', skip: 'skip', info: 'info' }

function matrixCell(run, caseId) {
  if (!run) return '-'
  const result = run.cases[caseId]
  if (!result) return 'not run'
  return `${SYMBOL[result.verdict] ?? result.verdict}${tierOf(run) === 'simulator' ? ' (sim)' : ''}`
}

const row = (cells) => `| ${cells.join(' | ')} |`
const num = (x, unit = '') => (x === null || x === undefined ? '-' : `${x}${unit}`)

/** RESULTS.md. */
export function render(runs, decision, generatedAt = new Date().toISOString(), cpu = {}, partial = [], controls = []) {
  const byClass = Object.fromEntries(runs.map((r) => [classOf(r), r]))
  const lines = []
  lines.push('# Spike S1 results: MSE playback of recorded fragments over plain HTTP', '')
  lines.push(`Generated ${generatedAt} by summarize.mjs from ${runs.length} run(s): ${runs.map((r) => r.env.label).join(', ') || 'none'}.`, '')

  lines.push('## Decision', '')
  const on = CLASSES.filter((c) => decision.keyStep[c] === 'on')
  if (decision.floor) {
    lines.push('**FLOOR SELECTED: settle-based scrubbing.** The playhead moves at full speed while the pointer moves, no picture is fetched during the drag, and the exact picture arrives 0.3 to 0.5 s after the pointer stops, then plays. Key steps are off in every browser class.', '')
  } else {
    lines.push(`**KEY STEPS: GO for ${on.join(', ')}.** The floor (settle-based scrubbing) applies to: ${decision.floorFor.join(', ')}, and to any browser not in this list.`, '')
  }
  lines.push(row(['Decision', 'Value', 'Why']), row(['---', '---', '---']))
  for (const cls of CLASSES) lines.push(row([`key step, ${cls}`, decision.keyStep[cls], `${decision.evidence[cls]} evidence; ${decision.reasons[cls].keyStep}`]))
  lines.push(row(['key step, other browsers', decision.keyStep.default, 'unknown browsers get the floor']))
  lines.push(row(['iPhone', decision.iphone, decision.reasons['iphone-safari'].iphone]))
  for (const cls of CLASSES) lines.push(row([`tile cap, ${cls}`, decision.tileCap[cls], decision.reasons[cls].tileCap]))
  for (const cls of CLASSES) lines.push(row([`hold canvas, ${cls}`, decision.holdCanvas[cls], decision.reasons[cls].holdCanvas]))
  lines.push(row(['MIME change', decision.mimeChange, 'recreate the MediaSource unless changeType is faster and works in every tested class (Chrome and Safari on devices)']))
  lines.push(row(['jump protocol', decision.jumpProtocol, 'how a chain starts far from held data: the simplest of offset, abort+offset, offset+init, abort+offset+init that passes in every tested class']))
  lines.push(row(['seek margin', `${decision.seekMarginMs} ms`, 'data that must lie after the target before a seek into held data is allowed']))
  if (decision.overrides) lines.push('', `Overrides by the person who ran the spike: ${JSON.stringify(decision.overrides.applied)}. Reason: ${decision.overrides.reason}`)
  lines.push('')

  lines.push('## This browser', '')
  lines.push(row(['', ...CLASSES]), row(['---', ...CLASSES.map(() => '---')]))
  const env = (label, pick) => lines.push(row([label, ...CLASSES.map((c) => (byClass[c] ? pick(byClass[c]) : '-'))]))
  env('run', (r) => r.env.label)
  env('evidence', (r) => tierOf(r) + (isHeadless(r) ? ' (headless)' : ''))
  env('origin kind', (r) => r.env.hostKind)
  env('isSecureContext', (r) => String(r.env.isSecureContext))
  env('typeof VideoDecoder', (r) => r.env.typeofVideoDecoder)
  env('MSE used', (r) => (r.env.usesManaged ? 'ManagedMediaSource' : r.env.mseKind))
  env('requestVideoFrameCallback', (r) => String(r.env.requestVideoFrameCallback))
  env('changeType', (r) => String(r.env.changeType))
  env('link to the server (Mbit/s)', (r) => num(r.env.linkMbps))
  env('tab hidden during the run (ms)', (r) => num(Math.round(r.visibility?.hiddenMs ?? 0)))
  lines.push('')

  lines.push('## The twelve cases', '')
  lines.push(row(['case', ...CLASSES]), row(['---', ...CLASSES.map(() => '---')]))
  const ids = [...new Set(runs.flatMap((r) => Object.keys(r.cases)))].sort()
  for (const id of ids) lines.push(row([id, ...CLASSES.map((c) => matrixCell(byClass[c], id))]))
  lines.push('')

  lines.push('## Numbers', '')
  lines.push(row(['', ...CLASSES]), row(['---', ...CLASSES.map(() => '---')]))
  const metric = (label, pick) => lines.push(row([label, ...CLASSES.map((c) => { try { return byClass[c] ? num(pick(byClass[c])) : '-' } catch { return '-' } })]))
  metric('c01 key picture, median (ms)', (r) => r.cases.c01.metrics.presentMs.p50)
  metric('c01 drag, key steps per second (best variant)', (r) => { const d = bestDrag(r); return d ? Math.round((1000 / d.totalP50) * 10) / 10 : null })
  metric('c01 drag, one step p95 (ms)', (r) => bestDrag(r)?.totalP95)
  metric('c01 stored form with prft accepted', (r) => r.cases.c01.metrics.storedFormWithPrft?.accepted)
  metric('c02 exact frame, median (ms)', (r) => r.cases.c02.metrics.presentMs.p50)
  metric('c02 within one frame (%)', (r) => r.cases.c02.metrics.withinOneFramePct)
  metric('c04 jump protocols that work', (r) => (r.cases.c04.metrics.passing ?? []).join(', ') || 'none')
  metric('c05 changeType works', (r) => r.cases.c05.metrics.changeTypeWorks)
  metric('c05 advice', (r) => r.cases.c05.metrics.mimeChangeAdvice)
  metric('c03 picture kept when its range is removed', (r) => r.cases.c03.metrics.removeUnderPlayhead?.keepsPicture)
  metric('c03 appended before a quota error (MB)', (r) => (r.cases.c03.metrics.memory ? Math.round((r.cases.c03.metrics.memory.quota?.afterBytes ?? r.cases.c03.metrics.memory.appendedBytes) / 1e6) + (r.cases.c03.metrics.memory.quota ? '' : '+') : null))
  metric('c06 a keyframe before time 0 loses its GOP', (r) => r.cases.c06.metrics.negative?.['-0.001']?.gop0Shown === false)
  metric('c07 smallest gap that stalls (ms)', (r) => r.cases.c07.metrics.smallestGapThatStallsMs)
  metric('c08 muxed sound on a video-only buffer', (r) => (r.cases.c08.metrics.muxedOnVideoOnly?.initAccepted === false ? 'init rejected' : 'accepted'))
  metric('c08 sound dropout stalls a muxed buffer', (r) => r.cases.c08.metrics.soundDropout?.stalledAtHole)
  metric('c10 startstreaming / endstreaming / bufferedchange seen', (r) => (r.cases.c10.verdict === 'skip' ? 'n/a' : [r.cases.c10.metrics.seenStartStreaming, r.cases.c10.metrics.seenEndStreaming, r.cases.c10.metrics.seenBufferedChange].join(' / ')))
  metric('c11 least data after the target that always worked (ms)', (r) => r.cases.c11.metrics.minReliableAfterTargetMs)
  metric('c12 8 MP tiles at 16 fps (4256x1888)', (r) => Object.entries(r.cases.c12.metrics.results ?? {}).filter(([key, x]) => key.startsWith('big_') && x.pass && x.visible !== false).map(([, x]) => x.tiles).join(', ') || 'none')
  metric('c12 8 MP, 4 MP tiles: lowest fps (big 1/4/9, cap 4/9)', (r) => ['big_n1', 'big_n4', 'big_n9', 'cap_n4', 'cap_n9'].map((k) => r.cases.c12.metrics.results?.[k]?.minFps ?? '-').join(' / '))
  metric('c12 browser CPU % while playing, big 1 / 4 / 9 tiles (Mac only)', (r) => ['big-n1', 'big-n4', 'big-n9'].map((p) => cpu[r.env.label]?.[p] ?? '-').join(' / '))
  lines.push('')

  const failures = []
  for (const run of runs) {
    for (const [id, result] of Object.entries(run.cases)) {
      if (result.verdict !== 'fail') continue
      if (result.error) failures.push(`- ${run.env.label} ${id}: ${result.error}`)
      for (const check of result.checks.filter((c) => !c.ok)) failures.push(`- ${run.env.label} ${id}: ${check.name} (${String(check.detail).slice(0, 200)})`)
    }
  }
  lines.push('## Failed checks', '', ...(failures.length ? failures : ['None.']), '')
  if (controls.length) {
    lines.push('## Control: the CSP the daemon sends today', '')
    for (const run of controls) lines.push(`- ${run.env.label}: x0 ${run.cases.x0.verdict} (${run.cases.x0.checks.map((c) => c.detail).join('; ')}); violations ${JSON.stringify(run.cases.x0.metrics?.violations ?? [])}`)
    lines.push('')
  }
  if (partial.length) {
    lines.push('## Runs not used for the decision', '')
    for (const run of partial) {
      const drag = bestDrag(run)
      const why = isComplete(run) ? `tab hidden for ${hiddenMs(run)} ms` : 'not all twelve cases (a single case, ?only=, the CSP control, or stopped early)'
      lines.push(`- ${run.env.label} (${why}): cases ${Object.keys(run.cases).join(', ')}; link ${num(run.env.linkMbps)} Mbit/s${drag ? `; best drag step p50 ${drag.totalP50} ms, p95 ${drag.totalP95} ms` : ''}`)
    }
    lines.push('')
  }
  return lines.join('\n')
}

/** Sum of %CPU of the browser's processes in the last sample of a `top` capture (one core is 100). Command names are cut to 16 characters by top. */
export function parseTopCpu(text) {
  const header = text.lastIndexOf('PID')
  if (header < 0) return null
  let sum = 0
  let found = false
  for (const line of text.slice(header).split('\n').slice(1)) {
    const match = line.match(/^\s*\d+\s+(.+?)\s+(\d+(?:\.\d+)?)\s+\S+\s*$/)
    if (match && /Chrome|Safari|WebKit|Firefox|firefox|Microsoft Edge/.test(match[1])) { sum += Number(match[2]); found = true }
  }
  return found ? Math.round(sum) : 0
}

/** { phase: cpu } for one run label, from results/<label>-cpu-<phase>.txt (written by the server's --sample-cpu on a Mac). */
export function loadCpu(dir, label) {
  if (!existsSync(dir)) return {}
  const out = {}
  for (const file of readdirSync(dir)) {
    const match = file.match(new RegExp(`^${label.replace(/[^a-z0-9-]/g, '')}-cpu-([a-z0-9-]+)\\.txt$`))
    if (match) out[match[1]] = parseTopCpu(readFileSync(join(dir, file), 'utf8'))
  }
  return out
}

/** The block step 12 pastes at the end of the T06 plan: the go/no-go in a few lines, with what is still missing. */
export function recordBlock(runs, decision, when = new Date()) {
  const stamp = `${when.getFullYear()}-${String(when.getMonth() + 1).padStart(2, '0')}-${String(when.getDate()).padStart(2, '0')} ${String(when.getHours()).padStart(2, '0')}:${String(when.getMinutes()).padStart(2, '0')}`
  const on = CLASSES.filter((c) => decision.keyStep[c] === 'on')
  const lines = [`### Decision record, ${stamp}`, '']
  lines.push(`Evidence: ${CLASSES.map((c) => `${c} ${decision.evidence[c]}${decision.evidence[c] === 'none' ? '' : ` (${runs.find((r) => classOf(r) === c).env.label})`}`).join('; ')}.`)
  lines.push(decision.floor
    ? 'FLOOR SELECTED: settle-based scrubbing in every browser class (key steps are off everywhere).'
    : `KEY STEPS: GO for ${on.join(', ')}. FLOOR (settle-based scrubbing) for ${decision.floorFor.join(', ')} and unknown browsers.`)
  lines.push(`iPhone: ${decision.iphone}${decision.evidence['iphone-safari'] === 'simulator' ? ' (simulator evidence; a device run is still due)' : decision.evidence['iphone-safari'] === 'none' ? ' (no run)' : ''}.`)
  lines.push(`Tile cap: ${CLASSES.map((c) => `${c} ${decision.tileCap[c]}`).join(', ')}.`)
  lines.push(`Hold canvas needed (the picture is lost when its range is removed): ${CLASSES.filter((c) => decision.holdCanvas[c]).join(', ') || 'none'}.`)
  lines.push(`MIME change: ${decision.mimeChange}. Jump protocol: ${decision.jumpProtocol}. Seek margin: ${decision.seekMarginMs} ms.`)
  const gaps = CLASSES.filter((c) => decision.evidence[c] !== 'device')
  lines.push(gaps.length ? `Evidence gaps: ${gaps.map((c) => `${c} (${decision.evidence[c]})`).join(', ')}.` : 'Evidence gaps: none.')
  if (decision.overrides) lines.push(`Overrides: ${JSON.stringify(decision.overrides.applied)} because ${decision.overrides.reason}.`)
  lines.push('Files: linux/web-dev/spike/RESULTS.md and DECISION.json.', '')
  return lines.join('\n')
}

export function loadRuns(dir) {
  if (!existsSync(dir)) return []
  return readdirSync(dir).filter((f) => f.endsWith('.json')).map((f) => {
    try { return JSON.parse(readFileSync(join(dir, f), 'utf8')) } catch { return null }
  }).filter((r) => r && r.env && r.cases)
}

function main(argv) {
  let dir = join(HERE, 'results')
  let overridesFile = null
  let write = false
  let record = false
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--results') dir = argv[++i]
    else if (argv[i] === '--overrides') overridesFile = argv[++i]
    else if (argv[i] === '--write') write = true
    else if (argv[i] === '--record') record = true
    else { console.error(`unknown option ${argv[i]}`); process.exit(2) }
  }
  const all = loadRuns(dir)
  const runs = selectRuns(all)
  if (runs.length === 0) { console.error(`no finished runs in ${dir} (${all.length} files read)`); process.exit(1) }
  const decision = decide(runs, overridesFile ? JSON.parse(readFileSync(overridesFile, 'utf8')) : null)
  if (record) { console.log(recordBlock(runs, decision)); return }
  const cpu = Object.fromEntries(runs.map((r) => [r.env.label, loadCpu(dir, r.env.label)]))
  const controls = all.filter((r) => r.cases.x0)
  const partial = all.filter((r) => !r.cases.x0 && (!isComplete(r) || hiddenMs(r) > HIDDEN_LIMIT_MS) && Object.keys(r.cases).length > 0)
  const markdown = render(runs, decision, new Date().toISOString(), cpu, partial, controls)
  if (write) {
    writeFileSync(join(HERE, 'RESULTS.md'), `${markdown}\n`)
    writeFileSync(join(HERE, 'DECISION.json'), `${JSON.stringify(decision, null, 2)}\n`)
    console.log(`wrote RESULTS.md and DECISION.json from ${runs.map((r) => r.env.label).join(', ')}`)
  } else {
    console.log(markdown)
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main(process.argv.slice(2))
