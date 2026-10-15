import { sleep } from '../lib/dom.js'
import { readBarcode, watchPlayback } from '../lib/present.js'
import { appendParts, openFixture, seekTo } from './common.js'

const OFFSET = 3000.125

export default {
  id: 'c03',
  title: 'chain extension after a key picture (contiguous appends, paused and playing)',
  needs: ['gop30', 'bar', 'big'],
  async run(ctx, report) {
    const fx = await ctx.fixture('gop30')          // 30 s GOP in 2.5 s continuation fragments: part 0 is K, parts 1.. start with a delta frame
    const video = ctx.video
    const surface = await openFixture(ctx, fx, { offsetSec: OFFSET })

    // 1. K alone, key picture.
    await surface.append(await fx.part(0))
    const key = await seekTo(ctx, fx, OFFSET, 0.001)
    report.check('the key picture of K is shown', key.ok, `seen ${key.observedN}, wanted ${key.expect.barcodeN}`)
    const timeAtKey = video.currentTime

    // 2. Extend the chain with parts 1..3 while paused: the picture and the playhead must not move.
    await appendParts(surface, fx, 1, 3)
    const held = surface.held()
    const shownNow = readBarcode(video, ctx.canvas)
    report.metric('afterExtensionRanges', held.map(([a, b]) => [Math.round((a - OFFSET) * 1000) / 1000, Math.round((b - OFFSET) * 1000) / 1000]))
    report.check('the extension is one contiguous range of 10 s', held.length === 1 && Math.abs(held[0][1] - held[0][0] - 10) < 0.05, JSON.stringify(held))
    report.check('the playhead did not move while extending', Math.abs(video.currentTime - timeAtKey) < 0.002, `${timeAtKey} -> ${video.currentTime}`)
    report.check('the key picture is still the one shown', shownNow === fx.barcodeBase, `counter on screen ${shownNow}`)

    // 3. A mid-GOP seek into the extended chain: exact frame.
    const mid = await seekTo(ctx, fx, OFFSET, 8.3)
    report.check('a seek into the extended chain shows the exact frame', mid.ok && Math.abs(mid.errorFrames ?? 99) <= 1, `error ${mid.errorFrames} frames, ${mid.ms} ms`)
    report.metric('midSeekMs', mid.ms)

    // 4. Extend while playing: play from 5 s, append parts 4 and 5 shortly after, and play through the old end (10 s).
    await seekTo(ctx, fx, OFFSET, 5.0)
    const watcher = watchPlayback(video)
    try { await video.play() } catch (error) { report.note(`play() was refused: ${error.name}`) }
    await sleep(500)
    await appendParts(surface, fx, 4, 5)
    const deadline = performance.now() + 7000
    while (video.currentTime < OFFSET + 11 && performance.now() < deadline) await sleep(50)
    video.pause()
    const play = watcher.stop()
    report.metric('playThroughOldEnd', play)
    report.check('playback ran through the end of the old range (to 11 s) without stalling for 300 ms', video.currentTime >= OFFSET + 11 && play.maxStallMs < 300,
      `reached ${Math.round((video.currentTime - OFFSET) * 100) / 100} s, longest stall ${play.maxStallMs} ms, waiting events ${play.waiting}`)

    // 5. Control: re-append a delta-start fragment out of order (it starts mid-GOP, earlier than the end). MSE drops non-key frames after a backward
    //    jump until the next keyframe, so the page must never do this; this records what the browser does.
    const before = surface.held()
    let threw = null
    try { await surface.append(await fx.part(2)) } catch (error) { threw = error.name }
    const after = surface.held()
    report.metric('reappendDeltaStart', { threw, before: before.length, after: after.length, sameEnd: before.length && after.length ? Math.abs(before[before.length - 1][1] - after[after.length - 1][1]) < 0.001 : null })
    surface.destroy()

    // 6. Make before break (L7.1 #7): when the buffered range under the playhead is removed, does the element keep showing the last picture? If it
    //    does not, the page needs its hold canvas on this browser.
    {
      const bar = await ctx.fixture('bar')
      const second = await openFixture(ctx, bar, { offsetSec: OFFSET })
      await second.append(await bar.part(0))
      const shown = await seekTo(ctx, bar, OFFSET, 0.001)
      await second.remove(0, Infinity)
      await sleep(150)
      const counter = readBarcode(video, ctx.canvas)
      report.metric('removeUnderPlayhead', { shownBefore: shown.ok, counterAfter: counter, keepsPicture: counter === bar.barcodeBase, readyState: video.readyState, videoWidth: video.videoWidth })
      report.note(counter === bar.barcodeBase ? 'the element keeps its last picture after its range is removed' : 'the element loses its picture when its range is removed: keep the hold canvas')
      second.destroy()
    }

    // 7. Memory (L7.1 #7): the page holds up to 16 MB per tile. Does one SourceBuffer take 24 MB of 8 MP key fragments, and what happens at its
    //    quota (QuotaExceededError, then remove and retry once)?
    {
      const big = await ctx.fixture('big')
      const third = await openFixture(ctx, big, { offsetSec: 5000 })
      let appended = 0
      let quota = null
      let retry = null
      for (let i = 0; i < 30 && quota === null; i++) {
        third.setOffset(5000 + i * 10)
        try {
          await third.append(await big.part(0))
          appended += big.parts[0].bytes
        } catch (error) {
          if (error.name !== 'QuotaExceededError') throw error
          quota = { afterBytes: appended, atAppend: i }
          try {
            await third.remove(0, 5000 + (i - 3) * 10)
            await third.append(await big.part(0))
            retry = 'accepted after removing the oldest ranges'
          } catch (retryError) {
            retry = retryError.name
          }
        }
      }
      report.metric('memory', { appendedBytes: appended, quota, retry, ranges: third.held().length })
      report.check('one SourceBuffer holds at least 24 MB of 8 MP key fragments (the page keeps 16 MB per tile)', appended >= 24e6 || (quota !== null && quota.afterBytes >= 24e6), `appended ${appended} bytes, quota ${JSON.stringify(quota)}`)
      third.destroy()
    }
  },
}
