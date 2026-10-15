// A stand-in for the bridge, for the soak tools' own tests: it answers only the routes the tools call (T00 C.5), from a synthetic
// recording that has existed for `footageMs` and grows with the clock. It is NOT the dev server of T07 and says nothing about the real
// daemon; it exists so that the tools can be tested before there is a daemon to point them at, and so a test can make the server slow,
// busy, gappy, forgetful or wrong on purpose.
import http from 'node:http'
import { createHash } from 'node:crypto'

const FRAGMENT_MS = 2500
const FRAGMENTS_PER_FILE = 360
const MOOF_BYTES = 1100

function fnv12(text) {
  let hash = 0xcbf29ce484222325n
  for (const byte of Buffer.from(text)) { hash ^= BigInt(byte); hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn }
  return hash.toString(16).padStart(16, '0').slice(0, 12)
}
function box(type, size) { const b = Buffer.alloc(size); b.writeUInt32BE(size, 0); b.write(type, 4, 'latin1'); return b }

export async function startFixture(options = {}) {
  const knobs = {
    footageMs: 3_600_000, fragmentBytes: 200_000, latencyMs: 1, maxInFlight: 6, failRate: 0, goneBeforeMs: 0, retentionMs: Infinity,
    gaps: [], healthDelayMs: 0, cameras: 2, setCSRF: 'csrf-token', eventsEveryMs: 0, eventStatus: null, freeBytes: 5e10, storageDelayMs: 0, ...options,
  }
  const startedAt = knobs.startedAt ?? Date.now() - knobs.footageMs
  const stats = { requests: 0, byRoute: {}, busy: 0, maxInFlight: 0, inFlight: 0, bytesSent: 0 }
  const cameras = []
  for (let i = 0; i < knobs.cameras; i++) cameras.push({ id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, '0')}`, name: `Camera ${i + 1}`, nvrEnabled: true })
  const segment = box('moof', MOOF_BYTES)
  const mdat = box('mdat', Math.max(16, knobs.fragmentBytes - MOOF_BYTES))
  const segmentBody = Buffer.concat([segment, mdat])
  const initBody = Buffer.concat([box('ftyp', 32), box('moov', 700)])
  const keys = new Map()   // fileKey -> { camera, file }

  const newestN = () => Math.floor((Date.now() - 500 - startedAt) / FRAGMENT_MS) - 1   // the newest whole fragment ends 0.5 to 3 s ago, like a recorder's edge
  const oldestN = () => Math.max(Math.ceil((knobs.goneBeforeMs - startedAt) / FRAGMENT_MS), Math.ceil((Date.now() - knobs.retentionMs - startedAt) / FRAGMENT_MS), 0)
  const startOf = (n) => startedAt + n * FRAGMENT_MS
  const inGap = (n) => knobs.gaps.some(([a, b]) => startOf(n) < b && startOf(n) + FRAGMENT_MS > a)
  function idOf(camera, n) {
    const file = Math.floor(n / FRAGMENTS_PER_FILE)
    const key = fnv12(`${camera.id}/${file}`)
    keys.set(key, { camera, file })
    return `${key}.${n % FRAGMENTS_PER_FILE}`
  }
  function nOf(camera, id) {
    const m = /^([0-9a-f]{12})\.(0|[1-9][0-9]{0,6})$/.exec(id)
    const hit = m && keys.get(m[1])
    if (!hit || hit.camera !== camera) return null
    return hit.file * FRAGMENTS_PER_FILE + Number(m[2])
  }
  const partOf = (camera, n) => ({ id: idOf(camera, n), file: idOf(camera, n).split('.')[0], start: startOf(n), end: startOf(n) + FRAGMENT_MS, bytes: knobs.fragmentBytes - 32, key: true })
  const fileInfo = (camera, n) => {
    const id = idOf(camera, Math.floor(n / FRAGMENTS_PER_FILE) * FRAGMENTS_PER_FILE)
    return [id.split('.')[0], { mime: 'video/mp4; codecs="avc1.4d0032"', width: 2688, height: 1520, anchor: startedAt + Math.floor(n / FRAGMENTS_PER_FILE) * FRAGMENTS_PER_FILE * FRAGMENT_MS + 0.25, initId: id, sound: false }]
  }

  function json(res, status, body, headers = {}) {
    const text = JSON.stringify(body)
    res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'content-length': Buffer.byteLength(text), ...headers })
    res.end(text)
  }
  const error = (res, status, code, message, headers) => json(res, status, { error: code, message }, headers)
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

  const server = http.createServer(async (req, res) => {
    stats.requests++
    const url = new URL(req.url, 'http://x')
    const path = url.pathname.replace(/^\/api\/v1\//, '')
    const routeKey = path.replace(/[0-9a-f-]{36}/g, ':id').replace(/[0-9a-f]{12}\.\d+/g, ':fid')
    stats.byRoute[routeKey] = (stats.byRoute[routeKey] ?? 0) + 1
    try {
      if (path === 'session') return json(res, 200, { authenticated: /cb_session=fixture/.test(req.headers.cookie ?? ''), setupRequired: false, setupTokenRequired: false })
      if (path === 'status') return json(res, 200, { product: 'Fixture', setupRequired: false, authenticated: /cb_session=fixture/.test(req.headers.cookie ?? '') })
      if (path === 'health') { if (knobs.healthDelayMs) await sleep(knobs.healthDelayMs); return json(res, 200, { ok: true, state: 'running' }) }
      if (req.method === 'POST' && (path === 'auth/setup' || path === 'auth/login')) {
        let body = ''
        for await (const chunk of req) body += chunk
        if (!JSON.parse(body || '{}').password) return error(res, 400, 'invalid', 'password')
        return json(res, path === 'auth/setup' ? 201 : 200, { csrfToken: knobs.setCSRF, bridgeName: 'Fixture' }, { 'set-cookie': 'cb_session=fixture; HttpOnly; SameSite=Strict; Path=/' })
      }
      if (!/cb_session=fixture/.test(req.headers.cookie ?? '')) return error(res, 401, 'unauthorized', 'Sign in.')
      if (req.method !== 'GET') {
        if (req.headers['x-csrf-token'] !== knobs.setCSRF) return error(res, 403, 'csrf', 'csrf')
        let body = ''
        for await (const chunk of req) body += chunk
        const data = JSON.parse(body || '{}')
        if (path === 'cameras') {
          const camera = { id: `00000000-0000-4000-8000-${String(cameras.length + 1).padStart(12, '0')}`, name: data.name ?? 'Camera', nvrEnabled: false }
          cameras.push(camera)
          return json(res, 201, camera)
        }
        let m = /^cameras\/([^/]+)\/nvr$/.exec(path)
        if (m && req.method === 'PATCH') {
          const camera = cameras.find((c) => c.id === m[1])
          if (!camera) return error(res, 404, 'not_found', 'no camera')
          if (typeof data.enabled === 'boolean') camera.nvrEnabled = data.enabled
          return json(res, 200, { ...camera, status: { nvr: { state: camera.nvrEnabled ? 'recording' : 'off', detail: null, pause: null, notes: [] } } })
        }
        if (path === 'nvr/storage' && req.method === 'PATCH') return json(res, 200, storage())
        return error(res, 404, 'not_found', 'no route')
      }
      if (path === 'events') {
        res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-store' })
        res.write('retry: 3000\n\n')
        // `eventStatus(camera, n)` (a knob) gives the status a camera event carries; n is 0 for the snapshot a new listener gets and counts the ticks after it.
        const payload = (c, n) => JSON.stringify({ id: c.id, ...(knobs.eventStatus ? { status: knobs.eventStatus(c, n) } : {}) })
        for (const c of cameras) res.write(`event: camera\ndata: ${payload(c, 0)}\n\n`)   // the snapshot a new listener gets
        let tick = 0
        const timer = knobs.eventsEveryMs && cameras[0] ? setInterval(() => res.write(`event: camera\ndata: ${payload(cameras[0], ++tick)}\n\n`), knobs.eventsEveryMs) : null
        req.on('close', () => clearInterval(timer))
        return
      }
      if (path === 'cameras') return json(res, 200, { cameras: cameras.map((c) => ({ ...c, status: { connection: 'online', nvr: { state: c.nvrEnabled ? 'recording' : 'off', detail: null, pause: null, notes: [] } } })) })
      if (path === 'nvr/storage') return json(res, 200, storage())
      if (path === 'nvr/cameras') {
        return json(res, 200, { serverTime: Date.now(), catalogVersion: Math.floor(Date.now() / 1000), cameras: cameras.filter((c) => c.nvrEnabled).map((c) => ({ id: c.id, oldest: startOf(oldestN()), newest: startOf(newestN()) + FRAGMENT_MS, typicalGOP: 2 })) })
      }
      // ---- archive routes: admission first ----
      const archive = path === 'nvr/activity' || /^nvr\/cameras\/[^/]+\/(fragments|keyframe)/.test(path)
      if (!archive) return error(res, 404, 'not_found', 'no route')
      if (stats.inFlight >= knobs.maxInFlight) { stats.busy++; return error(res, 429, 'busy', 'Busy.', { 'retry-after': '1' }) }
      stats.inFlight++
      stats.maxInFlight = Math.max(stats.maxInFlight, stats.inFlight)
      try {
        await sleep(knobs.latencyMs)
        if (knobs.failRate && Math.random() < knobs.failRate) return error(res, 500, 'internal', 'Fixture failure.')
        return await archiveRoute(req, res, url, path)
      } finally { stats.inFlight-- }
    } catch (e) {
      if (!res.headersSent) error(res, 500, 'internal', String(e.message))
      else res.destroy()
    }
  })

  const bootedAt = Date.now()
  function storage() {
    if (Date.now() - bootedAt < knobs.storageDelayMs) return { location: 'builtin', label: 'Fixture', state: 'ok', message: null, recordingCameras: 0, keepDays: 7, maxSizeGB: 20, limits: { keepDays: [1, 365], maxSizeGB: [10, 100000] }, usedBytes: 0, freeBytes: 0, totalBytes: 0, floorBytes: 0, roomBytes: 0, effectiveMaxBytes: 0, oldest: null, newest: null }   // before the first measurement
    return { location: 'builtin', label: 'Fixture', state: 'ok', message: null, recordingCameras: cameras.filter((c) => c.nvrEnabled).length, keepDays: 7, maxSizeGB: 20,
      limits: { keepDays: [1, 365], maxSizeGB: [10, 100000] }, usedBytes: 1e9, freeBytes: knobs.freeBytes, totalBytes: 1e11, floorBytes: 8e9, roomBytes: 4e10, effectiveMaxBytes: 2e10,
      oldest: startOf(oldestN()), newest: startOf(newestN()) + FRAGMENT_MS }
  }

  async function archiveRoute(req, res, url, path) {
    if (path === 'nvr/activity') {
      const bins = Number(url.searchParams.get('bins')), by = {}
      for (const id of (url.searchParams.get('cameras') ?? '').split(',')) by[id] = { typical: 1000, complete: true, coverage: Array(bins).fill(100), level: Array(bins).fill(900) }
      return json(res, 200, { from: Number(url.searchParams.get('from')), binMs: Number(url.searchParams.get('binMs')), bins, serverTime: Date.now(), catalogVersion: 1, byCamera: by })
    }
    const m = /^nvr\/cameras\/([^/]+)\/(fragments(?:\/([^/]+)(\/init)?)?|keyframe)$/.exec(path)
    const camera = m && cameras.find((c) => c.id === m[1])
    if (!camera) return error(res, 404, 'not_found', 'no camera')
    const fid = m[3], isInit = Boolean(m[4])
    if (m[2] === 'keyframe' || (!fid && url.searchParams.has('at'))) {
      const at = Number(url.searchParams.get('at'))
      if (!Number.isInteger(at)) return error(res, 400, 'invalid', 'at')
      const n = Math.floor((at - startedAt) / FRAGMENT_MS)
      if (n < oldestN() || n > newestN() || inGap(n)) {
        const next = n < oldestN() ? startOf(oldestN()) : null
        if (m[2] === 'keyframe') return error(res, 404, 'gap', 'No recording at that time.', next ? { 'x-cb-next': String(next) } : {})
        return json(res, 200, { serverTime: Date.now(), found: false, at, reason: n < oldestN() ? 'beforeStart' : n > newestN() ? 'afterEnd' : 'gap', next, newest: startOf(newestN()) + FRAGMENT_MS })
      }
      if (m[2] === 'keyframe') {
        const [file, info] = fileInfo(camera, n)
        const header = JSON.stringify({ id: idOf(camera, n), file, start: startOf(n), end: startOf(n) + FRAGMENT_MS, mime: info.mime, width: info.width, height: info.height, anchor: info.anchor, initId: info.initId })
        res.writeHead(200, { 'content-type': 'video/mp4', 'cache-control': 'no-store', 'content-length': segmentBody.length, 'x-cb-part': header })
        stats.bytesSent += segmentBody.length
        return res.end(segmentBody)
      }
      const ahead = Number(url.searchParams.get('ahead') ?? 2)
      const parts = [], files = {}
      for (let k = n; k <= Math.min(newestN(), n + ahead); k++) { parts.push(partOf(camera, k)); const [f, i] = fileInfo(camera, k); files[f] = i }
      return json(res, 200, { serverTime: Date.now(), found: true, at, exact: true, targetIndex: 0, parts, files })
    }
    if (!fid && url.searchParams.has('after')) {
      const after = nOf(camera, url.searchParams.get('after'))
      if (after === null || after < oldestN()) return error(res, 410, 'gone', 'That recording was removed.')
      const limit = Number(url.searchParams.get('limit') ?? 8), parts = [], files = {}
      for (let k = after + 1; k <= Math.min(newestN(), after + limit); k++) { parts.push(partOf(camera, k)); const [f, i] = fileInfo(camera, k); files[f] = i }
      return json(res, 200, { serverTime: Date.now(), parts, files })
    }
    if (fid) {
      const n = nOf(camera, fid)
      if (n === null || n < oldestN()) return error(res, 410, 'gone', 'That recording was removed.')
      const body = isInit ? initBody : segmentBody
      res.writeHead(200, { 'content-type': 'video/mp4', 'cache-control': 'no-store', 'content-length': body.length })
      stats.bytesSent += body.length
      return res.end(body)
    }
    return error(res, 400, 'invalid', 'mode')
  }

  await new Promise((resolve) => server.listen(options.port ?? 0, '127.0.0.1', resolve))
  const port = server.address().port
  return {
    port, url: `http://127.0.0.1:${port}`, stats, knobs, cameras,
    close: () => new Promise((resolve) => { server.closeAllConnections(); server.close(resolve) }),
  }
}
