import { h, sleep } from '../lib/dom.js'
import { Surface } from '../lib/surface.js'
import { pct, round1 } from './common.js'

const WINDOW_MS = 5000
const WARM_MS = 1500
const PLAYING_FPS_FLOOR = 16          // 80% of the fixtures' 20 fps

/** n tiles, each its own MediaSource, all playing the same fixture muted; measures the steady state. */
async function runTiles(ctx, fx, count) {
  const host = ctx.tiles
  host.replaceChildren()
  const tiles = []
  const t0 = performance.now()
  for (let i = 0; i < count; i++) {
    const video = h('video', { muted: true, playsinline: true })
    host.append(video)
    const surface = ctx.track(new Surface({ video, managed: ctx.managed, attach: ctx.attach }))
    tiles.push({ video, surface, frames: 0, firstFrameMs: null, error: null })
  }
  // Setup in parallel, as a grid page would.
  await Promise.all(tiles.map(async (tile) => {
    try {
      await tile.surface.open(fx.mime)
      await tile.surface.append(await fx.init())
      for (let i = 0; i < fx.parts.length; i++) await tile.surface.append(await fx.part(i))
      tile.video.currentTime = 0.001
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, 3000)
        const done = () => { clearTimeout(timer); tile.firstFrameMs = Math.round(performance.now() - t0); resolve() }
        if (typeof tile.video.requestVideoFrameCallback === 'function') tile.video.requestVideoFrameCallback(done)
        else tile.video.addEventListener('seeked', done, { once: true })
      })
    } catch (error) {
      tile.error = `${error.name}: ${error.message}`
    }
  }))
  const setupMs = Math.round(performance.now() - t0)

  for (const tile of tiles) {
    if (tile.error || typeof tile.video.requestVideoFrameCallback !== 'function') continue
    const count = (_now, _metadata) => { tile.frames++; tile.id = tile.video.requestVideoFrameCallback(count) }
    tile.id = tile.video.requestVideoFrameCallback(count)
  }
  for (const tile of tiles) { if (!tile.error) tile.video.play().catch((error) => { tile.error = `play: ${error.name}` }) }
  await sleep(WARM_MS)

  // The measured window.
  const longTasks = []
  let observer = null
  if (globalThis.PerformanceObserver?.supportedEntryTypes?.includes('longtask')) {
    observer = new PerformanceObserver((list) => longTasks.push(...list.getEntries().map((e) => e.duration)))
    observer.observe({ entryTypes: ['longtask'] })
  }
  for (const tile of tiles) {
    tile.frames = 0
    tile.quality0 = tile.video.getVideoPlaybackQuality?.() ?? null
    tile.time0 = tile.video.currentTime
  }
  const heap0 = performance.memory?.usedJSHeapSize ?? null
  ctx.mark(`${fx.id}-n${count}`)
  await sleep(WINDOW_MS)
  const heap1 = performance.memory?.usedJSHeapSize ?? null
  observer?.disconnect()

  const perTile = tiles.map((tile) => {
    const q1 = tile.video.getVideoPlaybackQuality?.() ?? null
    const total = q1 && tile.quality0 ? q1.totalVideoFrames - tile.quality0.totalVideoFrames : null
    const dropped = q1 && tile.quality0 ? q1.droppedVideoFrames - tile.quality0.droppedVideoFrames : null
    return {
      fps: round1(tile.frames / (WINDOW_MS / 1000)), total, dropped, droppedPct: total ? pct(dropped, total) : null,
      advancedSec: round1(tile.video.currentTime - tile.time0), readyState: tile.video.readyState,
      error: tile.error ?? (tile.video.error ? `media error ${tile.video.error.code}` : null), firstFrameMs: tile.firstFrameMs,
    }
  })
  for (const tile of tiles) { try { tile.video.pause() } catch { /* gone */ } }
  const summary = {
    tiles: count, setupMs, perTile,
    minFps: Math.min(...perTile.map((t) => t.fps)),
    worstDroppedPct: Math.max(...perTile.map((t) => t.droppedPct ?? 0)),
    errors: perTile.filter((t) => t.error).length,
    visible: document.visibilityState === 'visible',
    focused: document.hasFocus(),
    minAdvancedSec: Math.min(...perTile.map((t) => t.advancedSec)),
    heapDeltaMB: heap0 !== null && heap1 !== null ? round1((heap1 - heap0) / 1048576) : null,
    longTasks: longTasks.length ? { count: longTasks.length, totalMs: Math.round(longTasks.reduce((a, b) => a + b, 0)), maxMs: Math.round(Math.max(...longTasks)) } : (observer ? { count: 0, totalMs: 0, maxMs: 0 } : null),
  }
  // The presented rate decides. droppedVideoFrames is reported but not judged: headless Chrome counts every frame as dropped and Safari's count is coarse.
  summary.pass = summary.visible && summary.errors === 0 && summary.minFps >= PLAYING_FPS_FLOOR && summary.minAdvancedSec >= (WINDOW_MS / 1000) * 0.8
  for (const tile of tiles) tile.surface.destroy()
  host.replaceChildren()
  await sleep(400)
  return summary
}

export default {
  id: 'c12',
  title: '1, 2, 4 and 9 simultaneous 8 MP surfaces (and 4 MP): frames, drops, memory',
  needs: ['big'],
  async run(ctx, report) {
    const maxTiles = Number(ctx.params.get('max-tiles') ?? (ctx.env.class === 'iphone-safari' ? 4 : 9))
    const big = await ctx.fixture('big')
    report.metric('maxTiles', maxTiles)
    report.metric('bigFixture', { size: `${big.width}x${big.height}`, parts: big.parts.length, bytes: big.parts.reduce((n, p) => n + p.bytes, 0), mime: big.mime })
    const results = {}
    // 8 MP of the owner's widest camera (4256 wide), 8 MP at the usual hardware limit (3840x2160), and 4 MP.
    for (const [id, counts] of [['big', [1, 2, 4, 9]], ['uhd', [1, 4]], ['cap', [4, 9]]]) {
      const fx = id === 'big' ? big : await ctx.fixture(id).catch(() => null)
      if (!fx) continue
      for (const count of counts.filter((n) => n <= maxTiles)) {
        const key = `${id}_n${count}`
        results[key] = await runTiles(ctx, fx, count)
        ctx.log(`c12 ${id} x${count}: min ${results[key].minFps} fps, dropped ${results[key].worstDroppedPct}%, pass ${results[key].pass}`)
        if (!results[key].pass && count >= 4) break      // do not push a browser that already fails
      }
    }
    report.metric('results', results)
    const passing = Object.entries(results).filter(([key, r]) => key.startsWith('big_') && r.pass).map(([, r]) => r.tiles)
    report.metric('bigTilesThatPass', passing)
    report.metric('tileCapBig', passing.length ? Math.max(...passing) : 0)
    report.check('one 8 MP surface is presented at 16 fps or more for 5 s', results.big_n1?.pass === true, JSON.stringify(results.big_n1 ?? null).slice(0, 400))
  },
}
