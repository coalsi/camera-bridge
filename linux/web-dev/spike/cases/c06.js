import { sleep } from '../lib/dom.js'
import { watchPlayback } from '../lib/present.js'
import { appendParts, openFixture, seekTo } from './common.js'

const BASE_OFFSET = 3.5e7 + 0.123456          // about 405 days: what the page uses (server time minus 400 days is the zero)
const ms3 = (x) => Math.round(x * 1000) / 1000

export default {
  id: 'c06',
  title: 'buffer times near 3.5e7 s, and a deliberately negative one',
  needs: ['bar', 'ntsc'],
  async run(ctx, report) {
    // Large positive offsets: exact buffered ranges, exact frames, steady playback.
    for (const id of ['bar', 'ntsc']) {
      const fx = await ctx.fixture(id)
      const surface = await openFixture(ctx, fx, { offsetSec: BASE_OFFSET })
      await appendParts(surface, fx, 0, 1)
      const held = surface.held()
      const startError = held.length ? Math.abs(held[0][0] - (BASE_OFFSET + fx.frameStartSec(0))) * 1000 : null
      const expectedEnd = BASE_OFFSET + fx.endSec(1)
      const endError = held.length ? Math.abs(held[held.length - 1][1] - expectedEnd) * 1000 : null
      const seek = await seekTo(ctx, fx, BASE_OFFSET, 1.234)
      const seekKey = await seekTo(ctx, fx, BASE_OFFSET, 2.001)
      await seekTo(ctx, fx, BASE_OFFSET, 0.5)
      const watcher = watchPlayback(ctx.video)
      try { await ctx.video.play() } catch (error) { report.note(`${id}: play() refused: ${error.name}`) }
      await sleep(1500)
      ctx.video.pause()
      const play = watcher.stop()
      report.metric(`large_${id}`, { ranges: held.length, startErrorMs: startError === null ? null : ms3(startError), endErrorMs: endError === null ? null : ms3(endError), seekOk: seek.ok, keyOk: seekKey.ok, errorFrames: seek.errorFrames, play, currentTime: ms3(ctx.video.currentTime) })
      report.check(`${id}: buffered times at 3.5e7 s are exact to 2 ms`, held.length === 1 && startError < 2 && endError < 2, `start error ${startError} ms, end error ${endError} ms, ranges ${held.length}`)
      report.check(`${id}: a mid-GOP seek at 3.5e7 s shows the exact frame (within one frame)`, seek.ok && Math.abs(seek.errorFrames ?? 99) <= 1, `error ${seek.errorFrames} frames`)
      report.check(`${id}: a seek to the next key fragment at 3.5e7 s works`, seekKey.ok, '')
      report.check(`${id}: playback at 3.5e7 s advances about as fast as the clock`, Math.abs(play.advancedSec - 1.5) < 0.4 && play.maxStallMs < 300,
        `advanced ${play.advancedSec} s in ${play.elapsedMs} ms, longest stall ${play.maxStallMs} ms`)
      surface.destroy()
    }

    // Negative times (information only: the page never produces them because BASE_MS sits 400 days in the past).
    const bar = await ctx.fixture('bar')
    const negative = {}
    for (const offset of [-1.0, -0.001]) {
      const row = { ranges: null, firstBufferedSec: null, droppedLeadSec: null, gop0Shown: null, gop1Shown: null, error: null }
      try {
        const surface = await openFixture(ctx, bar, { offsetSec: offset })
        await appendParts(surface, bar, 0, 2)
        const held = surface.held()
        row.ranges = held.length
        row.firstBufferedSec = held.length ? ms3(held[0][0]) : null
        row.droppedLeadSec = held.length ? ms3(held[0][0] - offset) : null            // how much of the file's start is missing
        row.gop1Shown = (await seekTo(ctx, bar, offset, 2.5, { timeoutMs: 800 })).ok    // the second GOP starts after time 0 and keeps its keyframe
        row.gop0Shown = (await seekTo(ctx, bar, offset, 1.0, { timeoutMs: 800 })).ok    // the first GOP lost its keyframe to the append window
        surface.destroy()
      } catch (error) {
        row.error = `${error.name}: ${error.message}`
      }
      negative[String(offset)] = row
    }
    report.metric('negative', negative)
    report.note('negative offsets: a keyframe before time 0 is dropped (appendWindowStart is 0), and so are its dependent frames; see metrics.negative')
  },
}
