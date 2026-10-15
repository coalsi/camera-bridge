import { mulberry32, percentile } from '../lib/pure.js'
import { openFixture, pct, round1, seekTo } from './common.js'

const OFFSET = 900
// Data kept after the target frame's end, in milliseconds. The page's rule is that at least 700 ms of the chain must lie after the target.
const MARGINS = [0, 40, 80, 120, 200, 300, 400, 500, 700, 1000]
const PLAN = [{ id: 'bar', trials: 4 }, { id: 'ntsc', trials: 4 }, { id: 'cap', trials: 2 }]

export default {
  id: 'c11',
  title: 'seek to the last frames of a buffered chain: how much data after the target is needed (the 700 ms margin)',
  needs: PLAN.map((p) => p.id),
  async run(ctx, report) {
    const random = mulberry32(11)
    const rows = []
    for (const { id, trials } of PLAN) {
      const fx = await ctx.fixture(id)
      const keys = fx.keyParts().slice(0, -1)
      for (const margin of MARGINS) {
        for (let n = 0; n < trials; n++) {
          const k = keys[Math.floor(random() * keys.length)]
          const frameIndex = fx.parts[k].frameFirst + 5 + Math.floor(random() * 15)
          const targetStart = fx.frameStartSec(frameIndex)
          const surface = await openFixture(ctx, fx, { offsetSec: OFFSET })
          await surface.append(await fx.part(k))
          await surface.append(await fx.part(k + 1))
          const cut = OFFSET + targetStart + fx.frameSec + margin / 1000
          await surface.remove(cut, Infinity)
          const held = surface.held()
          const afterTargetMs = held.length ? Math.round((held[held.length - 1][1] - (OFFSET + targetStart)) * 1000) : null
          const r = await seekTo(ctx, fx, OFFSET, targetStart + 0.0005, { timeoutMs: 1500 })
          rows.push({ fixture: id, margin, afterTargetMs, ok: r.ok, ms: r.ms, seen: r.observedN ?? r.observedMediaTime })
          surface.destroy()
        }
      }
    }
    const byMargin = {}
    for (const margin of MARGINS) {
      const list = rows.filter((r) => r.margin === margin)
      byMargin[margin] = { n: list.length, okPct: pct(list.filter((r) => r.ok).length, list.length), afterTargetMs: [Math.min(...list.map((r) => r.afterTargetMs)), Math.max(...list.map((r) => r.afterTargetMs))],
        presentMsP50: round1(percentile(list.filter((r) => r.ok).map((r) => r.ms), 50) ?? 0) }
    }
    // The smallest "data after the target" from which every trial succeeded (scanning from the largest down to the first failure).
    const sorted = rows.filter((r) => r.afterTargetMs !== null).sort((a, b) => b.afterTargetMs - a.afterTargetMs)
    let minReliable = null
    for (const row of sorted) {
      if (!row.ok) break
      minReliable = row.afterTargetMs
    }
    report.metric('byMargin', byMargin)
    report.metric('minReliableAfterTargetMs', minReliable)
    report.metric('failures', rows.filter((r) => !r.ok).slice(0, 10))
    report.check('with 700 ms or more after the target every seek shows the exact frame', rows.filter((r) => r.afterTargetMs >= 700).every((r) => r.ok),
      `${rows.filter((r) => r.afterTargetMs >= 700 && !r.ok).length} failures`)
    report.check('with the target frame as the last buffered frame the picture is still shown (no hold-back)', rows.filter((r) => r.margin === 0).every((r) => r.ok),
      `${rows.filter((r) => r.margin === 0 && r.ok).length} of ${rows.filter((r) => r.margin === 0).length}`)
  },
}
