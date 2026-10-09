# Camera Bridge

Camera Bridge brings the network cameras you already own into the Apple Home app, with HomeKit Secure Video recording,
live view, motion and doorbell notifications. It is a macOS app that speaks to cameras over standard protocols (RTSP and
ONVIF) and shows up in Home as ordinary camera accessories. No NVR, no cloud account and no extra recording box: the
Home hub records, and Camera Bridge only has to stay running on a Mac on the same network.

Camera Bridge is **free for personal and noncommercial use**, and the source is available here. Commercial use needs a
license: see [License](#license).

Website: <https://www.camera-bridge.app> · Documentation: <https://docs.camera-bridge.app>

## What it does

- Publishes every camera you add to Apple Home as its own accessory, with **HomeKit Secure Video** recording, live view,
  snapshots, and two-way audio on cameras that support it. Doorbells are supported.
- Motion, person, vehicle, animal and package events become Home notifications and recording triggers. Events come from
  the camera itself (ONVIF events and, where a camera offers one, its native event interface) or from Camera Bridge's
  built-in motion detection.
- Extra sensors (day/night, tamper, offline and others) appear in a separate bridge, only for signals a camera provides.
- Finds ONVIF cameras on your network, checks how ready a camera is for HomeKit Secure Video and can fix common
  encoder settings for you.
- Watch your cameras in the app too: an overview grid and a single-camera viewer, no Home app needed.
- Runs from the menu bar. Settings for launch at login, keeping the Mac awake, a local webhook for other motion
  sources, backup and restore of the configuration, and an exportable diagnostics log.
- Updates itself (Sparkle) from signed, notarized releases. Camera passwords stay in your Mac's keychain, and nothing
  about you or your cameras is sent anywhere unless you opt in to anonymous setup reports.

## Supported cameras

Camera Bridge supports cameras by the standards they speak, not by brand:

| Standard | What is used |
|---|---|
| **RTSP** | Any camera with an RTSP stream: H.264 or H.265 video, AAC or G.711 audio, over TCP, with Basic or Digest authentication. |
| **ONVIF** (Profile S and T) | Discovery on the local network, stream addresses, device settings, event subscriptions (motion and smart detections), two-way audio. |
| **Manufacturer event interfaces** | Several camera families have their own local HTTP interface for events and settings, which Camera Bridge uses when it finds one. |
| **Webhook** | Anything that can make an HTTP request (Frigate, Home Assistant, a script) can trigger motion on a camera. |

The list of cameras people have set up successfully is on the website: <https://www.camera-bridge.app/cameras>.
If yours is missing or misbehaves, open a [camera support request](https://github.com/coalsi/camera-bridge/issues/new?template=camera_support_request.yml).

## Requirements

- A Mac running **macOS 15 (Sequoia)** or later, awake and on the same network as the cameras. Keep Mac Awake is a setting.
- An Apple **home hub** for HomeKit Secure Video: an Apple TV 4K (2nd generation or later), a HomePod (2nd
  generation), or a HomePod mini, updated to the latest software. The hub records and analyzes the video.
- An **iCloud+** plan for recording (live view works without one). Apple decides how many cameras each plan covers.
- Cameras that offer RTSP or ONVIF, reachable from the Mac.
- Camera Bridge accessories are not certified by Apple: the Home app asks you to tap *Add Anyway* when you add one.

## Install

Download the latest `CameraBridge-<version>.dmg` from <https://www.camera-bridge.app> or from
[GitHub Releases](https://github.com/coalsi/camera-bridge/releases), open it and drag Camera Bridge to Applications. The app is signed with a Developer
ID and notarized by Apple. It updates itself; *Camera Bridge ▸ Check for Updates…* looks right away.

Then follow the welcome guide: allow Local Network access, add a camera, scan its code in the Home app.

## Camera Bridge OS (a USB stick or mini PC, no Mac needed)

The same engine also runs on Linux. **Camera Bridge OS** is a small Debian-based system you flash to a USB stick (or
install to the SSD of a mini PC such as an Intel N100/N150 box): plug in your cameras, open `http://camera-bridge.local`
in a browser, add them, and pair them in the Home app. It is in development; the design is in
[docs/linux/ARCHITECTURE.md](docs/linux/ARCHITECTURE.md). Releases of the Mac app are tagged `v*` and releases of the
Linux system `os-v*`, from this one repository and one engine.

## Build from source

Requirements: Xcode 27 (the app runs on macOS 15 and later, but builds with the macOS 27 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.43 (`brew install xcodegen`).

```sh
# The engine (portable Swift package) and its tests
cd Packages/CameraBridgeKit
swift test

# The app
cd ../..
xcodegen generate
xcodebuild -project CameraBridge.xcodeproj -scheme CameraBridge -configuration Debug build
xcodebuild -project CameraBridge.xcodeproj -scheme CameraBridge -configuration Debug test
```

Open `CameraBridge.xcodeproj` in Xcode to run it. A Debug build is signed for development with your own team (set
`DEVELOPMENT_TEAM` in `project.yml`, or in Xcode's Signing & Capabilities), has no updater, and accepts launch arguments
such as `-previewEngine YES` for sample data (see [App/README.md](App/README.md)). Building without a Developer
account works with `CODE_SIGNING_ALLOWED=NO` (the app then cannot be run, only built and tested).

Layout:

| Path | What |
|---|---|
| `Packages/CameraBridgeKit` | The engine: HomeKit Accessory Protocol server, HomeKit Secure Video, RTSP/RTP, camera drivers, media pipeline. Portable Swift; Apple frameworks only in `PlatformApple`. |
| `App` | The macOS app (SwiftUI). |
| `Tools` | Release script, key setup, asset scripts, `cbctl`. |
| `Interop` | Node-based test oracles (dev only, never shipped). |
| `docs` | Integration guides, distribution, interop notes, third-party notices and the engine contract changes. |

Releases are built with `Tools/release.sh` (see [docs/distribution.md](docs/distribution.md)).

## License

Camera Bridge is **free for personal and noncommercial use**. It is licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE): use it at home, for hobby projects, study, research, and inside
charities, schools, public bodies and similar organizations. **Commercial use requires a license**: installers,
integrators, businesses, products and services built on it, and resale. See [COMMERCIAL.md](COMMERCIAL.md) or write to
<legal@camera-bridge.app>.

This is a *source-available* license, not an OSI "open source" license. Third-party components keep their own licenses:
see [NOTICE](NOTICE) and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## Contributing

Bug reports, camera reports and pull requests are welcome. Contributions require signing the
[Contributor License Agreement](CLA.md) once; see [CONTRIBUTING.md](CONTRIBUTING.md). Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md). Security issues: see [SECURITY.md](SECURITY.md).

## Trademarks

Apple, the Apple logo, Apple Home, HomeKit, HomePod, Apple TV, iCloud and macOS are trademarks of Apple Inc., registered
in the U.S. and other countries. "Works with Apple Home" and similar marks belong to Apple. Camera Bridge is an independent
project and is not affiliated with, endorsed by or sponsored by Apple Inc. Camera Bridge accessories are not certified
under Apple's MFi Program. All other names are the property of their owners and are used only to describe compatibility.
