import { classOfLabel, guessClass, hostKind } from './pure.js'
import { mseKind } from './surface.js'

/** What the browser is and which of the things the design relies on it has. Logged with every result (isSecureContext must be false on the LAN name). */
export async function collectEnvironment(params) {
  const userAgent = navigator.userAgent
  const guessed = guessClass(userAgent, navigator.maxTouchPoints ?? 0)
  const label = params.get('label') ?? guessed
  const { class: browserClass, simulator } = classOfLabel(label)
  const video = document.createElement('video')
  const env = {
    label,
    class: browserClass,
    simulatorLabel: simulator,
    guessedClass: guessed,
    userAgent,
    platform: navigator.platform,
    maxTouchPoints: navigator.maxTouchPoints ?? 0,
    hardwareConcurrency: navigator.hardwareConcurrency ?? null,
    deviceMemory: navigator.deviceMemory ?? null,
    screen: `${screen.width}x${screen.height}@${devicePixelRatio}`,
    origin: location.origin,
    hostKind: hostKind(location.hostname),
    isSecureContext: window.isSecureContext,
    crossOriginIsolated: window.crossOriginIsolated ?? false,
    typeofVideoDecoder: typeof globalThis.VideoDecoder,
    typeofMediaSource: typeof globalThis.MediaSource,
    typeofManagedMediaSource: typeof globalThis.ManagedMediaSource,
    mseKind: mseKind(params.get('managed') === '1'),
    usesManaged: params.get('managed') === '1' || (!globalThis.MediaSource && Boolean(globalThis.ManagedMediaSource)),
    requestVideoFrameCallback: typeof video.requestVideoFrameCallback === 'function',
    changeType: typeof globalThis.SourceBuffer?.prototype?.changeType === 'function',
    mediaCapabilities: typeof navigator.mediaCapabilities?.decodingInfo === 'function',
    performanceMemory: Boolean(performance.memory),
    longTaskObserver: Boolean(globalThis.PerformanceObserver?.supportedEntryTypes?.includes('longtask')),
    startedAt: new Date().toISOString(),
  }
  try {
    const t0 = performance.now()
    const response = await fetch('/api/speed?kb=4096', { cache: 'no-store' })
    const size = (await response.arrayBuffer()).byteLength
    env.linkMbps = Math.round(((size * 8) / 1e6 / ((performance.now() - t0) / 1000)) * 10) / 10
  } catch {
    env.linkMbps = null
  }
  return env
}
