#!/usr/bin/env node
// Writes and updates the run's meta.json, the one file that tells the analyzer what the run was.
//   node meta.mjs create --out meta.json --run-id ID --target mac|container|attach --scenario soak --t0 MS --end-sec N --port N --cameras N --seed N --cap-gb N \
//        --root RECORDINGS_FOLDER [--phases phases.json] [--rehearsal 1]
//   node meta.mjs patch  --out meta.json --json '{"shutdown":{"seconds":2.4,"ok":true}}'      (shallow merge of the JSON into the file)
//   node meta.mjs phases --end-sec N --out phases.json
import fs from 'node:fs'
import { buildPhases } from './plan.mjs'

const [command, ...rest] = process.argv.slice(2)
const a = {}
for (let i = 0; i < rest.length; i += 2) a[rest[i].replace(/^--/, '').replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = rest[i + 1]

if (command === 'phases') {
  fs.writeFileSync(a.out, JSON.stringify(buildPhases(Number(a.endSec))))
} else if (command === 'create') {
  const meta = {
    runId: a.runId, target: a.target, scenario: a.scenario ?? 'soak', t0Ms: Number(a.t0), endSec: Number(a.endSec), port: Number(a.port), cameras: Number(a.cameras), seed: Number(a.seed),
    capGB: Number(a.capGb), recordingsRoot: a.root, phases: a.phases ? JSON.parse(fs.readFileSync(a.phases, 'utf8')) : Number(a.endSec) >= 120 ? buildPhases(Number(a.endSec)) : [], ...(a.rehearsal === '1' ? { rehearsal: true } : {}),
  }
  fs.writeFileSync(a.out, JSON.stringify(meta, null, 2))
} else if (command === 'patch') {
  const meta = JSON.parse(fs.readFileSync(a.out, 'utf8'))
  fs.writeFileSync(a.out, JSON.stringify({ ...meta, ...JSON.parse(a.json) }, null, 2))
} else {
  console.error('usage: meta.mjs create|patch|phases ...'); process.exit(2)
}
