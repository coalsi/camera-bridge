# cbctl

Developer HAP controller CLI (`swift run cbctl --help`). Dev-only; never embedded in the app. The commands live in
TestSupport's `ControllerCLI` (so tests drive them in-process); `main.swift` only forwards the arguments.

## Commands

```
cbctl pair <host:port> <setup-code>          pair-setup + pair-verify, store the pairing
cbctl accessories                            print the /accessories JSON
cbctl watch-motion [--seconds N]             subscribe to every MotionDetected and print events
cbctl snapshot <out.jpg> [--width W] [--height H]
cbctl live <seconds> <out.h264> [--width W] [--height H] [--fps F]
cbctl record <out.mp4> [--seconds N] [--fragments N] [--no-audio]
cbctl unpair                                 remove our pairing on the accessory and locally
```

Global options: `--home DIR` (store directory), `--accessory host:port|ID` (default: most recently paired),
`--aid N`, `--timeout S`. Exit codes: 0 ok, 1 failure, 64 usage.

## Behaviour

- Connects by host:port only (IPv6 as `[::1]:port`); never advertises anything.
- Pairing data in `~/.cbctl/` (or `$CBCTL_HOME`, `--home`): `controller.json` (controller identity incl. its Ed25519
  key) and `accessories.json` (host, port, accessory ID + public key); files 0600. A directory cbctl creates is 0700;
  an existing one must already be private (no group/other access) — cbctl refuses it otherwise and never chmods it.
  The setup code and keys are never printed.
- `pair` stores the pairing as soon as pair-setup succeeds (the accessory then counts cbctl as its admin and refuses
  another pair-setup). If pair-verify or GET /accessories fails afterwards it exits 1 with the pairing kept: retry any
  command, or `cbctl unpair --accessory host:port` to release the accessory.
- `live`: SetupEndpoints with a local `SRTPTestReceiver`, `start` at the requested (or nearest offered) resolution with
  Opus audio when offered, receiver reports as keepalive, writes complete access units from the first keyframe as
  Annex B, then `end`.
- `record`: reads the Supported* recording values, writes a hub-like SelectedCameraRecordingConfiguration, turns on
  HomeKitCameraActive / EventSnapshotsActive / recording Active / RecordingAudioActive, opens HDS, `dataSend/open`,
  writes init + fragments until `endOfStream` (then `ack`), `--fragments`, `--seconds` (then `close`).
