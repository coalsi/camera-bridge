import test from 'node:test'
import assert from 'node:assert/strict'
import { Histogram, percentile, median, mean, slope } from '../web-dev/soak/stats.mjs'

test('a histogram percentile is within 3% of the exact one', () => {
  const values = Array.from({ length: 20000 }, (_, i) => 1 + (i % 997) * 0.37 + (i % 13))
  const h = new Histogram()
  for (const v of values) h.add(v)
  for (const p of [50, 95, 99]) {
    const exact = percentile(values, p), approx = h.percentile(p)
    assert.ok(Math.abs(approx - exact) / exact < 0.035, `p${p}: exact ${exact}, histogram ${approx}`)
  }
  assert.equal(h.total, 20000)
})

test('histograms merge and survive JSON', () => {
  const a = new Histogram(), b = new Histogram()
  for (let i = 1; i <= 100; i++) a.add(i)
  for (let i = 101; i <= 200; i++) b.add(i)
  const merged = Histogram.fromJSON(JSON.parse(JSON.stringify(a))).merge(Histogram.fromJSON(JSON.parse(JSON.stringify(b))))
  assert.equal(merged.total, 200)
  assert.ok(Math.abs(merged.percentile(50) - 100) < 4)
  assert.equal(merged.max, 200)
})

test('an empty histogram answers NaN and the extremes are clamped', () => {
  const h = new Histogram()
  assert.ok(Number.isNaN(h.percentile(99)))
  h.add(0); h.add(-5); h.add(10_000_000)
  assert.equal(h.total, 3)
  assert.ok(h.percentile(100) <= 10_000_000)
})

test('exact percentiles, median, mean', () => {
  assert.equal(percentile([5, 1, 3, 2, 4], 50), 3)
  assert.equal(percentile([1, 2, 3, 4], 100), 4)
  assert.equal(median([10, 20, 30, 40]), 20)
  assert.equal(mean([1, 2, 3]), 2)
  assert.ok(Number.isNaN(percentile([], 50)))
})

test('slope of a line and of noise around it', () => {
  assert.equal(slope([[0, 1], [1, 3], [2, 5], [3, 7]]), 2)
  assert.ok(Number.isNaN(slope([[1, 1]])))
  assert.ok(Number.isNaN(slope([[2, 1], [2, 5]])))
  const noisy = Array.from({ length: 200 }, (_, i) => [i, 10 + 0.5 * i + ((i * 7919) % 11 - 5) * 0.2])
  assert.ok(Math.abs(slope(noisy) - 0.5) < 0.02)
})
