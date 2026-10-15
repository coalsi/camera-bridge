import { Surface, isTypeSupported } from '../lib/surface.js'
import { openFixture, seekTo } from './common.js'

const A = 100
const B = 200

/** Same codec string, another init (SPS): barB after bar. */
async function sameMime(ctx, bar, barB, report) {
  const row = { startOk: false, withInitOk: false, backToAOk: false, sizeFollows: false, mediaOnlyAccepted: null, mediaOnlyPresented: null, error: null }
  try {
    const surface = await openFixture(ctx, bar, { offsetSec: A })
    await surface.append(await bar.part(0))
    row.startOk = (await seekTo(ctx, bar, A, 0.001)).ok
    surface.setOffset(B)
    await surface.append(await barB.init())
    await surface.append(await barB.part(0))
    row.withInitOk = (await seekTo(ctx, barB, B, 0.001)).ok
    row.sizeFollows = ctx.video.videoWidth === barB.width && ctx.video.videoHeight === barB.height
    row.backToAOk = (await seekTo(ctx, bar, A, 0.5)).ok
    row.ranges = surface.held().length
    surface.destroy()

    // Without the new init: does the browser cope with another SPS inside the media?
    const second = await openFixture(ctx, bar, { offsetSec: A })
    await second.append(await bar.part(0))
    second.setOffset(B)
    try { await second.append(await barB.part(0)); row.mediaOnlyAccepted = true } catch (error) { row.mediaOnlyAccepted = false; row.mediaOnlyError = error.name }
    if (row.mediaOnlyAccepted) row.mediaOnlyPresented = (await seekTo(ctx, barB, B, 0.001)).ok
    second.destroy()
  } catch (error) {
    row.error = `${error.name}: ${error.message}`
  }
  row.pass = row.startOk && row.withInitOk && row.sizeFollows && row.backToAOk
  return row
}

/** A different codec string (bar avc1.4d401f -> barH avc1.640028): changeType against destroy-and-rebuild. */
async function otherMime(ctx, bar, barH) {
  const result = { supportedBoth: isTypeSupported(bar.mime, ctx.managed) && isTypeSupported(barH.mime, ctx.managed), changeType: null, recreate: null }

  // changeType on the same SourceBuffer.
  {
    const row = { available: false, startOk: false, newOk: false, sizeOk: false, ms: null, error: null }
    try {
      const surface = await openFixture(ctx, bar, { offsetSec: A })
      row.available = surface.canChangeType
      await surface.append(await bar.part(0))
      row.startOk = (await seekTo(ctx, bar, A, 0.001)).ok
      if (row.available) {
        const t0 = performance.now()
        surface.changeType(barH.mime)
        surface.setOffset(B)
        await surface.append(await barH.init())
        await surface.append(await barH.part(0))
        const r = await seekTo(ctx, barH, B, 0.001)
        row.newOk = r.ok
        row.ms = Math.round(performance.now() - t0)
        row.sizeOk = ctx.video.videoWidth === barH.width && ctx.video.videoHeight === barH.height
      }
      surface.destroy()
    } catch (error) {
      row.error = `${error.name}: ${error.message}`
    }
    row.pass = row.available && row.startOk && row.newOk && row.sizeOk
    result.changeType = row
  }

  // Destroy the MediaSource and build a new one for the new mime on the same <video>.
  {
    const row = { startOk: false, newOk: false, sizeOk: false, ms: null, blankMs: null, error: null }
    try {
      const first = await openFixture(ctx, bar, { offsetSec: A })
      await first.append(await bar.part(0))
      row.startOk = (await seekTo(ctx, bar, A, 0.001)).ok
      const t0 = performance.now()
      first.destroy()
      const second = ctx.track(new Surface({ video: ctx.video, managed: ctx.managed, attach: ctx.attach }))
      await second.open(barH.mime)
      second.setOffset(B)
      await second.append(await barH.init())
      await second.append(await barH.part(0))
      const r = await seekTo(ctx, barH, B, 0.001)
      row.newOk = r.ok
      row.ms = Math.round(performance.now() - t0)
      row.blankMs = row.ms             // the element has no picture from destroy() until the first new frame; the page covers it with the held canvas
      row.sizeOk = ctx.video.videoWidth === barH.width && ctx.video.videoHeight === barH.height
      second.destroy()
    } catch (error) {
      row.error = `${error.name}: ${error.message}`
    }
    row.pass = row.startOk && row.newOk && row.sizeOk
    result.recreate = row
  }
  return result
}

export default {
  id: 'c05',
  title: 'two files: same mime (another SPS) and different mime (changeType against recreate)',
  needs: ['bar', 'barB', 'barH'],
  async run(ctx, report) {
    const bar = await ctx.fixture('bar')
    const barB = await ctx.fixture('barB')
    const barH = await ctx.fixture('barH')
    report.check('bar and barB share a codec string, differ in their init segment and in picture size (1280x720 against 960x540)', bar.mime === barB.mime && bar.initInfo.bytes !== barB.initInfo.bytes && bar.width !== barB.width,
      `${bar.mime} / ${barB.mime}, init ${bar.initInfo.bytes} / ${barB.initInfo.bytes} bytes`)
    report.check('barH has another codec string', bar.mime !== barH.mime, barH.mime)

    const same = await sameMime(ctx, bar, barB, report)
    report.metric('sameMime', same)
    report.check('same mime: appending the second file\'s init and media after the first works, and the first is still there', same.pass, JSON.stringify(same))

    const other = await otherMime(ctx, bar, barH)
    report.metric('otherMime', other)
    report.check('different mime: recreating the MediaSource works', other.recreate.pass, JSON.stringify(other.recreate))
    report.metric('changeTypeWorks', other.changeType.pass)
    // Recreating always works; changeType is only worth its extra moving part when it saves a visible amount of time (100 ms or more).
    report.metric('mimeChangeAdvice', other.changeType.pass && other.recreate.pass && other.recreate.ms - other.changeType.ms >= 100 ? 'changeType' : 'recreate')
  },
}
