# BridgeEngine

The engine the app talks to: configuration, credentials, per-camera runtimes, HAP servers, sensors bridge,
webhook, status aggregation. Depends on every portable module; platform access only through `BridgeEnvironment`
(`PlatformServices` + `MediaCodecs`). PlatformApple is imported only in `Environment.swift` under
`#if canImport(Darwin)` (for `live()` / `testing(directory:)`); AppKit stays in the app (`systemDidWake()`).
Owners: W2-3 (`Configuration/`, `Persistence/`, `Credentials/`, `Events/`, `Sensors/`, `Ports/`), W3-1 (`Runtime/`,
`Delegates/`, `BridgeEngine.swift`, `Environment.swift`, `LocalNetwork.swift`, `Power.swift`), W1-8
(`BridgeEngine+Preview.swift`). No stubs remain. `preview()` (W1-8) is `.running` but never started, has no runtimes,
and its operations do nothing.

## Part B (W3-1): runtime, delegates, facade

Data flow per camera (`Runtime/CameraRuntime.swift`, an actor):

```
IngestSupervisor(main) ─► MediaHub(main, 12 s) ─┬─► RecordingHandler/RecordingProducer ─► FMP4 ─► CameraController (HDS dataSend)
IngestSupervisor(sub, on demand) ─► MediaHub(sub)┼─► StreamingHandler/LiveStreamPipeline ─► LiveStreamSession (SRTP)
                                                 ├─► SnapshotProvider (camera API first)
                                                 └─► SoftMotionMonitor ─┐
CameraDriver.makeEventSource() ───────────────────────────────────────┴─► EventRouter ─► ControllerRegistry ─► CameraController
WebhookServer (engine) ───────────────────────────────────────────────────┘           └─► SensorsBridge.follow
```

