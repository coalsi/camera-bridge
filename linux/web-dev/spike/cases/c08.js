import { sleep } from '../lib/dom.js'
import { watchPlayback } from '../lib/present.js'
import { isTypeSupported } from '../lib/surface.js'
import { appendParts, openFixture, seekTo } from './common.js'

const OFFSET = 700

async function playFor(ctx, ms) {
  const watcher = watchPlayback(ctx.video)
  try { await ctx.video.play() } catch { /* the result shows it */ }
  await sleep(ms)
  ctx.video.pause()
  return watcher.stop()
}

export default {
  id: 'c08',
  title: 'video-only output of a file with sound: plays; muxed sound does not belong in the video buffer',
  needs: ['av', 'avv'],
  async run(ctx, report) {
    const av = await ctx.fixture('av')           // video + AAC, fragments with two trafs
    const avv = await ctx.fixture('avv')         // the same video alone (ffmpeg stand-in for ArchiveMedia's output; the later pass uses the real one)
    report.metric('fixtures', { avInit: av.initInfo.bytes, avvInit: avv.initInfo.bytes, avPart0: av.parts[0].bytes, avvPart0: avv.parts[0].bytes, avHasAudio: av.hasAudio, avvHasAudio: avv.hasAudio })
    report.check('the video-only fixture has no audio track and the muxed one has', !avv.hasAudio && av.hasAudio, '')
    report.check('isTypeSupported accepts the video-only mime', isTypeSupported(avv.mime, ctx.managed), avv.mime)

    // 8a: the video-only file plays on a video-only buffer.
    {
      const surface = await openFixture(ctx, avv, { offsetSec: OFFSET })
      await appendParts(surface, avv, 0, 2)
      const seek = await seekTo(ctx, avv, OFFSET, 0.5)
      const play = await playFor(ctx, 1500)
      report.metric('videoOnly', { seekOk: seek.ok, errorFrames: seek.errorFrames, play, ranges: surface.held().length })
      report.check('video-only: the exact frame is shown', seek.ok && Math.abs(seek.errorFrames ?? 99) <= 1, `error ${seek.errorFrames}`)
      report.check('video-only: playback advances without a stall', play.advancedSec > 1.0 && play.maxStallMs < 300, `advanced ${play.advancedSec} s, longest stall ${play.maxStallMs} ms`)
      surface.destroy()
    }

    // 8b (control): the muxed file on a muxed buffer.
    {
      const row = { supported: isTypeSupported(av.mimeAV, ctx.managed), accepted: null, seekOk: null, advancedSec: null, error: null }
      if (row.supported) {
        try {
          const surface = await openFixture(ctx, av, { offsetSec: OFFSET, mime: av.mimeAV })
          await appendParts(surface, av, 0, 2)
          row.accepted = true
          row.seekOk = (await seekTo(ctx, av, OFFSET, 0.5)).ok
          row.advancedSec = (await playFor(ctx, 1500)).advancedSec
          surface.destroy()
        } catch (error) {
          row.error = `${error.name}: ${error.message}`
        }
      }
      report.metric('muxedOnMuxed', row)
    }

    // 8c: the muxed file on a video-only buffer (what happens if the server forgot to drop the sound).
    {
      const row = { initAccepted: null, partAccepted: null, seekOk: null, error: null }
      try {
        const surface = await openFixture(ctx, av, { offsetSec: OFFSET, init: false })
        try { await surface.append(await av.init()); row.initAccepted = true } catch (error) { row.initAccepted = false; row.error = `${error.name}: ${error.message}` }
        if (row.initAccepted) {
          try { await surface.append(await av.part(0)); row.partAccepted = true } catch (error) { row.partAccepted = false; row.error = `${error.name}: ${error.message}` }
          if (row.partAccepted) row.seekOk = (await seekTo(ctx, av, OFFSET, 0.001, { timeoutMs: 800 })).ok
        }
        surface.destroy()
      } catch (error) {
        row.error = `${error.name}: ${error.message}`
      }
      report.metric('muxedOnVideoOnly', row)
    }

    // 8d (control, the reason for video-only): a muxed buffer where one fragment lost its sound. The element's buffered range is the intersection of the
    //     tracks, so it has a hole there and playback stops at it.
    {
      const row = { videoRanges: null, sbRanges: null, stalledAtHole: null, error: null }
      if (isTypeSupported(av.mimeAV, ctx.managed)) {
        try {
          const surface = await openFixture(ctx, av, { offsetSec: OFFSET, mime: av.mimeAV })
          await appendParts(surface, av, 0, 1)                    // 0..4 s with sound
          await surface.append(await avv.part(2))                 // 4..6 s video only (a media segment may hold one track)
          await appendParts(surface, av, 3, 4)                    // 6..10 s with sound
          row.sbRanges = surface.held().length
          row.videoRanges = surface.videoHeld().length
          await seekTo(ctx, av, OFFSET, 3.0)
          const play = await playFor(ctx, 2500)
          row.stalledAtHole = play.advancedSec < 1.5
          row.advancedSec = play.advancedSec
          surface.destroy()
        } catch (error) {
          row.error = `${error.name}: ${error.message}`
        }
      }
      report.metric('soundDropout', row)
    }

    // 8e (only when out/ava exists, the plan's pass B): the real ArchiveMedia output for a recorded file with sound.
    const ava = await ctx.fixture('ava').catch(() => null)
    if (ava) {
      const row = { hasAudio: ava.hasAudio, parts: ava.parts.length, seekOk: null, advancedSec: null, error: null }
      try {
        const surface = await openFixture(ctx, ava, { offsetSec: OFFSET })
        await appendParts(surface, ava, 0, Math.min(2, ava.parts.length - 1))
        const seek = await seekTo(ctx, ava, OFFSET, ava.startSec(0) + 0.4)
        row.seekOk = seek.ok
        row.advancedSec = (await playFor(ctx, 1500)).advancedSec
        surface.destroy()
      } catch (error) {
        row.error = `${error.name}: ${error.message}`
      }
      report.metric('archiveMediaOutput', row)
      report.check('ArchiveMedia output (video only, from a file with sound) plays', ava.hasAudio === false && row.seekOk === true && row.advancedSec > 1.0, JSON.stringify(row))
    }
  },
}
