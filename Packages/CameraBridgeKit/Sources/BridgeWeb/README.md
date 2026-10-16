# BridgeWeb

The web interface of Camera Bridge OS, as portable Swift: an HTTP/1.1 server over the injected `NetworkTransport`, the JSON API
(`/api/v1`), password and session handling, static file serving and an SVG QR code encoder. It depends on the engine and on
`Crypto` only; every test runs on a Mac against a fake backend, the in-memory transport or the real engine. The API contract is
in `docs/linux/ARCHITECTURE.md`; the interface itself is `linux/web/`.

## Layout

| File | What |
|---|---|
| `HTTPServer.swift`, `HTTPTypes.swift` | Keep-alive and pipelined requests (parsed by BridgeSupport's `HTTPRequestParser`), head, body and time limits, connection limits per peer, chunked streaming answers (server-sent events, multipart JPEG) that end when the client leaves |
| `WebApp.swift`, `WebApp+Routes.swift`, `WebApp+Bridge.swift` | The route table and handlers; Host, Origin, session and CSRF checks; security headers |
| `AuthStore.swift`, `Security.swift` | First-run setup, PBKDF2-HMAC-SHA256 (600,000 rounds, per-password salt), 256-bit session tokens kept as SHA-256 hashes in `<data>/web/auth.json` (0600), login rate limiting, constant-time comparison |
| `CameraSetup.swift`, `CameraTypeCatalog.swift`, `HostInput.swift` | The Mac app's Add Camera wizard as a stateless service: the same types, words and checks |
| `EventHub.swift`, `LogFeed.swift` | Server-sent events from the engine's observable state; the live log |
| `StaticFiles.swift` | The interface's files: content types, ETag and 304, traversal-proof paths |
| `QRCode.swift` | QR Code encoder (byte mode, versions 1 to 10, levels L and M) drawing SVG |
| `BridgeBackend.swift`, `SystemControl.swift` | The seams: `EngineBackend` wraps `BridgeEngine`; `SystemControlling` is the operating system under the bridge |
| `WebApp+NVR.swift`, `WebApp+NVRStorage.swift`, `WebApp+NVRCatalog.swift`, `WebApp+NVRMedia.swift`, `WebApp+NVROptimize.swift`, `ArchiveLocation.swift` | The NVR routes: the route table (`WebApp.archiveRoutes`), admission slots, the gates and the one error mapping; storage and the Record switch; catalog and activity; fragment plans, video-only fragments, init segments and key pictures; the optimizer and its undo; the places the page may offer for recordings (`ArchiveLocation`: the browser sends the id and never the path) |

## Additions beyond the contract

Installer stick (2026-10-14, docs/CONTRACT_CHANGES.md): `SystemInfo.runningFromUSB` says whether the system runs from a USB drive; the System page offers installing to a disk only then.

New module (additive; docs/CONTRACT_CHANGES.md 2026-10-08): `BridgeWeb` with `WebService`, `WebApp`, `WebConfiguration`, `HTTPServer`,
`HTTPRequest`, `HTTPResponse`, `ResponseStream`, `AuthStore`, `BridgeBackend`, `EngineBackend`, `BridgeOverview`,
`SystemControlling`, `UnavailableSystemControl`, `SystemInfo`, `UpdateStatus`, `InstallTarget`, `SystemError`, `LogFeed`,
`CameraTypeCatalog`, `CameraTypeSpec` and `QRCode`.

Labels (2026-10-14, docs/CONTRACT_CHANGES.md): `BridgeBackend.setCleanPicture(cameraID:clean:)` (extension default throws), route `POST cameras/:id/clean-picture`, and `labels=1` on the clip route (`WebApp+NVRClipLabels.swift`: the clip re-encoded with the camera's label by ffmpeg, streamed as fragmented MP4).

Camera clocks (2026-10-14, docs/CONTRACT_CHANGES.md): `BridgeBackend.setCameraClockShown(cameraID:shown:)` and `BridgeBackend.setCameraTimeZone(cameraID:)` (extension defaults throw), routes `POST cameras/:id/camera-clock` and `POST cameras/:id/camera-time-zone`, and `timeZone` in the settings resource.

Live video (2026-10-14, docs/CONTRACT_CHANGES.md): `BridgeBackend.liveVideo(cameraID:stream:displayWidth:)` (an extension default throws `EngineError.cameraNotRunning`, so existing conformers compile) and the route `GET /api/v1/live` (`WebApp+LiveVideo.swift`: one answer carries every asked camera's own video as fragmented MP4, framed per camera; `LiveMP4Remuxer` in BridgeEngine makes the fragments).

Recording drive (2026-10-13, docs/CONTRACT_CHANGES.md): `SystemControlling.recordingDrives()`, `SystemControlling.useRecordingDrive(targetID:phrase:keepData:)` and `SystemControlling.forgetRecordingDrive()` (extension defaults refuse, so existing conformers compile), `RecordingDriveReport`, `InstallTarget.isRecordingDrive` and `InstallTarget.inUse`; the routes are in `docs/linux/ARCHITECTURE.md`.

Wi-Fi (2026-10-13, docs/CONTRACT_CHANGES.md): `SystemControlling.wifi()`, `SystemControlling.scanWifi()`, `SystemControlling.joinWifi(ssid:password:restart:)`, `SystemControlling.forgetWifi(ssid:)` and `SystemControlling.setupHotspot()` (extension defaults), `WifiNetwork`, `WifiReport` and `SetupHotspot`; the setup routes and the captive-portal redirect are in `docs/linux/ARCHITECTURE.md`.

NVR seams (2026-10-10, docs/CONTRACT_CHANGES.md): `BridgeBackend.archive`, `BridgeBackend.inspectArchiveFolder(_:)`, `BridgeBackend.setNVR(cameraID:enabled:recordSound:)`
(requirements without defaults: `EngineBackend`, `DemoDiscoveryBackend` and the tests' `FakeBackend` are the conformers) and `BridgeOverview.nvrStorage`.

NVR web API (2026-10-10, docs/CONTRACT_CHANGES.md): `BridgeBackend.optimizeForHomeKit(cameraID:)` and `BridgeBackend.undoHomeKitOptimization(cameraID:)` (requirements without defaults, like the seams above). The routes themselves are internal: `archiveRoutes` lists them, and their requests and answers are listed in `docs/linux/ARCHITECTURE.md`. Archive requests are admitted at most `WebConfiguration.maximumArchiveReads` (8) at once and `maximumArchiveReadsPerAddress` (6) per peer, the next gets `429 busy`; a media answer is at most `maximumSegmentBytes` and `Cache-Control: no-store`, without ranges or validators, and `HEAD` on it is `405`.

NVR limits and locations (2026-10-10, docs/CONTRACT_CHANGES.md): `ArchiveLocation` (a place the page may offer for recordings: `id`, `label`, `path`; the browser sends
the id, never the path), `WebConfiguration.archiveLocations`, `WebConfiguration.maximumArchiveReads` (8), `WebConfiguration.maximumArchiveReadsPerAddress` (6) and
`WebConfiguration.maximumSegmentBytes` (16 MiB). The Content-Security-Policy gains `media-src 'self' blob:`.

- Plugins (2026-10-15): the Wyze and eufy plugins (`Plugins/`). `WebConfiguration.wyzeTransport` and `WebConfiguration.eufyBridge` let tests replace
  Wyze's servers and the `eufy-bridge` helper. Neither plugin keeps a password: Wyze's session is in the secret store, eufy's in its helper's folder.

- Pan and tilt (2026-10-16): `BridgeBackend.panTilt(cameraID:pan:tilt:)` (extension default throws) and route `POST cameras/:id/pan-tilt`.

## Security notes

- Only IP addresses, `localhost`, `*.local`, `*.home.arpa`, names without a dot and `allowedHosts` are served (DNS rebinding).
- A request that changes something needs an `Origin` that matches `Host` (or `Sec-Fetch-Site: same-origin`), the session's
  `X-CSRF-Token` and `Content-Type: application/json`.
- The session cookie is `HttpOnly; SameSite=Strict; Path=/` (and `Secure` behind a TLS front end).
- Recordings: every NVR route needs a session. The browser sends ids and times, never a path (a location is an opaque id from `WebConfiguration.archiveLocations`, a fragment
  id is opaque). Footage is `Cache-Control: no-store`, an answer is at most `maximumSegmentBytes`, there is no `Range` support and HEAD on a media route is 405. Archive
  requests are admitted at most `maximumArchiveReads` in all and `maximumArchiveReadsPerAddress` per peer address (`429 busy`, `Retry-After: 1`), and no handler touches the
  disk on the cooperative pool.
- The Content-Security-Policy allows `media-src 'self' blob:` and nothing else beyond what the interface already had: the player's MediaSource URL is a `blob:`; no script, frame, worker or remote host is widened.
- Camera passwords, cloud sources and API keys go to the engine's secret store and never into an answer, the log or a file of the web
  interface.
