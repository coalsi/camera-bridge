# HAPCamera

Camera / video doorbell controller (plan task W2-1, done): RTP stream management, HKSV recording management, operating
mode, data stream transport + HDS `dataSend`, motion sensor, doorbell, microphone/speaker. Portable: depends on HAP,
HDS, HAPCore, BridgeSupport only (SHA-256 via `HAPCrypto.sha256`).

## Public entry points

- `CameraController`: `init(configuration:streamingDelegate:recordingDelegate:dataStreamServer:)`, `install(on:server:)`
  (adds services, `/resource` + `dataSend` handlers, restores state), `setMotionDetected`, `ringDoorbell`,
  `setStreamingAvailable`, `stopStreamingSession`, `setSensorStatus`, `operatingState` / `operatingStateChanges`,
  `motionService`, `active*Streams`.
- Delegates: `CameraStreamingDelegate` (snapshot, prepareStream, start/reconfigure/stop), `CameraRecordingDelegate`.
- `CameraTLV`: every camera TLV (Supported*, SetupEndpoints, SelectedRTPStreamConfiguration, selected recording
  configuration, SetupDataStreamTransport, StreamingStatus) in both directions — also for test controllers.

## Additions beyond the contract

`CameraController.init(…, timings:, log:)` (`log`: the camera's logger, category "camera", used by the
controller, its stream managements and recording streams; default untagged) + `CameraControllerTimings` (12 s ack,
10 s stop, 3 min cap backstopped one fragment + 5 s later (`recordingCapGrace`), 8 s streaming delegate deadline; tests
shorten them), `CameraController.stopStreamingSession(_:) -> Bool` (HAP-NodeJS `forceStopStreamingSession`: the
accessory ends a live session, e.g. after 30 s without controller RTCP), `CameraTLV` and its nested request/response
types, `CameraTLVError`; public memberwise inits of the parameter structs; `PrepareStreamRequest.connectionZone` (W4
review round 4: the HAP session's IPv6 zone, `HAPSessionHandle.zone`, which a link-local `controllerAddress` needs —
SetupEndpoints carries none; default nil, not in the initializer; `RTPStreamManagement` fills it).

Session lifecycle (2026-10-03, hardening plan WS-C): `CameraControllerTimings.preparedSessionTimeout` (20 s: a session that was
prepared and never started is ended, the stream service reports available again and the delegate gets its one `.stop`) and
`staleUnstartedSessionAge` (15 s). A new SetupEndpoints finds a service busy with a session that was never started and takes it
over when it comes from the same controller or HAP connection, or the session is older than 15 s; a started session yields only to
a setup on the HAP connection that owns it (another connection of the same controller may be that user's other device). The
controller's End frees the service at once and the delegate's `.stop` follows without holding the HAP write up.
`CameraController.stopUnstartedStreamingSessions(because:)` (the wake path). A `dataSend/open` from another HDS connection than the
one holding the recording slot cancels that stream (`.cancelled`, delegate told) and is accepted; the same connection still gets
busy. A stream that replaces another asks the delegate for its packets only after the predecessor's end was delivered to the
delegate (`RecordingStream` predecessor, bounded by the stop timeout), so a late end of an old stream never cancels a new
producer that reuses its stream ID.

## Invariants

- TLVs are byte-exact to HAP-NodeJS (list items separated by `00 00`; Opus-only audio, comfort noise off, 1 channel,
  variable bitrate). Triggers: motion, plus doorbell when `isDoorbell`. Parsers throw on missing/out-of-range fields.
- Services: [Doorbell primary, validValues [0]] + RTP management ×max(1, streamCount) (subtypes "0"…, `Active` 1) +
  Microphone (+ Speaker if twoWayAudio; Mute false, Volume 100) + [RecordingManagement (DataStreamTransport + motion
  linked), OperatingMode, DataStreamTransport — with recording; OperatingMode also for night vision/indicator] + Motion.
- Live sessions (per stream service, one FIFO lock): the delegate sees `prepareStream`, then `.start`/`.reconfigure`,
  then exactly one `.stop` for every successful prepare (end command, failed start/reconfigure, HAP connection of the
  setup closing, `Active` or HomeKitCameraActive off, a setup whose HAP request timed out, `stopStreamingSession`).
  Suspend/resume, unknown session, second start, reconfigure before start → -70410; stream `Active` 0 or
  HomeKitCameraActive 0 → -70412. `stopStreamingSession` does not wait (safe inside a delegate call); `.stop` follows
  once the service's current operation is done.
- Delegate deadline: every `prepareStream` / `handleStreamRequest` call has 8 s (`streamingDelegateTimeout`, below
  HAP's 9 s; BridgeSupport's `withDeadline`, and the FIFO lock is its `AsyncSerialLock`). A call that misses it (or whose HAP request timed out, for prepare/start/reconfigure) is cancelled and
  abandoned: the request fails with -70408, the service moves on (later calls may then overlap the abandoned one), a
  failed start/reconfigure still ends the session with `.stop`, and a `prepareStream` that succeeds after its setup
  was abandoned gets its `.stop` then. A setup or command whose HAP request times out while it waits for the lock
  leaves the queue without reaching the delegate. Delegates should still answer promptly.
- One close handler per (stream service, HAP connection), however many setups the connection sends; it ends whichever
  session that connection owns and drops its busy/error read-back. Likewise one per HDS connection for recordings.
- SetupEndpoints reads per HAP session, through GET /characteristics and `/accessories` alike: the owner gets its
  read-back, a refused controller gets `{id, busy|error}`, everyone else `{2:2}`. The HAP module never stores a
  control point's written request or read-back (it asks the read handler on every `/accessories`, also within 5 s of
  the previous one), so no controller sees another's SRTP keys (deviation from HAP-NodeJS, which serves the stored
  value). Default MTU 1378 (IPv4) / 1228 (IPv6).
  StreamingStatus: in use while a session exists, else available / unavailable (`setStreamingAvailable`); unavailable
  services answer setups with error.
