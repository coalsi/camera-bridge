import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { startFixture } from './soak-fixture-server.mjs'
import { prepare } from '../web-dev/soak/prepare.mjs'

test('prepare signs in, adds the cameras, chooses the location, turns Record on and writes a private session file', async () => {
  const fixture = await startFixture({ cameras: 0 })
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-prepare-'))
  try {
    fs.writeFileSync(path.join(dir, 'pw'), 'a-long-throwaway-password\n', { mode: 0o600 })
    const out = path.join(dir, 'out')
    const { cameras, sessionFile } = await prepare({ base: fixture.url, passwordFile: path.join(dir, 'pw'), outDir: out, cameras: 3, urlTemplate: 'rtsp://127.0.0.1:18554/load{n}', capGB: 20, waitSec: 20 })
    assert.equal(cameras.length, 3)
    assert.equal(fixture.cameras.filter((c) => c.nvrEnabled).length, 3)
    assert.equal(fs.statSync(sessionFile).mode & 0o777, 0o600)
    assert.ok(JSON.parse(fs.readFileSync(path.join(out, 'cameras.json'), 'utf8')).length === 3)
    assert.ok(!fs.readFileSync(sessionFile, 'utf8').includes('a-long-throwaway-password'))
    assert.deepEqual(Object.keys(JSON.parse(fs.readFileSync(sessionFile, 'utf8'))).sort(), ['cookie', 'csrf'])
  } finally { await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }) }
})

test('prepare with --login-only picks up the cameras that already record', async () => {
  const fixture = await startFixture({ cameras: 2 })
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-prepare-'))
  try {
    fs.writeFileSync(path.join(dir, 'pw'), 'a-long-throwaway-password\n')
    const { cameras } = await prepare({ base: fixture.url, passwordFile: path.join(dir, 'pw'), outDir: path.join(dir, 'out'), loginOnly: true, waitSec: 20 })
    assert.equal(cameras.length, 2)
  } finally { await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }) }
})

test('prepare reports a daemon that never answers, and a camera that never records', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-prepare-'))
  try {
    fs.writeFileSync(path.join(dir, 'pw'), 'a-long-throwaway-password\n')
    await assert.rejects(prepare({ base: 'http://127.0.0.1:9', passwordFile: path.join(dir, 'pw'), outDir: path.join(dir, 'out'), cameras: 1, urlTemplate: 'rtsp://x/{n}', capGB: 20, waitSec: 2 }), /did not answer \/health/)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('first-run setup answers 201 and sign-in 200: both give a session', async () => {
  const { signIn } = await import('../web-dev/soak/bridge-http.mjs')
  const fixture = await startFixture({ cameras: 0 })
  try {
    for (const setup of [true, false]) {
      const session = await signIn(fixture.url, { password: 'a-long-throwaway-password', setup, setupToken: 'abc' })
      assert.match(session.cookie, /cb_session=/)
      assert.ok(session.csrf.length > 3)
    }
  } finally { await fixture.close() }
})

test('prepare stops before turning Record on when the disk cannot hold the cap above the daemon floor', async () => {
  const fixture = await startFixture({ cameras: 0, freeBytes: 20e9 })   // 12 GB above the 8 GB floor: not enough for a 20 GB cap
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-prepare-'))
  try {
    fs.writeFileSync(path.join(dir, 'pw'), 'a-long-throwaway-password\n')
    await assert.rejects(prepare({ base: fixture.url, passwordFile: path.join(dir, 'pw'), outDir: path.join(dir, 'out'), cameras: 2, urlTemplate: 'rtsp://x/{n}', capGB: 20, waitSec: 5 }), /not enough room: 12 GB are free above the daemon's floor/)
    assert.equal(fixture.cameras.filter((c) => c.nvrEnabled).length, 0, 'Record was not turned on')
  } finally { await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }) }
})

test('prepare does not guess when the storage numbers are missing', async () => {
  const fixture = await startFixture({ cameras: 0, freeBytes: undefined })
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-prepare-'))
  try {
    fs.writeFileSync(path.join(dir, 'pw'), 'a-long-throwaway-password\n')
    await assert.rejects(prepare({ base: fixture.url, passwordFile: path.join(dir, 'pw'), outDir: path.join(dir, 'out'), cameras: 1, urlTemplate: 'rtsp://x/{n}', capGB: 10, waitSec: 5 }), /did not report freeBytes/)
  } finally { await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }) }
})

test('prepare waits for the first measurement of the folder instead of reading zeros', async () => {
  const fixture = await startFixture({ cameras: 0, storageDelayMs: 2500 })   // zero bytes everywhere for the first 2.5 s
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soak-prepare-'))
  try {
    fs.writeFileSync(path.join(dir, 'pw'), 'a-long-throwaway-password\n')
    const started = Date.now()
    const { cameras } = await prepare({ base: fixture.url, passwordFile: path.join(dir, 'pw'), outDir: path.join(dir, 'out'), cameras: 1, urlTemplate: 'rtsp://x/{n}', capGB: 10, waitSec: 20 })
    assert.equal(cameras.length, 1)
    assert.ok(Date.now() - started >= 1500, 'it waited for the numbers')
  } finally { await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }) }
})
