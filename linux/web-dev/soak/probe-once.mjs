#!/usr/bin/env node
// One GET, timed, printed as one JSON line: { path, status, ms, retryAfter, error, wall }. For the scenarios' shell code. No body is printed.
//   node probe-once.mjs --base URL [--session SESSION.json] --path /api/v1/health
import { createHttp, loadSession } from './bridge-http.mjs'

export async function probeOnce({ base, session, path, timeoutMs = 20_000 }) {
  const http = createHttp({ base, session, maxSockets: 1, timeoutMs })
  try {
    const wall = Date.now()
    const r = await http.request('GET', path, { collect: 'json' })
    return { path: path.replace(/\?.*$/, ''), status: r.status, ms: Math.round(r.ms * 10) / 10, retryAfter: r.headers?.['retry-after'] ? Number(r.headers['retry-after']) : null, error: r.netError ?? r.json?.error ?? null, wall }
  } finally { http.close() }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const a = {}
  for (let i = 2; i < process.argv.length; i += 2) a[process.argv[i].replace(/^--/, '')] = process.argv[i + 1]
  console.log(JSON.stringify(await probeOnce({ base: a.base, session: a.session ? loadSession(a.session) : null, path: a.path })))
}