- Peer address: `PrepareStreamRequest.peerAddress` is the HAP TCP connection's remote address (the controller's
  SetupEndpoints address can be a VPN's); `localAddress` (the answer's accessory address) is on the peer's interface.
- Address family: the read-back's version is the controller's requested one. `PrepareStreamRequest.localAddress` is
  the HAP connection's local address; when the controller asks for the other family, the delegate must answer with an
  address of the requested family (`::ffff:a.b.c.d` counts as IPv4), otherwise (or for anything that is no IP
  literal) the setup fails with -70402, an error read-back and `.stop` (HAP-NodeJS: "ip versions must be the same").
- Writes of Active (recording, RTP), SelectedCameraRecordingConfiguration, HomeKitCameraActive, Event/Periodic
  snapshots are admin-only (-70401). State writes run one at a time, call the delegate in order, persist, then answer,
  so `updateRecordingActive` / `updateRecordingConfiguration` / `updateRecordingAudioActive` must return promptly and
  schedule heavy work (e.g. restarting the producer) in the background; a call over 1 s is logged, one near 9 s makes
  the hub's write fail with -70408 and holds up every other state write meanwhile.
- Persistence: `extras["camera"]` JSON (`PersistedCameraState`); the selection is kept only while SHA-256 of the three
  Supported*Recording values (base64, as HAP-NodeJS) matches. `install` reports configuration, active and audio
  active to the recording delegate once. Missing fields take their defaults (state from another version stays
  readable); unreadable state is ignored and rewritten. Night vision/indicator default on. The state belongs to the
  pairing: an accessory without pairings starts from the factory state below (pairings cleared while the camera was
  not running, e.g. `BridgeEngine.resetPairing` of a stopped camera).
- Unpairing (HAP-NodeJS `handleAccessoryUnpairedForControllers` → `handleFactoryReset`): `install` watches
  `server.events`; on `.unpaired` (the last admin removed, `resetPairings`) the selection is dropped, recording Active
  and RecordingAudioActive go to 0, HomeKitCameraActive / EventSnapshotsActive / PeriodicSnapshotsActive and every RTP
  `Active` to 1 (StatusActive follows), the microphone and speaker are unmuted at volume 100, a running recording is
  closed `.notAllowed`, live sessions end, the recording delegate hears active false, configuration nil and audio
  active false (each only if it changed), and the result is persisted. Night vision and the indicator stay.
- HomeKitCameraActive 0: StatusActive false (it is sensor active AND camera active), snapshots and setups refused,
  live streams stopped, recording closed `.notAllowed`. Recording Active 0 also closes the recording `.notAllowed`.
- Snapshots (brief §3.5): all streams inactive or camera off → -70412; event/periodic off → -70412 for that reason,
  -70401 without a reason; delegate errors → their `HAPStatus` or -70402; empty JPEG → -70402.
- `dataSend/open`: wrong target/type/streamId → 5, recording or camera off → 1, busy → 2, no selection → 9. Packets:
  first `mediaInitialization` seq 1, then `mediaFragment` 2…; chunks ≤ 0x40000 numbered from 1; `dataTotalSize` on
  chunk 1; `endOfStream` = packet.isLast on each packet's last chunk (HAP-NodeJS). One stream at a time; the hub's
  `ack` / `close` (or its HDS connection closing) frees the slot before the next message is handled, so an `open`
  right behind it (e.g. continuing an event after the 3-minute cap) is not refused as busy.
- A recording ends once: ack → `acknowledgeStream`; hub close / HDS close → `closeRecordingStream(reason / nil)`; our
  close queues `dataSend/close` (no ack 12 s after the last packet → cancelled; delegate error → its
  `HDSProtocolReason` or unexpectedFailure; camera or recording off → notAllowed) and never waits for it: the slot is
  freed, the delegate told and the 10 s stop watchdog started at once, also when a hub that stopped reading holds a data
  event in the transport. The delegate hears it only after `recordingStream(streamID:)` was called (possibly while it
  runs). Ending drops the delegate's stream (`onTermination`); a sender still busy 10 s later, or a close event still
  unsent 10 s later, gets its HDS connection closed. The delegate owns the 3-minute cap: every packet goes out as it
  marks it, also after the cap (its last fragment can come up to one fragment later, as the second of two that one
  keyframe closes). Only as a backstop, a stream the delegate has not ended by 3 minutes + the selected fragment length
  + 5 s (`recordingCapGrace`) has its next packet sent as the last one. A stream closed before it started (camera
  turned off while its open was in flight) answers the open with that reason and sends no close event.
- No SRTP keys, salts or secrets are logged.

## References

Research brief §3.5, §3.7, §3.8; integration brief §5; HAP-NodeJS 2.2.3 `lib/camera/{RTPStreamManagement,
RecordingManagement}.ts`, `lib/controller/{CameraController,DoorbellController}.ts`, `lib/datastream/DataStreamManagement.ts`
(Apache-2.0; derived files carry the attribution header). Tests: `Tests/HAPCameraTests` (W1-9 goldens in `Fixtures/`,
handler-level tests, loopback HDS, an in-memory HDS transport whose sends can stall (a hub that stopped reading), and
loopback HAP + HDS end-to-end tests driven by TestSupport's `HAPTestController` and `HDSTestClient`, including
unpair → re-pair). The normative timer defaults are pinned by `RecordingStreamTests.timersDefaultToTheBriefsValues`.
