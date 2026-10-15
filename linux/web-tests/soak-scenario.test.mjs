import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { startFixture } from './soak-fixture-server.mjs'
import { signIn } from '../web-dev/soak/bridge-http.mjs'
import { snapshot, recovery, hangCheck, startupCheck } from '../web-dev/soak/scenario-check.mjs'

const failed = (checks) => checks.filter((c) => !c.pass).map((c) => c.id)

test('after a restart that keeps the recording, every remembered fragment has the same id and size', async () => {
  const startedAt = Date.now() - 1_800_000
  const first = await startFixture({ cameras: 2, startedAt })
  const session = await signIn(first.url, { password: 'x' })
  const before = await snapshot({ base: first.url, session })
  const killWall = Date.now() - 8000   // the real check runs a restart later: the new footage is newer than the kill
  await first.close()
  assert.equal(Object.keys(before.cameras).length, 2)
  assert.ok(Object.values(before.cameras).every((c) => c.parts.length >= 4))
  const second = await startFixture({ cameras: 2, startedAt, port: first.port })
  try {
    const checks = await recovery({ before, killWallMs: killWall, base: second.url, session, recoverSec: 5 })
    assert.deepEqual(failed(checks), [], JSON.stringify(checks.filter((c) => !c.pass)))
  } finally { await second.close() }
})

test('a restart that lost footage, or changed an id, or is not recording, is reported', async () => {
  const startedAt = Date.now() - 1_800_000
  const first = await startFixture({ cameras: 2, startedAt })
  const session = await signIn(first.url, { password: 'x' })
  const before = await snapshot({ base: first.url, session })
  const killWall = Date.now() - 8000
  await first.close()
  const forgetful = await startFixture({ cameras: 2, startedAt, port: first.port, goneBeforeMs: Date.now() - 600_000 })
  try {
    const checks = await recovery({ before, killWallMs: killWall, base: forgetful.url, session, recoverSec: 2 })
    assert.ok(failed(checks).includes('recovery.ids'), JSON.stringify(checks))
  } finally { await forgetful.close() }
  const shifted = await startFixture({ cameras: 2, startedAt: startedAt - 1234, port: first.port })
  try {
    const checks = await recovery({ before, killWallMs: killWall, base: shifted.url, session, recoverSec: 2 })
    assert.ok(failed(checks).includes('recovery.ids'), 'the same id with another start time is a changed fragment')
  } finally { await shifted.close() }
})

// ---- a hung volume, on made-up samples ----
function hangRun({ pauses = true, resumes = true, healthMs = 4, threadsPeak = 52, shim = ['1.0 blocked write'], locations = { status: 200, seconds: 8.4, problem: 'The drive isn’t answering.' }, noticeAt = [150, 290] } = {}) {
  const hang = { startedAt: 120, endedAt: 270, locations }
  const samples = []
  for (let t = 0; t < 380; t++) {
    samples.push({ t, k: 'health', ms: healthMs + (t % 7), status: 200, ok: true })
    samples.push({ t, k: 'catalog', status: 200, version: t < 130 || (t >= 270 && resumes) ? 1000 + t : 1130 })
    if (t % 5 === 0) {
      const hung = t >= 135 && t < 270
      const state = t >= 270 ? (resumes ? 'recording' : 'paused') : hung ? (pauses ? 'paused' : 'recording') : 'recording'
      samples.push({ t, k: 'status', status: 200, nvr: Object.fromEntries(Array.from({ length: 8 }, (_, i) => [`c${i}`, { state, pause: state === 'paused' ? 'notWritable' : null }])) })
    }
    if (t % 10 === 0) samples.push({ t, k: 'events', seconds: 10, counts: noticeAt.includes(t) ? { notices: 1 } : {} })
    if (t % 10 === 0) {
      samples.push({ t, k: 'storage', status: 200, ms: 3, state: t >= 135 && t < 270 ? 'notWritable' : 'ok' })
      samples.push({ t, k: 'proc', threads: t >= 125 && t < 280 ? threadsPeak : 44, rssKB: 1, fds: 1, established: 1, closeWait: 0 })
    }
  }
  const notify = [{ t: 0, wall: 1000, msg: 'LISTENING' }, { t: 1, wall: 1001, msg: 'READY=1' }]
  for (let t = 1; t < 380; t += 10) notify.push({ t, wall: 1000 + t, msg: 'WATCHDOG=1' })
  return { samples, notify, clientRows: [{ neterr: 0, bad: 0, unexpected: 0, slow: 12 }], shimLog: shim, hang, cameras: 8 }
}

