# eufy-bridge (Node.js and the eufy SDK)

Camera Bridge OS includes **eufy-bridge**, Camera Bridge's helper program for Eufy cameras: one process for the Eufy account, started by the daemon while the eufy plugin is on, streaming on demand over loopback HTTP. Its own code (`linux/helpers/eufy-bridge/src/`) is Camera Bridge's, under the PolyForm Noncommercial licence like the rest. It runs on **Node.js** and contains the **@mega-yfue/eufy-sdk** library and its npm dependencies, each under its own licence (below).

- **In the image:** the folder `/usr/lib/camera-bridge/helpers/eufy/` (`node`, `eufy-bridge.js`, `package.json`, `LICENSES/`, `VERSION`) and the launcher `/usr/lib/camera-bridge/helpers/eufy-bridge`, which runs that folder's `node` with `eufy-bridge.js`. Everything `root:root`, programs `0755`, the rest `0644`. Every licence text is in `/usr/lib/camera-bridge/helpers/eufy/LICENSES/` (with a `README.txt` listing them); `/usr/share/doc/eufy-bridge/copyright` summarises. The helper writes only to its state folder under the daemon's data directory (`CB_EUFY_STATE_DIR`; `HOME` points there too). amd64 only.
- **Node.js:** v24.21.0, the official `node-v24.21.0-linux-x64.tar.gz` from nodejs.org, unmodified (not stripped). The build accepts the tarball only with SHA-256 `6e1db87ef58b8819e5d5402eff1536491b18edd8eb7bee5ef7897876e88dc5ff` (also checked against the release's `SHASUMS256.txt`) and the `bin/node` inside it only with SHA-256 `7fde7b8afa198da66257f42ee2001d874c7355631e6d1579a5fb5ef1f246df4c`; the image build checks the binary again. Licence: MIT, plus the licences of the components Node.js bundles (OpenSSL, ICU, V8, libuv and others), all in Node's `LICENSE` file, shipped as `LICENSES/node/LICENSE`.
- **@mega-yfue/eufy-sdk:** v0.4.0 (upstream commit `7d1f016362465b0747405c5dc83124c86b2c630b`, "release: 0.4.0 (#331)"), Apache License 2.0, "Copyright 2026 mega-yfue". The package ships no `NOTICE` file. It is bundled into `eufy-bridge.js` with esbuild; one change is made at bundle time (`scripts/bundle.mjs`): its lazy `createRequire(import.meta.url)("protobufjs")` loader is rewritten to a plain `require("protobufjs")` so the bundler includes protobufjs. Nothing else is modified. `eufy-bridge.js` says so in its first lines.
- **Build:** `linux/os/build-helpers.sh` (run by `linux/os/build.sh`) runs `linux/helpers/eufy-bridge/build.sh` in the Node image pinned by digest (`node:24.21.0-bookworm-slim`, `node@sha256:d6aa754f…`; see `pins.env`): `npm ci` from `package-lock.json` (every package checked against its integrity hash), the SDK version in the lockfile checked against the pin, the tests, the bundle, then the licence texts of exactly the packages esbuild bundled (`scripts/collect-licenses.mjs`).

## npm packages bundled into eufy-bridge.js

| Package | Version | Licence |
|---|---|---|
| @mega-yfue/eufy-sdk | 0.4.0 | Apache-2.0 |
| @babel/runtime | 7.29.10 | MIT |
| abort-controller | 3.0.0 | MIT |
| bl | 6.1.6 | MIT |
| broker-factory | 3.1.15 | MIT |
| debug | 4.4.3 | MIT |
| event-target-shim | 5.0.1 | MIT |
| fast-unique-numbers | 9.0.27 | MIT |
| inherits | 2.0.4 | ISC |
| ip-address | 10.7.4 | MIT |
| jpeg-js | 0.4.4 | BSD-3-Clause |
| long | 5.3.2 | Apache-2.0 |
| lru-cache | 10.4.3 | ISC |
| mqtt | 5.16.1 | MIT |
| mqtt-packet | 9.0.2 | MIT |
| ms | 2.1.3 | MIT |
| process | 0.11.10 | MIT |
| process-nextick-args | 2.0.1 | MIT |
| protobufjs | 8.8.1 | BSD-3-Clause |
| readable-stream | 4.8.0 | MIT |
| rfdc | 1.4.1 | MIT |
| safe-buffer | 5.2.1 | MIT |
| smart-buffer | 4.2.0 | MIT |
| socks | 2.8.10 | MIT |
| string_decoder | 1.3.0 | MIT |
| worker-timers | 8.0.34 | MIT |
| worker-timers-broker | 8.0.18 | MIT |
| ws | 8.22.0 | MIT |

esbuild (MIT) is used to build and is not shipped. The list is generated at build time from what was bundled (`LICENSES/README.txt` in the build output); when `package-lock.json` changes, compare it with this table and update this page, `NOTICE`, `THIRD_PARTY_LICENSES.md` and `docs/linux/LICENSES.md`.
