// The spike's web server: the page, the fixtures and a results drop box, with the security headers the daemon will send
// (T00 C.8: the CSP including media-src 'self' blob:). No dependencies.
//   node server.mjs [--port 8099] [--lan [--lan-minutes N]] [--rate-mbps N] [--sample-cpu] [--verbose]
// Without --lan it listens on 127.0.0.1 only (a secure context when opened as 127.0.0.1: WebCodecs exist, which hides the box's plain-HTTP condition;
// a name mapped to 127.0.0.1 inside the browser, as in Chrome's --host-resolver-rules, is plain HTTP again).
// With --lan it listens on every interface so a phone, an iPad or another browser can open it by the Mac's LAN name. That is the LAN window of T00 A.3:
// it needs CB_SPIKE_LAN_YES set to the sentence below (only after the owner's yes in chat), and it stops itself after --lan-minutes (1 to 60, default 60).
import { execFile, execFileSync } from 'node:child_process'
import { once } from 'node:events'
import { createReadStream, existsSync, mkdirSync, readdirSync, renameSync, statSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { networkInterfaces, hostname } from 'node:os'
import { Readable } from 'node:stream'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))

export const LAN_YES = 'owner said yes in chat'

/** The rules for --lan (T00 A.3): the owner's yes, and a window of 1 to 60 minutes. Pure, so a test can check it. */
export function lanPolicy({ lan, lanMinutes }, env) {
  if (!lan) return { ok: true, minutes: 0 }
  if (env.CB_SPIKE_LAN_YES !== LAN_YES) {
    return { ok: false, message: "--lan serves the fixtures and takes result files from the whole local network: it needs the owner's yes in chat to that window (T00 A.3). Set CB_SPIKE_LAN_YES only after it." }
  }
  if (!(Number.isFinite(lanMinutes) && lanMinutes >= 1 && lanMinutes <= 60)) return { ok: false, message: '--lan-minutes must be 1...60' }
  return { ok: true, minutes: lanMinutes }
}

export const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; " +
  "font-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
// What the daemon sends today: the same without media-src, so default-src 'none' blocks blob: media. Served for /?csp=old to prove the change is needed.
export const CSP_OLD = CSP.replace("media-src 'self' blob:; ", '')

const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.mp4': 'video/mp4', '.m4s': 'video/mp4' }
const PAGE_FILE = /^\/(index\.html|spike\.js|spike\.css|lib\/[A-Za-z0-9-]+\.js|cases\/[A-Za-z0-9-]+\.js)$/
const FIXTURE_FILE = /^\/fx\/([A-Za-z0-9]{1,12})\/(init\.mp4|manifest\.json|[ps][0-9]{4}\.m4s)$/
const LABEL = /^[a-z0-9][a-z0-9-]{0,39}$/
const PHASE = /^[a-z0-9-]{1,30}$/
const MAX_RESULT_BYTES = 4_000_000
const MAX_SPEED_KIB = 16384

