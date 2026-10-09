# Camera Bridge OS: architecture

Camera Bridge OS is a small Linux system on a USB stick (or the SSD of a mini PC) that runs the same engine as Camera Bridge for Mac. You plug in ONVIF or RTSP cameras, open a web page, and Apple Home records them with HomeKit Secure Video. No Mac and no NVR are needed.

One repository, two products, one engine:

| Product | What it is | Release tag | Artifact |
|---|---|---|---|
| Camera Bridge for Mac | SwiftUI app, Developer ID signed, Sparkle updates | `v1.0`, `v1.1`, … | `CameraBridge-1.0.dmg` |
| Camera Bridge OS | Debian 13 image with the engine, a web UI and A/B updates | `os-v0.1`, `os-v0.2`, … | `camera-bridge-os-0.1-amd64.img.xz` (+ `.sha256`, `.sig`) |

## The engine is shared

`Packages/CameraBridgeKit` holds the engine. Every module except `PlatformApple` is portable Swift (the rule in `Tests/PortabilityTests`). A platform supplies these services (`BridgeSupport/PlatformServices.swift`, `MediaCore/Codecs.swift`):

| Service | macOS (`PlatformApple`) | Linux (`PlatformLinux`) |
|---|---|---|
| `NetworkTransport` (TCP, UDP) | Network.framework | POSIX sockets + Dispatch |
| `ServiceAdvertiser`, `ServiceBrowsing` (mDNS) | `dns_sd` | `dns_sd` API from `libavahi-compat-libdnssd` (same calls) |
| `SecretStore` | Keychain | encrypted file store (AES-GCM, key file `secrets/master.key` `0600`, the one the image creates at first boot; optional TPM seal) |
| `NetworkChangeMonitoring` | `NWPathMonitor` | netlink (`RTMGRP_LINK`, `RTMGRP_IPV4_IFADDR`, `RTMGRP_IPV6_IFADDR`) |
| `PowerManaging` | IOPM assertions | no-op (the box never sleeps) |
| `InstanceLocking` | flock | flock |
| `MediaCodecs` (decode, encode, scale, overlay, audio transcode, JPEG) | VideoToolbox, AudioToolbox, ImageIO | `ffmpeg` child processes, VA-API hardware encode when present |
| Helper process (go2rtc) | `ProcessHelperLauncher` | `Foundation.Process` |

HomeKit Secure Video needs H.264 video passed through untouched wherever possible. Transcoding is only needed for audio (AAC-ELD / Opus for live view, AAC-LC for recording), for cameras that send H.265, and for the timestamp overlay.

## Processes on the box

```
camerabridged        Swift daemon: BridgeEngine + web API (one process, user camerabridge)
  ├─ go2rtc          helper for Ring / Nest / Wyze / Tuya (started on demand)
  └─ ffmpeg          codecs (started per stream)
avahi-daemon         mDNS (HomeKit advertising)
camerabridge-web     not a process: camerabridged serves the web UI itself on :80 (and :443 with a local certificate)
```

State lives in `/var/lib/camera-bridge` (a separate data partition, so updates never touch it): `config.json`, `hap/`, `secrets/` (the encrypted items and `master.key`), `Diagnostics/`. This is the same layout the Mac app uses in `~/Library/Application Support/CameraBridge`.

## Web API (served by `camerabridged`)

JSON over HTTP on port 80 (`http://camera-bridge.local`). Types follow the Mac app's models (`CameraConfiguration`, `CameraStatus`, `DiscoveredCamera`, `NetworkNotice`) and its words (`StatusText`, the Add Camera wizard's pages and messages), so the two UIs say the same things. Errors are `{"error": "<code>", "message": "<a sentence for the person>", "field": "<input, when one is to blame>"}` with the usual status codes (400 invalid, 401 unauthorized, 403 csrf / cross_origin / setup_required, 404, 409, 415, 422 the engine refused, 429 too_many_attempts or too_many_streams, 503 no_picture). Every answer carries `Cache-Control: no-store` and the security headers.

Sessions: the `cb_session` cookie (see Security). Everything needs a session except the rows marked "open". Requests that change something also carry `X-CSRF-Token` (from `/session`, `/auth/login` or `/auth/setup`) and `Content-Type: application/json`.

