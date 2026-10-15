import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { startFixture } from './soak-fixture-server.mjs'
import { runSampler } from '../web-dev/soak/sampler.mjs'
import { signIn } from '../web-dev/soak/bridge-http.mjs'

const probe = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Tools/nvr-soak/probe.sh')

test('the sampler writes one line per sample for each thing it watches, and the process probe reads this very process', async () => {
  const fixture = await startFixture({ cameras: 2 })
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-sampler-'))
  try {
    const session = await signIn(fixture.url, { password: 'x' })
    const outFile = path.join(dir, 'samples.ndjson')
    await runSampler({ base: fixture.url, session, t0Ms: Date.now(), endSec: 3.2, outFile, pid: process.pid, port: fixture.port,
      platform: process.platform === 'darwin' ? 'darwin' : 'linux', probeScript: probe, probeCommand: 'sh', intervals: { status: 1000, storage: 1000, proc: 1000 } })
    const rows = fs.readFileSync(outFile, 'utf8').trim().split('\n').map((l) => JSON.parse(l))
    const of = (k) => rows.filter((r) => r.k === k)
    assert.ok(of('health').length >= 3 && of('health').every((r) => r.status === 200 && r.ok === true && r.ms < 100), 'health')
    assert.ok(of('catalog').length >= 3, 'catalog')
    const cat = of('catalog')[0]
    assert.equal(Object.keys(cat.cams).length, 2)
    assert.ok(Object.values(cat.cams).every((c) => c.lag > 0 && c.lag < 5000), JSON.stringify(cat.cams))
    assert.ok(of('status').length >= 2 && Object.values(of('status')[0].nvr).every((n) => n.state === 'recording'))
    assert.ok(of('storage').length >= 2 && of('storage')[0].state === 'ok')
    const p = of('proc')
    assert.ok(p.length >= 2 && p[0].rssKB > 10_000 && p[0].fds > 3 && p[0].threads >= 1, JSON.stringify(p[0]))
    assert.ok(p[0].memKB > 10_000 && p[0].memKB < p[0].rssKB * 3, `the process's own memory (footprint, RssAnon): ${JSON.stringify(p[0])}`)
    assert.ok(rows.every((r) => typeof r.t === 'number'))
    assert.ok(!/cookie|csrf|cb_session/i.test(fs.readFileSync(outFile, 'utf8')), 'no session data in the samples')
  } finally { await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }) }
})

test('the sampler counts the event stream by name and leaves the snapshot out', async () => {
  const fixture = await startFixture({ cameras: 3, eventsEveryMs: 100 })
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-events-'))
  try {
    const session = await signIn(fixture.url, { password: 'x' })
    const outFile = path.join(dir, 'samples.ndjson')
    await runSampler({ base: fixture.url, session, t0Ms: Date.now(), endSec: 7, outFile, pid: process.pid, port: fixture.port, platform: process.platform === 'darwin' ? 'darwin' : 'linux', intervals: { health: 5000, catalog: 5000, status: 5000, storage: 5000, proc: 5000 } })
    const rows = fs.readFileSync(outFile, 'utf8').trim().split('\n').map((l) => JSON.parse(l)).filter((r) => r.k === 'events' && r.counts)
    const camera = rows.reduce((sum, r) => sum + (r.counts.camera ?? 0), 0)
    assert.ok(camera >= 20 && camera <= 50, `camera events counted: ${camera} (the 3 snapshot events are not news; about 40 ticks in 4 s)`)
  } finally { await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }) }
})

test('the sampler tells the camera events in which the NVR status changed from the ones that carry other news', async () => {
  // The engine's measured frame rate changes in its last decimals on every tick; the NVR status changes twice (a note appears and goes).
  const eventStatus = (_camera, n) => ({ connection: 'online', mainStreamInfo: { fps: 25 + (n % 2) * 1e-12 }, nvr: { state: 'recording', notes: n === 50 ? [{ id: 'keyframe' }] : [] } })
  const fixture = await startFixture({ cameras: 2, eventsEveryMs: 100, eventStatus })
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-events-nvr-'))
  try {
    const session = await signIn(fixture.url, { password: 'x' })
    const outFile = path.join(dir, 'samples.ndjson')
    await runSampler({ base: fixture.url, session, t0Ms: Date.now(), endSec: 8, outFile, pid: process.pid, port: fixture.port, platform: process.platform === 'darwin' ? 'darwin' : 'linux', intervals: { health: 5000, catalog: 5000, status: 5000, storage: 5000, proc: 5000 } })
    const rows = fs.readFileSync(outFile, 'utf8').trim().split('\n').map((l) => JSON.parse(l)).filter((r) => r.k === 'events' && r.counts)
    const sum = (name) => rows.reduce((total, r) => total + (r.counts[name] ?? 0), 0)
    assert.ok(sum('camera') >= 20, `every camera event is still counted: ${sum('camera')}`)
    assert.equal(sum('cameraNvr'), 2, 'the note appearing and going away are the only changes of status.nvr')
    const changed = rows.reduce((all, r) => { for (const [name, n] of Object.entries(r.changed ?? {})) all[name] = (all[name] ?? 0) + n; return all }, {})
    assert.ok(changed['status.mainStreamInfo.fps'] >= 20, JSON.stringify(changed))
    assert.equal(changed['status.nvr.notes'], 2, JSON.stringify(changed))
    assert.ok(rows.every((r) => 'cameraNvr' in r.counts), 'every row says how many NVR changes there were, so the analyzer knows the sampler could tell')
  } finally { await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a daemon that is gone or slow shows up as errors in the samples, not as an exception', async () => {
  const fixture = await startFixture({ cameras: 1 })
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-sampler-'))
  try {
    const session = await signIn(fixture.url, { password: 'x' })
    const outFile = path.join(dir, 'samples.ndjson')
    const run = runSampler({ base: fixture.url, session, t0Ms: Date.now(), endSec: 2.5, outFile, pid: 2_147_483_000, port: fixture.port, platform: process.platform === 'darwin' ? 'darwin' : 'linux',
      probeScript: probe, probeCommand: 'sh', intervals: { proc: 500 } })
    setTimeout(() => fixture.close(), 1200)
    await run
    const rows = fs.readFileSync(outFile, 'utf8').trim().split('\n').map((l) => JSON.parse(l))
    assert.ok(rows.some((r) => r.k === 'proc' && r.err), 'the probe of a missing process is an error line')
    assert.ok(rows.some((r) => r.k === 'health' && r.status === 0 && r.err), 'a closed port is an error line')
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})