export function createSpikeServer({ root = HERE, outDir = join(HERE, 'out'), resultsDir = join(HERE, 'results'), rateMbps = 0,
  sampleCpu = false, verbose = false } = {}) {
  mkdirSync(resultsDir, { recursive: true })

  function headers(response, csp = CSP) {
    response.setHeader('Content-Security-Policy', csp)
    response.setHeader('X-Content-Type-Options', 'nosniff')
    response.setHeader('X-Frame-Options', 'DENY')
    response.setHeader('Referrer-Policy', 'no-referrer')
    response.setHeader('Cross-Origin-Opener-Policy', 'same-origin')
    response.setHeader('Cross-Origin-Resource-Policy', 'same-origin')
    response.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=(), usb=()')
    response.setHeader('Cache-Control', 'no-store')
  }

  function send(response, status, body = '', type = 'text/plain; charset=utf-8') {
    response.statusCode = status
    response.setHeader('Content-Type', type)
    response.setHeader('Content-Length', Buffer.byteLength(body))
    response.end(body)
  }

  // Sends a file or a buffer; with a rate limit the body leaves in 16 KiB pieces spaced to the chosen speed (to imitate Wi-Fi).
  async function sendBytes(response, size, type, open) {
    response.statusCode = 200
    response.setHeader('Content-Type', type)
    response.setHeader('Content-Length', size)
    const stream = open()
    if (!rateMbps) { stream.pipe(response); return }
    const bytesPerSecond = rateMbps * 125_000
    const started = performance.now()
    let sent = 0
    for await (const chunk of stream) {
      for (let at = 0; at < chunk.length; at += 16384) {
        if (response.destroyed) { stream.destroy(); return }
        const piece = chunk.subarray(at, at + 16384)
        if (!response.write(piece)) await once(response, 'drain')
        sent += piece.length
        const wait = started + (sent / bytesPerSecond) * 1000 - performance.now()
        if (wait > 1) await new Promise((resolve) => setTimeout(resolve, wait))
      }
    }
    response.end()
  }

  // Reads a request body of at most `limit` bytes. A longer one is drained (not stored) and refused with 413, so the client sees the answer.
  function readBody(request, limit) {
    return new Promise((resolve, reject) => {
      const chunks = []
      let total = 0
      request.on('data', (chunk) => {
        total += chunk.length
        if (total > 4 * limit) request.destroy()
        else if (total <= limit) chunks.push(chunk)
      })
      request.on('end', () => (total > limit ? reject(Object.assign(new Error('too large'), { status: 413 })) : resolve(Buffer.concat(chunks))))
      request.on('error', reject)
    })
  }

  async function post(request, response, path) {
    const result = path.match(/^\/results\/([^/]+)$/)
    if (result) {
      if (!LABEL.test(result[1])) return send(response, 400, 'bad label')
      let body
      try { body = await readBody(request, MAX_RESULT_BYTES) } catch (error) { return send(response, error.status ?? 400, 'too large') }
      let parsed
      try { parsed = JSON.parse(body.toString('utf8')) } catch { return send(response, 400, 'not JSON') }
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return send(response, 400, 'expected a JSON object')
      const target = join(resultsDir, `${result[1]}.json`)
      writeFileSync(`${target}.tmp`, body)
      renameSync(`${target}.tmp`, target)
      response.statusCode = 204
      return response.end()
    }
    const mark = path.match(/^\/mark\/([^/]+)\/([^/]+)$/)
    if (mark) {
      if (!LABEL.test(mark[1]) || !PHASE.test(mark[2])) return send(response, 400, 'bad label or phase')
      await readBody(request, 1000).catch(() => null)
      if (sampleCpu && process.platform === 'darwin') {
        // Six one-second samples of the busiest processes; the first block is an average since boot, the summary reads the last one.
        execFile('top', ['-l', '6', '-s', '1', '-n', '50', '-o', 'cpu', '-stats', 'pid,command,cpu,mem'], { timeout: 20_000 }, (error, stdout) => {
          if (!error) writeFileSync(join(resultsDir, `${mark[1]}-cpu-${mark[2]}.txt`), stdout)
        })
        return send(response, 202, 'sampling')
      }
      return send(response, 204)
    }
    return send(response, 404, 'not found')
  }

  return createServer(async (request, response) => {
    let url
    try { url = new URL(request.url, 'http://spike.invalid') } catch { return send(response, 400, 'bad url') }
    const path = url.pathname
    const old = path === '/' && url.searchParams.get('csp') === 'old'
    headers(response, old ? CSP_OLD : CSP)
    if (verbose) console.log(request.method, path)
    try {
      if (request.method === 'POST') return await post(request, response, path)
      if (request.method !== 'GET') { response.setHeader('Allow', 'GET, POST'); return send(response, 405, 'method not allowed') }

      if (path === '/api/ping') return send(response, 200, JSON.stringify({ t: Date.now() }), TYPES['.json'])
      if (path === '/api/speed') {
        const kib = Number(url.searchParams.get('kb') ?? '1024')
        if (!Number.isInteger(kib) || kib < 1 || kib > MAX_SPEED_KIB) return send(response, 400, 'kb must be 1...16384')
        const bytes = Buffer.alloc(kib * 1024)
        return await sendBytes(response, bytes.length, 'application/octet-stream', () => Readable.from([bytes]))
      }
      if (path === '/fx/index.json') {
        const fixtures = existsSync(outDir) ? readdirSync(outDir).filter((id) => /^[A-Za-z0-9]{1,12}$/.test(id) && existsSync(join(outDir, id, 'manifest.json'))).sort() : []
        return send(response, 200, JSON.stringify({ fixtures }), TYPES['.json'])
      }
      const fixture = path.match(FIXTURE_FILE)
      if (fixture) {
        const file = join(outDir, fixture[1], fixture[2])
        if (!existsSync(file)) return send(response, 404, 'no such fixture file')
        return await sendBytes(response, statSync(file).size, TYPES[fixture[2].slice(fixture[2].lastIndexOf('.'))], () => createReadStream(file))
      }
      const pagePath = path === '/' ? '/index.html' : path
      if (PAGE_FILE.test(pagePath)) {
        const file = join(root, pagePath)
        if (!existsSync(file)) return send(response, 404, 'not found')
        return await sendBytes(response, statSync(file).size, TYPES[pagePath.slice(pagePath.lastIndexOf('.'))], () => createReadStream(file))
      }
      return send(response, 404, 'not found')
    } catch (error) {
      if (!response.headersSent) send(response, 500, 'server error')
      else response.destroy()
      if (verbose) console.error(error)
    }
  })
}

