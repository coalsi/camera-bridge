import { once } from '../lib/dom.js'

// Only run on /?csp=old: the page is then served with the daemon's CURRENT policy (no media-src), under which a blob: MediaSource must be blocked.
// It proves the one-directive change in T00 C.8 is needed, and that default-src 'none' is what blocks it today.
export default {
  id: 'x0',
  title: 'control: with the current CSP (no media-src) a blob: MediaSource is blocked',
  needs: [],
  async run(ctx, report) {
    if (ctx.params.get('csp') !== 'old') {
      report.skip('run this one with /?csp=old')
      return
    }
    const video = ctx.video
    const ms = new globalThis.MediaSource()
    const url = URL.createObjectURL(ms)
    video.src = url
    let opened = false
    try { await once(ms, 'sourceopen', 2500); opened = true } catch { opened = false }
    URL.revokeObjectURL(url)
    video.removeAttribute('src')
    video.load()
    report.metric('sourceopen', opened)
    report.metric('violations', ctx.violations.slice(0, 5))
    report.check('the old policy blocks the blob: media (no sourceopen, or a media-src/default-src violation reported)', !opened || ctx.violations.length > 0, `opened=${opened} violations=${ctx.violations.length}`)
  },
}
