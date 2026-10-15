import { mulberry32 } from '../lib/pure.js'
import { openFixture, pct, round1, seekTo } from './common.js'

const OFFSET = 1000.25          // an ordinary positive offset on the video timeline (case 6 does the huge and the negative ones)
const DRAG_STEPS = 24

/** Key-step drag: one picture per step. Each step evicts what is held, fetches the GOP's key fragment, appends it and seeks to K.start + 1 ms. */
async function dragSimulation(ctx, fx, variant) {
  const random = mulberry32(42)
  const surface = await openFixture(ctx, fx, { offsetSec: OFFSET })
  const keys = fx.keyParts()
  const rows = []
  let previous = -1
  for (let step = 0; step < DRAG_STEPS; step++) {
    let k
    do { k = keys[Math.floor(random() * keys.length)] } while (k === previous && keys.length > 1)
    previous = k
    const t0 = performance.now()
    await surface.remove(0, Infinity)
    const { data, ms: fetchMs } = await fx.fetchPart(k)
    const fetched = performance.now()
    if (variant.abort) surface.abortParser()
    surface.setOffset(OFFSET)
    if (variant.init) await surface.append(await fx.init())
    await surface.append(data)
    const appended = performance.now()
    const r = await seekTo(ctx, fx, OFFSET, fx.startSec(k) + 0.001)
    rows.push({ ok: r.ok, fetchMs, appendMs: appended - fetched, presentMs: r.ms, totalMs: performance.now() - t0 })
  }
  surface.destroy()
  const ok = rows.filter((r) => r.ok)
  return { steps: rows.length, correctPct: pct(ok.length, rows.length), rows }
}

export default {
  id: 'c01',
  title: 'init + K, seek to K.start + 1 ms: the key picture and its time',
  needs: ['bar', 'ntsc', 'cap'],
  async run(ctx, report) {
    const trials = []
    const ids = ['bar', 'ntsc', 'cap']
    // Pass B of the plan: out/capm is a recorder-layout file (FMP4Muxer, T03's fixture of the capture), when someone has put it there.
    if (await ctx.fixture('capm').catch(() => null)) ids.push('capm')
    for (const id of ids) {
      const fx = await ctx.fixture(id)
      for (const k of fx.keyParts()) {
        const surface = await openFixture(ctx, fx, { offsetSec: OFFSET })
        await surface.append(await fx.part(k))
        const r = await seekTo(ctx, fx, OFFSET, fx.startSec(k) + 0.001)
        trials.push({
          fixture: id, part: k, ok: r.ok, ms: r.ms, errorFrames: r.errorFrames, notBlack: r.notBlack, readyState: ctx.video.readyState,
          sizeOk: ctx.video.videoWidth === fx.width && ctx.video.videoHeight === fx.height, firstSeen: r.history[0] ?? null,
        })
        surface.destroy()
      }
    }
    const okTrials = trials.filter((t) => t.ok)
    report.metric('trials', trials.length)
    report.metric('correctPct', pct(okTrials.length, trials.length))
    report.stats('presentMs', okTrials.map((t) => t.ms))
    report.metric('presentMsByFixture', Object.fromEntries(ids.map((id) => {
      const list = okTrials.filter((t) => t.fixture === id).map((t) => t.ms)
      return [id, list.length ? round1(list.reduce((a, b) => a + b, 0) / list.length) : null]
    })))
    report.metric('failures', trials.filter((t) => !t.ok).slice(0, 6))
    report.check('every key picture is the right frame, presented within 1.5 s (at least 95%)', pct(okTrials.length, trials.length) >= 95,
      `${okTrials.length} of ${trials.length}`)
    report.check('the element reports the fixture size', trials.every((t) => t.sizeOk), 'videoWidth x videoHeight')
    report.check('the picture is not black', okTrials.every((t) => t.notBlack !== false), '')
    report.check('the content security policy blocked nothing', ctx.violations.length === 0, ctx.violations.map((v) => v.directive).join(','))

    // Does a browser accept the stored form (with the leading prft)? Tells T03 whether stripping it is mandatory.
    const bar = await ctx.fixture('bar')
    const stored = await bar.stored(0)
    if (stored) {
      let accepted = true
      let errorName = null
      const surface = await openFixture(ctx, bar, { offsetSec: OFFSET })
      try { await surface.append(stored) } catch (error) { accepted = false; errorName = error.name }
      const r = accepted ? await seekTo(ctx, bar, OFFSET, 0.001) : null
      report.metric('storedFormWithPrft', { accepted, errorName, presented: r ? r.ok : false })
      surface.destroy()
    }

    // The drag: how fast can one picture per step be made on this browser (bytes come from the spike server, so this is the browser's share).
    const drag = {}
    for (const id of ['cap', 'bar']) {
      const fx = await ctx.fixture(id)
      drag[id] = {}
      for (const [name, variant] of [['plain', { abort: false, init: false }], ['abort+offset+init', { abort: true, init: true }]]) {
        const run = await dragSimulation(ctx, fx, variant)
        const total = run.rows.filter((r) => r.ok).map((r) => r.totalMs)
        const present = run.rows.filter((r) => r.ok).map((r) => r.presentMs)
        const fetch = run.rows.map((r) => r.fetchMs)
        const append = run.rows.map((r) => r.appendMs)
        const sorted = (list) => [...list].sort((a, b) => a - b)
        const at = (list, p) => (list.length ? round1(sorted(list)[Math.min(list.length - 1, Math.ceil((p / 100) * list.length) - 1)]) : null)
        drag[id][name] = {
          steps: run.steps, correctPct: run.correctPct,
          totalP50: at(total, 50), totalP95: at(total, 95), presentP50: at(present, 50), presentP95: at(present, 95),
          fetchP50: at(fetch, 50), appendP50: at(append, 50),
          picturesPerSecond: at(total, 50) ? round1(1000 / at(total, 50)) : null,
          keyBytes: fx.parts[fx.keyParts()[0]].bytes,
        }
      }
    }
    report.metric('drag', drag)
    const bestCorrect = Math.max(...Object.values(drag).flatMap((v) => Object.values(v).map((x) => x.correctPct)))
    report.check('a key-step drag produces the right picture at least 95% of the time (best variant)', bestCorrect >= 95, `best ${bestCorrect}%`)
  },
}