function lanNames() {
  const names = []
  if (process.platform === 'darwin') {
    try { names.push(`${execFileSync('scutil', ['--get', 'LocalHostName'], { encoding: 'utf8' }).trim()}.local`) } catch { /* no Bonjour name */ }
  }
  if (!names.length && hostname().endsWith('.local')) names.push(hostname())
  for (const list of Object.values(networkInterfaces())) {
    for (const address of list ?? []) if (address.family === 'IPv4' && !address.internal) names.push(address.address)
  }
  return names
}

function main(argv) {
  const options = { port: 8099, lan: false, lanMinutes: 60, rateMbps: 0, sampleCpu: false, verbose: false }
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--lan') options.lan = true
    else if (arg === '--lan-minutes') options.lanMinutes = Number(argv[++i])
    else if (arg === '--sample-cpu') options.sampleCpu = true
    else if (arg === '--verbose') options.verbose = true
    else if (arg === '--port') options.port = Number(argv[++i])
    else if (arg === '--rate-mbps') options.rateMbps = Number(argv[++i])
    else { console.error(`unknown option ${arg}`); process.exit(2) }
  }
  if (!Number.isInteger(options.port) || options.port < 1024 || options.port > 65535) { console.error('--port must be 1024...65535'); process.exit(2) }
  const policy = lanPolicy(options, process.env)
  if (!policy.ok) { console.error(policy.message); process.exit(2) }
  const server = createSpikeServer({ rateMbps: options.rateMbps, sampleCpu: options.sampleCpu, verbose: options.verbose,
    outDir: process.env.CB_SPIKE_OUT ?? join(HERE, 'out'), resultsDir: process.env.CB_SPIKE_RESULTS ?? join(HERE, 'results') })
  const host = options.lan ? '0.0.0.0' : '127.0.0.1'
  server.listen(options.port, host, () => {
    console.log(`spike server on ${host}:${options.port}${options.rateMbps ? `, limited to ${options.rateMbps} Mbit/s` : ''}`)
    if (options.lan) {
      console.log(`Serving the fixtures to the whole local network for at most ${policy.minutes} minutes. Stop it (Ctrl-C) when the tests are done.`)
      setTimeout(() => { console.log('The LAN window is over: the server stops.'); process.exit(0) }, policy.minutes * 60_000)
      for (const name of lanNames()) console.log(`  http://${name}:${options.port}/?label=<class>`)
    } else {
      console.log(`  http://127.0.0.1:${options.port}/   (127.0.0.1 is a secure context: for the real test use a name the browser maps to 127.0.0.1, or --lan after the owner's yes)`)
    }
  })
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main(process.argv.slice(2))
