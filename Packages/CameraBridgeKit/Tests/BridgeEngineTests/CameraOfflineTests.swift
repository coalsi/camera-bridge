#if canImport(Darwin)
import TestSupport
@testable import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import RTSP
import Synchronization
import Testing
@testable import BridgeEngine

/// A Wi-Fi doorbell that stops answering (log, 2026-10-02 10:29): RTSP closed, then "connection refused" and "timed out"
/// in turns on every channel, the main stream switching between RTSP and HTTP-FLV every 1 to 5 s, a snapshot request every
/// 10 s waiting out its 8 s, ONVIF and the event poll trying on their own clocks. The camera is now offline as a whole:
/// one probe on a growing delay, no transport changes while it answers nothing, nothing sent, the last picture served,
/// everything resumed at once when it answers.

/// A transport that only ever connects (or refuses) for the probes: the camera is "up" per port while `answering` holds it.
final class ProbeTransport: NetworkTransport {
    final class Connection: TCPConnection {
        let id = UUID()
        let localAddress = "127.0.0.1"
        let remoteAddress = "192.0.2.10"
        let isIPv6 = false
        func receive(maximumLength: Int) async throws -> Data? { nil }
        func send(_ data: Data) async throws {}
        func close() {}
    }

    /// Ports that accept connections; every other port is refused (or times out, with `timesOut`).
    let openPorts = Box<Set<UInt16>>([])
    let timesOut = Box(false)
    let attempts = Box<[(port: UInt16, at: ContinuousClock.Instant)]>([])

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener { throw TransportError.failed("unused") }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        attempts.update { $0.append((port, .now)) }
        if openPorts.value.contains(port) { return Connection() }
        throw timesOut.value ? TransportError.timedOut : TransportError.connectionRefused
    }

    /// The instants of the probes made on `port`.
    func probes(on port: UInt16) -> [ContinuousClock.Instant] { attempts.value.filter { $0.port == port }.map(\.at) }
}

