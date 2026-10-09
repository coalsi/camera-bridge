# The go2rtc streaming helper

[go2rtc](https://github.com/AlexxIT/go2rtc) (MIT, version pinned in `Tools/fetch-go2rtc.sh`) is a program that speaks the protocols of cloud cameras and consoles (Ring, Google Nest, Wyze, Tuya, UniFi's RTSPS, Kasa, Xiaomi, …) and republishes each camera as RTSP. Camera Bridge bundles it as `Camera Bridge.app/Contents/Helpers/go2rtc` and runs it as a child process. The licence text is in [../third-party/go2rtc.md](../third-party/go2rtc.md).

## What runs

- **One helper process** serves every camera that uses it. It starts when the first such camera starts and ends with the last (or when the bridge stops). Camera Bridge's ordinary RTSP ingest then reads `rtsp://127.0.0.1:<port>/cb-<camera id>` like any camera.
- **Ports.** The API and RTSP ports are free ports on this Mac, picked at random the first time and kept while the app runs, so the addresses stay valid when the helper restarts. Both bind `127.0.0.1` only. The helper's web API asks for a random password on every run, even from this Mac.
- **Supervision.** The helper is restarted after a crash, waiting 1 s, 2 s, 4 s … up to 60 s between attempts (starting over after it ran 30 s). A health check on its API decides when it is up. Adding or removing a cloud camera restarts the helper (go2rtc reads its configuration once): other cloud cameras reconnect within a few seconds. Its output goes to the Camera Bridge log (Settings › Diagnostics) with secrets masked; its warnings and errors about a camera appear in that camera's log and in the message when a check fails.
- **A previous run's leftovers.** The helper's process ID is kept in `go2rtc/go2rtc.pid` in the app's data folder; after a crash of the app the next start ends a helper left behind (only if that process is still go2rtc).

## What it is allowed to do

go2rtc can run programs, read files, open tunnels and talk to Home Assistant. Camera Bridge starts it with only the modules it needs (`api`, `rtsp`, `ring`, `nest`, `tuya`, `wyze`, `tapo`, `doorbird`, `dvrip`, `xiaomi`); `exec`, `echo`, `expr`, `ffmpeg`, `ngrok`, `pinggy`, `hass`, `homekit`, `webtorrent`, `webrtc` and the rest are not started, and its API serves only `/api` and `/api/streams`. A pasted source that would run something (`exec:`, `echo:`, `expr:`, `ffmpeg:`, `http:`, `file:`) is refused by the wizard before it is saved.

## Secrets

- A camera's **source** (the go2rtc address with its tokens, e.g. `ring:?…&refresh_token=…`) is the camera's Keychain "password". `config.json` holds only the service (`ring`) and the camera's name.
- The helper's **configuration file** (`go2rtc/go2rtc.yaml`, 0600 in a 0700 folder) contains no secret either: each source is written as `${CB_SRC_0}`, and go2rtc fills it from an environment variable it is started with. The file is removed as soon as the helper answers and when it stops.
- Nothing is put on a command line (the only argument is the path of the file) or in the log (go2rtc masks the values it was started with, and Camera Bridge masks `refresh_token`, `password`, `secret`, `enr`, `uid`, `mac` and stream keys in what it logs).
- A process of your own user can still read the helper's environment, as it could read the app's memory. The helper is the same user as the app.

## The sign-in page

For Ring, Wyze, Tuya (and Google Nest) go2rtc has pages where you sign in and get the source for each camera. **Open Sign-In Page** in the wizard starts a second, short-lived helper that serves only those pages (on `127.0.0.1`, a random port, closed after 20 minutes or when the wizard closes) and opens it in your browser. You type your account into **go2rtc's page, not Camera Bridge**; Camera Bridge only receives the source you paste back. (For Wyze, go2rtc's page writes the account's password into the page helper's own configuration file in a private temporary folder, which is deleted when the page closes.)

## Building the app with the helper

```bash
Tools/fetch-go2rtc.sh        # downloads the pinned release, checks its SHA-256, builds build/helpers/go2rtc (universal)
xcodebuild … build           # the "Embed go2rtc helper" phase copies it to Contents/Helpers and signs it
```

- `Tools/fetch-go2rtc.sh` takes go2rtc **only** from the official GitHub release of the pinned version and **refuses any file whose SHA-256 is not the pinned one** (a mirror can be named with `CB_GO2RTC_BASE_URL` but cannot change what is accepted). `--verify` checks the cache and the built binary without a network. `Tools/test-fetch-go2rtc.sh` tests it, including a corrupted download.
- Without `build/helpers/go2rtc` the build phase prints a note and the app is built without the helper: the wizard's cloud types then say the helper is missing, and nothing else changes.
- Signing: development builds sign it ad hoc; a Developer ID build signs it with the same identity, the hardened runtime and a secure timestamp (what notarization needs). The app itself must not be sandboxed to run it (the Developer ID build is not).

## Updating go2rtc

1. Choose the release on <https://github.com/AlexxIT/go2rtc/releases>; note the SHA-256 GitHub shows for `go2rtc_mac_arm64.zip` and `go2rtc_mac_amd64.zip` and check them against the downloaded files.
2. Change `VERSION` and both checksums in `Tools/fetch-go2rtc.sh`, and the version in `docs/third-party/go2rtc.md`.
3. Run `Tools/test-fetch-go2rtc.sh <folder with the two zips>` and the real-binary tests: `CAMERABRIDGE_GO2RTC_DIR=build/helpers swift test --filter Go2RTCRealBinaryTests` in `Packages/CameraBridgeKit` (they start the helper on loopback, check it listens on nothing else, that its API wants the password, that the secret never reaches a file, and that the sign-in page serves; no cloud is contacted).
4. Read go2rtc's release notes for changes to the `ring`, `nest`, `tuya` and `wyze` sources.

## Troubleshooting

| Message | Meaning |
|---|---|
| "The streaming helper (go2rtc) is not installed with this copy of Camera Bridge." | The app was built without `build/helpers/go2rtc`. |
| "The streaming helper (go2rtc) is not running: it ended right after starting (…)" | go2rtc exited at start; the log has its last lines. Quitting and reopening Camera Bridge picks new ports. |
| "<Service> did not deliver video in time. go2rtc says: …" | The helper is running but the service refused or timed out; its words follow. Wrong or expired token, camera offline, or the service changed. |
| Camera offline after working for weeks | Tokens expire (Ring); sign in again: camera page › Connection › Replace Source… |
