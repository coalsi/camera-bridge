// What the soak does and when: the phase schedule, a seeded random generator and the way a scripted client picks where to scrub.
// Pure functions, so the schedule and the choices are the same on every run with the same seed.

// A small, fast, well-spread seeded generator. rng() is in [0, 1).
export function mulberry32(seed) {
  let a = seed >>> 0
  return function rng() {
    a = (a + 0x6D2B79F5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

// Phase kinds: 'off' (recording only: the baseline and the cool-down), 'load' (clients scrub in bursts with pauses and plays
// in between) and 'storm' (clients scrub without pause at the full rate).
// For the 2 h run: 10 min baseline, 20 min load, 10 min storm, 50 min load, 10 min storm, 10 min load, 10 min cool-down.
const SHAPE = [['warmup', 'off', 1], ['load', 'load', 2], ['storm1', 'storm', 1], ['load', 'load', 5], ['storm2', 'storm', 1], ['load', 'load', 1], ['cooldown', 'off', 1]]

export function buildPhases(totalSec) {
  if (!(totalSec >= 120)) throw new Error('a soak needs at least 120 seconds')
  const weight = SHAPE.reduce((sum, [, , w]) => sum + w, 0)
  const phases = []
  let from = 0
  SHAPE.forEach(([name, kind, w], i) => {
    const to = i === SHAPE.length - 1 ? totalSec : from + Math.round((totalSec * w) / weight)
    phases.push({ name, kind, from, to })
    from = to
  })
  return phases
}

export function phaseAt(phases, tSec) {
  return phases.find((p) => tSec >= p.from && tSec < p.to) ?? null
}

export const TICK_MS = 40   // 25 requests a second

// extents: [{ id, oldest, newest }] in server milliseconds. Returns where one drag starts and how fast it moves.
export function newGesture(rng, extents, { tickMs = TICK_MS } = {}) {
  const usable = extents.filter((e) => e.newest - e.oldest > 20_000)
  if (usable.length === 0) return null
  const camera = usable[Math.floor(rng() * usable.length)]
  const latest = camera.newest - 6_000          // the page plays 6 s behind the newest fragment
  const r = rng()
  let lo, hi
  if (r < 0.6) { lo = Math.max(camera.oldest, latest - 60_000); hi = latest }                                        // recent footage
  else if (r < 0.9) { lo = camera.oldest; hi = latest }                                                              // anywhere
  else { lo = camera.oldest; hi = Math.min(latest, camera.oldest + 30_000) }                                         // about to be deleted by retention
  const startMs = Math.round(lo + rng() * Math.max(0, hi - lo))
  const stepMs = Math.round(Math.exp(Math.log(100) + rng() * (Math.log(6_000) - Math.log(100))))   // 100 ms to 6 s of footage per 40 ms tick
  return { camera: camera.id, startMs, stepMs, direction: rng() < 0.5 ? -1 : 1, ticks: 75 + Math.floor(rng() * 175), tickMs }
}

// Where the pointer is after `i` ticks: moves by stepMs a tick and turns around at the ends of the recording.
export function gestureTarget(gesture, extent, i) {
  const lo = extent.oldest, hi = Math.max(lo + 1, extent.newest - 1_000)
  const span = hi - lo
  let offset = (gesture.startMs - lo) + gesture.direction * gesture.stepMs * i
  const period = 2 * span
  offset = ((offset % period) + period) % period
  if (offset > span) offset = period - offset
  return Math.round(lo + offset)
}
