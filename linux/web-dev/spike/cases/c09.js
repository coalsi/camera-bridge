import { isTypeSupported, mseKind } from '../lib/surface.js'

// The strings the recorder and the owner's cameras produce. avc1.PPCCLL: profile, constraint flags, level. hvc1.<profile>.<compat>.<tier+level>.<constraints>.
const H264 = [
  ['Main 3.1 (fixture bar)', 'avc1.4d401f'],
  ['Main 5.0 (the Tapo capture)', 'avc1.4d0032'],
  ['High 4.0 (fixture barH)', 'avc1.640028'],
  ['High 5.1 (4256x1888 at 20 fps, fixture big)', 'avc1.640033'],
  ['High 5.2', 'avc1.640034'],
  ['Baseline 3.1', 'avc1.42c01f'],
  ['Constrained High 4.0', 'avc1.640828'],
]
const HEVC = [
  ['Main 3.1, hvc1 (fixture hevc)', 'hvc1.1.6.L93.90'],
  ['Main 5.1, hvc1', 'hvc1.1.6.L153.B0'],
  ['Main 4.1, hev1', 'hev1.1.6.L123.B0'],
  ['Main 10 5.1, hvc1', 'hvc1.2.4.L153.B0'],
]
const SIZES = [
  ['2688x1520 (Tapo)', 2688, 1520, 3_000_000],
  ['3632x1632 (I51HD)', 3632, 1632, 6_000_000],
  ['4256x1888 (ANNKE FCD800)', 4256, 1888, 8_000_000],
  ['3840x2160', 3840, 2160, 8_000_000],
]

export default {
  id: 'c09',
  title: 'isTypeSupported for avc1 and hvc1, canPlayType, MediaCapabilities, secure context',
  needs: ['bar', 'hevc', 'big'],
  async run(ctx, report) {
    const env = ctx.env
    const video = document.createElement('video')
    const kinds = { MediaSource: Boolean(globalThis.MediaSource), ManagedMediaSource: Boolean(globalThis.ManagedMediaSource) }
    const support = (list) => list.map(([name, codec]) => {
      const mime = `video/mp4; codecs="${codec}"`
      return {
        name, codec,
        MediaSource: globalThis.MediaSource ? globalThis.MediaSource.isTypeSupported(mime) : null,
        ManagedMediaSource: globalThis.ManagedMediaSource ? globalThis.ManagedMediaSource.isTypeSupported(mime) : null,
        canPlayType: video.canPlayType(mime) || 'no',
      }
    })
    const h264 = support(H264)
    const hevc = support(HEVC)
    report.metric('kinds', kinds)
    report.metric('h264', h264)
    report.metric('hevc', hevc)
    report.metric('hevcFixtureMime', (await ctx.fixture('hevc')).mime)

    report.check('the browser has MediaSource or ManagedMediaSource', mseKind(ctx.managed) !== null, JSON.stringify(kinds))
    for (const id of ['bar', 'cap', 'big']) {
      const fx = await ctx.fixture(id).catch(() => null)
      if (fx) report.check(`isTypeSupported accepts the ${id} fixture (${fx.mime})`, isTypeSupported(fx.mime, ctx.managed), '')
    }
    report.check('isTypeSupported accepts H.264 Main 5.0 and High 5.1 (the owner\'s cameras)', isTypeSupported('video/mp4; codecs="avc1.4d0032"', ctx.managed) && isTypeSupported('video/mp4; codecs="avc1.640033"', ctx.managed), '')

    // The condition the whole design rests on: the box is plain HTTP, so its page is not a secure context. Loopback is one, which hides this.
    report.metric('secureContext', { isSecureContext: env.isSecureContext, hostKind: env.hostKind, typeofVideoDecoder: env.typeofVideoDecoder, origin: env.origin })
    if (env.hostKind === 'loopback') {
      report.note('LOOPBACK: this origin is a secure context, so the plain-HTTP facts below were not tested. Open the page by the LAN name.')
    } else {
      report.check('isSecureContext is false on the LAN name (the box is plain HTTP)', env.isSecureContext === false, String(env.isSecureContext))
      report.metric('webCodecsOnPlainHttp', env.typeofVideoDecoder !== 'undefined')
      if (env.typeofVideoDecoder !== 'undefined') report.note('VideoDecoder exists on this plain-HTTP origin; the addendum (L3 fact 2) says it should not. The plan does not use WebCodecs, so nothing changes.')
    }

    // MediaCapabilities: will it play smoothly, and with hardware? (information; Safari answers coarsely)
    const capabilities = []
    if (typeof navigator.mediaCapabilities?.decodingInfo === 'function') {
      for (const [name, width, height, bitrate] of SIZES) {
        for (const type of ['media-source', 'file']) {
          try {
            const info = await navigator.mediaCapabilities.decodingInfo({ type, video: { contentType: 'video/mp4; codecs="avc1.640033"', width, height, bitrate, framerate: 20 } })
            capabilities.push({ name, type, supported: info.supported, smooth: info.smooth, powerEfficient: info.powerEfficient })
          } catch (error) {
            capabilities.push({ name, type, error: `${error.name}: ${error.message}` })
          }
        }
      }
    }
    report.metric('mediaCapabilities', capabilities)
  },
}
