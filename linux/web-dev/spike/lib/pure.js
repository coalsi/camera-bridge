// Pure helpers shared by the page and the Node tests. No DOM, no network.

/** Nearest-rank percentile of a copy of `values` (p in 0...100); null for no values. */
export function percentile(values, p) {
  if (values.length === 0) return null
  const sorted = [...values].sort((a, b) => a - b)
  const rank = Math.max(1, Math.ceil((p / 100) * sorted.length))
  return sorted[Math.min(rank, sorted.length) - 1]
}

const round1 = (x) => Math.round(x * 10) / 10

export function stats(values) {
  if (values.length === 0) return { n: 0, min: null, p50: null, p95: null, max: null, mean: null }
  return {
    n: values.length,
    min: round1(Math.min(...values)),
    p50: round1(percentile(values, 50)),
    p95: round1(percentile(values, 95)),
    max: round1(Math.max(...values)),
    mean: round1(values.reduce((sum, v) => sum + v, 0) / values.length),
  }
}

/** Index (in decode order) of the frame shown at `tick`: the one with the greatest pts not after it; -1 before the first. frames: [[pts, key], ...]. */
export function frameIndexAt(frames, tick) {
  let best = -1
  for (let i = 0; i < frames.length; i++) {
    if (frames[i][0] <= tick && (best < 0 || frames[i][0] >= frames[best][0])) best = i
  }
  return best
}

/** The frame counter drawn by make-fixtures.sh: 16 blocks, block k is bit k. `lumas` are the 16 block-centre luminances (0...255). */
export function decodeBarcode(lumas, { threshold = 128, margin = 40 } = {}) {
  if (lumas.length !== 16) return { value: null, valid: false }
  let value = 0
  let valid = true
  lumas.forEach((luma, k) => {
    if (Math.abs(luma - threshold) < margin) valid = false
    if (luma > threshold) value += 2 ** k
  })
  return { value, valid }
}

/** A small deterministic generator (0 <= x < 1) so a run picks the same targets every time. */
export function mulberry32(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const CLASSES = ['chrome-mac', 'safari-mac', 'firefox-mac', 'ipad-safari', 'iphone-safari']

/** { class, simulator } from a result label such as chrome-mac, safari-mac-run2 or iphone-safari-sim. */
export function classOfLabel(label) {
  const found = CLASSES.find((c) => label === c || label.startsWith(`${c}-`))
  return { class: found ?? label, simulator: /(^|-)sim\d*(-|$)/.test(label) }
}

/** The class from the user agent when the URL gave no ?label=. Chrome and Edge are one class; Chrome or Firefox on iOS is WebKit. */
export function guessClass(userAgent, maxTouchPoints = 0) {
  if (/iPhone|iPod/.test(userAgent)) return 'iphone-safari'
  if (/iPad/.test(userAgent) || (/Macintosh/.test(userAgent) && maxTouchPoints > 1)) return 'ipad-safari'
  if (/Firefox\//.test(userAgent)) return 'firefox-mac'
  if (/Edg\/|Chrome\//.test(userAgent)) return 'chrome-mac'
  if (/Safari\//.test(userAgent)) return 'safari-mac'
  return 'unknown'
}

/** loopback (a secure context), ip (a literal address) or name (a LAN name such as studio.local). */
export function hostKind(hostname) {
  const host = hostname.replace(/^\[|\]$/g, '').toLowerCase()
  if (host === 'localhost' || host.endsWith('.localhost') || host === '::1' || /^127\./.test(host)) return 'loopback'
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.includes(':')) return 'ip'
  return 'name'
}

export function mimeParts(mime) {
  const match = mime.match(/^([^;]+);\s*codecs="([^"]*)"/)
  return match ? { type: match[1].trim(), codecs: match[2].split(',').map((c) => c.trim()) } : { type: mime, codecs: [] }
}