- Ingest (`IngestSupervisor`): RTSP main stream always (configured URL, else Hikvision ISAPI 101/102 or Reolink
  `h264Preview_01_main|sub`, else the driver's probe — ONVIF — retried with backoff); the sub stream only while a live
  view below 1280 px wide uses it (stopped 10 s after the last user: the check and the stop happen on the runtime, and
  a user that arrives while it stops gets it started again) or while soft motion runs; Reolink switches to
  HTTP-FLV after 3 attempts without video (and back after 3 more; rejected credentials never count, as the fallback
  sends the same ones); the demo camera uses
  `MediaCodecs.makeSyntheticSource` (1920×1080@30, 2 s GOP, AAC 32 kHz; sub 640×360@15). Only video counts: the stream
  is `.online` from its first video frame, backoff 1 s → 60 s (reset by a stream that delivered video), watchdog 15 s
  without a video frame (audio alone keeps nothing alive). An offline stream stays `.offline` through its retries (no
  `.connecting` in between: StatusFault, StatusActive and the bridged sensors' reachability do not flip at every
  attempt). Rejected credentials retried after 10 min (reported as `.authenticationFailed`, origin `.stream`; the
  rejection is reset whenever the runtime stops, so a new password is not blamed while the camera is unreachable); the
  wait holds across `reconnect()` (wake, network change) and the sub stream's idle stop and restart, and the ONVIF
  stream-address probe waits and reports rejected credentials the same way (review W4 round 2: lockouts). A reconnect
  starts with the source that last delivered video (a Reolink with RTSP off stays on HTTP-FLV through wakes).
  `hub.discontinuity()` on every reconnect, source stops bounded by `Timing.sourceStopLimit` (`CameraRuntime.stopLimit`,
  3 s). The sub stream's supervisor reports to the runtime: an offline sub stream that should run is logged at warning
  level and shown as `CameraStatus.subStreamProblem`, which stays known (and shown) across its idle stop until it
  delivers a picture again (review W4 round 4).
  `stop()` always wins: a `reconnect()` still closing the old connection does not connect again, and `stop()` returns
  once every connection being closed is closed. Every sample feeds `StreamTraits` (B-frames: an H.264 B slice or
  dts ≠ pts, kept across reconnects until one connection delivered `bFrameClearGOPs` (3) whole GOPs without a reordered
  frame — B-frames turned off on the camera bring passthrough back without a restart; the longest of the last 8 GOPs).
  Reasons for `lastError` never contain URLs or credentials.
- Camera-tagged logs: a runtime gives every layer it builds a logger with the camera's ID (`LogEntry.cameraID`): its
  `AccessoryServer` ("hap"), `CameraController` with its stream managements and recording streams ("camera"),
  `DataStreamServer` and its connections ("HDS"), its RTSP / HTTP-FLV sessions (`RTSPConfiguration.cameraID`,
  "rtsp", "flv"), and its driver (`CameraDrivers.make(…cameraID:)`: event sources, camera API clients, RTSP probes,
  talkback sinks; W4 review round 4), so the app's per-camera log shows pairing, recording, stream, event channel,
  camera API and two-way audio lines (`Tests/BridgeEngineTests/RuntimeCameraLogTests`).
- Reentrancy (`CameraRuntime`): every start and stop bumps an epoch; `start`, `refresh`, the ONVIF probe task, ingest
  and soft-motion setup re-check it after each suspension and undo what they started once the runtime stopped (both
  supervisors are assigned before the first suspension so a concurrent `stop()` sees them); a late probe answer
  reports nothing. A wake or network change asks a camera still waiting for its stream addresses again at once (fresh
  backoff), unless it waits after rejected credentials or a probe is under way (review W4 round 3).
- Accessory: category 17 (18 for doorbells), `AccessoryOptions.accessoryInfo` (Home-safe name, vendor fallbacks,
  numeric firmware), `CameraController` with 2 stream services, Opus 16/24 kHz, Main 3.1–4.0, live resolutions from
  the source (4K/1440p only when that tall, 4:3 sizes for 4:3), HKSV 4 s prebuffer / 4 s fragments with recording
  resolutions 1280×720 + 1920×1080 (+ 1280×960, 1600×1200 for 4:3) **frozen per camera**: the aspect is stored in the HAP
  extras (`cameraBridge.recordingOptions`) as soon as a picture showed it (at this start or an earlier one); without a
  picture the 16:9 default is published unfrozen and frozen once a controller pairs (never changed under a pairing).
  The main stream's picture size is remembered (`cameraBridge.sourceSize`, also when it arrives after publishing), so
  live options follow the source at every start — only a camera without a remembered size waits (≤ 5 s) for a
  picture. `AccessoryServer` on the camera's `hapPort` (next free port on `.addressInUse`, persisted),
  `FileHAPStore` `hap/<uuid>/` + `hap.<uuid>`, `DataStreamServer` on the same transport; the runtime subscribes to the
  server's events before it starts it (a Bonjour registration refused by Local Network privacy during the start is
  reported too). An accessory that could not start leaves the camera offline ("the Apple Home accessory could not
  start (…)") and is tried again with the ingest's backoff, and at once on a wake or network change. Two-way audio is
  offered when the user enabled it and the driver has a talkback sink.
- Live (`StreamingHandler`, `LiveStreamPipeline`): `prepareStream` binds two UDP sockets (127.0.0.1/::1 when
  `loopbackOnly`, the requested family), random distinct SSRCs, echoes the SRTP keys, answers with an address of the
  requested family on the HAP connection's interface (`StreamAddress`, HAP-NodeJS `getLocalAddress`: the connection's
  own address when it has that family — not a link-local IPv6 one when the interface has an unscoped address — else the
  interface's first IPv4 address or IPv6 address without a scope; `getifaddrs`). The controller's SetupEndpoints
  address is where the stream goes only when one of the Mac's interface networks holds it (`getifaddrs` addresses and
  prefix lengths; loopback always; IPv6 link-local when an interface has a link-local address): an iPhone on a VPN
  (NordLynx 10.5.0.2) advertises the tunnel's address while its HAP connection arrives over the LAN, so otherwise the
  HAP connection's peer address (`PrepareStreamRequest.peerAddress`, same family, on one of our networks) is used, with
  one INFO line (`StreamAddress.controllerRoute`; both off-network: the advertised one, as before). The live trace's
  "destination" phase and `LiveStreamPipeline.advertisedHost` show advertised vs chosen; `LiveStreamSession` additionally
  latches onto the source of the first authenticated controller packet when it differs. The SetupEndpoints address is
  text without a scope: a link-local one (fe80::/10) gets the HAP connection's zone
  (`PrepareStreamRequest.connectionZone`, else the interface of our address; `StreamAddress.controllerHost`), or every
  packet would fail with EHOSTUNREACH from the wildcard sockets (review W4 round 4). `.start`: sub stream for requests
  < 1280 px wide or remote ones (audio packet time ≥ 60 ms, integration brief §5.4) when it delivers a picture within
  3 s (at once the main stream while the sub stream is known to be down — offline while it runs, or when it last ran,
  then tried again in the background — and as soon as it goes offline while the view waits; a live view on a sub stream that stays offline for
  `subStreamStartWait` while the main stream delivers is ended through `stopStreamingSession`, so the controller starts
  it again on the main stream instead of showing a frozen picture); a `.stop` (or a cancellation: RTPStreamManagement
  abandons a start that misses its deadline) while the start waits for the hub wins and the start undoes itself. The
  hub's last keyframe is sent first — once the controller's first packet (its RTCP) arrived, at most 1 s later
  (`Context.controllerWait`, `LiveStreamSession.waitForController`) — then a `.nextKeyframe` subscription. That first
  keyframe is stamped as captured when it is sent: it moves forward by its age, at most a GOP, so RTP time keeps pace
  with arrival from the first frame (receivers anchor playout on it; W3-2 regression). The age is measured from its
  arrival on the hub's monotonic clock (`MediaHub.lastKeyframeArrival`), never from its `wallClock`, which for RTSP is
  the camera's clock (review W4 round 2). Passthrough when `MediaFit.live` accepts the H.264 source
  (≤ requested size +2 %, declared level ≤ requested or actual frame size/macroblock rate at the requested frame rate
  within it — no level check for a requested size its level cannot carry, 1440p and 4K, where a transcoder would raise
  the level too — ≤ requested fps +10 %, Baseline/Main/High, no B-frames per the hub's `StreamTraits`), else
  `VideoTranscoding` (requested size/fps/bit rate, Main, keyframe every 2 s; the requested frame rate limits the
  output, the hub's measured rate is only the encoder's expected rate, rounded up); the path is chosen again at a source
  keyframe whose format (codec, size, profile, level) changed (a camera that reconnected with other settings); camera
  audio → Opus at the requested rate, joined to the requested packet time by `OpusRepacketizer` (code-3 packets; 30 ms
  → 20 ms); packets ≤ min(1200, MTU); RTCP at the requested interval. PLI → `requestKeyframe()` (passthrough: no-op).
  `.reconfigure`: bit rate at once (also when the size changes too), a new size chooses the path again at the next
  source keyframe (also one that comes while a path decision builds its transcoder: that transcoder gets the new bit
  rate, and the next keyframe decides again). Return audio → one
  `TalkbackBridge` per camera, shared by its sessions (cameras have one talkback channel; NVR cameras sharing a
  Hikvision two-way channel share its session in CameraAdapters' `HikvisionTwoWaySession`): the talking session holds the
  sink, other sessions' return audio is dropped until it ends or stays silent for 1 s; the sink is opened on the first
  packet (single-flight, on its own task: packets during the open are dropped — the opener's too, which queued up behind
  it and reached the camera in one late burst before review W4 round 4 — and the holder stays, so a slow camera never
  gets a second open on its one channel) and closed when the last session that used it ends; failures retried after 5 s; a close
  waits at most 3 s (`CameraRuntime.stopLimit`), and a stopping session lets the hub and the transcoder go first. The
  return-audio task is never cancelled (it ends with the session's return audio): the camera-facing open runs apart from
  its caller's cancellation (a sink nobody wants once it opened is closed), and a cancelled caller sends nothing to the
  shared sink. A session that ends by itself (30 s without controller RTCP, source gone) is ended through
  `stopStreamingSession`. `TimelineRebaser` keeps one timeline across ingest reconnects (frames compared by decode time
  when present; without one a non-keyframe up to 1 s behind is reordering and passes unchanged, a keyframe that does not
  move forward or a larger step back is a new timeline); live frames carry their arrival, so at a new timeline (or a step
  over 10 s) the next frame follows the last by the time between their arrivals and RTP time keeps pace with
  wall-clock and RTCP sender-report time; recordings close the gap to one frame interval.
- Live start, replacing "the hub's last keyframe, then the next one" above (field report: Home sat loading for minutes): the
  pipeline subscribes with `.prebuffer(.zero)`, so the newest GOP (a keyframe and what followed) is replayed and the stream
  goes on live from there. A camera with a long GOP (smart codecs: up to a minute) used to give the controller one stale
  frame and then nothing until its next keyframe; the controller gave up after about 30 s and retried at another random
  point of the GOP. Transcoding: `VideoTranscoding.catchUp` decodes the whole replay and encodes ONE keyframe of the newest
  picture (no wait for the controller's first packet; once it is heard — or silent for 2 s / 5 s — a fresh keyframe is
  requested, and silence is logged as a warning). Passthrough: the replay goes out compressed in time (`compressedReplay`,
  1/120 s apart, so the receiver is not held back by the GOP's age) when it is at most 400 kB / 90 frames, else the path is
  a transcode ("the camera's current keyframe interval is long"). Each session records its phases (`SessionTrace`: prepare,
  start, path decided, encoder ready, first video packet, keyframe sent, first RTCP received, end reason) in the
  `DiagnosticsCenter`, and logs them as `live stream trace` lines; `LiveStreamSession.timeline` has the instants.
  `RTPStreamManagement.forceStop` frees the stream service at once when the accessory ends a session, and a controller's end for
  a session that is gone is a no-op (it used to log "end for an unknown stream session" and answer an error).
- Live view never fails silently (HomeKit live-view hardening, audit 2 F1-F9; `LiveStreamHealth.swift`, `LiveStreamPipeline`).
  Every failure is detected, logged in one plain line (`Live stream [session]: ...`) and either heals or ends the stream, which
  goes through `LiveStreamSession.end(reason: .pipelineFailed(...))` so the log and the status say why, and `StreamingHandler` ends the
  HomeKit session and Home retries (`CameraStatus.liveSessions` carries each stream's `health` and, once the pipeline gave up, its
  `endReason`). Transcoder: never
  replaced by a passthrough that would not fit (HEVC, a timestamp overlay, a straightened picture, a profile/level over the request; only a transcode
  chosen for a long GOP falls back to the camera's own stream when the transcoder cannot be made); creation is retried after
  0.5 / 1 / 2 s, then the stream ends; a failing transcoder drops the frame, then is rebuilt (software decoder after a keyframe
  failure; at most every 0.5 s), and 3 s of failures without a frame ends the stream; creation, teardown and each transcode call
  run off the cooperative threads under deadlines (2 s a frame, 10 s a catch-up) and a wedged transcoder is abandoned and
  rebuilt (`stop()` never waits for one). Health (`LiveStreamHealth`, 1 Hz, `LiveStreamTiming`, all injectable): no video
  packet for 4 s while the camera delivers forces a keyframe and rebuilds the transcoder from the hub's newest GOP, once per 4 s
  at most 3 times; the pipeline's own end is a later backstop to the session's hard limits (12 s at the start, 10 s mid-session);
  a transcoding stream without a keyframe for 6 s gets one forced (end at 10 s). Self-check (`LiveSelfCheck`): the first three
  keyframes and then one GOP a minute are packetized as the session does, reassembled and decoded by a separate low-priority
  decoder (one probe at a time in the process, 5 s deadline, never affecting the stream when it cannot run): a keyframe that
  does not decode twice in a row, a picture of another size than the SPS or the request, a profile above the selected one,
  broken packetization, or a blank/all-zero (green) picture while the camera's is real ends the stream. A new picture size
  rebuilds from the hub's newest GOP at once (no wait for the camera's keyframe); a passthrough stream switches to transcoding
  when the controller asks for a keyframe twice in 10 s; a camera GOP over 60 frames or 2 s asks the camera for a keyframe
  (`Context.cameraKeyframe`, `LiveStreamPipeline.cameraKeyframeRequest(driver:isOffline:log:)` → `CameraDriver.requestKeyframe`:
  Hikvision ISAPI `requestKeyFrame`, ONVIF `SetSynchronizationPoint`; once per need, never retried, spaced 10 s per camera, held
  by `ONVIFLoginGuard` and `CameraHTTPGates`). The pipeline's output to the session and the app viewer's pump are `GOPQueue`s
  (an overflow drops a GOP and asks for a keyframe). `CameraRuntime` wires both seams into `LiveStreamPipeline.Context`: the camera
  keyframe request goes through the driver (and so its guards; nothing is sent while the camera is offline), and
  `subStreamSize` is the sub stream's picture size once its hub has seen one (kept across the sub stream's idle stops); with it
  `MediaFit.prefersSubStream(... subStreamSize:)` reads a request the sub stream's picture covers from the sub stream.
  `EngineTuning.liveStreamTiming` (default `.standard`) holds the pipeline's timings. Snapshots decode forward from the newest keyframe through the frames after it
  (a decoder session continues a GOP instead of starting it again), concurrent requests share one camera fetch and one decode,
  events wait 3 s and other requests 4 s before the last picture (up to 5 minutes old) stands in, and an offline camera's picture
  older than 5 minutes is not served. A recording stream holds at most 8 packets for a consumer that stopped reading and ends.
- Diagnostics: `DiagnosticsCenter.install(directory:)` (the app does) registers a `DiagnosticsLog` (every entry at debug level,
  redacted, 20 000 in memory + 5 × 2 MB rotating files) and turns `LogHub.minimumLevel` to debug; the Log Level setting then only
  limits `recentLogs`. `BridgeEngine.diagnosticsReport(context:)` renders the text bundle (`DiagnosticsReport`).
- Camera events that keep dropping: after 5 short sessions in a row an event source emits `.eventChannelUnreliable`; the runtime
  starts built-in motion detection for that camera and `CameraStatus.eventsNote` says so until the runtime stops.
- Snapshots (`SnapshotProvider`): camera API (skipped for 30 s after a failure, for `unauthorizedRetry` — 10 min, the
  ingest's wait — after rejected credentials: every request is a login, review W4 round 4; never again after "unsupported"),
  resized to the request; else the last (or next) keyframe → JPEG. Periodic/reason-less requests use a 4 s cache of the
  same size, event requests never; 8 s budget (BridgeSupport's `withDeadline` returns on time even if a camera ignores cancellation).
  A failed camera API is logged without its URL (BridgeSupport's `URLFreeErrors.describe`; CameraAdapters'
  `CameraHTTP.sanitized` already strips URLs from transport errors: a Reolink token or an ONVIF snapshot URI's password).
- Recording (`RecordingHandler`, `RecordingProducer`): `.prebuffer(prebufferLength)` subscription → passthrough when
  `MediaFit.recording` accepts the source (as live, plus profile ≤ selected and GOP ≤ fragment + min(5 %, 50 ms) — the
  fragmenter's jitter allowance, since a passthrough fragment is at least one GOP — where the GOP is the longer of the
  hub's mean and `StreamTraits.longestGOP`; not measured yet, the age of the GOP still open is its lower bound; a
  passed-through GOP that outgrows the fragment — or, on either path, video that comes back after a gap (a lost IDR, a
  stall, a keyframe the decoder rejected) that would stretch the open fragment past its length — ends the stream with
  what fits as the last fragment, so the hub's next stream decides again: no fragment is longer than fragmentLength
  plus the allowance, review W4 round 4),
  else `VideoTranscoding` (selected size/profile/level/bit rate/frame rate as the output's limit, the measured rate only
  as the expected one; I-frame interval ≤ fragment; a frame it fails on — a rejected keyframe — is dropped and the
  recording goes on from the next keyframe, a second failure in a row gets a new transcoder, a third ends the stream;
  the replay, which starts at a source keyframe up to a GOP before the requested prebuffer — 10 s and more for long-GOP
  cameras — is decoded but recorded only from the requested prebuffer on, where a keyframe is forced (not for B-frame sources): review W4 round 4)
  → `GOPFragmenter.pushGroups`
  → `FMP4Muxer.fragment(_:)` (exact tfdt continuity). Audio only while RecordingAudioActive (decided per stream):
  camera AAC-LC at the selected rate/channels as is, other camera audio transcoded, silent AAC (contiguous, covering
  each fragment's video) when the camera has none or its audio is disabled. Init first; fragments ≤ 1 per 250 ms
  (prebuffer pacing); after 3 min the next fragment is `isLast` (of two closed by one keyframe, the second; this is the
  one cap: HAPCamera sends both and only backstops a stream still running one fragment + 5 s later); the end
  of the subscription flushes the open group (`flushGroups()`: split in two when one would run past the fragment
  length) as the last fragment(s), and so does a passthrough keyframe the initialization segment cannot describe (new parameter
  sets after a reconnect: the hub's next stream starts over); camera audio that comes back in another format (any
  codec, transcoded or passed through) gets its own converter to the track's format (else dropped; a frame that cannot
  be converted is dropped); close/ack/cancel stop at once; one producer per camera (a new stream cancels a lingering one);
  no selected configuration → `invalidConfiguration`; errors → `unexpectedFailure`. Every fragment's
  `lastFragmentStatistics` is logged at debug level.
- Events: the driver's event source (camera motion ignored unless `motionSource == .cameraEvents`; stopped with
  `resetOrigin(.camera)`), `SoftMotionMonitor` for `.softMotion` (decodes the sub stream, else the main one, ~4
  analyses/s at 320 px; while the sub stream has had no picture for `softMotionSubStreamWait` (10 s: a wrong path,
  a 404, rejected credentials, an unsupported codec) it decodes the main stream, and the sub stream again once it
  delivers; a picture stalled 5 s while motion is on resets `.softMotion`; `stop()` waits for the analysis
  task, so no transition lands after its reset; a sensitivity change restarts only the monitor; the detector runs on the
  monotonic clock, so a wall clock stepped back never holds motion on, review W4 round 4), the engine's webhook. Router
  outputs reach controllers through `ControllerRegistry`: `.motion` → `setMotionDetected`, `.doorbell` → `ringDoorbell`
  (the router adds the motion pulse), `.state` → `setSensorStatus` and `setStreamingAvailable(online)`. A starting
  runtime registers its controller and applies the camera's current state in one step on the router
  (`EventRouter.withCurrentState`), so no output falls between the two.
- Facade (`BridgeEngine`): loads `config.json` in `init` when readable (so settings and cameras show before `start`);
  `start()` = load (or `.failed`) → `resolvePorts` → register cameras → status loop → sensors bridge (`bind` from its
  port; a moved port is persisted; it subscribes to the router's outputs before it applies the current states; only while at least one camera is configured — the first `addCamera` starts it,
  removing the last stops it and clears `sensorsBridge`, so a fresh install publishes nothing on the LAN) → webhook (when enabled) → runtimes (concurrently) → network-change monitoring →
  `.running` ("Bridge running with N cameras"). `recentLogs` follows the log sink from the first start until `stop()`
  (its own loop, at the status rate): also while paused or after a failed start, when the status loop does not run —
  the app's messages then point to the log (review W4 round 4). Lifecycle and configuration operations run one at a time
  (BridgeSupport's `AsyncSerialLock`, on the main actor); Keychain and `config.json` I/O runs off the main actor (`offMain`; an unreadable stored identity
  is cached, not re-read at every status tick). `updateCamera` restarts the runtime unless only the sensors, the
  motion hold, soft motion's sensitivity (applied to the running monitor) or — for a paired camera, whose name Home
  keeps — the name changed. `removeCamera` saves first: when the configuration cannot be saved the camera stays, with
  its password and HomeKit identity. `updateSettings` starts a webhook that was turned on, moved or given a new token
  before it saves: when it cannot listen the old one comes back and `EngineError.invalidSettings` says why; paused or
  stopped, the port is bound once and let go, and refused the same way. A webhook that cannot listen at start or
  resume (another app took the port), or whose listener the platform stopped and that cannot listen again
  (`WebhookServer.listenerStates`; cleared once it listens again), is published as `webhookProblem` (Settings shows it
  with Try Again: `retryWebhook()`, which also replaces a webhook still trying to listen again); a port in use is
  retried for 1 s first (a listener closed just before lets it go asynchronously). The webhook asks the router about
  each event's camera (`EventRouter.webhookCameraState`, the rule `handle` drops events by): 404 for an ID no configured
  camera has, 409 for a disabled camera, 204 only for events the router takes (W4 CameraAdapters review, round 3). A
  damaged `config.json` set aside at load is published as `configurationRecoveredFrom` until
  `acknowledgeConfigurationRecovery()` (the app's banner and menu bar), also across launches: `loadOrRecover()` saves
  the backup's name as `config.recovered` next to `config.json`, `init` reads it, and the acknowledgement removes it
  (the configuration saved after a recovery loads normally, so without it a relaunch forgot the notice).
  `updateSettings(_ change:)` applies a change to the settings as they are when its turn in the queue comes (the app's
  settings controls: two changes made while the engine is busy both stick; an unchanged result saves nothing). State
  strings the app shows as they are — `.failed`'s reason (`startFailure`), a camera whose accessory could not start,
  `webhookProblem`, a stream's offline reason and `subStreamProblem` — word errors with `readableReason` (public: the
  app's alerts make sentences of it, so every network, stream, camera API and storage error is worded once;
  `IngestSupervisor.describe` words only the stream's own failures): never Swift case names, NSError dumps or the
  platform's text (`TransportError.failed`'s POSIX and URLError codes); the raw error goes to the log. `pause()` stops bridging (servers closed), `resume()` starts again, `stop()` also removes the log
  sink. Status: rebuilt on change (and every 2 s), at most every `statusInterval` (250 ms); a refresh that read before
  an operation changed the cameras, runtimes, sensors bridge or state publishes nothing (the operation refreshes
  again: no removed camera's row or stopped bridge's code comes back). Cameras without a runtime show the setup code
  from their HAP store: one that will not run (disabled, bridge paused or stopped) gets its identity created on first
  use with `HAPStore.loadOrCreateIdentity()`, which removes the pairings of a lost identity (the engine then logs that
  the camera must be removed from Home and added again); one that runs or is about to only reads it (its accessory
  server creates it), and a camera removed meanwhile gets none (its secrets are deleted under the same lock). Identity
  creation is atomic per Keychain account across every store (`HAPStore.identityLockName`): the engine and a starting
  accessory server never both create one. `resetPairing(cameraID:)` / `resetSensorsBridgePairing()` give a new identity
  (`HAPStore.replaceIdentity()`: device ID, key, setup code, setup ID; no pairings), so the old setup code pairs nothing
  afterwards; a running accessory restarts with it.
  `PowerController`: background
  activity on start (`endBackgroundActivity` on pause/stop), keep-awake while running with `keepMacAwake`
  (`updateSettings` toggles it), released on pause/stop. `systemDidWake()` / network changes (debounced together on
  the trailing edge: once 2 s, `networkSettle`, passed without another wake or change, so a burst — a wake and the
  path update of the Wi-Fi rejoin it brings included, in either order — reconnects once; review W4 round 4): ingest
  reconnect, event channel restart, re-advertising, accessories that could not start tried again — run through the same
  operation queue, so they never overlap a pause, stop or camera change. Neither
  logs in again after rejected credentials before their wait is over: the ingest keeps it, and an event channel whose
  login the camera rejected (`EventRouter.credentialsRejected(by: .camera, …)`) keeps its source, which waits
  `delayAfterUnauthorized`. Local Network: `checkLocalNetworkAccess(host:)` connects to the host's RTSP port (port 80 for a host that is
  not a camera, e.g. the router; refused counts as granted, timeouts as unknown). Until an answer is known
  (`localNetworkAccess == .unknown`) the system's Local Network alert may be on screen, and connections are blocked
  until the person answers it (TN3179): a denial is retried every `EngineTuning.localNetworkRetryInterval` (500 ms) for
  up to `localNetworkAnswerWait` (20 s) before it counts, and `localNetworkAccess` does not change meanwhile; once an
  answer is known one attempt decides. Runtimes report denied connections, refused advertising and LAN connections.
  `discoverCameras()` returns nothing in loopback-only environments (tests never multicast). Since 2026-10-24 it runs ONVIF's
  WS-Discovery and Hikvision's SADP at once (`SADPDiscovery`) and merges them (`mergedDiscovery`): a SADP device at an address WS-Discovery
  listed adds `activated` and `httpPort` to that entry; another is listed after them, `onAnotherNetwork` when its address is on none of the
  bridge's IPv4 networks (loopback and tunnels left out; `SADPDevice.isOnNetwork(of:)`). Tests: `CameraDiscoveryMergeTests`.
- Probing (`probeCamera`, app review W4): `vendor` nil → `CameraDrivers.detect`; the ONVIF device service's port is
  kept when it isn't the HTTP port (detected, or searched with `CameraDrivers.onvifPort` for an `.onvif` camera without
  `onvifPort`), used for the driver and reported as `CameraProbeResult.onvifPort`. Nothing detected and no main stream
  URL → `EngineError.noCameraAPI(host:)`. When the camera may not have been reached (no answer, transport or URL
  errors, RTSP timeout — not a camera that answered with 401/HTTP/RTSP errors), Local Network access is checked against
  the camera (HTTP port, RTSP for plain RTSP), waiting up to `EngineTuning.localNetworkAnswerWait` (20 s) for the system
  alert's answer while none is known: denied → `TransportError.localNetworkDenied` (and `localNetworkAccess` follows);
  allowed just now → the probe runs once more. `probeCamera(_:password:)` probes a configured camera as described
  (vendor, endpoint, stream URLs, user name) with its stored password when `password` is nil; it saves nothing. Every
  probe closes the driver it built (`CameraDriver.close()`, in the background: a Reolink check logs its API session
  out instead of holding one of the camera's few sessions for an hour; W4 review round 4).

### Additions beyond the contract (Part B)

**Motion shadow test (2026-10-04).** `BridgeSettings.motionShadowTest` (default off, saved in `config.json`; a missing or unreadable value reads
as off) measures the built-in motion detection against a camera's own events without changing what reaches HomeKit. For each camera whose
`motionSource` is `.cameraEvents` the runtime starts a second `SoftMotionMonitor` made with `init(…shadow:…)` on the SUB stream (it holds one user
of the sub stream while it runs; a camera with no sub stream is skipped and logged once: the main stream is never decoded for the test). That
monitor holds no `EventRouter`: its transitions go to the camera's `MotionShadowTest` recorder and nowhere else, so they can never move
HomeKit motion or start a recording. The camera's own motion events (origin `.camera`) are copied to the same recorder from the event task. The
test steps aside while built-in detection is the camera's motion (events unreliable) and while a camera is stopped, and starts again with the
runtime; `BridgeEngine.updateSettings` starts and stops it on running cameras, and a sensitivity change restarts only the shadow monitor.
`MotionShadowComparator` (a pure value, times as durations on one clock) groups the periods of both sources into events: a period that starts
while an event is open, or within `pairingSlack` (2 s) of its end, joins it; an event ends when both sources have been quiet for the slack (or
after `maximumEventLength`, 30 min, for a source that never reports its end). Each event is **both** (with the start delay: built-in start minus
camera start), **camera only** (built-in missed it) or **built-in only** (an extra trigger). Memory is bounded: one open event kept as a few
numbers, finished events for the last 24 h and at most 2,000, the newest 1,000 delays for the median since enabled, and plain counters. Logging
(category "Events", the camera's log): one INFO line per finished event, e.g. `Motion shadow test: Patio: both detected; built-in 0.8 s later`
(`… camera only; built-in missed it`, `… built-in only; the camera reported nothing`), and every hour `Motion shadow test: Patio, last 24 h: 5 both,
1 camera only, 2 built-in only; median delay 0.9 s later`. Public surface: `BridgeSettings.motionShadowTest`; `CameraStatus.motionShadow`
(`MotionShadowStatus`: `state` `.comparing` / `.paused(reason)`, `sensitivity`, `enabledSince`, `last24Hours` and `sinceEnabled` as
`MotionShadowTotals` (`both`, `cameraOnly`, `builtInOnly`, `medianDelaySeconds`, `events`), `eventInProgress`; nil when the test is off or does not
apply); `RuntimeStatus.motionShadow` carries it from the runtime. The diagnostics report lists the setting and each camera's numbers. Tests:
`MotionShadowComparatorTests`, `MotionShadowRecorderTests`, `RuntimeMotionShadowTests`.

**Network change, wake and recovery (2026-10-03, hardening plan WS-C).** A reconnect (`systemDidWake()` / a network change, debounced
`EngineTuning.networkSettle` after the last, at most `networkSettleCap` (15 s) after the first of a burst that keeps flapping) refreshes
each camera in this order: the accessory (`AccessoryServer.relistenNow()`, then the Bonjour record registered again, cameras
`advertisingStagger` apart), then the main and sub streams (a stream that delivered video within `healthyIngestWindow` (2 s) is left
connected after a network change; a wake always reconnects), then the event channel. Each camera's refresh has
`runtimeRefreshDeadline` (20 s): one that hangs is logged and left behind, the engine's operations and the other cameras go on
(`IngestSupervisor.close()` waits for a closing connection at most `sourceStopLimit` + `closeGrace`). `systemWillSleep()` (the app
forwards `NSWorkspace.willSleepNotification`) logs the sleep and times it; the wake logs "The Mac woke up after …", closes the HAP
connections that were silent since before the sleep (a sleep of under 30 s leaves them alone) and ends live views that were prepared
and never started. `CameraRuntime.refresh` clears the live transport's per-controller sending strategies (`StreamingHandler.networkChanged()`). A heartbeat every `runtimeHeartbeatInterval` (10 s) asks each runtime (and its accessory server) to answer within
`runtimeHeartbeatDeadline` (3 s); three misses in a row restart that camera only. Each running accessory has a `HAPHealthMonitor`
(`EngineTuning.accessoryHealth`); `CameraStatus.homeKitNote` carries its "Home hasn't contacted this camera for N min". A failed
accessory start (a refused Keychain, a listener failure) no longer stops the camera's runtime: the stream, events and the app's
viewers keep running (`CameraRuntime.AccessoryStartFailure`), only the accessory is tried again with backoff (and at once on a wake or
network change), and the stream's own state is reported again once it is up. A new installation on a Mac without a battery
(`PowerManaging.hasBattery`) starts with Keep Mac Awake on; a saved configuration is never touched, a laptop's stays off with a
log line saying what that means. `PlatformServices.instanceLock` (`AppleInstanceLock` in the app): a second copy on the same data
directory fails its start with "CameraBridge is already running with this configuration" (a Debug build under another bundle ID has
its own container and its own lock). `PlatformServices.browser` (`NullServiceBrowser` by default) is the health monitor's Bonjour
check.

**HomeKit allowlist (2026-10-02).** `BridgeEngine.homeKitAllowlist` (`Set<UUID>?`, nil = every camera) and
`setHomeKitAllowlist(_:because:)` (the cause goes into the log line of every change) limit which cameras are published to HomeKit, for a host that wants to keep some cameras out of Home (the app does not: it publishes every camera).
tier). It is a generic setting, not persisted and not tied to any store: the host sets it before `start()` (a host that never does
publishes everything, as `cbctl` does) and whenever its rule changes. A camera outside the set still gets a runtime (ingest, events,
snapshots, `liveVideo`), but no accessory (`CameraRuntime.start(publishing:)`): nothing is advertised, Home shows it as not
responding, and its sensors are not on the sensors bridge. Moving a running camera in or out of the set calls
`CameraRuntime.publish` / `unpublish`, which take only the HAP accessory (server, data stream, live views, recordings) down or up, so
the connection to the camera and the app's viewers are not touched, and the identity and pairings in the camera's HAP store are the
ones the accessory comes back with (same device ID, setup code and pairing: `HomeKitAllowlistTests`). A camera added while the set
does not name it starts unpublished. The status of a held-back camera reports its stored setup code and pairing (`hapPort` is nil).

**VPN notices (2026-10-02).** `BridgeEngine.recentNetworkNotices` (`[NetworkNotice]`) and `BridgeEngine.macVPN` (`MacVPNStatus?`) tell the
app what the network does to Apple Home devices that watch live video. `NetworkNotice.Kind.controllerOnVPN`: a controller advertised an
RTP address that is on none of this Mac's networks and looks like a tunnel's (`StreamAddress.looksLikeTunnelAddress`); the notice names the
camera, the advertised and the HAP peer address, whether the stream was sent to the peer instead (`usedFallback`) and, once known,
whether the controller answered (`delivery`: `.pending`, then `.reached` after its first RTCP or `.failed` after
`StreamingHandler`'s 8 s of silence). One notice per device (`NetworkNotice.id`), kept for an hour after it was last seen.
`.macOnVPN`: `MacVPNDetector` found an addressed tunnel interface (`utun`, `ipsec`, `wg`, …) that carries the IPv4 default route (or both
halves 0/1 and 128/1) or has a NordLynx-style 10.5.0.0/16 address; the status loop looks every 30 s and at every network change. The route
table is read with `sysctl(NET_RT_DUMP)` in `StreamAddress.routeDump()`. `DiagnosticsReport.render` has a "Network" section;
`PreviewScenario` has `.vpn`, `.vpnFailed` and `.macVPN`. RTP: `LiveStreamSession.hasEnded`.

**Live-view transport (2026-10-03).** `StreamingHandler` ties each session's sockets to the network through a per-controller
`SendStrategy`: bound to the accessory address and scoped to its interface (`IP_BOUND_IF`), else bound only, else the wildcard. A session that
ends `.controllerNotReceiving` (the controller's RTCP kept coming but its receiver reports showed no video arriving; `RTP`'s
`ControllerReceptionMonitor`) moves that controller one step down for its next session; the choice is kept an hour and `networkChanged()`
(for the runtime's network-change path) forgets it. `The Home app on this Mac (an IPv4 controller that is one of this Mac's own non-tunnel addresses, its HAP connection over another address of the Mac, e.g. a VM's `bridge100`) is answered its own address (`StreamAddress.localControllerAddress`): a packet from the bridge's address to the Mac's LAN address has no route. `StreamAddress.accessoryAddress` prefers an IPv6 address in the controller's /64, else a
stable global, else a stable ULA, never a temporary or deprecated one (`SIOCGIFAFLAG_IN6`). New `NetworkNotice.Kind`s: `.liveViewNotReceived`
(a session ended blind; settled `.reached` when a later session of that controller received video), `.localNetworkDenied` (a fatal send
errno EHOSTUNREACH / EPERM persisted) and `.dualHomedSubnet` (two interfaces hold addresses on one subnet; said once per subnet and hour).
`controllerOnVPN` no longer fires for a routed subnet (a specific route through a LAN interface covers the address, `StreamAddress.routeTable`),
this Mac's own LAN address, or an advertised address the HAP connection itself comes from.

**Live sound for the browser (2026-10-15).** `BridgeEngine.browserLiveVideo(cameraID:stream:displayWidth:audio:)` is `liveVideo` with the camera's
sound as AAC-LC (`LiveAudioConverter`: AAC-LC passed through, G.711 and the rest converted to 16 kHz mono by the platform's transcoder);
`LiveMP4Remuxer(audio:)` and its `push(audio:)` add it to the page's live MP4 as a second track at the next keyframe.

**In-app live viewer (2026-10-02).**

`BridgeEngine.liveVideo(cameraID:stream:audio:displayWidth:)` (`LiveVideo/`) gives the app's own viewer the camera's encoded access units
(H.264 / H.265, with their `VideoFormat`: parameter sets and size, and the camera's timestamps) as a `LiveVideoSubscription` (`LiveVideoStream`: `.main`, `.sub`, `.automatic`): no
transcoding, the app decodes in hardware (`AVSampleBufferDisplayLayer`). It leases the camera's ingest the way a HomeKit live view does
(`CameraRuntime.openLiveVideo` → `lease(preferSub:)`): the sub stream starts on demand and stops `subStreamIdleStop` after the last user (HomeKit
or app), a camera without a usable sub stream serves the main stream, `.automatic` takes the sub stream only for a main stream taller than
1440 px shown at most 1280 px wide. Delivery starts at the newest keyframe the hub holds (`.prebuffer(.zero)`: the replay of the newest GOP, so
the first picture is immediate, then live; after a reconnect the hub makes the subscription wait for a keyframe again), a slow consumer loses
the oldest samples (600 buffered), audio is delivered only when asked for and never from the replay. The lease is released once however the
subscription ends: `cancel()`, the consumer finishing, dropping the stream, or the camera's runtime stopping (it ends its viewers). App viewers
are counted in `CameraStatus.appViewers` ("1 viewer in CameraBridge"), never in `liveViewers`, and nothing in a HomeKit session depends on them.
Throws `EngineError.unknownCamera` / `.cameraNotRunning`; an offline camera that runs does not throw (its stream arrives when it delivers).

The preview engine serves synthetic streams (`PreviewLiveSources`): the test pattern is encoded once per picture size and frame rate (two
keyframe intervals) and replayed in a loop at real-time pace with continuing timestamps, leased and counted like a real camera's; only cameras
shown online are served. `PreviewScenario.fleet` has eight sample cameras (seven online) for the Overview grid. Tests:
`Tests/BridgeEngineTests/LiveVideoTests.swift`.

`BridgeEngine.cameraSettings(cameraID:recheck:)` and `BridgeEngine.homeKitReadiness(cameraID:recheck:)` (2026-10-02): after ONVIF refused a
camera's credentials (or locked logins) they answer from memory for 10 minutes (`EngineTuning.onvifRefusalMemory`), without asking the
camera, unless `recheck` is true (the person asked to check again) or the camera was changed. `BridgeEngine.setCameraClockHidden` repeats an
"unsupported" answer instead of asking the camera again. Each `CameraRuntime` owns a `CameraReachability` (the ingest, the camera API, the
event channel and the snapshot provider share it): while the camera answers nothing the ingest neither retries nor switches between
RTSP and HTTP-FLV (a switch needs three failures while the camera answers and 30 s since the last one: `IngestSupervisor.Timing.minimumSwitchInterval`), and the
snapshot provider serves the last picture at once. Snapshots decode a keyframe at most once per size, on one decoder kept 60 s after its last use
(`SnapshotDecoderPool`), and the periodic cache lasts 10 s.

`EngineError` (`unknownCamera`, `duplicateCamera`, `cameraNotRunning`, `invalidSettings`, `configurationUnavailable`,
`noCameraAPI(host:)`). `probeCamera(_:password:)` (the app's Connection sheet). `CameraStatus.recentEvents` /
`SensorState.recentEvents` (`[CameraEventRecord]`, `EventRouter.recentEventLimit`). `CameraStatus.subStreamProblem`,
`BridgeEngine.webhookProblem` and `BridgeEngine.retryWebhook()` (review W4 round 2: a broken sub stream and a webhook
that cannot listen were only logged).
`checkLocalNetworkAccess(host:answerWait:)` and `BridgeEngine.localNetworkAnswerWait` (W3-3 review: the app chooses how
long Check Access waits for the system alert; `checkLocalNetworkAccess(host:)` uses `localNetworkAnswerWait`).
`updateSettings(_ change: (inout BridgeSettings) -> Void)` (App W4 review round 2: settings changed while the engine was
busy undid one another). `BridgeEngine.configurationRecoveredFrom` and `acknowledgeConfigurationRecovery()` (review W4
round 3: a damaged configuration replaced by the defaults was only logged); `localNetworkAnswerWait` is `nonisolated`.
Review W4 round 4 (App findings): `SensorsBridgeStatus.publishedSensors` (`[UUID: [BridgedSensor]]`, `init` parameter
defaulted to `[:]`: the Sensors Bridge page lists the engine's own list instead of a copy of its rule),
`BridgeEngine.readableReason(_:)` is public (one wording for errors on screen), and
`acknowledgeConfigurationRecovery()` is `async` (it removes the saved notice off the main actor).

Per-camera live view / HKSV stream and quality controls (2026-10-01, see `docs/CONTRACT_CHANGES.md`):
`CameraConfiguration.liveStreamMode`/`.liveQualityMode`/`.liveMaxBitrateOverride`/`.recordingStreamMode`/
`.recordingQualityMode` (all decode with `decodeIfPresent`-style defaults when missing, so an older `config.json`
file is unaffected). `.automatic`/`.matchHomeKitRequest`/`.matchHubRequest` reproduce the engine's pre-existing behaviour
exactly; `.alwaysMain`/`.alwaysSub` force the live view's stream; `.originalQuality`/`.originalWhenPossible` make
`MediaFit.live`/`MediaFit.recording` (new optional `qualityMode` parameter) ignore the controller's or hub's requested
size and send the camera's own H.264 untouched, still falling back to transcoding for HEVC or B-frame sources (and,
for recording, a GOP longer than the fragment); `MediaFit.prefersSubStream` takes a new optional `mode` parameter.
`AccessoryOptions.recordingResolutions` grows optional `sourceWidth`/`sourceHeight` parameters. New
`EngineStatus` types `LiveSessionStatus`, `RecordingSessionStatus`, `SourceStreamInfo`;
`CameraStatus.liveSessions`/`.recordingSession`/`.mainStreamInfo`/`.subStreamInfo` expose what is currently playing
through each live viewer and the running recording, and the camera's own measured stream facts, to the app's camera
detail page (`StreamsSection` in `Archive/mac-app/App/Sources/Manager/CameraDetailView.swift`). `LiveSessionStatus.health` (the stream health check's
verdict) and `.endReason` (why the pipeline ended it; nil while it runs) are init parameters with default nil (2026-10-03). `StreamingHandler.init` and
`RecordingHandler.init` grow optional stream/quality parameters; `RecordingHandler.stopAll` is now `async`.

HomeKit Readiness advisor + optimizer (2026-10-01, see `docs/CONTRACT_CHANGES.md`): `BridgeEngine.homeKitReadiness(cameraID:)` /
`homeKitReadiness(vendor:endpoint:credentials:)` (probe-time) grade a camera with CameraAdapters' `HomeKitReadinessAdvisor`,
mixing in `CameraRuntime.readinessFacts()`'s measured codec/size/rate/GOP/B-frame facts when the camera is running.
`optimizeForHomeKit(cameraID:)` applies every automatic fix (ONVIF main/sub encoder settings, Hikvision's smart codec
over ISAPI), snapshotting the previous values (`undoHomeKitOptimization(cameraID:)`), restarts the camera's ingest the
same way `applyCameraSettings` does, and re-measures for `EngineTuning.homeKitOptimizationMeasureWait` before returning
a before/after `HomeKitOptimizationResult`.
Encoder changes (the optimizer, its undo, Camera Settings → Save) try several methods and read each change back
(`CameraConfigMethod`: Hikvision ISAPI / Reolink API, then ONVIF minimal, then ONVIF full); the method that worked is kept
in `CameraConfiguration.preferredConfigMethod` and tried first next time, and the result says which method changed each fix
or why every method failed.
CameraBridge timestamp (2026-10-02, see `docs/CONTRACT_CHANGES.md`): `CameraConfiguration.timestampOverlay`
(`TimestampOverlaySettings`: off by default, top right, medium, date and seconds on, camera name off, 12/24-hour as the Mac's region;
a configuration saved before it existed loads with the defaults) draws the Mac's clock on live view and HKSV recordings.
While it is on `MediaFit.live` / `MediaFit.recording` (new optional `timestampOverlay` parameter) always return
`.transcode("timestamp overlay")` (`MediaFit.timestampOverlayReason`); with Original Quality / Original When Possible the transcode
keeps the camera's own size (`MediaFit.liveEncoderSettings` / `recordingEncoderSettings`), at most `MediaFit.maximumOutputWidth` (3840) wide, the height in proportion and even (`MediaFit.cappedEvenSize`, the rule saved clips use too: the H.264 encoder's limit is 4096). The look (position, size, text options,
camera name) is applied in place to running streams through the camera's `TimestampOverlayControl` (no restart); turning it on or
off restarts the camera's runtime (`BridgeEngine.needsRestart`). The time shown is each picture's `wallClock` corrected by the hub's
measured `wallClockOffset`, so an RTSP camera whose own clock runs off shows the Mac's time. `BridgeEngine.setCameraClockHidden(cameraID:hidden:)`
turns the camera's own on-screen clock off and back on (`CameraSettingsService.hideCameraClock`) and keeps how in
`CameraConfiguration.hiddenCameraClock`, which only the engine writes (`updateCamera` keeps the engine's value).
Straighten the picture (2026-10-18, see `docs/CONTRACT_CHANGES.md`, `docs/superpowers/specs/2026-10-18-straighten-the-picture-design.md`):
`CameraConfiguration.pictureCorrection` (MediaCore's `PictureCorrection`: `straighten` −0.60 to +0.60 bends the horizon's curve onto a
straight line, `level` −0.40 to +0.40 tips it; both 0, `.off`, by default and for a configuration saved before it existed; values past the
limits are clamped, never refused) is the per-camera correction of a bent horizon. Changing it never restarts the camera:
`BridgeEngine.needsRestart` ignores it, because a restart would close the camera's NVR file; it is applied to the running camera in place.
The web API's `PATCH /api/v1/cameras/:id` takes it as a whole value (`{"pictureCorrection": {"straighten": 0.4, "level": 0.15}}`) and the
camera resource carries it with the configuration. Apple Home's live view and HKSV recordings straighten the picture where the codecs can
(`MediaCodecs.supportsPictureCorrection`, the box's ffmpeg; where they cannot, the correction is off everywhere, so it never shows in one
place and not in another): while it is on `MediaFit.live` / `MediaFit.recording` (new optional `pictureCorrection` parameter) return
`.transcode("straightened picture")` (`MediaFit.pictureCorrectionReason`; the overlay's reason when both are on), Original Quality /
Original When Possible keep the camera's own size as they do for the overlay (capped at 3840 wide, so a 4256 × 1888 panorama is converted at 3840 × 1704), and the transcoder is handed the camera's
`PictureCorrectionControl`, which it asks at every picture. An edit reaches the running camera through `CameraRuntime.updatePictureCorrection`,
never a restart. Every transcoder of a live view or recording holds the control, on or off (a nil correction costs nothing), so it
straightens its next picture by a new value, or leaves it as the camera sends it once the correction is off. A live view's path follows the
correction as it is at the session's start, or the next time its video path is rebuilt, and turning the correction on or off rebuilds each
running live view whose path that changes, at once from the hub's newest GOP (`LiveStreamPipeline.pictureCorrectionSwitched`, as a new
size does): a passthrough view starts transcoding to straighten, a transcode that was there for the correction goes back to passthrough. A
new value while it stays on rebuilds nothing. An HKSV recording keeps the path it started with until its next start: one that passes the
camera's stream through is straightened from the next recording on, and one transcoded only for the correction stays transcoded to its end,
unstraightened from its next picture. Snapshots (Apple Home's tiles and notifications, the app's and the web's stills) go through
`CorrectedSnapshots`: the `SnapshotProvider`'s JPEG straightened by the codecs' `MediaCodecs.correctJPEG` at the correction of the moment,
unless the caller asks for the original (`BridgeEngine.snapshot(cameraID:original:)`, `CameraRuntime.snapshot(width:height:original:)`; the
web's `?original=1` for the camera page, which straightens it in the browser while its sliders move). While the correction is off nothing
runs. The straightening fits inside the provider's own budget (`SnapshotProvider.Timing.limit(for:)`: 3 s for an event snapshot, else 4 s;
it gets what the provider left, less 150 ms), a camera runs one correction at a time (each holds a thread while its ffmpeg runs: one of `CodecOffload`'s, never one of the cooperative pool's, which HomeKit and RTP share, and it is given up on after `CorrectedSnapshots.deadline`, 7 s; a request
for another picture waits for it within its budget), the newest straightened picture of each of the last two sizes is kept (Apple Home's
tiles and the web ask for different ones) and handed out at once, a picture straightened by values that changed meanwhile is straightened
once more by the new ones, and a correction that fails or is late serves the camera's own picture, warned at most once every 30 s (a late
one keeps running, and the next request for the same picture takes its result).
Saved clips are straightened by the web route (BridgeWeb, `straighten=1`), which re-encodes them with ffmpeg; `ClipExporter.pictureSize(_:part:)` gives it
the part's picture size (from the part's recordings' init segment), at which the maps are made. The recordings themselves are never changed.
Internal: `EngineTuning` (`Runtime/EngineTuning.swift`; `afterSensorsBridgeStatus` is a test hook) +
`BridgeEngine.init(environment:tuning:)` (tests shrink the demo camera and shorten timers), `BridgeEngine.networkSettle`,
`CameraRuntime`, `IngestSupervisor`, `StreamTraits`, `StreamSources`, `AccessoryOptions`, `SoftMotionMonitor`, `ControllerRegistry`,
`MediaFit`, `H264Levels` (HAP level → level_idc; limits from MediaCore's `H264LevelLimits`), `StreamAddress`, `InterfaceAddress`, `OpusRepacketizer`, `TimelineRebaser`, `StreamingHandler`, `LiveStreamPipeline`,
`TalkbackBridge`, `RecordingHandler`, `RecordingProducer`, `SnapshotProvider`, `CorrectedSnapshots`, `PowerController`, `LocalNetworkCheck`,
`LogCollector`, `ChangeSignal` (deadlines and the FIFO lock are BridgeSupport's `withDeadline` and `AsyncSerialLock`).

## Part A (W2-3) entry points — additions beyond the contract

- `ConfigurationStore` (`config.json`) + `BridgeConfiguration` (settings + cameras), `ConfigurationStoreError`,
  `ConfigurationMigration`; `CameraConfiguration.withoutStreamCredentials`.
- `CredentialStore.credentials(for:)`, `.forgetCamera(_:dataDirectory:)`, `.account(for:)`; `HAPStorage` (FileHAPStore
  accounts/directories for cameras and the sensors bridge).
- `CredentialStore.storeStreamCredentials(of:)`, `.streamCredentials(for:)`, `.streamURLsAccount(for:)` (2026-10-18): the
  credentials a camera takes in its stream URLs' query (BridgeSupport's `StreamURLCredentials`).
- `EventRouter` (actor; `maximumInputsPerCamera`, `maximumInputIDLength`), `EventOrigin`, `SensorState`,
  `EventRouterOutput`.
- `SensorsBridge` (actor), `BridgedSensor`. `PortAllocator` (`resolvePorts(…, listening:)`), `PortAllocationError`.

## Invariants

- `config.json`: `{"schemaVersion": 1, "settings", "cameras"}`, atomic 0600 writes, directory created 0700 (BridgeSupport
  `PrivateFiles`, shared with the HAP store; an existing directory is left as it is). Older files
  run through `migrations[n]` (n → n+1), are rewritten and keep `config.json.v<n>.bak`; newer files, and older ones
  without a migration, are never read nor overwritten (`unsupportedSchemaVersion`). `loadOrRecover()` moves a corrupt
  file (not JSON, no version, `settings` not an object, `cameras` not a list, failing migration) to
  `config.corrupt-<UTC>.json` — use it at startup, since `save` overwrites a corrupt file. Cameras decode one entry at
  a time: an entry this build cannot read (unknown `vendor`/`kind`, no `id`, …) is skipped with a warning and written
  back unchanged by `save` (use one store, and load before saving); missing or unreadable optional keys take the
  `init` defaults, logged by key name (`id`, `name`, `kind`, `vendor`, `endpoint` required); stream URLs are saved
  without user info; repeated camera ids keep the first. Passwords: `camera.<UUID>` in the `SecretStore`; HAP identity `hap.<UUID>` + `<data>/hap/<UUID>/`
  (`hap.sensors-bridge`, `<data>/hap/sensors-bridge/`).
- `EventRouter` (hold timers on the injected `any Clock<Duration>`; reads apply expired holds): motion is on while an
  origin that reports ends (camera event channel, soft motion, stream) reports it **and** for `motionHoldSeconds`
  (≥ 1 s) after the last activity — after every start and after every end those origins report. An origin whose end
  already trails the last activity adds only the rest: Hikvision camera events end 20 s after the last pulse
  (CameraAdapters' pulse hold), soft motion 10 s after the last movement; other vendors' camera events (ONVIF
  MotionAlarm, Reolink, demo) get the full hold after the camera ends them. Holds are kept per owner: webhook/user
  starts are pulses and a webhook stop ends only the webhook's own hold (levels, other origins' holds and the
  doorbell's motion pulse stay). `resetOrigin` ends that origin's levels and holds motion/detections for the full
  hold from the reset. Detections: same with 60 s. Doorbell: presses within 3 s of the last accepted one are dropped; a
  press emits `.doorbell` then a motion pulse no stop can end. Tamper, audio alarm, alarm inputs: levels (≤ 32 inputs
  per camera, ids ≤ 32 characters without control characters; others dropped with one warning). Day/night,
  temperature, humidity: last finite value. `.eventChannel(false)` =
  fault — 5 s after the drop when the channel was connected (`eventChannelGrace`: a routine reconnect raises none), at
  once when it never was (levels are not reset: adapters end them). `.authenticationFailed` → `connection == .offline("Camera
  rejected the username or password")`, `lastError`, fault, unreachable, until the same side succeeds
  (`.eventChannel(true)`, or `setStreamConnection(.online)` for origin `.stream`). Disabled cameras ignore events.
  Outputs go to the handler (synchronous, on the actor) then to `outputs` (AsyncBroadcaster, 1024). Logs: transitions
  under `Events` ("Driveway motion detected", "… doorbell ring", "… person detected"), connection/credentials under
  `Camera`, both with the camera's id. Rising edges are also kept as `SensorState.recentEvents` (the newest
  `recentEventLimit` = 20, oldest first, the most specific edge last), whatever the log level: the app's "Recent Events"
  read them, not the log. `SensorState.apply(to:)` projects into `CameraStatus`.
- `SensorsBridge`: category-2 bridge "CameraBridge Sensors" (AccessoryInformation + ProtocolInformation; each bridged
  sensor has AccessoryInformation + its sensor service, no ProtocolInformation); per camera a bridged accessory (category sensor) per
  enabled option the camera offers (unknown capabilities trust the options; a camera whose motion source is the webhook
  is also offered person/vehicle/animal/package, which the webhook reports): OccupancySensor per person/vehicle/animal/
  package, LightSensor "Daylight" (night 1 lux, day 1000 lux, day until told), ContactSensor per reported alarm input
  (active = 1, open; ids remembered in the bridge's HAP extras, ≤ 16 per camera, ≤ 32 chars; rejected ids warned once
  per camera; `update(cameras:)` forgets remembered ids of every camera not in the list), Temperature, Humidity.
  Stable key `camera.<UUID>.<person|vehicle|animal|package|dayNight|input.<id>|temperature|humidity>` keeps aids across
  restarts, order and option toggles. Each sensor mirrors StatusActive / StatusFault / StatusTampered; unreachable while
  the camera is offline, rejected its credentials or is disabled. Structure changes call `configurationDidChange()`.
  Names are Home-safe (`homeName`: HAP-NodeJS `checkName` rule applied to the camera name and the label; alarm inputs
  are "Alarm Input <cleaned id>", or "Alarm Input <position>" when nothing is left or two ids clean alike).
- Ports: `assignPorts` keeps unique ports and gives others `basePort` (≥ 1024) + lowest free offset, avoiding the
  sensors bridge and webhook ports; persist `hapPort`. `isAvailable` connects to 127.0.0.1 then ::1 (never binds: a
  closed probe listener lingers); `resolvePorts` moves taken ports upward — pass the engine's own listening ports as
  `listening` once servers run (else call it at startup only); `bind(from:…)` retries on `.addressInUse`.
- Defaults: camera events for motion, sensitivity 0.5, hold 20 s, audio on, two-way off, port 0, enabled; webhook off
  on 21090 (random 32-hex token), sensors bridge 21099, base port 21100, log level info. `BridgeEnvironment.live()` =
  `ApplePlatform.services()` + `AppleMediaCodecs`; `.testing(directory:)` = Apple transport/codecs, in-memory secrets,
  null advertiser/network changes/power, loopback, no Bonjour; internal `.inert(directory:)` throws on every call.

References: spec §3.3–§3.4, §5, §7–§8; research brief §3.5–§3.9; integration brief §3–§6. Tests:
`Tests/BridgeEngineTests` (TestClock, fakes; `Runtime*`: decisions and helpers, recording/live/snapshot delegates on
VideoToolbox synthetic sources, ingest from `RTSPTestServer`, soft motion, and the engine end to end on loopback with
`HAPTestController`, `SRTPTestReceiver` and `HDSTestClient`). The plan W3-2 scenarios run the public engine from outside in
`Tests/IntegrationTests/EndToEnd` (opt-in Node / ffmpeg oracles: `docs/interop.md`).

## Additions beyond the contract: cameras behind a service (2026-10-08, docs/CONTRACT_CHANGES.md)

`CameraConfiguration.integration` (`IntegrationSettings`: the service and plain facts; the secret is the camera's Keychain password). The engine owns a `Go2RTCManager`
(`EngineTuning.go2rtc` replaces what the runtimes talk to in tests): it starts with the first go2rtc/UniFi camera and stops with the bridge (`stopServices`).
`CameraRuntime` asks a `StreamHoldingDriver` for its local RTSP address (`attachStreams()`) instead of probing, and calls `releaseStreams()` when it stops; a go2rtc
camera has no `CameraReachability` (it is reached on this Mac). `probeIntegration(…)` is the wizard's check; `beginIntegrationSetup()` / `endIntegrationSetup()` run
go2rtc's sign-in pages on loopback; `isStreamingHelperInstalled` says whether the app bundle holds the helper.

## Additions beyond the contract: the NVR (2026-10-10, docs/CONTRACT_CHANGES.md)

Recording of the main stream to fragmented MP4 files (a `.cbidx` index beside each), and reading them back. Reading: `ArchiveReading` (`activity(camera:range:binCount:)`,
`fragment(camera:containing:)`, `fragment(camera:startingAfter:)`, `fragment(camera:id:)`, `read(_:_:)`, `extent(camera:)`, `catalogVersion`, `isReady`),
`ArchiveFragment` (`fileKey`, `index`, `backToKey`, `byteLength`, `id`), `ArchiveReadPart`, `ArchiveExtent`, `ArchiveActivity`, `ArchiveError`; `BridgeEngine.archive`.
Status and storage: `ArchivePause`, `ArchiveRecordingState`, `ArchiveNote`, `CameraArchiveStatus`, `CameraStatus.nvr`, `ArchiveStorageStatus`, `BridgeEngine.nvrStorage`.
Host policy and folder check: `ArchivePlatformPolicy`, `BridgeEnvironment.archivePolicy`, `BridgeEnvironment.demoKeyframeSeconds` (development only), `ArchiveFolderReport` (`floorBytes`), `ArchiveFolderCheck`, `ArchiveFolderError` (`belowFloor`),
`BridgeEngine.inspectArchiveFolder(_:)`. Configuration: `CameraConfiguration.nvrEnabled`, `CameraConfiguration.nvrRecordSound`, `BridgeSettings.nvrFolder`,
`BridgeSettings.nvrKeepDays`, `BridgeSettings.nvrMaxSizeGB`, `BridgeSettings.nvrKeepDaysRange`, `BridgeSettings.nvrMaxSizeGBRange`,
`BridgeSettings.isValidNVRFolder(_:)` (old files decode unchanged; an unusable value takes its default). `BridgeEngine.setNVR(cameraID:enabled:recordSound:)` changes the two
camera fields in place under the operations lock, never restarts the camera, and is the only place they change (`updateCamera` carries them forward; `needsRestart` ignores them).
Shared constants and names: `ArchiveConstants`, `ArchiveIdentity` (`fileKey(forSegment:)`, `fragmentID(fileKey:index:)`, `parseFragmentID(_:)`), `ArchiveLayout`.
Package-only: `ArchiveMedia` (the browser's video-only view of a file), `CBIndexFormat`, `CBIndexFile`. Internal: `NVRCoordinator`, `ArchiveStore`, `RecorderHost`, `ArchiveWriteTarget`.

The recorder: `RecorderHost` starts one `CameraArchiveRecorder` per camera with Record on; it subscribes to the camera's `MediaHub` with `.prebuffer(.zero)`, cuts fragments at every keyframe, after 2.5 s of decode time,
900 frames or 16 MiB (`FMP4Muxer.fragment(…continuation:)` for the pieces after a keyframe) and appends them to `<folder>/<camera directory>/<yyyy-MM-dd>/<HH-mm-ss>.mp4` through an `ArchiveFileWriter`, which does all disk
work on the camera's own serial queue (the recorder never waits for a drive; 15 s or 256 MiB pending is a stall). A file has one anchor; fragment times are media times from it; a break (reconnect, decode time more than 0.5 s back or more than max(5 s, 4 frame intervals) forward,
parameter-set or audio-format change, 15 s without video, 1 s of drift twice) closes it and the next keyframe opens a new one; 900 s or 2 GiB ends it at a keyframe without a gap. A jittery or lossy camera does not cut files: a decode time up to 0.5 s at or behind the last is moved to just after it (the frame and its composition offset kept; `ArchiveConstants.backwardNudgeLimit`), a forward step above max(1.5 s, 4 intervals) up to 5 s stays in the file (`forwardGapLimit`; the picture before it lasts through it, as the player and an export, which holds gaps up to 10 s, already do), and either logs "<camera>: its video arrives unevenly (network?)" at most every 5 minutes. The camera's audio converter is kept across cuts about the video (a roll, a clock jump, a divergence, a format change) while the camera's audio format is the same, so a cut does not start it again; a reconnect, an idle camera or an audio change starts a new one. `FragmentIndexer` (package) measures a stored
fragment for the index (`CBIndexFragmentRecord`, per-minute `CBIndexRollup`s) and is the only code that does, for the recorder and for a recovery scan. The camera folder is the sanitized camera name (the Mac) or the camera's UUID
(the box), with `camera.json`; the recordings folder itself is never created.

### ArchiveMedia (NVR)

`ArchiveMedia` (package access, the browser's view of a recording) reads the init segments and fragments `FMP4Muxer` writes and gives the page video only:
`mime(forInit:)` (`video/mp4; codecs="avc1.PPCCLL"` or `hvc1.…`, the string `MediaSource.isTypeSupported` wants), `videoInit(_:)` (the init segment without its
sound track, byte for byte what a muxer without sound writes, or the input itself when there is none; with the picture size and whether sound was dropped) and
`videoSegment(_:)` (a stored `prft` + `moof` + `mdat` as `moof` + `mdat` with the video samples only). Video is track 1 and sound is track 2; any other layout is
refused with `ArchiveMedia.Failure.unsupported` or `.malformed`, the only errors it throws. Tests: `ArchiveMedia*Tests` in `BridgeEngineTests`.

The store behind `BridgeEngine.archive` (NVR; `ArchiveStore`, internal): `start` returns at once while the folder is probed, unclosed files are repaired (`IndexScanner`: a
torn tail is cut, the sidecar rebuilt) and the catalog is loaded from each file's sidecar header and per-minute rollups; `ArchiveReading.isReady` turns true when that is done, so
nothing archive-related delays `engine.start()`. A fragment's `start` and `end` are whole milliseconds and abut; when files overlap the one that starts later wins. Closed files'
fragment tables are read from their sidecars when a lookup needs them (the 256 most recent stay in memory); bytes are read on a 6-wide queue with a 5 s deadline, through at most 16
open handles and a 64 MB cache, and a file that is unlinked while it is read stays readable through its handle. A drive probe every 5 s sets the pause recorders obey (`ArchivePause`: no
folder, folder missing, below the floor with 1 GiB of hysteresis, writes refused, drive not answering) and publishes `BridgeEngine.nvrStorage`; a probe that hangs blocks one thread and
nothing else. Retention (at start, every 60 s, after each file close and after a settings change) deletes closed own-pattern files with a valid sidecar in every camera directory that
holds a `camera.json`: first those that ended before `nvrKeepDays`, then the oldest starts across all cameras down to `min(nvrMaxSizeGB x 1e9, total - 2 x floor)`; free space never causes
a deletion, and a file a recorder has open is never touched. `ArchiveFolderCheck.inspect(_:policy:)` checks a folder on a probe queue of its own. No public or package symbol is added
beyond the list above.

Preview data for the NVR (2026-10-10, docs/CONTRACT_CHANGES.md): `PreviewScenario.nvr` (`-previewEngine YES -demoScenario nvr`, `camerabridged --preview nvr`) shows the eight fleet
cameras with recordings: `BridgeEngine.preview(scenario:)` gives the engine an `archive` of made-up recordings (a daily rhythm of activity with bursts, a gap, a camera that stopped
recording, real playable video from one synthetic clip), `nvrStorage` numbers and an NVR folder in the settings. Internal: `PreviewArchive`, `PreviewClip`.

## Additions beyond the contract: exporting a clip (2026-10-12, docs/CONTRACT_CHANGES.md)

Cutting a stretch of one camera's recordings into a normal MP4 (the export-clip design, `docs/superpowers/specs/2026-10-12-export-clip-design.md`; the planner, the writer and `ClipExporter` come with the tasks that follow and are listed here when they land). The read seam gains one part, `ArchiveReadPart.header`: the first `headerLength` bytes of a fragment, that is `prft` + `moof` + the 8-byte `mdat` header, so that the sample tables of a clip are planned from headers alone, before any video is read. `ArchiveStore` serves it on the same read queue, with the same checks and cache as the other parts; `PreviewArchive` refuses it. Public types: `ClipLimits` (`standard`: 2 hours per camera, 20 GiB in all, a gap up to 10 s is held), `ClipRequest`, `ClipGap`, `ClipPart`, `ClipPlan` (the exact size of every part before a byte is written; a fake in another target builds one with the public initializer), `ClipError`, `ClipSink` (where the bytes go), `ClipExporting` (what the Mac app and the box's routes call) and `ClipFileName` (`part`, `folder`, `archive`, `unique`: the names of a clip's file, of the folder a multi-camera export makes on the Mac and of the ZIP the browser gets). Package-only: `ClipSample`, `ClipCopy`, `ClipPartTables` and `ClipPlan.tables`, which is what the planner hands the writer. `ClipPlanner` (package; `ClipPlanner(archive:limits:sizing:)`, `plan(_:)`) turns a `ClipRequest` into a `ClipPlan` from fragment headers alone: the key picture at or before the start, parts where the camera's init bytes change, gaps held, skipped or refused by the limits, and the exact size of every part from the writer's sizing function. `ClipLayout` and `ClipSizing` (package; the boxes are made with a small `ClipBoxBuilder`) build the `ftyp`, the complete `moov` and the `mdat` header of a progressive MP4 from a part's tables, so the file's exact size is known before a picture is read (`co64` and a 64-bit `mdat` from 4 GiB); `ClipWriter` (package) writes them and then copies each fragment's pictures untouched, cancellable between fragments. `ClipExporter` (public) is the facade the Mac app and the box's routes call: `plan(_:)` and `export(_:part:to:progress:)`, with parts counted from 1.

## Additions beyond the contract: camera events beside the recordings (2026-10-16, docs/CONTRACT_CHANGES.md)

`ArchiveReading.events(cameras:range:limit:)` → `ArchiveEventPage` (`events`, `isTruncated`) of `ArchiveEvent` (`id`, `camera`, `kind`, `start`,
`end`, `hadVideo`, `recorded`), newest first; a page never splits a millisecond (the router stamps every edge of one publication alike, so
the events of the oldest start are all in a page or all in the next, and a moment with more than `limit` events is one page). The
requirement has an extension default (no events), so `PreviewArchive` and other conformers compile unchanged. Only "no place for recordings
is chosen" answers no events without looking: while the catalog loads or the folder is missing it throws `ArchiveUnavailable` (`loading`,
`folderMissing`), and `ArchiveError.timedOut` while reads are stalled. The store answers it from `ArchiveEventLog` (internal, `NVR/ArchiveEventLog.swift`): the router's rising and falling edges
(`EventRouter.setEdgeHandler`, internal; the names `recentEvents` uses) go through `NVRCoordinator.recordEvents` to one append-only JSON-lines
file per camera per UTC day, `<recordings>/.events/<CAMERA-UUID>/<yyyy-MM-dd>.jsonl`, written on a serial queue of its own (lines that cannot be
written wait, at most 1000, the oldest dropped first but never the one being written; a new folder gives up the old one's; `.events` and the
camera folders are never written, read or pruned through a link), kept whether or not the camera records, and read on the store's read queue
with its deadline (a torn line is skipped). `recorded`: the catalog holds video at the event's start (from 3 s before a file), or the recorder
was writing it less than 2 minutes ago. The janitor deletes whole day files after each pass: those that ended before `nvrKeepDays`, and those
before the newest file the size rule deleted. Nothing is kept while no folder is chosen.

## Additions beyond the contract: descriptions of events (2026-10-18, docs/CONTRACT_CHANGES.md)

`ArchiveEvent.description` (`EventDescription?`, a trailing `init` parameter with default nil): what an AI service said it saw at the event's
start, as `EventDescription` has it (`summary`, `kind`, `concern`, `model`, `at`; `EventDescription` is now `Hashable`, so `ArchiveEvent` stays
so). The event log gains a third kind of line, `{"ai":{"at","concern","kind","model","summary"},"id":"<the event's>","v":1}` (`at` in milliseconds
like every time in the file): it goes through the same pending queue and serial drain as the start and end lines, into the day file of the
event's start (whenever the answer comes, so retention takes the event and its description together), at most 2048 bytes (a description that
does not fit is not kept, and a longer line is not read). The last description line of an id wins; one of an id the file does not hold (the
place for recordings changed since the event began) is ignored; a build that does not know `ai` sees a line that is neither a start nor an end
and skips it. `ArchiveEventLog.record` returns a `StartedEvent` (`cameraID`, `kind`, `id`, `date`; internal) for each event it began and kept,
`NVRCoordinator.recordEvents(_:)` hands them on, and `NVRCoordinator.recordDescription(_:for:)` writes a description for one of them. The
events route of BridgeWeb carries `description` (`{summary, kind, concern}` or null) on each event.

## Additions beyond the contract: AI descriptions (2026-10-18, docs/CONTRACT_CHANGES.md)

`BridgeEngine/AI` writes one brief description of a camera event from a few still pictures, with the AI service the person chose. Opt-in twice: no
service is chosen until the person chooses one (`BridgeSettings.ai`), and each camera has its own switch (`CameraConfiguration.aiDescriptions`, off).

- **The description.** `EventDescription` (`summary` at most `maximumSummaryLength` characters and `maximumSummaryBytes` (600) UTF-8 bytes, without control or format characters (the emoji joiner stays), `kind` and `concern` as `EventDescription.Kind` and
  `EventDescription.Concern`, `model`, `at`); `EventDescription.parse(_:model:at:)` reads a model's answer leniently; `nothingNotable` is the
  summary of an event with nothing in it.
- **The services.** `AIVisionDescribing` (`model`, `describe(_:)`) is what one service is: `AnthropicVision` (Claude; `defaultModel` is
  `claude-haiku-5-5`) and `OpenAICompatibleVision` (OpenAI, OpenRouter, or a model at home such as Ollama; the key may be empty). A
  `DescriptionRequest` holds the camera's name, the kind of event, the local time and the `LabeledPicture`s in time order; `DescriptionPrompt` is what
  the model is told. Both send through an `AITransport`, `URLSessionAITransport` live (certificate checks on, 20 s, answers up to 1 MiB, and
  it never follows a redirect: `AuthenticatingHTTPClient(followsRedirects: false)`, so a 3xx is the answer and the key and the pictures go only
  to the saved address). `AIProviderError` (`keyRefused`, `notAllowed`, `notFound`, `rateLimited`, `unreachable`, `serviceFailed(_:)`, `keyNeeded`
  (a 401 with no key to send), `requestRefused` (a 400), `redirected` (a 3xx), `declined` (Claude's `stop_reason` "refusal"), `badAnswer`)
  carries no request or answer data, so it is safe to log and show; `sentence` is the plain words.
- **The settings.** `AIDescriptionSettings` (`provider` as `AIProviderKind`, `anthropic` or `openAICompatible`; `model`, 1 to 100 printable
  characters (`modelLengthRange`); `baseURL`, which an OpenAI-compatible provider needs: http or https, a host, no user name or password, no query or
  fragment, at most 500 characters; and `dailyLimit`, 1 to 5000 (`dailyLimitRange`), default 200) is `BridgeSettings.ai`. `validationProblem` names the first field that cannot be saved (`Problem`: the field and the words),
  and `BridgeEngine` refuses such settings with `EngineError.invalidSettings`. Decoding is lenient: a value the
  build would refuse takes its default (logged by key name, never by value), and an OpenAI-compatible provider without a usable address loads as no
  provider, so what is loaded can always be saved again.
- **The key.** `BridgeEngine.setAIKey(_:)` keeps it in the platform `SecretStore` as `ai.key`: never in `config.json`, a log, a diagnostic, an error or
  an answer of the web API. It is trimmed of spaces, tabs and line breaks (`AIDescriptionSettings.cleanedKey(_:)`: a trailing newline would make an
  invalid header) and refused unless what is left is 1 to `maximumKeyLength` characters of visible ASCII (0x21 to 0x7E), which leaves out an inner space,
  a control character, a zero-width character, a byte order mark, a bidi control and any non-ASCII text; nil or an empty string deletes it.
  Nothing reads it back but the engine and the describer (`aiKey()`, internal). `aiKeySaved` and `aiKeyHint` (its last four characters; none for a key
  under eight characters, where four would be most of it) are all the page learns; `aiKeyStatus()` gives both from one read made off the main actor
  (a failed read counts as no key and is logged once, by the name `ai.key`).
- **A key is for one service.** The settings update that changes `ai.provider` (to or from none too), or for an OpenAI-compatible service the
  scheme, host or port of `baseURL` (the scheme's own port when none is written; the case of the host and the path do not count), deletes the saved key
  first (one that cannot be read is deleted all the same), and only a failure to delete it stops the update; a new model, daily limit or path
  keeps it. The card then asks for the key of the new service, and the old one is never sent there. Two addresses that cannot be read are never the
  same server. The log says the key was removed, naming the new service (the address's host only), once the settings are saved.
- **The camera's switch** is applied in place: `needsRestart` ignores `aiDescriptions`, so switching it never restarts a camera.
- **The pictures.** Two steps, so that only encoded data waits and one set of pictures is decoded at a time. `CameraRuntime.gatherEventFrames(at:)`
  (internal; `EventPictures.gather(at:)`), called when the event starts, with its date on the bridge's clock as the event router stamps it,
  gathers `EventFrames` and decodes nothing: "4 s before" and "2 s before", keyframes of the main stream's ring (`MediaHub.recentKeyframes()`), each
  within 1.5 s of its moment and used once (the pair closest to their moments together, else one for the moment it is nearer; none for a camera
  that streams on demand: its ring is empty when the event starts); the event picture's source, the camera's own JPEG as it sent it when it comes
  within 3 s of the event (`SnapshotProvider.cameraJPEG(within:startedAfter:)`: Home's one fetch, never Home's caches, never the last picture in
  its place; a fetch it starts keeps Home's own limit for an event snapshot, so only the describer's wait is short, and a fetch that began more
  than 0.5 s before the event, a picture of before it, is not used), else
  the newest GOP of the ring up to the frame nearest the event (at most 150 frames and 8 MiB; in a longer GOP the last frame kept), else the first
  keyframe that arrives within 3 s, else none; "2 s after" and "4 s after", chosen as the ones before, from the ring and then live, the wait ending
  at the first keyframe 4 s after the event or 6 s after the call (`afterWait`). Frame times are `wallClock` plus the hub's `wallClockOffset`, the
  bridge's clock as the recordings place frames. `CameraRuntime.eventPictures(from:)` (`EventFrames.pictures(decoders:log:)`) makes the JPEGs later,
  in time order, at most 768 px wide at quality 0.7 (a camera JPEG that fits as it came), one set at a time on the runtime's own
  `SnapshotDecoderPool` for them (kept 10 s, never the snapshot provider's), whose JPEG work runs off the cooperative pool
  (`SnapshotDecoderPool.offCooperativePool`, `CodecOffload`); decoding forward to the event picture stops after 3 s. A picture that cannot be had
  is left out; a cancelled gather or decode stops at once. One `EventFrames` holds about 10 MiB at most; the describer keeps few waiting (it drops
  an event older than 60 s). `SnapshotDecoderPool` gains `blockingWork` (default inline, as Home's snapshots always ran), `quality:` on
  `jpeg(fromKeyframe:…)` and `jpeg(fromGOP:…)` (default 0.8) and `resizedJPEG(_:maxWidth:maxHeight:quality:)`; a keyframe decoded on it moves the
  decoder off the GOP it was partway through, so the next picture of that GOP starts again at its keyframe.
- **The describer.** `EventDescriber` (internal actor, `AI/EventDescriber.swift`), made by the engine at first use, started with `startServices` and
  stopped with `stopServices` (before the runtimes; a call in flight is cancelled). The edge handler hands it what the event log began
  (`eventsStarted`, which returns at once; nothing while no recordings folder is chosen). It describes an event when a service is set, describing is
  not paused, today's limit is not reached, the camera runs with its switch on and had no event described in the last 60 s; of the events of one
  camera that start together, the most specific (Person > Package > Vehicle > Animal > Face > Doorbell ring > Motion); tamper, sound and alarm inputs
  never. A skipped event costs nothing. A more specific kind that starts on the camera within 2 s of the admitted event (Motion, then Person a
  second later), while that one is still gathered or waits, takes its place: its frames, and the description goes to its row (the minute still
  counts from the first). The frames of an admitted event are gathered at once (every camera at the same time), then it waits in a queue of
  width one; one that waited more than 60 s is dropped before its pictures are made, and when its turn comes its camera is looked up again: one
  turned off or removed meanwhile has nothing made or sent; the switch is read once more, and the service must still be the one the turn began
  with (`serviceGeneration`), right before the first send and again right before the retry, else the event is dropped unsent (uncounted before its
  first send). The request carries the camera's name, the kind it
  reported and the event's local time in the bridge's zone ("Sunday 18 October 2026, 9:19 PM"); a network error or a 5xx is tried once more after
  2 s unless the event is stale by then, nothing else is. The description goes into the event log (its `at` to the whole millisecond); a failure
  becomes the last error, unless the service or key it came from was replaced since. A refused key pauses describing until the service or the
  key changes, or Try it works again (which also clears the refusal): one error, one log line.
  Each event sent counts once toward the day (`AIUsage`, `<data>/ai/usage.json`, 0600: the counts of the last 8 days by the day's name in the
  bridge's zone, so a 25-hour day is one day and a restart keeps the count). The engine gives it its service whenever the settings or the key change
  (`AnthropicVision`, which needs a key, or `OpenAICompatibleVision`, over `URLSessionAITransport`; tests replace the transport and the clock with
  `EngineTuning.aiTransport` and `aiNow`), and every change of the AI settings (a new model or limit too), the service or the key starts a new generation: a pause ends, the last
  error is forgotten and a call for what was in use before is neither kept nor sent again (whether the key goes with the service is a separate
  rule, `keepsKey(from:)`). A settings save that fails after
  the change of service deleted the key gives the describer its service again, without the key. `BridgeEngine.aiStatus()` gives the Settings
  card an `AIStatus` (`today`, `last7Days`, `limitReached`, `paused`, `lastError`, `lastErrorAt`, `needsRecordingsFolder`).
  `BridgeEngine.tryAIDescription(cameraID:)` is Try it: the pictures around now of any running camera (its switch on or off: the person asked),
  described and not stored, counted toward the day, one at a time; it throws `EngineError.unknownCamera`, `AIDescriberError` (`noService`,
  `limitReached(_:)`, `cameraNotRunning`, `noPictures`, `alreadyTrying`, each with a `sentence`) or the service's `AIProviderError`. A failed try is
  logged as "Try it for <camera> failed: <sentence>".

## The NVR (Sources/BridgeEngine/NVR)

Recording the cameras' main streams and reading the recordings back (docs/CONTRACT_CHANGES.md 2026-10-10; the new public API is listed under "Additions beyond the contract: the NVR"). One `MediaHub` subscription per camera feeds one recorder; the store owns the catalog, the reads and the retention; the engine's own surface is `setNVR`, `archive` and `nvrStorage`.

```
MediaHub (per camera) ─► recorder ─► <recordings>/<camera folder>/<yyyy-MM-dd>/<HH-mm-ss>.mp4  (+ .cbidx when the file closes)
                           ▲                                   │
       RecorderHost ◄── NVRCoordinator ──► ArchiveStore ───────┴─► ArchiveReading (catalog, reads, activity) ─► the app, BridgeWeb
```

- **Time.** A file has one anchor: its first frame's wall clock, or the host's clock when that differs by more than 60 s. A fragment starts at anchor plus media time, so fragments abut exactly. A measured wall time more than 1 s off the derived one, twice in a row, ends the file.
- **Fragments and files.** A fragment is cut at every keyframe or after 2.5 s, 900 frames or 16 MiB; one that does not start on a keyframe is a continuation fragment (`FMP4Muxer.fragment(video:audio:nextDecodeTime:continuation:)`). Any break (a reconnect seen through `MediaHub.discontinuityCount`, a decode time that steps back or far forward, a parameter-set or audio change, 900 s or 2 GiB at a keyframe, 15 s without video) flushes, writes the sidecar and closes the file; the next keyframe opens a new one.
- **Safety.** The recorder never creates the recordings folder or a parent of it, only the camera and date folders. Files are 0600, folders 0700. Retention deletes only closed files with the exact own name and a valid sidecar, in every camera folder that holds a `camera.json`, never an open file, and never because free space is low. The `.cbidx` sidecar is a cache: the mp4 is the truth, and a missing or untrusted sidecar is rebuilt with `MovieFragmentReader`.
- **Start.** `ArchiveStore.start` returns at once. Repair and the catalog load run in the background and `isReady` says when they are done, so nothing archive-related delays `engine.start()` (the daemon says `READY=1` after it).
- **The host.** What only the host knows is `ArchivePlatformPolicy`: free space, which volume is the system volume, the floor, and how camera folders are named. The box: `statvfs` from BridgeDaemon, `max(8 GiB, 5%)`, the camera ID. The Mac: Foundation's volume attributes, `max(20 GiB, min(10%, 50 GiB))` on the startup volume, the camera name.

| File | What |
|---|---|
| `ArchiveConstants.swift`, `ArchiveIdentity.swift` | The numbers the parts share; the file key, the fragment id and the name patterns |
| `ArchiveReading.swift`, `ArchiveStatus.swift`, `ArchivePlatformPolicy.swift` | The reading seam; the status and storage values; what the host supplies |
| `CBIndexFormat.swift` | The `.cbidx` v1 sidecar codec |
| `NVRCoordinator.swift`, `ArchiveWriteTarget.swift` | The engine's one handle on the NVR; the seam between the recorders and the store |
| `RecorderHost.swift`, `CameraArchiveRecorder.swift` and the files beside them | The recorders: file writing, folder naming, continuity rules |
| `ArchiveStore.swift`, `FolderCheck.swift` and the files beside them | The store: catalog, index scanner and repair, retention, volume monitor, read queue, activity |
| `ArchiveEventLog.swift` | The cameras' events beside the recordings: the day files, reading them with what the catalog holds, their retention |
| `ArchiveMedia.swift` | The browser's video-only view of a file (`package`) |
| `ArchiveDrive.swift`, `ArchiveMove.swift`, `ArchiveMover+Store.swift` | The archive drive: its state, probe, marker and remembered file list; the move (copy, sync, check, put in place) and its clean-up after a crash; the store's monitor, loader and mover |

## Additions beyond the contract: the archive drive (2026-10-25, docs/CONTRACT_CHANGES.md)

A second drive where older recordings move when the recordings drive fills, instead of being deleted (archive-tier brief). Additive API:
`BridgeEnvironment.archiveDriveFolder` (the host names the folder; nil keeps today's behaviour exactly), `ArchivePlatformPolicy.isSameVolume` and
`ArchivePlatformPolicy.lowerThreadPriority` (both optional, set by the daemon), `ArchiveReading.awaySpan(camera:containing:)` (a requirement with a default
that answers nil), `ArchiveActivity.Bin.away`, `ArchiveStorageStatus.archive`, `ArchiveStorageStatus.hardMaximumBytes` and `ArchiveDriveStatus` (`State`: `connected`,
`notConnected`, `notAnswering`, `failing`, `refused`; `Move`; `usedBytes`, `freeBytes`, `totalBytes`, `floorBytes`, `oldest`, `newest`, `moving`, `waitingFiles`, `waitingBytes`,
`movedFiles`, `movedBytes`). Internal: `StorageTier`, `CatalogFile.tier`, `CatalogState.archiveAway`, `ArchiveDriveState`, `ArchiveDriveMeasurement`, `ArchiveDriveIndex`,
`ArchiveMove`, `ArchiveMoveStep`, `ArchiveMoveWorker`, `RetentionPlanner.plan(_:archive:)`, `RetentionPlanner.ArchiveInput`, `RetentionPlanner.TieredPlan`, and the store's
`driveLoop`, `probeDrive`, `loadDrive`, `moveLoop`, `move`, `resolveDuplicate`, `removeMainCopy`, `writeDriveIndexIfDue`.

- **Which folder is the archive.** Only a folder that holds the drive's marker `.camera-bridge-archive` (written by `cb-recording-drive --archive` as root, `{"uuid": …}`),
  is not on the system volume (`isSystemVolume`) and not on the recordings drive (`isSameVolume`) is the archive drive; anything else (the folder of an unplugged drive,
  the OS's read-only placeholder, a bare folder on the box's disk) is never written. A failed write test leaves its recordings playable but moves nothing.
- **The catalog knows each file's drive** (`CatalogFile.tier`). A file keeps its segment, file key and fragment ids when it moves: the archive has the recordings
  folder's own layout (`<camera directory>/camera.json`, `<camera directory>/<date>/<HH-mm-ss>.mp4` + `.cbidx`). Reads go to the drive a file is on: the archive has its own
  read queue with the same deadline (`ArchiveConstants.readDeadline`, 4 at a time), its own handles, probe queue and control queue, so a slow USB drive holds up nothing of
  the recordings drive. The block and table caches are shared (a move copies the bytes exactly).
- **Retention** (`RetentionPlanner.plan(_:archive:)`, `RetentionJanitor.swift`). Given only while the archive is connected, loaded, answering and not failing; otherwise the
  plan is `plan(_:)`, today's. Aged files are deleted on both drives (the same `nvrKeepDays`). Over `maximumBytes` the oldest files of the box move, each when the archive can
  take it within its own maximum (its size minus twice its floor) and above its floor, after the archive let go of what is older than it; a file it cannot take is deleted as
  today. Over `ArchiveStorageStatus.hardMaximumBytes` (size minus 1.5 floors) the oldest are deleted even with an archive, so moves that lag never pause recording.
  The event log's size cutoff never passes the oldest recording kept on either drive. A file being written is never a candidate; neither is the one being moved.
- **The move** (`ArchiveMove.perform`, on `ArchiveMoveWorker`'s own thread at background quality of service, `nice` 19 and the idle I/O class on the box): the box's mp4 and
  sidecar must be what the catalog says and the archive must have room; both are copied to `<name>.moving` a chunk at a time (1 MiB, at most 32 MiB/s, waiting while someone
  reads the archive), hashed with SHA-256 as they are read and synced; the copies are read back and compared; the sidecar takes its name, then the mp4, then the folder is
  synced. Then, under the store's lock and only if nothing changed meanwhile, the catalog points at the archive; then the box's copy is deleted (mp4, then sidecar, kept on
  `pendingMainRemovals` until it is gone) once the archive's copy is found whole: while the drive is away it waits (its bytes still count on the box), and a copy the drive
  lost makes the box's copy the recording again. A move whose file changed takes its copy away again; three moves in a row that the archive failed make it "failing" for 10
  minutes.
- **After a crash** (`ArchiveMoveStep` names each step a test stops at): before the archive's files are read, its `.moving` files and a sidecar that took its name without its
  mp4 are deleted (the box still has the recording); a recording found on both drives stays the box's in the catalog until the mover compared the two (sizes, sidecar bytes
  and SHA-256 of the contents): the same, the box's copy is deleted; different, both files stay and the box's is the one shown. A sidecar the box has without its mp4 whose
  recording is on the archive is deleted. Each crash point leaves exactly one good copy after the next start.
- **Away and back.** A drive that goes away (no marker) leaves its files in the catalog: they count in the extent and the events' `recorded`, no lookup finds a fragment in
  them (`fragment(startingAfter:)` skips them), `awaySpan` names the stretch and `activity` counts it as `away`, not `coverage`. Its files are remembered in
  `<data directory>/archive-drive-index.json` (written when they changed, at most every 10 s), so a start without the drive still shows them; a start with it scans both drives.
  Plugged back in, its files are read again and play.
- **The Sky Watcher's log and stills (`.sky`) and the cameras' events (`.events`) never move**: they stay in the recordings folder (the mover only takes catalog files).

## Additions beyond the contract: the bridge's time zone (2026-10-14, docs/CONTRACT_CHANGES.md)

`BridgeSettings.timeZone` (an IANA identifier; nil: the system's) becomes the process's time zone when the settings are saved (`TZ` and
Foundation's default, so the timestamp overlay and ffmpeg children follow it until the next launch); at launch the engine leaves the
process's zone as it is (the recorder names its folders in the zone it starts with, and the overlay draws that zone until a save). It is the
zone of every clock time the engine words for people ("Camera Bridge waits until 9:19 AM", `readableReason`) and of the internet guard's
"today", from the start: `BridgeTime` (BridgeSupport), set when the configuration loads and when the setting changes (2026-10-18).
`BridgeEngine.setCameraTimeZone(cameraID:)` sets a camera's clock to it through ONVIF `SetSystemDateAndTime` (a POSIX string from
`PosixTimeZone`), so the date and time the camera draws itself is local time.

`BridgeEngine.setCleanPicture(cameraID:clean:)` (2026-10-14) turns every label the camera draws itself off or back, keeping the saved copy in
`CameraConfiguration.cleanPictureBackup` (engine-owned, like `hiddenCameraClock`).

Plugins (2026-10-15): `BridgeSettings.plugins` (`[String: PluginState]`, decoded leniently) keeps each plugin's switch, account line, last sync and
last problem; `BridgeBackend.pluginSecret(id:)` / `setPluginSecret(id:_:)` keep a plugin's session in the platform `SecretStore` (account
`plugin.<id>`); `BridgeBackend.portAnswer(host:port:timeout:)` → `PortAnswer` (answers, refused, silent) and `BridgeBackend.localIPv4Addresses()`
serve the Wyze plugin's search of the local network. All have extension defaults, so existing conformers compile.

On-demand cameras (2026-10-15): a camera whose driver says `CameraDriver.streamsOnDemand` (a eufy battery camera) has its main stream connected
only while something wants it: a HomeKit or in-app live view (`lease`), an HKSV recording (the recording handler holds the main stream for its
length), or a motion event (held while the event lasts; the start reaches the router once the picture flows, or after `onDemandWakeWait`, so the
recording Home asks for starts with video). It is woken once at the start for its picture size, and sleeps `onDemandIdleStop` after its last user.
Soft motion and the motion shadow test never run for it, and asleep is not offline: when the idle stop puts it to sleep after a wake that delivered
video it reads as online, even if that wake ended in a stall (2026-10-16); a wake that never delivered leaves it offline. The engine hands
`EufyBridge.shared` its helper launcher and the `plugins/eufy` folder of the data directory at every start.

Pan and tilt (2026-10-16): `BridgeEngine.panTilt(cameraID:pan:tilt:)` moves a camera whose driver has `CameraDriver.makePanTilt()`; a move stops
by itself 1.5 s after the last ask. `CameraStatus.panTilt` says whether a camera pans and tilts. Motion detection asks for
`MediaCodecs.makeMotionDecoder(format:)` (default `makeVideoDecoder`), which may hand back smaller pictures decoded on the GPU.
`CameraStatus.zoom` and `BridgeEngine.panTilt(cameraID:pan:tilt:zoom:)`: the runtime asks the control what it can do when the camera starts.

Battery (2026-10-16): `CameraStatus.battery` (`BatteryStatus`, nil without one). The runtime asks `CameraDriver.batteryStatus()` at the start and
every `EngineTuning.batteryPollInterval` (5 min) once it answered; one that has not answered yet is asked again after 1/20, 1/10, 1/5 and 2/5 of
the interval, then no more. The last reading is kept when an answer is missing, and goes to the accessory's Battery service
(`CameraController.setBattery`, ChargingState charging or not charging).

Night vision in Apple Home (2026-10-16): `CameraStatus.nightVision.lightOn` is the lamp as the camera says (`NightVisionControl.currentLight()`,
asked with the mode when the camera starts and after the page switches it), else as last set from the bridge. A camera whose night vision can go
to both auto and off (`CameraRuntime.offersHomeKitNightVision`) gets Night Vision on its accessory's Camera Operating Mode
(`CameraController.setNightVision`, added at run time and kept from then on): it shows the camera (on unless the camera is in its day picture
with the IR lights off), a Home write turns the camera to auto (on; a camera already in night vision stays so) or off
(`CameraController.nightVisionWrites`), the page's changes reach Home, and a change the camera refuses puts Home back to what the camera does
(to what Home showed before when the camera cannot say; so does a write the runtime cannot follow, before the camera's night vision is known).
What Home showed before starts as the accessory's saved Night Vision (`CameraController.operatingState`, read when the accessory comes up), so
a write of the value Home already shows leaves it so.

## Additions beyond the contract: Change it by hand (2026-10-18, docs/CONTRACT_CHANGES.md)

Why a step of Set up for Camera Bridge, or a finding of the Security card, could not be done, and how to do it by hand (owner decisions,
2026-10-18). `Security/CameraManualHelp.swift`: `CameraFamily` (`hikvision` (and its OEMs), `reolink`, `tapo`, `ipcWebAPI` (Jennov and other
Anjvision cameras), `ipcamWeb` (the IPCamera Web family), `dahua` (Dahua, Amcrest, Lorex), `axis`, `hanwha` (Wisenet), `uniview`, `foscam`,
`vigi`, `xmeye`, `unifi` (standalone), `onvif`; `CameraFamily.of(_:webAPI:)`: the vendor, then the web API the camera's address showed in
this run (CameraAdapters' `CameraWebAPIFamily.seen(at:)`), then its maker and model (a Tapo, then the manufacturer containing "hikvision",
"annke", "reolink", "dahua", "amcrest", "lorex", "axis", "hanwha", "wisenet", "uniview", "foscam", "vigi" (the model too), "xiongmai" or
"ubiquiti", any case), then what an earlier setup kept), `CameraManualHelp` (`why`, one sentence; `places`, each `CameraManualHelp.Place`
with `app`, menu `path`, `action` and `confirmed`; `values` to set, `CameraManualHelp.Value` with `copy` for an address to type; `router`,
`note`, `then`; `caveat`, set by the init whenever a place is not confirmed; since 2026-10-19 `link`, `current`, `keep`, `reserve`,
`warnings`, below), and `CameraManualHelpText`, every word in one table like `InternetGuardText` (`CameraManualHelpText.Context`: the
bridge's time server and DNS address on the camera's network and its time zone in words, and since 2026-10-19 `webPage`, `cameraAddress`,
`currentDNS`, `addressing`, `ipv6On`; `CameraManualHelpText.caveat`; `CameraManualHelpText.step(_:status:detail:family:context:changes:)`;
`CameraManualHelpText.withHelp(_:family:context:)` for a `CameraSetupReport` or a `CameraSecurity`). Only `notSupported` and `refused` steps
get help, and none for the DNS or the time without the bridge's address. The why comes from the step's own detail where it says something (a
refused login, paused logins, no answer, an account that may not change it: "sign Camera Bridge in with an administrator account", the
camera's own words); a menu path is `confirmed` only when it was read on the camera's own pages or in its maker's documents (the IPCamera
Web family's page, the IP camera web API's page, TP-Link FAQs 688 and 4372, Reolink's UPnP and UID articles, and for the DNS the makers'
documents in the research's §4: Hikvision's manual 5.7.20, the AXIS OS help, Hanwha's KB, Uniview's manual V3.00, Foscam FAQ 243 and VIGI
FAQ 4741), and any other path or a general instruction carries "Menu names differ between models and firmware versions, so look for the
closest match." Watch also offers the router's way (a DHCP reservation with the bridge as the camera's DNS, which counts too but can change
when the router renews the address, and works only while the camera takes its DNS from DHCP, from its next renewal or restart; or blocking
the camera's internet) and "Then press Check again on the camera’s Security card."; UPnP and the cloud offer the router too. On the Security
card: UPnP or the cloud on or unreadable, the video or an extra service without a password, where `canChange` is false, and the Internet
guard's finding while `CameraSecurity.internetGuard` does not watch the camera because of its DNS (`CameraManualHelpText.GuardDNS`, from the
engine's last reading, `manualHelpGuardDNS`: it asks other servers and is not waiting for a restart that takes the bridge, or its DNS could
not be read; not while it already asks the bridge, nor while a listed camera's box isn't running). `CameraSetupStep.manualHelp` and
`CameraSecurityFinding.manualHelp` (init parameters, default nil) carry it; nothing in the engine sets them and they are never saved:
`BridgeEngine.withManualHelp(_:cameraID:)` (a report or a security result) and `BridgeEngine.withManualHelp(_:)` (statuses, the bridge's
interfaces and its zone read once) add it for a camera the setup works with, reached directly, and BridgeWeb's `EngineBackend` calls them
for the page's preview, run, check and statuses, never for a restore's report (its help would say how to make the change Restore is
undoing). The other steps of Hikvision, Dahua and Amcrest (their menus only in other people's guides) and of the makers added on 2026-10-19
(their menus not known), and the IP camera web API's OSD tab, get the general instruction with the caveat; their DNS menus are the table's
below (Hikvision's TCP/IP page confirmed, the Dahua family's a best guess); Reolink's cloud note says doorbell rings still come through
Apple Home only for a doorbell (`Context.doorbell`); where the camera has no place of its own (a Tapo's cloud and UPnP, the IPCamera Web
family's UPnP) the router's way is said as the way, not as another. `BridgeEngine.cameraFamily(_:)` keeps the web API family each camera's
address showed while the bridge runs (the clients forget it when the camera starts again).

Pointing the DNS at Camera Bridge by hand (2026-10-19, docs/superpowers/specs/2026-10-18-camera-dns-design.md, "What the person sees" 1):
each maker's menus from the research's §4 (`.superpowers/sdd/camera-dns-research.md`; confirmed: Hikvision's TCP/IP page, Axis, Hanwha,
Uniview's DNS page, Foscam and its Equipment Search Tool, VIGI, the Tapo app, the IPCamera Web family, the IP camera web API; best guesses
with the caveat: Reolink's DNS switch on its confirmed network pages, the Dahua family's (Amcrest and Lorex), XMEye on the recorder or in
CMS/VMS, a standalone UniFi camera; a camera of an unknown maker gets the general instruction). `link` ("Open the camera’s web page") is
the camera's configured address and web port (internal `webPageURL`: `http(s)://host[:port]/`, https where Camera Bridge reaches it so, the port left
out when it is the scheme's own; nil for a host that is not a plain name or address), never anything the camera says (ruling D1), on a help
that names the camera's web page, for a maker Camera Bridge knows (not a Tapo, not an unknown maker). The DNS help also carries `current`
(the servers the engine's last reading showed; empty in a setup report, whose change row says them), `keep` and `reserve`
(`CameraManualHelp.Keep`: address, mask, gateway; `CameraManualHelp.Reserve`: address, MAC; `CameraManualHelp.Link` for `link`) for a camera whose
DNS stays only with a fixed address (Hikvision, Foscam, VIGI, Tapo, the IP camera web API, XMEye, UniFi: the address, mask, gateway and
hardware address of a setup report's offer or fix, else the last reading's `CameraDNSReading.addressing` when it is of the address Camera
Bridge reaches the camera at, else that address alone; with none, the reservation as a warning), and `warnings` (both slots the bridge; IPv6,
"IPv6 is on: the camera may get DNS servers from your router over IPv6 too. Turn IPv6 off on the camera.", only while `Context.ipv6On`;
a restart the camera asks for; a recorder that runs the camera's network; a Tapo's factory reset). Uniview's note says to set its address
to static first, keeping it, and reserve it in the router, if it won't take the servers. The router's way says which routers can hand one
device its DNS (OpenWrt, pfSense, OPNsense, MikroTik, ASUS, Pi-hole), which only a whole network (UniFi, Synology, Firewalla) and which
can't (eero, Google/Nest Wifi, Deco, Orbi), and that it works only while the camera takes its DNS from DHCP (automatic), from its next
DHCP renewal or restart. `manualHelpContext` fills the context from the camera's configuration, its last DNS reading and, for `ipv6On`,
its last security check (which asks a camera whose DNS it read through ONVIF whether its IPv6 is on: CameraAdapters'
`CameraSettingsService.readIPv6()`, one `GetNetworkInterfaces`; kept with the check's record, never asked by the guard's own reads);
nothing here asks the camera. Tests: `CameraManualHelpTests` (every step and family
that can fail says why and where; the bridge's address; only the confirmed paths unmarked; the caveat; the why from the detail; one test per
maker's DNS; the link; what it asks now; keep and reserve; the warnings, IPv6's among them; the router; the families; the Security card; the guard's DNS help
only where the DNS is why; the page's fixtures, `linux/web-tests/support/manual-help-fixtures.json`, are the table's own words, written
again with `CB_WRITE_WEB_FIXTURES=1 swift test --filter CameraManualHelpTests`), `CameraManualHelpEngineTests`, and BridgeWeb's
`CameraManualHelpBackendTests` (the real `EngineBackend`: preview, run, check and status carry it, a restore does not).

## Additions beyond the contract: Set up for Camera Bridge (2026-10-16, docs/CONTRACT_CHANGES.md)

`BridgeEngine.cameraSetupPreview(cameraID:)` (reads only), `BridgeEngine.applyCameraSetup(cameraID:)` and
`BridgeEngine.restoreCameraSetup(cameraID:)` → `CameraSetupReport` (`CameraSetupStep`, `CameraSetupStepStatus`); `BridgeEngine.cameraSetupVendors`
and `BridgeEngine.cameraSetupTitle(_:)` (the step names, one table). `CameraConfiguration.setupBackup` (`CameraSetupBackup`) and
`CameraConfiguration.setupState` (`CameraSetupState`, with `currentVersion`: the setup's contents are versioned in code), engine-owned like
`cleanPictureBackup` and decoded leniently. The backup is saved before the first change; an earlier run's values, Optimize's undo and Clean
picture's backup are folded in (the oldest value wins), so there is one way back, and the Clean picture switch also restores from it. A
Reolink backup an earlier build saved with less than a run now changes is completed from the camera's values as read, for a run that
changes the step (`mergedSetupBackup`): a time zone kept as the daylight-saving switch alone (before 2026-10-18; that build changed only
the switch) gets the camera's `timeZone` and `Dst` rule, with the old switch as `Dst.enable` (`completedReolinkTimeZone`), and a time
source saved through ONVIF that names no server gets the camera's own server, port and interval (`completedReolinkTimeSource`), so Restore
puts back everything the run writes. Steps run
in order (time zone, time from the bridge, clean picture, streams, UPnP, cloud, video password, extra services, watch its internet); a refusal stops the run, the steps before it stay done, and only "Watch its internet" may still run after it (below); a step refused only because the account Camera Bridge uses may not make the change stops nothing (2026-10-18, below). The
streams step is the HomeKit optimizer's plan (`plannedEncoderFixes`, shared with `optimizeForHomeKit`), made from the codec the bridge really
receives (`CameraRuntime.readinessFacts`, counted only when the measured picture size is the stream's) as well as the camera's settings: a
camera whose settings say H.264 while it sends H.265 is planned as a codec change, written although the camera already names it
(`CameraEncoderEdit.rewriteCodec`), and the preview says what it sends. A changed stream restarts the camera's ingest; when the setup changed
a stream's codec it then watches the new ingest (`EngineTuning.cameraSetupMeasureWait`, 15 s, ending once the stream arrives as H.264) and
marks the streams step refused ("The camera says its main stream is H.264 but still sends H.265.") when it still arrives as something else
(`streamsCheckAfterSetup`, `streamsStillWrong`; nothing measured in time is not a failure, and the recording re-enable hint follows the
result). `BridgeEnvironment.servesTime` (the daemon sets it where chrony serves the local network) offers "Time from the bridge", at the
bridge's address on the camera's subnet. The cloud step is "Cloud off" (Hikvision's Hik-Connect, and the maker's cloud of an ONVIF camera that
speaks the IP camera web API, whose clean picture also goes through that API: docs/integrations/ip-camera-web-api.md); its restore passes the
saved `CameraFeatureBackup` (`setFeature(…saved:)`), which for those cameras holds the cloud's kind. Its sign-in value (the Authcode) is never
in the configuration (which reaches the page, its events and the Mac's backup files): the engine keeps it in the platform `SecretStore`
(`CredentialStore.setupCloudAuthcode(for:)`, account `camera.<UUID>.setup-cloud`), puts it back into the backup to restore, and deletes it once
a restore gave it back or the camera is removed (`forgetCamera` tries every secret even when one fails). A store that cannot be read fails the
cloud step and keeps the value for the next try.

## Additions beyond the contract: the internet guard (2026-10-17, docs/CONTRACT_CHANGES.md)

Camera Bridge OS's internet guard, Watch (docs/superpowers/specs/2026-10-17-internet-guard-design.md): the box answers a watched camera's DNS
with "does not exist" and keeps what it asked for. `BridgeEnvironment.hasInternetGuard` (the daemon sets it on Camera Bridge OS, where the
guard is installed; never on the Mac), `BridgeEnvironment.setGuardedCameras` (replaces the whole list of `GuardedCamera`, an `address` on the
local network and a `GuardLevel`, only `watch` so far; an empty list turns the guard off; throws a sentence) and
`BridgeEnvironment.guardReport` (a `GuardReport`, nil while the box has none): `available`, `running` (its DNS answers now), `timeZone` and
`todayStart` (today is counted in the bridge's time zone, to the hour), `updatedAt`, and per watched camera a `GuardReport.Camera` (`address`,
`level`, `since`: watched without a break since then, nil when the box does not say, `today`, `last24h`, `names`: `GuardReport.Lookup` `name`,
`count`, `first`, `last`, the last 7 days' names, most asked first, at most 50; since 2026-10-19 `local`: its questions that never leave the
home network in those 7 days, counted, never named, 0 from an older box; `GuardReport.camera(at:)`). `GuardReport.unavailable` is the report of a system without the guard. The report is read leniently (the root
side writes it): a missing or odd field gets its default, a level this build does not know is nil, a camera without an address is left out.

## Additions beyond the contract: camera security levels (2026-10-17, docs/CONTRACT_CHANGES.md)

Each camera's security level (owner decision, 2026-10-17), from what Camera Bridge can read. `CameraSecurity` (`level`, `title`, `summary`,
`findings`, `checkedAt`) and its pure `CameraSecurity.assess(_:cloudModel:internetGuard:checkedAt:)`; `CameraSecurityLevel` (`red` "Outside
access possible", `yellow` "Needs work", `green` "Good", `gold` "Local only"; `Comparable`, red lowest; `title`); `CameraSecurityFinding`
(`feature`, `state`, `level`: the best level the finding leaves, `sentence`, `canChange`, `linked`, `service`); `CameraSecurityFeature`
(`RemoteAccessFeature`'s cases and `internetGuard`); `GuardEvidence` (`watched`, `outsideLookups24h`, `lastLookupNames`, `available`: what the
Internet guard saw, nil without a guard, so green is the best there; `listed`: it is on the guard's list here (its Watch done, or its DNS
read pointing at the bridge), `asksBridge`: the camera's DNS as last read is the bridge's address now, nil when not read, `dnsFromRouter`: those
servers came from the router's DHCP, `watchedFor`: how long the box has watched it without a break, nil when it
does not say, `waitsForRestart`: the step was taken "after the camera restarts" (ISAPI `statusCode` 7: "The camera takes Camera Bridge as its
DNS server when it restarts."); since 2026-10-19 `localLookups` (init parameter, default 0: the box's `local` count) and `lookupSeen` (a
name it blocked in the box's week, or a local question: the box saw the camera ask it); the init's `listed` defaults to `watched` and
`asksBridge` to true for a watched camera; `GuardEvidence.quietDay` 24 h; `GuardEvidence.noLookupsSeen`);
`CloudDependentModels.brand(integration:manufacturer:model:)` (Wyze and eufy through their plugins; Ring, Google Nest, TP-Link Tapo (also a
maker "tp-link" with a model that is not VIGI, as Tapo's ONVIF names itself), Blink, Arlo, SimpliSafe by integration or maker: red, and never
asked). Red: the cloud on and linked or of unknown link, UPnP, DDNS or RTMP on, a cloud-dependent model. Yellow: the cloud on but not linked
or unknown (a camera without a reader), video (or another service, named) without a password, watched and still looking up internet names.
Green: none of that, but an unknown, another service on, no guard, not watched, a camera that no longer asks the bridge or whose DNS could
not be read, or watched for less than a day ("has watched it for 2 hours and seen no internet lookups yet"), or (since 2026-10-19) watched
for a day by a box that never saw it ask anything: "No lookups seen yet; Camera Bridge can’t rule out a built-in DNS server." (silence is
no proof: a camera with a DNS server of its own is quiet too; research §5, spec docs/superpowers/specs/2026-10-18-camera-dns-design.md,
"What the person sees" 3). Gold: all confirmed off or absent, the video locked, watched for a full day without an internet lookup, and at
least one lookup seen from the camera in the box's last 7 days, any name, local ones included (`GuardEvidence.lookupSeen`). The guard's finding says "doesn't watch this camera" for a camera not on
its list whatever the box's state (a box watching no camera has its DNS off), and "isn't running" only for a listed one; a watch on DNS the
router gives adds that the router can change it (`CameraSecurity.dnsFromRouterNote`).

`BridgeEngine.checkCameraSecurity(cameraID:)` checks now (a check under way is joined; `CameraSecurityCheckTooSoon` with
`retryAfterSeconds` within a minute of the camera's last check; not the demo camera; `CameraOfflineError` for a camera known unreachable or
that stopped answering during the check, whose last result then stays) and `BridgeEngine.guardEvidenceChanged()` works every level out again
from the last readings with the guard's evidence, without asking the cameras and keeping the readings' `checkedAt` (it runs at every poll of
the box's report; the status is refreshed only when something changed). `CameraStatus.security` holds the last result (nil until the first check; in memory only). A check reads
`CameraSettingsService.readRemoteAccess()` with the camera's credentials and sends one RTSP `DESCRIBE` without credentials to the configured
sub stream (else the main, the vendor's usual one, or the address the running ingest got: `CameraRuntime.rtspAddresses`), never for a camera
behind a helper or a console. The DNS servers of every camera the Internet guard can watch are read too (`CameraSettingsService.readDNS()`,
`readsGuardDNS`: also one whose Watch is not done, and one of a cloud-dependent model, whose other readings are not asked; kept with the
readings as `CameraDNSCheck`, and a read that gives none keeps the last reading): the reading decides whether the camera is watched, and the
guard's gold rests on the camera asking the bridge's address now (the internet guard in the engine, below). It runs
`EngineTuning.securityCheckDelay` (60 s) after a camera's runtime starts (unless checked within `securityCheckFreshness`, 10 min), every
`securityCheckInterval` (24 h), right after "Set up for Camera Bridge" ran or was restored, and on "Check again" (`POST cameras/:id/security/check`);
a camera unreachable at its time, or that stopped answering during the check (`CameraSettingsService.remoteAccessUnanswered`), is tried again
after `securityCheckRetry` (10 min), doubling up to `securityCheckRetryCap` (2 h), and keeps its last readings meanwhile. It never writes to
a camera, and holds the engine's operations only to save what a DNS reading changed about the camera's watch. `EngineTuning.testing` turns
the scheduled ones off (`securityChecks`); `securityReading` (nil: the camera did not answer), `securityDNS` (nil: not readable; what it
throws: the read's error, a login pause or a refused login), `rtspAccessProbe` and `guardEvidence` replace the readings in tests, and
`guardEvidence(for:dns:)` is where the Internet guard's report goes in.

Set up for Camera Bridge's new steps (the IPCamera Web family: docs/integrations/ipcamera-web.md): "Video password" and "Extra services off"
(`cameraSetupTitle`), after UPnP off and Cloud off (a refused step stops the steps after it, but for a change the account may not make, and these are not yet tried on many cameras),
their values in `CameraSetupBackup.videoPassword` / `extraServices`; other cameras show them "not offered for this camera"
(`CameraSetupStepStatus.notOffered`).

## Additions beyond the contract: the internet guard in the engine, Watch (2026-10-17, docs/CONTRACT_CHANGES.md)

Stage 1 of docs/superpowers/specs/2026-10-17-internet-guard-design.md (owner's answers, 2026-10-17: the name "Internet guard", the levels
"Watch" and "Seal", Watch on by default in Set up for Camera Bridge, Seal always its own choice, every lookup blocked at once). The words are
one table, `InternetGuardText` (`name`, `watch`, `seal`, `watchStep` "Watch its internet", `sealStep`, `notOnThisBridge`, `notOnItsNetwork`;
`GuardLevel.title`). Seal is not built: nothing sets it.

- **The step.** `CameraSetupStepID.internetWatch` ("Watch its internet", last, after the cloud and the IPCamera Web family's steps, so a camera
  that refuses it still gets every other step and Restore puts its DNS back first; part of every run like "Cloud off") points the camera's DNS
  at the bridge's address on the camera's own network (`CameraSettingsService.readInternetWatch(server:)`,
  `applyDNS`, `restoreDNS`; the preview row "DNS": "8.8.8.8 and 1.1.1.1" → "the bridge (192.168.77.2)"; the backup `CameraSetupBackup.internetWatch`).
  It is offered only where the bridge has the guard (`BridgeEnvironment.hasInternetGuard` with `setGuardedCameras`) and has an address on the
  camera's subnet (`bridgeAddress(onNetworkOf:interfaces:)`, no fallback, unlike the time source); otherwise not offered, "Camera Bridge OS
  watches cameras’ internet; this bridge does not." or "Camera Bridge can watch only cameras on its own local network." A restore that gives
  the DNS back marks the step's record `restored`.
- **"Fix its address so the DNS stays"** (2026-10-18). For a camera whose DNS only stays with a fixed address, the preview's step carries the
  offer (`CameraSetupStep.fixAddress`, off unless chosen; read against the camera's address as the guard knows it, `guardCameraAddress`, and,
  for an ONVIF camera, offered only after a run whose Watch it refused for its own reasons, `watchRefusedLastRun`).
  `applyCameraSetup(cameraID:options:)` takes the person's choice (`CameraSetupOptions`: `fixAddress`, with `shownAddress`, the address the
  preview showed): the step then changes the address as it is and the DNS (`chooseFixAddress`), the backup records the address it fixes
  before anything changes (`keepingFixedAddress`, never the hardware address), and the adapters write nothing when the camera's address is
  not the shown one any more. A run that fixed it says so in its step (`CameraSetupStep.fixedAddress`, with the hardware address, for the
  router reservation); Restore puts DHCP back. A fix refused before anything about the address changed (`CameraSetupOutcome.addressUntouched`)
  takes the address this run saved back out of the backup, so Restore and removal don't wait on it. Without the choice nothing about the
  address changes.
- **"Restart the camera now"** (2026-10-18). Camera Bridge restarts a camera only when the person presses it.
  `BridgeEngine.offersCameraRestart(_:)` says whether it is offered: a step of the setup's last run was done "after the camera restarts" (a
  Hikvision's ISAPI `statusCode` 7, ONVIF's `RebootNeeded` after a fixed address: `needsRestart`) and the person has not restarted it since
  (a reading of its DNS is no proof of a restart, and a new run's record replaces the flags). `BridgeEngine.restartCamera(id:)` restarts it
  (`CameraSettingsService.reboot()`, one request, under the engine's operations) only then, else throws `CameraRestartNotNeeded` before
  anything is sent; once the camera took it no step waits any more, and its DNS is read again `guardDNSReconnectDelay` later. BridgeWeb's
  `POST cameras/:id/restart` and the camera resource's `restartOffered` carry it.
- **After a refused step.** The steps after a refused one are not run, but this one still is whenever it is offered and was read (a
  camera's DNS is another setting, and its read in this run just took the login it needs): streams that "didn't stick" no longer keep a
  camera's DNS from the guard. It is not run, with why (`watchHeld`, the step's detail and the log), after a refusal that says the camera stopped
  answering (`CameraReachability.isUnreachable`, or every encoder method without an answer) or refused the login of the API the DNS step goes
  through (ISAPI on a Hikvision with the address document, Reolink's own API on a Reolink that shows its `LocalLink`, else ONVIF, whose
  account the IP camera web APIs share; `CameraSetupLogin`), or of one the engine can't tell (clean picture and the streams try several):
  another refused login can lock the camera's logins, and ONVIF's are paused for 2 minutes after one anyway. A login refused for another API
  (ISAPI against ONVIF, Reolink's own against ONVIF) does not hold it; a Reolink's time zone, time source, UPnP off and Cloud off go through
  its own API (`setupLogin`: the backup paths "reolink:Upnp" and "reolink:P2p" are Reolink's login), as its DNS does, so a login refused there
  holds Watch (ReolinkAPI keeps no block after a refused login: Watch would log in again with the refused password).
- **A change the account may not make** (owner decision, 2026-10-18). `CameraAdapterError.notPermitted` (the camera signed the account in,
  then refused it the write, as the Reolink doorbell's ONVIF refuses `SetNTP`), or Reolink's `GetAbility` saying the account may not change
  it before anything is sent, is the camera's answer about that change alone, not a refused login: no login pauses, the step reads "the
  account Camera Bridge uses may not change this; use an administrator account in the camera’s settings" (`setupReason`, `readableReason`;
  the streams step when every method was refused that way, `streamsRefusal`; clean picture when every way was), and the run goes on: every
  step after it still runs, Watch too. The IPCamera Web family's 532374 ("No Privilege") is one too, at a write and at the sign-in (its
  steps then say the family's words, which also say to use an administrator account). It is carried typed, never by the words:
  `CameraSetupOutcome.notPermitted` (`BridgeEngine.refusal(_:)` for a step that threw it, by `CameraAdapterError.isNotPermitted`;
  `encoderNotPermitted` for the streams, `CleanPictureChange.notPermitted`). Any other refusal stops the steps
  after it that would change something, as before; the report's `stoppedAt` is the first such step (nil when only changes the account may
  not make were refused).
- **Who is watched** (`internetWatchDone`), so the box watches its address: the camera's DNS points at the bridge, as the newest of the
  step's result and the guard's readings of its DNS says, whoever changed it (owner decision, 2026-10-18: the owner on the camera, its
  router's DHCP, or the setup). `CameraSetupState.watchedServer` (decoded leniently, nil when absent) is the bridge's address once the step
  is done or already right, nil once it is refused, not run or restored; a run keeps the value it starts with until the step has its result
  (no list without the camera is sent meanwhile, so the box's `since`, which lasts only while it is listed, is kept) and when it could not
  read the step (not supported or not offered this time). A reading sets it or clears it too (below). A record saved before that field
  counts when its last record of the step is done or already right, so a camera an older build watched stays listed, also through a run
  that takes the step again (the run's carry-over gives it the bridge's address), until a reading finds it asking other servers. A camera
  never set up keeps a reading's watch in `CameraConfiguration.dnsWatch` (`CameraDNSWatch`: `server`, the bridge's address it points at, nil
  when it asks others; `setupStarted`, the setup record it was read against, nil without one; engine-owned like `setupState`, carried over
  by `updateCamera`, decoded leniently), so it grows no setup record and the page still says it is not set up; a reading of other servers
  against a setup record keeps `CameraDNSWatch(server: nil, setupStarted:)` there (an older build's record has no `watchedServer` to clear),
  and a watch read against a setup record Restore has cleared is none. The DNS servers the setup keeps to give back
  (`CameraSetupBackup.internetWatch`) are no proof: they are saved before the step runs and kept when the camera refuses it (a camera can
  take part of a change, such as the first of its two DNS servers), for Restore and for giving them back on removal. A camera being removed
  whose servers are kept gets them back first, whether or not it is watched (`giveDNSBackOnRemoval`, best effort, logged "its DNS may still
  point at Camera Bridge" when the camera doesn't take them; one watched by a reading has none kept: "its DNS still points at Camera Bridge
  (set on the camera)"; `EngineTuning.restoresWatchOnRemoval`, off in `EngineTuning.testing`). A stored `CameraSetupState` with a step or
  status this build does not know keeps its other records.
- **The camera's DNS, read** (2026-10-18). The guard reads the DNS servers of every camera it can watch (`readsGuardDNS`: the bridge has
  the guard and an address on the camera's network, and reaches the camera directly through Hikvision's, Reolink's or Amcrest's API or ONVIF;
  whether its Watch is done does not matter, and a cloud-dependent model such as a Tapo is read too). A reading
  (`watchAfterReading`, pure; saved under the engine's operations, so the box's list follows the save) watches a camera whose DNS points only
  at the bridge (`CameraDNSReading.pointsAt`, DNS the router gives included; a Reolink on automatic DNS by the servers ONVIF says DHCP gives,
  never by the slots its `LocalLink` keeps): it joins the list then, and the box's
  `since` starts there; one that asks other servers ends the watch, and the camera leaves the list (the setup's record of what it did and its
  backup stay). Logged "Doorbell: its DNS points at Camera Bridge, so the Internet guard watches it" and "… no longer points at Camera Bridge,
  so the Internet guard no longer watches it". A read that gives nothing (the camera does not show its DNS, did not answer, or the read met a
  login pause) changes nothing, and the camera's evidence keeps its last reading; so does a reading that does not know which servers the
  camera asks (`CameraDNSReading.serversUnknown`, `GuardDNSRead.serversUnknown`: a Reolink on automatic DNS whose ONVIF did not say which
  servers DHCP gives, as a Wi-Fi doorbell's often times out), not to be confused with one that knows DHCP gives none, which ends a watch.
  Its login worked, though: it lets the guard's own reads of a camera whose login was refused go on. Nothing changes for a reading taken
  before the setup's last run ended (the run's result is newer), nor while a Watch taken "after the camera restarts" still sees the
  servers the setup saved. A
  reading the camera's setup changed under (`setupChanged`: its setup record or backup is not what it was when the read began, because a
  setup run or a restore saved meanwhile, also while the reading waited for that operation to save its own change) is no evidence either:
  `recordGuardDNS` saves nothing, and `settleGuardDNS` reads the camera again (at most twice more), so the evidence and the watch rest on the
  camera as the run or the restore left it; the check right after a run or a restore (`scheduleSecurityCheck(fresh:)`,
  `runSecurityCheck(startedAfter:)`) waits for a check that began before it instead of joining it. A full Restore also clears a watch a
  reading made (`dnsWatch`), and a reading with a setup record that finds the bridge leaves the watch to the record. When:
  in each security check (above), right after "Check again" (`POST cameras/:id/security/check`, 60 s cooldown); by itself (`readGuardDNS`,
  only the DNS: what the camera lets out is not asked, and the camera's level is worked out again with the newest reading,
  `reassessSecurity`) every `EngineTuning.guardDNSInterval` (30 min) for each enabled camera, one after the other (`interval / count` apart,
  `startGuardDNSReads`, from `startInternetGuard`; a camera read in the last half interval is skipped), `guardDNSReconnectDelay` (2 min) after a
  camera comes back online after it went offline (`noteGuardConnections`, from the status loop; a reconnect alone, such as an on-demand
  camera's wake, and its first time online after the bridge starts are no return), and `guardDNSPauseMargin` (5 s) after a login pause a read
  met ends (`CameraAdapterError.loginsPaused` or `.lockedOut`); those two (`scheduleGuardDNSRead`) no sooner than `guardDNSSpacing` (5 min)
  after the camera's last read (a camera whose stream keeps dropping is read at most that often: a Reolink's read is a login of its own), not
  at all when a read happened since they were asked for, and returns close together share one read. No read runs during that pause, also not
  on "Check again" (`GuardDNSRead.paused`; a read that met it sent nothing and is no read for the spacing). A read whose login the camera
  refused stops the guard's own reads of that camera, those after a return or a pause too, until a read works (each would be another wrong
  password).
  These reads are scheduled only while the bridge runs and `EngineTuning.securityChecks` is on; a read shares the security check's
  `CameraSettingsService` when it is part of one, and is one `readDNS()` with a service of its own otherwise. Removing a camera forgets its
  reads (`forgetGuardDNS`).
- **The list.** Every watched camera, by its local IPv4 address (`guardAddress`: 10/8, 172.16/12, 192.168/16, 169.254/16, as the box
  checks), level `watch`, once each (`guardedCameraList`). It is sent with `BridgeEnvironment.setGuardedCameras` when the bridge starts
  and whenever a saved configuration changes it (the step applied or restored, a reading that watches a camera or ends its watch, a camera
  removed or moved: `syncInternetGuard`, called by the engine's save). It never holds the setup: a refusal is logged and sent again after
  `EngineTuning.guardSyncRetry` (5 s), doubling up to `guardSyncRetryCap` (5 min), until the box takes it or a newer list replaces it. A
  report that lists other cameras than the list the box took sends the list again (the box's job can end with an older list's result).
- **The evidence.** While the bridge runs the box's report (`BridgeEnvironment.guardReport`) is read every `guardPollInterval` (1 min,
  `pollGuardReport`), and every level is worked out again (`guardEvidenceChanged`: the report may have changed, a day of watching passed, or
  the bridge moved to another address). `GuardEvidence` gains `today` and `names`; a camera is `watched` when it is on the list here, the box
  watches its address and the camera's DNS, as last read, is the bridge's address on its network now (`asksBridge`), and the report is
  evidence (`available`) only while the box has the guard, its DNS answers and the report is younger than `guardReportStaleAfter` (10 min)
  (`guardEvidence(address:listed:asksBridge:waitsForRestart:dnsFromRouter:report:fresh:now:)`); `watchedFor` comes from the box's `since`.
  `GuardEvidence.dnsFromRouter` (init parameter, default false): the reading's servers came from the router's DHCP; a camera watched on them
  says "Its DNS servers come from your router, which can change them when it renews the camera’s address." (`CameraSecurity.dnsFromRouterNote`).
  `lastLookupNames` are the last 24 hours' names, newest first. Names are shown as `GuardNames.shown` has them: a part that looks like a
  camera's id (12 or more letters and digits, 4 or more digits) becomes "*". `CameraSecurity.internetGuard` (`CameraGuardActivity`: `watched`,
  `today`, `last24h`, `names`, at most 10, most asked first; nil without a guard) is `status.security.guard` on the web API.
- **Alerts (2026-10-22: notifications).** There is no daily notice any more: a blocked lookup of a watched camera is the guard working, and it
  counts in the camera's favour (`CameraSecurity.guardFinding`: it never lowers the level; gold still needs a full day watched and a lookup
  seen, and a blocked one is one). `BridgeEngine.internetGuardAlerts` (`InternetGuardAlert`: `cameraID`, `cameraName`, `kind`, `date`) holds
  what needs the person: `.firstTry` (a watched camera the box has seen ask for an outside name, now or in its last 7 days: "Patio New tried
  to reach the internet", "Camera Bridge blocked it. Nothing got out.", once per camera: the web layer's notification log never logs the same
  event twice) and `.stoppedAsking` (a camera the guard watched at the last report and does not now: a warning, until it is watched again).
  `CameraGuardActivity.last7d` is the 7-day total behind "Blocked 12 attempts today, 340 in the last 7 days. Nothing got out." A lookup the
  guard did not block is not raised: the box's report does not say.
- Tests: `EngineTuning.guardCameraAddress` stands a loopback fake camera for one at 192.168.77.x; nothing else of the guard runs unless the
  test's environment has it. `EngineTuning.securityDNS` stands for the cameras' DNS (it may throw the read's error), and the reads' times are
  shortened through `guardDNSInterval`, `guardDNSReconnectDelay`, `guardDNSPauseMargin` and `guardDNSSpacing`.

## Additions beyond the contract: credentials in stream URLs (2026-10-18, docs/CONTRACT_CHANGES.md)

Some cameras take credentials in their stream URL's query (`?user=admin&password=…`, a password `hash=`, a `token=`; an ONVIF
`GetStreamUri` answer can carry them) or path (XMEye `/user=admin&password=…&channel=1&stream=0.sdp`, its `_`-joined variant,
`;pwd=…`). They are kept like the password:

- **Saved without them.** `addCamera` and `updateCamera` move them to the secret store (`CredentialStore.storeStreamCredentials(of:)`,
  account `camera.<UUID>.stream-urls`: `{"main": "<URL>", "sub": "<URL>"}`) before saving; `configurations`, `config.json`, backups,
  the web API and the diagnostics report have the URLs without them (`URL.removingStreamCredentials`). An address saved again as
  shown keeps what is stored for it; a new address without credentials drops them (they never go to another address); credentials
  typed into an address replace the stored ones and restart the camera. A secret store that refuses them fails the save. Removing the
  camera deletes them (`forgetCamera`).
- **Moved on load.** A `config.json` that has them (earlier builds kept them in the URL) is rewritten without them when it is loaded
  (`movingStreamCredentials(of:to:store:log:)`, in `init` and in `ensureLoaded`), once each camera's are stored. A camera whose
  credentials the secret store cannot take keeps its URLs as they were, so it still connects, and the next load tries again. The
  move is logged by camera name, never with a URL.
- **Sent only when connecting.** `streamCredentials(for:)` gives the stored URLs whose address is still the camera's to its runtime
  (`CameraRuntime.init(configuration:credentials:streamCredentials:dependencies:)`: the ingest's `RTSPConfiguration`s and the driver
  through `CameraDrivers.make(…, streamCredentials:)`) and to `probeCamera(_:password:)`; `RTSPClient` puts them into its request lines
  only. The RTSP access check of the security check asks the address without them, as before with no credentials at all.
- In the path, the saved URL loses each credential assignment and keeps the rest of its segment (`/channel=1&stream=0.sdp`,
  `/channel=1_stream=0.sdp`, `/snapshot.cgi`); a segment that was only credentials goes. `Redact.url` keeps masking only the secret
  values there (a path's `user=admin` shows in logs, as before).

## A camera that is turned off (2026-10-22, docs/CONTRACT_CHANGES.md)

A camera with `isEnabled == false` has no `CameraRuntime`: no ingest, events, recording or AI. Before, it had no HomeKit accessory either (Home
showed it as not responding). Now `CameraOffAccessory` (Runtime) keeps the accessory published, on the camera's port and in its own HAP store,
so Home keeps the camera, its room, automations and pairing:
- **Snapshots** are the "Camera off" still (`CameraOffStill`: `MediaCodecs.cameraOffJPEG`, exactly the size Home asks for, clamped to 16...4096,
  made once per name and size, the newest 8 kept). A rename (`rename`) shows in later pictures.
- **Live view** fails the way an offline camera's does: `setStreamingAvailable(false)`, and a request that comes anyway is refused. The still is
  not streamed as video (`makeSyntheticSource` could, but it needs the whole RTP pipeline for a picture that does not move).
- **Sensors** stay quiet: the controller is never registered on the event router, and its sensor status is not active.
- **HomeKit Secure Video** records nothing: the recording delegate refuses every stream.
Started with the bridge, on add and on update (`startOffAccessories`); `stopRuntime` and `stopServices` stop it. Turning the camera on stops it
and starts the runtime (same port, no bridge restart). Not done: no retry after a failed start, and no re-advertising after a wake.

## Additions beyond the contract: a maker's own interface (2026-10-23, docs/CONTRACT_CHANGES.md)

`probeCamera` for a camera added as ONVIF with credentials asks `CameraDrivers.ownInterface` (CameraAdapters README) once ONVIF accepted the credentials, or did not answer: a camera that answers Hikvision's ISAPI (also ANNKE and other OEMs), Reolink's or Dahua's API is probed as that vendor and returned with `CameraProbeResult.usedOwnInterface`, the manufacturer (ONVIF's name when the interface gives none) and the model. A wrong password stops at ONVIF (one failed login, the other interfaces are not asked); a refusal at the maker's interface leaves the ONVIF answer. `EngineTuning.findOwnInterface` replaces the check in tests (`EngineTuning.testing` answers none).

## Additions beyond the contract: a removed camera's Apple Home pairing (2026-10-24, docs/CONTRACT_CHANGES.md)

Removing a camera no longer deletes its Apple Home identity: `removeCamera(id:)` keeps it for 30 days (`RemovedHAPIdentities`,
`Credentials/RemovedHAPIdentities.swift`). `CredentialStore.forgetCamera(_:dataDirectory:keepingHomePairing:serialNumber:mac:now:)` (the
new parameters default to the old behaviour) still deletes the password, the stream URLs' credentials and the setup's cloud sign-in, and with
`keepingHomePairing` moves `<data>/hap/<id>/` (its pairings, `state.json`) to `<data>/hap-removed/<id>/` with a note, `removed.json`
(`RemovedHAPIdentity`: `cameraID`, `removedAt`, `serialNumber` and `mac` when known; the engine passes the configuration's serial number, and
keeps no MAC), and the identity (device ID, setup code, long-term keys) from the secret store's `hap.<id>` to `hap-removed.<id>`. Nothing is
deleted; a failure leaves the identity where it was (logged). `addCamera` asks `CredentialStore.restoreHomePairing(for:serialNumber:mac:dataDirectory:now:)`
under the identity lock before the camera's accessory starts: the same camera (`RemovedHAPIdentity.isSameCamera(id:serialNumber:mac:)`:
the same serial number, MAC or id, and no known serial number or MAC that differs) removed less than `RemovedHAPIdentities.keptFor` (30
days) ago gets that identity and those pairings under its new id, so Home sees the old accessory again (the entry with the same id first,
then the newest); a camera that already has an identity keeps its own. `CredentialStore.sweepRemovedHomePairings(dataDirectory:now:)`
(`RemovedHAPIdentities.sweep`) deletes entries 30 days old or older, at the engine's start and then daily (`EngineTuning.removedPairingSweepInterval`).
Public: `RemovedHAPIdentity`, `RemovedHAPIdentities.keep(cameraID:serialNumber:mac:dataDirectory:secrets:now:)`, `.restore(…)`, `.sweep(…)`,
`.keptFor`. Tests: `RemovedHAPIdentitiesTests`, `RemovedCameraPairingEngineTests` (macOS).

## Additions beyond the contract: the sky detector's geometry (2026-10-25, docs/CONTRACT_CHANGES.md)

The sky detector's maths is portable Swift in `Sky/` (Foundation's math and `SIMD3` only). Public: `SkyDirection` (azimuth from true north,
clockwise, and elevation, in degrees) and `SkyLogView` (`night`, `day`), for the web interface later. Internal:
- `SkyGeometry.swift`: `SkyObserver` (the box's location, kept on the box; it prints, dumps and debug-prints as "location hidden") and `SkyMath`: separations, the Julian date, Greenwich mean
  sidereal time, right ascension and declination to a direction, and a WGS84 position to a direction and range (Earth-centred, then
  east-north-up, so the Earth's curve counts).
- `SunEphemeris.swift`: the Sun within 0.01° (Meeus, chapter 25), sunset and sunrise at an elevation of −0.833° and darkness below −6°;
  `SkyNight` names each night after the local date of its sunset and finds its window to the next sunrise (one window across midnight and
  a daylight saving change; none on a day the Sun does not set). A moment belongs to the night that contains it or, in the day, to the
  one that ended that morning. A log's night view runs from sunset to sunrise, and its day view is the local day it is named after.
- `SkyCameraModel.swift`: how the camera's original picture (never the straightened one) maps to the sky. A single lens, or a dual camera
  (two lenses side by side, stitched on the camera; the default for pictures 2:1 and wider) split at a seam (x = 0.5 to start), each half
  a camera of its own: its own projection (rectilinear, equidistant, cylindrical or equirectangular, chosen by the fit), pose, fields of
  view, principal point and Brown radial distortion (k1, k2, k3), with nothing shared between the halves; a single lens has the same
  choice. What projecting needs is worked out once per lens, not per projection. Large radial terms bow the halves' seam columns in
  opposite directions, so a track crossing the seam is matched across it by direction, with an angular tolerance (about 3°). A direction projects through every lens that sees it (both near the seam, where the halves
  overlap); a pixel maps back through the lens of its half; a band of 1 % of the width around the seam is low trust, kept but not used
  for fitting. A dual card's lenses (`initial`) are the housing (facing, tilted up by the card's tilt) turned 45° to each side about the
  housing's own up, so the halves meet all down the seam at any tilt: the camera stitches its picture in its own frame, which tilts with it.
  (Beta 0.1.125 turned them about the vertical instead, which kept them level but left North Sky's upper sky 20–30° off, its bright stars
  9–30° from that card and 3–11° from this one, so planes up there could not match at the rough aim.)
  Tests: `SkyGeometryTests`, `SkyCameraModelTests`.

## Additions beyond the contract: the sky detector's aim (2026-10-25, docs/CONTRACT_CHANGES.md)

How a sky camera's aim is fitted to what it sees, in `Sky/` (Foundation's math and `SIMD3` only). Public: `SkyAimQuality` (`rough`, `good`,
`precise`) and `SkyAimStatus`, the card's aim line: the quality, the planes and stars matched, the residual (the inliers' RMS in pixels of
the original picture), when, each lens's own (`SkyLensAimStatus`), and a note such as "The camera seems to have moved; aiming again." (a
status without `lenses` or `note` decodes with none). Internal:
- `SkyAim.swift`: `AimCorrespondence`, a pixel of the original picture and the sky direction really there (a plane's from the feed, a star's
  from the catalogue), and `AimFit`, the fitted model with the stage, quality and residuals of the camera and of each lens.
- `AimFitter.swift`: each lens is fitted on its own, to the matches it owns outside the seam band. RANSAC (200 samples of 3, the rotation
  alone, by Horn's method), then Levenberg–Marquardt (at most 50 iterations) on the pixel errors, with Huber weights (δ 3 px), a ridge prior
  on the correction terms and small rotations of the lens's own axes, so a lens looking straight up fits like any other. A pixel error past
  a quarter of the width, or a direction with no point, is an outlier with no weight, never a huge squared error. The inliers are judged
  again at the tolerance the residual earns (0.75°, 1.5° or 15°); one that would cost the lens its stage tries 1.5°, then takes the lower
  stage, 1.5° before 15°, and never down to stage 0; a lens whose matches mostly disagree at its previous tolerance tries the next looser one.
  Stages free the pose and the field (1: 8 matches of 5 objects), the principal point and k1 (2: 40 of at least 8 objects, aircraft and
  stars, with 10 in each quadrant of the lens's frame, or in 3 of them for a dual camera's lens, whose outer bottom corner is usually
  ground), k2 and the vertical field (3: 150 over 6 of the 9 cells of a 3×3 grid) and, for a single lens only, k3 (4: 300). From stage 2
  each lens's projection is chosen by the lowest robust residual, the one it has kept unless another is more than 10 % better. A lens's fit
  is accepted when 60 % of what it saw agrees (each star match once, each aircraft once by at least half of its samples), its RMS is at most
  1.1 × the previous aim's on them, and its frame is sane (no fold; for a dual camera's lens, no correction moving the picture by more than
  3 % of its width); otherwise, and while it has too few matches, it keeps its earlier aim. Good is within 0.8°, precise 25 star matches
  whose own RMS is within 0.15°; the camera's quality and stage are its least aimed lens's. `matchTolerance` (rough 15°, good 1.5°,
  precise 0.75°) is for the matchers.
- `SkyAimStore.swift`: `<data>/sky/<camera-uuid>/aim.json` and `matches.jsonl` (0600 in 0700; a line that does not parse is skipped). They
  stay on the box: the matched directions with their times tell where the box is, so they are never logged, sent or exported. One pass of
  an aircraft (its samples in one `add`) keeps at most 12 samples, each 1° from the others; the latest 2,000 matches of each source are
  kept, planes for 30 days; a refit happens at most once per 10 new matches or per hour. 10 plane matches in a row each more than 3 × the
  fit's plane RMS and half their lens's match tolerance off (one aircraft's samples counting once) start the aim again; a fit with no plane
  matches judges none. A fit runs on a thread of its own, outside the cooperative pool, while the store answers with the aim it had.
- `SkyCameraModel.Lens.undistortedRadius` falls back to a bracketed search where Newton's ten steps do not settle (steep or wavy terms far
  out, or next to the fold), and `localPoint(ofUnit:)` projects a direction given as its unit vector. Tests: `SkyAimFitterTests`.

## Additions beyond the contract: the sky detector's lights (2026-10-25, docs/CONTRACT_CHANGES.md)

Finding and following the lights that cross a sky camera's view, in `Sky/` (Foundation's math and `SIMD3`, and MediaCore's `GrayImage`).
Public: `SkyPathShape` (`straight`, `curved`, `suddenStop`, `sharpTurn`) and `SkyMeasures`, a track's measures on the sky (where it was
first and last seen, duration, speed in °/s and its acceleration, turn rate and largest turn within a second, straightness, shape,
size in degrees, brightness, blinking and its rate, focus; and, since the rules of 2026-10-26, optional: `strobePeriod` and `strobeStrength`
(a regular flash like a plane's strobe), `seenShare` (the share of its pictures it was seen in), `wobble` (degrees off a smooth path) and
`turns` (turns of 45° or more); nil in an entry logged before them): never a real size, distance or speed. Internal:
- `SkyFrameAnalyzer.swift`: `SkyFrameAnalyzer` (owned by one detector actor, its buffers allocated once per picture size) compares each
  analysed picture with a running mean of the sky (5 % a picture), smooths the difference by a 3×3 kernel (a matched filter for a small dot,
  which cuts a camera's single-pixel speckle many times over) and thresholds it per 64×64 tile at max(8, 4σ) about the tile's own level
  (where its smoothed difference sat in the last picture: a sky that brightens slowly passes nothing), σ the robust noise of the last 25
  pictures; at night only brighter pixels count, by day darker ones too. More than 20 % of the picture over the threshold at once (an IR-cut
  switch, an exposure step) starts the background again, and nothing is found for 10 pictures (2 s). Blobs are 8-connected, 1…5000 px, found
  per lens of a dual camera (never across its seam; those in the seam band are flagged, never used for aiming; the pieces of a blob the seam
  cuts are linked, each with its own centre and the whole blob's measures); more than 200 make the picture noisy, with none. `SkyDetection`
  is a blob's centre, area, flux, peak, elongation and orientation, sharpness, lens, significance and seam group. `SkyMask`: the ground's
  rows, the horizon below 1° once the aim is good, and circles: the Sun within 15° while it is above −6° (`SkyMask.sunCircles`);
  `SkyMaskRaster` lays it on the pixels, also masking the picture's outermost pixels, which the smoothing cannot see past. A second, slow
  background (a running mean over about 3 minutes) holds what stands still in the sky, a star, a wire, a lamp; each detection carries how
  far it stands under and around it (`fixedRise`, `fixedRiseUnder`).
- `SkyTracker.swift`: `SkyTracker` follows the detections: alpha-beta prediction (α 0.85, β 0.005) and a gate of max(6 px, 0.6 × the step);
  born after 3 detections in consecutive pictures, or 2 elongated ones along their path (a meteor, `streakBorn`); coasting 1.5 s; split at
  10 minutes; under 0.6 s dropped unless streak-born; at most 50 open. Each track keeps to its lens; across a dual camera's seam it is
  joined through the two lenses' sky directions within 3° once the aim is good, and by the picture with a wider gate before (the join marked
  uncertain), and so are a track's first two detections; a light on the seam is one track (a track takes its own lens's piece of a cut blob,
  and the other pieces go with it). A track seen in the last picture that misses its gate continues with a strong detection (significant,
  and not a lone sharp pixel: the sensor's speckle) about as bright as it, within one step of where it was (a sharp turn, a sudden stop); a
  second detection that is faint or a lone sharp pixel is looked for only where a chance one is unlikely, and a third is about as bright as
  the first two, so noise rarely starts a track. A picture with the same time as the last is ignored. No track is kept that barely moved
  (none of its samples 4 px from its first, or 0.05° on the sky once the aim is good: a loop or a path out and back that went far is kept)
  or whose samples are all faint (significance under 1.5), whatever it lasted: a twinkling star, a flickering spot; nor one that sat on
  something fixed all along (every detection within 10 px of a spot of the slow background standing 5σ; right on it half the time, if it
  travelled 10 px or more): a star whose track wanders onto the noise beside it, flicker along a wire. A light passing a star, or flying
  along a wire, is kept. The tracks dropped for barely moving or for sitting on something fixed are not lost:
  `update(_:at:wallClock:dropped:)` and `endAll(dropped:)` hand them over apart from the kept ones, each a `SkyDroppedTrack` with its reason
  (`barelyMoved`, `fixed`; noise and tracks under 0.6 s are not handed over), for the flashes and stationary points the later parts read,
  and nothing logs one as a light. `SkyTrack` keeps its samples (`SkyTrackSample`: time, wall clock, point, area, flux, sharpness,
  elongation, lens, seam band, significance, fixedRise, fixedRiseUnder), the pictures it was missing from, and its seam joins; `filters`
  shows the open tracks' predictions.
- `TrackMeasurer.swift`: `TrackMeasurer.measure` turns a track into `SkyMeasures` through the camera model, each sample by its own lens (by
  the model's split when the samples' lenses disagree with it outside the seam band: a picture analysed without the model knows one lens):
  the path between points at least 4 analysed pixels apart, headings along great circles (a straight path across the sky never turns), the
  shape (a sharp turn of 60° within a second at 0.2°/s or more; a sudden stop from 0.5°/s or more to 10 % within 0.6 s, then staying a
  second, by the least-squares speed over it; straight under 15° of turning and 0.97 straightness; else curved), the size from the area and
  the local degrees per pixel, the brightness in the original picture's pixels, and blinking from dips below 30 % of the median flux
  (missing pictures count as dips). `isStationary`: under 0.05°/s over 2 s or more. The overnight prototype's measures (2026-10-26): the strobe
  (the flux of every picture from the first to the last, a missing one dark, less its running median over 11 pictures; the first lag of 0.6
  to 1.6 s whose autocorrelation is over 0.25, a peak, and 0.3 over the half lag's: its period and strength; at least 20 pictures; the
  camera's 2 s keyframe pulse is outside the range), the seen share, the wobble (quadratic fits over time, 30 s at a time, on the plane
  touching the sky at the track's middle) and the turns. The tracker counts the tracks born in each picture (`SkyTracker.beganWith`, the
  last 10 minutes): many beginning at once is the camera changing its picture.
- `SkyVisibility.swift`: `SkyVisibility` counts the stars (local maxima 5σ above the sky around them) in an 8×4 grid of the background once
  a minute at night; a cell is visible at 30 % of the 90th percentile of its counts on past nights; unknown until 3 nights, and by day. A
  night's counts are a small histogram per cell, and a night closes after 24 hours (a polar night).
  Tests: `SkyDetectionTests`, `SkyTrackMathTests`.

## Additions beyond the contract: the sky detector's flights (2026-10-25, docs/CONTRACT_CHANGES.md)

Where the aircraft are, and which one a track is, in `Sky/` (Foundation, and `CameraAdapters.NeighborTable` for the feed finder; the
live transport is the existing `AuthenticatingHTTPClient`). Public: `SkyLabel` (`unexplained`, `plane`, `probablePlane`, `satellite`,
`probableSatellite` (2026-10-26, the rules), `satelliteFlare`, `meteor`, `bug`, `bird`), what the sky log calls a light. Internal:
- `SkyHTTP.swift`: `SkyHTTP`, one bounded GET (a status is an answer, whatever it is; a wait that ran out or an answer that is too long is an
  error that names no address), and `URLSessionSkyHTTP`, its live form: one `AuthenticatingHTTPClient` for the bridge's life, shared by every
  instance, with no credentials, the certificate checks on and redirects never followed. Each call has its own timeout and byte limit: the
  answer is read as it arrives and cut off when it passes the limit, and the whole call at the timeout.
- `AircraftFeed.swift`: `AircraftFeedParser` reads a dump1090, readsb, tar1090 or PiAware `aircraft.json` (`aircraft`) or an adsb.fi answer
  (`ac`) into `AircraftReport`s (hex, call sign, place, height in metres and feet, the position's time, ground speed and track). It uses
  `JSONSerialization` and reads each field on its own (a number, or a plain decimal in a string; never a boolean, `nan` or a hex float), so
  one odd field costs only its aircraft; a feed that writes `nan` or `inf` bare is read with those made `null`. Both shapes of an aircraft
  are read: the newer (`alt_baro`, `alt_geom`, `gs`) and the older that dump1090-mutability writes and a tar1090 may serve (`altitude`,
  `speed`; read in the newer shape only, every aircraft of such a feed was lost). The height is the geometric altitude, else the barometric
  one; an aircraft on the ground, with a position older than 30 s (`seen_pos`), with a place or height that is
  not one, or with no `seen_pos` is left out. **The position's time is the box's receive time less `seen_pos`; the feed's own `now` is never
  read**, since a feed host's clock can be minutes out. A body over 4 MiB is not read, at most 5,000 aircraft come out, and a document nested
  more than 16 levels deep is not read (on macOS, Apple's reader overflows a 512 KB thread stack at about 480 levels of objects, which is a crash).
  `FlightFeedPoller` polls a feed once a second (each request bounded to 5 s and 4 MiB) into a `FlightHistory`; `problem` says in plain
  words what is wrong ("The flight feed answered 404.") and `lastAnswer` when the last good answer came; `stop()` returns when polling has
  stopped, and a poller nobody holds stops by itself. A feed that answers but whose aircraft cannot be read says so: once its answers have
  listed aircraft and none with a position, age and height the parser reads (`AircraftFeedParser.read` counts them) for 5 minutes,
  `problem` is "The flight feed answers, but none of its planes can be read (no height or position). Check that it's dump1090, readsb,
  tar1090 or PiAware." until a plane can be read again, with one journal line when that starts and one when it ends. An empty list (no
  aircraft around) is no problem, nor are aircraft read and left out (on the ground, last placed over 30 s ago).
- `FlightHistory.swift`: the last 15 minutes of reports of each aircraft, in time order (bounded: 10,000 aircraft, 1,200 reports each, and
  one report for a time); `tracks(overlapping:)` gives, for a time range, the reports in it and the nearest on each side.
- `FlightFeedFinder.swift`: the "Find a feed" of Settings. It asks only the hosts in the box's own neighbour table (`NeighborTable`), private
  addresses only (10/8, 172.16/12, 192.168/16, written plainly), at most 64 hosts, for the four places a feed usually is (tar1090,
  dump1090-fa and SkyAware on port 80, dump1090 on port 8080), 8 requests at a time, 1.5 s each; an answer counts when it reads as a feed
  (an empty sky does). It builds no address of its own and logs nothing.
- `FlightMatcher.swift`: `FlightMatcher.match` says which aircraft a track is, if any: each aircraft's place at each picture's time is
  interpolated in its history (up to 5 s beyond it, extrapolated from its speed and track; not across a gap of over 20 s); its score is the
  median angular distance to the track's directions through the camera model (a picture it cannot be placed at is infinitely far); it matches
  within the aim's tolerance (`AimFitter.matchTolerance`), with its heading within 30° of the track's for a track of a second or more. While
  the aim is rough it must also be the only aircraft within 15° and within 50 % of the track's speed. A match is a `FlightMatch`: the hex, a
  detail like "TEST123 · 35,000 ft", the score, `.probablePlane` (rough) or `.plane`, and one `AimCorrespondence` per matched picture outside
  the seam band, which go to `SkyAimStore.add` in one call.
  Tests: `SkyFlightTests`.

## Additions beyond the contract: the sky detector's settings and log (2026-10-25, docs/CONTRACT_CHANGES.md)

The Sky Watcher (the name a person reads; the code and the JSON keep `sky` and `skyDetector`): its settings, the log it keeps beside the
recordings and the engine's face on it, in `Sky/SkySettings.swift`, `Sky/SkyEntry.swift`, `Sky/SkyLogStore.swift` and `BridgeEngine+Sky.swift`.
Public:
- **Settings.** `BridgeSettings.sky` (`SkySettings`): `location` (a `SkyLocation`: `latitude`, `longitude`, `heightMeters`; −90 to 90, −180 to 180,
  not 0 and 0, −500 to 9,000 m, all numbers), `flightFeedURL` (http or https with a host; no user name or password, no `#`, one line of at most 500
  characters) and `aiDailyLimit` (`SkySettings.aiDailyLimitRange`, 1 to 1,000; `SkySettings.defaultAIDailyLimit`, 50). `SkySettings.validationProblem`
  is the first thing wrong (a `SkySettings.Problem`: the `field`, `sky.location`, `sky.flightFeedURL` or `sky.aiDailyLimit`, and the words, which never
  repeat what was typed); `updateSettings` refuses such settings with `EngineError.invalidSettings`. Decoding is lenient like the AI settings: a missing
  or unreadable value takes its default and what this build would refuse to save is dropped, logged by the name of its key.
  **Where the box is stays on the box.** It is in `config.json` and in the signed-in page's `GET settings`, and nowhere else: `SkyLocation` prints,
  interpolates and dumps as "location hidden", and it is in no log line, no diagnostics report, no notification, no AI request and no export.
- **A camera's switch.** `CameraConfiguration.skyDetector` (a `SkyDetectorSettings`; nil: never saved): `enabled` (off), `facing` (0 up to 360°
  clockwise from true north, 0 is north), `tilt` (20°, 0 to 90), `groundPercent` (12, 0 to 60), `nightProfile` (on) and `lensLayout` (a `SkyLensLayout`,
  `single` or `dual`; nil: automatic, two lenses for a picture of 2:1 or wider). Decoding is lenient (an unknown layout is automatic) and
  `SkyDetectorSettings.validationProblem` names the field (`skyDetector.facing`, `skyDetector.tilt`, `skyDetector.groundPercent`). `needsRestart` ignores it:
  the Sky Watcher takes its settings in place. `CameraConfiguration.streamsOnDemand` says a camera cannot watch the sky (a battery camera: it would be
  kept awake all night); it is decided from the configuration and a test keeps it equal to what every driver says. Turning a camera's switch on or off
  is logged ("Sky Watcher turned on for North Sky"), and the diagnostics say "Sky Watcher on for 2 cameras" and nothing more about it (while the plugin is off, "Sky Watcher is off in Plugins (2 cameras are set to watch the sky)").
- **The plugin's switch.** The Sky Watcher is a plugin that a person switches on first (2026-10-25): `BridgeSettings.skyPluginOn` is
  `plugins["sky"]?.enabled == true`, the switch on the Plugins page (a `PluginState`; off on a new box and in every configuration from before it, and a
  value that cannot be read is off). The engine's Sky Watcher runs only while it is true: no detector, no flight feed polling and no downloads while it
  is off. Switching it off or on touches neither `BridgeSettings.sky` nor any camera's `skyDetector`, so switching it on again brings the same cameras back.
- **The log's types.** A `SkyEntry` is one light: `id` (1 to 64 letters, digits, `-` and `_`: `SkyEntry.isValidID`, since it names the entry's picture),
  `camera`, `kind` (`SkyEntryKind`: `track`, `newLight`, `flash`), `start`, `end`, `path` (`SkyPathPoint`: seconds from the start and `x`, `y` in the camera's
  original picture, 0 to 1; at most 64), `measures` (`SkyMeasures`), `label` (`SkyLabel`) with `by` (`SkyLabelSource`) and `detail`, `unusual`
  (`SkyUnusualReason`), `speedVsPlanes`, `candidate`, `alerted`, `hasStill`, `ai` (a `SkyAIAnswer`) and the person's `correction` (`SkyCorrection`: plane,
  bird, bug, satellite, meteor, notSure); since 2026-10-26 the guide to the unexplained: `priority` (`SkyPriority`: high, medium, low), `reasons` (at most 8
  short phrases), `doubtful` and `group` (set when the log is read, never kept; see "the sky detector's rules"), and `sortedLater` (logged before the rules and
  sorted by them as the log is read, never kept: "older lights sorted when the night is read"); since "one light, not fifteen" (2026-10-26) `pieces` (how
  many pieces the box saw the light in), and `parts` and `stillPart` (a light the log kept in pieces, joined as it is read; never kept). `SkyDisplay.label`
  is what the log shows: a correction wins, and "not sure" shows the entry's own label.
  `SkyConditions` (`SkyConditionState`: clear, cloudy, notVisible, unknown) say how the sky was for a stretch of time; `SkyCounts` count a night's
  entries by what the log shows (`SkyCounts(counting:)`: planes include probable ones, satellites probable ones and their flares; an entry the box explained and the
  person was not sure of is `notSure`, one it did not explain stays `unexplained` whatever the person said; `explained` is the sum of all but the
  unexplained); `SkyLearning` is how many planes and satellites the box has matched against what it needs (30 and 10); `SkyNightLog` is one night's or
  day's log with its counts and the camera's aim, and `capped` (2026-10-25, the clutter fix): the hours of its view in which the camera followed more
  lights that nothing explains than it logs, each a `SkyCappedHour` (`hour`, the clock hour's start, and `count`, how many more), oldest first;
  `SkyLogError` says in the person's words why the log cannot answer (no place, no folder, a night that is not a date, no such entry, no picture).
- **The engine.** `BridgeEngine.skyNightLog(cameraID:night:view:)` reads a log (`night` is the log's name, nil for the latest; `view` is `SkyLogView`,
  the night from sunset to sunrise or the day from sunrise to sunset), `BridgeEngine.correctSkyEntry(cameraID:entryID:night:label:)` records a
  person's word and answers the entry, `BridgeEngine.skyStill(cameraID:night:entryID:)` reads an entry's picture, and `BridgeEngine.findFlightFeeds()`
  finds the flight feeds on the box's network, one address per host (the first that answers, in the finder's own order), looking for at most 20 s.
  Until the detector runs (the tasks that follow) a log reports the aim as not fitted and nothing matched.

Internal:
- `SkyLogStore` (`Sky/SkyLogStore.swift`; the Sky Watcher's log beside the recordings, owned by `ArchiveStore.skyLog` next to the events). Layout:
  `<recordings>/.sky/<CAMERA-UUID>/<yyyy-MM-dd>.jsonl`, one file per camera per night, mode 0600 in folders of 0700, append-only, one JSON object per line
  with sorted keys and times in milliseconds: `{"entry": {…}, "v": 1}`, `{"correction": {"at", "label"}, "id", "v": 1}`, `{"ai": {…}, "id", "v": 1}`,
  `{"alerted": true, "id", "v": 1}`, `{"id", "still": true, "v": 1}` (its picture was made later, from the recording: Ruling S31),
  `{"conditions": {…}, "v": 1}` and `{"capped": {"at", "count", "hour"}, "v": 1}` (`count` more lights in the clock hour `hour` were not logged; an
  hour's lines add up, one read twice counts once); an entry's picture is `<yyyy-MM-dd>/<id>.jpg` in the camera's folder (at most 2 MiB).
  The first entry line of an id wins and the lines after it apply to it in order (the last correction and the last answer win, a picture's line sets
  `hasStill`; a line for an id the file does not hold is ignored); a line that does not parse (a torn last line, a later version's, one over 64 KiB) is
  skipped, and the next append starts on a line of its own. A line of a kind a reader does not know is skipped too (every key it knows is absent, or
  names an entry it applies nothing to): the builds before the picture's and the capped lines skip them. `SkyLogStore.contents` reads all of it
  (`SkyLogContents`: the entries, the conditions, the capped hours), `read` the entries and the conditions; a file over 16 MiB is read from its end, so
  a night is read whole after a day that flooded the file before it. An entry is kept within bounds (its path thinned to 64 points, text cut to length, an end never before the start, a number that is
  not one written as a word that reads back, `pieces` 1 to 10,000, never `parts` or `stillPart`). Writes run on one serial queue and never wait for a drive: what cannot be written waits (at most 1,000
  lines, and 16 MiB of pictures; the oldest go first, never the one being written; `retry()` tries again, and the janitor calls it every pass). A write that
  finds a link where a folder or a file belongs is given up, not waited on; `.sky`, a camera's folder, a night's file and its folder of pictures are never
  written, read or pruned through a link. A read sees what waits for the drive as well as the file. Nothing is kept while no place for recordings is chosen,
  and the recordings folder itself is never made. Retention: `ArchiveStore.pruneEvents` also prunes `.sky` by the events' cutoff, deleting a night with its
  pictures once its date and the day after it are over (the night named D lasts to the morning of D+1), so nothing newer than the cutoff goes.
- Filing by time (Ruling S4; `SkyNight.logName(for:observer:zone:)`, `SkyNight.logSpan(named:view:observer:zone:)`, `SkyNight.latestLogName(view:now:observer:zone:)`):
  a night (sunset to sunrise) is named by the local date of its sunset, a day (sunrise to sunset) by its own local date, and the day after night N is day
  N+1. An entry is filed by its time, so a night is one file across midnight, and one file holds a day and the night that follows it: the log named D reaches
  from the sunrise of D to the sunrise of D+1. The detector files with `logName(for:)`, not with `SkyNight.name(containing:)` (which names, in the day, the night
  that ended that morning). Where the Sun does not set or rise there is no night, and a day is the local day.
- `ArchiveStore.skyRead(_:)` runs a read of the log on the store's read queue with its deadline (a drive that is away is `ArchiveUnavailable.folderMissing`, one that
  does not answer `ArchiveError.timedOut`); `BridgeEngine.skyLog`, `BridgeEngine.skyFolder` and `BridgeEngine.skyStatus(of:)` (the camera's aim and learning for a
  log, which the detector's task fills in) are the engine's hooks.
- Tests: `SkySettingsTests`, `SkyLogStoreTests`, `SkyFilingTests` and `SkyNightLogEngineTests`.


## Additions beyond the contract: the sky detector's picture stream (2026-10-25, docs/CONTRACT_CHANGES.md)

The pictures the sky detector looks at, in `Runtime/` (`SkyStream.swift`, `SkyMonitor.swift`, `CameraRuntime`'s "Sky detector" section). Public, in MediaCore:
`MediaCodecs.makeSkyDecoder(format:maxOutputWidth:keepEvery:)`, `VideoDecoding.decodingPlace` and `DecodingPlace` (`gpu`, `software`). Internal:
- `SkyStreamChoice` (`stream` sub or main, `analysisWidth`, `keepEvery`; `choose(sub:subFrameRate:main:mainFrameRate:)`): the sub stream when it is at least 1280
  pixels wide, else the main stream, analysed at its own width but at most 1920, `keepEvery = max(1, round(frames per second / 5))`; nil while there is no picture
  to choose from (a sub stream under 1280 is no help while the main stream has shown none). A rate that is not known is the one the resolution carries, else 1.
- `SkyFrame` (`image` luma at the analysis width, `time` the stream's own presentation time in seconds, `wallClock` the encoded frame's, `clockOffset` to add to
  it for the bridge's clock, `MediaHub.wallClockOffset`, and `pictureWidth` × `pictureHeight`, the size of the stream's own picture before it was scaled down: what the
  camera model is about) and `SkyFrameSink` (`frame(_:)`, `gap(at:reason:)`), where the pictures go.
- `SkyMonitor` (an actor; `start()`, `stop()`, `analysed`, `decoding`, `isFinished`): reads the hub from the newest keyframe on (`.prebuffer(.zero)`), makes a decoder with
  `makeSkyDecoder` at a keyframe, keeps to five pictures a second from the pictures' times (a decoder that makes every picture, as the default does, is kept to the rate
  here: pictures closer than 0.16 s are not both analysed, before the thumbnail is made), maps each picture's time back to the wall clock of its own encoded frame
  (a picture may come out frames after the one it shows), and asks the picture for `grayThumbnail(maxWidth: analysisWidth)`. Nothing applies `PictureCorrection`:
  the detector works on the camera's own picture. A **gap** is told once for a break: the hub's source was reconnected (`discontinuityCount`), the stream's time went back
  or forward by more than 5 s, no picture for 5 s (once for a silence, however long), or the picture's codec or size changed; several together are one gap with all the
  reasons. After a gap, and after a decoder that failed, the decoder starts again at the next keyframe. On a format change the monitor tells the sink and **ends**
  (`isFinished`): its choice is for the old format, and the runtime chooses again. Stopping returns once nothing more can reach the sink.
- `CameraRuntime.startSky(sink:)` (false: an on-demand camera, which sleeps, or a camera that is not running), `stopSky()`, `skyStream` (the choice in use, nil before a
  picture to choose from), `skyDecoding` (`gpu`, `software`, or nil), `skyStill(around:)`. The main stream always runs. The sub stream's size is learned first: if the
  hub does not remember it (or its rate, when it is wide enough) the runtime holds the sub stream (`acquireSub`) until it shows a picture, `subStreamStartWait` at most
  (it goes offline: the main stream); a sub stream under 1280 is given back at once (`releaseSub`, the idle stop), and one that is watched is held for as long as the sky
  runs (one user, shown by `subStreamUsers`). A look every 250 ms starts the monitor when there is a picture and a rate, replaces one that ended, and otherwise leaves
  a running monitor alone; the sub stream is looked at again only then (when the sky starts and after a format change). The camera's `stop()` ends the sky; its detector
  starts it again when the camera runs again. `skyStill(around:)` is the JPEG (full size, quality 0.8, the camera's own picture, no correction) of the main ring's keyframe
  nearest a time, with that keyframe's wall clock (the same clock as `SkyFrame.wallClock`), on a decoder of its own, one at a time; the ring holds at least the last 12 s.
- The decoder: `Codecs/README.md` of PlatformLinux. A stream the GPU's decoder cannot take (H.264 over 4096 wide or tall) or fails on is decoded in software, and
  `skyDecoding` says so. Tests: `RuntimeSkyTests` (the choice, the monitor with fake codecs, the runtime on the demo camera) and PlatformLinux's `SkyDecoderTests`.

## Additions beyond the contract: the sky detector at work (2026-10-25, docs/CONTRACT_CHANGES.md)

The Sky Watcher running on a camera: `Sky/SkyCameraDetector.swift` (one camera's pipeline), `Sky/SkyService.swift` (the detectors, the flight history and the
feed's poller), `Sky/SkyAimSearch.swift` (the wide search of a card), and the engine's side in `BridgeEngine+Sky.swift`. Public: `SkyCameraStatus` (`running`,
`stream` `main` or `sub`, `analysisWidth`, `picturesPerSecond`, `decoding` `gpu` or `software`, `aim`, `learning`, `problem`, `profile`), `CameraStatus.sky` (nil while
the Sky Watcher is off for the camera) and `BridgeSettings.skyPluginOn` (the Sky Watcher is a plugin, id `sky`, off by default: `plugins["sky"]?.enabled`). Internal:
- **When it runs** (`BridgeEngine.applySky`, Ruling S21): a detector runs for a camera only while the plugin is on, the camera's switch is on, the camera is turned on and
  the bridge runs, and only with a valid place and a recordings folder; a battery camera never (it would be kept awake). Otherwise the camera's `status.sky` is nil (the
  plugin or its switch off) or not running with a sentence in `problem` ("Set where the box is first.", "Choose a recordings folder first: the sky log is kept with the
  recordings.", "Battery cameras can’t watch the sky: it would keep them awake."). It is applied at the start, after a change of the settings it needs
  (`skyChanged`: the plugin, `sky`, the recordings folder, the zone: `PATCH plugins/sky` goes through `updateSettings`), of a camera (`addCamera`, `updateCamera`) and
  when a runtime starts (`startRuntimes` gives it to the camera's detector, `startSkyIfWanted`, through `CameraRuntime.startSky(sink:)`); a pause stops every detector
  (`stopAllSky`) and `removeCamera` deletes the camera's aim (`removeSky`). **Nothing is fetched while no detector runs**: `SkyService` polls the feed
  (`FlightFeedPoller`, once a second) only while at least one runs, and stops it with the last.
- **Each picture** (`SkyCameraDetector.frame`, on its actor): the mask (the ground, the horizon below 1° once the aim is good, the Sun within 15°; the Sun and the night
  are worked out once a minute), the analyzer, the tracker on the box's clock (`SkyFrame.wallClock + clockOffset`). A whole-picture change ends every open track unlogged
  (`endAll(dropped:)`, its drops thrown away too) and starts none for `quietAfterChange` (3 s on the stream's clock): one such jump made 49 lights on the owner's camera.
  The drops of the tracker go to `droppedTrack(_:analysisWidth:analysisHeight:)`: they count towards their spot being busy (below), and Tasks 9 and 10 read them there. A gap (`gap(at:reason:)`) or a new runtime (`restarted()`) cuts what was open: a track
  a gap cut is not logged, and a gap is never a track. The aim is read from a copy kept on the detector: a picture never waits for the store's fit.
- **One light, not fifteen** (2026-10-26, below): a track that ended, and a flash the tracker dropped, is first held (`SkyStitchHold`) until nothing can
  continue it, so that a light seen in pieces is classified and logged once, as one track.
- **Each ended track** (a queue of its own, in order, off the picture path): measured with the current aim; a stationary one is left (Task 10's); `classify` (the
  flights: `FlightMatcher` on the shared `FlightHistory`, off the actor; a match is `.plane`, or `.probablePlane` while the aim is rough, by `.flight`, with its call sign and
  height, and its correspondences go to `SkyAimStore.add` in one call; then, for what no flight explains and no filter below skips, the rules: "the sky detector's
  rules"); nothing explains it: `.unexplained`, ranked, with a still of its middle
  (`CameraRuntime.skyStill`, at most 1920 wide, `BridgeEngine.skyStillPicture`). Entries are filed with `SkyNight.logName` (Ruling S4), their path at most 64 points
  evenly picked, their id the start's milliseconds and a random part in hex. The learning is the baseline's planes, matched with a good aim (ready at 30; satellites
  are not asked for while no orbits are loaded). **Fewer junk entries** (Ruling S24, `SkyLightFilter`): a light that nothing explains and that crawls (a mean speed along its path under
  0.05°/s while the lens's aim is good or precise, under 0.5 analysed pixels a second while it is rough: a star), or that never gets 12 analysed pixels from where it was
  first seen while it is never bright (Rulings S28 and S29, `SkyLightFilter.wandersInPlace`: a faint star or a wire whose centroid wanders; a light that turns back
  counts by its farthest point, and one that stands 6σ or more above the sky at its strongest is kept however little it moved), is no entry and
  has no picture, only a count that the
  journal gets once a clock hour ("Sky Watcher, North Sky: 41 slow lights skipped this hour (likely stars)"; a plane is a plane whatever its speed).
- **Daytime clutter** (2026-10-25: the owner's camera logged about 2,500 lights that were not lights in one afternoon, tree tops and shimmer above the ground cut, then
  four a minute of glare on the west edge in the late sun). Each is no entry, only a count with its own journal line a clock hour:
  - **Busy spots** (`Sky/SkyClutterMap.swift`): every ended track that no flight explains, kept or dropped by the tracker
    (`SkyCameraDetector.droppedTrack(_:analysisWidth:analysisHeight:)`), counts in the analyser's 64-pixel tile it began in and in the one it was seen in most; a
    count is worth 1 and decays (to 1/e in 2 hours), a tile's score is capped at 20, and a tile is busy once its score reaches 10 (ten tracks in a short while,
    about five an hour kept up; a real sky's two or three an hour at one spot stay near 6) until it falls under 5 (83 minutes after ten at once, 2.8 hours after an
    afternoon of them). A light that nothing explains and that began and stayed in busy tiles is not logged ("Sky Watcher, North Sky: 14 lights at busy spots
    skipped this hour (trees, wires or glare)"); one that crosses out of them is, and a plane is a plane there: over the tree line or a wire a real light is
    still logged, which a mask would not do. The status's `aim.note` says "Ignoring 3 busy spots (trees, wires or glare)" (touching tiles are one spot). The map
    is kept in memory and in `clutter.json` beside the aim, written with the state, so a restart does not learn it again; a changed card (Ruling S25, also the
    2-hour restart and a card changed while off) deletes it, and another analysed size starts it afresh. Replayed on the owner's 2,539 entries it would have
    logged 114: the one spot (x 0 to 13 %, y 75 to 90 % of the picture) was learnt within the first four minutes.
  - **The Sun's guard** (`Sky/SkySunGuard.swift`): while the Sun is up (above −6°) and outside the view but within 25° of its nearest picture edge (40° while the
    aim is rough: a card is only guessed), a light whose whole path lies in the band along that edge, 25° of the lens's field deep (40° while rough: North Sky's
    left lens's outer 44 %), is not logged ("… 3 lights near the Sun skipped this hour (likely glare)"). A dual camera's seam is no edge. With the Sun in the view
    its circle of the mask is the guard, as before; planes are matched first and logged wherever they are.
  - **At most 200 an hour** (`SkyLightFilter.unexplainedPerHour`): a camera logs at most 200 lights that no flight explains and that the rules leave unexplained or call
    a meteor, a bug or a bird (`SkyLightFilter.countsAgainstTheHour`; never their probable planes and satellites, which are logged whatever the hour holds: 2026-10-26)
    in a clock hour of the box's zone (of the light's start); the rest are counted, and once the hour is over (the next minute's `tick`, or the stop) one line of the log of each night they belong to
    says how many (`SkyLogStore.recordCapped`, `{"capped": {"at", "count", "hour"}, "v": 1}`), as does the journal ("… 212 more lights were not logged this hour
    (at most 200 are logged an hour)"). The log's view carries the hours it holds (`SkyNightLog.capped`) and the page shows a note for each. A detector that
    restarts in the hour counts afresh (its lines add up).
- **A picture for every logged light** (Ruling S31): there is no limit of pictures an hour any more: every logged entry that wants one
  (`SkyLightFilter.wantsStill(_:by:)`: unexplained, the rules' meteors, bugs and birds, and since 2026-10-26 their probable planes and satellites and a satellite's
  flare; never a flight's plane or an orbit's named satellite) asks for its still, and its small one is made once it is written (`Context.stillWritten`). **The pictures stay off a full drive** (Rulings S27
  and S31): one is taken only while the recordings drive has its floor and 1 GiB more free (`SkyLightFilter.stillsHaveRoom`, from `nvr.storageStatus()`; below the
  floor every camera's recording pauses, and the size rule never counts what the sky log keeps; it was twice the floor, which a full recorder, kept by retention at
  about twice its floor free, almost never had), a picture that cannot be made 1920 wide is not kept at full size (`BridgeEngine.skyStillJPEG`), and each camera's
  pictures stay under 2 GiB, the oldest nights' folders going first (`SkyLogStore.pruneStills`, from the retention janitor every 10 minutes; never the logs or the
  recordings, never the newest night, no link followed; an entry whose picture went answers "There is no picture of it"). **Pictures made later**
  (`Sky/SkyStillBackfill.swift`): a light logged without one (no room then, a long track whose middle had left the camera's ring, an older build's 30 an hour, the
  rules' probable planes and satellites before they had pictures) gets one from the recording, and then its small one. Once a minute (`tick`), while the drive has room, at most 4 of the lights of the log the time is filed in and the one before it, newest
  first, that ended a minute ago or more: `BridgeEngine.skyRecordedStill` reads the recording's keyframe of the light's middle (the governing one, or the next when it
  is nearer: `ArchiveReading` `.keyframe` and `.initialization`, `FMP4FrameSlicer.frame(fromKeyframeBytes:info:start:)`), decodes it on a pool of its own one at a
  time for all the cameras, and makes it as a live still is (full size at 0.8, then 1920 wide); the picture is written and then a line `{"id", "still": true, "v": 1}`,
  so the log stays append-only and the entry reads `hasStill`. The logs are read off the actor on the store's read queue (`Context.readLog`), again only once every
  candidate was tried and 10 minutes passed. A recording that is gone (before the oldest, a gap, a camera that does not record, a time 10 minutes past the newest) or
  that makes no picture is given up quietly; one not written yet is asked again, five times at the most: no retry storm. What was given up is kept in memory only.
- **The conditions** (`SkyConditionsRecorder`): the visible share once a minute (`SkyVisibility`): clear at 0.6 or more, not visible below 0.3, cloudy between, unknown when
  not known; a span is written when the state changes or once it has lasted an hour, and a silence of more than 5 minutes ends it at its last look.
- **The status** (`SkyCameraDetector.status`; `skyCameraStatus` adds the flight feed's trouble as `problem` when the detector has none): `running` while a picture came in
  the last 10 s, the stream and where it is decoded from the pictures (`SkyFrame.stream`, `SkyFrame.decoding`, set by `SkyMonitor`), `picturesPerSecond` over the last 25
  pictures' stream times since the last break, to a tenth, the aim and the learning. The log's `aim` and `learning` are the detector's (`skyStatus(of:)`).
- **An aim far off** (Ruling S18; `SkyMatchWatch`, `SkyAimSearch`): once a minute the feed's aircraft that the aim puts in the view (within 60 km, 2° up, above the
  ground; not while the sky is known not visible) are noted. When planes have been in view for 2 hours (5 aircraft at least), 5 lights or more were followed and none
  matched, `aim.note` says "Planes are flying through the view but none match: check which way the camera faces" (also the sign of a camera that moved), until a match.
  While the aim is still rough then, once an hour, the unexplained tracks of the last 2 hours (at most 40, 16 pictures each, with up to 40 aircraft within 100 km
  placed at their times; kept in memory only) are matched again through the cards of facing ±45° in 15° steps and tilt ±30° in 10° steps (within 0…90°), off the
  actor. A card that explains at least 5 aircraft and twice as many as the best card not next to it on the grid becomes the aim's start (`SkyAimStore.reset` with the
  note "The planes fit the camera facing about 30° further right and tilted 10° higher than set: it aims from there now.", then `setStart`); it is kept until the person
  changes the card. **A camera that moved** (Ruling S25): the aim starts again from the card, rough as a new camera's is (so that the wide search can run), when the
  card's facing, tilt or lenses change through the settings update (the ground and the night profile change nothing of where it looks), or when the aim is good or precise
  and the stretch above has held its 2 hours; the journal says so ("Sky Watcher, North Sky: no planes matched for 2 hours with the aim good; starting the aim again") and
  so does `aim.note`. The aim keeps the card it started from in `aim.json` (`SkyAimStore.Card`), so a card changed while the plugin or the camera's switch was off starts
  it again, quietly, when the detector next opens it (Ruling S25b; an `aim.json` from before keeps its fit and saves the card).
- **Stopping** (Ruling S27; `SkyCameraDetector.stop`, `SkyService`, `BridgeEngine.stopAllSky`): the engine stops the detectors with its locks held, and the daemon gives the
  whole engine ten seconds, so a stop is quick. The lights that wait in the queue are dropped, none takes a picture once the detector is told to stop, and the light the
  queue is at work on gets one second (a keyframe's decode can stall for ten) and no longer; what it leaves unfinished can write nothing of the aim (`SkyAimStore.close`).
  `SkyService` stops its detectors together, `stopAllSky` is bounded to 2 s, and `stopServices` closes the recordings (`nvr.detachAll`) before it stops the sky.
- **Kept per camera** in `<data>/sky/<camera-uuid>/` (`SkyService.directory(of:in:)`, beside the aim's `aim.json` and `matches.jsonl`): `detector.json` (0600) with the
  visibility's memory, the open conditions span, the planes learned and the card the search found with the card it was found for, `clutter.json` (0600) with the
  busy spots (tiles, scores and times), and `baseline.json` (0600) with what the camera learned of its sky (`SkyBaseline`). No place is in them; nothing logged names the
  place. Kept when the detector is turned off; deleted with the camera.
- Tests: `SkyDetectorTests` (synthetic pictures through the whole pipeline: a matched plane, an unexplained light with its still, a gap, a brightness jump, the status, the
  conditions; the aim improved by twelve planes and kept over a restart; the note and the wide search; in `SkyDetectorPolicyTests.swift` and `SkyStillsAndStopTests.swift`, Rulings S24, S25 and S27;
  in `SkyClutterTests.swift` the busy spots, the Sun's guard, the hourly cap, a picture for every logged light and the pictures made later), `SkyClutterMapTests`,
  `SkySunGuardTests` and `SkyRecordedStillTests` (the recording's keyframe nearest a time, and what is gone or not yet), and `SkyServiceTests` (the feed asked only while a
  detector runs, the aim kept and removed; on macOS `SkyEngineTests`: the switch, the plugin both ways and across a pause, a cleared place or folder, a removed camera).

## Additions beyond the contract: the Sky Watcher's small pictures (2026-10-26, docs/CONTRACT_CHANGES.md)

The grid of the Sky Watcher's log puts a picture on every card, and a night can hold hundreds of lights with a still each (a JPEG up to 1920 pixels wide): a phone scrolling
a night would download hundreds of big pictures to look at postage stamps. `GET sky/cameras/:id/entries/:eid/still?size=thumb` answers a small one instead, and
`BridgeEngine.skyStillThumbnail(cameraID:night:entryID:)` is the engine's side of it (`Sky/SkyThumbnails.swift`, `Sky/SkyCloseUp.swift`, `Sky/SkyPicture.swift`,
`Sky/SkyLogStore+Thumbnails.swift`). Public (and in MediaCore, `MediaCodecs.croppedJPEG(_:crop:maxWidth:quality:)` and `ImageCrop`):
- `BridgeEngine.skyStillThumbnail(cameraID:night:entryID:)` answers a `SkyStillPicture` (`jpeg`, `isThumbnail`): the thumbnail, at most 480 pixels wide, or, when one cannot be
  made, the whole picture (`isThumbnail` false), which is what the page then shows as it always did. It throws what `skyStill` throws (`EngineError.unknownCamera`,
  `SkyLogError.noStill` for an entry with no picture or one that is gone, `unknownNight`, `noFolder`, `ArchiveUnavailable` and `ArchiveError.timedOut` while the drive is away or slow)
  and never fails because a thumbnail could not be made.
- `SkyNightLog.picture` (a `SkyPictureSize`, `width` and `height`; nil when none can be read; a default of nil in `SkyNightLog.init`): how big the night's pictures are, read from
  the frame header of the newest light's picture that can be read (`SkyLogStore.pictureSize(ofStills:camera:night:folder:)`, at most eight tried, 128 KiB read of each). The page
  needs it to draw a light's path over a thumbnail of it: the thumbnail is cut where the page's close-up is, and that depends on the picture's size.

Internal:
- **What is cut** (`SkyCloseUp`): the page's own close-up rule (`closeUpRect` and `thumbRect` in `linux/web/js/screens/sky-model.js`): around the light's path, its box with half its
  size more on every side, at least 160 × 90 pixels of the still, 16:9, as big as the picture at most and inside it (moved in from an edge or a corner, never cut), in whole pixels;
  none (the whole picture, small) for a light that crossed more of the sky than a close-up holds. It is a copy, and the page draws the path with its own, so the two must give the
  same rectangle to the pixel: `SkyCloseUpTests` checks this one against the page's answers to hundreds of paths (`Tests/BridgeEngineTests/Fixtures/sky-closeup-vectors.json`,
  made from the page's functions by `linux/web-tests/support/sky-closeup-vectors.mjs`, which `sky-model.test.mjs` keeps equal to them). Change one and change the other.
- **Made with the picture** (2026-10-26; the grid's first views were slow): once the detector has handed a picture to the log, live or made later from the recording, it says
  so (`SkyCameraDetector.Context.stillWritten`), and the engine makes its thumbnail at background priority as soon as the log's queue has written the picture and its line
  (`SkyThumbnails.prepare`: the same lookup, room, failure memory and making as a page's request, in the same two places, but after every page's request that waits:
  `SkyThumbnailGate.run(background:)`; one that finds `maximumWaiting` waiting in all is left for the page's first view). The page's first view then reads it.
- **Made once, kept beside the picture** (`SkyThumbnails`, `SkyLogStore+Thumbnails.swift`): the first request finds there is a picture and no thumbnail (`thumbnailLookup`: a stat of the
  picture, and a kept thumbnail is read: a regular file in real folders, a JPEG, stamped with the time of the picture it was made from, so that a clock that was set back does not make
  every thumbnail stale), and takes its turn (below). Then, on a thread of its own, it reads the picture (`readStill`, only if it is still the one that was stamped), its size
  (`JPEGHeader`) and the entry's path from the night's file (`SkyLogStore.path(ofEntry:…)`: the id's bytes are searched for and only the lines that hold them are decoded, the lines
  that wait for the drive included: a busy night's file is megabytes and a page asks for hundreds of thumbnails), and has the codecs cut it, at quality 0.8, at most 480 wide, never larger
  than the part. The result is kept as `<night>/<id>.thumb.jpg` in the folder of the night's pictures (`SkyLogStore.storeThumbnail`: a 0600 temporary file given the picture's time and
  moved into place, never through a link, no folder made, at most 512 KiB), and read from there from then on. The picture's own file is untouched. **Remade with the picture**:
  `writeStillFile` removes the entry's thumbnail when it moves a new picture over the old one (both the detector's live pictures and the backfill write through it), and a thumbnail is
  stored only for the picture it was made from (`SkyStillStamp`: file, size and time, checked under the same lock, `SkyLogStore.pictureMoves`, that the picture's move holds), so one made
  while the picture was replaced is refused. A picture written later for an entry (the backfill) is the first one: nothing was kept for it.
- **Off the request, at low priority, two at a time**: the work runs on a concurrent queue of utility priority (a thread of its own, not a cooperative one) and the ffmpeg child under
  `nice -n 10`, at most `SkyThumbnails.concurrent` (2) at a time through `SkyThumbnailGate`, whatever is asked, in the order the requests came (the cards of the first screen are asked
  for first). A request that waits holds nothing (not the picture, not the path); when `SkyThumbnails.maximumWaiting` (128) wait already, the next to come is answered with the whole
  picture at once. A request that finds the thumbnail already made by another while it waited does not make it again. One that takes longer than `SkyThumbnails.deadline` (30 s) is given
  up on (it finishes on its thread and a thumbnail it makes late is kept).
- **Only while the drive has room**: a thumbnail is made and kept only while the recordings drive has its floor and 1 GiB more free (`SkyLightFilter.stillsHaveRoom`, as the pictures
  are taken: Ruling S27, the Sky Watcher never pushes the recorder into pausing); otherwise the whole picture, which is on the drive already, is answered. A kept thumbnail is read whatever
  the drive has.
- **Never a 500 for the grid**: a thumbnail that cannot be made (no codecs that can crop, a picture or an entry the box cannot read, a codec that failed, took too long or made a
  picture that is not what was asked for) is answered with the whole picture and nothing is kept; what went wrong is remembered for `SkyThumbnails.failureMemory` (5 minutes, at most
  256 pictures) so that a picture that cannot be made is not tried at every request. A drive that does not answer is not the picture's fault and is not remembered.
- **Pruning**: a thumbnail is a regular file in the night's folder of pictures, so `pruneStills` counts it in the camera's 2 GiB (`SkyLightFilter.stillBytesPerCamera`) and takes it
  with its night, and `prune` (the events' cutoff) takes the folder whole.
- `EngineTuning.skyThumbnailDeadline`, `skyThumbnailFailureMemory`, `skyThumbnailWaiting` and `skyThumbnailRoom` shorten, shrink and decide the limits in tests.
- Tests: `SkyCloseUpTests` and `JPEGHeaderTests` (`SkyThumbnailGeometryTests.swift`), `SkyThumbnailStoreTests` (kept beside the picture, owner and mode, remade with the picture, never
  through a link, counted and pruned, the entry's path, a night's picture size), `SkyThumbnailEngineTests` (cut around the light, made once, a replaced picture, the whole picture when it cannot be
  made and its memory, no room on the drive, two at a time, in the order asked, a full queue, a codec that hangs, the night's picture size; in `SkyRulesPicturesTests.swift`, made with the
  picture and after the page's requests) and `SkyThumbnailRealCodecsTests` (a real still through the codecs
  of the platform), with `CroppedPictureTests` in PlatformLinuxCodecsTests and `CroppedPictureAppleTests` in PlatformAppleTests for the codecs.

## Additions beyond the contract: the sky detector's rules and the guide to the unexplained (2026-10-26, docs/CONTRACT_CHANGES.md)

The owner, after a night of Sky Watcher: the unexplained were mostly planes and birds, and he wanted the rest ranked, "multiple objects moving the same direction-ish,
large, fast, a sudden change in direction". The plan's Task 11 (the rules, the unusual rule learned per camera, candidates and the alert gate) and the overnight prototype's
probable planes and satellites, in `Sky/SkyRules.swift`, `Sky/SkyBaseline.swift`, `Sky/SkyGuide.swift` and `Sky/SkyAlertGate.swift`. Public: `SkyLabel.probableSatellite`,
`SkyPriority` (`high`, `medium`, `low`), `SkyEntry.priority`, `reasons`, `doubtful` and `group`, and the new optional `SkyMeasures.strobePeriod`,
`strobeStrength`, `seenShare`, `wobble` and `turns` ("the sky detector's lights"). Internal:
- **The pipeline** (`SkyCameraDetector.classified`): the flights, then the skips (slow, wandering, busy spots, the Sun's guard), then the rules, in order (`SkyRules.verdict`,
  each with its `detail`, by `.rule`):
  - **a bug on silk** (the prototype's "drop"): a meteor's streak (below) at 1.5 to 8°/s going straight down the picture (within 8°); first, as in the prototype,
    since gravity fits better than a meteor;
  - **a meteor**: at most 2 s, at least 0.98 straight, no blink, streak-born or seen in 3 pictures (the plan's); 1.5°/s or more (the plan's 4°/s: the overnight test's
    meteors crossed 1.84 to 5.1°/s in the engine's degrees, its clear meteor 2.6°/s, and its satellites at most 1.13°/s); the Sun under −6°, alone (no other light
    began within 1 s of it) and no faster than a meteor can cross at its height (72 km/s at the distance of a height of 100 km in its direction, with half again for a
    rough aim; about 5°/s on the horizon) (the owner's nights: dusk birds are short, fast and straight; at dusk a camera change made 31 streaks along the wires in one
    picture; the fastest streaks low down were the tracker linking lights along the skyline);
  - **a bug**: blurred (focus at most 0.35) and 1° across or more, or turned by 45° three times or more (the plan's); never a steady light (a bright plane's lights spread
    to a degree on the owner's camera);
  - **a probable plane** by its strobe (a regular flash every 0.6 to 1.6 s of strength 0.3 or more, 0.25 or more over 30 s; followed 5 s or more), or a chain of flashes in
    a line (an entry of kind `flash`, straight);
  - **a bird**: the Sun at −6° or above, 0.1 to 4° across, 1 to 300°/s, curved or straight (the plan's 0.2–4°, 1–30°/s and "in focus" changed by the owner's nights: his
    dusk birds crossed up to 148°/s, birds by day are dark blobs whose focus reads 0 to 0.33, some 0.13° across);
  - **a steady light** (5 s or more, 0.98 straight, within 0.25° or half its size of a smooth path, seen in 40 % of its pictures or more, no strobe): by day slower than
    3°/s and 0.95 straight is enough, a plane; at night at 0.15 to 2°/s a **probable satellite** where a satellite could be in sunlight (some point of its line of sight
    at 200 to 1,500 km outside the Earth's shadow: `SkyRules.satelliteCouldBeSunlit`, from the Sun and the box's place, which never leaves the box), else a probable
    plane; slower, followed 8 s or more, a distant plane.
- **The unexplained**: first the doubts (`SkyRules.doubt`): it began with 2 or more other lights in its picture or within a second, or as the camera changed its picture
  (5 began at once, from 1 s before to 10 s after); it went out and came back (straightness under 0.3); a ragged path (2°/s or more, and off a smooth path by more than 0.3° and
  more than a quarter of its step); too fast and small (60°/s, under 0.25°); faster than a meteor could cross at its height (the meteor's bound: on the owner's evening,
  tracks along the power lines and the skyline). A doubted light is low, never unusual, never a candidate (`doubtful`). Then the unusual rule (`SkyBaseline`): in its band
  of elevation (0–10, 10–30, 30–60, 60–90°; all bands when its own has fewer than 10), `faster` over 1.5 × the larger p95 speed of planes and satellites, `larger` over 1.5 ×
  the planes' p95 size, `brighter` over 1.5 × the p95 brightness; before learning (30 planes) a p95 speed of 2°/s and size of 0.75° (the plan's 0.3°: the rules' planes on the
  owner's camera were 0.76° at the 95th percentile), and no `brighter`; `suddenStop` and `sharpTurn` from the shape only when it can be trusted (1°/s or more for 2 s or more,
  at most two turns, within 0.2° of a smooth path). `speedVsPlanes`: the speed over the median plane speed in its band (nil under 10 planes). The baseline learns from planes
  matched with a good aim (later: orbits' satellites), the last 500 of each kind in each band, in `baseline.json`, kept through a new card (Ruling S25: what the box learned of
  the sky is not the aim). `candidate` is unexplained and unusual. **`SkyAlertGate`** (Task 12 raises the alerts): a candidate alerts once learning is ready, unless the sky was
  known not visible and unless one alerted for the camera in the last 300 s, which it joins.
- **The guide** (`SkyGuide.assess`): **high** when faster, larger, a stop or a turn; **medium** when only brighter, a long, low, steady light that is neither a plane's nor a
  satellite's (20 s or more, under 15° up, neither blinking nor flashing like a strobe: every long, low light the rules left on the owner's nights blinked,
  and was a distant plane), or a light that appeared and stayed on one spot for seconds (2 to 60 s, ending within 0.7° of where it began: the
  prototype's "barely moved"; kept only when bright, Ruling S29); **low** otherwise. The reasons are short phrases: "Fast across the sky (about 6× a plane at that height)"
  (before learning, "about 3× typical planes", against the default speed), "Looks larger than planes here" ("than typical planes"), "Stopped suddenly", "Turned sharply",
  "Looks brighter than planes and satellites here", the doubt, or "Too short to tell a plane from a satellite", "Too short to tell what it was", "Nothing unusual about it".
- **Lights that moved together** (`SkyFormations.mark`, on the night's entries as `BridgeEngine.skyNightLog` reads them, after the older lights are sorted, so a person's word counts at
  once; the lights are taken in the order they began, and a group one of whose lights ended before a light began and its second together can take no later light, so it
  is passed over: a night of hundreds of sorted unexplained lights groups in milliseconds): unexplained lights
  the guide ranked, not doubted, seen together for 1 s or more, their headings within 20°, their speeds within 1.5×, 0.5 to 20° apart, not one behind the other on one line
  within 3° (two pieces of one light), not begun in one picture; every one moves with all the others of its group; each gets `group` ("g-" and its first light's id), the
  priority high and "Several lights moving together" first. The owner's words were "within the same few minutes": lights minutes apart made 70 to 95 such groups of plane
  and satellite fragments on the night of Oct 25; seen together, 3 (2 as the box would log that night now).
- **On the owner's logs** (a scratch replay, read-only, the place in memory only): of the prototype's labelled night of Oct 24, the rules agree on 224 of its 277 planes,
  318 of its 363 satellites (29 more are planes: no satellite can be in sunlight there), 6 of its 7 meteors (the seventh, not quite straight and not alone, ranks high) and all 7
  of its bugs; 16 of its 19 unexplained rank medium ("appeared and stayed on one spot"). Of the 1,533 unexplained of Oct 25, 910 are explained (403 birds, 257 probable
  planes, 195 probable satellites, 43 bugs, 12 meteors); with the busy spots and the Sun's guard of that day, 1,106 would be logged, 407 of them unexplained: 9 high,
  12 medium, 386 low.
- Tests: `SkyRulesTests` (the plan's nine, the strobe, the steady light and the shadow, a meteor that is no satellite, the bug on silk, the doubts, the trusted shapes,
  the baseline kept, the guide's levels and words, the groups), `SkyNightLogEngineTests.theGuideIsKeptAndLightsThatMovedTogetherAreGroupedAsTheLogIsRead`, and the
  detector suites, whose made-up lights now meet the rules.

## Additions beyond the contract: older lights sorted when the night is read, and the rules' planes and satellites with a picture (2026-10-26, docs/CONTRACT_CHANGES.md)

Two follow-ups to the rules (above). The owner's box logged the night of Oct 25 before them: 1,533 lights, every one "unexplained", which the replay of the rules
sorted. And the rules' probable planes and satellites had no picture, so the rules could not be checked by eye. Public: `SkyEntry.sortedLater` (set as the log is
read and never kept, as `group` is; in `SkyEntry.init` with a default of false, so a caller written before it compiles unchanged). Internal, in `Sky/SkySortLater.swift`
and the detector, the filter, the backfill and the thumbnails:
- **Sorted when the night is read** (`SkySortLater`, from `BridgeEngine.skyNightLog` once the lights the log kept in pieces are joined, a joined light as one:
  "one light, not fifteen", below; and for the entry a correction answers): every entry of the view that is
  unexplained, named by nothing (`by` nil) and has none of the guide's fields (`SkySortLater.needsSorting`) is judged as the detector judges a light now
  (`SkyRules.judge`, which the detector calls too: the rules' verdict, by `.rule` with its `detail`; or the doubts, the unusual rule against the camera's baseline
  now, or the defaults before it learned, `candidate`, and the guide's priority and reasons), shown as if logged so and marked `sortedLater`; then the lights that
  moved together are found on the whole view, the sorted ones among them. The log is not written: it stays append-only, and the next read sorts again, with what
  the camera has learned by then. A person's word wins as ever (`SkyDisplay`; "not sure" shows what the rules say), and the counts are of what is shown. What an
  older entry does not keep comes from the night and its path, as the replay took it: how it began, from the start times of every light of the log
  (`SkySortLater.Beginnings`: in its picture, within a second, and 5 at once from 1 s before it to 10 s after; the tracker counts the tracks it drops too, so
  these doubts are fewer than live ones); the Sun at its middle and whether a satellite could be in sunlight there; its way across the camera's picture (a bug on
  silk; none while the picture's size is not known); and the five measures it was logged without, from its path through the camera's aim now
  (`TrackMeasurer.pathMeasures`, the cheap part of `measure`): the wobble and the turns from any path, the strobe and the share of its pictures it was seen in only
  from a whole path (under 64 points, one a picture it was seen in: the pictures it was missed in are found in the gaps at the camera's pace, every point at one
  brightness), never from a path thinned to 64. They decide the rules only: the entry keeps the measures it was logged with. It is taken as not streak-born. The
  camera is its running detector's (`SkyCameraDetector.sortingCamera`: the aim, the analysed width, the picture's size, the pace and the baseline); otherwise
  (`BridgeEngine.skySortingCamera`) the card over the picture's size as last seen (the camera's stream, else the night's pictures) with the camera's
  `baseline.json` (`SkyCameraDetector.readBaseline(in:)`) or the defaults; without a picture's size no path is measured again. It runs off the main actor: a
  night of 2,000 old lights is sorted and grouped in about 25 ms of a release build on a Mac (0.5 to 1.2 s of a debug build), and the engine reads such a
  night (4.6 MB) whole in about 0.11 s, against 0.09 s for the same night logged with the rules. The grouping passes over the groups that can take no later
  light (above), which a night of hundreds of sorted unexplained lights needs, and the measurer's fits and strobe add up without an array a point (the same
  numbers). The page shows a small "Sorted later" in the player only.
- **The rules' planes and satellites keep a picture** (`SkyLightFilter.wantsStill(_:by:)`): their probable planes and satellites and a satellite's flare want
  one, as the unexplained and the rules' meteors, bugs and birds do; a flight's plane (`by: .flight`, a probable one while the aim is rough) and an orbit's
  named satellite do not. They do not count against the hour's 200 (`SkyLightFilter.countsAgainstTheHour`: the unexplained, meteors, bugs and birds that no
  flight explains, as before), so that a busy hour of satellites never takes the room of a light nothing explains; the room rule and each camera's 2 GiB bound
  their pictures with the rest. A new one has its picture live; an older one (tonight's log and last night's) gets it from the backfill.
- **The small picture is made with the big one** (`SkyCameraDetector.Context.stillWritten`, `SkyThumbnails.prepare`, `SkyThumbnailGate.run(background:)`): see "the
  Sky Watcher's small pictures".
- Tests: `SkySortLaterTests` (which lights are sorted, as the detector sorts one now, a thinned path, how a light began, a bug on silk, what the camera learned, the
  cost), `SkyNightLogEngineTests.oldLightsAreSortedByTheRulesAsTheNightIsReadAndTheLogStaysAsItWas` and `.aNightOfTwoThousandOldLightsIsReadQuickly`, and in
  `SkyRulesPicturesTests.swift` the pictures and the hour's room, the backfill, and the small pictures made with the big ones (`SkyDetectorTests`,
  `SkyThumbnailEngineTests`, `SkyThumbnailGateTests`).

## Additions beyond the contract: one light, not fifteen (2026-10-26, docs/CONTRACT_CHANGES.md)

The owner, after browsing the log: "a lot of events are one event just more than a few seconds, like if you look at the timing of the event and the
location it should understand it's one object not 15". The tracker loses a light whenever it misses it for 1.5 s or the light leaves its gate, and a new
track begins where it shows again: a plane whose lights fade for a few seconds, a light crossing a dual camera's seam (the stitch hides a strip of sky, so
in the picture the light waits at the seam, for up to 6 s on the owner's camera), a picture that froze for a moment, a light followed twice at once, and
by day the freshly lit parts of a plane's contrail. On the owner's night of Oct 25 one plane at 7:32 PM was eight entries of 2 to 39 s along one line. In
`Sky/SkyStitch.swift` (the rule), `Sky/SkyStitchHold.swift` (live) and `Sky/SkyStitch+Log.swift` (older logs). Public: `SkyEntry.pieces` (how many pieces
the box saw the light in: 1, or more for a light joined live; kept in the log only when more than 1), `SkyEntry.parts` (a light the log kept in pieces,
joined as it is read: every part's id in the order they began, its own first; empty otherwise) and `SkyEntry.stillPart`, a `SkyStillPart` (`id` and
`path`: the part whose picture the joined light shows, and that part's path, as its small picture is cut around it); `parts` and `stillPart` are never
kept; the three are in `SkyEntry.init` with defaults. Internal:
- **The rule** (`SkyStitch`, one for both sides): pieces in the analysed picture's pixels (x times its width, y times its height), times on one clock.
  - **A continuation** (`Link.next`): a piece that begins at most `longestGap` (6 s) after the light ended (or up to 1 s before: seen twice for a
    moment), and ends after it, where the light would be by then: the light's end, fitted over its last 6 s, carried on at its speed over the gap; across
    its way within 4 pixels and a quarter of its travel over the gap; along it as much behind, and ahead by that and up to 1.5 s more of its travel (at
    most 30 pixels: after a frozen picture a light shows again ahead of where it was, never behind). When both moved for 1.5 s or more they go the same
    way within 30° at 0.5 to 2 times the speed (the piece's first 3 s against the light's last 6 s or its last 3 s: a turning light's way lags over the
    longer time, a slow light that jitters says it better over it). A piece too short to say (or a flash) is placed by the light's motion and must go its
    way as far as its chord can tell (within 30° and the angle 4 pixels make across its chord, once it is 2 pixels long) and at most twice as fast (a
    contrail threw pieces of 0.2 to 0.8 s at 6 to 15 times its plane's speed along its line); a light too short to say is placed by the piece's own
    motion, carried back over the gap.
  - **Across a dual camera's seam** (`Link.seam`: the light ends within 2 % of the width of the seam in one half and the piece begins near it in the
    other) the light may have waited at the seam the whole gap: the piece may begin anywhere from the light's end to where it would be, 8 pixels more
    across.
  - **The same light followed twice** (`Link.sameLight`): within 4 pixels of each other (the median) at 3 or more pictures that both were seen in, the
    same way at about the same speed when both moved long enough to say. Lights side by side (a formation) are further apart than that, and lights that
    cross go different ways.
  - **By day, a plane's contrail** (`Link.trail`): a light that drew a line for 10 s and 60 pixels or more leaves a contrail whose freshly lit parts the
    tracker follows as lights of their own (on the owner's morning of Oct 26 one plane made 22 entries); a piece seen by day with 90 % of its points
    within 4 pixels of the line the light drew in the 15 s before is part of that light, not of its path. Never at night: a satellite train keeps to one
    line too.
  - **Flashes** (live: what the tracker drops as barely moved, streak-born or under 1.5 s) have no way of their own: one joins a light that moves, and two
    a little apart (6 pixels a second at most, 0.4 s or more apart) begin a chain that the next must continue, in a line.
  - A piece joins the light it fits best (the same light first, then a continuation, then a contrail); a light it joins takes in another light that is the
    same one, or that it continues (`Joiner`). A light is never longer than 10 minutes. The gap window was tuned on the owner's logs (below): 6 s joins
    the seam crossings (1.6 to 5.6 s) and the fades; a longer wait mostly joins faint lights low over the horizon, where it also joins different ones.
- **Live** (`SkyStitchHold`, on the detector's actor): a track that ended, kept by the tracker or a flash it dropped, joins the light it belongs to or begins
  one. A light is held for 6 s after its last piece ended and 1 s more (the tracker reports a track three pictures after it began), longer only while a
  track open now may still be part of it (`SkyTracker.openTracks`, as followed so far), at most 100 lights (the light that ended first goes first), and
  everything is let go at a gap, a restart, a new picture size, a clock that went back and the stop (to the queue, whose waiting lights the stop drops, as
  before: Ruling S27). Let go, it is one track (`SkyStitchHold.Released.track`): its spine's samples (its own pieces', not its contrail's), the pictures
  it was missed in its pieces' own and, in each gap between them, one at their pace, so that its blinking, strobe and seen share are measured over the
  whole light (a light seen in pieces at a steady rhythm is a strobe: a probable plane), with how many pieces it was seen in (`pieces`); then classified
  and logged once, with one picture of its middle. A flash alone is nothing (the tracker dropped it); 3 or more flashes in a line, over 5 s and 16 pixels
  end to end, are a chain (`SkyEntryKind.flash`, which the rules call a probable plane when straight). The tracker's coasting is unchanged (1.5 s, pinned
  by its tests): the hold joins what it loses, and a coast long enough for a 6-s gap would let a track take another light into its gate.
- **The picture of a held light** (`SkyLightFilter.stillIsOf`): the camera's ring of recent keyframes holds its last 12 s or so, and a light is handed over
  7 s or more after it ended, so the ring no longer holds the middle of a long one. Its picture is kept when it is of the middle half of the light's time,
  or within 4 s of its middle (`stillReach`: a short light, between two keyframes); otherwise the light is logged without one, and the recording gives it
  the picture of its middle (`SkyStillBackfill`, a minute later).
- **Older logs** (`SkyStitch.joined`, first in `BridgeEngine.skyNightLog`: then the lights logged before the rules are sorted, a joined light of them as
  one, so that `sortedLater`, the rules' word and the guide are the joined light's (`SkySortLater`, above), and then the lights that moved together are
  grouped; the log is not written): the moving lights of the view, in the order they began, joined by the same rule (by day where the Sun was at −6° or
  above at the box's place), in the camera's picture as the joining reads it (`BridgeEngine.skyStitchPicture`: the analysed size from the camera's main
  stream or the night's pictures, at most 1,920 wide; the seam when the camera has two lenses side by side, as set or 2:1 and wider). A joined light is one
  entry in the place of its first part (`SkyStitch.entry(of:entries:picture:corrected:)`): the first part's id and camera, `parts`, `pieces` the sum of
  its parts'; from the first part's start to the last one's end; its path the spine's, at most 64 points evenly picked; its measures put together from
  the parts' (`measures(of:)`: from where the first was first seen to where the last was last seen, the path the parts' own and the sky crossed in each
  gap, speed, straightness, turns, size, brightness and focus weighted by how long each lasted, its blinking and strobe from its pictures, the gaps dark);
  what it is, a flight's when a part matched one (the longest such), else its longest piece's (a light whose pieces were logged before the rules is then
  sorted as one); the person's latest word on any part (by when it was said:
  `SkyLogContents.corrected`); alerted when any part was; its picture the part nearest its middle that has one (`stillPart`), else none.
- **A word on a joined light** (`BridgeEngine.correctSkyEntry`): written to every part (one line each, the same time), as the view the entry began in joins
  it, and the answer is the joined light as the log reads it (sorted as one when its parts were logged before the rules); a part's earlier word still shows
  until a later one.
- **On the owner's logs** (a scratch replay, read-only, the place in memory only): Oct 25's 1,533 entries are 1,262 lights (the night view 1,055 → 858,
  the day view 478 → 404; 177 lights joined from 448 entries: 195 continuations, 56 the same light twice, 14 across the seam, 6 contrail pieces; the
  largest of 8 parts, the plane of 7:32 PM and another at 6:37 PM, each one straight line in its pictures); Oct 24's 673 are 638, Oct 26's 292 are 229
  (its largest, 11 parts, a plane's contrail at 10:11 AM). With a window of 3, 4, 5, 6, 8 and 10 s, Oct 25 is 1,310, 1,295, 1,279, 1,262, 1,244 and
  1,234 lights. Joining a night of 1,533 entries takes about 0.3 s (a debug build).
- Tests: `SkyStitchTests` (strobe gaps, a frozen picture, the seam, two planes crossing, a formation, a turn and a reversal, the same light twice, the
  contrail by day only, the hold's wait, bound and flush, flash chains, older logs, a joined light's measures and label, the lines as they were),
  `SkyStitchDetectorTests` (a light in pieces logged once with one picture of its middle, a picture the ring no longer holds, a gap and the stop, a light
  that fades twice end to end), `SkyStitchNightLogTests` (older logs read as one light and not written, a word on a joined light, a light across sunset).
