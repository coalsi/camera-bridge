# App (CameraBridge.app)

SwiftUI app (Dock and/or menu bar, Settings › General; at least one stays on: `Model/AppPresence.swift`) over the live `BridgeEngine(environment: .live())` (plan tasks W1-8 UI, W3-3 wiring). May import
SwiftUI, AppKit, ServiceManagement, CoreImage and Network (gateway lookup); everything else comes from the package.

## Entry points

- `CameraBridgeApp.swift` — `MenuBarExtra` (`.menu`), `Window(id: "manager")` (suppressed at launch unless onboarding
  or `-openManager`), app commands (⌘, Settings, ⌘N Add Camera), `AppDelegate` (reopen → manager,
  `NSWorkspace.didWakeNotification` → `engine.systemDidWake()`, becoming active → login item status and a denied
  Local Network check again, quit → `engine.stop()` for at most 5 s: `Model/TimeLimit`).
- `Model/AppModel.swift` — owns the engine, login item, onboarding flag, navigation, the manager's one sheet
  (`ManagerSheet`: onboarding or Add Camera, never both), alerts, `bridgeIssue`; implements `CameraSetupService`.
  `Model/*` holds all logic (no SwiftUI) and is unit-tested (`AppEngineWiringTests` against a real loopback engine).
- `Model/CameraEditor.swift` — the camera detail draft: applied after 0.6 s of quiet (and when the view goes away),
  one update at a time; engine updates merge field by field so edits in progress survive; a failed update reverts.
- `Menu/StatusMenu.swift` — text status per camera ("● Driveway — Live · Recording": macOS 27 hides menu images),
  the bridge issue's item under the header (`BridgeIssue.menuItemTitle` → `AppModel.show(_:)`), Manage Cameras,
  Settings, Pause/Resume/Start Bridge, Launch at Login (with "Allow Launch at Login in System Settings…" while it waits
  for approval), Keep Mac Awake, Quit.
- `Manager/` — `ManagerWindow` (`NavigationSplitView`: cameras, Sensors Bridge, Settings; `BridgeIssueBanner` on top),
  `CameraDetailView` (+ recent events from `CameraStatus.recentEvents`, `Model/RecentEvents`, and Last Event: relative
  times redrawn every second by a `TimelineView`, `StatusText.lastEvent(_:at:now:)` / `timeAgo`; Change Address… →
  `Model/CameraConnectionEditor`; its log shows every line tagged with the camera: runtime, HAP accessory, HomeKit
  camera controller, HDS, RTSP, and the camera's driver — event channel, camera API and two-way audio), `AddCameraWizard`
  (+ `Model/AddCameraWizardModel`; `Model/HostInput` parses pasted
  addresses), `SensorsBridgeView`, `SettingsView` + `Settings*Tab` (the Settings window: General, HomeKit, Network, Webhook,
  Privacy, Diagnostics, Backup, About, on `SectionCard`s with the `SettingsComponents` rows; `Model/SettingsTab`,
  `SettingsText`, `NetworkSettings`, `ConfigurationBackup` + `BackupModel` hold the testable logic). Settings › Diagnostics has the motion
  shadow test's switch ("Compare built-in motion detection with camera events (test)", off by default, `AppModel.motionShadowTest` →
  `BridgeSettings.motionShadowTest`); while it is on, the Diagnostics page shows a per-camera table (both / camera only / built-in only /
  median delay / sensitivity, last 24 hours or since enabled; `Model/MotionShadowTable`) above the log.
- `Onboarding/OnboardingView.swift` — prerequisites, Local Network check (`checkLocalNetworkAccess`) and fix steps
  (scrolled into view while access is denied; Get Started on the first run, Done afterwards), and
  `LocalNetworkAccessSheet` (Fix… for a denial: just the check, the fix steps, Open Settings and Check Again).
