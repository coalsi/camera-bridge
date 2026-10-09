#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import PlatformApple
import RTSP
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

/// Supervised ingest (plan W3-1 item 1; spec §7): RTSP from `RTSPTestServer` into a `MediaHub`, reconnect with backoff
/// after a drop, the 15 s watchdog (shortened), rejected credentials, and the Reolink-style fallback source after three
/// failed attempts.
@Suite struct RuntimeIngestTests {
    static let log = Log(category: "IngestTest")
    static let credentials = HTTPCredentials(username: "admin", password: "s3cret")

    /// A source whose behaviour the test scripts.
    final class ScriptedSource: MediaSource {
        enum Behavior: Sendable {
            case fail(RTSPError)
            case failTransport(TransportError)
            /// One keyframe, then silence until stopped.
            case oneKeyframeThenHang
            /// One keyframe at `pts` (90 kHz), then silence until stopped.
            case keyframeThenHang(pts: Int64)
            /// Audio every 50 ms (and, with `keyframeFirst`, one keyframe before it) until stopped: video never flows.
            case audioOnly(keyframeFirst: Bool)
        }

        let displayName = "Scripted"
        let behavior: Behavior
        let calls: Box<Int>
        let stops = Box(0)
        private let continuation = Mutex<AsyncThrowingStream<MediaSample, any Error>.Continuation?>(nil)

        init(_ behavior: Behavior, calls: Box<Int>) {
            self.behavior = behavior
            self.calls = calls
        }

        func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
            calls.update { $0 += 1 }
            switch behavior {
            case .fail(let error):
                throw error
            case .failTransport(let error):
                throw error
            case .oneKeyframeThenHang, .keyframeThenHang:
                var pts: Int64 = 0
                if case .keyframeThenHang(let value) = behavior { pts = value }
                let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
                continuation.yield(.video(EncodedVideoFrame(format: VideoFormat(codec: .h264, width: 64, height: 64, parameterSets: []),
                                                            nalUnits: [Data([0x65, 0])], isKeyframe: true, pts: MediaTime(value: pts, timescale: 90_000),
                                                            wallClock: Date())))
                self.continuation.withLock { $0 = continuation }
                return stream
            case .audioOnly(let keyframeFirst):
                let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
                if keyframeFirst {
                    continuation.yield(.video(EncodedVideoFrame(format: VideoFormat(codec: .h264, width: 64, height: 64, parameterSets: []),
                                                                nalUnits: [Data([0x65, 0])], isKeyframe: true, pts: MediaTime(value: 0, timescale: 90_000),
                                                                wallClock: Date())))
                }
                let feeder = Task {
                    var pts: Int64 = 0
                    while !Task.isCancelled {
                        continuation.yield(.audio(EncodedAudioFrame(format: .aacLC(sampleRate: 16_000, channels: 1), data: Data([1, 2, 3]),
                                                                    pts: MediaTime(value: pts, timescale: 16_000), sampleCount: 1024, wallClock: Date())))
                        pts += 1024
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                continuation.onTermination = { _ in feeder.cancel() }
                self.continuation.withLock { $0 = continuation }
                return stream
            }
        }

        func stop() async {
            stops.update { $0 += 1 }
            continuation.withLock { $0 }?.finish()
        }
    }

    /// Review finding (W4): an offline camera flipped back to `.connecting` at every retry, so StatusFault, StatusActive
    /// and the bridged sensors' reachability went healthy for the length of each connection attempt.
    @Test(.timeLimit(.minutes(1))) func anOfflineStreamStaysOfflineWhileItRetries() async throws {
        let calls = Box(0)
        let events = Events()
        let source = IngestSupervisor.Source(label: "RTSP") { ScriptedSource(.fail(.timeout), calls: calls) }
        let ingest = IngestSupervisor(name: "Main stream", hub: MediaHub(), primary: source, timing: Self.fast(), log: Self.log,
                                      onEvent: events.handler)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(5)) { calls.value >= 4 })
        await ingest.stop()
        let states = events.states
        #expect(states.first == .connecting)
        let firstOffline = try #require(states.firstIndex { if case .offline = $0 { true } else { false } })
        #expect(!states[firstOffline...].contains(.connecting), "retries of an offline camera keep it offline: \(states)")
        #expect(states.last == .idle)

