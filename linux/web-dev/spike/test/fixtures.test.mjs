import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

// Checks the fixtures make-fixtures.sh built (skipped until `sh make-fixtures.sh` has run). They are what every browser result stands on.
const out = process.env.CB_SPIKE_OUT ?? join(dirname(fileURLToPath(import.meta.url)), '..', 'out')
const ids = existsSync(out) ? readdirSync(out).filter((id) => existsSync(join(out, id, 'manifest.json'))) : []
const have = (id) => ids.includes(id)
const manifest = (id) => JSON.parse(readFileSync(join(out, id, 'manifest.json'), 'utf8'))
const haveFfmpeg = spawnSync('ffprobe', ['-version']).status === 0

test('the fixture directory has been built', { skip: ids.length > 0 ? false : 'run sh make-fixtures.sh first' }, () => {
  for (const id of ['bar', 'barB', 'barH', 'ntsc', 'gop30', 'av', 'avv', 'hevc', 'big', 'uhd', 'cap']) assert.ok(have(id), `missing fixture ${id}`)
})

for (const id of ids) {
  test(`${id}: fragments are contiguous, start on a keyframe and add up`, () => {
    const m = manifest(id)
    assert.equal(m.timescale, 90000)
    assert.equal(m.parts[0].key, true)
    assert.equal(m.parts[0].startTick, 0)
    let frames = 0
    m.parts.forEach((part, i) => {
      if (i > 0) assert.equal(part.startTick, m.parts[i - 1].startTick + m.parts[i - 1].durTicks, `part ${i} does not follow part ${i - 1}`)
      assert.equal(part.frameFirst, frames)
      frames += part.frameCount
      assert.equal(part.backToKey, part.key ? 0 : m.parts[i - 1].backToKey + 1, `backToKey of part ${i}`)
      assert.ok(part.durTicks > 0 && part.bytes > 0)
      assert.ok(!part.midKey, `part ${i} holds a keyframe that does not start it`)
    })
    assert.equal(frames, m.frames.length)
    assert.equal(m.durationTicks, m.parts.reduce((n, p) => n + p.durTicks, 0))
    assert.match(m.mime, /^video\/mp4; codecs="(avc1|hvc1)\.[0-9A-Za-z.]+"$/)
  })
}

test('bar: 20 fps, 2 s GOPs, a barcode base of 0, and the stored form with prft', { skip: !have('bar') }, () => {
  const m = manifest('bar')
  assert.match(m.mime, /^video\/mp4; codecs="avc1\.4d[0-9a-f]{2}1f"$/)      // Main profile, level 3.1 (x264 sets a constraint flag, hence the wildcard)
  assert.equal(m.parts.length, 6)
  assert.ok(m.parts.every((p) => p.key && p.frameCount === 40))
  assert.ok(m.frames.every(([pts], i) => pts === i * 4500))
  assert.equal(m.barcodeBase, 0)
  assert.equal(m.parts[0].storedBytes, m.parts[0].bytes + 32)
})

test('ntsc has 3003 ticks per frame; gop30 has one keyframe per 12 fragments of 2.5 s', { skip: !have('ntsc') || !have('gop30') }, () => {
  assert.ok(manifest('ntsc').frames.every(([pts], i) => pts === i * 3003))
  const g = manifest('gop30')
  assert.deepEqual(g.parts.slice(0, 13).map((p) => p.backToKey), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0])
  assert.ok(g.parts.slice(0, 12).every((p) => p.durTicks === 225000))
})

test('barB shares bar\'s codec string with another size; barH has another codec string; hevc is hvc1', { skip: !have('bar') || !have('barB') || !have('barH') || !have('hevc') }, () => {
  assert.equal(manifest('barB').mime, manifest('bar').mime)
  assert.notEqual(manifest('barB').width, manifest('bar').width)
  assert.equal(manifest('barH').mime, 'video/mp4; codecs="avc1.640028"')
  assert.match(manifest('hevc').mime, /hvc1\./)
})

test('av has sound in every fragment, avv has none, and both carry the same video', { skip: !have('av') || !have('avv') }, () => {
  const av = manifest('av'), avv = manifest('avv')
  assert.equal(av.hasAudio, true)
  assert.equal(avv.hasAudio, false)
  assert.ok(av.parts.every((p) => p.hasAudio))
  assert.equal(av.frames.length, avv.frames.length)
  assert.match(av.mimeAV, /mp4a\.40\.2"$/)
})

for (const id of ['bar', 'ntsc', 'avv', 'hevc', 'cap']) {
  test(`${id}: init + fragments concatenated decode to every frame (ffmpeg)`, { skip: !have(id) || !haveFfmpeg }, () => {
    const m = manifest(id)
    const dir = mkdtempSync(join(tmpdir(), 'cb-spike-fx-'))
    try {
      const file = join(dir, 'all.mp4')
      writeFileSync(file, Buffer.concat([readFileSync(join(out, id, 'init.mp4')), ...m.parts.map((p) => readFileSync(join(out, id, p.file)))]))
      const count = execFileSync('ffprobe', ['-v', 'error', '-count_frames', '-select_streams', 'v:0', '-show_entries', 'stream=nb_read_frames', '-of', 'default=nw=1:nk=1', file], { encoding: 'utf8' }).trim()
      assert.equal(Number(count), m.frames.length)
    } finally { rmSync(dir, { recursive: true, force: true }) }
  })
}
