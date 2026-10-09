# CameraAdapters

Vendor drivers (Hikvision ISAPI, Reolink API, ONVIF, generic RTSP, demo), self-reconnecting event sources, talkback
sinks, WS-Discovery, soft motion detection and the local webhook server. Portable: depends on RTSP, RTP, MediaCore,
BridgeSupport only; HTTP through `AuthenticatingHTTPClient`, TCP through the injected `NetworkTransport`, XML through
Foundation `XMLParser` (`FoundationXML` on Linux), WS-Discovery through BSD UDP sockets (`Darwin`/`Glibc`). Owner: W1-7.

## Public entry points

- `CameraDrivers.make(vendor:…transport:)` → `HikvisionDriver`, `ReolinkDriver`, `ONVIFDriver`, `GenericRTSPDriver`,
  `DemoCameraDriver` (all internal types behind `CameraDriver`); `CameraDrivers.detectVendor` (checked concurrently,
  precedence ISAPI realm/namespace → Reolink `/api.cgi` JSON → ONVIF `GetSystemDateAndTime` on ONVIF/HTTP port, 8000, 8080, 2020).
- `ONVIFDiscovery.discover(timeout:)`, `SoftMotionDetector`, `WebhookServer`.
- Additions beyond the contract: `CameraEvent.eventChannelUnreliable(shortSessions:)` (an event channel that connects and drops again and
  again; the engine falls back to built-in motion detection), `CameraAdapterError`, `ReolinkStreamURLs` (RTSP + HTTP-FLV builders),
  `WebhookServer.boundPort`, `WebhookServer.listenerStates` / `ListenerState` (listening, each failed attempt to listen
  again after the platform stopped the listener, stopped: review W4 round 3); `CameraDrivers.detect` → `VendorDetection` (vendor + the ONVIF port that answered when it
  isn't the HTTP port; `detectVendor` returns its vendor), `CameraDrivers.onvifPort(endpoint:)` (the ONVIF device
  service's port: configured/HTTP port, else 8000, 8080, 2020), `CameraProbeResult.onvifPort` (set by the engine's
  probe), `WebhookServer.CameraState` and `WebhookServer.init(port:token:loopbackOnly:transport:cameras:)` (the
  contract initializer plus a camera lookup: 404 / 409 for unknown / disabled camera IDs);
  `CameraDrivers.make(vendor:endpoint:credentials:mainStreamURL:subStreamURL:transport:cameraID:)` (the contract
  `make` plus the configured camera's ID, which everything the driver builds logs with; the contract overload passes
  nil) and `CameraDriver.close()` (a requirement with a default that does nothing: ends the camera sessions a driver
  holds, Reolink's API login; the driver stays usable), W4 review round 4.
- `HomeKitReadinessAdvisor` (2026-10-01, docs/CONTRACT_CHANGES.md): grades a camera's ONVIF encoder settings and
  measured stream facts against HomeKit Secure Video's expectations (`evaluate`), with vendor-specific manual fix-up
  steps (`manualSteps`); `MeasuredStreamFacts`, `HomeKitReadinessCheck`, `HomeKitReadinessReport`. `CameraSettingsService`
  grows `hikvisionSmartCodecEnabled`/`setHikvisionSmartCodec` (ISAPI read-modify-write of a channel's smart codec);
  `CameraDrivers.hikvisionChannelID(mainStreamURL:sub:)` exposes the ISAPI channel numbering outside the module.

- Offline cameras (2026-10-02, docs/CONTRACT_CHANGES.md): `CameraDrivers.make(...reachability:)` takes the camera's `CameraReachability`
  (BridgeSupport). A Reolink driver then sends nothing to a camera known to be unreachable (`CameraOfflineError`), reports what its
  requests show, and sends one request at a time to a camera address (`CameraHTTPGates`, shared by every `ReolinkAPI` of that
  address: a Wi-Fi doorbell serves only a few connections); its event channel and ONVIF side channel wait for the probe instead of
  failing on their own clocks. Reolink answers -9 and -26 (ability error) and a bare ONVIF "Sender" fault read as *unsupported*, not
  as a failure to retry (`CameraConfigFailure.from`).
- Keyframe request (additive, live-view hardening): `CameraDriver.requestKeyframe(subStream:)` (default: throws `.unsupported`) asks the
  camera for an IDR so a live view that starts inside a long GOP does not wait for the next one: Hikvision `PUT
  /ISAPI/Streaming/channels/<id>/requestKeyFrame`, ONVIF `SetSynchronizationPoint` on the main/sub profile (tokens from the probe,
  listed once otherwise). One call per need, never retried: `CameraKeyframeGuard` spaces requests 10 s per camera and stream, never
  asks again a camera that answered "not supported" (HTTP 404/405/501, `ActionNotSupported`), and nothing is sent while
  `ONVIFLoginGuard` has the camera's logins paused; a rejected login of its own pauses them (2 min) and is not repeated; the call
  runs under the camera's `CameraHTTPGates` gate.
- Camera's own clock (2026-10-02, docs/CONTRACT_CHANGES.md): `CameraSettingsService.hideCameraClock()` /
  `restoreCameraClock(_:)` turn the camera's own on-screen date/time off and back on (Hikvision ISAPI
  `/ISAPI/System/Video/inputs/channels/<n>/overlays` `DateTimeOverlay/enabled`, Reolink `GetOsd`/`SetOsd` `osdTime`, ONVIF Media
  `GetOSDs` / `DeleteOSD` / `CreateOSD` / `SetOSD` for Date, Time and DateAndTime text elements), each a read-modify-write that
  is read back; `HiddenCameraClock` (how, and what was there before), `CameraClockChange`, `CameraConfigMethod.clockOrder(vendor:preferred:)`
  (the vendor's API, then ONVIF; the remembered method first) and `CameraConfigMethod.clockDisplayName`. A camera without such an
  overlay is reported as not supported, never thrown; credential problems end the chain (the ONVIF login guard is respected).

## Behaviour and invariants

- Event sources (`SupervisedEventSource`) start on the first `events()`, reconnect with `Backoff` (1 s → 60 s; a session
  that lived ≥ `healthyAfter` reconnects at once; rejected credentials emit `.authenticationFailed` — Hikvision's shared
  stream replays it to late subscribers — and wait 10 min, so login lockouts are never tripped), emit
  `.eventChannel(connected:)` per session and stop when released (keep the source; `stop()` finishes every stream and
  runs the source's stop hook, e.g. Reolink `Logout`). A session that connected but ended before `healthyAfter` backs off on its
  own schedule (`ReconnectPolicy.shortSessionBackoff`: 5 s doubling to 5 min for ONVIF and Reolink; ONVIF's `healthyAfter` is
  30 s); `ReconnectLoop` logs the first failure of a streak as a warning, the rest at debug with a summary every 10 min; after
  5 short sessions in a row the source emits `.eventChannelUnreliable` and the engine falls back to built-in motion detection.
  Tapo (measured, unauthenticated): its ONVIF HTTP server closes a connection idle for 10.3 s, which kills a PullMessages long
  poll (`Timeout` PT1M); the PullPoint loop retries on the same subscription with 70 % of the time the camera tolerated and
  remembers it per host. `EventHoldState`
  emits every transition once: a key is on while any source is on; pulse sources expire after their hold (20 s);
  doorbell rings within 3 s of the previous ring are dropped (ONVIF `Visitor` + Reolink polling). When a channel drops,
  level states (sources without a hold) end with `false` events before `.eventChannel(connected: false)`; the
  reconnected channel re-asserts whatever is still on. Pulses keep their hold.
- Object detections (ONVIF, Hikvision smart events, Reolink AI) also turn motion on, so HKSV records them.
- Camera-reported numbers (sample rates, sizes, frame rates, JSON numbers, dates) pass through `CameraNumbers` or range
  checks: NaN, ∞, huge or negative values are dropped, never converted (no traps on hostile input).
- ONVIF: WS-UsernameToken PasswordDigest with the camera clock offset (SHA-1 from BridgeSupport's `Hashes.sha1`, i.e.
  swift-crypto; no hand-written hash here); XAddrs keep port/path but take the configured
  host; with "Use HTTPS" (an HTTPS device service) reported `http` XAddrs, subscription addresses and snapshot URIs
  become `https` on the device service's port, so media, events, PullPoint and snapshots never fall back to cleartext
  (W4 review, round 3); stream/snapshot URIs lose credentials. Event states with a stop (MotionAlarm, cell motion,
  field detector, rule detectors, tamper, DigitalInput, DetectedSound) are keyed per property instance — full topic plus
  Source items — so each detecting service (Imaging §5.5.1 `…/ImagingService`, `…/AnalyticsService`,
  `…/RecordingService`), video source and rule is its own OR input; per subscription, a stop also ends the instances
  whose Source items it does not contradict (a firmware that sends fewer items, or none, on the stop leaves nothing
  stuck). PullPoint: `PT2M` / `PT1M` / 10 messages / 80 s reply; Renew every 60 s
  and whenever the next pull could end within 10 s of the subscription's end (from 30 s after the last renew);
  ActionNotSupported-style faults → PullMessages only, ResourceUnknown / "create subscription first" → subscribe again,
  other faults retried, given up after 3; `Unsubscribe` only for a created subscription, sent even on cancellation.
- Hikvision: one alertStream per device (`HikvisionAlertHub`, keyed by scheme/host/port/credentials, reference-counted)
  shared by every channel driver; each camera filters by `channelID` when its stream URL names an ISAPI channel
  (`…/channels/<n>01`, also 101) and applies its own holds. Multipart parsing: header boundary or literal `--boundary`,
  Content-Length parts, JPEG skipped, unsized parts end only at whole delimiter lines (linear scan).
  VMD/smart/tamper/IO/audio pulses held 20 s; any bytes (videoloss heartbeat) feed the 5-min idle watchdog; a stream
  that died within 10 s waits ≥ 10 s. Re-subscribing (every event source after a driver's first one: wake, network
  change) reconnects the shared stream at once when every camera on it has re-subscribed since its current attempt
  began — one reconnect per refresh, none when a camera just joins, none after rejected credentials. Probe:
  `deviceInfo`, `Streaming/channels`, `Event/triggers` (only `center` notifications reach alertStream),
  `TwoWayAudio/channels` (skipped for HTTPS cameras, which report no two-way audio). Intercoms are not flagged
  `isDoorbell` (no ring event is mapped; the webhook `doorbell` event can ring a camera the user set up as a doorbell).
- Hikvision talkback: `open`/`close` via ISAPI; audio is a raw `PUT …/audioData` (`Content-Length: 0`, then G.711 bytes
  on the socket) over the injected transport with a Digest answer (Basic only from a camera that never asked for
  Digest) — URLSession cannot stream an open-ended upload.
  Probe and sink choose the TwoWayAudio channel by one rule (`HikvisionTalkbackSink.channel(forCamera:in:)`): the
  camera's own channel when the device lists it, else channel 1 (an NVR's shared channel); neither listed → no two-way
  audio. The codec is read from that channel (W4 review, round 3: an NVR camera 2+ opened a channel the device lacked).
  An NVR's cameras share channel 1, so the camera's side of a two-way session (`PUT …/open`, the upload, `PUT …/close`)
  belongs to `HikvisionTwoWaySession`, one per device (scheme, host, HTTP port) and channel, shared by every camera's
  sink: the first open opens it (closing a stale session first), an open while its upload is up joins it, the last
  sink's close closes it, and opens and closes reach the device in order; while one camera talks the others' audio is
  dropped until it has been silent for 1 s (W4 review round 4: one camera's open or close ended another camera's live
  talk session).
  `inputFormat` is PCMU 8 kHz, PCMA if the camera reports A-law on `open()` (read it after opening); a two-way channel
  set to any other codec (G.726, G.722.1, MP2L2, AAC…) fails `open()` with `.unsupported` naming the setting to change
  (the camera's configuration is not rewritten); nothing reported keeps PCMU. The upload's raw connection cannot do
  TLS, so HTTPS cameras get no sink (`makeTalkbackSink()` nil, probe `twoWayAudio` false): no Speaker is published
  for a talk button that could never open (W4 review).
- Talkback sinks (Hikvision, ONVIF RTSP backchannel): `send` fails with `TransportError.timedOut` after 5 s when the
  camera stops reading (the connection/session is closed; `open()` again) — also when the closed send fails first; a
  concurrent `open()` closes what it replaces. The RTSP backchannel session sets up only the backchannel track
  (`RTSPConfiguration.backchannelOnly`: no second main stream per talking viewer); a camera that refuses that (RTSP
  error status or protocol error) gets one full session whose media is drained.
- Reolink: token login in the POST body (never in a URL), refreshed a minute before the lease (3600 s) and after
  -6/-21. One `ReolinkAPI` per driver serves probe, snapshots and event polling (reconnects reuse the live token;
  concurrent callers share one login; stopping the event source sends `Logout`, and so does `close()`, which the
  engine's probe calls on its throwaway driver: an Add Camera or Connection check no longer holds one of the camera's
  few sessions for an hour); after -5 (max sessions) or -105 ("Frequent logins, please try again later!") no login is
  attempted for 5 min (W4 review round 4). `GetEvents` (else `GetMdState` + `GetAiState`) polled at 1 Hz; doorbells (`type BELL`, model,
  `visitor`) and ONVIF-detection models also run ONVIF PullPoint when ONVIF is switched on: `GetNetPort.onvifEnable`
  decides (`supportOnvifEnable` only says the camera has the switch, and newer firmware ships with it off); off → no
  side channel and a once-per-source notice to turn ONVIF on for instant rings; `GetNetPort` refused (older firmware,
  user rights) → `supportOnvifEnable`, else a configured ONVIF port, decides as before. Port: configured, else the
  reported `onvifPort`, else 8000. Each event session
  decides on legacy polling only when `GetEvents` is refused for the request itself (-1/-4/-9/-23/-24/-26: unknown or
  unsupported command, bad or missing parameters, no ability; transient codes are retried), and on the ONVIF side channel only
  from `GetDevInfo` / `GetAbility` / `GetNetPort` answers: an unreachable camera fails the session (backoff) instead
  of latching legacy polling (no visitor) or dropping `Visitor`. The channel reports connected from the first successful poll. Level states
  the side channel turned on end when its subscription ends (polling keeps the session up). Talkback = ONVIF RTSP
  backchannel if the probe saw one in the SDP (nil after a negative probe).
- `SoftMotionDetector`: ~4 fps, box-downscale to `analysisWidth`, running average α 0.1, pixel threshold 32 − 7·s,
  area threshold 10 % → 0.2 %, on after 2 hits, off after 10 s quiet, global changes reset the background. Motion is
  released only from `process(_:at:)`: if frames stop arriving while motion is on, it stays on — the caller (BridgeEngine)
  ends motion itself when the decoded stream stops. Times should be monotonic (BridgeEngine's monitor passes its own);
  a time before the last hit (a clock stepped back) restarts the quiet period from there instead of holding motion on
  for the size of the step (W4 review round 4).
- `WebhookServer`: `POST /cameras/<uuid>/<event>` + `Bearer` token (401 first, constant time), 404/405/400, keep-alive;
  with a camera lookup (`init(…cameras:)`; the engine asks its `EventRouter`) an authorized event for an ID no
  configured camera has is 404 and for a disabled camera 409, nothing is published and each is logged once per ID — a
  stale or mistyped ID in a Frigate / Home Assistant automation no longer gets 204 for a dropped event (W4 review,
  round 3);
  30 s idle, 5 s to the first byte of a new connection, 10 s to receive a whole request, 32 connections. Before the
  token is known any LAN peer can send bytes, so a head may be at most 8 KiB with at most 64 header lines (else 400),
  the incremental parser examines each byte once however it is trickled (no re-search or re-parse per read), and a
  request whose body is still to come is answered 401 and closed as soon as its head shows a wrong token — its body is
  never read (W4 review round 4: a trickling peer without the token kept many cores busy). With every
  slot taken, the oldest connection that has not sent a request with the right token is closed to admit the newcomer
  (idle or unauthenticated LAN sockets cannot lock Frigate / Home Assistant out); only when all 32 are authorized is
  the newcomer refused. A listener the platform stops on its own (`connections` ends without `stop()`: interface
  change, sleep/wake, Local Network access revoked) is replaced on the same port with backoff (1 s → 30 s; port 0
  reuses the previous port until it is refused as in use 3 times), keeping `events` and open connections;
  `boundPort` is nil meanwhile. Concurrent `start()` binds once; released without `stop()` it closes its listener and
  stops retrying (W4 review).
- Hard bounds (`withTimeout`: vendor detection, RTSP probes, Hikvision talkback replies, webhook reads) use
  BridgeSupport's `withDeadline`, so they return on time even when the bounded call ignores cancellation (it is
  cancelled and abandoned); a missed bound is `TransportError.timedOut`.
- Demo camera: motion for 10 s every 60 s, first after 10 s. Nothing here logs credentials, tokens or credentialed URLs.
- Camera-tagged logs (W4 review round 4): a driver made with a camera ID (`CameraDrivers.make(…cameraID:)`, as
  `CameraRuntime` does) gives it to everything it builds — event sources ("events", "reolink-events", "onvif-events"),
  camera API clients (`ReolinkAPI` "reolink", `ONVIFClient` "onvif"), RTSP probes ("rtsp-probe", and
  `RTSPConfiguration.cameraID` of the probe's and the backchannel's RTSP sessions) and talkback sinks ("talkback") — so
  their lines carry `LogEntry.cameraID`. Hikvision's shared alertStream logs each of its lines once per subscribed
  camera (tagged; the message names the device). Engine-wide lines (vendor detection, discovery, the webhook) stay
  untagged.
- Transport errors of camera HTTP requests (`CameraHTTP.send`, ONVIF SOAP calls, the Hikvision alert stream) are
  rethrown without their URL (`CameraHTTP.sanitized`, over BridgeSupport's one `URLFreeErrors.sanitized`: URLError →
  `TransportError`, other Foundation errors → domain and code, `CameraAdapterError` unchanged): URLSession puts the
  failing URL — a Reolink `token=`, a password in an ONVIF snapshot URI — in the user info, and callers log errors
  (W4 review).
- Buffered camera answers (`CameraHTTP.send`: Reolink commands and snapshots, Hikvision ISAPI; ONVIF SOAP calls, also
  the PullMessages long poll; vendor detection) are bounded by `AuthenticatingHTTPClient.data(for:)`: at most 16 MiB
  (`HTTPClientError.bodyTooLarge`, passed through unchanged) and the client's timeout per round trip in total (10 s;
  the long poll's 80 s), so the Reolink and ONVIF event loops cannot hang on, or buffer, an endless body (W4 review).
- Stream URLs drop `user:password@` with BridgeSupport's `URL.removingUserInfo` (StreamInfo never carries it).
- ONVIF SOAP faults (`ONVIFSOAP.fault(in:)`: code, subcode, reason) pass through BridgeSupport's `Redact.cameraText`
  (at most 200 characters each, control characters replaced) before they reach `CameraAdapterError.soapFault`, the
  logs and the app (W4 review round 4: a fault could be 16 MiB of text with line breaks).
- The Hikvision talkback upload never answers a Basic challenge once the camera asked for Digest (BridgeSupport's
  `BasicDowngradeGuard`, one per sink; W4 review round 4): a host impersonating the camera would read the password.

## Tests

`Tests/CameraAdaptersTests`: fixture-driven parsers and mappers (`Fixtures/{onvif,hikvision,reolink}`, synthetic, read
via `#filePath`); loopback mock cameras (`MockHTTPServer` on `AppleNetworkTransport` + `HTTPRequestParser`, macOS
only); RTSP through `FakeRTSPSession` (no real RTSP or LAN traffic; the live multicast probe is not unit-tested).

## References

Public ONVIF specifications, the Hikvision ISAPI and Reolink HTTP API v8 documents, the project's research notes (not
published), and Scrypted's Hikvision, ONVIF and Reolink plugins (read for behaviour only; no code copied).

## Additions beyond the contract: integrations beyond RTSP/ONVIF (2026-10-08, docs/CONTRACT_CHANGES.md; user docs: `docs/integrations/`)

- **Native adapters** (`CameraVendor.amcrest`, `.doorbird`, `.unifi`): `AmcrestDriver` (Dahua/Amcrest CGI: `magicBox.cgi`, `snapshot.cgi`,
  `eventManager.cgi?action=attach&codes=[All]` with Digest; `AmcrestEventStreamParser` finds `Code=…;action=…;index=…;data={…}` lines whatever the
  multipart framing, `AmcrestEventMapper` maps them to motion, smart detections, tamper, sound, inputs and doorbell presses), `DoorBirdDriver` (LAN API
  `info.cgi`, `image.cgi`, `monitor.cgi?ring=doorbell,motionsensor`, RTSP `/mpeg/720p|media.amp`), `UnifiProtectDriver` (official Integration API with an
  API key: cameras, `rtsps-stream`, snapshots; the events WebSocket `subscribe/events` through `UnifiProtectEvents` and `UnifiEventTracker`; video through
  the go2rtc helper). All use `ONVIFLoginGuard` so a rejected login pauses every login to the camera, and `SupervisedEventSource` for events.
- **`RawHTTPStream`**: the `multipart/x-mixed-replace` event streams (Dahua, DoorBird) are read on a raw HTTP connection (`NetworkTransport`), answering a
  Digest/Basic challenge once, because URLSession holds each part back until the next boundary. HTTPS endpoints fall back to URLSession.
- **go2rtc** (`Integrations/`): `Go2RTCSource` (a validated, secret go2rtc source; only allow-listed schemes), `Go2RTCConfig` (loopback ports, an allow-list
  of modules and API paths, secrets as `${CB_…}` placeholders), `Go2RTCManager` (the supervised child process: random free ports kept for the run, secrets
  only in its environment, health check, restart with backoff, output to the log with secrets masked, a second short-lived helper for go2rtc's sign-in
  pages), `Go2RTCDriver` (`CameraVendor.go2rtc`: the camera's source is the Keychain password; probe = attach + RTSP DESCRIBE of the local address),
  `StreamHoldingDriver` (drivers that hold helper streams: `attachStreams()` / `releaseStreams()`), `NestDeviceAccess` (Google's documented Device Access
  sign-in steps for the wizard), `IntegrationSettings`.
- Tests: `Go2RTCManagerTests` (fake `HelperLaunching` from TestSupport), `Go2RTCRealBinaryTests` (the real helper when `CAMERABRIDGE_GO2RTC_DIR` names its
  folder), `AmcrestTests`, `DoorBirdTests`, `UnifiProtectTests` (recorded payloads in `Fixtures/`), `RawHTTPStreamTests`, `NestDeviceAccessTests`.

Also: `IntegrationService` (ring, nest, tuya, wyze, unifiProtect, other), `Go2RTCStreamProviding` (what a driver needs from the helper; `Go2RTCManager` conforms), `Go2RTCError` and `IntegrationError` (readable failures), `UnifiProtectCamera` (the wizard's console camera list), `AmcrestRTSP` and `DoorBirdRTSP` (the RTSP paths the engine uses as defaults), `CameraDrivers.unifiProtectCameras(endpoint:apiKey:)`.