```
GET    /api/v1/status                 open: {product, version, name, setupRequired, authenticated}; signed in: + state, uptime, camera counts, notices, system summary
GET    /api/v1/health                 open: 200 while the bridge runs (or is paused on purpose), 503 otherwise (the A/B update's health check)
GET    /api/v1/session                open: {authenticated, setupRequired, setupTokenRequired, bridgeName, csrfToken?}
POST   /api/v1/auth/setup             open, once: {password, bridgeName?, setupToken?} -> session
POST   /api/v1/auth/login             open: {password} -> {csrfToken, bridgeName} + cookie        (429 after 5 wrong tries per address)
POST   /api/v1/auth/logout
POST   /api/v1/auth/password          {current, new}; signs every other browser out
GET    /api/v1/camera-types           the Mac app's Camera Type page: groups, types, setup steps, what you get, which inputs
GET    /api/v1/cameras                {cameras: [camera]}; a camera is its CameraConfiguration JSON plus `status` (live state), vendorName, kindName, address
POST   /api/v1/cameras                add: {type, host, httpPort, rtspPort, onvifPort, useHTTPS, username, password, mainStreamURL, subStreamURL, source,
                                      apiKey, unifiCameraID, nestSession, nestDeviceID, name, kind, motionSource, motionSensitivity, motionHoldSeconds,
                                      sensors, audioEnabled, twoWayAudio}; checks the camera again, then adds it (201)
GET    /api/v1/cameras/{id}
PATCH  /api/v1/cameras/{id}           name, isEnabled, username, password, endpoint{host,ports,useHTTPS}, mainStreamURL, subStreamURL, motionSource,
                                      motionSensitivity, motionHoldSeconds, sensors{}, audioEnabled, twoWayAudio, liveStreamMode, liveQualityMode,
                                      liveMaxBitrateOverride, recordingStreamMode, recordingQualityMode, timestampOverlay{}
DELETE /api/v1/cameras/{id}
GET    /api/v1/cameras/{id}/snapshot  JPEG (503 + Retry-After while there is none)
GET    /api/v1/cameras/{id}/live      multipart/x-mixed-replace JPEGs, about one a second, at most 15 minutes, at most 6 at a time
GET    /api/v1/cameras/{id}/pairing   {accessoryName, paired, setupCode, setupURI, qrSVG, blocker?, blockerMessage?, blockerAction?}
POST   /api/v1/cameras/{id}/reset-pairing
POST   /api/v1/cameras/{id}/test-motion
POST   /api/v1/discover               ONVIF WS-Discovery -> {cameras: [{host, name, hardware, onvifPort, alreadyAdded}]}
POST   /api/v1/probe                  the same body as POST /cameras (no choices needed) -> {ok: true, vendor, model, streams, capabilities, suggestions,
                                      motionSources, sensorsByMotionSource, alreadyAdded?} or {ok: false, error}
POST   /api/v1/integrations/unifi/cameras   {host, apiKey, ...} -> the console's cameras
POST   /api/v1/integrations/nest/authorize  {projectID, clientID} -> {url};  .../nest/connect {projectID, clientID, clientSecret, code} -> {session, cameras}
GET    /api/v1/sensors-bridge         same shape as pairing; POST /api/v1/sensors-bridge/reset-pairing
GET    /api/v1/settings               {bridgeName, basePort, sensorsBridgePort, webhookEnabled, webhookPort, webhookToken, webhookProblem, logLevel, motionShadowTest}
PATCH  /api/v1/settings               the same keys (+ regenerateWebhookToken)
POST   /api/v1/bridge/pause | resume
GET    /api/v1/logs?since=&limit=&level=   {lines: [{date, level, category, message, cameraID}]}; with Accept: text/event-stream, `event: log` lines live
GET    /api/v1/diagnostics            the text bundle the Mac app exports (attachment)
GET    /api/v1/events                 server-sent events: bridge, camera, removed, motion, doorbell, notices (the current state first)
GET    /api/v1/system                 {product, version, build, mode (installed | development), osName, hostname, hardware, architecture, can*, canManage,
                                      sshEnabled?, automaticUpdates?, update?, install?}
POST   /api/v1/system/update          {action: "check" | "apply"}: check answers when the answer is in (at most 60 s); apply answers at once with state "downloading",
                                      then GET /system follows update.state (downloading -> ready, or error)
POST   /api/v1/system/reboot | poweroff   {confirm: true} -> 202
GET    /api/v1/system/disks           {disks: [{id, name, model, sizeBytes, note, eligible, problems[], phrase}]}: the installer's own list, usable or not
POST   /api/v1/system/install         {targetID, phrase, copyData?}: phrase is "ERASE ALL DATA ON <disk name>", typed by the person; -> 202, progress in GET /system install
POST   /api/v1/system/ssh             {enabled, authorizedKeys?}: key login for root, plain public keys only (up to 20) -> the system
POST   /api/v1/system/auto-update     {enabled} -> the system
POST   /api/v1/system/factory-reset   {confirm: "RESET"} -> 202 (erases settings and pairings, restarts)
```

