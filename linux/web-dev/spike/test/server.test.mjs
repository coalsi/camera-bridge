import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, before, test } from 'node:test'
import { CSP, CSP_OLD, LAN_YES, createSpikeServer, lanPolicy } from '../server.mjs'

let tmp, server, base

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'cb-spike-server-'))
  mkdirSync(join(tmp, 'out', 'bar'), { recursive: true })
  mkdirSync(join(tmp, 'results'))
  writeFileSync(join(tmp, 'out', 'bar', 'manifest.json'), JSON.stringify({ id: 'bar', parts: [] }))
  writeFileSync(join(tmp, 'out', 'bar', 'init.mp4'), Buffer.from('init-bytes'))
  writeFileSync(join(tmp, 'out', 'bar', 'p0000.m4s'), Buffer.alloc(300000, 7))
  writeFileSync(join(tmp, 'secret.txt'), 'must never be served')
  mkdirSync(join(tmp, 'page', 'lib'), { recursive: true })
  mkdirSync(join(tmp, 'page', 'cases'))
  for (const file of ['index.html', 'spike.js', 'spike.css', 'lib/pure.js', 'cases/c01.js']) writeFileSync(join(tmp, 'page', file), `// ${file}\n`)
  server = createSpikeServer({ root: join(tmp, 'page'), outDir: join(tmp, 'out'), resultsDir: join(tmp, 'results') })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${server.address().port}`
})
after(() => { server.close(); rmSync(tmp, { recursive: true, force: true }) })

test('the CSP is exactly the one the daemon will send (T00 C.8), and the old one lacks only media-src', () => {
  assert.equal(CSP, "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; " +
    "font-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
  assert.equal(CSP_OLD, CSP.replace("media-src 'self' blob:; ", ''))
  assert.equal(CSP.includes('unsafe-inline') || CSP.includes('unsafe-eval'), false)
})

test('every answer carries the daemon security headers', async () => {
  for (const path of ['/', '/spike.js', '/fx/bar/manifest.json', '/api/ping']) {
    const response = await fetch(base + path)
    assert.equal(response.status, 200, path)
    assert.equal(response.headers.get('content-security-policy'), CSP, path)
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff', path)
    assert.equal(response.headers.get('cache-control'), 'no-store', path)
    assert.equal(response.headers.get('cross-origin-resource-policy'), 'same-origin', path)
    assert.equal(response.headers.get('referrer-policy'), 'no-referrer', path)
    await response.arrayBuffer()
  }
  const old = await fetch(base + '/?csp=old')
  assert.equal(old.headers.get('content-security-policy'), CSP_OLD)
  await old.arrayBuffer()
})

test('content types: modules are javascript, fragments are video/mp4', async () => {
  const js = await fetch(base + '/spike.js')
  assert.match(js.headers.get('content-type'), /^text\/javascript/)
  await js.arrayBuffer()
  const fragment = await fetch(base + '/fx/bar/p0000.m4s')
  assert.equal(fragment.headers.get('content-type'), 'video/mp4')
  assert.equal(Number(fragment.headers.get('content-length')), 300000)
  assert.equal((await fragment.arrayBuffer()).byteLength, 300000)
})

test('only the allowed files are served; traversal and other methods are refused', async () => {
  for (const path of ['/secret.txt', '/../secret.txt', '/%2e%2e/secret.txt', '/fx/bar/../../secret.txt', '/fx/../secret.txt', '/fx/bar/other.txt',
    '/fx/BAR!/manifest.json', '/results/x.json', '/server.mjs', '/lib/../server.mjs', '/test/server.test.mjs']) {
    const response = await fetch(base + path)
    assert.ok([400, 404].includes(response.status), `${path} gave ${response.status}`)
    await response.arrayBuffer()
  }
  const put = await fetch(base + '/spike.js', { method: 'PUT', body: 'x' })
  assert.equal(put.status, 405)
  await put.arrayBuffer()
})

test('with the real page directory the server, its tests and the results are not served', async () => {
  const real = createSpikeServer({ outDir: join(tmp, 'out'), resultsDir: join(tmp, 'results') })
  await new Promise((resolve) => real.listen(0, '127.0.0.1', resolve))
  try {
    for (const path of ['/server.mjs', '/split-fmp4.mjs', '/make-fixtures.sh', '/test/split.test.mjs', '/results/chrome-mac.json', '/out/bar/manifest.json']) {
      const response = await fetch(`http://127.0.0.1:${real.address().port}${path}`)
      assert.equal(response.status, 404, path)
      await response.arrayBuffer()
    }
  } finally { real.close() }
})

