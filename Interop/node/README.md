# Interop/node — dev-only oracles

Independent references CameraBridge is checked against (plan task W1-9). Never shipped, never linked.
Pinned: `@homebridge/hap-nodejs` 2.2.3 (Apache-2.0), `hap-controller` 0.10.2 (MPL-2.0, IP transport only —
its BLE half is never loaded), `fast-srp-hap` 2.0.4 (MIT). Node ≥ 24. Full guide: `docs/interop.md`.
`.npmrc` sets `ignore-scripts=true`: `npm ci` builds and downloads no native code (the BLE/USB dependencies'
install scripts never run; nothing here needs them).

## Entry points

- `node goldens.mjs [section …] [--check] [--out DIR]` — writes the JSON goldens below (all sections by
  default); `--check` writes nothing and exits 1 on a missing or stale fixture, 2 on bad usage.
- `node pair-oracle.mjs <host> <port> <setupCode> [--seconds N] [--min-events N] [--timeout-ms N] [--strict]
  [--expect-status TYPE=STATUS] [--method 0|1] [--device-id LABEL] [--quiet]` — pair-setup, pair-verify,
  list-pairings, `/accessories`, read every `pr` characteristic, subscribe to MotionDetected (204, or 207 with
  every status 0) and log events for N s, unsubscribe (same rule), remove the pairing, confirm pair-verify is then
  refused with kTLVError_Authentication. A run that fails after pair-setup removes its own pairing
  (`summary.cleanup`). JSON summary on stdout; exit 0 ok, 1 a step failed, 2 bad usage.
- `node reference-accessory.mjs [--port N] [--setup-code C] [--storage DIR] [--kind camera|doorbell]
  [--motion-interval-ms N] [--device-id MAC] [--lifetime-s N] [--fault subscribe[=STATUS]|unsubscribe[=STATUS]|close-on-unpair]…`
  — HAP-NodeJS camera/doorbell with the v1 options, used to prove the oracle. `--fault` makes it misbehave, so
  the tests can show the oracle fails. JSON lines on stdout (`ready` with `faults`, `paired`, `unpaired`).
- Plan W3-2: `CB_NODE_ORACLE=1 swift test --filter 'IntegrationTests.EndToEndTests.NodeOracle'` (from
  `Packages/CameraBridgeKit`, after `npm ci` here) runs `pair-oracle.mjs` against a live `BridgeEngine` camera on
  loopback. It runs once with `--method 0` and once with `--method 1`, and needs `--min-events 2` (the test
  pulses motion). See `docs/interop.md` § End-to-end oracles.
- `npm test` — node:test suite (`test/`): brief §3 goldens reproduced, fixtures up to date, canonical HDS
  encoder, loopback guard, oracle end-to-end against the reference accessory (Method 0 and 1, plus the faults:
  a refused subscription or unsubscription, and a listener that closes after unpairing).

## Goldens

| Section | Fixture (under `Packages/CameraBridgeKit/Tests/`) | Produced by |
|---|---|---|
| `srp` | `HAPCoreTests/Fixtures/srp.json` | fast-srp-hap (HAP 3072-bit group, SHA-512) |
| `tlv8` | `HAPCoreTests/Fixtures/tlv8.json` | HN `util/tlv` encode / decodeWithLists |
| `setup-payload` | `HAPCoreTests/Fixtures/setup-payload.json` | HN `Accessory.setupURI`, `computeSetupHash` |
| `hds-codec` | `HDSTests/Fixtures/hds-codec.json` | HN `DataStreamWriter`/`Reader` + canonical rules |
| `hds-frames` | `HDSTests/Fixtures/hds-frames.json` | HN `DataStreamServer` payload/HKDF/frame layout |
| `camera` | `HAPCameraTests/Fixtures/camera-tlv.json` | HN `CameraController`/`DoorbellController` |

Every fixture carries `generator`/`source` fields (srp.json: `source`) and `notes` describing its format; Swift
tests read them via `URL(fileURLWithPath: #filePath)` (the test targets exclude `Fixtures`).

## Invariants

- Deterministic: fixed inputs (SHA-256 of labels), no randomness; `goldens.mjs` twice → identical bytes.
- Every generator self-checks (throws on mismatch): SRP proofs verify both ways; setup URIs/hashes against the
  brief §3.3 formula; TLV decodes against `decodeWithLists`; HDS canonical bytes decode to their values; every
  HN divergence (0x2F, int64, short data, arrays > 12, back-references) is documented per case; HDS keys and
  frames re-derived/opened with `node:crypto`; camera options decode back from their TLVs.
- The reference accessory is loopback only (`lib/loopback-guard.mjs`): every TCP listener is forced onto
  127.0.0.1, UDP sockets are refused (no mDNS, no RTP) and HAP-NodeJS's advertisers are no-ops; it aborts if the
  HAP server is not on 127.0.0.1. Storage is a throwaway directory (auto-deleted unless `--storage` is given).
- The oracle never prints key material or the setup code; per-step timeouts (hap-controller has none).
- `hap-controller` 0.10.2's `subscribeCharacteristics` ignores the per-characteristic statuses of a 207, and its
  `unsubscribeCharacteristics` never unsubscribes (inverted check). The oracle sends both `ev` writes itself, on
  its own pair-verified connection, and checks every status.

## References

HAP-NodeJS 2.2.3 sources (lib/util/tlv.ts, lib/datastream/*, lib/camera/*, lib/controller/*), research brief
§3.2–§3.8, plan W1-6 item 1 (canonical HDS forms), research brief integration §5.1 (v1 options).
