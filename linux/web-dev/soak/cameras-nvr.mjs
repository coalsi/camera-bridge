#!/usr/bin/env node
// Turns Record or Record sound on or off for every camera of the run (the scenarios use it to make a recorder start a new file: a change of the
// sound switch replaces the camera's recorder, which closes the open file).
//   node cameras-nvr.mjs --base URL --session SESSION.json --cameras cameras.json --set record|sound --to on|off
import fs from 'node:fs'
import { createHttp, loadSession } from './bridge-http.mjs'

const a = {}
for (let i = 2; i < process.argv.length; i += 2) a[process.argv[i].replace(/^--/, '')] = process.argv[i + 1]
const field = { record: 'enabled', sound: 'recordSound' }[a.set]
if (!field || !['on', 'off'].includes(a.to)) { console.error('usage: cameras-nvr.mjs --base U --session S --cameras F --set record|sound --to on|off'); process.exit(2) }
const http = createHttp({ base: a.base, session: loadSession(a.session), maxSockets: 1, timeoutMs: 60_000 })
let failures = 0
for (const camera of JSON.parse(fs.readFileSync(a.cameras, 'utf8'))) {
  const r = await http.request('PATCH', `/api/v1/cameras/${camera.id}/nvr`, { body: { [field]: a.to === 'on' } })
  if (r.status !== 200) { failures++; console.error(`${camera.name}: HTTP ${r.status || r.netError} ${r.json?.error ?? ''}`) }
}
http.close()
console.log(`${a.set} ${a.to}: ${failures === 0 ? 'all cameras changed' : `${failures} failed`}`)
process.exit(failures === 0 ? 0 : 1)
