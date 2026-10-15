#!/usr/bin/env node
// A stand-in for camerabridged's NVR routes: serves linux/web and answers /api/v1 (the existing routes the page needs, and the NVR
// routes of docs/superpowers/plans/2026-10-10-nvr/T00-contracts.md Part C) over fixture clips, with nine cameras and three days of footage.
//
//   sh linux/web-dev/make-fixtures.sh                       once
//   node linux/web-dev/dev-archive-server.mjs [options]     then open http://127.0.0.1:8090/ and sign in
//
// See linux/web-dev/README.md. No dependencies; Node 22 or newer.

import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createDevServer, DEFAULTS } from './lib/server.mjs';
import { fixturesPresent } from './lib/fixtures.mjs';
import { SCENARIOS } from './lib/state.mjs';
import { isLoopback } from './lib/http.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const USAGE = `Usage: node dev-archive-server.mjs [options]
  --host ADDRESS         where to listen (default 127.0.0.1; anything else needs CB_DEV_PASSWORD)
  --port N               default 8090
  --scenario NAME        ${Object.keys(SCENARIOS).join(' | ')} (default ok)
  --latency-ms N         wait this long in every archive request (default 0); --jitter-ms N adds up to N more
  --throttle-mbps N      send media bytes as if the link had this speed (default: no limit)
  --stall-ms N           how long a stalled drive holds a read (default 5000) and a folder check (8000 unless given)
  --loading-ms N         how long the "loading" scenario lasts before it turns into "ok" (default 3000)
  --optimize-ms N        how long the keyframe fix takes (default 1500)
  --disk-gb N            size of the pretend drive (default 512)
  --clock-offset-ms N    the server's clock is this far ahead of this computer's (default 0; negative is behind)
  --allowed-host NAME    an extra Host name to accept (a name on your network); repeatable
  --fixture-dir DIR      default linux/web-dev/fixtures      --web-root DIR   default linux/web
  --verbose              log method, path and status of each request (never bodies, cookies or passwords)
Environment: CB_DEV_PASSWORD sets the sign-in password (default: camera-bridge-dev, loopback only).`;

if (Number(process.versions.node.split('.')[0]) < 22) {
  console.error(`dev-archive-server needs Node 22 or newer (this is ${process.versions.node}).`);
  process.exit(2);
}

const numbers = { '--port': 'port', '--latency-ms': 'latencyMs', '--jitter-ms': 'jitterMs', '--throttle-mbps': 'throttleMbps', '--loading-ms': 'loadingMs', '--optimize-ms': 'optimizeMs', '--disk-gb': 'diskGB', '--clock-offset-ms': 'clockOffsetMs' };
const options = { webRoot: resolve(here, '../web'), fixtureDir: resolve(here, 'fixtures'), allowedHosts: [] };
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 1) {
  const name = args[i];
  const value = () => {
    if (i + 1 >= args.length) { console.error(`${name} needs a value.\n${USAGE}`); process.exit(2); }
    return args[++i];
  };
  if (name === '--help' || name === '-h') { console.log(USAGE); process.exit(0); }
  else if (name in numbers) {
    const parsed = Number(value());
    if (!Number.isFinite(parsed)) { console.error(`${name} needs a number.`); process.exit(2); }
    options[numbers[name]] = parsed;
  } else if (name === '--host') options.host = value();
  else if (name === '--scenario') options.scenario = value();
  else if (name === '--stall-ms') options.stallReadMs = options.stallFolderMs = Number(value());
  else if (name === '--allowed-host') options.allowedHosts.push(value());
  else if (name === '--fixture-dir') options.fixtureDir = resolve(value());
  else if (name === '--web-root') options.webRoot = resolve(value());
  else if (name === '--verbose') options.verbose = true;
  else { console.error(`Unknown option ${name}.\n${USAGE}`); process.exit(2); }
}
if (options.scenario && !(options.scenario in SCENARIOS)) { console.error(`Unknown scenario ${options.scenario}.\n${USAGE}`); process.exit(2); }
if (!existsSync(join(options.webRoot, 'index.html'))) { console.error(`There is no index.html in ${options.webRoot}.`); process.exit(2); }
if (!fixturesPresent(options.fixtureDir)) { console.error(`The fixtures are missing in ${options.fixtureDir}. Run: sh linux/web-dev/make-fixtures.sh`); process.exit(2); }

const host = options.host ?? DEFAULTS.host;
const loopback = isLoopback(host) || host === 'localhost' || host === '::1';
if (!loopback && !process.env.CB_DEV_PASSWORD) {
  console.error('Listening beyond this computer needs your own password: set CB_DEV_PASSWORD. The dev server serves fixture video and a fake bridge.');
  process.exit(2);
}
options.password = process.env.CB_DEV_PASSWORD || DEFAULTS.password;

const dev = createDevServer(options);
const address = await dev.listen().catch((error) => { console.error(`Cannot listen on ${host}:${options.port ?? DEFAULTS.port}: ${error.code ?? error.message}`); process.exit(1); });
const shown = address.family === 'IPv6' ? `[${address.address}]` : address.address;
console.log(`Camera Bridge dev archive server on http://${shown}:${address.port}/ (scenario ${dev.state.scenario}).`);
console.log(process.env.CB_DEV_PASSWORD ? 'Sign in with the password from CB_DEV_PASSWORD.' : `Sign in with the development password: ${DEFAULTS.password}`);
if (!loopback) console.log('This is reachable from your network. Stop it when you are done.');
console.log('Switch scenarios with:  curl -s -X POST http://127.0.0.1:' + address.port + '/__dev/scenario -H "Content-Type: application/json" -d \'{"name":"diskFull"}\'');
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => dev.close().then(() => process.exit(0)));
