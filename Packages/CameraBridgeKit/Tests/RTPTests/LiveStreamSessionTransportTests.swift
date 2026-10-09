import BridgeSupport
import Foundation
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import RTP

/// What the `LiveStream` logger said, so a test can count the lines about its own session (they name the session's
/// destination port; tests run in parallel, and the log hub is process-wide).
final class LiveStreamLogLines: LogSink {
    let entries = Mutex<[LogEntry]>([])
    private let token = Mutex<LogSinkToken?>(nil)

    init() {
        token.withLock { $0 = LogHub.addSink(self) }
    }

    func record(_ entry: LogEntry) {
        guard entry.category == "LiveStream" else { return }
        entries.withLock { $0.append(entry) }
    }

    func stop() {
        if let value = token.withLock({ let value = $0; $0 = nil; return value }) { LogHub.removeSink(value) }
    }

    /// The messages at `level` or above that mention `needle`.
    func messages(from level: LogLevel = .warning, mentioning needle: String) -> [String] {
        entries.withLock { $0.filter { $0.level >= level && $0.message.contains(needle) }.map(\.message) }
    }
}

extension TestController {
    /// Sends a receiver report on the video socket every `interval` until the returned task is cancelled; `blocks` decides what
    /// each carries (it sees this controller, for the sequence numbers received so far).
    func reporting(to port: UInt16, every interval: Duration = .milliseconds(100),
                   blocks: @escaping @Sendable (TestController) -> [RTCPReportBlock]) -> Task<Void, Never> {
        Task { [self] in
            while !Task.isCancelled {
                try? sendRTCP([.receiverReport(ssrc: 0xC0C0_C0C0, blocks: blocks(self))], video: true, to: port)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// A block saying the video arrives: the newest sequence number received, nothing lost.
    static func healthyBlock(_ controller: TestController) -> [RTCPReportBlock] {
        guard let last = controller.received.value.videoRTP.last else { return [] }
        return [RTCPReportBlock(ssrc: SessionUnderTest.videoSSRC, extendedHighestSequence: UInt32(last.sequenceNumber))]
    }
}

extension Frames {
    /// A keyframe of about `bytes` bytes, i.e. `bytes / 1_188` packets.
    static func keyframe(bytes: Int, index: Int = 0) -> EncodedVideoFrame {
        let nal = Data([0x65]) + Data((1..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        return EncodedVideoFrame(format: format, nalUnits: [nal], isKeyframe: true, pts: MediaTime(value: Int64(index) * 3_000, timescale: 90_000), wallClock: Date())
    }
}

/// Short timings so the protections that take 3 to 10 seconds in production show up in a second or two.
private func fastTimings() -> LiveStreamTimings {
    var timings = LiveStreamTimings()
    timings.watchdogTick = .milliseconds(20)
    timings.blindAfter = .milliseconds(400)
    timings.endBlindAfter = .milliseconds(1_400)
    timings.interfaceFlipInterval = .milliseconds(300)
    timings.minimumSessionAge = .milliseconds(300)
    timings.minimumPacketsSent = 10
    timings.minimumPacketsSentWhileFrozen = 15
    timings.sendRetryDelay = .milliseconds(1)
    return timings
}

/// The session's transport protections: a controller that answers but receives nothing, the liveness limits, send errors,
/// loss recovery and sender reports (loopback only).
@Suite(.timeLimit(.minutes(1)), .loopback) struct LiveStreamSessionTransportTests {
    private func frames(_ count: Int, interval: Duration = .milliseconds(20)) -> AsyncStream<EncodedVideoFrame> {
        Frames.stream((0..<count).map(Frames.video), interval: interval, finish: false)
    }

    // MARK: A controller that answers but receives nothing

    /// A reported "loading forever" Home: RTCP keeps the session alive, the receiver reports never mention our video.
    @Test func aControllerWhoseReportsNeverMentionOurVideoIsWarnedAboutThenEnded() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: fastTimings())
        let logs = LiveStreamLogLines()
        defer { logs.stop() }
        let notified = Box<[String]>([])
        sut.videoSocket.transport.update {
            $0.boundSource = "192.0.2.25"
            $0.strategy = "bound to the accessory address"
            $0.route = "advertised 192.0.2.20, on this network"
            $0.onControllerNotReceiving = { symptom in notified.update { $0.append(symptom) } }
        }
        let port = "\(controller.video.localPort)"
        let started = ContinuousClock.now
        await sut.session.start(video: frames(300), audio: nil)
        let reports = controller.reporting(to: sut.videoSocket.localPort) { _ in [] }
        defer { reports.cancel() }

        #expect(await eventually(timeout: .seconds(3)) { await sut.session.timeline.controllerNotReceiving })
        let detected = ContinuousClock.now - started
        #expect(detected >= .milliseconds(400) && detected < .milliseconds(1_400), "detected after \(detected)")
        #expect(notified.value == [ControllerReceptionMonitor.Symptom.noReportBlock.rawValue])

        let reason = await sut.endReason(within: .seconds(4))
        #expect(reason == .controllerNotReceiving)
        let ended = ContinuousClock.now - started
        #expect(ended >= .milliseconds(1_400) && ended < .milliseconds(3_000), "ended after \(ended)")
        let warnings = logs.messages(mentioning: port)
        #expect(warnings.count == 2, "one WARNING when it is found, one when the session is ended: \(warnings)")
        let found = try #require(warnings.first)
        for expected in ["not receiving our video", "192.0.2.25", "bound to the accessory address", "advertised 192.0.2.20", "packets", "octets",
                         "no report block about our video was ever received"] {
            #expect(found.contains(expected), "\(expected) missing from: \(found)")
        }
        #expect(await sut.session.timeline.controllerNotReceivingEpisodes == 1)
    }

    @Test func aHealthyControllerIsNeverFlaggedOrEnded() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: fastTimings())
        let notified = Box(0)
        sut.videoSocket.transport.update { $0.onControllerNotReceiving = { _ in notified.update { $0 += 1 } } }
        await sut.session.start(video: frames(200), audio: nil)
        let reports = controller.reporting(to: sut.videoSocket.localPort, blocks: TestController.healthyBlock)
        defer { reports.cancel() }
        try await Task.sleep(for: .milliseconds(2_500))   // well past the blind and end limits of fastTimings
        let blind = await sut.session.timeline.controllerNotReceiving
        #expect(!blind && notified.value == 0)
        #expect(await sut.endReason(within: .milliseconds(1)) == nil)
        await sut.session.stop()
        _ = await sut.session.waitForEnd()
    }

    @Test func receiverReportsWithoutBlocksBeforeAnyVideoAreNotBlindness() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: fastTimings())
        let (stream, continuation) = AsyncStream.makeStream(of: EncodedVideoFrame.self)
        await sut.session.start(video: stream, audio: nil)
        let reports = controller.reporting(to: sut.videoSocket.localPort) { _ in [] }
        defer { reports.cancel() }
        try await Task.sleep(for: .milliseconds(2_000))   // 5x the blind limit of RTCP-only life
        #expect(await sut.session.timeline.controllerNotReceiving == false)
        #expect(await sut.endReason(within: .milliseconds(1)) == nil, "alive: the controller is waiting for the video")
        // Video starts: the controller is healthy now.
        reports.cancel()
        let healthy = controller.reporting(to: sut.videoSocket.localPort, blocks: TestController.healthyBlock)
        defer { healthy.cancel() }
        Task { for index in 0..<100 { continuation.yield(Frames.video(index)); try? await Task.sleep(for: .milliseconds(20)) } }
        try await Task.sleep(for: .milliseconds(1_800))
        #expect(await sut.session.timeline.controllerNotReceiving == false)
        #expect(await sut.endReason(within: .milliseconds(1)) == nil)
        await sut.session.stop()
        _ = await sut.session.waitForEnd()
    }

    /// A report block whose highest sequence number stands still while we send: the other face of the same failure.
    @Test func aSequenceNumberThatStandsStillIsBlindToo() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: fastTimings())
        await sut.session.start(video: frames(300), audio: nil)
        let reports = controller.reporting(to: sut.videoSocket.localPort) { _ in
            [RTCPReportBlock(ssrc: SessionUnderTest.videoSSRC, extendedHighestSequence: 1_234)]
        }
        defer { reports.cancel() }
        #expect(await sut.endReason(within: .seconds(5)) == .controllerNotReceiving)
        #expect(await sut.session.timeline.controllerNotReceivingEpisodes == 1)
    }

    /// While blind the sockets are scoped to other interfaces one after another (the controller was told the source address,
    /// which stays), and a controller that starts receiving ends the episode.
    @Test func whileBlindTheSocketsAreScopedToOtherInterfacesAndRecoveryEndsTheEpisode() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: fastTimings())
        sut.videoSocket.transport.update { $0.recoveryScopes = ["lo0", nil] }
        let logs = LiveStreamLogLines()
        defer { logs.stop() }
        await sut.session.start(video: frames(300), audio: nil)
        let healthy = Box(false)
        let reports = controller.reporting(to: sut.videoSocket.localPort) { controller in
            healthy.value ? TestController.healthyBlock(controller) : []
        }
        defer { reports.cancel() }
        #expect(await eventually(timeout: .seconds(3)) { sut.videoSocket.scopedInterface == "lo0" }, "first the interface owning the address")
        #expect(sut.audioSocket.scopedInterface == "lo0", "both sockets")
        #expect(await eventually(timeout: .seconds(3)) { sut.videoSocket.scopedInterface == nil }, "then no scope at all")
        #expect(await sut.session.timeline.controllerNotReceiving)
        // The controller starts receiving after the second step.
        healthy.set(true)
        #expect(await eventually(timeout: .seconds(2)) { await sut.session.timeline.controllerNotReceiving == false })
        #expect(await sut.endReason(within: .milliseconds(300)) == nil, "recovered: the session goes on")
        let port = "\(controller.video.localPort)"
        #expect(logs.messages(from: .info, mentioning: port).contains { $0.contains("sending through interface lo0") })
        #expect(logs.messages(from: .info, mentioning: "receiving our video again").isEmpty == false)
        await sut.session.stop()
        _ = await sut.session.waitForEnd()
    }

    // MARK: Liveness

    @Test func noVideoPacketAfterTheStartEndsTheSession() async throws {
        let controller = try TestController()
        defer { controller.close() }
        var timings = fastTimings()
        timings.noVideoAtStart = .milliseconds(500)
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: timings)
        let logs = LiveStreamLogLines()
        defer { logs.stop() }
        // Only delta frames: nothing is sent before a keyframe.
        let deltas = Frames.stream((1..<400).filter { $0 % 30 != 0 }.map(Frames.video), interval: .milliseconds(10), finish: false)
        let started = ContinuousClock.now
        await sut.session.start(video: deltas, audio: nil)
        let keepalive = controller.reporting(to: sut.videoSocket.localPort) { _ in [] }
        defer { keepalive.cancel() }
        #expect(await sut.endReason(within: .seconds(3)) == .noVideoAtStart)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(500) && elapsed < .seconds(2), "ended after \(elapsed)")
        let warnings = logs.messages(mentioning: "\(controller.video.localPort)")
        #expect(warnings.count == 1 && warnings[0].contains("before a keyframe"), "\(warnings)")
    }

    @Test func aSourceThatStopsDeliveringEndsTheSessionAfterTheLimit() async throws {
        let controller = try TestController()
        defer { controller.close() }
        var timings = fastTimings()
        timings.sourceStalled = .milliseconds(600)
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: timings)
        let logs = LiveStreamLogLines()
        defer { logs.stop() }
        await sut.session.start(video: frames(10), audio: nil)   // 10 frames, then nothing (the stream stays open)
        let reports = controller.reporting(to: sut.videoSocket.localPort, blocks: TestController.healthyBlock)
        defer { reports.cancel() }
        #expect(await eventually(timeout: .seconds(2)) { await sut.session.timeline.videoPackets >= 10 })
        let last = ContinuousClock.now
        #expect(await sut.endReason(within: .seconds(4)) == .sourceStalled)
        #expect(ContinuousClock.now - last >= .milliseconds(400), "not before the limit")
        let warnings = logs.messages(mentioning: "\(controller.video.localPort)")
        #expect(warnings.count == 1 && warnings[0].contains("no video packet was sent for"), "\(warnings)")
    }

    /// A dead stream's sender reports used to go on extrapolating its clock for as long as the controller kept the session alive.
    @Test func senderReportsStopWhenAStreamHasSentNothingForAWhile() async throws {
        let controller = try TestController()
        defer { controller.close() }
        var timings = fastTimings()
        timings.senderReportStaleAfter = .milliseconds(700)
        timings.sourceStalled = .seconds(30)
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: timings)
        await sut.session.start(video: frames(10), audio: nil)
        let reports = controller.reporting(to: sut.videoSocket.localPort, blocks: TestController.healthyBlock)
        defer { reports.cancel() }
        #expect(await eventually(timeout: .seconds(3)) { controller.senderReports.count >= 1 })
        try await Task.sleep(for: .milliseconds(1_500))   // the last SR is at most one report interval after the stale limit
        let count = controller.senderReports.count
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(controller.senderReports.count == count, "no sender report from a stream that sent nothing for \(timings.senderReportStaleAfter)")
        await sut.session.stop()
        _ = await sut.session.waitForEnd()
        // Stopping still says goodbye, with a report first.
        #expect(await eventually(timeout: .seconds(2)) { controller.received.value.videoRTCP.contains { $0.packet == .bye(ssrcs: [SessionUnderTest.videoSSRC]) } })
    }

    // MARK: Send errors

    /// A bound address that vanished (DHCP, Wi-Fi rejoin): every send fails with EADDRNOTAVAIL; after the grace period the session
    /// ends with one clear line so Home asks again.
    @Test func aFatalSendErrorThatPersistsEndsTheSessionWithOneLine() async throws {
        let controller = try TestController()
        defer { controller.close() }
        var timings = fastTimings()
        timings.fatalSendErrorAfter = .milliseconds(500)
        timings.noVideoAtStart = .seconds(30)
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: timings)
        sut.videoSocket.injectSendFailures { _ in EADDRNOTAVAIL }
        let denied = Box<[Bool]>([])
        sut.videoSocket.transport.update { $0.onFatalSendError = { _, _, localNetworkDenied in denied.update { $0.append(localNetworkDenied) } } }
        let logs = LiveStreamLogLines()
        defer { logs.stop() }
        let started = ContinuousClock.now
        await sut.session.start(video: frames(300), audio: nil)
        let reason = await sut.endReason(within: .seconds(4))
        guard case .socketError(let text)? = reason else {
            Issue.record("expected socketError, got \(String(describing: reason))")
            return
        }
        #expect(text.contains("EADDRNOTAVAIL"))
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(500) && elapsed < .seconds(2), "ended after \(elapsed)")
        let lines = logs.messages(mentioning: "\(controller.video.localPort)")
        #expect(lines.count == 2, "the first failure of an errno and the end, no more: \(lines)")
        #expect(lines.contains { $0.contains("cannot be sent") && $0.contains("EADDRNOTAVAIL") })
        #expect(denied.value == [false], "EADDRNOTAVAIL is not a Local Network problem")
    }

    @Test func noRouteToTheHostIsReportedAsPossiblyLocalNetworkDenied() async throws {
        let controller = try TestController()
        defer { controller.close() }
        var timings = fastTimings()
        timings.fatalSendErrorAfter = .milliseconds(300)
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: timings)
        sut.videoSocket.injectSendFailures { _ in EHOSTUNREACH }
        let reported = Box<[Int32]>([])
        sut.videoSocket.transport.update { $0.onFatalSendError = { code, _, denied in if denied { reported.update { $0.append(code) } } } }
        await sut.session.start(video: frames(300), audio: nil)
        guard case .socketError? = await sut.endReason(within: .seconds(4)) else {
            Issue.record("expected socketError")
            return
        }
        #expect(reported.value == [EHOSTUNREACH])
    }

    @Test func aFatalErrorThatGoesAwayDoesNotEndTheSession() async throws {
        let controller = try TestController()
        defer { controller.close() }
        var timings = fastTimings()
        timings.fatalSendErrorAfter = .milliseconds(600)
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: timings)
        sut.videoSocket.injectSendFailures { attempt in (1...15).contains(attempt) ? ENETDOWN : nil }   // a brief outage
        await sut.session.start(video: frames(200), audio: nil)
        let reports = controller.reporting(to: sut.videoSocket.localPort, blocks: TestController.healthyBlock)
        defer { reports.cancel() }
        try await Task.sleep(for: .milliseconds(1_800))
        #expect(await sut.endReason(within: .milliseconds(1)) == nil)
        #expect(await sut.session.timeline.videoPackets > 20, "video flows again")
        await sut.session.stop()
        _ = await sut.session.waitForEnd()
    }

    // MARK: Loss

    /// ENOBUFS on packet 7 of a keyframe that outlives the retries: the packet is lost, the picture undecodable until the next
    /// keyframe, so one is asked for. One WARNING for the incident.
    @Test func aLostPacketAsksForAFreshKeyframeAndLogsOnce() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: fastTimings())
        // Attempt 7 and its ten retries (8...17) fail; everything else goes out.
        sut.videoSocket.injectSendFailures { attempt in (7...17).contains(attempt) ? ENOBUFS : nil }
        let logs = LiveStreamLogLines()
        defer { logs.stop() }
        let requests = Box(0)
        let watcher = Task { for await _ in sut.session.keyframeRequests { requests.update { $0 += 1 } } }
        defer { watcher.cancel() }
        let keyframe = Frames.keyframe(bytes: 100_000)
        await sut.session.start(video: Frames.stream([keyframe] + (1..<30).map(Frames.video), interval: .milliseconds(20), finish: false), audio: nil)
        #expect(await eventually(timeout: .seconds(3)) { requests.value >= 1 }, "a lost video packet asks for a keyframe")
        let timeline = await sut.session.timeline
        #expect(timeline.videoPacketsLost == 1 && timeline.videoSendRetries == 10 && timeline.lossKeyframeRequests == 1, "\(timeline)")
        #expect(await eventually(timeout: .seconds(3)) { controller.received.value.videoRTP.count >= 100 })
        let sequences = controller.received.value.videoRTP.map(\.sequenceNumber)
        let holes = zip(sequences, sequences.dropFirst()).filter { $1 != $0 &+ 1 }.count
        #expect(holes == 1, "exactly one packet is missing from the wire")
        let lines = logs.messages(mentioning: "\(controller.video.localPort)")
        #expect(lines.count == 1 && lines[0].contains("1 of ") && lines[0].contains("ENOBUFS") && lines[0].contains("asking for a fresh keyframe"), "\(lines)")
        await sut.session.stop()
        _ = await sut.session.waitForEnd()
    }

    @Test func aBriefFullBufferIsRetriedWithoutLossOrKeyframeRequest() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: fastTimings())
        sut.videoSocket.injectSendFailures { attempt in (7...9).contains(attempt) ? ENOBUFS : nil }
        let requests = Box(0)
        let watcher = Task { for await _ in sut.session.keyframeRequests { requests.update { $0 += 1 } } }
        defer { watcher.cancel() }
        let logs = LiveStreamLogLines()
        defer { logs.stop() }
        await sut.session.start(video: Frames.stream([Frames.keyframe(bytes: 30_000)] + (1..<10).map(Frames.video), interval: .milliseconds(20), finish: false), audio: nil)
        #expect(await eventually(timeout: .seconds(3)) { controller.received.value.videoRTP.filter(\.marker).count >= 10 })
        let timeline = await sut.session.timeline
        #expect(timeline.videoPacketsLost == 0 && timeline.videoSendRetries == 3 && requests.value == 0)
        let sequences = controller.received.value.videoRTP.map(\.sequenceNumber)
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $1 == $0 &+ 1 }, "nothing lost, in order")
        #expect(logs.messages(mentioning: "\(controller.video.localPort)").count == 1, "the errno is logged once")
        await sut.session.stop()
        _ = await sut.session.waitForEnd()
    }

    // MARK: Pacing on the wire

    /// A 250-packet keyframe arrives complete and in order: paced in chunks, not one burst over the kernel's send queue.
    @Test func aLargeKeyframeIsSentCompleteAndInOrder() async throws {
        let controller = try TestController()
        defer { controller.close() }
        let sut = try SessionUnderTest(controller: controller, withAudio: false, timings: fastTimings())
        await sut.session.start(video: Frames.stream([Frames.keyframe(bytes: 300_000)], interval: .milliseconds(20), finish: false), audio: nil)
        #expect(await eventually(timeout: .seconds(5)) { controller.received.value.videoRTP.contains(where: \.marker) })
        let received = controller.received.value.videoRTP
        #expect(received.count >= 250)
        #expect(zip(received, received.dropFirst()).allSatisfy { $1.sequenceNumber == $0.sequenceNumber &+ 1 })
        #expect(await sut.session.timeline.videoPacketsLost == 0)
        await sut.session.stop()
        _ = await sut.session.waitForEnd()
    }

    // MARK: End to end with the test controller

    /// `SRTPTestReceiver` stands for a controller: counting blocks are a healthy one, `.none` and `.frozen` one that receives
    /// nothing although its RTCP keeps coming.
    @Test(arguments: [SRTPTestReceiver.ReportBlocks.none, .frozen])
    func theTestReceiverModesDriveTheWatchdog(mode: SRTPTestReceiver.ReportBlocks) async throws {
        let receiver = try await SRTPTestReceiver.start(videoKeys: .init(masterKey: TestController.videoKey, masterSalt: TestController.videoSalt),
                                                        audioKeys: .init(masterKey: TestController.audioKey, masterSalt: TestController.audioSalt))
        let sut = try SessionUnderTest(videoPort: receiver.videoPort, audioPort: receiver.audioPort, withAudio: false, timings: fastTimings())
        await receiver.connect(to: SRTPTestReceiver.Peer(host: "127.0.0.1", videoPort: sut.videoSocket.localPort, audioPort: sut.audioSocket.localPort,
                                                         videoSSRC: SessionUnderTest.videoSSRC, controllerVideoSSRC: 0xC0C0_C0C0, controllerAudioSSRC: 0xC0C1_C0C1),
                               keepaliveInterval: .milliseconds(100))
        await sut.session.start(video: frames(400), audio: nil)
        // Healthy first: counting blocks for well over the end limit.
        try await Task.sleep(for: .milliseconds(1_800))
        #expect(await sut.endReason(within: .milliseconds(1)) == nil)
        let blind = await sut.session.timeline.controllerNotReceiving
        #expect(!blind)
        await receiver.setReportBlocks(mode)
        #expect(await sut.endReason(within: .seconds(5)) == .controllerNotReceiving)
        await receiver.stop()
    }
}