test('the fixture index lists the fixtures that have a manifest', async () => {
  const index = await (await fetch(base + '/fx/index.json')).json()
  assert.deepEqual(index.fixtures, ['bar'])
})

test('POST /results/<label> stores the JSON under results/ and nowhere else', async () => {
  const body = JSON.stringify({ label: 'chrome-mac', cases: { c01: { verdict: 'pass' } } })
  const ok = await fetch(base + '/results/chrome-mac', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body })
  assert.equal(ok.status, 204)
  assert.equal(readFileSync(join(tmp, 'results', 'chrome-mac.json'), 'utf8'), body)
  for (const label of ['..%2Fescape', 'UPPER', 'a b', '-lead', 'x'.repeat(41)]) {
    const bad = await fetch(base + '/results/' + label, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body })
    assert.ok([400, 404].includes(bad.status), `${label} gave ${bad.status}`)
    await bad.arrayBuffer()
  }
  const notJSON = await fetch(base + '/results/chrome-mac', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{nope' })
  assert.equal(notJSON.status, 400)
  const array = await fetch(base + '/results/chrome-mac', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '[1]' })
  assert.equal(array.status, 400)
  const big = await fetch(base + '/results/big', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ x: 'y'.repeat(5_000_000) }) })
  assert.equal(big.status, 413)
  assert.deepEqual(readdirSync(join(tmp, 'results')).sort(), ['chrome-mac.json'])
  assert.equal(existsSync(join(tmp, 'escape.json')), false)
})

test('/api/speed sends the asked number of KiB, capped', async () => {
  const response = await fetch(base + '/api/speed?kb=64')
  assert.equal((await response.arrayBuffer()).byteLength, 65536)
  const capped = await fetch(base + '/api/speed?kb=99999999')
  assert.equal(capped.status, 400)
  await capped.arrayBuffer()
})

test('--lan needs the owner\'s yes and a window of 1 to 60 minutes', () => {
  assert.deepEqual(lanPolicy({ lan: false, lanMinutes: 60 }, {}), { ok: true, minutes: 0 })
  const without = lanPolicy({ lan: true, lanMinutes: 60 }, {})
  assert.equal(without.ok, false)
  assert.match(without.message, /owner's yes in chat/)
  assert.equal(lanPolicy({ lan: true, lanMinutes: 60 }, { CB_SPIKE_LAN_YES: 'yes' }).ok, false, 'any other words are not the yes')
  const yes = { CB_SPIKE_LAN_YES: LAN_YES }
  assert.deepEqual(lanPolicy({ lan: true, lanMinutes: 60 }, yes), { ok: true, minutes: 60 })
  assert.deepEqual(lanPolicy({ lan: true, lanMinutes: 1 }, yes), { ok: true, minutes: 1 })
  for (const bad of [0, 0.5, 61, 1000, Number.NaN]) assert.equal(lanPolicy({ lan: true, lanMinutes: bad }, yes).ok, false, String(bad))
})

test('--rate-mbps spaces the body out to the chosen speed', async () => {
  const slow = createSpikeServer({ root: join(tmp, 'page'), outDir: join(tmp, 'out'), resultsDir: join(tmp, 'results'), rateMbps: 16 })
  await new Promise((resolve) => slow.listen(0, '127.0.0.1', resolve))
  try {
    const started = performance.now()
    const response = await fetch(`http://127.0.0.1:${slow.address().port}/api/speed?kb=256`)
    assert.equal((await response.arrayBuffer()).byteLength, 262144)
    const elapsed = performance.now() - started
    assert.ok(elapsed >= 100, `256 KiB at 16 Mbit/s should take about 131 ms, took ${elapsed}`)
    assert.ok(elapsed < 1500, `took ${elapsed} ms`)
  } finally { slow.close() }
})
