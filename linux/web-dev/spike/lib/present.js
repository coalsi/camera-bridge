import { decodeBarcode } from './pure.js'

const WIDTH = 512
const HEIGHT = 32
const BLOCK = 32

export function makeReadCanvas() {
  const canvas = document.createElement('canvas')
  canvas.width = WIDTH
  canvas.height = HEIGHT
  return canvas
}

/** The frame counter drawn into the picture (its fixture base included), or null when no clear frame can be read. */
export function readBarcode(video, canvas) {
  if (video.readyState < 2 || !video.videoWidth) return null
  const context = canvas.getContext('2d', { willReadFrequently: true })
  try {
    context.drawImage(video, 0, 0, WIDTH, HEIGHT, 0, 0, WIDTH, HEIGHT)   // source rectangle in video pixels, whatever the CSS size
  } catch {
    return null
  }
  const data = context.getImageData(0, 0, WIDTH, HEIGHT).data
  const lumas = []
  for (let k = 0; k < 16; k++) {
    const at = ((HEIGHT / 2) * WIDTH + k * BLOCK + BLOCK / 2) * 4
    if (data[at + 3] !== 255) return null
    lumas.push(0.299 * data[at] + 0.587 * data[at + 1] + 0.114 * data[at + 2])
  }
  const { value, valid } = decodeBarcode(lumas)
  return valid ? value : null
}

/** Mean luminance (0...255) of the whole picture on a 64x36 grid, or null when nothing can be read: a black or empty picture is near 0. */
export function lumaMean(video) {
  if (video.readyState < 2 || !video.videoWidth) return null
  const small = lumaMean.canvas ?? (lumaMean.canvas = Object.assign(document.createElement('canvas'), { width: 64, height: 36 }))
  const context = small.getContext('2d', { willReadFrequently: true })
  try {
    context.drawImage(video, 0, 0, video.videoWidth, video.videoHeight, 0, 0, 64, 36)
  } catch {
    return null
  }
  const data = context.getImageData(0, 0, 64, 36).data
  let sum = 0
  for (let i = 0; i < data.length; i += 4) sum += 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2]
  return sum / (data.length / 4)
}

const round1 = (x) => Math.round(x * 10) / 10

/**
 * Sets video.currentTime and waits until the expected picture is on screen (or timeoutMs).
 * expect: { mediaTime, tolSec, barcodeN? }. With a barcode the picture is identified by its counter (works in every browser); without one,
 * by the presented frame's mediaTime from requestVideoFrameCallback. Resolves (never rejects) with
 * { ok, ms, observedN, observedMediaTime, mediaTimeOk, via, seekedMs, history } where history lists the first pictures seen.
 */
export function seekAndPresent(video, timeSec, { expect, canvas, timeoutMs = 1500 } = {}) {
  return new Promise((resolve) => {
    const t0 = performance.now()
    const history = []
    const useBarcode = Boolean(expect) && expect.barcodeN !== undefined
    const hasRVFC = typeof video.requestVideoFrameCallback === 'function'
    let settled = false
    let rvfcId = null
    let seekedMs = null
    let last = { N: null, mediaTime: null, via: null }

    const finish = (ok, via) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      clearInterval(poll)
      video.removeEventListener('seeked', onSeeked)
      if (rvfcId !== null && typeof video.cancelVideoFrameCallback === 'function') {
        try { video.cancelVideoFrameCallback(rvfcId) } catch { /* the element may be gone */ }
      }
      const mediaTimeOk = expect && last.mediaTime !== null ? Math.abs(last.mediaTime - expect.mediaTime) <= expect.tolSec : null
      resolve({ ok, ms: round1(performance.now() - t0), observedN: last.N, observedMediaTime: last.mediaTime, mediaTimeOk, via: via ?? last.via, seekedMs, history })
    }

    const observe = (mediaTime, via) => {
      if (settled) return
      const N = useBarcode ? readBarcode(video, canvas) : null
      last = { N, mediaTime, via }
      if (history.length < 12) history.push({ t: Math.round(performance.now() - t0), N, mediaTime: mediaTime === null ? null : Math.round(mediaTime * 1e6) / 1e6, via })
      if (useBarcode) {
        if (N !== null && N === expect.barcodeN) finish(true, via)
      } else if (via === 'rvfc' && expect && Math.abs(mediaTime - expect.mediaTime) <= expect.tolSec) {
        finish(true, via)
      }
    }

    const onFrame = (_now, metadata) => {
      observe(metadata.mediaTime, 'rvfc')
      if (!settled) rvfcId = video.requestVideoFrameCallback(onFrame)
    }
    const onSeeked = () => {
      seekedMs = round1(performance.now() - t0)
      // Without requestVideoFrameCallback and without a barcode the best evidence is the seek itself.
      if (!hasRVFC && !useBarcode) setTimeout(() => finish(true, 'seeked'), 50)
    }
    const poll = setInterval(() => { if (useBarcode) observe(video.currentTime, 'poll') }, 20)
    const timer = setTimeout(() => finish(false, last.via), timeoutMs)

    video.addEventListener('seeked', onSeeked)
    if (hasRVFC) rvfcId = video.requestVideoFrameCallback(onFrame)
    video.currentTime = timeSec
  })
}

/**
 * Watches a playing video: stalls (currentTime not moving for a while, as the longest such period), `waiting` events and, where supported,
 * the longest gap between presented frames. Call stop() for the result.
 */
export function watchPlayback(video) {
  const state = { waiting: 0, frames: 0, maxFrameGapMs: 0, maxStallMs: 0, startTime: video.currentTime, startedAt: performance.now() }
  let lastNow = null
  let rvfcId = null
  let stopped = false
  let lastTime = video.currentTime
  let lastMoved = performance.now()
  const onWaiting = () => { state.waiting++ }
  const onFrame = (now) => {
    if (stopped) return
    state.frames++
    if (lastNow !== null) state.maxFrameGapMs = Math.max(state.maxFrameGapMs, now - lastNow)
    lastNow = now
    rvfcId = video.requestVideoFrameCallback(onFrame)
  }
  const sampler = setInterval(() => {
    const now = performance.now()
    if (video.currentTime !== lastTime) { lastTime = video.currentTime; lastMoved = now } else if (!video.paused) state.maxStallMs = Math.max(state.maxStallMs, now - lastMoved)
  }, 25)
  video.addEventListener('waiting', onWaiting)
  if (typeof video.requestVideoFrameCallback === 'function') rvfcId = video.requestVideoFrameCallback(onFrame)
  return {
    state,
    stop() {
      stopped = true
      clearInterval(sampler)
      video.removeEventListener('waiting', onWaiting)
      if (rvfcId !== null && typeof video.cancelVideoFrameCallback === 'function') { try { video.cancelVideoFrameCallback(rvfcId) } catch { /* gone */ } }
      return {
        waiting: state.waiting, frames: state.frames,
        advancedSec: Math.round((video.currentTime - state.startTime) * 1000) / 1000, elapsedMs: Math.round(performance.now() - state.startedAt),
        maxFrameGapMs: Math.round(state.maxFrameGapMs), maxStallMs: Math.round(state.maxStallMs),
      }
    },
  }
}
