# Third-party licenses

Camera Bridge itself is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE). It contains, links to or is
built with the third-party software below, each under its own license. This file is the index; the **full license texts**
are in [`App/Resources/Acknowledgements.md`](App/Resources/Acknowledgements.md), which is bundled in the app and shown
under *About > Acknowledgements*. Attribution notices that licenses require are in [NOTICE](NOTICE).

The PolyForm license applies to Camera Bridge's own code only. It does not change the terms of anything listed here.

## Shipped in the macOS app

| Component | Version | License | Where it is used | Full text |
|---|---|---|---|---|
| HAP-NodeJS (derived code, not linked) | 2.2.3 | Apache-2.0 | Portions of the HomeKit protocol layers (`HAP`, `HAPCore/Identity`, `HAPCamera`, `HDS`) are derived from its TypeScript sources and modified. | Acknowledgements.md, "HAP-NodeJS" (Apache-2.0 text) |
| [swift-crypto](https://github.com/apple/swift-crypto) | 3.15.1 | Apache-2.0 | Cryptography (`Crypto`; on macOS this re-exports Apple CryptoKit). | Acknowledgements.md, "swift-crypto" (with its NOTICE) |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.3 | Apache-2.0 | Dependency of swift-crypto. | Acknowledgements.md, "swift-asn1" (with its NOTICE) |
| [BigInt](https://github.com/attaswift/BigInt) | 5.7.0 | MIT | Arbitrary-precision integers for SRP pair-setup. | Acknowledgements.md, "BigInt" |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | MIT, plus bundled components under BSD-2-Clause-style, MIT and zlib-style licenses (bsdiff, sais-lite, orlp/ed25519, SUSignatureVerifier) | Software updates (`App/Sources/Updates`). Embedded as `Sparkle.framework`. | Acknowledgements.md, "Sparkle" |
| [go2rtc](https://github.com/AlexxIT/go2rtc) | 1.9.14 | MIT (built from Go modules under their own permissive licenses, listed in its `go.mod`) | Helper program for cloud cameras and consoles (Ring, Nest, Wyze, Tuya, UniFi RTSPS). Bundled unmodified as `Contents/Helpers/go2rtc` and run as a separate process; fetched and checksum-verified by `Tools/fetch-go2rtc.sh`. | Acknowledgements.md, "go2rtc"; [docs/third-party/go2rtc.md](docs/third-party/go2rtc.md) |

Versions are those pinned in `Packages/CameraBridgeKit/Package.resolved`, `project.yml` and `Tools/fetch-go2rtc.sh`.

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

## Development and test tooling (not shipped)

| Component | License | Use |
|---|---|---|
| `@homebridge/hap-nodejs` 2.2.3 | Apache-2.0 | Reference accessory and pairing oracle in `Interop/node` (installed with `npm ci`, never committed or shipped). |
| `hap-controller` 0.10.2 | MPL-2.0 | HAP controller used as a test oracle in `Interop/node` (installed with `npm ci`, never committed or shipped). |
| `fast-srp-hap` 2.0.4 and their npm dependencies | see `Interop/node/package-lock.json` | Test oracles only. |
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

When a dependency is added or its version changes, update the table, `App/Resources/Acknowledgements.md` (and its
fallback in `App/Sources/Model/Acknowledgements.swift`) and, where the license asks for it, `NOTICE`.
