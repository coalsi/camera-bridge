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
  replaced by a passthrough that would not fit (HEVC, a timestamp overlay, a profile/level over the request; only a transcode
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
(for the runtime's network-change path) forgets it. `StreamAddress.accessoryAddress` prefers an IPv6 address in the controller's /64, else a
stable global, else a stable ULA, never a temporary or deprecated one (`SIOCGIFAFLAG_IN6`). New `NetworkNotice.Kind`s: `.liveViewNotReceived`
(a session ended blind; settled `.reached` when a later session of that controller received video), `.localNetworkDenied` (a fatal send
errno EHOSTUNREACH / EPERM persisted) and `.dualHomedSubnet` (two interfaces hold addresses on one subnet; said once per subnet and hour).
`controllerOnVPN` no longer fires for a routed subnet (a specific route through a LAN interface covers the address, `StreamAddress.routeTable`),
this Mac's own LAN address, or an advertised address the HAP connection itself comes from.

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
detail page (`StreamsSection` in `App/Sources/Manager/CameraDetailView.swift`). `LiveSessionStatus.health` (the stream health check's
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
keeps the camera's own size (`MediaFit.liveEncoderSettings` / `recordingEncoderSettings`). The look (position, size, text options,
camera name) is applied in place to running streams through the camera's `TimestampOverlayControl` (no restart); turning it on or
off restarts the camera's runtime (`BridgeEngine.needsRestart`). The time shown is each picture's `wallClock` corrected by the hub's
measured `wallClockOffset`, so an RTSP camera whose own clock runs off shows the Mac's time. `BridgeEngine.setCameraClockHidden(cameraID:hidden:)`
turns the camera's own on-screen clock off and back on (`CameraSettingsService.hideCameraClock`) and keeps how in
`CameraConfiguration.hiddenCameraClock`, which only the engine writes (`updateCamera` keeps the engine's value).
Internal: `EngineTuning` (`Runtime/EngineTuning.swift`; `afterSensorsBridgeStatus` is a test hook) +
`BridgeEngine.init(environment:tuning:)` (tests shrink the demo camera and shorten timers), `BridgeEngine.networkSettle`,
`CameraRuntime`, `IngestSupervisor`, `StreamTraits`, `StreamSources`, `AccessoryOptions`, `SoftMotionMonitor`, `ControllerRegistry`,
`MediaFit`, `H264Levels` (HAP level → level_idc; limits from MediaCore's `H264LevelLimits`), `StreamAddress`, `InterfaceAddress`, `OpusRepacketizer`, `TimelineRebaser`, `StreamingHandler`, `LiveStreamPipeline`,
`TalkbackBridge`, `RecordingHandler`, `RecordingProducer`, `SnapshotProvider`, `PowerController`, `LocalNetworkCheck`,
`LogCollector`, `ChangeSignal` (deadlines and the FIFO lock are BridgeSupport's `withDeadline` and `AsyncSerialLock`).

## Part A (W2-3) entry points — additions beyond the contract

- `ConfigurationStore` (`config.json`) + `BridgeConfiguration` (settings + cameras), `ConfigurationStoreError`,
  `ConfigurationMigration`; `CameraConfiguration.withoutStreamCredentials`.
- `CredentialStore.credentials(for:)`, `.forgetCamera(_:dataDirectory:)`, `.account(for:)`; `HAPStorage` (FileHAPStore
  accounts/directories for cameras and the sensors bridge).
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
