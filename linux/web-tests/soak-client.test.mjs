import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { startFixture } from './soak-fixture-server.mjs'
import { runClient, classify } from '../web-dev/soak/client.mjs'
import { signIn } from '../web-dev/soak/bridge-http.mjs'
import { Histogram } from '../web-dev/soak/stats.mjs'

function readBuckets(file) {
  const rows = fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []
  const total = {}
  for (const row of rows) {
    const t = (total[row.kind] ??= { n: 0, ok: 0, gap: 0, gone: 0, busy: 0, unexpected: 0, neterr: 0, bad: 0, superseded: 0, bytes: 0, hist: new Histogram() })
    for (const k of Object.keys(t)) if (typeof t[k] === 'number') t[k] += row[k] ?? 0
    t.hist.merge(Histogram.fromJSON(row.h))
  }
  return total
}

async function setup(options, run) {
  const fixture = await startFixture(options)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-client-'))
  try {
    const session = await signIn(fixture.url, { password: 'correct horse' })
    await run({ fixture, dir, session })
  } finally { await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }) }
}

const phases = (seconds, kind = 'load') => [{ name: 'p', kind, from: 0, to: seconds }]
const common = (fixture, dir, session, extra = {}) => ({ base: fixture.url, session, clientId: 1, seed: 5, style: 'polite', t0Ms: Date.now(), outFile: path.join(dir, 'c.ndjson'), tickMs: 8, bucketSec: 1, ...extra })

test('a polite client against a healthy bridge sees only good answers and never aborts', async () => {
  await setup({ cameras: 2, latencyMs: 2 }, async ({ fixture, dir, session }) => {
    await runClient(common(fixture, dir, session, { phases: phases(5), endSec: 5 }))
    const t = readBuckets(path.join(dir, 'c.ndjson'))
    assert.ok(t.key.ok > 100, `keyframes ok: ${t.key.ok}`)
    for (const kind of Object.keys(t)) for (const bad of ['unexpected', 'neterr', 'bad']) assert.equal(t[kind][bad], 0, `${kind} ${bad}`)
    assert.ok(t.plan.ok >= 1 && t.fragment.ok >= 1 && t.init.ok >= 1, JSON.stringify(Object.fromEntries(Object.entries(t).map(([k, v]) => [k, v.ok]))))
    assert.ok(fixture.stats.maxInFlight <= 3, `a polite client has at most 3 byte requests and 1 JSON request in flight, saw ${fixture.stats.maxInFlight}`)
  })
})

test('an aggressive client against a busy bridge is told 429 with Retry-After and counts it as busy, not as an error', async () => {
  await setup({ cameras: 1, latencyMs: 30, maxInFlight: 2 }, async ({ fixture, dir, session }) => {
    await runClient(common(fixture, dir, session, { style: 'aggressive', phases: phases(4, 'storm'), endSec: 4 }))
    const t = readBuckets(path.join(dir, 'c.ndjson'))
    assert.ok(t.key.busy > 5, `busy answers: ${t.key.busy}`)
    assert.equal(t.key.unexpected + t.key.neterr + t.key.bad, 0)
    assert.ok(fixture.stats.busy > 5)
  })
})

test('footage that retention removed is "gone", a hole in the recording is "gap", both expected', async () => {
  const hole = [Date.now() - 20 * 60_000, Date.now() - 15 * 60_000]
  await setup({ cameras: 1, footageMs: 3_600_000, goneBeforeMs: Date.now() - 1_800_000, gaps: [hole] }, async ({ fixture, dir, session }) => {
    await runClient(common(fixture, dir, session, { seed: 11, phases: phases(8, 'storm'), endSec: 8 }))
    const t = readBuckets(path.join(dir, 'c.ndjson'))
    assert.ok(t.key.gap > 0, 'gaps are counted')
    assert.equal(t.key.unexpected + t.key.neterr + t.key.bad, 0, JSON.stringify(t.key))
  })
})

test('a server error, a wrong body and a missing Retry-After are counted as failures and written down', async () => {
  await setup({ cameras: 1, failRate: 0.3 }, async ({ fixture, dir, session }) => {
    await runClient(common(fixture, dir, session, { phases: phases(4), endSec: 4 }))
    const t = readBuckets(path.join(dir, 'c.ndjson'))
    assert.ok(t.key.unexpected > 10, `500s are unexpected: ${t.key.unexpected}`)
    const lines = fs.readFileSync(path.join(dir, 'c.unexpected.ndjson'), 'utf8').trim().split('\n').map((l) => JSON.parse(l))
    assert.ok(lines.length > 0 && lines.length <= 50 && lines[0].status === 500 && !/cookie|csrf/i.test(JSON.stringify(lines)))
  })
  const ok = { status: 200, bytes: 100, headers: { 'content-type': 'video/mp4', 'cache-control': 'no-store', 'content-length': '100' }, head: Buffer.alloc(100) }
  assert.equal(classify('fragment', ok).name, 'bad')
  assert.match(classify('fragment', ok).detail, /moof|boxes|box/)
  assert.deepEqual(classify('key', { status: 429, headers: {} }), { name: 'bad', detail: '429 without Retry-After' })
  assert.equal(classify('key', { status: 0, netError: 'ECONNRESET' }).name, 'neterr')
  const slow = { status: 504, headers: { 'retry-after': '2' }, json: { error: 'drive_slow' } }
  assert.equal(classify('fragment', slow).name, 'unexpected', 'a slow drive is an error in a normal soak')
  assert.equal(classify('fragment', slow, { tolerateSlow: true }).name, 'slow', 'and expected while the volume is hung on purpose')
  assert.equal(classify('key', { status: 404, headers: {}, json: { error: 'not_found' } }).name, 'unexpected')
})

test('a storm interrupts play and rest at once: the clients drag without pause as soon as it begins', async () => {
  await setup({ cameras: 2, latencyMs: 1 }, async ({ fixture, dir, session }) => {
    const plan = [{ name: 'load', kind: 'load', from: 0, to: 2 }, { name: 'storm', kind: 'storm', from: 2, to: 7 }]
    await runClient(common(fixture, dir, session, { phases: plan, endSec: 7, seed: 21 }))
    const rows = fs.readFileSync(path.join(dir, 'c.ndjson'), 'utf8').trim().split('\n').map((l) => JSON.parse(l)).filter((r) => r.kind === 'key')
    const inStorm = rows.filter((r) => r.t >= 2).reduce((s, r) => s + r.ok, 0)
    assert.ok(inStorm > 150, `key pictures in the storm: ${inStorm}`)
  })
})

test('a client started before the run clock waits for it, then works', async () => {
  await setup({ cameras: 1 }, async ({ fixture, dir, session }) => {
    await runClient(common(fixture, dir, session, { t0Ms: Date.now() + 2000, phases: phases(6), endSec: 6 }))
    const t = readBuckets(path.join(dir, 'c.ndjson'))
    assert.ok(t.key.ok > 30, `keyframes ok: ${t.key.ok}`)
  })
})

test('during an off phase a client sends nothing but stops on time', async () => {
  await setup({ cameras: 1 }, async ({ fixture, dir, session }) => {
    const before = fixture.stats.requests
    await runClient(common(fixture, dir, session, { phases: phases(2, 'off'), endSec: 2 }))
    assert.equal(fixture.stats.requests, before)
  })
})
