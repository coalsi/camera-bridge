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
  `discoverCameras()` returns nothing in loopback-only environments (tests never multicast).
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
work on the camera's own serial queue (the recorder never waits for a drive; 15 s or 256 MiB pending is a stall). A file has one anchor; fragment times are media times from it; a break (reconnect, decode time back or far forward,
parameter-set or audio-format change, 15 s without video, 1 s of drift twice) closes it and the next keyframe opens a new one; 900 s or 2 GiB ends it at a keyframe without a gap. `FragmentIndexer` (package) measures a stored
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
