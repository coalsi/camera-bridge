# Distribution

Camera Bridge is free and source-available (PolyForm Noncommercial 1.0.0). It is **not** sold through the Mac App Store.
Releases are a notarized DMG from GitHub Releases, signed with a Developer ID, and the app updates itself with Sparkle 2.
The App Store route (sandbox, in-app purchases, Camera Bridge Pro) was dropped on 2026-10-08; the old checklists are kept in
[archive/app-store](archive/app-store).

## Signing and entitlements

| Setting | Value | Why |
|---|---|---|
| Signing identity | Developer ID Application, team `XL4RAH5J96` (Release, `Tools/release.sh`); Apple Development for Debug | Gatekeeper accepts a notarized Developer ID app from a download |
| Hardened runtime | on (`ENABLE_HARDENED_RUNTIME`) | required for notarization; no exceptions are requested |
| App Sandbox | **off** (`ENABLE_APP_SANDBOX = NO`) | so the app can launch a bundled helper process (go2rtc) later, and read its own old sandbox container once (see Migration) |
| Secure timestamp | on in `release.sh` (`--timestamp`) | required for notarization |
| `get-task-allow` | absent in Release (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`) | notarization refuses debuggable builds |

`App/CameraBridge.entitlements` holds exactly two entitlements:

| Entitlement | Why |
|---|---|
| `com.apple.security.network.client` | connects to cameras (RTSP, HTTP) and the update feed |
| `com.apple.security.network.server` | listens for HomeKit controllers (HAP), the local webhook and the HomeKit data stream |

Outside the sandbox neither entitlement gates anything: they document what the app does and keep the file valid should it
ever be sandboxed again. Nothing else is requested: no JIT or unsigned-memory exception, no library-validation
exception (Sparkle is re-signed with the app's identity), no Apple Events, no camera or microphone capture, no file
access entitlements (outside the sandbox, a save panel needs none).

`Info.plist` keeps `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_hap._tcp`): macOS asks for Local Network
permission on first use. `NSAppTransportSecurity.NSAllowsLocalNetworking` allows plain HTTP to cameras on the LAN.

### Migration from the sandboxed build

Earlier local builds were sandboxed, with data in `~/Library/Containers/com.coreysilvia.CameraBridge`. On the first launch
of the unsandboxed build, `App/Sources/Model/LegacySandboxMigration.swift` copies that container's configuration
(`Application Support/CameraBridge`) to `~/Library/Application Support/CameraBridge` and takes over its preferences, once.
It only copies; the container is left untouched. Camera passwords and pairing secrets live in the login keychain, which the
sandbox never changed, so cameras and Home pairings carry over. macOS may ask once whether the differently signed app
may use the existing keychain items: choose Always Allow.

## One-time setup (owner)

1. **Developer ID Application certificate.** Xcode > Settings > Accounts > your team > Manage Certificates > + > *Developer
   ID Application* (or developer.apple.com > Certificates). Check with:
   `security find-identity -v -p codesigning | grep "Developer ID Application"`
2. **Notarization profile**, once:
   ```sh
   xcrun notarytool store-credentials camera-bridge-notary --apple-id YOU@EXAMPLE.COM --team-id XL4RAH5J96
   ```
   It asks for an app-specific password (appleid.apple.com > Sign-In and Security > App-Specific Passwords) and keeps the
   profile in your Keychain. Nothing is stored in the repository.
3. **Sparkle update key**, once:
   ```sh
   Tools/sparkle-generate-keys.sh
   ```
   It creates the EdDSA key in your login Keychain (the private key is never printed or written to a file), puts the
   public key into `project.yml` (`SPARKLE_PUBLIC_ED_KEY`, which becomes `SUPublicEDKey` in Info.plist) and regenerates the
   Xcode project. Commit `project.yml`, `CameraBridge.xcodeproj` and `App/Info.plist`. **Back up the private key** (the script
   says how); without it installed copies can never be updated.

## Releasing

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` (Sparkle compares the build number, which must
   always increase). Run `xcodegen generate`, `swift test`, the app tests; commit and tag `vX.Y`.
2. `Tools/release.sh`. It archives with Developer ID, exports, checks the signature, hardened runtime and entitlements of
   every executable, notarizes and staples the app, builds and signs the DMG, notarizes and staples it, signs it for
   Sparkle, writes `build/release/appcast.xml` (appended to the live one) and prints what to upload.
3. Create the GitHub Release `vX.Y` with the DMG (`gh release create ...`, printed by the script).
4. Publish `appcast.xml` at <https://www.camera-bridge.app/appcast.xml> **after** the release is public.

`Tools/release.sh --local-check` runs the same pipeline with a development identity and no secrets (no notarization, no
Keychain key): use it to test the script or the packaging. Its output must never be shipped.

The appcast item's download URL is `https://github.com/coalsi/camera-bridge/releases/download/vX.Y/CameraBridge-X.Y.dmg`.
Override `GITHUB_REPO`, `APPCAST_URL`, `TEAM_ID`, `NOTARY_PROFILE` in the environment if any of them change.

## Auto-updates

Sparkle 2 (MIT) is linked into the app (`App/Sources/Updates/AppUpdater.swift`; pinned in `project.yml`). The app asks
`SUFeedURL` (the appcast) about once a day unless the person turns that off (Settings > General > Updates), and offers
*Check for Updates…* in the app menu, Settings > General and About. A download is verified against `SUPublicEDKey` before it
is installed. Debug builds and builds without a public key have no updater (the menu item is disabled).

Because the app is not sandboxed, Sparkle needs no XPC services or extra entitlements.
