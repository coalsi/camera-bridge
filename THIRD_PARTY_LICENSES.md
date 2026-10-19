# Third-party licenses

Camera Bridge itself is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE). It contains, links to or is
built with the third-party software below, each under its own license. This file is the index; the **full license texts**
are in [`Archive/mac-app/App/Resources/Acknowledgements.md`](Archive/mac-app/App/Resources/Acknowledgements.md), which was
bundled in the Mac app (archived in October 2026) and shown under *About > Acknowledgements*. Attribution notices that licenses require are in [NOTICE](NOTICE).

The PolyForm license applies to Camera Bridge's own code only. It does not change the terms of anything listed here.

## Shipped in the macOS app (archived October 2026)

| Component | Version | License | Where it is used | Full text |
|---|---|---|---|---|
| HAP-NodeJS (derived code, not linked) | 2.2.3 | Apache-2.0 | Portions of the HomeKit protocol layers (`HAP`, `HAPCore/Identity`, `HAPCamera`, `HDS`) are derived from its TypeScript sources and modified. | Acknowledgements.md, "HAP-NodeJS" (Apache-2.0 text) |
| [swift-crypto](https://github.com/apple/swift-crypto) | 3.15.1 | Apache-2.0 | Cryptography (`Crypto`; on macOS this re-exports Apple CryptoKit). | Acknowledgements.md, "swift-crypto" (with its NOTICE) |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.3 | Apache-2.0 | Dependency of swift-crypto. | Acknowledgements.md, "swift-asn1" (with its NOTICE) |
| [BigInt](https://github.com/attaswift/BigInt) | 5.7.0 | MIT | Arbitrary-precision integers for SRP pair-setup. | Acknowledgements.md, "BigInt" |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | MIT, plus bundled components under BSD-2-Clause-style, MIT and zlib-style licenses (bsdiff, sais-lite, orlp/ed25519, SUSignatureVerifier) | Software updates (`Archive/mac-app/App/Sources/Updates`). Embedded as `Sparkle.framework`. | Acknowledgements.md, "Sparkle" |
| [go2rtc](https://github.com/AlexxIT/go2rtc) | 1.9.14 | MIT (built from Go modules under their own permissive licenses, listed in its `go.mod`) | Helper program for cloud cameras and consoles (Ring, Nest, Wyze, Tuya, UniFi RTSPS). Bundled unmodified as `Contents/Helpers/go2rtc` and run as a separate process; fetched and checksum-verified by `Tools/fetch-go2rtc.sh`. | Acknowledgements.md, "go2rtc"; [docs/third-party/go2rtc.md](docs/third-party/go2rtc.md) |

Versions are those pinned in `Packages/CameraBridgeKit/Package.resolved`, `Archive/mac-app/project.yml` and `Tools/fetch-go2rtc.sh` (Camera Bridge OS: `linux/os/fetch-go2rtc.sh`, `linux/helpers/wyze-lake/go.mod`, `linux/helpers/eufy-bridge/pins.env` and `package-lock.json`).

Apple's system frameworks (CryptoKit, Network, VideoToolbox, AVFoundation, SwiftUI and others) and the `dns_sd`
(Bonjour) API are used through their public interfaces under Apple's SDK terms; none of their code is copied.

### Files derived from HAP-NodeJS

These files begin with "Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0.
Modified for CameraBridge." which is also the notice that they were changed (Apache-2.0 section 4(b)):

- `Interop/node/lib/goldens/hds-frames.mjs`
- `Packages/CameraBridgeKit/Sources/HAP/Definitions/CharacteristicType+Definitions.swift`
- `Packages/CameraBridgeKit/Sources/HAP/Definitions/ServiceType+Definitions.swift`
- `Packages/CameraBridgeKit/Sources/HAP/Model/Accessory.swift`
- `Packages/CameraBridgeKit/Sources/HAP/Model/Characteristic.swift`
- `Packages/CameraBridgeKit/Sources/HAP/Model/HAPJSONEncoding.swift`
- `Packages/CameraBridgeKit/Sources/HAP/Model/Publication.swift`
- `Packages/CameraBridgeKit/Sources/HAP/Model/Service.swift`
- `Packages/CameraBridgeKit/Sources/HAP/Server/AccessoryServer+Characteristics.swift`
- `Packages/CameraBridgeKit/Sources/HAP/Server/AccessoryServer+Pairing.swift`
- `Packages/CameraBridgeKit/Sources/HAP/Server/AccessoryServer.swift`
- `Packages/CameraBridgeKit/Sources/HAP/Server/HAPConnection.swift`
- `Packages/CameraBridgeKit/Sources/HAPCamera/CameraController.swift`
- `Packages/CameraBridgeKit/Sources/HAPCamera/CameraTLV.swift`
- `Packages/CameraBridgeKit/Sources/HAPCamera/PersistedCameraState.swift`
- `Packages/CameraBridgeKit/Sources/HAPCamera/RTPStreamManagement.swift`
- `Packages/CameraBridgeKit/Sources/HAPCamera/RecordingStream.swift`
- `Packages/CameraBridgeKit/Sources/HAPCore/Identity.swift`
- `Packages/CameraBridgeKit/Sources/HDS/DataStreamConnection.swift`
- `Packages/CameraBridgeKit/Sources/HDS/DataStreamServer.swift`
- `Packages/CameraBridgeKit/Sources/HDS/HDSCodec.swift`
- `Packages/CameraBridgeKit/Sources/HDS/HDSFrameCodec.swift`
- `Packages/CameraBridgeKit/Sources/TestSupport/Controller/ControllerTLV.swift`
- `Packages/CameraBridgeKit/Sources/TestSupport/Controller/DataSendReassembler.swift`
- `Packages/CameraBridgeKit/Sources/TestSupport/HAPTestController.swift`
- `Packages/CameraBridgeKit/Sources/TestSupport/HDSTestClient.swift`
- `Packages/CameraBridgeKit/Tests/HDSTests/DataStreamParserSpecTests.swift`
- `Tools/hap-definitions/generate.mjs`

Most are shipped in the app. `Packages/CameraBridgeKit/Sources/TestSupport`, `Packages/CameraBridgeKit/Tests`,
`Interop/` and `Tools/` are development and test tooling and are not part of the app.

The `HAP/Definitions/*+Definitions.swift` files are generated by `Tools/hap-definitions/generate.mjs` from HAP-NodeJS's
service and characteristic definitions; the generator is not shipped.

## Used only when the engine is built for Linux

| Component | License | Notes |
|---|---|---|
| BoringSSL, inside swift-crypto (`CCryptoBoringSSL`) | OpenSSL / ISC-style (see swift-crypto's `LICENSE.txt` and `NOTICE.txt`) | swift-crypto compiles it in only on non-Apple platforms; the macOS app does not contain it. |
| [go2rtc](https://github.com/AlexxIT/go2rtc) 1.9.14+dev.c245815 (commit `c245815e75e2a5fd60b4290f12bfc04e55a984d3`) | MIT (built from Go modules under their own permissive licenses, listed in its `go.mod`) | Camera Bridge OS only: the helper program at `/usr/lib/camera-bridge/helpers/go2rtc`, built unmodified from that commit and checksum-verified by `linux/os/fetch-go2rtc.sh`; run as a separate process. Licence in the image at `/usr/share/doc/go2rtc/copyright`; details in [docs/third-party/go2rtc.md](docs/third-party/go2rtc.md). |
| wyze-lake 0.1.0: the Go modules linked into it — the Go standard library (go1.24.13), `golang.org/x/crypto`, `x/net`, `x/sys`, `x/time`, `github.com/google/uuid`, `github.com/wlynxg/anet` (BSD-3-Clause), `github.com/gorilla/websocket` (BSD-2-Clause) and 15 `github.com/pion/*` WebRTC modules (MIT) | BSD-3-Clause, BSD-2-Clause, MIT | Camera Bridge OS only: `/usr/lib/camera-bridge/helpers/wyze-lake`, Camera Bridge's own helper for Wyze's cloud cameras ([`linux/helpers/wyze-lake`](linux/helpers/wyze-lake), itself MIT-licensed), a static binary built by `linux/os/build-helpers.sh`. Texts in `linux/helpers/wyze-lake/LICENSES/` and in the image at `/usr/share/doc/wyze-lake/`; versions in [docs/third-party/wyze-lake.md](docs/third-party/wyze-lake.md). |
| [Node.js](https://nodejs.org) 24.21.0 | MIT (and the licences of the components it bundles, in its `LICENSE` file) | Camera Bridge OS only (amd64): the runtime of the eufy-bridge helper, `/usr/lib/camera-bridge/helpers/eufy/node`, the official linux-x64 binary, unmodified and checked against pinned SHA-256s (`linux/helpers/eufy-bridge/pins.env`). Licence in the image at `/usr/lib/camera-bridge/helpers/eufy/LICENSES/node/LICENSE`. |
| [@mega-yfue/eufy-sdk](https://www.npmjs.com/package/@mega-yfue/eufy-sdk) 0.4.0 (commit `7d1f016362465b0747405c5dc83124c86b2c630b`) | Apache-2.0 | Camera Bridge OS only (amd64): bundled into the eufy-bridge helper (`/usr/lib/camera-bridge/helpers/eufy/eufy-bridge.js`, source [`linux/helpers/eufy-bridge`](linux/helpers/eufy-bridge)); its protobufjs loader is rewritten at bundle time, nothing else is modified (see NOTICE). No upstream NOTICE file. |
| npm packages bundled with the eufy SDK: @babel/runtime 7.29.10, abort-controller 3.0.0, bl 6.1.6, broker-factory 3.1.15, debug 4.4.3, event-target-shim 5.0.1, fast-unique-numbers 9.0.27, ip-address 10.7.4, mqtt 5.16.1, mqtt-packet 9.0.2, ms 2.1.3, process 0.11.10, process-nextick-args 2.0.1, readable-stream 4.8.0, rfdc 1.4.1, safe-buffer 5.2.1, smart-buffer 4.2.0, socks 2.8.10, string_decoder 1.3.0, worker-timers 8.0.34, worker-timers-broker 8.0.18, ws 8.22.0 (MIT); inherits 2.0.4, lru-cache 10.4.3 (ISC); jpeg-js 0.4.4, protobufjs 8.8.1 (BSD-3-Clause); long 5.3.2 (Apache-2.0) | MIT, ISC, BSD-3-Clause, Apache-2.0 | Camera Bridge OS only (amd64), inside `eufy-bridge.js`, unmodified. Every licence text is in the image at `/usr/lib/camera-bridge/helpers/eufy/LICENSES/`; list in [docs/third-party/eufy-bridge.md](docs/third-party/eufy-bridge.md). |

## Development and test tooling (not shipped)

| Component | License | Use |
|---|---|---|
| `@homebridge/hap-nodejs` 2.2.3 | Apache-2.0 | Reference accessory and pairing oracle in `Interop/node` (installed with `npm ci`, never committed or shipped). |
| `hap-controller` 0.10.2 | MPL-2.0 | HAP controller used as a test oracle in `Interop/node` (installed with `npm ci`, never committed or shipped). |
| `fast-srp-hap` 2.0.4 and their npm dependencies | see `Interop/node/package-lock.json` | Test oracles only. |
| esbuild 0.28.2 | MIT | Bundles the eufy-bridge helper (`linux/helpers/eufy-bridge`, installed with `npm ci` inside the build container); not shipped. |
| FFmpeg | LGPL/GPL, depending on the build | Optional test oracle (`Packages/CameraBridgeKit/Tests/RTPTests/FFmpegOracleTests.swift`, `Tools/capture_stream.sh`) when an `ffmpeg` binary is installed. Not bundled, not linked, not distributed. |

## Referenced, not copied

The source comments and module READMEs mention other projects whose *behavior* or public protocol documentation informed
the implementation. According to those notes no code from them was ported, and none is included:

- **Scrypted** plugins for ONVIF, Hikvision, Reolink and UniFi, and its SRTP/RTP and recording behavior: read as a
  behavioral reference only. No Scrypted code is included (many of its plugins carry no license).
- ONVIF, ISO/IEC 14496, RFC and manufacturer API documents: public specifications.

Test fixtures under `Packages/CameraBridgeKit/Tests/**/Fixtures` are synthetic, written for these tests from the public
formats; they were not captured from real devices.

## Trademarks and the HomeKit Accessory Protocol

Apple, Apple Home, HomeKit, HomePod and related marks belong to Apple Inc. Camera Bridge implements the HomeKit Accessory
Protocol independently and is not part of Apple's MFi Program; it is not affiliated with Apple.

## Updating this file

When a dependency is added or its version changes, update the table and, where the license asks for it, `NOTICE`. The Mac
app's own notices (`Archive/mac-app/App/Resources/Acknowledgements.md`) are archived with it and are not kept up to date.
