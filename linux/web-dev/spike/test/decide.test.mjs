import assert from 'node:assert/strict'
import { test } from 'node:test'
import { decide, parseTopCpu, recordBlock, render, selectRuns } from '../summarize.mjs'

// A finished run of one class in which everything works, with knobs to break single facts.
function run(label, knobs = {}) {
  const cls = label.replace(/-sim.*$/, '').replace(/-run\d+$/, '')
  const sim = /-sim/.test(label)
  const ok = (id, metrics = {}, checks = [{ name: 'x', ok: true, detail: '' }]) => ({ id, verdict: checks.every((c) => c.ok) ? 'pass' : 'fail', checks, metrics, notes: [] })
  const drag = (correctPct, p95) => ({ plain: { steps: 24, correctPct, totalP50: p95 / 2, totalP95: p95, picturesPerSecond: 1000 / (p95 / 2) }, 'abort+offset+init': { steps: 24, correctPct, totalP50: p95 / 2, totalP95: p95 } })
  const tiles = (passing) => Object.fromEntries([1, 2, 4, 9].map((n) => [`big_n${n}`, { tiles: n, pass: passing.includes(n), visible: true, minFps: passing.includes(n) ? 20 : 9 }]))
  const cases = {
    c01: ok('c01', { correctPct: knobs.c01Pct ?? 100, drag: { cap: drag(knobs.dragPct ?? 100, knobs.dragP95 ?? 80), bar: drag(100, 30) }, presentMs: { p50: 20 } }),
    c02: ok('c02', { withinOneFramePct: 100, presentMs: { p50: 30 } }),
    c03: ok('c03', { removeUnderPlayhead: { keepsPicture: knobs.keeps ?? true } }, [{ name: 'chain extension', ok: knobs.c03 !== false, detail: '' }]),
    c04: ok('c04', { passing: knobs.passing ?? ['offset', 'abort+offset', 'offset+init', 'abort+offset+init'] }),
    c05: ok('c05', { changeTypeWorks: knobs.changeType ?? true, mimeChangeAdvice: knobs.advice ?? 'recreate', otherMime: { changeType: { ms: 30 }, recreate: { ms: 40 } } }),
    c06: ok('c06'),
    c07: ok('c07'),
    c08: ok('c08'),
    c09: ok('c09'),
    c10: knobs.mms ? ok('c10', {}, [{ name: 'sourceopen', ok: knobs.c10 !== false, detail: '' }]) : { id: 'c10', verdict: 'skip', checks: [], metrics: {}, notes: [], skipReason: 'no ManagedMediaSource' },
    c11: ok('c11', { minReliableAfterTargetMs: 'minReliable' in knobs ? knobs.minReliable : 33 }),
    c12: ok('c12', { results: tiles(knobs.tiles ?? [1, 2, 4, 9]) }),
  }
  return {
    label, finished: knobs.finished ?? true,
    env: { label, class: cls, simulatorLabel: sim, hostKind: knobs.hostKind ?? 'ip', isSecureContext: false, typeofVideoDecoder: 'undefined', userAgent: knobs.userAgent ?? 'Mozilla/5.0', mseKind: knobs.mms ? 'ManagedMediaSource' : 'MediaSource', usesManaged: Boolean(knobs.mms), requestVideoFrameCallback: true, changeType: true, linkMbps: 900, startedAt: knobs.startedAt ?? '2026-10-11T09:00:00Z' },
    visibility: { hiddenMs: 0 },
    cases,
  }
}

test('Chrome and Safari on devices with everything passing give key steps on and a GO', () => {
  const result = decide(selectRuns([run('chrome-mac'), run('safari-mac')]))
  assert.deepEqual(result.keyStep['chrome-mac'], 'on')
  assert.deepEqual(result.keyStep['safari-mac'], 'on')
  assert.equal(result.keyStep.default, 'off')
  assert.equal(result.go, true)
  assert.equal(result.floor, false)
  assert.equal(result.evidence['chrome-mac'], 'device')
  assert.equal(result.evidence['firefox-mac'], 'none')
  assert.equal(result.keyStep['firefox-mac'], 'off')
})

test('a class whose chain extension fails, or whose drag is too slow, gets the floor; the others keep key steps', () => {
  const result = decide(selectRuns([run('chrome-mac'), run('safari-mac', { c03: false })]))
  assert.equal(result.keyStep['chrome-mac'], 'on')
  assert.equal(result.keyStep['safari-mac'], 'off')
  assert.equal(result.go, true)
  assert.match(result.reasons['safari-mac'].keyStep, /chain extension/)
  const slow = decide(selectRuns([run('chrome-mac', { dragP95: 900 }), run('safari-mac', { dragPct: 80 })]))
  assert.equal(slow.keyStep['chrome-mac'], 'off')
  assert.equal(slow.keyStep['safari-mac'], 'off')
  assert.equal(slow.floor, true)
  assert.equal(slow.go, false)
})

