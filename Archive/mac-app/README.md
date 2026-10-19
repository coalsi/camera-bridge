# Camera Bridge for Mac (archived)

This folder holds the source of the Camera Bridge macOS app: the SwiftUI app (menu bar item, manager window, live viewer,
NVR), its Xcode project, and the tools and notes it was released with. It sits on the engine in `Packages/CameraBridgeKit`,
which is not archived.

- **Last version:** 1.1, build 10 (`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, which `App/Info.plist`
  reads). The last commit before the archive is "Mac build 10: Move to Camera Bridge OS".
- **Archived:** 2026-10-18.
- **Why:** the focus is Camera Bridge OS. A later Mac version is planned to run the same server (`camerabridged`) and the
  same web interface as Camera Bridge OS, so this app is kept for reference and is not being developed. Copies that are
  already installed keep working; they get no new versions for now.
- **Not built by CI.** Only `xcodegen generate` was run after the move. The app has not been built from this folder.

## What moved here

The layout is the same as it was in the repository root, so paths inside this folder still work. Paths that start with
`Packages/` are the repository's, two levels up.

| Was | Is now |
|---|---|
| `App/` | `Archive/mac-app/App/` |
| `project.yml` | `Archive/mac-app/project.yml` (the engine package is `../../Packages/CameraBridgeKit`; the go2rtc helper is looked for in `../../build/helpers`) |
| `CameraBridge.xcodeproj/` | `Archive/mac-app/CameraBridge.xcodeproj/` (made again with `xcodegen generate`, XcodeGen 2.43) |
| `Tools/release.sh`, `Tools/sparkle-generate-keys.sh`, `Tools/lib/sparkle.sh`, `Tools/update_appcast.py` | `Archive/mac-app/Tools/` (same names): the Developer ID, notarization and Sparkle release tools |
| `Tools/embed-go2rtc.sh` | `Archive/mac-app/Tools/embed-go2rtc.sh`: the Xcode build phase that puts the go2rtc helper into the app |
| `Tools/nvr-soak.sh`, `Tools/nvr_soak_report.py` | `Archive/mac-app/Tools/`: the Mac app's NVR soak and measurement runs |
| `docs/distribution.md` | `Archive/mac-app/docs/distribution.md`: signing, entitlements, notarization, Sparkle |

What stayed where it was: `Packages/` (including `PlatformApple`, which the macOS package tests use and a Mac version will
use again), `Interop/`, `linux/`, `docs/brand/`, `Tools/fetch-go2rtc.sh` (the engine's real-binary tests use it), and
`Tools/render_brand_assets.sh` with `Tools/compose_brand_assets.py`, which now read the logos from and write the app icon
into `Archive/mac-app/App/Resources`.

To make the Xcode project again, from this folder: `xcodegen generate`.

## The CI job that was removed

`.github/workflows/ci.yml` had a third job, `app`, named **App build (unsigned)**. On a macOS runner it chose the newest
Xcode, skipped the rest unless that was Xcode 27 or later, installed XcodeGen with Homebrew, ran `xcodegen generate`, then
ran `xcodebuild` build and test on the `CameraBridge` scheme (Debug, `CODE_SIGNING_ALLOWED=NO`). The package jobs (macOS and
Linux) were not changed.

Take it from commit `a51878b` (the commit on `main` before the archive): `git show a51878b:.github/workflows/ci.yml`.

## How to restore the app

1. `git mv` everything in the table back to where it was: `Archive/mac-app/App` to `App`, `project.yml` and
   `CameraBridge.xcodeproj` to the root, the `Tools/` files to `Tools/` (and `Tools/lib/sparkle.sh` to `Tools/lib/`), and
   `docs/distribution.md` to `docs/`.
2. Undo the path changes made for this folder: `../../Packages/CameraBridgeKit` back to `Packages/CameraBridgeKit` and
   `$(SRCROOT)/../../build/helpers/go2rtc` back to `$(SRCROOT)/build/helpers/go2rtc` in `project.yml`; the same go2rtc path
   in `Tools/embed-go2rtc.sh`; `APP_ROOT` and `REPO_ROOT` in `Tools/nvr-soak.sh`. Then run `xcodegen generate`.
3. Point `Tools/render_brand_assets.sh` and `Tools/compose_brand_assets.py` back at `App/Resources`, and the two scans of
   `App/Sources` (and the expected file key) in `Packages/CameraBridgeKit/Tests/PortabilityTests/PortabilityTests.swift` back at `App/Sources`.
4. Put the `app` job back into `.github/workflows/ci.yml` from `a51878b`.

The archive commit also fixed links and build steps in `README.md`, `CONTRIBUTING.md`, the pull request template,
`THIRD_PARTY_LICENSES.md` and a few docs. If nothing else has touched those files since, `git revert` of that commit does
all of the above in one step. Find it with `git log --follow -- Archive/mac-app/project.yml`.