Changes to the first draft of this contract: `POST /probe` and `POST /cameras` take the wizard's inputs by camera type (`GET /camera-types` says which); `/auth/setup | login | logout | password` are separate routes; `/health`, `/session`, `/camera-types`, `/bridge/pause|resume`, `/sensors-bridge`, `/integrations/*` and `/system/disks` were added; `/system/update` takes an `action`; `reset-pairing` and `test-motion` are per camera.

### The system helper

`camerabridged` runs as an unprivileged user and never starts anything privileged. The image offers a privilege-separated, asynchronous protocol (the contract is `linux/os/README.md`): the daemon writes one small JSON file per request into `CAMERABRIDGE_OS_REQUEST_DIR` (`/run/camera-bridge/requests`), named `<name>.json` with `<name>` one of `update-check`, `update-apply`, `auto-update`, `ssh-enable`, `ssh-disable`, `reboot`, `poweroff`, `factory-reset`, `install-list`, `install-to-disk`. A systemd path unit wakes a root helper (`cb-system process-requests`) that checks the name and the JSON again, deletes the file and runs the job. The helper publishes how it goes as JSON files in `CAMERABRIDGE_OS_STATUS_DIR` (`/run/camera-bridge/status`): `<name>.json` (`state` queued, running, ok or failed; `message`; `updatedAt`), `update.json`, `install-candidates.json`, `install-to-disk.json` (`state`, `step`, `device`), `system.json` (`version`, `sshEnabled`, `autoUpdate`) and `health.json`.

`RequestFileSystemControl` (BridgeDaemon) is the daemon's side:

| Web action | Request(s) | What the call waits for |
|---|---|---|
| `GET /system` | none: reads `system.json`, `update.json`, `install-to-disk.json` | nothing |
| update check | `update-check` `{}` | `update.json` reaching `available`, `current` or `failed` after the request (or `status/update-check.json` ok or failed), at most 60 s, then it gives up; the answer is `update.json` as the page's `UpdateStatus` |
| update apply | `update-apply` `{"reboot": false}` | only that the helper took the request; answers `downloading`, the page follows `GET /system` |
| reboot, power off | `reboot`, `poweroff` `{}` | only pickup |
| factory reset | `factory-reset` `{"confirm":"RESET"}` | only pickup |
| SSH on / off | `ssh-enable` `{"authorizedKeys": "<keys, one per line>"}` / `ssh-disable` `{}` | the job's `ok` or `failed` (30 s), then a moment for `system.json` |
| automatic updates | `auto-update` `{"enabled": bool}` | the same |
| disks | `install-list` `{}` | `install-candidates.json` newer than the request (30 s) |
| install | `install-list` first (fresh), then `install-to-disk` `{"device":"/dev/<name>","phrase":"ERASE ALL DATA ON <name>","copyData":bool,"poweroff":true,"dryRun":false}` | only pickup; `install-to-disk.json` has the steps |

Rules it keeps: the file name always comes from a fixed list (`Request`), never from input; the body is built from validated values only (SSH keys are plain public keys, the disk is a kernel name from the installer's own list that is usable, the phrase is exactly `ERASE ALL DATA ON <name>`); a request is written under a temporary name in the same folder and renamed onto `<name>.json`, so the helper never sees half a request; a request nobody takes within 15 s is withdrawn and reported; every wait is a bounded loop; a status file only counts when its `updatedAt` is not before the second the request was written. When the two folders do not exist (a Mac, a plain Linux box) the mode is `development` and every privileged action is refused with a sentence. There is no `sudo`, no setuid program and no shell in the path.

### The daemon

```
camerabridged [--data-dir /var/lib/camera-bridge] [--port 80] [--static-dir|--web-root /usr/share/camera-bridge/web] [--loopback-only]
              [--allowed-host NAME] [--setup-token-file PATH] [--run-dir /run/camera-bridge] [--os-request-dir DIR] [--os-status-dir DIR]
              [--log-level info] [--hap-base-port N] [--sensors-port N] [--dev] [--preview [scenario]] [--fake-discovery] [--no-demo-camera]
```

Every flag has a variable; a flag wins. The image's unit sets `CAMERABRIDGE_DATA_DIR`, `CAMERABRIDGE_WEB_ROOT`, `CAMERABRIDGE_HTTP_PORT`, `CAMERABRIDGE_RUN_DIR`, `CAMERABRIDGE_OS_REQUEST_DIR` and `CAMERABRIDGE_OS_STATUS_DIR` (the request and status folders default to `requests` and `status` in the run folder); the older `CAMERA_BRIDGE_*` spellings (`_DATA_DIR`, `_PORT`, `_STATIC_DIR`, `_LOOPBACK_ONLY`, `_ALLOWED_HOSTS`, `_SETUP_TOKEN`, `_LOG_LEVEL`) still work, and the `CAMERABRIDGE_*` name wins when both are set. It logs to standard output (journald priorities when under systemd; the engine's diagnostics log in `<data>/Diagnostics` as always), sends `READY=1` once the web interface listens, `WATCHDOG=1` every WatchdogSec/3 (10 s for the image's `WatchdogSec=30`) while the engine runs and the interface listens (use `Type=notify`, `WatchdogSec=`), and shuts down on SIGTERM or SIGINT: web interface first, then the engine, within 10 seconds. `GET /api/v1/status` needs no sign-in (the image's boot health check uses it). `--setup-token-file` makes first-run setup ask for a code the image prints on the console, so nobody else on the network can claim a new bridge.