test('simulator evidence never switches key steps on, and a device run replaces a simulator run', () => {
  const simOnly = decide(selectRuns([run('chrome-mac'), run('safari-mac'), run('iphone-safari-sim', { mms: true })]))
  assert.equal(simOnly.evidence['iphone-safari'], 'simulator')
  assert.equal(simOnly.keyStep['iphone-safari'], 'off')
  assert.equal(simOnly.iphone, 'managed-mse')
  const both = selectRuns([run('iphone-safari-sim', { mms: true }), run('iphone-safari', { mms: true })])
  assert.equal(both.find((r) => r.env.class === 'iphone-safari').env.label, 'iphone-safari')
  assert.equal(decide(selectRuns([run('chrome-mac'), run('safari-mac')])).iphone, 'cannot-play')
  assert.equal(decide(selectRuns([run('chrome-mac'), run('iphone-safari', { mms: true, c10: false })])).iphone, 'cannot-play')
})

test('unfinished runs are ignored and the latest finished run of a class wins', () => {
  const chosen = selectRuns([
    run('chrome-mac-run1', { startedAt: '2026-10-11T08:00:00Z' }),
    run('chrome-mac-run2', { startedAt: '2026-10-11T10:00:00Z' }),
    run('chrome-mac-run3', { startedAt: '2026-10-11T11:00:00Z', finished: false }),
  ])
  assert.equal(chosen.length, 1)
  assert.equal(chosen[0].env.label, 'chrome-mac-run2')
})

test('the hold canvas is needed where removing the playing range loses the picture, and by default', () => {
  const result = decide(selectRuns([run('chrome-mac'), run('safari-mac', { keeps: false })]))
  assert.equal(result.holdCanvas['chrome-mac'], false)
  assert.equal(result.holdCanvas['safari-mac'], true)
  assert.equal(result.holdCanvas['firefox-mac'], true)
  assert.equal(result.holdCanvas.default, true)
  assert.match(result.reasons['safari-mac'].holdCanvas, /loses its picture/)
  assert.match(render(selectRuns([run('safari-mac', { keeps: false })]), decide(selectRuns([run('safari-mac', { keeps: false })]))), /hold canvas, safari-mac \| true/)
})

test('a finished run that lacks cases (the CSP control, one case) is not used', () => {
  const control = { ...run('chrome-mac-cspold', { startedAt: '2026-10-11T13:00:00Z' }), cases: { x0: { id: 'x0', verdict: 'pass', checks: [], metrics: {}, notes: [] } } }
  const chosen = selectRuns([run('chrome-mac-run1', { startedAt: '2026-10-11T08:00:00Z' }), control])
  assert.equal(chosen[0].env.label, 'chrome-mac-run1')
  assert.equal(selectRuns([control]).length, 0)
})

test('a run whose tab was hidden for more than 2 s is not used', () => {
  const hidden = { ...run('chrome-mac-run2', { startedAt: '2026-10-11T12:00:00Z' }), visibility: { hiddenMs: 5000 } }
  const chosen = selectRuns([run('chrome-mac-run1', { startedAt: '2026-10-11T08:00:00Z' }), hidden])
  assert.equal(chosen[0].env.label, 'chrome-mac-run1')
  assert.equal(selectRuns([hidden]).length, 0)
})

test('the jump protocol is the simplest one that passes in every tested class, and the conservative one without Chrome and Safari evidence', () => {
  assert.equal(decide(selectRuns([run('chrome-mac'), run('safari-mac')])).jumpProtocol, 'offset')
  assert.equal(decide(selectRuns([run('chrome-mac'), run('safari-mac', { passing: ['abort+offset', 'abort+offset+init'] })])).jumpProtocol, 'abort+offset')
  assert.equal(decide(selectRuns([run('chrome-mac'), run('safari-mac', { passing: ['offset+init', 'abort+offset+init'] })])).jumpProtocol, 'offset+init')
  assert.equal(decide(selectRuns([run('chrome-mac')])).jumpProtocol, 'abort+offset+init')
  assert.equal(decide(selectRuns([run('chrome-mac'), run('safari-mac', { passing: [] })])).jumpProtocol, 'abort+offset+init')
})

test('recreate unless changeType is better and works in every tested class', () => {
  assert.equal(decide(selectRuns([run('chrome-mac'), run('safari-mac')])).mimeChange, 'recreate')
  assert.equal(decide(selectRuns([run('chrome-mac', { advice: 'changeType' }), run('safari-mac', { advice: 'changeType' })])).mimeChange, 'changeType')
  assert.equal(decide(selectRuns([run('chrome-mac', { advice: 'changeType' }), run('safari-mac', { advice: 'recreate' })])).mimeChange, 'recreate')
  assert.equal(decide(selectRuns([run('chrome-mac', { advice: 'changeType' })])).mimeChange, 'recreate')
})

