import { openFixture, seekTo } from './common.js'

// The four ways to start a chain far from the held data. The page needs the simplest one that works in every gate browser.
const PROTOCOLS = [
  { name: 'offset', abort: false, init: false },
  { name: 'abort+offset', abort: true, init: false },
  { name: 'offset+init', abort: false, init: true },
  { name: 'abort+offset+init', abort: true, init: true },
]
const A = 100.0          // first chain
const B = 5000.123       // far forward
const C = 50.456         // far backward, before A

async function jump(surface, fx, offsetSec, protocol, part) {
  if (protocol.abort) surface.abortParser()
  surface.setOffset(offsetSec)
  if (protocol.init) await surface.append(await fx.init())
  await surface.append(await fx.part(part))
}

export default {
  id: 'c04',
  title: 'far jump with and without abort() and timestampOffset (and a re-appended init)',
  needs: ['bar'],
  async run(ctx, report) {
    const fx = await ctx.fixture('bar')            // 2 s GOPs, one key fragment each: parts 0..5
    const outcome = {}
    for (const protocol of PROTOCOLS) {
      const row = { A: false, B: false, C: false, backToA: false, ranges: null, error: null, ms: {} }
      try {
        const surface = await openFixture(ctx, fx, { offsetSec: A })
        await surface.append(await fx.part(0))
        row.A = (await seekTo(ctx, fx, A, fx.startSec(0) + 0.001)).ok

        let t0 = performance.now()
        await jump(surface, fx, B, protocol, 2)                                    // forward by about 4900 s
        row.B = (await seekTo(ctx, fx, B, fx.startSec(2) + 0.001)).ok
        row.ms.forward = Math.round(performance.now() - t0)

        t0 = performance.now()
        await jump(surface, fx, C, protocol, 4)                                    // backward, before everything held
        row.C = (await seekTo(ctx, fx, C, fx.startSec(4) + 0.001)).ok
        row.ms.backward = Math.round(performance.now() - t0)

        row.backToA = (await seekTo(ctx, fx, A, fx.startSec(0) + 0.5)).ok          // the first chain must still be there
        row.ranges = surface.held().length
        surface.destroy()
      } catch (error) {
        row.error = `${error.name}: ${error.message}`
      }
      row.pass = row.A && row.B && row.C && row.backToA && row.ranges === 3
      outcome[protocol.name] = row
    }
    report.metric('protocols', outcome)
    const passing = PROTOCOLS.filter((p) => outcome[p.name].pass).map((p) => p.name)
    report.metric('passing', passing)
    report.metric('simplestPassing', passing[0] ?? null)
    report.check('abort+offset+init (the conservative protocol) works: forward jump, backward jump, first chain kept, three ranges', outcome['abort+offset+init'].pass,
      JSON.stringify(outcome['abort+offset+init']))
    report.check('at least one protocol works', passing.length > 0, passing.join(', '))
  },
}