        // Once online again, a later drop reports `.connecting` → … as usual; the router sees online in between.
        let working = Events()
        let flaky = Box(0)
        let recovering = IngestSupervisor.Source(label: "RTSP") {
            flaky.value < 2 ? ScriptedSource(.fail(.timeout), calls: flaky) : ScriptedSource(.oneKeyframeThenHang, calls: flaky)
        }
        let second = IngestSupervisor(name: "Main stream", hub: MediaHub(), primary: recovering, timing: Self.fast(), log: Self.log,
                                      onEvent: working.handler)
        await second.start()
        #expect(await eventually(timeout: .seconds(5)) { await second.state == .online })
        #expect(working.states == [.connecting, .offline("the camera’s video stream didn’t answer in time"), .online])
        await second.stop()
    }

    /// Review finding (W4): audio alone made the stream "online" and fed the stall watchdog, so a camera whose video
    /// never became decodable (or froze while audio flowed, as on HTTP-FLV) was advertised as streaming.
    @Test(.timeLimit(.minutes(1))) func audioAloneNeitherBringsTheStreamOnlineNorFeedsTheWatchdog() async throws {
        // No video at all: never online, and these attempts count towards the fallback.
        let primaryCalls = Box(0), fallbackCalls = Box(0)
        let events = Events()
        let ingest = IngestSupervisor(name: "Main stream", hub: MediaHub(),
                                      primary: IngestSupervisor.Source(label: "RTSP") { ScriptedSource(.audioOnly(keyframeFirst: false), calls: primaryCalls) },
                                      fallback: IngestSupervisor.Source(label: "HTTP-FLV") { ScriptedSource(.fail(.notFound), calls: fallbackCalls) },
                                      timing: Self.fast { $0.watchdog = .milliseconds(400) }, log: Self.log, onEvent: events.handler)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(10)) { fallbackCalls.value >= 1 }, "attempts without video count towards the fallback")
        await ingest.stop()
        #expect(!events.states.contains(.online))
        #expect(events.states.contains(.offline("no video for 0.4 s")))

        // One keyframe, then audio only (frozen video): the watchdog still fires.
        let calls = Box(0)
        let frozen = Events()
        let second = IngestSupervisor(name: "Main stream", hub: MediaHub(),
                                      primary: IngestSupervisor.Source(label: "HTTP-FLV") { ScriptedSource(.audioOnly(keyframeFirst: true), calls: calls) },
                                      timing: Self.fast { $0.watchdog = .milliseconds(400) }, log: Self.log, onEvent: frozen.handler)
        await second.start()
        #expect(await eventually(timeout: .seconds(5)) { calls.value >= 2 })
        await second.stop()
        #expect(frozen.states.contains(.online))
        #expect(frozen.states.contains(.offline("no video for 0.4 s")))
    }

    /// Review finding (W4): rejected credentials counted towards the Reolink fallback, whose switch cut the 10 min
    /// unauthorized wait to the initial backoff — two failed logins about 1 s apart with the same password.
    @Test(.timeLimit(.minutes(1))) func rejectedCredentialsNeverSwitchToTheFallbackNorShortenTheWait() async throws {
        let primaryCalls = Box(0), fallbackCalls = Box(0)
        let ingest = IngestSupervisor(name: "Main stream", hub: MediaHub(),
                                      primary: IngestSupervisor.Source(label: "RTSP") { ScriptedSource(.fail(.unauthorized), calls: primaryCalls) },
                                      fallback: IngestSupervisor.Source(label: "HTTP-FLV") { ScriptedSource(.fail(.unauthorized), calls: fallbackCalls) },
                                      timing: Self.fast { $0.unauthorizedRetry = .milliseconds(500); $0.initialBackoff = .milliseconds(10) },
                                      log: Self.log)
        await ingest.start()
        try await Task.sleep(for: .milliseconds(1_800))   // attempts at 0, 0.5, 1.0, 1.5 s
        await ingest.stop()
        #expect(fallbackCalls.value == 0, "the fallback sends the same credentials")
        #expect(primaryCalls.value <= 4, "every retry waits the unauthorized delay (\(primaryCalls.value) attempts)")
    }

    /// Review finding (W4 round 2): every wake and network change called `reconnect()`, which cancelled the 10 min wait
    /// after rejected credentials and logged in again at once; a wake (often with a path change or two) was enough
    /// failed logins to lock a Hikvision account. The wait now holds across `reconnect()` and a stop/start (the sub
    /// stream's idle stop).
    @Test(.timeLimit(.minutes(1))) func aReconnectNeverShortensTheWaitAfterRejectedCredentials() async throws {
        let calls = Box(0)
        let events = Events()
        let ingest = IngestSupervisor(name: "Main stream", hub: MediaHub(),
                                      primary: IngestSupervisor.Source(label: "RTSP") { ScriptedSource(.fail(.unauthorized), calls: calls) },
                                      timing: Self.fast { $0.unauthorizedRetry = .seconds(600) }, log: Self.log, onEvent: events.handler)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(5)) { events.all.value.contains(.unauthorized) })
        for _ in 0..<5 { await ingest.reconnect() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.value == 1, "a wake or network change must not log in again (\(calls.value) attempts)")
        #expect(await ingest.isRunning)
        // The sub stream's idle stop and a later start keep the wait too.
        await ingest.stop()
        await ingest.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.value == 1, "a restart of the same supervisor must not log in again (\(calls.value) attempts)")
        #expect(await ingest.state == .offline("the camera rejected the user name or password for its video stream"))
        await ingest.stop()

        // A reconnect during the wait changes nothing; once the wait is over, the next attempt runs.
        let retried = Box(0)
        let short = IngestSupervisor(name: "Main stream", hub: MediaHub(),
                                     primary: IngestSupervisor.Source(label: "RTSP") { ScriptedSource(.fail(.unauthorized), calls: retried) },
                                     timing: Self.fast { $0.unauthorizedRetry = .milliseconds(600) }, log: Self.log)
        await short.start()
        #expect(await eventually(timeout: .seconds(5)) { retried.value >= 1 })
        await short.reconnect()
        #expect(retried.value == 1)
        #expect(await eventually(timeout: .seconds(5)) { retried.value >= 2 }, "the wait still ends")
        await short.stop()
    }

    /// Review finding (W4 round 2): the source that worked (Reolink HTTP-FLV with RTSP off) was forgotten at every
    /// reconnect, so every wake or network change took the camera offline for three failed RTSP attempts.
    @Test(.timeLimit(.minutes(1))) func aReconnectStaysOnTheSourceThatDeliveredVideo() async throws {
        let primaryCalls = Box(0), fallbackCalls = Box(0)
        let events = Events()
        let ingest = IngestSupervisor(name: "Main stream", hub: MediaHub(),
                                      primary: IngestSupervisor.Source(label: "RTSP") { ScriptedSource(.fail(.timeout), calls: primaryCalls) },
                                      fallback: IngestSupervisor.Source(label: "HTTP-FLV") { ScriptedSource(.oneKeyframeThenHang, calls: fallbackCalls) },
                                      timing: Self.fast(), log: Self.log, onEvent: events.handler)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(10)) { await ingest.state == .online })
        #expect(await ingest.sourceLabel == "HTTP-FLV")
        let primaryBefore = primaryCalls.value
        let statesBefore = events.states.count
        await ingest.reconnect()
        #expect(await eventually(timeout: .seconds(5)) { fallbackCalls.value >= 2 })
        #expect(await eventually(timeout: .seconds(5)) { await ingest.state == .online })
        #expect(primaryCalls.value == primaryBefore, "the reconnect goes straight to the source that worked")
        let after = Array(events.states[statesBefore...])
        #expect(!after.contains { if case .offline = $0 { true } else { false } }, "no offline state across the reconnect: \(after)")
        // The same after a stop and start (an on-demand sub stream's idle stop).
        await ingest.stop()
        await ingest.start()
        #expect(await eventually(timeout: .seconds(5)) { await ingest.state == .online })
        #expect(primaryCalls.value == primaryBefore)
        await ingest.stop()
    }

    /// Streams keyframes until stopped; `stop()` takes `stopDelay` (an RTSP TEARDOWN to a camera that went away).
    final class SlowStopSource: MediaSource {
        let displayName = "Slow"
        let stopDelay: Duration
        let stopsStarted: Box<Int>
        let stopsFinished: Box<Int>
        private let feeder = Mutex<Task<Void, Never>?>(nil)

        init(stopDelay: Duration, stopsStarted: Box<Int>, stopsFinished: Box<Int>) {
            self.stopDelay = stopDelay
            self.stopsStarted = stopsStarted
            self.stopsFinished = stopsFinished
        }

        func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
            let task = Task {
                var pts: Int64 = 0
                while !Task.isCancelled {
                    continuation.yield(.video(EncodedVideoFrame(format: VideoFormat(codec: .h264, width: 64, height: 64, parameterSets: []),
                                                                nalUnits: [Data([0x65, 0])], isKeyframe: true,
                                                                pts: MediaTime(value: pts, timescale: 90_000), wallClock: Date())))
                    pts += 9_000
                    try? await Task.sleep(for: .milliseconds(100))
                }
                continuation.finish()
            }
            feeder.withLock { $0 = task }
            return stream
        }

        func stop() async {
            stopsStarted.update { $0 += 1 }
            try? await Task.sleep(for: stopDelay)
            feeder.withLock { $0 }?.cancel()
            stopsFinished.update { $0 += 1 }
        }
    }

    final class Events: Sendable {
        let all = Box<[IngestSupervisor.Event]>([])
        var handler: @Sendable (IngestSupervisor.Event) -> Void { { [all] event in all.update { $0.append(event) } } }
        var states: [IngestSupervisor.State] {
            all.value.compactMap { if case .state(let state) = $0 { state } else { nil } }
        }
    }

    static func rtspServer(credentials: HTTPCredentials? = RuntimeIngestTests.credentials) async throws -> RTSPTestServer {
        var configuration = RTSPTestServer.Configuration()
        configuration.credentials = credentials
        configuration.authentication = .digest
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil),
                                    transport: AppleNetworkTransport(), configuration: configuration)
        try await server.start()
        return server
    }

    static func rtsp(_ server: RTSPTestServer, credentials: HTTPCredentials?) -> IngestSupervisor.Source {
        let url = server.url
        return IngestSupervisor.Source(label: "RTSP") {
            RTSPMediaSource(configuration: RTSPConfiguration(url: url, credentials: credentials, timeout: .seconds(5)), displayName: "Test",
                            transport: AppleNetworkTransport())
        }
    }

    static func fast(_ configure: (inout IngestSupervisor.Timing) -> Void = { _ in }) -> IngestSupervisor.Timing {
        var timing = IngestSupervisor.Timing()
        timing.initialBackoff = .milliseconds(100)
        timing.maximumBackoff = .milliseconds(400)
        timing.minimumSwitchInterval = .zero
        configure(&timing)
        return timing
    }

    @Test(.timeLimit(.minutes(1))) func rtspIngestReconnectsAfterADrop() async throws {
        let server = try await Self.rtspServer()
        let hub = MediaHub()
        let events = Events()
        let ingest = IngestSupervisor(name: "Main stream", hub: hub, primary: Self.rtsp(server, credentials: Self.credentials), timing: Self.fast(),
                                      log: Self.log, onEvent: events.handler)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(10)) { await ingest.state == .online })
        #expect(await eventually { await hub.lastKeyframe != nil })
        #expect(events.states.prefix(2) == [.connecting, .online])

        server.dropConnections()
        #expect(await eventually(timeout: .seconds(10)) { events.states.contains { if case .offline = $0 { true } else { false } } })
        #expect(await eventually(timeout: .seconds(10)) {
            let attempts = await ingest.attempts
            let state = await ingest.state
            return attempts >= 2 && state == .online
        })
        #expect(await eventually { await hub.lastKeyframe != nil }, "video flows again after the reconnect")

        let stopped = ContinuousClock.now
        await ingest.stop()
        #expect(ContinuousClock.now - stopped < .seconds(3))
        #expect(await ingest.state == .idle)
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1))) func rejectedCredentialsAreReportedAndRetriedSlowly() async throws {
        let server = try await Self.rtspServer()
        let hub = MediaHub()
        let events = Events()
        let ingest = IngestSupervisor(name: "Main stream", hub: hub,
                                      primary: Self.rtsp(server, credentials: HTTPCredentials(username: "admin", password: "wrong")),
                                      timing: Self.fast { $0.unauthorizedRetry = .seconds(2) }, log: Self.log, onEvent: events.handler)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(10)) { events.all.value.contains(.unauthorized) })
        #expect(events.states.contains(.offline("the camera rejected the user name or password for its video stream")))
        // No hammering: the next attempt waits for the unauthorized retry, not the 100 ms backoff.
        try await Task.sleep(for: .milliseconds(800))
        #expect(await ingest.attempts == 1)
        #expect(await eventually(timeout: .seconds(5)) { await ingest.attempts >= 2 })
        await ingest.stop()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1))) func watchdogReconnectsASilentStream() async throws {
        let calls = Box(0)
        let hub = MediaHub()
        let events = Events()
        let source = IngestSupervisor.Source(label: "RTSP") { ScriptedSource(.oneKeyframeThenHang, calls: calls) }
        let ingest = IngestSupervisor(name: "Main stream", hub: hub, primary: source, timing: Self.fast { $0.watchdog = .milliseconds(600) },
                                      log: Self.log, onEvent: events.handler)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(5)) { calls.value >= 2 })
        #expect(events.states.contains(.online))
        #expect(events.states.contains(.offline("no video for 0.6 s")))
        await ingest.stop()
    }

    @Test(.timeLimit(.minutes(1))) func fallsBackAfterThreeFailedAttemptsAndBack() async throws {
        let primaryCalls = Box(0), fallbackCalls = Box(0)
        let hub = MediaHub()
        let primary = IngestSupervisor.Source(label: "RTSP") { ScriptedSource(.fail(.timeout), calls: primaryCalls) }
        let fallback = IngestSupervisor.Source(label: "HTTP-FLV") { ScriptedSource(.fail(.notFound), calls: fallbackCalls) }
        let events = Events()
        let ingest = IngestSupervisor(name: "Main stream", hub: hub, primary: primary, fallback: fallback, timing: Self.fast(), log: Self.log,
                                      onEvent: events.handler)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(10)) { fallbackCalls.value >= 3 && primaryCalls.value >= 4 })
        // Exactly three tries of each before switching.
        #expect(primaryCalls.value >= 3 && (primaryCalls.value - 3) <= fallbackCalls.value)
        #expect(events.states.contains(.offline("the camera’s video stream didn’t answer in time")))
        #expect(events.states.contains(.offline("the camera has no video stream at this address")))
        await ingest.stop()

        // A working fallback stays online.
        let working = IngestSupervisor(name: "Main stream", hub: hub, primary: primary,
                                       fallback: IngestSupervisor.Source(label: "HTTP-FLV") {
                                           syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil)
                                       }, timing: Self.fast(), log: Self.log)
        await working.start()
        #expect(await eventually(timeout: .seconds(10)) { await working.state == .online })
        #expect(await working.sourceLabel == "HTTP-FLV")
        await working.stop()
    }

    /// Review finding: a `stop()` while a wake/network `reconnect()` was still closing the old connection returned at
    /// once, and the reconnect then connected again — an orphaned ingest nobody would ever stop.
    @Test(.timeLimit(.minutes(1))) func aStopWhileReconnectingWinsAndWaitsForTheClose() async throws {
        let made = Box(0), stopsStarted = Box(0), stopsFinished = Box(0)
        let source = IngestSupervisor.Source(label: "RTSP") {
            made.update { $0 += 1 }
            return SlowStopSource(stopDelay: .milliseconds(800), stopsStarted: stopsStarted, stopsFinished: stopsFinished)
        }
        let ingest = IngestSupervisor(name: "Main stream", hub: MediaHub(), primary: source, timing: Self.fast(), log: Self.log)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(5)) { await ingest.state == .online })
        let reconnect = Task { await ingest.reconnect() }
        #expect(await eventually(timeout: .seconds(5)) { stopsStarted.value == 1 }, "the reconnect is closing the old connection")
        await ingest.stop()
        #expect(stopsFinished.value == 1, "stop() returns once the connection being closed is closed")
        await reconnect.value
        try await Task.sleep(for: .milliseconds(300))
        let running = await ingest.isRunning
        #expect(!running, "the reconnect must not connect again after stop()")
        #expect(made.value == 1)
        #expect(await ingest.state == .idle)

        // Without a stop, a reconnect connects again; start() during a reconnect makes no second loop.
        let again = IngestSupervisor(name: "Main stream", hub: MediaHub(), primary: source, timing: Self.fast(), log: Self.log)
        await again.start()
        #expect(await eventually(timeout: .seconds(5)) { await again.state == .online })
        let second = Task { await again.reconnect() }
        #expect(await eventually(timeout: .seconds(5)) { stopsStarted.value == 2 })
        await again.start()
        await second.value
        #expect(await eventually(timeout: .seconds(5)) { await again.state == .online })
        #expect(await again.isRunning)
        try await Task.sleep(for: .milliseconds(300))
        #expect(made.value == 3, "one new connection after the reconnect")
        // A reconnect of a stopped supervisor does nothing.
        await again.stop()
        await again.reconnect()
        #expect(await !again.isRunning)
        #expect(made.value == 3)
    }

    /// Review finding (W4 round 4): the ingest source's stop (RTSP TEARDOWN, HTTP-FLV) was bounded by its own 3 s literal,
    /// not by `CameraRuntime.stopLimit`, whose documentation and test claimed it; changing the literal passed every
    /// suite. The bound is `Timing.sourceStopLimit`, `CameraRuntime.stopLimit` by default.
    @Test(.timeLimit(.minutes(1))) func aSourceStopToACameraThatVanishedIsBoundedBySourceStopLimit() async throws {
        let stopsStarted = Box(0), stopsFinished = Box(0)
        let source = IngestSupervisor.Source(label: "RTSP") {
            SlowStopSource(stopDelay: .seconds(10), stopsStarted: stopsStarted, stopsFinished: stopsFinished)
        }
        let ingest = IngestSupervisor(name: "Main stream", hub: MediaHub(), primary: source, timing: Self.fast { $0.sourceStopLimit = .milliseconds(300) },
                                      log: Self.log)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(5)) { await ingest.state == .online })
        let stopping = ContinuousClock.now
        await ingest.stop()
        #expect(ContinuousClock.now - stopping < .seconds(2), "stopped after \(ContinuousClock.now - stopping)")
        #expect(stopsStarted.value == 1)
        #expect(IngestSupervisor.Timing().sourceStopLimit == CameraRuntime.stopLimit)
    }

    @Test(.timeLimit(.minutes(1))) func samplesFeedTheStreamTraits() async throws {
        let calls = Box(0)
        let traits = StreamTraits()
        // Connection n delivers one keyframe at n × 10 s: across a reconnect that would look like a 10 s GOP.
        let source = IngestSupervisor.Source(label: "RTSP") { ScriptedSource(.keyframeThenHang(pts: Int64(calls.value) * 900_000), calls: calls) }
        let ingest = IngestSupervisor(name: "Main stream", hub: MediaHub(), primary: source, timing: Self.fast { $0.watchdog = .milliseconds(400) },
                                      traits: traits, log: Self.log)
        #expect(ingest.traits === traits)
        await ingest.start()
        // A reconnect restarts the timeline (`traits.restart()`), so no GOP spans two connections.
        #expect(await eventually(timeout: .seconds(5)) { calls.value >= 3 })
        #expect(traits.longestGOP == nil)
        await ingest.stop()
    }

    @Test func failureReasonsNeverCarryURLs() {
        let reasons = [IngestSupervisor.describe(RTSPError.protocolError("rtsp://admin:pw@10.0.0.1/stream"), watchdog: .seconds(15)),
                       IngestSupervisor.describe(TransportError.failed("rtsp://admin:pw@10.0.0.1"), watchdog: .seconds(15)),
                       IngestSupervisor.describe(URLError(.cannotConnectToHost), watchdog: .seconds(15))]
        #expect(reasons.allSatisfy { !$0.contains("rtsp://") && !$0.contains("pw") })
        #expect(IngestSupervisor.describe(TransportError.localNetworkDenied, watchdog: .seconds(15)) == "Local Network access is denied")
    }

    /// Review finding (W4 round 4): the stream's status line, the engine's state strings and the app each worded the same
    /// errors their own way, and they disagreed ("the camera did not answer" / "the connection timed out"; the app showed
    /// `TransportError.failed`'s POSIX text). Every error that isn't the stream's own is worded once, by
    /// `BridgeEngine.readableReason`, which never passes the platform's text on.
    @Test func reasonsAreWordedOnce() {
        let posix = "POSIXErrorCode(rawValue: 64): Host is down"
        let errors: [any Error] = [TransportError.timedOut, TransportError.addressInUse, TransportError.failed(posix),
                                   TransportError.failed("HTTP request failed (URLError -1003)"), RTSPError.timeout, RTSPError.unauthorized,
                                   CameraAdapterError.httpStatus(503), HTTPClientError.notHTTPResponse, URLError(.cannotFindHost)]
        for error in errors {
            #expect(IngestSupervisor.describe(error, watchdog: .seconds(15)) == BridgeEngine.readableReason(error), "\(error)")
        }
        #expect(BridgeEngine.readableReason(TransportError.failed(posix)) == "a network error occurred")
        #expect(BridgeEngine.readableReason(TransportError.failed("HTTP request failed (URLError -1003)")) == "a network error occurred")
    }

    /// Hardening plan WS-C 5 (audit F4): a network change that did not touch the camera's path reconnected every healthy
    /// stream (hub.discontinuity empties the replay ring, a Hikvision gets another digest login). A stream that delivered
    /// video within the window is left alone; one that stalled, and one that is not online, still reconnect.
    @Test(.timeLimit(.minutes(1))) func aHealthyStreamIsNotReconnectedByANetworkChangeButAStalledOneIs() async throws {
        let calls = Box(0)
        let source = IngestSupervisor.Source(label: "RTSP") { ScriptedSource(.oneKeyframeThenHang, calls: calls) }
        let ingest = IngestSupervisor(name: "Main stream", hub: MediaHub(), primary: source, timing: Self.fast(), log: Self.log)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(5)) { await ingest.state == .online })
        #expect(calls.value == 1)

        // The picture just arrived: left connected, no new attempt, no discontinuity.
        #expect(await ingest.isDelivering(within: .seconds(5)))
        let reconnected = await ingest.reconnect(unlessDeliveringWithin: .seconds(5))
        #expect(!reconnected)
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls.value == 1)
        #expect(await ingest.state == .online)

        // The same stream a moment later (this source delivers one frame and then nothing): stalled, so it reconnects.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!(await ingest.isDelivering(within: .milliseconds(200))))
        #expect(await ingest.reconnect(unlessDeliveringWithin: .milliseconds(200)))
        #expect(await eventually(timeout: .seconds(5)) { calls.value == 2 })

        // Without a window (a wake) it always reconnects, healthy or not.
        #expect(await eventually(timeout: .seconds(5)) { await ingest.state == .online })
        #expect(await ingest.reconnect())
        #expect(await eventually(timeout: .seconds(5)) { calls.value == 3 })
        await ingest.stop()

        // A stream that is not online is not "healthy" however recently it delivered.
        let offlineCalls = Box(0)
        let failing = IngestSupervisor.Source(label: "RTSP") { ScriptedSource(.fail(.timeout), calls: offlineCalls) }
        let offline = IngestSupervisor(name: "Main stream", hub: MediaHub(), primary: failing, timing: Self.fast(), log: Self.log)
        await offline.start()
        #expect(await eventually(timeout: .seconds(5)) { offlineCalls.value >= 1 })
        #expect(!(await offline.isDelivering(within: .seconds(60))))
        await offline.stop()
    }

    /// Review finding (W4 round 2): camera API errors (the ONVIF stream-address probe) read "stream error".
    @Test func cameraAPIErrorsAreDescribed() {
        #expect(IngestSupervisor.describe(CameraAdapterError.unauthorized, watchdog: .seconds(15)) == "the camera rejected the user name or password")
        #expect(IngestSupervisor.describe(CameraAdapterError.httpStatus(503), watchdog: .seconds(15)) == "the camera answered with an error (HTTP 503)")
        #expect(IngestSupervisor.describe(CameraAdapterError.unsupported("the camera reports no stream"), watchdog: .seconds(15))
            == "the camera reports no stream")
        #expect(IngestSupervisor.isUnauthorized(CameraAdapterError.unauthorized))
    }
}
#endif
