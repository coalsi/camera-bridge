# CameraAdapters

Vendor drivers (Hikvision ISAPI, Reolink API, ONVIF with the IP camera web API next to it, generic RTSP, demo), self-reconnecting event sources, talkback
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
  holds, Reolink's API login; the driver stays usable), W4 review round 4. `CleanPictureBackup`, `CleanPictureChange`, `CameraSettingsService.cleanPicture()` and `CameraSettingsService.restorePicture(_:)` (2026-10-14: every label the camera draws itself off through Hikvision ISAPI's overlays document, Reolink's `Osd` or ONVIF's text OSD elements, and back from the saved copy). `PosixTimeZone` (2026-10-14: `string(for:)` reads the POSIX TZ string at the end of a zone file, `hasDaylightSaving(_:)`; cameras take their time zone in that form) and `CameraSettingsService.setCameraTimeZone(posix:)`. `CameraEventSource.credentialsConfirmed()` (2026-10-13, a requirement
  with a default that does nothing: the camera's video signed in with the same credentials, so a `SupervisedEventSource` waiting after a refused
  login tries again now, once per streak of refusals).
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
- Login pauses (2026-10-18, docs/CONTRACT_CHANGES.md): `CameraAdapterError.loginsPaused(until:)` is Camera Bridge's own pause after the camera
  refused a login (`ONVIFLoginGuard`, 2 min: nothing is sent, the camera locked nothing); `.lockedOut(until:)` is only the camera's own lock
  (Hikvision's "locked" answer, the IP camera web API's `passwordLock`, DoorBird's HTTP 423). Both are login refusals (`isLoginRefusal`, and
  `CameraConfigFailure.loginsPaused(until:)` ends a chain like `.lockedOut`: "logins paused"). `CameraSettingsSnapshot.onvifLoginLockedByCamera`
  says whose pause `onvifLoginPausedUntil` is, and `HomeKitReadinessAdvisor` words the two apart, its time in the bridge's zone (`BridgeTime`).
  The guard keeps the cause per host (`ONVIFLoginGuard.Pause`, `pause(host:)`, `pause(hosts:)` for one account behind several ports,
  `Pause.error`): while the camera's lock lasts it is the reason, and a refusal never shortens or recasts it. An `ONVIFClient` whose own login
  was refused reports `.unauthorized` on its next calls, not the pause it caused, so an ONVIF event channel (PullPoint, Reolink's ONVIF side
  channel) refused on its own login waits the 10-minute unauthorized delay (`ReconnectPolicy.delayAfterUnauthorized`), not the 2-minute pause.