- `Viewer/` + `Model/{LiveFeed,OverviewModel,LiveOverlay,LiveQuality}.swift` — the in-app live viewer (no Home app needed). The engine's
  `BridgeEngine.liveVideo` gives encoded H.264 / H.265 access units (a lease on the camera's stream, like a HomeKit viewer's); `LiveFeed`
  (Model: wanted / suspended / retry / stall watchdog / mute) reads them off the main thread into a `LiveVideoSink`, the
  `LiveVideoRenderer` (`AVSampleBufferDisplayLayer` through a render-synchronizer receiver: hardware decode, each picture shown at once,
  keyframe first, backlog dropped for the next keyframe) with `LiveAudioPlayer` (`AVSampleBufferAudioRenderer`, muted by default), hosted by
  `LiveVideoView`. `OverviewView` / `OverviewTile` is the first sidebar page and the default selection: every camera in a grid of two to four
  columns (`OverviewModel.columns(forWidth:)`), snapshots until Play All (remembered, `overviewPlayAll`) or a tile's own hover button; live
  tiles read the sub stream, at most nine at once, only while on screen (`onScrollVisibilityChange`) and online, and none while the page or the
  window cannot be seen (`WindowActivity`) or the viewer covers the page; double-click or the expand button opens `SingleCameraViewer` (main
  stream, sound toggle, quality menu, Save Snapshot… of the displayed picture as a JPEG in a save panel, Open Camera Settings, Esc, full
  screen), the info area opens the camera's page. The camera page's hero has a play button (`HeroLive`: quality menu, mute, expand, stop; ends
  when the page goes away). `StatusText.viewersDetail` shows "1 viewer in CameraBridge" apart from the Home app's viewers.
- Free: there is no plan, store or limit. Every configured camera is published to Apple Home (`BridgeEngine.homeKitAllowlist` stays nil; the
  engine's allowlist API is a generic switch the app does not use). Camera Bridge is source-available under PolyForm Noncommercial 1.0.0 (LICENSE,
  COMMERCIAL.md). `Model/LegacySandboxMigration` copies the old sandbox container's configuration and preferences once (copy only).
- `Updates/AppUpdater` — Sparkle 2 (the only file that imports it; the logic-test bundle does not link it). Check for Updates… is in the app menu,
  Settings › General › Updates and About; it is disabled in Debug builds and while `SUPublicEDKey` is empty. Release: `Tools/release.sh`.
