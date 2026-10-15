// Shape checks for what the archive routes answer (T00 C.5). Each returns null when the answer is right, else a short reason.
// They look at structure only: they cannot tell that the pictures are the right pictures (the Node conformance tool and the engine tests do that).

const FRAGMENT_ID = /^[0-9a-f]{12}\.(0|[1-9][0-9]{0,6})$/
const REASONS = new Set(['empty', 'beforeStart', 'gap', 'afterEnd'])

// The top-level boxes of an mp4 whose first bytes are `head`; the last box may run past `head`.
export function topBoxes(head, total) {
  const boxes = []
  let offset = 0
  while (offset + 8 <= head.length && offset < total) {
    let size = head.readUInt32BE(offset)
    const type = head.toString('latin1', offset + 4, offset + 8)
    if (size === 1) {
      if (offset + 16 > head.length) break
      size = Number(head.readBigUInt64BE(offset + 8))
    } else if (size === 0) {
      size = total - offset
    }
    if (size < 8) return { boxes, error: `a ${type} box at ${offset} claims ${size} bytes` }
    boxes.push({ type, size, offset })
    offset += size
  }
  return { boxes, error: null }
}

// `fragments/:fid` and `keyframe`: moof then mdat, the two exactly filling the answer.
export function checkSegment(head, total) {
  if (total < 16) return `only ${total} bytes`
  const { boxes, error } = topBoxes(head, total)
  if (error) return error
  if (boxes.length < 2) return `the first ${head.length} bytes hold ${boxes.length} box(es); the moof is larger than the part kept for checking`
  if (boxes[0].type !== 'moof' || boxes[1].type !== 'mdat') return `boxes ${boxes.map((b) => b.type).join(',')}, wanted moof,mdat`
  if (boxes[0].size + boxes[1].size !== total) return `moof ${boxes[0].size} + mdat ${boxes[1].size} is not ${total}`
  if (boxes[1].size <= 8) return 'an empty mdat'
  return null
}

// `fragments/:fid/init`: ftyp then moov filling the answer.
export function checkInit(head, total) {
  if (total < 16) return `only ${total} bytes`
  const { boxes, error } = topBoxes(head, total)
  if (error) return error
  if (boxes.length < 2) return 'ftyp and moov are not both in the part kept for checking'
  if (boxes[0].type !== 'ftyp' || boxes[1].type !== 'moov') return `boxes ${boxes.map((b) => b.type).join(',')}, wanted ftyp,moov`
  if (boxes[0].size + boxes[1].size !== total) return `ftyp ${boxes[0].size} + moov ${boxes[1].size} is not ${total}`
  return null
}

// The X-CB-Part header of `keyframe`.
export function checkPartHeader(text) {
  let part
  try { part = JSON.parse(text) } catch { return 'X-CB-Part is not JSON' }
  for (const key of ['id', 'file', 'start', 'end', 'mime', 'width', 'height', 'anchor', 'initId']) if (!(key in part)) return `X-CB-Part has no ${key}`
  if (!FRAGMENT_ID.test(part.id) || !FRAGMENT_ID.test(part.initId)) return 'X-CB-Part ids are not fragment ids'
  if (!part.id.startsWith(`${part.file}.`)) return 'X-CB-Part id does not start with its file'
  if (!Number.isInteger(part.start) || !Number.isInteger(part.end) || part.end <= part.start) return 'X-CB-Part start/end are wrong'
  if (typeof part.mime !== 'string' || !part.mime.startsWith('video/mp4; codecs="')) return 'X-CB-Part mime is wrong'
  if (!(part.width > 0) || !(part.height > 0) || typeof part.anchor !== 'number') return 'X-CB-Part size or anchor is wrong'
  return null
}

// `fragments?at=` (mode at) and `fragments?after=` (mode after).
export function checkPlan(plan) {
  if (typeof plan !== 'object' || plan === null) return 'not an object'
  if (typeof plan.serverTime !== 'number') return 'no serverTime'
  if (plan.found === false) {
    if (!REASONS.has(plan.reason)) return `reason ${plan.reason}`
    return null
  }
  if (plan.found !== true) return 'found is neither true nor false'
  return checkParts(plan.parts, plan.files, true) ?? ((Number.isInteger(plan.targetIndex) && plan.targetIndex >= 0 && plan.targetIndex < plan.parts.length) ? null : 'targetIndex is outside parts')
}

export function checkAfter(answer) {
  if (typeof answer !== 'object' || answer === null || typeof answer.serverTime !== 'number') return 'no serverTime'
  return checkParts(answer.parts, answer.files, false)
}

function checkParts(parts, files, nonEmpty) {
  if (!Array.isArray(parts)) return 'parts is not an array'
  if (nonEmpty && parts.length === 0) return 'parts is empty'
  if (typeof files !== 'object' || files === null) return 'no files'
  let previousEnd = -Infinity
  for (const part of parts) {
    if (!FRAGMENT_ID.test(part.id) || !part.id.startsWith(`${part.file}.`)) return `bad part id ${part.id}`
    if (!Number.isInteger(part.start) || !Number.isInteger(part.end) || part.end <= part.start) return `bad part times in ${part.id}`
    if (part.start < previousEnd - 1_000) return `parts overlap at ${part.id}`
    previousEnd = part.end
    if (typeof part.bytes !== 'number' || part.bytes < 0 || typeof part.key !== 'boolean') return `bad bytes or key in ${part.id}`
    const info = files[part.file]
    if (!info || typeof info.mime !== 'string' || !FRAGMENT_ID.test(info.initId ?? '')) return `no file info for ${part.file}`
  }
  return null
}

export function checkCameras(answer) {
  if (typeof answer !== 'object' || answer === null) return 'not an object'
  if (typeof answer.serverTime !== 'number' || !Number.isInteger(answer.catalogVersion) || !Array.isArray(answer.cameras)) return 'missing serverTime, catalogVersion or cameras'
  for (const c of answer.cameras) if (typeof c.id !== 'string' || !(c.newest >= c.oldest)) return `bad extent for ${c.id}`
  return null
}

export function checkActivity(answer, bins) {
  if (typeof answer !== 'object' || answer === null || typeof answer.byCamera !== 'object') return 'no byCamera'
  if (answer.bins !== bins) return `bins ${answer.bins}, asked ${bins}`
  for (const [id, a] of Object.entries(answer.byCamera)) {
    if (a.coverage?.length !== bins || a.level?.length !== bins) return `${id}: arrays are not ${bins} long`
  }
  return null
}