test('the seek margin is 700 ms unless a browser needs more data after the target', () => {
  assert.equal(decide(selectRuns([run('chrome-mac'), run('safari-mac')])).seekMarginMs, 700)
  assert.equal(decide(selectRuns([run('chrome-mac'), run('safari-mac', { minReliable: 900 })])).seekMarginMs, 1200)
  assert.equal(decide(selectRuns([run('chrome-mac'), run('safari-mac', { minReliable: null })])).seekMarginMs, 1500)
})

test('the tile cap is the largest 8 MP count that passed on a visible, headed run; otherwise the addendum defaults', () => {
  const result = decide(selectRuns([run('chrome-mac', { tiles: [1, 2, 4] }), run('safari-mac', { tiles: [1, 2, 4, 9] }), run('ipad-safari-sim', { tiles: [1] })]))
  assert.equal(result.tileCap['chrome-mac'], 4)
  assert.equal(result.tileCap['safari-mac'], 9)
  assert.equal(result.tileCap['ipad-safari'], 4)            // simulator: speed means nothing, default stays
  assert.equal(result.tileCap['firefox-mac'], 4)
  assert.equal(result.tileCap['iphone-safari'], 2)
  const headless = decide(selectRuns([run('chrome-mac', { tiles: [1], userAgent: 'Mozilla/5.0 HeadlessChrome/155' })]))
  assert.equal(headless.tileCap['chrome-mac'], 4)
  assert.match(headless.reasons['chrome-mac'].tileCap, /headless/)
  const none = decide(selectRuns([run('chrome-mac', { tiles: [] })]))
  assert.equal(none.tileCap['chrome-mac'], 1)
})

test('overrides replace computed values and are recorded', () => {
  const result = decide(selectRuns([run('chrome-mac'), run('safari-mac', { c03: false })]), { overrides: { keyStep: { 'safari-mac': 'on' }, seekMarginMs: 1000 }, reason: 'Safari extension failure was a stale tab' })
  assert.equal(result.keyStep['safari-mac'], 'on')
  assert.equal(result.seekMarginMs, 1000)
  assert.equal(result.overrides.reason, 'Safari extension failure was a stale tab')
  assert.deepEqual(Object.keys(result.overrides.applied).sort(), ['keyStep.safari-mac', 'seekMarginMs'])
})

test('the markdown has the evidence, the case matrix and an explicit floor sentence', () => {
  const floor = render(selectRuns([run('chrome-mac', { c03: false }), run('safari-mac', { c03: false })]), decide(selectRuns([run('chrome-mac', { c03: false }), run('safari-mac', { c03: false })])))
  assert.match(floor, /FLOOR SELECTED/)
  assert.match(floor, /settle-based scrubbing/)
  assert.match(floor, /\| c01 /)
  assert.match(floor, /isSecureContext/)
  const go = render(selectRuns([run('chrome-mac'), run('safari-mac')]), decide(selectRuns([run('chrome-mac'), run('safari-mac')])))
  assert.match(go, /KEY STEPS: GO for chrome-mac, safari-mac/)
  assert.doesNotMatch(go, /FLOOR SELECTED/)
})

test('parseTopCpu sums the browser processes of the last sample', () => {
  const sample = [
    'PID    COMMAND          %CPU  MEM',
    '100    Google Chrome He 99.0  1G',
    '',
    'Processes: 1 total',
    'PID    COMMAND          %CPU  MEM',
    '425    WindowServer     47.3  1378M',
    '700    Google Chrome He 120.5 900M',
    '701    Google Chrome    12.0  400M',
    '702    com.apple.WebKit 30.2  100M',
    '703    Finder           33.4  496M',
  ].join('\n')
  assert.equal(parseTopCpu(sample), 163)
  assert.equal(parseTopCpu('nothing here'), null)
  assert.equal(parseTopCpu('PID COMMAND %CPU MEM\n1 Finder 3.0 1M'), 0)
})

test('the record block states the go/no-go, the evidence and the gaps', () => {
  const runs = selectRuns([run('chrome-mac'), run('safari-mac'), run('iphone-safari-sim', { mms: true })])
  const block = recordBlock(runs, decide(runs), new Date(2026, 9, 11, 11, 55))
  assert.match(block, /^### Decision record, 2026-10-11 11:55/)
  assert.match(block, /KEY STEPS: GO for chrome-mac, safari-mac\./)
  assert.match(block, /FLOOR \(settle-based scrubbing\) for firefox-mac, ipad-safari, iphone-safari and unknown browsers/)
  assert.match(block, /iPhone: managed-mse \(simulator evidence; a device run is still due\)/)
  assert.match(block, /Evidence gaps: firefox-mac \(none\), ipad-safari \(none\), iphone-safari \(simulator\)\./)
  const floor = selectRuns([run('chrome-mac', { c03: false })])
  assert.match(recordBlock(floor, decide(floor)), /FLOOR SELECTED/)
})