@Suite(.timeLimit(.minutes(1))) struct CameraOfflineTests {
    static let log = Log(category: "OfflineTest")
    static let http: UInt16 = 80, rtsp: UInt16 = 554

    static func timing(initial: Duration = .milliseconds(50), maximum: Duration = .milliseconds(400)) -> CameraReachability.Timing {
        var timing = CameraReachability.Timing()
        timing.probeInitial = initial
        timing.probeMaximum = maximum
        timing.probeJitter = 0
        timing.probeTimeout = .milliseconds(100)
        return timing
    }

    static func reachability(_ transport: ProbeTransport, timing: CameraReachability.Timing = timing()) -> CameraReachability {
        CameraReachability(host: "192.0.2.10", ports: [http, rtsp], transport: transport, timing: timing, log: log)
    }

    // MARK: Reachability

    @Test func threeFailuresInARowWithNothingAnsweringTakeTheCameraOffline() async throws {
        let transport = ProbeTransport()
        let camera = Self.reachability(transport)
        camera.reportUnreachable()
        camera.reportUnreachable()
        #expect(camera.phase == .reachable, "two failures prove nothing")
        camera.reportReachable()   // any answer resets the count
        camera.reportUnreachable()
        camera.reportUnreachable()
        #expect(camera.phase == .reachable)
        camera.reportUnreachable()
        #expect(camera.phase == .verifying)
        await camera.settled()
        #expect(camera.isOffline)
        camera.reset()
    }

    @Test func aCameraThatAnswersOnAnotherPortIsNotOffline() async throws {
        // RTSP switched off (554 refused), the web server answers: what failed was one service, not the camera.
        let transport = ProbeTransport()
        transport.openPorts.set([Self.http])
        let camera = Self.reachability(transport)
        for _ in 0..<3 { camera.reportUnreachable() }
        await camera.settled()
        #expect(camera.phase == .reachable)
        #expect(camera.probeCount == 0)
    }

    @Test func probesGrowTwoFoldToTheCapAndTheCameraResumesWhenItAnswers() async throws {
        let transport = ProbeTransport()
        let camera = Self.reachability(transport, timing: Self.timing(initial: .milliseconds(60), maximum: .milliseconds(240)))
        for _ in 0..<3 { camera.reportUnreachable() }
        await camera.settled()
        #expect(camera.isOffline)
        let waiter = Task { await camera.waitUntilReachable() }
        #expect(await eventually(timeout: .seconds(5)) { transport.probes(on: Self.http).count >= 6 })   // the verdict + 5 probes
        let times = transport.probes(on: Self.http)
        // The gaps after the verdict: 60, 120, 240, 240 ms (the cap), never faster than asked.
        let gaps = zip(times.dropFirst(), times).map { ($0 - $1).timeInterval }
        let expected = [0.06, 0.12, 0.24, 0.24, 0.24]
        for (gap, wanted) in zip(gaps.dropFirst(0), expected) {
            #expect(gap >= wanted * 0.9, "probe gap \(gap) s, wanted at least \(wanted) s: \(gaps)")
        }
        #expect(gaps.dropFirst(2).allSatisfy { $0 < 0.24 * 4 }, "capped: \(gaps)")
        let probesBefore = transport.attempts.value.count

        transport.openPorts.set([Self.rtsp])
        await waiter.value   // resumes when a probe connects
        #expect(camera.phase == .reachable)
        try await Task.sleep(for: .milliseconds(500))
        // Reachable: no more probes beyond the one that found it (and at most one in flight when the port opened).
        #expect(transport.attempts.value.count <= probesBefore + 6)
        let settledCount = transport.attempts.value.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(transport.attempts.value.count == settledCount, "probing stops once the camera answers")
    }

    @Test func aCameraThatFlapsKeepsItsProbeBackoffWhileOneThatStayedUpStartsAfresh() async throws {
        let transport = ProbeTransport()
        var timing = Self.timing(initial: .milliseconds(40), maximum: .milliseconds(640))
        timing.stableAfter = .seconds(60)
        let camera = Self.reachability(transport, timing: timing)
        for _ in 0..<3 { camera.reportUnreachable() }
        await camera.settled()
        #expect(await eventually { transport.probes(on: Self.http).count >= 5 })   // 40, 80, 160, 320 ms of backoff used
        transport.openPorts.set([Self.http])
        await camera.waitUntilReachable()
        transport.openPorts.set([])
        let firstOutage = transport.probes(on: Self.http).count

        // Down again right away (less than `stableAfter`): the first probe waits where the backoff was, not 40 ms.
        for _ in 0..<3 { camera.reportUnreachable() }
        await camera.settled()
        #expect(camera.isOffline)
        let started = ContinuousClock.now
        #expect(await eventually(timeout: .seconds(5)) { transport.probes(on: Self.http).count > firstOutage + 1 })
        let second = transport.probes(on: Self.http)[firstOutage + 1]
        #expect(second - started >= .milliseconds(250), "the probe backoff continues after a short recovery")
        camera.reset()
    }

    @Test func aWaitingTaskThatIsCancelledStopsWaiting() async throws {
        let transport = ProbeTransport()
        let camera = Self.reachability(transport, timing: Self.timing(initial: .seconds(30), maximum: .seconds(30)))
        for _ in 0..<3 { camera.reportUnreachable() }
        await camera.settled()
        let waiter = Task { await camera.waitUntilReachable() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await waiter.value
        #expect(camera.isOffline)
        camera.reset()
    }

    @Test func whatCountsAsNoAnswer() {
        #expect(CameraReachability.isUnreachable(TransportError.connectionRefused))
        #expect(CameraReachability.isUnreachable(TransportError.timedOut))
        #expect(CameraReachability.isUnreachable(TransportError.closed))
        #expect(!CameraReachability.isUnreachable(TransportError.localNetworkDenied))
        #expect(CameraReachability.isUnreachable(URLError(.timedOut)))
        #expect(CameraReachability.isUnreachable(URLError(.cannotConnectToHost)))
        #expect(!CameraReachability.isUnreachable(URLError(.cancelled)))
        #expect(!CameraReachability.isUnreachable(CameraAdapterError.unauthorized))
        #expect(CameraReachability.isGatewayFailure(httpStatus: 502) && CameraReachability.isGatewayFailure(httpStatus: 503))
        #expect(!CameraReachability.isGatewayFailure(httpStatus: 404))
        #expect(IngestSupervisor.cameraAnswer(RTSPError.notFound) == .answered)
        #expect(IngestSupervisor.cameraAnswer(RTSPError.badStatus(503)) == .unreachable)
        #expect(IngestSupervisor.cameraAnswer(RTSPError.timeout) == .unreachable)
        #expect(IngestSupervisor.cameraAnswer(IngestSupervisor.Failure.stalled(.seconds(15))) == .neutral)
    }

    // MARK: Ingest: no flip-flopping

    @Test func aCameraThatAnswersNothingIsNeverSwitchedBetweenTransportsAndResumesOnTheSameOne() async throws {
        let transport = ProbeTransport()
        let camera = Self.reachability(transport)
        let primaryCalls = Box(0), fallbackCalls = Box(0)
        let primary = IngestSupervisor.Source(label: "RTSP") { RuntimeIngestTests.ScriptedSource(.failTransport(.connectionRefused), calls: primaryCalls) }
        let fallback = IngestSupervisor.Source(label: "HTTP-FLV") { RuntimeIngestTests.ScriptedSource(.failTransport(.timedOut), calls: fallbackCalls) }
        var timing = RuntimeIngestTests.fast()
        timing.minimumSwitchInterval = .zero   // only the offline state keeps it from switching
        let ingest = IngestSupervisor(name: "Doorbell main stream", hub: MediaHub(), primary: primary, fallback: fallback, timing: timing,
                                      log: Self.log, reachability: camera)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(5)) { camera.isOffline })
        try await Task.sleep(for: .milliseconds(800))   // many 100 ms backoffs would pass
        #expect(primaryCalls.value == 3, "three failures, then no attempt while nothing answers: \(primaryCalls.value)")
        #expect(fallbackCalls.value == 0, "no switch to HTTP-FLV for a camera that answers nothing")
        #expect(await ingest.sourceLabel == "RTSP")

        // The camera comes back: the next attempt is at once, on RTSP.
        transport.openPorts.set([Self.http])
        #expect(await eventually(timeout: .seconds(5)) { primaryCalls.value >= 4 })
        #expect(fallbackCalls.value == 0)
        await ingest.stop()
        camera.reset()
    }

    @Test func aTransportThatFailsWhileTheCameraAnswersSwitchesOnceThenWaitsOutTheMinimumInterval() async throws {
        // RTSP is off (refused) but the camera's web server answers: reachable, so the three failures count.
        let transport = ProbeTransport()
        transport.openPorts.set([Self.http])
        let camera = Self.reachability(transport)
        let primaryCalls = Box(0), fallbackCalls = Box(0)
        let primary = IngestSupervisor.Source(label: "RTSP") { RuntimeIngestTests.ScriptedSource(.failTransport(.connectionRefused), calls: primaryCalls) }
        let fallback = IngestSupervisor.Source(label: "HTTP-FLV") { RuntimeIngestTests.ScriptedSource(.failTransport(.connectionRefused), calls: fallbackCalls) }
        var timing = RuntimeIngestTests.fast()
        timing.minimumSwitchInterval = .seconds(2)
        let ingest = IngestSupervisor(name: "Main stream", hub: MediaHub(), primary: primary, fallback: fallback, timing: timing, log: Self.log,
                                      reachability: camera)
        await ingest.start()
        #expect(await eventually(timeout: .seconds(5)) { fallbackCalls.value >= 1 }, "switched after three failures of RTSP")
        #expect(primaryCalls.value >= 3)
        let primaryAtSwitch = primaryCalls.value
        // Three failures of HTTP-FLV in under 2 s do not take it back.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(primaryCalls.value == primaryAtSwitch, "no second switch within the minimum interval")
        #expect(fallbackCalls.value >= 3)
        #expect(await eventually(timeout: .seconds(5)) { primaryCalls.value > primaryAtSwitch }, "back to RTSP once the interval passed")
        await ingest.stop()
        camera.reset()
    }

    // MARK: Snapshots

    @Test func anOfflineCameraServesTheLastSnapshotAtOnceInsteadOfWaitingForTheBudget() async throws {
        let offline = Box(false)
        let apiCalls = Box(0)
        let clock = Box(ContinuousClock.now)
        let api: SnapshotProvider.CameraSnapshot = {
            apiCalls.update { $0 += 1 }
            if offline.value { throw CameraOfflineError() }
            return Data([0xFF, 0xD8, 7])
        }
        let provider = SnapshotProvider(cameraSnapshot: api, resize: { jpeg, _, _ in jpeg }, keyframeJPEG: { _, _, _ in Data([0xFF, 0xD8, 9]) },
                                        hub: MediaHub(), log: Self.log, isOffline: { offline.value }, now: { clock.value })
        let live = try await provider.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .periodic))
        #expect(live == Data([0xFF, 0xD8, 7]))

        offline.set(true)
        clock.update { $0 += .seconds(290) }   // far past the cache lifetime, within the 5 minutes a last picture is still served
        let started = ContinuousClock.now
        let stale = try await provider.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .periodic))
        #expect(stale == live, "the last picture, while it is under 5 minutes old")
        let event = try await provider.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .event))
        #expect(event == live)
        #expect(ContinuousClock.now - started < .milliseconds(500), "no waiting")
        #expect(apiCalls.value == 1, "nothing is asked of a camera that answers nothing")
    }
}
#endif
