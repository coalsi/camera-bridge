// Numbers for the soak tools: a mergeable latency histogram, exact percentiles, medians and a least-squares slope. No dependencies.

const MIN_MS = 0.05            // the smallest value the histogram tells apart
const GROWTH = 1.03            // each bucket is 3% wider than the one before, so a percentile is right to within 3%
const BUCKETS = Math.ceil(Math.log(600_000 / MIN_MS) / Math.log(GROWTH)) + 1   // up to ten minutes

export class Histogram {
  constructor() {
    this.counts = new Map()    // bucket index -> count (sparse: a run touches a few dozen buckets)
    this.total = 0
    this.max = 0
  }

  static indexFor(ms) {
    if (!(ms > MIN_MS)) return 0
    return Math.min(BUCKETS - 1, Math.floor(Math.log(ms / MIN_MS) / Math.log(GROWTH)) + 1)
  }

  // The value a bucket stands for: the middle of its range, in milliseconds.
  static valueFor(index) {
    if (index <= 0) return MIN_MS / 2
    return MIN_MS * Math.pow(GROWTH, index - 1) * Math.sqrt(GROWTH)
  }

  add(ms) {
    const index = Histogram.indexFor(ms)
    this.counts.set(index, (this.counts.get(index) ?? 0) + 1)
    this.total += 1
    if (ms > this.max) this.max = ms
  }

  merge(other) {
    for (const [index, count] of other.counts) this.counts.set(index, (this.counts.get(index) ?? 0) + count)
    this.total += other.total
    if (other.max > this.max) this.max = other.max
    return this
  }

  // p in 0...100. NaN when empty.
  percentile(p) {
    if (this.total === 0) return NaN
    const target = Math.max(1, Math.ceil((p / 100) * this.total))
    let seen = 0
    for (const index of [...this.counts.keys()].sort((a, b) => a - b)) {
      seen += this.counts.get(index)
      if (seen >= target) return Math.min(Histogram.valueFor(index), this.max)
    }
    return this.max
  }

  toJSON() { return { n: this.total, max: round(this.max), c: Object.fromEntries(this.counts) } }

  static fromJSON(json) {
    const h = new Histogram()
    if (!json) return h
    for (const [index, count] of Object.entries(json.c ?? {})) h.counts.set(Number(index), count)
    h.total = json.n ?? 0
    h.max = json.max ?? 0
    return h
  }
}

function round(value) { return Math.round(value * 1000) / 1000 }

// Exact percentile of an array of numbers (nearest rank). NaN for an empty array.
export function percentile(values, p) {
  if (values.length === 0) return NaN
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1))]
}

export function median(values) { return percentile(values, 50) }

export function mean(values) { return values.length === 0 ? NaN : values.reduce((a, b) => a + b, 0) / values.length }

// Least-squares slope of y over x (units of y per unit of x). NaN for fewer than two points or no spread in x.
export function slope(points) {
  const n = points.length
  if (n < 2) return NaN
  const mx = mean(points.map(([x]) => x)), my = mean(points.map(([, y]) => y))
  let num = 0, den = 0
  for (const [x, y] of points) { num += (x - mx) * (y - my); den += (x - mx) ** 2 }
  return den === 0 ? NaN : num / den
}
