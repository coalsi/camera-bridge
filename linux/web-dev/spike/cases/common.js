import { lumaMean, seekAndPresent } from '../lib/present.js'
import { Surface } from '../lib/surface.js'

/** A fresh surface on the stage video with the fixture's mime and init segment appended at `offsetSec` on the video timeline. */
export async function openFixture(ctx, fx, { offsetSec = 0, mime = fx.mime, init = true } = {}) {
  const surface = ctx.track(new Surface({ video: ctx.video, managed: ctx.managed, attach: ctx.attach }))
  await surface.open(mime)
  surface.setOffset(offsetSec)
  if (init) {
    await surface.append(await fx.init())
    await surface.metadata()
  }
  return surface
}

/** Appends fixture parts from..to (inclusive) in order. */
export async function appendParts(surface, fx, from, to) {
  for (let i = from; i <= to; i++) await surface.append(await fx.part(i))
}

/** How many frames the shown picture is away from the expected one (null when it cannot be told). */
export function errorFrames(result, expect, fx) {
  if (result.observedN !== null && expect.barcodeN !== undefined) return result.observedN - expect.barcodeN
  if (result.observedMediaTime !== null) return Math.round((result.observedMediaTime - expect.mediaTime) / fx.frameSec)
  return null
}

/**
 * Seeks to fixture time `fixtureSec` (the fixture sits at `offsetSec` on the video timeline) and waits for the right picture.
 * Adds the expected frame, the error in frames and whether the picture is not black.
 */
export async function seekTo(ctx, fx, offsetSec, fixtureSec, { timeoutMs = 1500 } = {}) {
  const expect = fx.expectAt(fixtureSec, offsetSec)
  const result = await seekAndPresent(ctx.video, offsetSec + fixtureSec, { expect, canvas: ctx.canvas, timeoutMs })
  const luma = result.ok ? lumaMean(ctx.video) : null
  return { ...result, expect, errorFrames: errorFrames(result, expect, fx), luma: luma === null ? null : Math.round(luma), notBlack: luma === null ? null : luma > 8 }
}

export const round1 = (x) => Math.round(x * 10) / 10
export const pct = (n, total) => (total === 0 ? 0 : Math.round((n / total) * 1000) / 10)

/** Deterministic pick of `count` distinct entries from `list`. */
export function pick(list, count, random) {
  const copy = [...list]
  const out = []
  while (out.length < count && copy.length > 0) out.push(copy.splice(Math.floor(random() * copy.length), 1)[0])
  return out
}
