# Interop oracles (dev-only)

`Interop/node/` holds independent references that CameraBridge is tested against. They run only on a developer
Mac. Nothing in them ships, and the app never loads Node.

- **Golden generator** (`goldens.mjs`): writes JSON test vectors from HAP-NodeJS 2.2.3 and fast-srp-hap 2.0.4
  into `Packages/CameraBridgeKit/Tests/<Module>Tests/Fixtures/`.
- **Controller oracle** (`pair-oracle.mjs`): uses hap-controller 0.10.2 as an independent HAP controller to run
  the whole pairing lifecycle against an accessory.
- **Reference accessory** (`reference-accessory.mjs`): a HAP-NodeJS camera that stays on loopback. It shows
  that the oracle works.

## Quick start

```sh
cd Interop/node
npm ci                                   # exact versions from package-lock.json; runs no install scripts (.npmrc)
node goldens.mjs                         # (re)write every fixture; prints wrote/unchanged per file
node goldens.mjs --check                 # CI-style: exit 1 if any fixture is missing or stale
npm test                                 # node:test suite (goldens, HDS encoder, loopback guard, oracle e2e incl. faults)

# Prove the oracle against the reference accessory (terminal 1, then terminal 2):
node reference-accessory.mjs --port 0 --setup-code 482-73-619 --motion-interval-ms 1000
#   → {"event":"ready","host":"127.0.0.1","port":<P>,…}
node pair-oracle.mjs 127.0.0.1 <P> 482-73-619 --seconds 5 --min-events 2
#   → JSON summary on stdout; exit 0. Stop the accessory with Ctrl-C.

# Against an unpaired CameraBridge accessory listening on loopback (e.g. the IntegrationTests engine):
node pair-oracle.mjs 127.0.0.1 <hapPort> <setupCode>
```

`node goldens.mjs srp` (or `tlv8`, `setup-payload`, `hds-codec`, `hds-frames`, `camera`) regenerates one
section. `--out <dir>` writes to another Tests directory instead.

`Interop/node/.npmrc` sets `ignore-scripts=true`. hap-controller depends on BLE and USB packages (`@stoprocent/noble`,
`usb`, `@serialport/bindings-cpp`) whose install scripts build native code with node-gyp or download prebuilt
binaries. The oracles only ever load hap-controller's IP transport, so no native module is needed, and `npm ci`
neither compiles nor downloads anything beyond the locked tarballs.

## Fixtures