- `Shared/` — `QRCodeView` (`CIQRCodeGenerator`, nearest-neighbour scaling, white quiet zone), `PairingSection`,
  `LogView` (the camera page's log; Settings › Diagnostics links to the Diagnostics page instead of embedding one), `BridgeIssueBanner`,
  window opening (`openWindow` + `NSApp.activate()`).

## Launch arguments (Debug builds only: a Release build ignores all of them and always runs the live engine)

- `-previewEngine YES` — `BridgeEngine.preview()` sample data; no networking, no system changes (login item
  simulated; its own defaults, `AppModel.previewDefaults`, so Get Started there never completes the live app's
  onboarding). Actions that would change the bridge are skipped with a notice; discovery/probe answer from
  `Model/PreviewFixtures` (RFC 5737 addresses). Every `#Preview` uses `AppModel.preview()` the same way.
- `-openSettings YES` (Debug) — open the Settings window at launch; `-settingsTab network` picks the tab (the `@AppStorage`
  key, one of `SettingsTab`'s raw values).
- `-openManager YES` — open the manager window at launch. `-showOnboarding YES` — show onboarding again (with cameras
  configured, the bridge then starts at Get Started).
- `-demoScenario fleet` (with `-previewEngine YES`) — eight sample cameras, seven online (the Overview grid). Live-viewer review (Debug, or Release
  built with `DEBUG`): `-demoPlayAll YES|NO` Play All, `-demoLiveCap 5` simultaneous live tiles, `-demoExpand 0` the single-camera viewer for that
  camera (`-demoUnmute YES` with sound), `-selectCameraIndex 0 -demoHeroLive YES` the camera page playing, `-demoWindowAction close|miniaturize|hide`
  (after 8 s: live pictures must stop), `-previewSnapshots YES` synthetic snapshots. The preview engine serves synthetic live streams (a looped test
  pattern: `PreviewLiveSources`).
- `-captureScreenshots YES` (Debug) — renders the manager pages and the onboarding sheet (with `-previewEngine YES` also
  the Add Camera sheet and each wizard step; never on the live engine, whose wizard searches the network) to
  `$TMPDIR/CameraBridgeScreenshots/` and logs whether the status
  item is on screen (the app draws its own windows: no screen-recording permission needed).

## Invariants

- Live launch: the engine starts at launch, also on the first run ("Bridge running with 0 cameras"). A bridge without
  cameras opens no connection and advertises nothing (the engine runs the sensors bridge only while a camera exists),
  and Add Camera waits behind the onboarding sheet, so the first LAN access follows onboarding. Onboarding pending
  while cameras are configured (`-showOnboarding YES`, reset app defaults with a surviving `config.json`) holds the
  engine until Get Started (`AppModel.startsEngineAtLaunch`), so the guide never runs alongside live cameras.
- `bridgeIssue`: a failed start (redacted reason, Try Again), a damaged configuration set aside
  (`BridgeEngine.configurationRecoveredFrom`, Show in Finder dismisses it; it survives relaunches until then, and a
  launch that finds it opens the manager), denied Local Network access (Fix… → `ManagerSheet.localNetworkAccess`, not
  the whole welcome guide) or a webhook that isn't listening (`webhookProblem`, Try Again → `retryWebhook()`) shows as
  a banner over the manager's detail and in the menu bar: the status item's warning symbol, its VoiceOver label naming
  the issue, and an item under the menu's header ("Your Cameras Couldn’t Be Loaded — Show…", "Local Network Access
  Denied — Fix…", "The Webhook Isn’t Listening — Show…"; a failed start is the header itself, "CameraBridge — Error —
  …", with Start Bridge). All from `AppModel.bridgeIssue`.
- Local Network check targets: every enabled non-demo camera (each address once), then the current IPv4 router
  (`DefaultGateway`, `NWPath.gateways`, port 80 via the engine), until one answers: an unplugged camera only times out,
  which says nothing about Local Network access. Reading the path sends nothing; only Check Access connects. Neither
  known → `LocalNetworkCheckOutcome.noNetwork` ("couldn't find your network"), nothing is sent.
- Check Access waits up to `BridgeEngine.localNetworkAnswerWait` (20 s) while no answer is known: the first check
  raises the system's alert and connections stay blocked until the person answers, so a prompt still on screen is not
  reported as a denial (the sheet says "If macOS asks…, click Allow" meanwhile). While access is denied the app checks
  again every 10 s and when it becomes active (back from System Settings), one attempt per target until one answers,
  until access is allowed or the app quits: the banner and the menu bar warning clear by themselves, also with no
  camera configured or the first camera offline. The onboarding sheet shows the engine's live answer.
- Sensors Bridge page: the QR code only while the engine is running and the bridge is up; paused, stopped, starting or
  without cameras it says why (the engine keeps the last `sensorsBridge` status after pause/stop). Cameras likewise
  (`Model/PairingBlocker`): the camera page and the wizard's last page offer the code only while the camera's accessory
  is published (engine running, camera on, `hapPort` known); otherwise they say why, with Resume/Start Bridge.
- The manager opens on the first configured camera, else on the "No Cameras Yet — Add Camera…" page (first run).
- Add Camera: the first search waits for the Local Network answer (Check Access is optional in onboarding, and a
  prompt still on screen would drop the search); a denial shows on the Discover page (searched again once allowed)
  and as the bridge issue. A probe that couldn't reach the camera because of Local Network privacy says so. A discovered
  camera's ONVIF port (its device service XAddr) and the one the probe found are saved (`CameraEndpoint.onvifPort`).
  A camera that is already configured is pointed out, not refused (`AddCameraWizardModel.alreadyAdded`: same serial
  number, or the same address and HTTP/RTSP ports for API cameras, or the same main stream for RTSP URL cameras; never
  the demo camera): discovered rows say "Already added as …", and Review warns that adding it again makes a second Home
  accessory with its own camera sessions and offers to open the existing camera (Change Address… is there).
- Use HTTPS (wizard and Change Address…) moves a default port with it (80 ↔ 443; a port the person entered stays), and
  the field is labelled "HTTPS Port" then: the adapters reach the API at `https://host:httpPort`.
- Change Address… (camera page): address, ports, HTTPS and stream URLs (URLs on the old address follow it), checked
  with the stored password (`BridgeEngine.probeCamera(_:password:)`), then `updateCamera` with the same id through the
  form's `CameraEditor` queue: the Home accessory, pairing and history stay. The fields are locked while the camera is
  checked; Cancel, Escape or the sheet closing (`CameraConnectionEditor.cancel()`) stops the check, and nothing is
  saved after it.
- Trigger Motion (camera page) sends a real motion event (with recording on, a clip; notifications): its footer says
  so, and it is off with the reason while the camera's accessory isn't published (`AppModel.testMotionBlocker`).
- Detection sensors (person, vehicle, animal, package) are offered when the camera reports them or its motion source is
  the webhook (the engine publishes them then too). Choosing another motion source turns off the sensors only the old
  one offered (`CameraEditor.chooseMotionSource`, `SensorKind.adjusted`); every sensor the engine may publish has its
  toggle (`SensorKind.shown`: unknown capabilities trust the options, like the engine), and the Sensors Bridge page lists
  the engine's own list (`SensorsBridgeStatus.publishedSensors`, `SensorKind.cameraRows`; an alarm input appears once
  the camera has reported it), never a copy of its rule.
- Webhook: every camera page shows its ID and webhook URLs whatever its motion source (`WebhookSettings.cameraURLs`:
  the doorbell first for doorbells, motion, motion/stop, the detections), and while the webhook isn't listening says so
  next to them with Try Again (`WebhookSettings.cameraNotice`: what is lost for a camera that depends on it); the
  wizard's Review and pairing pages show the doorbell URL of a doorbell that reports no button (`ringsThroughWebhook`:
  every Hikvision doorbell). Settings' example names no camera (`<camera ID>`).