test('a daemon that rides out a hung volume passes every hang check', () => {
  assert.deepEqual(failed(hangCheck(hangRun())), [])
})

test('each way of not riding it out is caught by its own check', () => {
  assert.ok(failed(hangCheck(hangRun({ pauses: false }))).includes('hang.paused'))
  assert.ok(failed(hangCheck(hangRun({ resumes: false }))).includes('hang.recovery'))
  assert.ok(failed(hangCheck(hangRun({ resumes: false }))).includes('hang.catalog'))
  assert.ok(failed(hangCheck(hangRun({ healthMs: 150 }))).includes('hang.health'))
  assert.ok(failed(hangCheck(hangRun({ threadsPeak: 90 }))).includes('hang.threads'))
  assert.ok(failed(hangCheck(hangRun({ shim: [] }))).includes('hang.shim'))
  assert.ok(failed(hangCheck(hangRun({ noticeAt: [] }))).includes('hang.notice'))
  assert.ok(failed(hangCheck(hangRun({ noticeAt: [150] }))).includes('hang.notice'), 'a banner that never goes away')
  assert.ok(failed(hangCheck(hangRun({ locations: { status: 200, seconds: 30, problem: null } }))).includes('hang.locations'))
  const silent = hangRun(); silent.notify = silent.notify.filter((n) => !(n.t > 150 && n.t < 190))
  assert.ok(failed(hangCheck(silent)).includes('hang.watchdog'))
  const restarted = hangRun(); restarted.notify.push({ t: 200, wall: 1200, msg: 'READY=1' })
  assert.ok(failed(hangCheck(restarted)).includes('hang.watchdog'))
  const errors = hangRun(); errors.clientRows[0].neterr = 1
  assert.ok(failed(hangCheck(errors)).includes('hang.clients'))
})

// ---- a start with a hung volume ----
function startupProbes({ readyAfter = 1.2, cameras = [200], statusMs = 5 } = {}) {
  const probes = []
  for (let i = 0; i < 20; i++) {
    probes.push({ label: 'status', status: 200, ms: statusMs }, { label: 'health', status: 200, ms: 3 }, { label: 'storage', status: 200, ms: 3 })
    const c = cameras[i % cameras.length]
    probes.push(c === 503 ? { label: 'nvrCameras', status: 503, ms: 2, error: 'archive_unavailable', retryAfter: '2' } : { label: 'nvrCameras', status: 200, ms: 2 })
  }
  const notify = [{ t: 0, wall: 1000, msg: 'LISTENING' }, { t: readyAfter, wall: 1000 + readyAfter, msg: 'READY=1' }]
  for (let t = 1; t < 60; t += 10) notify.push({ t, wall: 1000 + t, msg: 'WATCHDOG=1' })
  return { probes, notify, startWallMs: 1000 * 1000, releasedMs: 1050 * 1000, readyAt: 1060 * 1000, recordingAt: 1075 * 1000, hangSec: 45 }
}

test('a start with a hung folder that is ready at once, answers at once and recovers passes', () => {
  assert.deepEqual(failed(startupCheck(startupProbes())), [])
  assert.deepEqual(failed(startupCheck(startupProbes({ cameras: [503, 503, 200] }))), [])
})

test('a start that waits for the folder, answers slowly, or never recovers is caught', () => {
  assert.ok(failed(startupCheck(startupProbes({ readyAfter: 40 }))).includes('startup.ready'))
  assert.ok(failed(startupCheck(startupProbes({ statusMs: 900 }))).includes('startup.status'))
  const hang = startupProbes(); hang.probes.filter((p) => p.label === 'nvrCameras').forEach((p) => { p.ms = 5000 })
  assert.ok(failed(startupCheck(hang)).includes('startup.loading'))
  const wrong = startupProbes({ cameras: [503] }); wrong.probes.filter((p) => p.status === 503).forEach((p) => { p.retryAfter = null })
  assert.ok(failed(startupCheck(wrong)).includes('startup.loading'))
  const never = startupProbes(); never.readyAt = null; never.recordingAt = null
  assert.deepEqual(failed(startupCheck(never)).sort(), ['startup.catalog', 'startup.recording'])
})
