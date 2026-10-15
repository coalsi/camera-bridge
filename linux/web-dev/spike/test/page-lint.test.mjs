import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

// The page runs under the daemon's content security policy (no inline script or style, no remote hosts) and must not use what the box will not
// have. This keeps the spike honest: whatever it proves, it proves under the same rules as the real page.
const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const files = ['index.html', 'spike.js', 'spike.css',
  ...readdirSync(join(root, 'lib')).map((f) => `lib/${f}`), ...readdirSync(join(root, 'cases')).map((f) => `cases/${f}`)]

const BANNED = [
  [/\.innerHTML|\.outerHTML|insertAdjacentHTML/, 'HTML strings'],
  [/\beval\s*\(|new Function\b/, 'eval'],
  [/document\.write/, 'document.write'],
  [/setAttribute\(\s*['"]style['"]/, 'a style attribute set from script'],
  [/\sstyle\s*=\s*["']/, 'an inline style attribute'],
  [/<script(?![^>]*\bsrc=)[^>]*>/, 'an inline script'],
  [/<style[\s>]/, 'an inline style element'],
  [/\bon[a-z]+\s*=\s*["']/, 'an inline event handler attribute'],
  [/new\s+Worker|importScripts|WebAssembly|SharedWorker/, 'workers or wasm'],
  [/new\s+VideoDecoder|new\s+VideoFrame|new\s+AudioDecoder/, 'WebCodecs (the box is plain HTTP: they are not part of the plan)'],
  [/https?:\/\/(?!spike\.invalid)/, 'a remote or absolute URL'],
  [/crypto\.randomUUID/, 'crypto.randomUUID (secure contexts only)'],
]

for (const file of files) {
  test(`${file} uses nothing the content security policy or a plain-HTTP origin forbids`, () => {
    const text = readFileSync(join(root, file), 'utf8')
    for (const [pattern, what] of BANNED) {
      if (file.endsWith('.css') && what !== 'a remote or absolute URL') continue
      assert.equal(pattern.test(text), false, `${file} contains ${what}`)
    }
  })
}