- Stream URLs are `rtsp://` only: the engine's RTSP client has no TLS, so `rtsps://` is refused with a reason in the
  wizard and the Connection sheet (a pasted `rtsps://` address gives the host, not its TLS port), and a camera saved
  with one earlier says so on its page. Plain RTSP cameras have no event channel: their Camera Events row says "None",
  not "Not connected".
- Settings changes go through `BridgeEngine.updateSettings(_ change:)`: the engine applies each change to its settings
  when the change's turn comes, so two changes made while it is busy (starting, adding a camera) both stick.
- Keep Mac Awake is `BridgeSettings.keepMacAwake` (the engine holds the IOPM assertion via `PlatformServices.power`).
  Launch at Login reads `SMAppService.mainApp.status` live (`AppModel.loginItemStatus`; the menu refreshes it when it
  opens, which doesn't activate this agent app); off by default; opens Login Items when approval is needed.
- Nothing on the main thread blocks on the network (no `ProcessInfo.hostName`; example webhook URLs use
  `gethostname()`, the token is masked until "Show"). Error text on screen goes through `Redact.string`, like the log,
  and is a sentence for every engine and adapter error (`ErrorText`): network, stream, camera API and storage errors
  are the engine's wording (`BridgeEngine.readableReason`, also behind its state strings) made a sentence, plus what
  to do; `TransportError.failed`'s platform text (POSIX, URLError codes) and Swift type and case names go to the log
  only (`ErrorText.logDescription`). The status item's symbol and VoiceOver label come from the same state.
- A failed action is an alert on the manager window, which is opened or brought forward and the app activated (a menu
  bar action leaves this agent app inactive, and an open window may be behind other apps); closing the window drops an
  unshown alert. The Connection sheet shows its own save failure with the reason (`applyCameraUpdate(…, showsFailure:
  false)`): an alert would wait behind the sheet.
  Remove Camera included: the engine keeps a camera whose removal it couldn't save (`removeCamera` doesn't throw), so
  the app checks afterwards, says so and goes back to the camera's page.
