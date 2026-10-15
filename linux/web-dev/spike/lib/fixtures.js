import { frameIndexAt } from './pure.js'

const loaded = new Map()

export async function fixtureIds() {
  const response = await fetch('/fx/index.json', { cache: 'no-store' })
  return (await response.json()).fixtures
}

async function bytes(url) {
  const response = await fetch(url, { cache: 'no-store' })
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`)
  return response.arrayBuffer()
}

export class Fixture {
  constructor(manifest) {
    Object.assign(this, manifest)
    this.cache = new Map()
    const gaps = manifest.frames.slice(1).map((f, i) => f[0] - manifest.frames[i][0]).sort((a, b) => a - b)
    this.frameTicks = gaps.length ? gaps[Math.floor(gaps.length / 2)] : 4500
    this.frameSec = this.frameTicks / manifest.timescale
  }

  get hasBarcode() { return this.barcodeBase !== null && this.barcodeBase !== undefined }
  url(file) { return `/fx/${this.id}/${file}` }

  async cached(file) {
    if (!this.cache.has(file)) this.cache.set(file, await bytes(this.url(file)))
    return this.cache.get(file)
  }

  init() { return this.cached(this.initInfo.file) }
  part(i) { return this.cached(this.parts[i].file) }
  stored(i) { return this.parts[i].stored ? this.cached(this.parts[i].stored) : Promise.resolve(null) }

  /** An uncached fetch, timed: what a key step costs on the network. */
  async fetchPart(i) {
    const t0 = performance.now()
    const data = await bytes(this.url(this.parts[i].file))
    return { data, ms: performance.now() - t0 }
  }

  startSec(i) { return this.parts[i].startTick / this.timescale }
  endSec(i) { return (this.parts[i].startTick + this.parts[i].durTicks) / this.timescale }
  keyPartOf(i) { return i - this.parts[i].backToKey }
  keyParts() { return this.parts.filter((p) => p.key).map((p) => p.i) }

  /** The parts of the GOP that starts at key part k: [k, nextKey - 1]. */
  gopRange(k) {
    let end = k + 1
    while (end < this.parts.length && !this.parts[end].key) end++
    return [k, end - 1]
  }

  partAt(sec) { return this.parts.findIndex((p, i) => sec >= this.startSec(i) && sec < this.endSec(i)) }
  frameIndexAt(sec) { return frameIndexAt(this.frames, Math.round(sec * this.timescale)) }
  frameStartSec(index) { return this.frames[index][0] / this.timescale }

  /** What the page should see after seeking to fixture time `sec` with the fixture placed at `offsetSec` on the video timeline. */
  expectAt(sec, offsetSec = 0) {
    const index = this.frameIndexAt(sec)
    return {
      index,
      mediaTime: offsetSec + this.frameStartSec(index),
      barcodeN: this.hasBarcode ? this.barcodeBase + index : undefined,
      tolSec: this.frameSec * 0.5,
    }
  }
}

export async function loadFixture(id) {
  if (!loaded.has(id)) {
    const response = await fetch(`/fx/${id}/manifest.json`, { cache: 'no-store' })
    if (!response.ok) throw new Error(`fixture ${id} is missing: run make-fixtures.sh`)
    const manifest = await response.json()
    manifest.initInfo = manifest.init
    delete manifest.init
    loaded.set(id, new Fixture(manifest))
  }
  return loaded.get(id)
}
