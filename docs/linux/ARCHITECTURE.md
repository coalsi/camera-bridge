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
| `SecretStore` | Keychain | encrypted file store (AES-GCM, key file `0600`, optional TPM seal) |
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

State lives in `/var/lib/camera-bridge` (a separate data partition, so updates never touch it): `config.json`, `hap/`, `secrets/`, `Diagnostics/`. This is the same layout the Mac app uses in `~/Library/Application Support/CameraBridge`.

## Web API (served by `camerabridged`)

JSON over HTTP on port 80. Browsers on the LAN reach it at `http://camera-bridge.local`. The first admin password is set in the browser the first time (see Security). Everything below needs a signed-in session unless noted.

```
GET    /api/v1/status                 bridge state, version, uptime, update available       (no auth: minimal)
GET    /api/v1/cameras                list with state, motion, pairing, stream info
POST   /api/v1/cameras                add a camera {type, host, port, username, password, name, ...}
GET    /api/v1/cameras/{id}           one camera
PATCH  /api/v1/cameras/{id}           rename, quality, motion source, overlay, ...
DELETE /api/v1/cameras/{id}
GET    /api/v1/cameras/{id}/snapshot  JPEG
GET    /api/v1/cameras/{id}/live      multipart MJPEG (a quick look; Apple Home does the real viewing)
GET    /api/v1/cameras/{id}/pairing   {setupCode, setupURI, qrSVG, paired}
POST   /api/v1/cameras/{id}/reset-pairing
POST   /api/v1/discover               ONVIF WS-Discovery + known-vendor probes -> [DiscoveredCamera]
POST   /api/v1/probe                  check credentials/type before adding -> {ok, vendor, streams, problems}
GET    /api/v1/settings               bridge settings
PATCH  /api/v1/settings
GET    /api/v1/logs?since=            recent engine log lines (SSE with Accept: text/event-stream)
GET    /api/v1/diagnostics            the same text bundle the Mac app exports
GET    /api/v1/events                 server-sent events: camera state, motion, doorbell, notices
POST   /api/v1/system/update          check / apply an OS update (A/B), POST /api/v1/system/reboot
POST   /api/v1/system/install         copy this USB system to the internal disk (installer mode)
POST   /api/v1/auth/setup | login | logout | password
```

The types match the Mac app's models (`CameraConfiguration`, `CameraStatus`, `DiscoveredCamera`, `NetworkNotice`) so the two UIs stay in step.

## Security

- The web UI is for the local network only; the box never opens a port to the internet.
- First boot: no admin yet. The UI asks you to set a password on first visit. Until then it only offers that page.
- Passwords are hashed with PBKDF2-SHA256 (swift-crypto) or scrypt; sessions are random 256-bit tokens in `HttpOnly; SameSite=Strict` cookies.
- Camera passwords and HomeKit keys are in the encrypted secret store.
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
Packages/CameraBridgeKit/Sources/camerabridged/   the daemon (executable)
linux/web/                                        the web UI (static files; no build step needed at runtime)
linux/os/                                         mkosi config, systemd units, sysupdate, installer, first-boot
docs/linux/                                       this file, the user guide, the build guide
```

## Build and test

- macOS: `swift test` in `Packages/CameraBridgeKit` runs everything that is portable, including `BridgeWeb`.
- Linux: `Tools/linux-test.sh` runs the same tests in a Swift container (Docker or OrbStack). CI does it on every push.
- OS image: `linux/os/build.sh` (needs Linux and root) or the GitHub Actions workflow.
