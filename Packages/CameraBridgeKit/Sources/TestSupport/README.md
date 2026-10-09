# TestSupport

Test-only helpers shared by test targets and `cbctl`; never linked by the app. Portable except for the default
`AppleNetworkTransport` (PlatformApple, under `#if os(macOS)`); everything else takes an injected `NetworkTransport`.

## Public entry points

- `TestSupportModule.makeTemporaryDirectory(prefix:)` (Wave 0; built on `TemporaryDirectory`); `RTSPTestServer` +
  `RTSPServer/` (W1-5).
- `HAPTestController` (actor, one TCP connection): `connect`/`connectVerified`/`paired`, `pairSetup(setupCode:)`,
  `pairVerify`, `listPairings`/`addPairing`/`removePairing`, `request`, `accessories()` → `HAPAccessoryDatabase`,
  `read`/`readValue`/`readData`, `write`/`writeValue`/`writeData` (`wantsResponse`, `timedWriteTTL` → `/prepare`),
  `subscribe`/`unsubscribe`, `nextEvent(for:)` (buffered) and `eventStream()`, `snapshot` (`/resource`).
  Camera helpers (`Controller/HAPTestController+Camera.swift`): `cameraIDs` (`CameraAccessoryIDs`,
  `RTPStreamManagementIDs`, `CameraRecordingIDs`), `supportedStreamingConfiguration`, `setupEndpoints`,
  `selectStream`, `startLiveStream` → `LiveStreamHandle` (`reconfigure`, `stop`), `supportedRecordingConfiguration`,
  `selectRecordingConfiguration`, `enableRecording`, `openDataStream` (SetupDataStreamTransport → HDS → hello).
- `ControllerTLV`: typed encode/decode of SetupEndpoints (request/response), SelectedRTPStreamConfiguration,
  Supported{Video,Audio}StreamConfiguration, SupportedRTPConfiguration, StreamingStatus, the three
  Supported*RecordingConfiguration values, SelectedCameraRecordingConfiguration (+ hub-like `preferred`),
  SetupDataStreamTransport request/response, SupportedDataStreamTransportConfiguration.
- `HDSTestClient` (actor): `connect`, `hello`, `sendRequest`/`sendEvent`/`sendResponse`, `nextEvent`, and the HKSV
  `dataSend` flow: `openRecording` → `DataSendOpenResult`, `receiveRecording` → `RecordingCapture` (init + whole
  fragments, `mp4`), `ackRecording`, `closeRecording`. `DataSendReassembler` checks chunking per brief §3.8.
  `TestHAPSession`: a fake `HAPSessionHandle` (known shared secret, manual `close()`, optional `zone`).
- `SRTPTestReceiver` (actor): two UDP sockets; decrypts SRTP/SRTCP, `videoFrames` (H.264 access units via
  `H264AccessUnitAssembler`: single NAL, STAP-A, FU-A) and `audioFrames` (Opus packets), `statistics`,
  `frameRecords`, `measuredFrameRate`, `firstKeyframeAt`; sends receiver reports (keepalive), PLI, return audio.
