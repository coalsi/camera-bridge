import { once, sleep } from './dom.js'

const OPERATION_TIMEOUT_MS = 10000
const SLOW_MS = 400

let trace = null
/** The page sets this to its log so a slow append, remove or open shows up there. */
export function setTrace(fn) { trace = fn }

export function mseConstructor(managed) {
  return managed ? globalThis.ManagedMediaSource : globalThis.MediaSource
}

/** 'MediaSource', 'ManagedMediaSource' or null: what a tile uses here. ManagedMediaSource only when MediaSource is missing (iPhone) or asked for. */
export function mseKind(preferManaged = false) {
  if (preferManaged && globalThis.ManagedMediaSource) return 'ManagedMediaSource'
  if (globalThis.MediaSource) return 'MediaSource'
  return globalThis.ManagedMediaSource ? 'ManagedMediaSource' : null
}

export function isTypeSupported(mime, managed = false) {
  const Constructor = mseConstructor(managed)
  return Boolean(Constructor) && Constructor.isTypeSupported(mime)
}

/**
 * One MediaSource and one SourceBuffer (segments mode) on one <video>: the spike's version of the page's MseSurface. Every wait is bounded.
 * Names follow T00 C.10 where they overlap (open, append, held, destroy); the rest are the raw operations the cases need.
 */
export class Surface {
  constructor({ video, managed = false, attach = 'src' }) {
    this.video = video
    this.managed = managed
    this.attach = attach
    this.events = []
    this.t0 = performance.now()
    this.ms = null
    this.sb = null
    this.url = null
  }

  log(type, detail) {
    if (this.events.length < 200) this.events.push({ t: Math.round(performance.now() - this.t0), type, ...(detail ? { detail } : {}) })
  }

  async open(mime, { timeoutMs = 3000 } = {}) {
    const Constructor = mseConstructor(this.managed)
    if (!Constructor) throw new Error(`${this.managed ? 'ManagedMediaSource' : 'MediaSource'} is not available`)
    this.mime = mime
    const ms = new Constructor()
    this.ms = ms
    for (const type of ['sourceopen', 'sourceended', 'sourceclose', 'startstreaming', 'endstreaming']) ms.addEventListener(type, () => this.log(type))
    if (this.managed) this.video.disableRemotePlayback = true     // without it Safari never fires sourceopen
    this.video.muted = true
    this.video.setAttribute('playsinline', '')
    const openStarted = performance.now()
    const opened = once(ms, 'sourceopen', timeoutMs, `sourceopen did not fire within ${timeoutMs} ms`)
    if (this.attach === 'srcObject' && 'srcObject' in this.video) {
      this.video.srcObject = ms
    } else {
      this.url = URL.createObjectURL(ms)
      this.video.src = this.url
    }
    await opened
    if (performance.now() - openStarted > SLOW_MS) trace?.(`slow open: ${Math.round(performance.now() - openStarted)} ms (${this.managed ? 'managed' : 'plain'})`)
    if (this.url) { URL.revokeObjectURL(this.url); this.url = null }       // as the page does: the URL is only needed to attach
    this.sb = ms.addSourceBuffer(mime)
    this.sb.mode = 'segments'
    if (this.managed) {
      this.sb.addEventListener('bufferedchange', (event) => this.log('bufferedchange', { added: event.addedRanges?.length, removed: event.removedRanges?.length }))
    }
    return this
  }

  /** Resolves when the append has finished; rejects on a SourceBuffer error, a thrown exception or after 10 s. */
  append(data) {
    return this.#operation((sb) => sb.appendBuffer(data), 'append')
  }

  remove(startSec, endSec = Infinity) {
    return this.#operation((sb) => sb.remove(startSec, endSec), 'remove')
  }

  #operation(start, label) {
    return new Promise((resolve, reject) => {
      const sb = this.sb
      if (!sb) { reject(new Error('no SourceBuffer')); return }
      let failed = false
      let settled = false
      const started = performance.now()
      const finish = (error) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        if (error || performance.now() - started > SLOW_MS) trace?.(`${error ? 'FAILED' : 'slow'} ${label}: ${Math.round(performance.now() - started)} ms${error ? ` (${error.name}: ${error.message})` : ''}`)
        sb.removeEventListener('updateend', onEnd)
        sb.removeEventListener('error', onError)
        if (error) reject(error)
        else resolve()
      }
      const onError = () => { failed = true }
      const onEnd = () => finish(failed ? new Error(`SourceBuffer error during ${label}`) : null)
      const timer = setTimeout(() => finish(new Error(`${label} did not finish within ${OPERATION_TIMEOUT_MS} ms`)), OPERATION_TIMEOUT_MS)
      sb.addEventListener('updateend', onEnd)
      sb.addEventListener('error', onError)
      try { start(sb) } catch (error) { finish(error) }
    })
  }

  /** The raw steps of a chain break. */
  abortParser() { this.sb.abort() }
  setOffset(seconds) { this.sb.timestampOffset = seconds }
  get offset() { return this.sb.timestampOffset }
  get canChangeType() { return typeof this.sb?.changeType === 'function' }
  changeType(mime) { this.sb.changeType(mime); this.mime = mime }

  /** Buffered ranges of the SourceBuffer as [[start, end], ...] in seconds on the video timeline. */
  held() {
    try {
      const ranges = this.sb.buffered
      return Array.from({ length: ranges.length }, (_, i) => [ranges.start(i), ranges.end(i)])
    } catch {
      return []
    }
  }

  /** The element's own buffered ranges (for a muxed buffer: the intersection of the tracks). */
  videoHeld() {
    const ranges = this.video.buffered
    return Array.from({ length: ranges.length }, (_, i) => [ranges.start(i), ranges.end(i)])
  }

  /** Waits (bounded) until the element knows its size after the init segment. */
  async metadata(timeoutMs = 2000) {
    const deadline = performance.now() + timeoutMs
    while (this.video.readyState < 1 && performance.now() < deadline) await sleep(10)
    return this.video.readyState >= 1
  }

  destroy() {
    try { this.video.pause() } catch { /* ignore */ }
    if (this.url) { URL.revokeObjectURL(this.url); this.url = null }
    this.video.removeAttribute('src')
    if ('srcObject' in this.video) this.video.srcObject = null
    try { this.video.load() } catch { /* ignore */ }
    this.ms = null
    this.sb = null
  }
}
