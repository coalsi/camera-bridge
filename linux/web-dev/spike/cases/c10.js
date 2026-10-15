import { once, sleep } from '../lib/dom.js'
import { watchPlayback } from '../lib/present.js'
import { appendParts, openFixture, seekTo } from './common.js'

const OFFSET = 300

/** The raw attach, to see what happens without disableRemotePlayback (the claim is that sourceopen then never fires). */
async function openWithoutDisablingRemotePlayback(ctx) {
  const video = document.createElement('video')
  video.muted = true
  video.setAttribute('playsinline', '')
  video.disableRemotePlayback = false
  ctx.tiles.append(video)
  const ms = new globalThis.ManagedMediaSource()
  let url = null
  try {
    url = URL.createObjectURL(ms)
    video.src = url
    await once(ms, 'sourceopen', 2000)
    return { sourceopen: true }
  } catch {
    return { sourceopen: false }
  } finally {
    if (url) URL.revokeObjectURL(url)
    video.removeAttribute('src')
    video.load()
    video.remove()
  }
}

export default {
  id: 'c10',
  title: 'ManagedMediaSource (the iPhone path): open, play, startstreaming and endstreaming, eviction',
  needs: ['bar'],
  async run(ctx, report) {
    if (!globalThis.ManagedMediaSource) {
      report.skip('this browser has no ManagedMediaSource')
      return
    }
    const fx = await ctx.fixture('bar')
    const original = ctx.managed
    ctx.managed = true            // every surface in this case is a ManagedMediaSource
    try {
      // 10a: attach by src and by srcObject.
      const attach = {}
      for (const mode of ['src', 'srcObject']) {
        const row = { opened: false, ms: null, error: null }
        const previous = ctx.attach
        ctx.attach = mode
        try {
          const t0 = performance.now()
          const surface = await openFixture(ctx, fx, { offsetSec: OFFSET })
          row.opened = true
          row.ms = Math.round(performance.now() - t0)
          row.streamingAfterOpen = surface.ms.streaming ?? null
          await surface.append(await fx.part(0))
          row.presented = (await seekTo(ctx, fx, OFFSET, 0.001)).ok
          surface.destroy()
        } catch (error) {
          row.error = `${error.name}: ${error.message}`
        }
        ctx.attach = previous
        attach[mode] = row
      }
      report.metric('attach', attach)
      report.check('sourceopen fires with disableRemotePlayback (attach by src)', attach.src.opened, JSON.stringify(attach.src))
      report.check('the first key picture is shown through ManagedMediaSource', attach.src.presented === true, JSON.stringify(attach.src))

      report.metric('withoutDisableRemotePlayback', await openWithoutDisablingRemotePlayback(ctx))

      // 10b: play a chain and watch the events.
      const surface = await openFixture(ctx, fx, { offsetSec: OFFSET })
      await appendParts(surface, fx, 0, 2)
      const seek = await seekTo(ctx, fx, OFFSET, 0.5)
      report.check('a mid-GOP seek shows the exact frame', seek.ok && Math.abs(seek.errorFrames ?? 99) <= 1, `error ${seek.errorFrames}`)
      const watcher = watchPlayback(ctx.video)
      try { await ctx.video.play() } catch (error) { report.note(`play() refused: ${error.name}`) }
      await sleep(2000)
      ctx.video.pause()
      const play = watcher.stop()
      report.check('playback advances', play.advancedSec > 1.2, `advanced ${play.advancedSec} s`)
      const eventsAfterPlay = surface.events.map((e) => `${e.t}:${e.type}`)

      // 10c: idle for a while with data held: does the browser tell us to stop (endstreaming) or evict (bufferedchange)?
      const heldBefore = surface.held()
      await sleep(5000)
      const heldAfter = surface.held()
      const streaming = surface.ms.streaming ?? null
      let appendWhileNotStreaming = null
      if (streaming === false) {
        try { await surface.append(await fx.part(3)); appendWhileNotStreaming = 'accepted' } catch (error) { appendWhileNotStreaming = `${error.name}` }
      }
      report.metric('events', { afterPlay: eventsAfterPlay, all: surface.events.map((e) => `${e.t}:${e.type}${e.detail ? JSON.stringify(e.detail) : ''}`).slice(0, 60) })
      report.metric('idle', { heldBefore: heldBefore.map((r) => r.map((x) => Math.round((x - OFFSET) * 100) / 100)), heldAfter: heldAfter.map((r) => r.map((x) => Math.round((x - OFFSET) * 100) / 100)), streamingNow: streaming, appendWhileNotStreaming })
      report.metric('seenStartStreaming', surface.events.some((e) => e.type === 'startstreaming'))
      report.metric('seenEndStreaming', surface.events.some((e) => e.type === 'endstreaming'))
      report.metric('seenBufferedChange', surface.events.some((e) => e.type === 'bufferedchange'))
      surface.destroy()
    } finally {
      ctx.managed = original
    }
  },
}
