import { mulberry32 } from '../lib/pure.js'
import { openFixture, pct, round1, seekTo } from './common.js'

const OFFSET = 2000.5
const PLAN = [
  { id: 'bar', trials: 12 },
  { id: 'ntsc', trials: 8 },
  { id: 'gop30', trials: 6 },
  { id: 'cap', trials: 5 },
]
const REQUIRED = PLAN.map((p) => p.id)

export default {
  id: 'c02',
  title: 'init + K..F, seek mid-GOP: the exact frame (within one frame)',
  needs: REQUIRED,
  async run(ctx, report) {
    const plan = [...PLAN]
    if (await ctx.fixture('capm').catch(() => null)) plan.push({ id: 'capm', trials: 5 })      // pass B: a recorder-layout file
    const random = mulberry32(2)
    const trials = []
    for (const { id, trials: count } of plan) {
      const fx = await ctx.fixture(id)
      const keys = fx.keyParts()
      for (let n = 0; n < count; n++) {
        const k = keys[Math.floor(random() * keys.length)]
        const [, last] = fx.gopRange(k)
        const from = fx.startSec(k) + 0.1
        const to = fx.endSec(last) - 0.1
        const target = from + random() * Math.max(0, to - from)
        const f = fx.partAt(target)
        const surface = await openFixture(ctx, fx, { offsetSec: OFFSET })
        let bytes = 0
        for (let i = k; i <= f; i++) { await surface.append(await fx.part(i)); bytes += fx.parts[i].bytes }
        const r = await seekTo(ctx, fx, OFFSET, target)
        const leadInFrames = r.expect.index - fx.parts[k].frameFirst
        trials.push({ fixture: id, target: Math.round(target * 1000) / 1000, parts: f - k + 1, bytes, leadInFrames, ok: r.ok, ms: r.ms, errorFrames: r.errorFrames, notBlack: r.notBlack })
        surface.destroy()
      }
    }
    const shown = trials.filter((t) => t.ok)
    const exact = shown.filter((t) => t.errorFrames === 0)
    const withinOne = shown.filter((t) => t.errorFrames !== null && Math.abs(t.errorFrames) <= 1)
    report.metric('trials', trials.length)
    report.metric('presentedPct', pct(shown.length, trials.length))
    report.metric('exactPct', pct(exact.length, trials.length))
    report.metric('withinOneFramePct', pct(withinOne.length, trials.length))
    report.stats('presentMs', shown.map((t) => t.ms))
    const bucket = (low, high) => shown.filter((t) => t.leadInFrames >= low && t.leadInFrames < high).map((t) => t.ms)
    report.stats('presentMs_leadIn_under_50_frames', bucket(0, 50))
    report.stats('presentMs_leadIn_50_to_250_frames', bucket(50, 250))
    report.stats('presentMs_leadIn_250_plus_frames', bucket(250, 100000))
    report.metric('byFixtureMs', Object.fromEntries(plan.map(({ id }) => {
      const list = shown.filter((t) => t.fixture === id).map((t) => t.ms)
      return [id, list.length ? round1(list.reduce((a, b) => a + b, 0) / list.length) : null]
    })))
    report.metric('failures', trials.filter((t) => !t.ok || (t.errorFrames !== null && Math.abs(t.errorFrames) > 1)).slice(0, 8))
    report.check('the exact frame is on screen within 1.5 s (at least 95%)', pct(shown.length, trials.length) >= 95, `${shown.length} of ${trials.length}`)
    report.check('the shown frame is within one frame of the target (at least 95%)', pct(withinOne.length, trials.length) >= 95, `${withinOne.length} of ${trials.length}`)
    const short = trials.filter((t) => t.leadInFrames < 100)
    report.check('a lead-in under 100 frames is presented in 1.5 s every time', short.every((t) => t.ok), `${short.filter((t) => t.ok).length} of ${short.length}`)
    report.check('the picture is not black', shown.every((t) => t.notBlack !== false), '')
  },
}
