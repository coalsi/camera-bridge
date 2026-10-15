# Camera Bridge

Camera Bridge brings the network cameras you already own into the Apple Home app, with HomeKit Secure Video recording,
live view, motion and doorbell notifications. It speaks to cameras over standard protocols (RTSP and ONVIF) and shows up
in Home as ordinary camera accessories.

**Camera Bridge OS** is the all-in-one way to run it, and the one we recommend: a small Linux system for an Intel mini PC
that brings your cameras into Apple Home, shows every camera live on a web page, and records them around the clock. You
set it all up from a browser at `http://camera-bridge.local`; it needs no keyboard, screen or Mac. If you would rather use
a Mac you already keep running, [Camera Bridge for Mac](#camera-bridge-for-mac) does the same from the menu bar.

Camera Bridge is **free for personal and noncommercial use**, and the source is available here. Commercial use needs a
license: see [License](#license).

Website: <https://www.camera-bridge.app> · Documentation: <https://docs.camera-bridge.app>

## Camera Bridge OS

Releases are tagged `os-v*` on [GitHub Releases](https://github.com/coalsi/camera-bridge/releases). Versions before 1.0 are
**betas** (published as pre-releases) while the interface is being refined: they run every day on the reference box below,
and a box on a beta updates itself to the next one. 1.0 will be the first full release.

### What it does

- Publishes every camera to Apple Home as its own accessory, with **HomeKit Secure Video** recording, live view,
  snapshots, two-way audio where the camera has it, and doorbells that ring like HomeKit doorbells.
- **Monitor:** a wall of every camera with real live video and sound (the cameras' own video, not re-encoded, over one
  connection), an activity timeline and notices. Click a camera to fill the wall with it.
- **Records around the clock** (a Record switch per camera, with limits on age and size) to the box's SSD or a drive you
  attach. Scrub every camera on one timeline, hear the recorded sound, and save clips as MP4 with sound.
- **One label everywhere:** the camera's name and the date and time look the same on the Monitor, in Apple Home and burned
  into saved clips, and one switch turns off each camera's own on-screen clock and text (Hikvision, Reolink, ONVIF). The
  bridge keeps the cameras' clocks on its time zone, daylight saving included.
- Motion, person, vehicle, animal and package events become Home notifications and recording triggers, from the camera
  itself (ONVIF events and native event interfaces) or from built-in motion detection.
- Finds ONVIF cameras on your network, joins Wi-Fi by itself (or opens a setup hotspot for your phone), installs itself
  to the PC's internal disk, and updates itself from signed releases with automatic rollback if a new version does not
  start properly.
- Imports your cameras from Camera Bridge for Mac.

### Minimum requirements

Camera Bridge OS is tuned for its reference box, a **Beelink Mini S (Intel N150, 12 GB, 512 GB SSD)**, which records five
cameras around the clock at about a quarter of its processor. That box is the minimum.

| | Minimum | More headroom |
|---|---|---|
| Processor | Intel N150 or N100 (4 cores) with its Intel graphics (VA-API) | Intel N305 or Core i3 |
| Memory | 12 GB | 16 GB |
| Storage | 512 GB internal SSD | 1 TB SSD, or a recording drive you attach |
| Network | Gigabit Ethernet or Wi-Fi | Gigabit Ethernet |
| Cameras | up to 12 recording, all live on the Monitor | 16 or more |

You also need:

- A USB stick (16 GB or more) to install from, and UEFI boot with Secure Boot off.
- Cameras that offer an RTSP stream or ONVIF Profile S or T, on the same network.
- For HomeKit Secure Video: an Apple **home hub** (Apple TV 4K or HomePod, on current software) and an **iCloud+** plan.
  Live view in Home works without iCloud+.

Details, storage advice and BIOS settings: [docs/linux/HARDWARE.md](docs/linux/HARDWARE.md).

### Install

1. Download `camera-bridge-os-<version>-amd64.img.xz` from the newest `os-v*` release and write it to a USB stick with
   balenaEtcher.
2. Start the mini PC from the stick. An Ethernet cable works with no setup; without one, join the box's own
   `CameraBridge-…` Wi-Fi with a phone and pick your network.
3. Open `http://camera-bridge.local`, set a password, and install the system to the PC's internal disk from the System
   page. Remove the stick and restart.
4. Add your cameras (the page finds ONVIF cameras on its own) and scan each one's code in the Home app.

The full guide is [docs/linux/USER-GUIDE.md](docs/linux/USER-GUIDE.md); the design is
[docs/linux/ARCHITECTURE.md](docs/linux/ARCHITECTURE.md).

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
Camera Bridge accessories are not certified by Apple: the Home app asks you to tap *Add Anyway* when you add one.

## Camera Bridge for Mac

An option if you already have a Mac that stays on: the same engine as a menu bar app. It publishes your cameras to Apple
Home with HomeKit Secure Video, shows them in an overview grid and a viewer, and can record them to a folder you choose
with a scrubbable timeline. Camera passwords stay in the Mac's keychain. When you are ready to move to a box, *Move to
Camera Bridge OS* exports your cameras for the box and stops the Mac's bridge, so the two never run the same cameras.

- Requires **macOS 15 (Sequoia)** or later on a Mac that stays awake on the cameras' network (Keep Mac Awake is a
  setting), plus the same home hub and iCloud+ plan for HomeKit Secure Video.
- Download the latest `CameraBridge-<version>.dmg` from <https://www.camera-bridge.app> or from
  [GitHub Releases](https://github.com/coalsi/camera-bridge/releases) (tags `v*`), open it and drag Camera Bridge to
  Applications. It is signed with a Developer ID, notarized by Apple, and updates itself (Sparkle).

## Build from source

Camera Bridge OS: the image is built with mkosi from `linux/os` (`linux/os/build.sh`, normally by GitHub Actions on an
`os-v*` tag), and the daemon is the `camerabridged` product of the engine package, built with Swift 6.4 on Linux. See
[docs/linux/BUILDING.md](docs/linux/BUILDING.md).

The Mac app requires Xcode 27 (the app runs on macOS 15 and later, but builds with the macOS 27 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.43 (`brew install xcodegen`).

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
| `linux` | Camera Bridge OS: the image (`linux/os`), the web interface (`linux/web`) and their tests and tools. |
| `App` | The macOS app (SwiftUI). |
| `Tools` | Release script, key setup, asset scripts, `cbctl`. |
| `Interop` | Node-based test oracles (dev only, never shipped). |
| `docs` | Integration guides, distribution, interop notes, third-party notices and the engine contract changes. |

Releases are built with `Tools/release.sh` (see [docs/distribution.md](docs/distribution.md)).

## Support the project

Camera Bridge is made by one person and is free for everyone at home. If it saves you an NVR or a cloud camera plan, you
can [buy me a coffee on Ko-fi](https://ko-fi.com/coreysilvia). You can also help by starring the repository, reporting a
camera that works (or doesn't) with a [camera support request](https://github.com/coalsi/camera-bridge/issues/new?template=camera_support_request.yml),
and sending pull requests.

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