- Changes the account may not make (2026-10-18, docs/CONTRACT_CHANGES.md): `CameraAdapterError.notPermitted(_:)` (the operation, "SetNTP"):
  the camera signed in the account Camera Bridge uses, then refused it a change, as the Reolink doorbell's ONVIF account reads `GetNTP` and
  `GetDNS` but is refused `SetNTP`. It is not a login refusal (`isLoginRefusal` is false): nothing pauses, the camera answered
  (`cameraAnswered`), `CameraConfigFailure.notPermitted` ("this account may not change it") lets a chain try its next method (on a Reolink
  never ONVIF after Reolink's API: the Reolink section below), and a step or
  a settings change says `CameraAdapterError.notPermittedReason` ("the account Camera Bridge uses may not change this; use an administrator
  account in the camera’s settings"; the steps quote refusals through the internal `refusalWords(_:)`). A setup step refused so says it typed,
  not only in words: `CameraSetupOutcome.notPermitted` (init parameter, default false; internal `CameraSetupOutcome.refused(_ error:)` and
  `notPermittedRefusal`) and `CleanPictureChange.notPermitted` (every way to take the labels off refused so, a way the camera does not have
  aside: internal `refusedOnlyForTheAccount(_:)`), so Set up for Camera Bridge goes on with the steps after it;
  `CameraAdapterError.isNotPermitted(_:)` says whether an error is one (`.notPermitted`, or the IPCamera Web family's API stopped for want of
  privilege). The IPCamera Web family's 532374 ("No Privilege") is one too: at a write once the camera signed Camera Bridge in it is
  `.notPermitted` ("set mobile"; nothing latched), and the steps a sign-in refused so stops are typed so (`CameraSetupOutcome.notPermitted`,
  their words the family's: internal `IPCamWebUnavailable.noPrivilege`, `notPermitted`). `ONVIFClient` throws it for a write
  (internal `writeName(action:)`: `Set…`, `Create…`, `Delete…`, PTZ moves and `Stop`, `SendAuxiliaryCommand`, `SystemReboot`; not the event
  service's messages) answered `NotAuthorized` or HTTP 401 within `loginProofWindow` (5 minutes) of a call that signed in on the same client
  (`provesLogin(action:)`: not ONVIF's calls before authentication, `preAuthenticationCalls`, which a camera may answer to anyone). A first
  call refused, or a write refused after only those, is a refused login as before (logins pause), and a refused login ends the proof. A camera
  whose ONVIF checks no password on its reads but does on its writes would read a wrong password as `.notPermitted` too: no pause, and the
  same words. The other way round, a write that no call proving the login came before on its client is still a refused login when the
  camera refuses it to the account: the page's camera time zone (`setCameraTimeZone(posix:)` asks only `GetSystemDateAndTime` first, a
  call before authentication) pauses logins for 2 minutes on such an account, as a Restore does whose first ONVIF call is a write. A
  keyframe request refused so (`SetSynchronizationPoint`) marks the camera as having none (`CameraKeyframeGuard`), so it is not sent again
  at every spacing.

## Behaviour and invariants

- Event sources (`SupervisedEventSource`) start on the first `events()`, reconnect with `Backoff` (1 s → 60 s; a session
  that lived ≥ `healthyAfter` reconnects at once; rejected credentials and the camera's own lock emit `.authenticationFailed` — Hikvision's
  shared stream replays it to late subscribers — and wait 10 min, so login lockouts are never tripped; an attempt that met Camera Bridge's
  own login pause (`.loginsPaused`) sent no login: it emits nothing, logs that it waits, and tries again when the pause ends), emit
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
  few sessions for an hour); after -5 (max sessions), -105 ("Frequent logins, please try again later!"), -500 (too many
  addresses) or -507 (too many logins) no login is attempted for 5 min (W4 review round 4; -500 and -507 since 2026-10-18).
  Answers as the v8 error table and reolink_aio read them (2026-10-18): a setting succeeded only when `code` is 0 and
  `value.rspCode` is 200, and a refusal keeps the camera's `detail` (internal `ReolinkAPI.answer`, `Answer`); -7, -27, -501,
  -502 and a detail saying "password wrong" are wrong credentials; -503 "login deny", -506 "login locked" and a detail saying
  "locked" are the camera's lock (`.lockedOut`, no login for 30 min); -12, -13 and -17 (the camera did not get the command) are
  asked once more after 1 s; a `Set…` refused with a credential code after the session's login worked is
  `CameraAdapterError.notPermitted` (the account may not make it), not a wrong password. A `CameraSettingsService` keeps one
  `ReolinkAPI` for its life (a setup run or a security check logs in once; `close()` or the service's end logs out). `GetEvents` (else `GetMdState` + `GetAiState`) polled at 1 Hz; doorbells (`type BELL`, model,
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
  A configured camera's stream URLs come without their query credentials; `CameraDrivers.make(…, streamCredentials:)` gives
  the secret store's copy to the driver's RTSP sessions (probes, the ONVIF backchannel, talkback: `RTSPProbing.factory`),
  which send it in their request lines only; StreamInfo keeps the URL as configured.
- ONVIF SOAP faults (`ONVIFSOAP.fault(in:)`: code, subcode, reason) pass through BridgeSupport's `Redact.cameraText`
  (at most 200 characters each, control characters replaced) before they reach `CameraAdapterError.soapFault`, the
  logs and the app (W4 review round 4: a fault could be 16 MiB of text with line breaks).
- The Hikvision talkback upload never answers a Basic challenge once the camera asked for Digest (BridgeSupport's
  `BasicDowngradeGuard`, one per sink; W4 review round 4): a host impersonating the camera would read the password.

## Tests

`Tests/CameraAdaptersTests`: fixture-driven parsers and mappers (`Fixtures/{onvif,hikvision,reolink}`, synthetic, read
via `#filePath`); loopback mock cameras (`MockHTTPServer` on `AppleNetworkTransport` + `HTTPRequestParser`, macOS
only); RTSP through `FakeRTSPSession` (no real RTSP or LAN traffic; the live multicast probe is not unit-tested). The IP camera web API:
`IPCWebTests` (DES and token vectors, the page check, the request's bytes, editing in place, night vision and its overlapping changes,
the latch, the shared login pause) and `IPCWebSetupTests` against `FakeIPCWebCamera`. The internet guard's DNS: `CameraDNSTests` (two real
cameras' ONVIF answers, then read, apply, read back, restore, refusals and IPv6 against `MockONVIFCamera` and `FakeSetupCamera`; cameras
with two slots that keep one not sent, refuse one address twice or keep their second server whatever they are sent, `MockONVIFCamera.dnsSlots`)
and `CameraDNSOwnAPITests` (the IPCamera Web family's `set=eth` byte for byte, its restart and Restore, against `FakeIPCamWebCamera` beside a
`MockONVIFCamera`; Reolink's `SetLocalLink` against `MockONVIFCamera.otherAPI`), and `IPCWebDNSTests` (the IP camera web API's
`setNetworkLANConfig` byte for byte, its restart with dropped requests (`MockResponse.drop`), Restore, DHCP, a paused API, ONVIF beside it,
against `FakeIPCWebCamera` and `MockONVIFCamera`). A change the account may not make: `ONVIFWriteNameTests`
(which calls are writes and which prove the login) and `ONVIFWriteRefusalTests` (`MockONVIFCamera.refusedWrites` answers chosen writes with
`NotAuthorized` or HTTP 401 while its reads answer: `.notPermitted`, no pause; a first refused call, a write after only calls anyone gets, a
proof older than `loginProofWindow` and one ended by a refused login are refused logins).

## References

Public ONVIF specifications, the Hikvision ISAPI and Reolink HTTP API v8 documents, the project's research notes (not
published), Scrypted's Hikvision, ONVIF and Reolink plugins and reolink_aio (read for behaviour only; no code copied).
Reolink's commands, answers and menu paths: docs/integrations/reolink.md.

## Additions beyond the contract: the web API a camera showed (2026-10-18, docs/CONTRACT_CHANGES.md)

`CameraWebAPIFamily` (`ipcWebAPI`, `ipcamWeb`) and `CameraWebAPIFamily.seen(at:)`: the web API the address of an ONVIF camera showed since
the camera last started in the bridge (the IP camera web API's sign-in script, `IPCWebLatch`; the IPCamera Web family's page,
`IPCamWebLatch`), nil when none was seen. Nothing is sent. BridgeEngine's "Change it by hand" (`CameraFamily`) names the family's own menus
with it.

## Additions beyond the contract: Set up for Camera Bridge (2026-10-16, docs/CONTRACT_CHANGES.md)

The camera's side of "Set up for Camera Bridge" (design: `docs/superpowers/specs/2026-10-16-camera-setup-design.md`): every step is read
(its value then is the backup), applied with a read-modify-write of the camera's own document, read back, and restorable.
`CameraSetupStepID` (in apply order: `timeZone`, `timeSource`, `internetWatch`, `cleanPicture`, `streams`, `videoPassword`, `extraServices`, `upnp`, `cloud`), `CameraSetupChange`,
`CameraSetupReading` (`willChange`, `alreadyRight`, `notSupported`, `notOffered`), `CameraSetupOutcome` (with `needsRestart` for ISAPI `statusCode` 7,
which is noted and never acted on), `CameraSetupBackup` (one backup: `CameraTimeZoneBackup`, `CameraTimeSourceBackup`, `CleanPictureBackup`,
`CameraStreamsBackup`, `CameraFeatureBackup`; never a Hik-Connect verification code; the IP camera web API cloud's Authcode, which turning
that cloud back on needs, is carried but never encoded), `CameraNetworkFeature`, `CameraSetupText`
(the values in a person's words). `CameraSettingsService.readTimeZone(posix:zoneName:)` / `applyTimeZone(posix:)` / `restoreTimeZone(_:)`
(Hikvision ISAPI `/ISAPI/System/time` `timeZone` in Hikvision's own text, else ONVIF; Reolink its own API, below),
`CameraSettingsService.readTimeSource(server:)` / `applyTimeSource(server:)` / `restoreTimeSource(_:)` (ISAPI mode NTP and
`/ISAPI/System/time/ntpServers/1`; ONVIF `SetNTP` then `SetSystemDateAndTime` with NTP), `CameraSettingsService.readCleanPicture()`,
`CameraSettingsService.readFeature(_:)` / `setFeature(_:enabled:path:)` (Hikvision UPnP and Hik-Connect: `/ISAPI/System/Network/capabilities`
says whether the camera has them, the cloud's path is tried as `EZVIZ` then `Ezviz`). Streams are only ever H.264/H.265: `CameraSettingsService.isStreamCodec(_:)`; `fetchSnapshot()` picks the main and sub
profiles among those whose `GetStreamUri` address matches the configured URLs (`CameraSettingsService.init(…subStreamURL:)`; the same path and the same value for every query parameter both name, a missing Dahua `subtype` being 0, `sameStream`), else the largest
and smallest such profiles, never a JPEG one; `CameraSetupReading.note` says when one of them is not offered. A `CameraSettingsService` keeps one ISAPI client for its
life (a client per request can crash FoundationNetworking on Linux).

## Additions beyond the contract: Reolink through its own API (2026-10-18, docs/CONTRACT_CHANGES.md)

Every Reolink step of "Set up for Camera Bridge" writes through Reolink's HTTP API (Reolink refuses ONVIF's writes to its ONVIF user;
commands, answers and menu paths: docs/integrations/reolink.md), each read back and restorable. ONVIF is written to only where Reolink's API
cannot make the change at all (internal `CameraConfigFailure.leavesONVIF`: `.unsupported`): the streams (a codec change, which Reolink ties
to the picture size and `SetEnc` cannot carry; `GetEnc` "not support"; a stream, a picture size or a value `GetEnc` does not show) and Clean
picture (no `GetOsd`, or `SetOsd` answered "not support" or "ability error") go on to ONVIF's `SetVideoEncoderConfiguration` and OSD calls
then. After any other answer of Reolink's API (the account may not, another refusal, a change that did not stick, no answer) nothing goes
through ONVIF, and Reolink's API goes first even when ONVIF changed the streams last time (`CameraConfigMethod.attemptOrder` and
`clockOrder` keep it first on a Reolink). The time zone, UPnP and the cloud never write through ONVIF, nor do the time source and the DNS
but on a Reolink without `GetNtp` or `LocalLink`. The streams step reads the camera's video profiles through ONVIF, as for every camera.
The steps: the time zone (`GetTime` / `SetTime`: `Time.timeZone` and the `Dst` rule, compared and written, not only the daylight-saving
switch; internal `ReolinkTimeZone`, which reads the sign of `timeZone` from the camera's own clock and else takes the guide's, west of
UTC), the time source (`GetNtp` / `SetNtp`), UPnP off (`GetUpnp` / `SetUpnp`), the cloud off (`GetP2p` / `SetP2p`, the UID; its preview's
note says the Reolink app stops working away from home and doorbell rings still come through Apple Home) and the DNS (`GetLocalLink` /
`SetLocalLink`, above); the streams through `GetEnc` with its range and `SetEnc` (`frameRate`, values inside the range, no `width`, `height`
or `vType`). `CameraTimeSourceBackup.interval` (Reolink's `Ntp.interval`; `hostName` and `port` hold `Ntp.server` and `Ntp.port`, `mode`
"NTP" or "manual"), `CameraTimeZoneBackup.reolinkTime` (`timeZone` and every number of `Dst` as the camera had them; nil in a backup saved
before 2026-10-18, which held only the switch: a run that changes the time zone completes it with the camera's zone and rule as read and
the old switch as `Dst.enable`, BridgeEngine's README, else it restores only the switch), and `CameraSettingsService.close()` (ends the
service's Reolink API session now; the service's end does too). A change `GetAbility` says the account may not make is not sent, and a
setting refused with a credential code once the login worked is `CameraAdapterError.notPermitted`: the step says to use an administrator
account (`CameraAdapterError.notPermittedReason`, `CameraSetupOutcome.notPermitted` set), and no login is paused. A time source an earlier
build saved through ONVIF (the setup keeps the oldest backup: the owner's doorbell holds `onvifMinimal`, NTP, pool.ntp.org) goes back
through `SetNtp` too, with `Ntp` as read, `enable` from the backup's mode and `server` its first server, else its `hostName`, with its
`port` and `interval` when it has them (a run that changes the time source completes such a backup that names no server with the camera's
own, BridgeEngine's README); one of NTP that still names no server is refused with why, nothing written (internal
`restoreReolinkTimeSourceFromONVIF`, `noSavedTimeServer`); ONVIF only for a Reolink without `GetNtp`.
`CameraSettingsService.setCameraTimeZone(posix:)` gives a Reolink the whole zone the same way (it set only the daylight-saving switch, and
fell back to ONVIF). Internal: `CameraSettingsService.reolink()`, `reolinkAbility(_:perChannel:)`, `reolinkMayNotChange(_:perChannel:)`,
`reolinkSet` (a refusal as the step's outcome), `ReolinkAbility`.
Tests: `ReolinkSetupTests` against `MockReolinkCamera` (`ReolinkDriverTests.swift`), which answers `GetAbility` (with the account's
permits), `GetNtp`/`SetNtp`, `GetUpnp`/`SetUpnp`, `GetP2p`/`SetP2p`, `GetLocalLink`/`SetLocalLink` (restarting its network after a write),
`GetEnc` with its range and `SetEnc` (-13 for a value outside the range), `GetTime`/`SetTime` (its clock in its zone, either sign),
`GetNetPort`, `GetOsd`/`SetOsd`, and error answers of the v8 table; every request body is kept and checked whole, and the doorbell's ONVIF
beside it must get no request but the reads of a doorbell on automatic DNS (`GetDNS`), and the writes of a change Reolink's API cannot make
at all (`onvifStaysTheWayForAChangeReolinksAPICannotMake`).

## Additions beyond the contract: Internet guard, the camera's DNS (2026-10-17, docs/CONTRACT_CHANGES.md)

Stage 1 (Watch) of the internet guard (design: `docs/superpowers/specs/2026-10-17-internet-guard-design.md`), the camera's side: every DNS
server it asks pointed at the bridge, so the bridge sees every name it looks up. `CameraDNSBackup` (`method`, `fromDHCP`, `servers`, optional
`searchDomains`, optional `ownAPI` since 2026-10-18: the DNS values of the camera's own API, below; optional `ipcWebAPI` since 2026-10-18: the
IP camera web API's `LANConfig` `DHCP`, `DNS1`, `DNS2`, below), `CameraDNSReading` (`servers` in use,
`fromDHCP`, `method`, `backup`, `pointsAt(_:)`: the camera asks that address and no other, an IPv6 address matching however it is written;
since 2026-10-18 wherever it has its servers from, the router's DHCP included (`fromDHCP` says so, and the Watch step's note that the
router can change them), and a slot holding 0.0.0.0 or :: is an empty slot, not a server, in readings and in Restore's comparison;
`serversUnknown` since 2026-10-18: a Reolink on automatic DNS whose ONVIF did not say which servers DHCP gives, below; `addressing` since
2026-10-19: the camera's `CameraAddressing` where the answer its servers came from shows it whole, ISAPI's address document or the IP camera
web API's `LANConfig` with its `MacAddress`, nil otherwise and nothing more asked for it, for BridgeEngine's "Change it by hand"),
`CameraSettingsService.readDNS()` (nil when the camera does not show its DNS servers; throws a login refusal),
`CameraSettingsService.applyDNS(server:)` (every server the camera asks set to that one address, read back; a refusal says what the camera
kept: "the camera asks Camera Bridge first but kept 8.8.8.8 as its other DNS server", or "the camera kept its own DNS servers") and
`CameraSettingsService.restoreDNS(_:)` (read back). Hikvision through ISAPI: `/ISAPI/System/Network/interfaces/1/ipAddress`, a
read-modify-write of the whole document in which only the `ipAddress` inside `PrimaryDNS` and `SecondaryDNS` changes (both set to the
bridge, and the read-back needs both: a camera that keeps its second server is refused, naming it; the camera's own address,
`addressingType` and gateway stay as they are; a missing `SecondaryDNS` is not added; IPv4 only; `statusCode` 7 noted: the step is done,
waiting for the camera's restart, which Camera Bridge starts only when the person presses "Restart the camera now" (BridgeEngine's README),
and the security check reads the DNS again before the guard counts the camera as watched; a camera that shows no document after the write
is a refusal). Since 2026-10-18 a Hikvision on DHCP (`addressingType` dynamic) is read `fromDHCP` (its DNS servers come with its address)
and its DNS is not written, as it would go back to the router's at the next renewal: the step is refused in words that name "Fix its
address so the DNS stays" (internal `hikvisionDHCPRefusal`; already right when the router hands it the bridge), and an ISAPI write answered
HTTP 403 is `CameraAdapterError.notPermitted`, not a refused login. The ISAPI document is built from the ISAPI 2.0 schema's shape and is not
yet checked on a real camera. Other cameras, and a Hikvision without that document, through ONVIF: `GetDNS` / `SetDNS` (`DNSManual`
entries, IPv4 and IPv6; the search domains are written back as the camera had them), checked against two real cameras' answers (one on
DHCP, one set by hand). Since 2026-10-18 `SetDNS` names the bridge in both slots first (a slot left empty, or one holding a server the
camera had, can send its lookups elsewhere: the owner's "Patio New" kept 8.8.8.8 as its second when sent the bridge alone), then the bridge
alone (for a camera that refuses one address twice), then the bridge and an empty entry (an empty `IPv4Address`, for a camera that refuses
both). A form answered with a fault is followed by the next at once, and so is one the camera took while it kept another server beside
the bridge. Each form the camera takes is read back at once and every 2 s: the first for up to 30 s (`DNSReadBackTiming`: a camera that
applies DNS slowly, or after its network restarts, still shows its old servers meanwhile), each later one for up to 6 s (ruling D2: the
setup dialog gives the whole run 180 s). Restore writes the old servers (or DHCP), and empties a slot its write did not name when the camera
kept the bridge there. Tapo and every other ONVIF camera go this way (a Dahua, Amcrest or Lorex through its CGI first, one that speaks the
IP camera web API, a Jennov, through that API instead: below); a camera whose ONVIF refuses `SetDNS` is refused in its words (the last
form's, or the account's), and one without `GetDNS` is not supported (router help).

`CameraSettingsService.readIPv6()` (2026-10-19): whether the camera has IPv6 on, as ONVIF's `GetNetworkInterfaces` shows it (true when an
interface that is on has its IPv6 enabled, false when none has or none shows an IPv6 section, nil when the camera has no ONVIF device
service or does not answer; throws a refused login). A camera with IPv6 on can take DNS servers from the router's advertisements or DHCPv6
beside the IPv4 ones (research §5). One read, nothing written; BridgeEngine's security check asks it of a camera whose DNS it read through
ONVIF, for the DNS help's warning, and the guard's own reads never do.

- **Dahua, Amcrest and Lorex** (vendor `.amcrest`, 2026-10-18; docs/integrations/amcrest-dahua.md; `Amcrest/AmcrestDNS.swift`): through
  the camera's own `configManager.cgi`, before ONVIF (their ONVIF `SetDNS` is known to be unreliable). `readDNS()` reads
  `getConfig&name=Network`: `table.Network.DefaultInterface` and that interface's `DnsServers[0]` and `[1]` (`method`
  `CameraConfigMethod.dahuaCGI`; the backup's `servers` the two slots as the camera had them, "0.0.0.0" included, and
  `CameraDNSBackup.dahuaInterface` the interface, init parameter, default nil); `applyDNS(server:)` sends `setConfig` with the bridge in
  both slots of that interface and no other key (IPv4 only; the slots can be changed on DHCP too), read back for up to 30 s; Restore writes
  the two slots back. An answer that is not Dahua's `table.` text (a login page, other HTML, a 404) leaves the camera to ONVIF. A write
  refused for any reason but the account's rights or the login, or answered "OK" while the read-back shows none of the bridge's servers,
  falls through to ONVIF for that run (rulings D3 and D4: no worse than before), and so does Restore; HTTP 403 is `notPermitted`, and a
  refused login is thrown (the login guard is ONVIF's, shared). The query's brackets go out encoded (`DnsServers%5B0%5D`), pinned by a test;
  not yet checked on a real camera. Internal: `AmcrestAPI.networkDNS(interface:)`, `setNetworkDNS(interface:servers:)`, `readDahuaDNS()`,
  `applyDahuaDNS`, `restoreDahuaDNS`.

- **The IP camera web API** (docs/integrations/ip-camera-web-api.md, 2026-10-18; `IPCWeb/IPCWebDNS.swift`): an ONVIF camera whose web API
  speaks (`ipcWeb()` `.speaks`) is read, set and restored through its own network settings before and instead of ONVIF, because its ONVIF
  reports DNS changes it does not keep (the owner's Jennov read `SetDNS` back as the bridge, then showed its original server again).
  `readDNS()` reads `getNetworkConfig`'s `LANConfig` (`DNS1`, `DNS2`, each once, an empty slot none; from DHCP unless `DHCP` is 0; on DHCP
  the slots as the page shows them are taken as the servers in use): `method` `.ipcWebAPI`, the backup's `servers` the two slots and its
  `ipcWebAPI` the three values as text. `applyDNS(server:)` writes `setNetworkLANConfig` with `LANConfig` as the camera wrote it and only
  `DNS1` and `DNS2` the bridge (IPv4), refused rather than written unless it holds every attribute the page writes (`MacAddress`, `DHCP`,
  `dhcpOffTime`, `ALLNET`, `IPAddress`, `Netmask`, `Gateway`, `DNS1`, `DNS2`, `hostname`, `MTU`), each once, with `IPAddress` the address
  Camera Bridge reaches the camera at (internal `ipcWebLANWrite(_:dns1:dns2:host:dhcp:)`); a camera on DHCP is refused, its mode switched
  only by the person's "Fix its address so the DNS stays" (below; the page sets DNS servers only in Mode Static: `ipcWebDHCPRefusal`,
  naming Network › Basic (TCP/IP), Mode Static, and the choice), and the preview says it is not supported without that choice. It is read back through the same call for up to 30 s (`DNSReadBackTiming`): a dropped connection or a timeout
  meanwhile, and a write the camera did not answer, are no refusal; a refusal pauses the web API (`IPCWebClient.isPaused`) and says so.
  `restoreDNS(_:)` writes the backup's `DNS1` and `DNS2` back the same way (nothing written when the camera has them; refused on a camera
  switched to DHCP since); a backup an earlier build saved through ONVIF goes back through this API too, one server in both slots, in Mode
  Static (internal `ipcWebDNS(restoring:)`), and through ONVIF on DHCP. ONVIF stays the way for a camera that does not speak the API or
  shows no `LANConfig`; a camera of the family whose web API cannot be asked now (paused, no answer, credentials it cannot take) is never
  read or written through ONVIF: `readDNS()` throws `IPCWebUnavailable` (the guard's reading is unreadable), and the step and Restore are
  refused with why. Only `LANConfig` of the answer is looked at (it also holds the camera's Wi-Fi, e-mail and FTP passwords), nothing of it
  is logged, and only `DHCP`, `DNS1` and `DNS2` are kept. Internal: `readIPCWebDNS()`, `applyIPCWebDNS`, `restoreIPCWebDNS`, `ipcWebLAN(_:)`,
  `ipcWebReading(_:)`, `ipcWebWatchRefusal(_:)`. Built from the camera's own page script; not yet run against a real camera.

Where ONVIF leaves a server that is not the bridge, or refuses, the IPCamera Web family's own API sets both of its slots, and a Reolink's
always does (2026-10-18). Its write restarts the camera's network service, so it is read back for up to 30 s (`DNSReadBackTiming`): no
answer, a 5xx or a lost session while waiting is not a refusal, and for the family ONVIF's `GetDNS`, when the camera shows it, must point
at the bridge too (the guard's own read; a Reolink's guard read is its `LocalLink`).
- **The IPCamera Web family** (docs/integrations/ipcamera-web.md), when its web API can be asked (`ipcamWeb()` `.speaks`): `get=eth`, then
  `set=eth` with the interface exactly as the camera's page writes it (`network.js`: `eth`'s ten attributes in the page's order with the
  values as read, then `<dns ondhcp='0' dns1='BRIDGE' dns2='BRIDGE' />`). An answer the page would write otherwise (another attribute or
  child, one missing, a value that is not an address, a number or a plain host name) is refused instead of written. When the API cannot
  be asked (a refused sign-in), ONVIF's words stand with why. Restore writes the backup's `dns` attributes back the same way whenever the
  API can be asked, else through ONVIF (also when the camera refuses Camera Bridge's sign-in at Restore time). The answer holds the
  camera's addresses and host name: it is never logged or kept. Internal: `ipcamWebDNS(_:)`, `ipcamEthWrite(_:dns:)`, `setIPCamWebDNS`,
  `restoreIPCamWebDNS`.
- **Reolink** (owner decision, 2026-10-18: Reolink refuses ONVIF's writes to its ONVIF user): read through `GetLocalLink` (`dns.auto` 1:
  from DHCP; the backup's `method` is `.reolinkAPI`), and set through `SetLocalLink` with the whole `LocalLink` as read and only `dns`
  changed (`auto` 0, `dns1` and `dns2` the bridge; IPv4 only), over the run's API session. With `auto` 1 its `dns1` and `dns2` are not the
  servers in use (the camera asks those DHCP hands out, and may keep the ones set by hand in the slots: the v8 guide's own example does): the
  reading's servers are ONVIF `GetDNS`'s `DNSFromDHCP` (a read, which Reolink's ONVIF user may make; internal `reolinkDHCPServers`), at
  the saved ONVIF port, else the one `GetNetPort` reports (`onvifPort`), else Reolink's default 8000, as the driver's events find it; no
  port is searched for, and nothing is asked when `GetNetPort` says ONVIF is off (internal `reolinkONVIFPort(saved:netPort:)`). When ONVIF
  does not say (off, no answer, a refused or paused login, no `GetDNS`, an answer not from DHCP), the reading says it does not know its
  servers (`CameraDNSReading.serversUnknown`, `servers` empty): it never points at the bridge, the step's preview still offers the change,
  and the Internet guard takes it as unreadable (BridgeEngine's README). ONVIF that says DHCP gives none is a reading of no servers. It is refused
  rather than written when that could change the camera's address (a `type` other than DHCP or Static, none, or a fixed address that is
  not the one Camera Bridge reaches it at), and not sent when `GetAbility` says the account may not change `localLink`
  (`CameraAdapterError.notPermittedReason`). Restore writes the backup's `dns` values back the same way; a backup an earlier build saved
  through ONVIF, without them (the owner's doorbell: from DHCP, no servers), is translated (internal `reolinkDNS(restoring:current:)`):
  `auto` 1 with the slots as they are, read back by `auto` alone, or `auto` 0 with its servers in the two slots. A Reolink without
  `LocalLink` goes through ONVIF. `LocalLink`'s address and MAC are never logged or kept. Built from Reolink's HTTP API v8 document
  (docs/integrations/reolink.md), not yet checked on a real camera.

The backup keeps the own API's DNS values (`ownAPI`: the family's `ondhcp`, `dns1`, `dns2`; Reolink's `auto`, `dns1`, `dns2`), read by
`readInternetWatch(server:)` before anything is written; a backup saved before 2026-10-18 has none and restores through ONVIF (a
Reolink's through `LocalLink`, above).
"Fix its address so the DNS stays" (2026-10-18, `ONVIF/CameraSettingsService+FixedAddress.swift`): the person's choice in the setup's
preview, off by default, for a camera whose DNS only stays with a fixed address (a Hikvision on DHCP, a camera that speaks the IP camera
web API on DHCP, an ONVIF camera on DHCP whose last run refused its DNS set by hand). `readInternetWatch(server:cameraAddress:refusedBefore:)`
offers it (`CameraSetupReading.fixAddress`: `CameraSetupFixAddress`, the camera's `CameraAddressing`, the change rows and the `method` it
is fixed through) only when the camera shows its whole address (an IPv4 address, a mask of contiguous bits, a gateway that is not 0.0.0.0
and is on that network; an ONVIF camera's lease as DHCP gave it), that address is `cameraAddress` and the bridge is on its network; never a
guess. An ONVIF camera on DHCP whose `SetDNS` did not stay is refused in words that say so (`fixedAddressNextTime`), only where the next
preview would offer the choice (`applyDNS(server:cameraAddress:)`, the engine passing the guard's address). A fix refused before or at its
first write changed nothing (`CameraSetupOutcome.addressUntouched`): only a definite refusal of that write counts (a SOAP fault, the
account's rights, an HTTP status that is not 2xx, a request Camera Bridge did not send: `refusedOutright`); a 2xx answer the client can't
read may be one the camera applied, so its address stays in the backup for Restore. `applyDNS(server:fixingAddress:)` reads the address again first and writes
nothing when it is not the one the preview showed (`addressChangedRefusal`); then ISAPI's address document with `addressingType` static
(the same `ipAddress`, `subnetMask`, `DefaultGateway`) and both DNS servers the bridge; `LANConfig` with `DHCP` 0 and `DNS1`, `DNS2` the
bridge; or ONVIF `SetNetworkInterfaces` (IPv4 on, `Manual` the address and prefix it has, `DHCP` false), `SetNetworkDefaultGateway` as it
was, then `SetDNS`, each read back (`CameraSetupOutcome.addressFixed`). "Reboot Required" and `RebootNeeded` make the step done waiting for
a restart, which only the person starts. The backup records the fixed address and the way it was fixed (`CameraDNSBackup.fixedAddress`,
never the hardware address, and `fixedAddressMethod`, which can differ from the way an earlier run read the DNS servers); `restoreDNS(_:)`
puts DHCP back that way with the DNS servers as they were while the camera still has that fixed address (`restoreFixedAddress`; ONVIF:
only the address and prefix `SetNetworkInterfaces` wrote are compared, the DNS first and DHCP last, also after a refused DNS part and
when a change waits for a restart; when the interface already shows DHCP and the DHCP-on write faults, Restore counts the DNS part alone as
done), and leaves one changed by hand since as it is. Internal: `ONVIFClient.setNetworkInterface(token:manual:dhcp:)` (its
body `setNetworkInterfaceBody`), `setDefaultGateway(_:)`, `defaultGateway()`, `networkInterfaces()` (now with `Info`'s `HwAddress`, for
the router reservation only: never logged or saved), `HikvisionISAPI.address(in:)`, `settingAddressing(_:dns:in:)`, `hardwareAddress(in:)`
(`/ISAPI/System/Network/interfaces/1`'s `MACAddress`), `ipcWebAddressing(in:)`, `fixIPCWebAddress`. Not yet run against a real camera.

The setup step "Watch its internet" (`CameraSetupStepID.internetWatch`, the last step; the engine offers it only where the bridge has
the guard: BridgeEngine's README): `CameraSettingsService.readInternetWatch(server:)` reads the DNS servers against the bridge's address for
the preview (the change row "DNS": "8.8.8.8 and 1.1.1.1", "1.1.1.1 and 8.8.8.8 from the router (DHCP)", "from the router (DHCP)" or "none
set" → "the bridge (192.168.77.2)"; already right when the camera asks that address and no other; not supported, "the camera does not show its
DNS servers", when `readDNS()` is nil; not supported with why for a camera that speaks the IP camera web API when that API cannot be asked
now, or when the camera is on DHCP there), and its value now is the backup (with the own API's DNS values), kept in
`CameraSetupBackup.internetWatch`; the step applies with `applyDNS(server:)` and restores with `restoreDNS(_:)`.

DNS safety (2026-10-24, docs/CONTRACT_CHANGES.md; `CameraSettingsService+AddressGuard.swift`): a DNS write never breaks a camera's address.
Two ANNKE I91ET (Hikvision OEM firmware V5.8.10) added as plain ONVIF on DHCP came up static at Hikvision's factory 192.168.1.64 after an
ONVIF `SetDNS` (that firmware turns the interface's DHCP off without saving an address). Before Watch's ONVIF `SetDNS`, `GetNetworkInterfaces`
is read: a Hikvision-family camera (vendor `.hikvision`; an ONVIF manufacturer of Hikvision, HiWatch, ANNKE or EZVIZ, a `DS-` model; or an
HTTP port that answers ISAPI's `deviceInfo` without a login with its document or a Hikvision Digest realm such as `IP Camera(…)`,
`CameraDrivers.answersISAPI`, no credentials sent) with IPv4 DHCP on, or that shows no interfaces, is sent no `SetDNS`: the preview says not
supported (`hikvisionONVIFRefusal`, no fixed address offered through ONVIF) and the engine's "Change it by hand" follows. After every ONVIF
DNS write the camera accepted (Watch's forms and Restore's), the interfaces are read again (at once, then while it restarts its network
service): one that had DHCP on and shows it off gets `SetNetworkInterfaces` with DHCP true at once, read back, and the step is refused in
plain words (`dhcpTurnedOff(back:atRestart:)`), logged as a warning; no other form or way is tried after it. A camera that shows no interfaces
again is refused (`dhcpUnconfirmed`). "Fix its address so the DNS stays" turns DHCP off on purpose with the address written: its interfaces
show DHCP off before its `SetDNS`, so nothing undoes it. Tests: `CameraDNSAddressGuardTests` (the mock ONVIF camera's `dnsTurnsDHCPOff` and
`deviceInformation`).

## Additions beyond the contract: SADP discovery (2026-10-24, docs/CONTRACT_CHANGES.md)

`SADPDiscovery.discover(timeout:)` (`Hikvision/SADPDiscovery.swift`, portable) sends Hikvision's SADP inquiry
(`<Probe><Uuid>…</Uuid><Types>inquiry</Types></Probe>`) to 239.255.255.250:37020 through `MulticastProbe` (WS-Discovery's socket, now with
`bindPort`: SADP binds the group's port, shared with `SO_REUSEADDR` / `SO_REUSEPORT`, as the devices answer to the group, which reaches the
bridge even from another subnet) and returns each device's `ProbeMatch` once per MAC as a `SADPDevice` (`mac`, `ipv4Address`, `subnetMask`,
`gateway`, `dhcp`, `activated`, `model` from `DeviceDescription`, `serialNumber` from `DeviceSN`, `httpPort`). `SADPDevice.isOnNetwork(of:)`
is the subnet check (an IPv4 address against networks with prefix lengths). No login is sent and nothing is written; the MAC and serial
number are never logged. `DiscoveredCamera` gains `activated`, `onAnotherNetwork` and `httpPort` (all optional; BridgeEngine's
`discoverCameras()` fills them). Internal: `SADPDiscovery.probeMessage(uuid:)`, `parseReply(_:)`, `merge(_:)`. Tests: `SADPDiscoveryTests`
(replies written from SADP's field list, made-up values).

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

- **Wyze cloud** (`Integrations/Wyze/`, 2026-10-15, spec `docs/superpowers/specs/2026-10-15-plugins-wyze-design.md`): `WyzeCloud` (an actor over an
  injected `WyzeTransport`; `URLSessionWyzeTransport` is `AuthenticatingHTTPClient`, 30 s, URL-free errors): `signIn` (`auth-prod.api.wyze.com/api/user/login`
  with the person's `Keyid`/`Apikey`, the password MD5-hashed three times by the portable `WyzeMD5`) → `WyzeSignIn.signedIn(WyzeSession)` or
  `.needsVerification(WyzeVerification)`; `sendCode` (`/user/login/sendSmsCode`, `/user/login/sendEmailCode`; nothing for an authenticator app) and
  `verify` (`/user/login` with `mfa_type`, `verification_id`, `verification_code`, as wyze-sdk and wyzeapy); `refresh` (`api.wyzecam.com/app/user/refresh_token`);
  `devices` (`app/v2/home_page/get_object_list`, cameras only, Gwell models kept and marked unsupported). `WyzeError` maps Wyze's codes (1000 + message,
  2001, 3044, HTTP 401/403/429) to sentences without any secret (tokens, keys, hash and session IDs are masked even when Wyze echoes them).
  The e-mailed code's endpoint follows the texted one's shape; no open-source client documents it, so it is unverified until tried on an account.
  `WyzeDevice` (`modelName` from `WyzeModels`, `connection`: `WyzeConnection` from `WyzeFirmware.hasRTSP` (v4 ≥ 4.52.17.0, v3 ≥ 4.36.16.5654, Pan v3 ≥
  4.50.16.5654, compared numerically) and DTLS/UID/`enr`), `Go2RTCSource.wyze(_:host:hd:)` (`wyze://HOST?dtls=true&enr=…&mac=…&model=…&subtype=hd|sd&uid=…`),
  `NeighborTable` (a MAC's IPv4 address from Linux `/proc/net/arp`). Tests: `WyzeCloudTests` (recorded answers through a fake transport).

Wyze helper programs (2026-10-15): `WyzeHelpers` (kinds `cloud` → `wyze-lake`, `gwell` → `wyze-gwell`; `Request`; `setProvider`, the plugin's fresh
credentials for every start; `kind(of:)`) and `WyzeHelperDriver`, which publishes into a go2rtc stream with no source (`Go2RTCSource.published`,
`isPublished`; written `'name': []`) and supervises the helper with restarts by exit code. `WyzeGwellAccess` and `WyzeCloud.gwellAccess(_:mac:)`:
Wyze's Mars registration for a Gwell camera (HMAC-MD5 signed). `CameraDrivers.make(…helpers:)` passes the helper launcher.

eufy (2026-10-15): `EufyBridge` (the `eufy-bridge` helper for the account: one process while the plugin is on, a loopback HTTP API with a
per-start token, camera events from its stderr lines; `EufyBridge.shared`, configured by the engine), `EufyBridgeCalling` (what the plugin needs;
tests fake it), `EufyModels` (model codes to names: T8134 is the SoloCam S220), `EufyDriver` (on demand: `CameraDriver.streamsOnDemand`; probe and
snapshots never wake the camera; motion and people from eufy's push notifications, held 30 s after the last), `Go2RTCSource.eufyBridge(port:token:serial:)`
(the helper's stream URL for go2rtc; its description never shows the token), `IntegrationService.eufy`, `IntegrationSettings.Key.eufySerial` /
`eufyModel`. `CameraDriver.streamsOnDemand` defaults to false.
The Wyze plugin's cameras carry `IntegrationSettings.Key.wyzeMAC`, `wyzeModel` and `wyzeWay` (`rtsp`, `local`, `cloud`, `gwell`).

Pan and tilt (2026-10-16): `PanTiltControl` (continuous `move(pan:tilt:)` in -1…1, `stop()`) and `CameraDriver.makePanTilt()` (default nil). The Wyze
Cam Pan v4 (`WyzeModels.pansAndTilts(_:)`) turns through `wyze-lake`'s loopback control server, one nudge per move.
`PanTiltControl.capabilities()` (`PanTiltCapabilities`: pan/tilt, zoom) and `zoom(_:)`; ONVIF cameras with a PTZ profile get `ONVIFPanTilt` (steps:
`ContinuousMove` for 0.4 s then `Stop`, never left turning).

IP camera web API (2026-10-16, `IPCWeb/`, notes: `docs/integrations/ip-camera-web-api.md`): the own web API of a family of OEM cameras (an
Anjvision platform sold under many brands, its sign-in page showing "IP Camera Web Login"), used next to ONVIF for what their ONVIF reports wrongly.
`IPCWebClient` (one long-lived HTTP client, 10 s; every call `POST /<name>` with `Content-Type` exactly `application/x-www-form-urlencoded`
and the envelope carrying the sign-in tokens; reads 200 with XML, writes 202), `IPCWebToken` (DES-ECB with the key "WebLogin" over the
zero-padded ISO-8859-1 text, in hex; nil for a character above U+00FF: such a camera of the family is `IPCWebUnavailable.credentials`) over the portable,
encryption-only `IPCWebDES` (FIPS 46-3), `IPCWebXML` (attributes read and replaced in the camera's own text, everything else kept),
`IPCWebDevice` (the probe: the camera's sign-in script first, `GET /jsCore/rpcLogin.js` without credentials, which must hold the token
key and the sign-in call
(`IPCWebClient.showsItsPage()`: the tokens can be turned back into the password, so no other camera gets them); then
`getSystemVersionInfo` and the feature flags of `getSystemControlString`), `IPCWebLatch` (per camera address: a non-2xx answer, a SOAP
fault or `passwordError` / `passwordLock` stops every request to it, said once in the log, until the camera's next start in the bridge:
the camera locks its account after a few wrong logins; it also remembers that the address showed the family's page). The client keeps
`ONVIFLoginGuard` with ONVIF (one account): nothing is sent while the camera's logins are paused, and `passwordError` / HTTP 401 / 403
pause them (`passwordLock`: the lockout pause). `IPCWebUnavailable` (`paused`, `noAnswer`, `credentials`): a camera of the family that cannot
be asked now. `IPCWebNoAnswer` (`IPCWebClient.probe()`): the sign-in script got no answer (a transport error, a timeout, a 5xx), nothing
kept; `device()` takes it as no web API (the setup), `NightVisionSelector` does not choose ONVIF on it (`unansweredTries` more tries once
ONVIF answers) and never for a camera of the family (`IPCWebNightVision.isOfTheFamily`). `IPCWebNightVision` (IrcutMode 0/1/2 auto, 3 manual with `setIRCutManual_DayNight`, 6/7 manual on/off; the IR lights through
`led_brightness_mode` / `led_brightness_value`; every write read back; one call at a time (`AsyncSerialLock`), since night vision and the
lights rewrite the same element; a day/night command that fails after the switch to manual puts the old mode back once), chosen by
`NightVisionSelector` in `ONVIFDriver.makeNightVision()` when the camera speaks the API, else `ONVIFNightVision`.
`NightVisionControl.currentLight()` (a requirement with a default nil: the lamp as the camera says). `CameraConfigMethod.ipcWebAPI` (only
for the clean picture, and since 2026-10-18 the DNS servers: "Internet guard, the camera's DNS"), `CameraFeatureBackup.cloudType` /
`cloudAuthcode` (never encoded: the engine keeps it in the secret store) and `CameraSettingsService.setFeature(_:enabled:path:saved:)`: on
an ONVIF camera that speaks the API (`CameraSettingsService.ipcWeb()`,
`IPCWebAccess`: `none`, `speaks`, `unavailable`), `readCleanPicture()`, `cleanPicture()` and `restorePicture(_:)` switch its overlay's
`Enable`, and `readFeature(.cloud)` / `setFeature(.cloud, …)` its `P2PConfig` (the switch, with the kind and sign-in value read and given
back; nothing else of the network settings, which hold the camera's other passwords, is kept or logged; its `LANConfig` is the DNS
step's). While the API of a camera of the family cannot be asked, these steps say why and never use ONVIF's on-screen display (nor its
DNS).

Battery (2026-10-16): `BatteryStatus` (`level` 0–100, `charging`, `source` `.solar` / `.cable` / nil; `BatteryStatus.lowLevel` 20,
`BatteryStatus.pollInterval` 5 min) and `CameraDriver.batteryStatus()` (default nil; must never wake the camera). `EufyDriver` answers from
`EufyBridge.battery(serial:)`: the helper's `GET /devices` (`battery`, `charging`, `chargingSource`: eufy's cloud, no wake-up), one list shared by
every eufy camera for 30 s.

## Additions beyond the contract: security readings and the IPCamera Web family (2026-10-17, docs/CONTRACT_CHANGES.md)

What a camera says about its ways out, for the security levels (BridgeEngine's `CameraSecurity`): `RemoteAccessFeature` (`cloud`, `upnp`,
`ddns`, `rtmp`, `unauthenticatedVideo`, `extraService`), `RemoteAccessState` (`on`, `off`, `absent`, `unknown`), `RemoteAccessFinding`
(`feature`, `state`, `linked`, `service`, `canChange`; `RemoteAccessFinding.cloudUnknown`) and `CameraSettingsService.readRemoteAccess()`
(read only; Hikvision: Hik-Connect, UPnP (absent only where `/ISAPI/System/Network/capabilities` says the camera has none; a document that
can't be read is unknown) and `/ISAPI/System/Network/DDNS`; Reolink: `GetP2p`, `GetUpnp`, `GetDdns` (only each `enable`), a refused command
unknown, the UID and UPnP `canChange` unless `GetAbility` says the account may not change them (2026-10-18); the IP camera
web API: `P2PConfig` and `UPNPConfig`, RTMP unknown (`getMediaStreamConfig` is not among the calls checked by hand, and a call the camera
lacks pauses its web API and night vision); the IPCamera Web family (an extra service on with `authorized` 0 is also video without a password,
named); any other camera: its cloud unknown; a cloud's online or signed-in status (`registerStatus`, `LoginStatus`) is never read as linked to
an account; a login refusal or a camera that stops answering ends the reading, the rest unknown, and a camera that stopped answering sets
`CameraSettingsService.remoteAccessUnanswered`; the cloud and UPnP come from the setup steps' own readings: internal `featureLookup`).
`RTSPAccessProbe.check(url:transport:timeout:)` (`RTSPAccessProbe.timeout` 5 s): one RTSP `DESCRIBE` without credentials, 200 with SDP on,
401/403 off, anything else unknown; credentials in the address's user info are dropped, an address with credentials in its path or query
(what `Redact.url` masks: XMEye `/user=admin&password=…`, `?pwd=…`) is unknown without connecting, and a challenge is never answered.

The IPCamera Web family (`IPCamWeb/`, notes: `docs/integrations/ipcamera-web.md`): `IPCamWebClient` (the page check first, `GET /` titled
"IPCamera Web" naming `js/script/land.js` and that script holding `auth.cgi?act=auth`, no credentials; the sign-in `GET /cgi/auth.cgi` with the
RC4 (`IPCamWebRC4`, key "pwnsd") of the UPPERCASE hex MD5 (`WyzeMD5`) of "username:password", as the page's `md5-min.js` has it; answered 0,
or 532379 (signed in, the password called insecure: logged once, `asksForStrongerPassword`), with an `authid` (without one
`IPCamWebUnavailable.noSession`, nothing latched); any other code a refusal, its code logged; an answer of the camera's (`<root>`) without
`<code>` is 0, as the page's `hXmlVal` reads it (`signInCode(in:)`; most likely how Patio New answered build 0.1.111's sign-in, which that build
could not read), at the sign-in and at every call; a sign-in answer that is not the camera's XML, or whose code is not a number,
`invalidResponse` (latched, not a refused password), and a call's answer that is not the camera's XML `invalidResponse`, not latched; the session reused, one new sign-in on 532227; 532374 "no privilege" said as such, and
at a write `CameraAdapterError.notPermitted` (a change the account may not make: the setup's other steps still run); each query
value encoded as the page's browser sends it, `=` `/` `?` `:` raw), `IPCamWebLatch` (a refused sign-in stops every request to the address,
keeping the camera's code: `refusal(_:)` is `IPCamWebUnavailable.noPrivilege` after 532374, which every step then names, typed as a change
the account may not make (`notPermitted`), else `.paused`;
the camera's next start (`cameraStarted`) tries again only with other credentials, kept as an in-memory SHA-256 from BridgeSupport's
`Hashes.sha256`, or 30 minutes after the refusal; ONVIF's logins are not paused by it, while a paused ONVIF login still stops the sign-in),
`IPCamWebNoAnswer`, `IPCamWebCameraError` (532229: no such option), `IPCamWebUnavailable`, `IPCamWebAccess` (`.unavailable` carries the
`IPCamWebUnavailable`; the setup signs in first, so a
refusal is each step's reason; a sign-in the camera does not answer, a 5xx or a transport failure, is that step's reason too, "the camera’s
web page did not answer Camera Bridge’s sign-in (HTTP 503)", so each step sends it once and the next one tries again), all internal.
"Set up for Camera Bridge" gains `CameraSetupStepID.videoPassword` and `.extraServices` (`CameraSetupReading.State.notOffered(_:)` and
`CameraSetupReading.notOffered(_:)` for other cameras: "not offered for this camera"), with `CameraSettingsService.readVideoPassword()` /
`requireVideoPassword()` (`rtsp` and `onvif` `authorized` 1; offered only with a saved password), `readExtraServices()` /
`turnOffExtraServices()` (`hik` and `meari` `on` 0) and `restoreServiceSwitches(_:)`, backed up in `CameraServiceSwitchesBackup`
(`CameraSetupBackup.videoPassword`, `CameraSetupBackup.extraServices`); its Cloud off is `mobile` `on` 0. The cloud and UPnP steps of a camera
Camera Bridge can't change say so and point to the router (`CameraNetworkFeature.cannotChange`).

## Additions beyond the contract: a maker's own interface (2026-10-23, docs/CONTRACT_CHANGES.md)

`CameraDrivers.ownInterface(endpoint:credentials:timeout:)` (`OwnInterface.swift`): `BridgeEngine.probeCamera` asks it for a camera added as ONVIF (chosen by hand or found by ONVIF), after ONVIF accepted the credentials or did not answer. ONVIF cannot read or turn off UPnP or the maker's cloud, so a camera that also answers its maker's interface is added as that vendor, with the interface's manufacturer (OEMs such as ANNKE keep their own name from ONVIF) and model: Hikvision ISAPI `deviceInfo` first (Digest; asked without a login first, and the credentials are sent only to a Digest challenge, once), then Reolink's and Dahua's (realm "Login to ...") unauthenticated signs. The three ask at once, each bounded by `timeout` (4 s). A refusal is `.rejected` and pauses the camera's logins (`ONVIFLoginGuard`): a wrong password costs one failed login. `CameraProbeResult.usedOwnInterface` (`CameraProbeResult` gains it, default false) tells the page to say so. Types: `OwnInterface`, `OwnInterfaceCheck`, `NotSetUp`.

`CameraDrivers.needsSetup(endpoint:timeout:)`: a Hikvision camera (and its OEMs) fresh from the box answers `GET /SDK/activateStatus` with `<Activated>false</Activated>` and no login; the Add Camera check then says to set it up on its web page. No login is made. Reolink's new camera accepts an empty password, which the web probe route refuses to keep. Dahua/Amcrest and app-only cameras (Tapo) are not detected: no cited, testable sign.
