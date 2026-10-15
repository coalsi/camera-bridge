import test from 'node:test'
import assert from 'node:assert/strict'
import { mulberry32, buildPhases, phaseAt, newGesture, gestureTarget, TICK_MS } from '../web-dev/soak/plan.mjs'

test('the same seed gives the same numbers, another seed another', () => {
  const a = mulberry32(42), b = mulberry32(42), c = mulberry32(43)
  const first = [a(), a(), a()], again = [b(), b(), b()], other = [c(), c(), c()]
  assert.deepEqual(first, again)
  assert.notDeepEqual(first, other)
  assert.ok(first.every((v) => v >= 0 && v < 1))
})

test('the 2 hour schedule is the documented one', () => {
  const phases = buildPhases(7200)
  assert.deepEqual(phases.map((p) => [p.name, p.kind, p.from, p.to]), [
    ['warmup', 'off', 0, 600], ['load', 'load', 600, 1800], ['storm1', 'storm', 1800, 2400], ['load', 'load', 2400, 5400],
    ['storm2', 'storm', 5400, 6000], ['load', 'load', 6000, 6600], ['cooldown', 'off', 6600, 7200]])
})

test('phases tile the run without gaps for any length', () => {
  for (const total of [120, 600, 777, 3600, 7200]) {
    const phases = buildPhases(total)
    assert.equal(phases[0].from, 0)
    assert.equal(phases.at(-1).to, total)
    phases.forEach((p, i) => { if (i > 0) assert.equal(p.from, phases[i - 1].to); assert.ok(p.to > p.from, `${total}: ${p.name} is empty`) })
  }
  assert.throws(() => buildPhases(60))
})

test('phaseAt finds the phase and is null after the end', () => {
  const phases = buildPhases(7200)
  assert.equal(phaseAt(phases, 0).name, 'warmup')
  assert.equal(phaseAt(phases, 1800).name, 'storm1')
  assert.equal(phaseAt(phases, 7199).name, 'cooldown')
  assert.equal(phaseAt(phases, 7200), null)
})

const extents = [
  { id: 'A', oldest: 1_000_000, newest: 1_000_000 + 3_600_000 },
  { id: 'B', oldest: 2_000_000, newest: 2_000_000 + 10_000 },     // too short to scrub: skipped
]

test('gestures only pick cameras with enough footage, start inside the recording and have a 40 ms tick', () => {
  const rng = mulberry32(7)
  const regions = { recent: 0, anywhere: 0, tail: 0 }
  for (let i = 0; i < 2000; i++) {
    const g = newGesture(rng, extents)
    assert.equal(g.camera, 'A')
    assert.equal(g.tickMs, TICK_MS)
    assert.ok(g.startMs >= extents[0].oldest && g.startMs <= extents[0].newest - 6_000)
    assert.ok(g.ticks >= 75 && g.ticks < 250 && g.stepMs >= 100 && g.stepMs <= 6_000)
    if (g.startMs >= extents[0].newest - 66_000) regions.recent++
    else if (g.startMs <= extents[0].oldest + 30_000) regions.tail++
    else regions.anywhere++
  }
  assert.ok(regions.recent > 1000 && regions.tail > 100 && regions.anywhere > 400, JSON.stringify(regions))
  assert.equal(newGesture(mulberry32(1), [extents[1]]), null)
})

test('the pointer stays inside the recording and turns around at its ends', () => {
  const rng = mulberry32(99)
  for (let n = 0; n < 200; n++) {
    const g = newGesture(rng, extents)
    for (let i = 0; i < g.ticks; i++) {
      const t = gestureTarget(g, extents[0], i)
      assert.ok(t >= extents[0].oldest && t <= extents[0].newest - 1_000, `tick ${i}: ${t}`)
    }
  }
  const g = { camera: 'A', startMs: extents[0].newest - 6_000, stepMs: 6_000, direction: 1, ticks: 10, tickMs: 40 }
  const path = Array.from({ length: 4 }, (_, i) => gestureTarget(g, extents[0], i))
  assert.ok(path[1] <= extents[0].newest - 1_000 && path[2] < path[1], JSON.stringify(path))
})
