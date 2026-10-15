import { sleep } from '../lib/dom.js'
import { watchPlayback } from '../lib/present.js'
import { openFixture, seekTo } from './common.js'

const A = 100
// Where the second "file" starts relative to the end of the first (6 s): overlap, abutting, and gaps. The same fixture is used twice.
const VARIANTS = [
  { name: 'overlap 0.4 ms', delta: -0.0004 },
  { name: 'abut', delta: 0 },
  { name: 'gap 40 ms', delta: 0.04 },
  { name: 'gap 100 ms', delta: 0.1 },
  { name: 'gap 300 ms', delta: 0.3 },
]

async function playAcross(ctx, fx, variant) {
  const video = ctx.video
  const secondStart = A + 6 + variant.delta
  const row = { ranges: null, stalled: false, resumed: null, resumeMs: null, waiting: 0, maxFrameGapMs: 0, maxStallMs: 0, endedAt: null, error: null }
  try {
    const surface = await openFixture(ctx, fx, { offsetSec: A })
    for (let i = 0; i <= 2; i++) await surface.append(await fx.part(i))      // 0..6 s of the first file
    surface.setOffset(secondStart)
    for (let i = 0; i <= 2; i++) await surface.append(await fx.part(i))      // the second file's first 6 s
    row.ranges = surface.held().length
    await seekTo(ctx, fx, A, 5.0)
    const watcher = watchPlayback(video)
    try { await video.play() } catch (error) { row.error = `play refused: ${error.name}` }
    const deadline = performance.now() + 4500
    let jumpedAt = null
    let resumedAt = null
    while (performance.now() < deadline) {
      await sleep(25)
      if (jumpedAt !== null && resumedAt === null && video.currentTime >= secondStart + 0.15) resumedAt = performance.now()
      if (video.currentTime >= secondStart + 1) break
      // The page's rule: waiting at the end of a buffered range with data after it -> move the playhead to the next part's start.
      if (jumpedAt === null && video.currentTime >= A + 5.9 && (watcher.state.waiting > 0 || video.readyState < 3)) {
        row.stalled = true
        jumpedAt = performance.now()
        video.currentTime = secondStart
      }
    }
    video.pause()
    const result = watcher.stop()
    row.waiting = result.waiting
    row.maxFrameGapMs = result.maxFrameGapMs
    row.maxStallMs = result.maxStallMs
    row.endedAt = Math.round((video.currentTime - A) * 1000) / 1000
    row.resumed = video.currentTime >= secondStart + 0.5
    if (jumpedAt !== null && resumedAt !== null) row.resumeMs = Math.round(resumedAt - jumpedAt)
    surface.destroy()
  } catch (error) {
    row.error = `${error.name}: ${error.message}`
  }
  return row
}

export default {
  id: 'c07',
  title: '0.4 ms overlap and gaps (40, 100, 300 ms) between two files during playback',
  needs: ['bar'],
  async run(ctx, report) {
    const fx = await ctx.fixture('bar')
    const rows = {}
    for (const variant of VARIANTS) rows[variant.name] = await playAcross(ctx, fx, variant)
    report.metric('variants', rows)
    // The page always applies the jump rule (move the playhead to the next part when playback waits at the end of a range), so what must hold is that
    // playback gets past the boundary, with or without a stall that the rule has to clear. Whether the browser stalled is recorded, not judged.
    const recovers = (name) => rows[name].error === null && rows[name].resumed && (!rows[name].stalled || (rows[name].resumeMs !== null && rows[name].resumeMs < 600))
    report.check('a 0.4 ms overlap: playback gets past the boundary (a stall, if any, is cleared by the jump rule within 600 ms)', recovers('overlap 0.4 ms'), JSON.stringify(rows['overlap 0.4 ms']))
    report.check('files that abut: playback gets past the boundary', recovers('abut'), JSON.stringify(rows.abut))
    report.check('a 300 ms gap: playback gets past the boundary once the playhead is moved to the next part', recovers('gap 300 ms'), JSON.stringify(rows['gap 300 ms']))
    report.metric('stallingVariants', VARIANTS.filter((v) => rows[v.name].stalled || rows[v.name].waiting > 0).map((v) => v.name))
    const smallestStalling = VARIANTS.find((v) => rows[v.name].stalled || rows[v.name].waiting > 0 || rows[v.name].maxStallMs >= 250)
    report.metric('smallestGapThatStallsMs', smallestStalling ? Math.max(0, Math.round(smallestStalling.delta * 1000)) : null)      // 0: even files that abut stall; null: none stalled
  },
}