| File | Consumer | Contents |
|---|---|---|
| `HAPCoreTests/Fixtures/srp.json` | `SRPTests` | SRP-6a vectors (I, P, salt, a, b → v, A, B, K, M1, M2) from fast-srp-hap. Inputs: our own SHA-256-derived values, plus the RFC 5054 App. B salt/a/b. Never the NC-spec vector. |
| `HAPCoreTests/Fixtures/tlv8.json` | HAPCore TLV8 | `encode`, `decode` (fragments merge after a 255-byte item; separators kept), `invalid` (→ `TLV8Error`), `lists` (`splitList` at `FF 00` / `00 00`) |
| `HAPCoreTests/Fixtures/setup-payload.json` | HAPCore `SetupPayload` | `X-HM://` URIs for 5 categories × several codes and setup IDs; TXT `sh` hashes |
| `HDSTests/Fixtures/hds-codec.json` | `HDSCodec` (`HDSCodecFixtureTests`) | `values` (typed value → canonical bytes, plus HAP-NodeJS's writer output and reader verdict), `decodeOnly` (non-canonical forms, back-references), `invalid` |
| `HDSTests/Fixtures/hds-frames.json` | `HDSFrameCodec` (`HDSFrameCodecFixtureTests`) | `messages` (header/payload bytes for control/hello and dataSend open/data/ack/close), `keys` (HKDF read/write keys), `frames` (sealed frames at given counters) |
| `HAPCameraTests/Fixtures/camera-tlv.json` | W2-1 `CameraController` | Supported video/audio/RTP stream TLVs and supported recording TLVs for the v1 options (camera and doorbell), `SelectedCameraRecordingConfiguration` parses, `0103010100`, streaming status, SetupEndpoints default. Streaming cases without `decodeOnly` can be built from `CameraStreamingOptions`. Channels 1, bitrate mode 0 and comfort noise off are implied. The one `decodeOnly` case (comfort noise on) is for parser tests only. Recording `isDoorbell` is `CameraControllerConfiguration.isDoorbell`. |

Each file has a `generator` or `source` field that names the tool and its version, and a `notes` array that
says exactly what the Swift API must do with each case. Swift tests read the files through
`URL(fileURLWithPath: #filePath)`. They are not SwiftPM resources: the test targets `exclude: ["Fixtures"]`.
Because the build never sees a fixture that no test opens, `PortabilityTests`' `FixtureUsageTests` fails when no
`.swift` file of a target names one of its `Fixtures/` files (by path or file name).

### Where CameraBridge differs from HAP-NodeJS

Some cases record HAP-NodeJS behaviour that CameraBridge must not copy. The fixtures document every one of
these per case.

- **HDS values.** CameraBridge writes canonical forms (plan W1-6), which differ from HAP-NodeJS in these ways:
  - Integer 39 uses tag `0x2F`. The HAP-NodeJS reader stops at `0x2E`.
  - int64 values are written in full. The HAP-NodeJS writer writes only 32 bits and throws outside 0…2³²−1.
  - Data of 0–32 bytes is readable. The HAP-NodeJS reader drops it.
  - Arrays of 13 or 14 items use the count form. HAP-NodeJS writes the terminated form for more than 12 items.
  - Back-references are never emitted. HAP-NodeJS emits them for repeated strings, ints, floats and data.
- **Back-reference numbering.** The HAP-NodeJS reader and writer count back-references differently. The reader
  also counts bools and the integers −1…39. The `decodeOnly` cases avoid that ambiguity.
- **HDS headers.** HDS headers always write `id` and `status` as int64 (tag `0x33`), as the brief §3.8
  hello-response golden shows.
- **Camera TLVs.** Camera TLV list elements are separated by `00 00`. This includes the sample-rate and
  resolution lists.

## Safety rules

- **Loopback only.** `reference-accessory.mjs` installs `lib/loopback-guard.mjs` before HAP-NodeJS starts:
  - Every TCP listener binds 127.0.0.1. Without the guard, HAP-NodeJS would still bind 0.0.0.0 for
    `bind: ["127.0.0.1"]`, and its DataStreamServer always binds all interfaces.
  - `dgram.createSocket` throws, so no mDNS or RTP can go out.
  - The mDNS advertisers are replaced with no-ops. The accessory is never announced on `_hap._tcp`.
  - The accessory refuses to run if its HAP server is not on 127.0.0.1.
  - The test suite also uses `lsof` to check that the process has only 127.0.0.1 listeners and no UDP sockets.
- **Throwaway storage.** The reference accessory stores its data in a fresh temporary directory, deleted on
  exit, unless you pass `--storage`. Point `TMPDIR` at a scratch area if you want it elsewhere. The accessory
  exits after `--lifetime-s` (default 900).
- **No secrets in output.** `pair-oracle.mjs` never prints long-term keys or the setup code. Its summary holds
  only pairing identifiers, per-step results, read statuses and values (long values truncated), and events.
- **Hands off shared services.** Do not point the oracle at anyone's live Homebridge or Scrypted instances, and
  never stop or restart them.

## Oracle details

| Step | What it checks |
|---|---|
| `pairSetup` | M1–M6 with Method 0 (`--method 1` for PairSetupWithAuth, hap-controller's own default; the e2e suite runs both) |
| `pairVerify` | M1–M4 on the persistent session connection |
| `listPairings` | this controller is listed, ≥ 1 admin |
| `getAccessories` | well-formed database (aid, services with iid/type, characteristics with iid/type/perms/format) |
| `readCharacteristics` | every `pr` characteristic (`meta&perms&type&ev`), status 0 and value matching its format. Two exceptions: `ProgrammableSwitchEvent` may read `null`, and `SelectedCameraRecordingConfiguration` (`209`) may answer −70402 before selection (`--strict` removes this allowance; `--expect-status TYPE=STATUS` adds others) |
| `subscribeMotion` | `ev:true` on every MotionDetected, sent on a separate pair-verified connection. The answer must be 204, or a 207 with status 0 for every requested characteristic. A 207 that carries −70406, −70402 or any other non-zero status fails the run, and so does a missing entry or a malformed body |
| `events` | events are logged for `--seconds`. The step fails with fewer than `--min-events` (default 0) or with an EVENT body that is not JSON |
| `unsubscribeMotion` | `ev:false` on the same connection, with the same 204 / all-zero-207 rule |
| `removePairing` | remove this controller |
| `verifyRemoved` | pair-verify with the removed keys must be refused with kTLVError_Authentication (2) in M2 or M4. A refused connection, a reset or any other error fails the step, because it does not show the pairing is gone |
| cleanup (`summary.cleanup`) | not a step and never changes the verdict. If a run fails after `pairSetup` and before `removePairing` succeeds, the oracle tries to remove its own pairing with a fresh client (timeout ≤ 5 s). It records `{needed, removed, error?}`, so a failed run does not leave the target paired to a controller whose keys were never printed. `{needed: false}` means there was nothing to remove |

Why the oracle sends the `ev` writes itself: hap-controller 0.10.2's `subscribeCharacteristics()` only rejects a
status other than 204/207 and throws away the per-characteristic statuses of a 207. Its
`unsubscribeCharacteristics()` never unsubscribes at all, because of an inverted check.

### Reference accessory faults (tests only)

`reference-accessory.mjs --fault …` (repeatable) makes the reference accessory misbehave, so the e2e suite can
show that the oracle fails when it should:

| Fault | Behaviour | Oracle result |
|---|---|---|
| `subscribe[=STATUS]` | `ev:true` on MotionDetected answers 207 with STATUS (−70412…−70401, default −70406) and does not subscribe | exit 1 at `subscribeMotion`, pairing cleaned up |
| `unsubscribe[=STATUS]` | the same for `ev:false` | exit 1 at `unsubscribeMotion`, pairing cleaned up |
| `close-on-unpair` | stops accepting HAP connections once the last admin is removed (open connections stay) | exit 1 at `verifyRemoved` (ECONNREFUSED is not a refusal) |

The `ready` line lists the active faults (`"faults": []` when there are none).

## End-to-end oracles (plan W3-2)

The end-to-end suites in `Packages/CameraBridgeKit/Tests/IntegrationTests/EndToEnd/` run a real `BridgeEngine`
(`BridgeEnvironment.testing`: loopback only, in-memory secrets, a recording advertiser at most — never Bonjour).
Two of them use the oracles above and are opt-in:

```sh
cd Interop/node && npm ci && cd -                              # once
cd Packages/CameraBridgeKit
CB_NODE_ORACLE=1   swift test --filter 'IntegrationTests.EndToEndTests.NodeOracle'
CB_FFMPEG_ORACLE=1 swift test --filter 'IntegrationTests.EndToEndTests.FFmpegOracle'
CB_NODE_ORACLE=1 CB_FFMPEG_ORACLE=1 swift test --filter 'IntegrationTests'   # everything
```

- **`NodeOracle`** (`CB_NODE_ORACLE=1`; `CB_NODE` overrides the Node binary): starts the engine with a demo camera
  (motion hold 1 s, a test motion pulse every 2 s) and runs `node Interop/node/pair-oracle.mjs 127.0.0.1 <port>
  <code> --seconds 6 --min-events 2` twice, with `--method 0` and `--method 1`. Each run must exit 0 with every
  step in order, no failed read, at least two MotionDetected events and no cleanup. The recorded TXT record must go
  from `sf=1` to `sf=0` and end at `sf=1`. TXT updates are debounced by 1 s, so the second run's pair-setup, which
  comes less than a second after the first run's removal, may fold into the paired state already announced.
- **`FFmpegOracle`** (`CB_FFMPEG_ORACLE=1`; `CB_FFMPEG` / `CB_FFPROBE` override the Homebrew binaries) has two tests:
  - ffprobe reads a 3-fragment HKSV recording (init + fragments as one file). It must find H.264 `avc1` Main
    ≤ 4.0 at 1920×1080, and AAC-LC at 32 kHz mono. It must also find one packet per video sample, with a
    keyframe first. ffmpeg must then decode the whole file with `-xerror` and print nothing.
  - ffmpeg acts as the controller's media endpoint for a live view. The test writes an SDP with two `RTP/SAVP`
    m-lines (H.264/90000 and opus/24000/2), each with `a=rtcp-mux` and
    `a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:<key‖salt>`. SetupEndpoints names ffmpeg's ports. ffmpeg must
    decode 6 s, at least 100 video frames and 150 Opus frames, with `-xerror` and no SRTP complaints. The stream
    opens with the camera's latest keyframe and continues from its next one, up to a GOP later, so the window is
    longer than the frames it requires.