- `ControllerCLI` (the `cbctl` commands), `HAPControllerStore` (identity + pairings on disk), `HostPort`.
- Test-target helpers (`TestHelpers.swift`): `Box` (a `Mutex`-protected value: `value`, `set`, `update` returning its
  body's result, typed throws) and `eventually(timeout:every:_:)` (polls a sync or async, non-`@Sendable` condition on
  the caller's actor; default 5 s every 10 ms, then one last check after the deadline). `TemporaryDirectory`
  (`init(prefix:)` creates `<tmp>/<prefix>-<UUID>`; `url`, `file(_:)`, sorted `contents()`, `remove()`).
  In-memory transport (`FakeTransport.swift`): `FakeNetworkTransport` (listeners on fake ports from 40000,
  `listeners`, `listenCount`, `failNextListens`; `connect` refused), `FakeTCPListener` (`accept`, `beforeClose`,
  `fail()` ends the stream without `close()`, `isClosed`), `FakeTCPConnection.pair(remoteAddress:)` (`inbound`,
  `isClosed`, `stallSends()` / `stalledSendCount`, `failSends()`: sends throw `TransportError.failed` while the
  connection stays open) over `FakeByteQueue` (`pendingByteCount`, `isShutDown`,
  `isFinished`). Every test target except BridgeSupportTests uses these instead of its own copy
  (`PortabilityTests/SharedTestHelperTests` enforces it).
- `RendezvousSecretStore`: a `SecretStore` whose reads of matching accounts meet once armed (the first waits up to a
  second for a second read, both having read their value), so a read-then-write race happens every run; writes are
  counted per account (HAP and engine identity-race tests).

## Invariants

- Never advertises; connects by host and port. Setup codes, keys and shared secrets are never logged or printed.
- `HAPTestController`: requests are serialized; a request timeout closes the connection (a late answer would be
  mistaken for the next one's); frames ≤ 1024 plaintext bytes, LE length AAD, per-direction counters; an oversized
  or undecryptable frame closes the connection. Events never answer requests; `nextEvent` keeps other events buffered,
  at most `eventBufferLimit` (default 1024; oldest dropped, counted in `droppedEventCount`); `eventStream()` has its
  own 1024-event buffer. Cancellation: a waiting `nextEvent` or a request still queued for its turn ends at once with
  `CancellationError`; a request already sent does too and closes the connection (as a timeout does).
- `startLiveStream` requires the SetupEndpoints answer to echo the controller's SRTP keys, carry both accessory SSRCs
  and an address of the connection's family (`malformedResponse` otherwise, before any start command).
- `HDSTestClient` is safe for concurrent callers: each frame is sealed with the next counter and queued in the same
  actor turn, and one writer sends the queue in order (a failed write closes the stream: later counters would not
  decrypt). A cancelled `sendRequest` / `nextEvent` ends at once with `CancellationError` (a late response is dropped
  by id); unclaimed events are kept up to `eventBufferLimit` (default 512; oldest dropped, `droppedEventCount`).
- `ControllerTLV` lists are `00 00`-separated like HAP-NodeJS; decoders accept any order of list items. UUIDs are the
  16 bytes in textual order (HAP-NodeJS `uuid.write`).
- `DataSendReassembler`: sequence 1 = `mediaInitialization`, then `mediaFragment` 2, 3, …; chunks from 1, ≤ 0x40000;
  `dataTotalSize` required on chunk 1 (`missingTotalSize`), absent/null on later chunks, equal to the size (a packet
  growing past it fails at that chunk); `endOfStream` only on the last chunk of the final packet.
- `H264AccessUnitAssembler`: a sequence gap at a timestamp change while a unit is open (marker not seen) flags both
  that unit and the next as incomplete (the loss cannot be attributed); a gap after a marker flags the next unit only.
- `SRTPTestReceiver`: one key/salt per stream for both directions; packets with another SSRC than SetupEndpoints
  returned are counted and dropped; incomplete access units (loss, broken FU-A) are delivered flagged.
- `HAPControllerStore`: creates its directory 0700; an existing directory must have no group/other permissions
  (`insecureDirectory`; never chmodded); `controller.json` / `accessories.json` 0600, written atomically.
- Fake transport: `FakeByteQueue.receive` (and so `FakeTCPConnection.receive`) honours cancellation like
  `AppleTCPConnection.receive` (`CancellationError`, nothing consumed), so a `withTimeout` or time limit can end it;
  `close()` fails this end's receives with `TransportError.closed` and gives the peer EOF after the bytes already
  sent; a send that is not stalled delivers without suspending; a stalled send waits until `close()` (cancellation
  does not end it, as with `AppleTCPConnection.send`) and then throws `TransportError.closed`.
- `ControllerCLI.pair` stores the pairing right after pair-setup (before pair-verify and /accessories), so a later
  failure never strands an accessory that counts cbctl as its admin.

## References

Research brief §3.1–§3.8; HAP-NodeJS 2.2.3 (Apache-2.0) `test-utils/*Client.ts`, `lib/camera/*`,
`lib/datastream/*` — derived files carry the attribution header. RFC 3550, 3711, 6184.
Self-tests: `Tests/IntegrationTests/ControllerSelfTests.swift` (`swift test --filter IntegrationTests.ControllerSelfTests`):
end to end against a real HAPCamera `CameraController` with fake delegates (`HAPCameraAccessoryTests`, always run),
and against a plain HAP
accessory standing in for a camera for negative cases and knobs (`FakeCamera`). The plan W3-2 end-to-end scenarios
(`Tests/IntegrationTests/EndToEnd`) drive a real `BridgeEngine` with these helpers.

`FakeHelperLauncher` / `FakeHelperProcess` (2026-10-08): a `HelperLaunching` whose processes the test drives (output lines, exits, SIGTERM handling); each
remembers the launch spec and the configuration file named by `-c` as it was at launch (for tests of what a helper is given).