- Engine state strings shown as they are (`EngineState.failed` in the banner, menu header and VoiceOver label, a
  camera's offline reason, `webhookProblem`) are sentences from the engine (`BridgeEngine.startFailure` /
  `readableReason`), never case names.
- Stream URLs never carry credentials (the wizard moves pasted `user:pass@` into the credential fields). Product copy
  says "Apple Home", never "HomeKit" as a name.

## Tests and verification

```sh
xcodegen generate
xcodebuild -project CameraBridge.xcodeproj -scheme CameraBridge -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test      # builds the app + CameraBridgeTests
open …/Debug/CameraBridge.app --args -captureScreenshots YES             # lsappinfo: type="UIElement"
log show --last 1m --predicate 'subsystem == "com.coreysilvia.CameraBridge" AND process == "CameraBridge"'
```

`CameraBridgeTests` (swift-testing) compiles `App/Sources/Model` directly and is not hosted, so tests never launch
the app or its menu bar item; live-engine tests use `BridgeEnvironment.testing` (loopback, no Bonjour, temp directory).

References: spec §3, §7; research brief §2.3 M14; the research notes on sandboxing and networking (not published)
(Local Network, menu bar extra, SMAppService, IOPM); integration brief (hubs, iCloud+ tiers); Apple HIG.
Acknowledgements: `Resources/Acknowledgements.md` (HAP-NodeJS, swift-crypto, BigInt).

## Camera types and integrations (2026-10-08; user docs `docs/integrations/`)

- The Add Camera wizard starts on **Camera Type** (`Model/CameraType`, `Manager/AddCameraTypePages`): ONVIF/RTSP with automatic detection, brand presets (Hikvision, Reolink,
  Tapo, Amcrest/Dahua, DoorBird, Wyze's official RTSP, a manual RTSP URL), the UniFi Protect console and cloud cameras (Ring, Google Nest, Wyze other models, Tuya, other go2rtc
  sources). Each shows what Camera Bridge gets from it (live view, HomeKit recording, events), its setup steps and honest notes (unofficial access, battery cameras).
  `CameraType.vendorChoice` is the engine route (`VendorChoice` gained `.amcrest`, `.doorbird`, `.unifi`, `.go2rtc`); `AddCameraWizardModel.cameraType` and `vendorChoice` follow each other.
  Types that are not searched for (`!CameraType.usesDiscovery`) skip the Find Your Camera page, and the step count follows.
- **Connect pages for services** (`IntegrationConnectPage`): a pasted go2rtc source (Ring, Wyze, Tuya, other; validated by `Go2RTCSource`, which refuses sources that run programs) with
  **Open Sign-In Page** (`BridgeEngine.beginIntegrationSetup`: go2rtc's own page on loopback; Camera Bridge never sees the account), the guided Google Nest steps (`NestDeviceAccess`:
  project and OAuth client → Google's link → pasted code → camera list), and UniFi Protect (console address + API key → camera list). Wyze's official RTSP takes the camera's IP and the
  RTSP user and tries `/stream0`, then `/live`, stopping at a rejected login.
- A cloud camera's secret (the go2rtc source) or a console's API key is stored as the camera's Keychain password (`AddCameraWizardModel.storedSecret`); `config.json` has only
  `CameraConfiguration.integration`. The camera page's Connection group shows the service and **Replace Source… / Replace Key…** for them (`SecretReplacementSheet`); `CameraConfiguration.hasCameraInterface` /
  `displayAddress` (`Model/CameraInterface`) keep the Camera Settings, readiness and web-page parts for cameras that have an interface of their own.
- Tests: `AddCameraTypeTests` (each type's flow through the model with `FakeSetupService`), `CameraInterfaceTests`.
