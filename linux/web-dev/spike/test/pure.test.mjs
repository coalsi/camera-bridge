import assert from 'node:assert/strict'
import { test } from 'node:test'
import { classOfLabel, decodeBarcode, frameIndexAt, hostKind, guessClass, mulberry32, percentile, stats, mimeParts } from '../lib/pure.js'

test('percentile is nearest-rank on a sorted copy and null for no values', () => {
  assert.equal(percentile([], 50), null)
  assert.equal(percentile([5, 1, 3], 50), 3)
  assert.equal(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 95), 10)
  assert.equal(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 50), 5)
  const input = [3, 1, 2]
  percentile(input, 50)
  assert.deepEqual(input, [3, 1, 2])
})

test('stats summarises a list and rounds to 0.1', () => {
  assert.deepEqual(stats([10, 20, 30, 40]), { n: 4, min: 10, p50: 20, p95: 40, max: 40, mean: 25 })
  assert.deepEqual(stats([]), { n: 0, min: null, p50: null, p95: null, max: null, mean: null })
  assert.equal(stats([1.04, 1.06]).mean, 1.1)
})

test('frameIndexAt finds the frame shown at a time (the last one that started)', () => {
  const frames = [[0, 1], [4500, 0], [9000, 0], [13500, 0]]
  assert.equal(frameIndexAt(frames, -1), -1)
  assert.equal(frameIndexAt(frames, 0), 0)
  assert.equal(frameIndexAt(frames, 4499), 0)
  assert.equal(frameIndexAt(frames, 4500), 1)
  assert.equal(frameIndexAt(frames, 99999), 3)
  // NTSC: 3003 ticks per frame; 100 ms is inside frame 3 (9009 ticks = 100.1 ms starts after it)
  const ntsc = Array.from({ length: 10 }, (_, i) => [i * 3003, i === 0 ? 1 : 0])
  assert.equal(frameIndexAt(ntsc, Math.round(0.1 * 90000)), 2)
  // B-frames: pts out of decode order still resolves by pts
  const reordered = [[0, 1], [9000, 0], [4500, 0], [18000, 0], [13500, 0]]
  assert.equal(frameIndexAt(reordered, 5000), 2)
})

test('decodeBarcode reads 16 blocks, low bit first, and flags unclear blocks', () => {
  const bits = (n) => Array.from({ length: 16 }, (_, k) => ((n >> k) & 1 ? 235 : 16))
  assert.deepEqual(decodeBarcode(bits(0)), { value: 0, valid: true })
  assert.deepEqual(decodeBarcode(bits(1)), { value: 1, valid: true })
  assert.deepEqual(decodeBarcode(bits(40000 + 123)), { value: 40123, valid: true })
  assert.deepEqual(decodeBarcode(bits(65535)), { value: 65535, valid: true })
  const smudged = bits(5)
  smudged[3] = 120
  assert.equal(decodeBarcode(smudged).valid, false)
  assert.equal(decodeBarcode([1, 2, 3]).valid, false)
})

test('mulberry32 is deterministic', () => {
  const a = mulberry32(1), b = mulberry32(1)
  assert.deepEqual([a(), a(), a()], [b(), b(), b()])
  assert.notEqual(mulberry32(2)(), mulberry32(1)())
  const value = mulberry32(7)()
  assert.ok(value >= 0 && value < 1)
})

test('labels map to browser classes; -sim marks the simulator', () => {
  assert.deepEqual(classOfLabel('chrome-mac'), { class: 'chrome-mac', simulator: false })
  assert.deepEqual(classOfLabel('safari-mac-run2'), { class: 'safari-mac', simulator: false })
  assert.deepEqual(classOfLabel('iphone-safari-sim'), { class: 'iphone-safari', simulator: true })
  assert.deepEqual(classOfLabel('ipad-safari-sim-ios26'), { class: 'ipad-safari', simulator: true })
  assert.deepEqual(classOfLabel('iphone-safari-sim2'), { class: 'iphone-safari', simulator: true })
  assert.deepEqual(classOfLabel('safari-mac-simple'), { class: 'safari-mac', simulator: false })
  assert.deepEqual(classOfLabel('odd'), { class: 'odd', simulator: false })
})

test('the user agent decides the class when no label is given', () => {
  const ua = {
    chrome: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
    edge: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0',
    safari: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15',
    firefox: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:142.0) Gecko/20100101 Firefox/142.0',
    iphone: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1',
    ipadDesktopUA: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15',
    chromeOnIPhone: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0.0.0 Mobile/15E148 Safari/604.1',
  }
  assert.equal(guessClass(ua.chrome, 0), 'chrome-mac')
  assert.equal(guessClass(ua.edge, 0), 'chrome-mac')
  assert.equal(guessClass(ua.safari, 0), 'safari-mac')
  assert.equal(guessClass(ua.firefox, 0), 'firefox-mac')
  assert.equal(guessClass(ua.iphone, 5), 'iphone-safari')
  assert.equal(guessClass(ua.chromeOnIPhone, 5), 'iphone-safari')
  assert.equal(guessClass(ua.ipadDesktopUA, 5), 'ipad-safari')
})

test('hostKind separates loopback (secure context), IP literals and names', () => {
  assert.equal(hostKind('localhost'), 'loopback')
  assert.equal(hostKind('127.0.0.1'), 'loopback')
  assert.equal(hostKind('foo.localhost'), 'loopback')
  assert.equal(hostKind('[::1]'), 'loopback')
  assert.equal(hostKind('192.0.2.10'), 'ip')
  assert.equal(hostKind('studio.local'), 'name')
  assert.equal(hostKind('camera-bridge.local'), 'name')
})

test('mimeParts reads the codec out of a mime type', () => {
  assert.deepEqual(mimeParts('video/mp4; codecs="avc1.4d401f"'), { type: 'video/mp4', codecs: ['avc1.4d401f'] })
  assert.deepEqual(mimeParts('video/mp4; codecs="avc1.4d401f,mp4a.40.2"').codecs, ['avc1.4d401f', 'mp4a.40.2'])
})