## Security

- The web interface is for the local network only; the box never opens a port to the internet. Only IP addresses, `localhost`, `*.local`, `*.home.arpa`, names without a dot and `--allowed-host` names are served (DNS rebinding).
- First boot: no admin yet. The UI asks you to set a password on first visit (and the setup code, when the image has one). Until then the API offers only `/status`, `/session`, `/health` and `/auth/setup`.
- Passwords: PBKDF2-HMAC-SHA256, 600,000 rounds, 16-byte salt per password (swift-crypto), 8 to 256 bytes. Wrong guesses: 5 free per address, then a 15 s lockout that doubles up to 15 min; 60 failures from anywhere slow everyone for a minute. Comparisons are constant time.
- Sessions are random 256-bit tokens in `HttpOnly; SameSite=Strict` cookies, kept server-side only as SHA-256 hashes (`<data>/web/auth.json`, 0600), 7 days idle, 30 days at most, signed out by a password change. Changing requests need a matching `Origin`, the session's HMAC-derived `X-CSRF-Token` and a JSON content type.
- Strict headers: a Content-Security-Policy that allows only the bridge's own files (no inline script or style), `nosniff`, no referrer, no framing, same-origin resource and opener policies.
- Camera passwords, cloud sources and HomeKit keys are in the encrypted secret store; none appears in an answer, the log, the diagnostics or the web interface's files.
- `nftables` default-deny inbound except 80, 443 (UI), the HAP ports (21100–21199), mDNS and SSH only if enabled.
- No telemetry. The only outbound calls are to the cameras, Apple's push relay (through the HomeKit hub), GitHub for update checks, and go2rtc's cloud sources if you add Ring or Nest.

## Operating system

- Debian 13 (trixie), minimal; built with `mkosi` into a GPT disk image.
- UEFI + systemd-boot. Partitions: ESP (512 MB), root A and root B (read-only, 2.5 GB each), data (the rest, ext4, grows on first boot).
- A/B updates with `systemd-sysupdate` and `systemd-bless-boot`: a new root is written to the idle slot, booted once, and kept only if `camerabridged` reports healthy.
- Runs straight from the USB stick (the data partition lives on the stick; use a good stick or an SSD in an enclosure) or installs to the machine's internal drive.
- Intel N100 / N150 mini PCs are the reference hardware (hardware H.264 encode through VA-API). Raspberry Pi 5 (arm64) follows, passthrough only.
- Reproducible: the image build is a GitHub Actions workflow (`.github/workflows/os-image.yml`); every release carries SHA-256 and a signature.

## Repository layout (Linux parts)

```
Packages/CameraBridgeKit/Sources/PlatformLinux/   Linux implementations of the platform services
Packages/CameraBridgeKit/Sources/BridgeWeb/       portable HTTP server + JSON API over NetworkTransport (testable on a Mac)
Packages/CameraBridgeKit/Sources/BridgeDaemon/    the daemon's logic: flags, systemd, logging, the system helper (testable)
Packages/CameraBridgeKit/Sources/camerabridged/   the daemon (executable; only a main)
linux/web/                                        the web UI (static files; no build step needed at runtime)
linux/os/                                         mkosi config, systemd units, sysupdate, installer, first-boot
docs/linux/                                       this file, the user guide, the build guide
```

## Build and test

- macOS: `swift test` in `Packages/CameraBridgeKit` runs everything that is portable, including `BridgeWeb`.
- The UI on a Mac: `swift run camerabridged --dev --data-dir /tmp/cb-dev --fake-discovery` (in `Packages/CameraBridgeKit`), then open `http://127.0.0.1:8080`. It runs the real engine with demo cameras, nothing advertised, the HomeKit ports from 38100; `--preview` serves the engine's sample data instead.
- Linux: `Tools/linux-test.sh` runs the same tests in a Swift container (Docker or OrbStack). CI does it on every push.
- OS image: `linux/os/build.sh` (needs Linux and root) or the GitHub Actions workflow.
