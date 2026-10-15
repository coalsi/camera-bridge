// HTTP to the bridge for the soak tools: keep-alive connections, one timing per request, the session cookie and CSRF token from a file.
// A request never throws and never aborts on its own account: a socket error or a timeout comes back as `netError` for the caller to count.
// One exception, and it is counted (`retried`): a GET that finds its kept-alive connection closed by the server before a single byte came back is sent
// once more, on a NEW connection (not another pooled one, which may be just as stale). That is the ordinary keep-alive race (the server closes an idle connection
// after 30 s, or after its 1,000th request, just as the next request is written), and a browser does the same; a connection that fails in any other way, or in the
// middle of an answer, or a new connection that is reset, is an error.
import http from 'node:http'
import fs from 'node:fs'
import { performance } from 'node:perf_hooks'

// The session file is written by prepare.mjs with mode 0600: { "cookie": "name=value; ...", "csrf": "..." }. Never printed.
export function loadSession(file) {
  const session = JSON.parse(fs.readFileSync(file, 'utf8'))
  if (typeof session.cookie !== 'string' || typeof session.csrf !== 'string') throw new Error('the session file has no cookie or csrf')
  return session
}

// `GET /api/v1/cameras` answers { "cameras": [...] } (WebApp+Routes.swift listCameras); an array is accepted too.
export function cameraList(json) { return Array.isArray(json) ? json : Array.isArray(json?.cameras) ? json.cameras : null }

export function createHttp({ base, session, maxSockets = 8, localAddress, timeoutMs = 60_000 }) {
  const url = new URL(base)
  const agent = new http.Agent({ keepAlive: true, maxSockets })

  // collect: 'json' (whole body parsed), 'text', 'media' (count the bytes, keep the first headLimit) or 'discard'. A status other than 200
  // always keeps the whole body (small JSON errors) so the caller can read the error code.
  async function request(method, path, options = {}) {
    const first = await attempt(method, path, options, false)
    if (method === 'GET' && first.staleSocket) {
      const second = await attempt(method, path, options, true)
      return { ...second, ms: first.ms + second.ms, retried: true }
    }
    return first
  }

  function attempt(method, path, { body, collect = 'json', headLimit = 262_144, headers = {} } = {}, fresh = false) {
    return new Promise((resolve) => {
      const started = performance.now()
      const payload = body === undefined ? null : Buffer.from(JSON.stringify(body))
      let settled = false
      const finish = (result) => { if (settled) return; settled = true; resolve({ ms: performance.now() - started, ...result }) }
      let gotResponse = false
      const request = http.request({
        host: url.hostname, port: url.port, method, path, agent: fresh ? false : agent, localAddress,
        headers: {
          cookie: session?.cookie ?? '', accept: '*/*',
          ...(payload ? { 'content-type': 'application/json', 'content-length': payload.length, origin: url.origin, 'x-csrf-token': session?.csrf ?? '' } : {}),
          ...headers,
        },
      }, (res) => {
        gotResponse = true
        const chunks = []
        let bytes = 0, kept = 0
        const keepAll = collect === 'json' || collect === 'text' || res.statusCode !== 200
        const limit = keepAll ? 4 * 1024 * 1024 : (collect === 'media' ? headLimit : 0)
        res.on('data', (chunk) => {
          bytes += chunk.length
          const room = limit - kept
          if (room > 0) { const piece = chunk.length > room ? chunk.subarray(0, room) : chunk; chunks.push(piece); kept += piece.length }
        })
        res.on('end', () => {
          const buffer = Buffer.concat(chunks)
          const result = { status: res.statusCode, headers: res.headers, bytes }
          if (keepAll) {
            const text = buffer.toString('utf8')
            result.text = text
            if (collect === 'json' || res.headers['content-type']?.includes('json')) { try { result.json = JSON.parse(text) } catch { result.jsonError = true } }
          } else if (collect === 'media') {
            result.head = buffer
          }
          finish(result)
        })
        res.on('close', () => { if (!res.complete) finish({ status: res.statusCode, headers: res.headers, bytes, netError: 'closed' }) })
        res.on('error', (e) => finish({ status: 0, bytes, netError: e.code ?? e.message }))
      })
      request.setTimeout(timeoutMs, () => request.destroy(Object.assign(new Error('timeout'), { code: 'ETIMEDOUT' })))
      request.on('error', (e) => finish({ status: 0, bytes: 0, netError: e.code ?? e.message, staleSocket: request.reusedSocket === true && !gotResponse && ['ECONNRESET', 'EPIPE'].includes(e.code) }))
      request.end(payload)
    })
  }

  return { request, base: url.origin, close: () => agent.destroy() }
}

// Signs in (or, on a new bridge, sets the password) and returns { cookie, csrf }. `password` and the setup code come from files the caller read.
export async function signIn(base, { password, setupToken, bridgeName = 'Soak', setup = false }) {
  const client = createHttp({ base, session: null, maxSockets: 1, timeoutMs: 20_000 })
  try {
    const body = setup ? { password, bridgeName, ...(setupToken ? { setupToken } : {}) } : { password }
    const result = await client.request('POST', setup ? '/api/v1/auth/setup' : '/api/v1/auth/login', { body })
    // First-run setup answers 201 (Created), sign-in 200.
    if (![200, 201].includes(result.status) || !result.json?.csrfToken) throw new Error(`sign-in failed: HTTP ${result.status || result.netError} ${result.json?.error ?? ''}`)
    const cookies = [].concat(result.headers['set-cookie'] ?? []).map((c) => c.split(';')[0]).join('; ')
    if (!cookies) throw new Error('sign-in gave no session cookie')
    return { cookie: cookies, csrf: result.json.csrfToken }
  } finally { client.close() }
}
