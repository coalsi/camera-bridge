import Foundation
import Testing
@testable import RTP

/// A send that fails the way the kernel does.
private func failure(_ code: Int32) -> UDPSocketError { .system(operation: "sendto", code: code) }

/// Pacing and error handling of a frame's datagrams (`PacedTransmission`): chunks, the frame delay cap, retries of the transient
/// errors, losses and fatal errors, with the send and the wait injected.
@Suite struct PacedTransmissionTests {
    /// A reported incident: a passthrough keyframe of 250 packets sent back to back overran the kernel's send queue
    /// (`sndq_maxlen` 128). The packets of a frame go out in chunks, in order, and an ENOBUFS is sent again.
    @Test func enobufsOnEveryThirdAttemptStillSendsAllThreeHundredPacketsInOrderInSmallChunks() async {
        var timings = LiveStreamTimings()
        timings.pacingGap = .milliseconds(2)   // distinct from the retry wait (1 ms), so the two can be told apart
        var attempts = 0
        var sent: [Int] = []
        var pauses: [Duration] = []
        let outcome = await PacedTransmission.run(count: 300, timings: timings, send: { index in
            attempts += 1
            if attempts % 3 == 0 { throw failure(ENOBUFS) }
            sent.append(index)
        }, pause: { pauses.append($0) })
        #expect(sent == Array(0..<300), "every packet, once, in sequence order")
        #expect(outcome.sent == 300 && outcome.lost == 0)
        #expect(outcome.chunkSizes.allSatisfy { $0 <= 32 } && outcome.chunkSizes.reduce(0, +) == 300, "\(outcome.chunkSizes)")
        #expect(outcome.chunkSizes.count > 1, "a keyframe is spread over several chunks")
        #expect(outcome.failures == [ENOBUFS: attempts / 3], "failed attempts are counted by errno")
        #expect(outcome.retries == outcome.failures[ENOBUFS], "each failed attempt was retried")
        let gaps = pauses.filter { $0 == timings.pacingGap }
        #expect(gaps.count == outcome.chunkSizes.count - 1, "one gap between chunks")
        #expect(pauses.count - gaps.count == outcome.retries, "the rest are retry waits")
    }

    @Test func aFrameIsNeverHeldBackLongerThanTheDelayCap() async {
        let timings = LiveStreamTimings()
        // 2000 packets would need 83 gaps of 1 ms at 24 per chunk; the cap (20 ms) makes the chunks bigger instead.
        let sizes = PacedTransmission.chunkSizes(count: 2_000, timings: timings)
        #expect(sizes.count - 1 <= Int(timings.maximumFrameDelay / timings.pacingGap))
        #expect(sizes.reduce(0, +) == 2_000)
        var paused: Duration = .zero
        let outcome = await PacedTransmission.run(count: 2_000, timings: timings, send: { _ in }, pause: { paused += $0 })
        #expect(outcome.sent == 2_000 && paused <= timings.maximumFrameDelay, "paced for \(paused)")
        // Small frames are one chunk, no waiting.
        #expect(PacedTransmission.chunkSizes(count: 3, timings: timings) == [3])
        #expect(PacedTransmission.chunkSizes(count: 24, timings: timings) == [24])
        #expect(PacedTransmission.chunkSizes(count: 25, timings: timings) == [13, 12])
        #expect(PacedTransmission.chunkSizes(count: 0, timings: timings).isEmpty)
    }

    @Test func aPacketThatKeepsFailingWithENOBUFSIsLostAfterTheRetries() async {
        var timings = LiveStreamTimings()
        timings.sendRetries = 4
        var attempts = 0
        var sent: [Int] = []
        let outcome = await PacedTransmission.run(count: 10, timings: timings, send: { index in
            attempts += 1
            if index == 5 { throw failure(ENOBUFS) }
            sent.append(index)
        }, pause: { _ in })
        #expect(sent == [0, 1, 2, 3, 4, 6, 7, 8, 9])
        #expect(outcome.lost == 1 && outcome.sent == 9 && outcome.retries == 4)
        #expect(outcome.failures == [ENOBUFS: 5], "the first attempt and four retries")
    }

    @Test func fatalAndOtherErrorsAreNotRetried() async {
        var attempts = 0
        let fatal = await PacedTransmission.run(count: 6, timings: LiveStreamTimings(), send: { _ in
            attempts += 1
            throw failure(EADDRNOTAVAIL)
        }, pause: { _ in })
        #expect(attempts == 6 && fatal.retries == 0 && fatal.lost == 6 && fatal.sent == 0)
        #expect(fatal.failures == [EADDRNOTAVAIL: 6])
        let tooLong = await PacedTransmission.run(count: 2, timings: LiveStreamTimings(), send: { _ in throw failure(EMSGSIZE) }, pause: { _ in })
        #expect(tooLong.retries == 0 && tooLong.lost == 2)
        #expect(SendFailure.classify(EMSGSIZE) == .other)
    }

    @Test func aClosedSocketStopsTheBurst() async {
        var sent = 0
        let outcome = await PacedTransmission.run(count: 100, timings: LiveStreamTimings(), send: { index in
            if index == 30 { throw UDPSocketError.closed }
            sent += 1
        }, pause: { _ in })
        #expect(sent == 30 && outcome.closed && outcome.sent == 30 && outcome.lost == 70)
    }

    @Test func interruptedCallsAndFullBuffersAreTransientTheAddressGoneIsFatal() {
        for code in [ENOBUFS, EAGAIN, EINTR] { #expect(SendFailure.classify(code) == .transient) }
        for code in [EADDRNOTAVAIL, ENETDOWN, ENETUNREACH, EHOSTUNREACH, EPERM] { #expect(SendFailure.classify(code) == .fatal) }
        #expect(SendFailure.suggestsLocalNetworkDenied(EHOSTUNREACH) && SendFailure.suggestsLocalNetworkDenied(EPERM))
        #expect(!SendFailure.suggestsLocalNetworkDenied(ENETDOWN) && !SendFailure.suggestsLocalNetworkDenied(EADDRNOTAVAIL))
        #expect(SendFailure.describe(ENOBUFS).hasPrefix("ENOBUFS (") && SendFailure.describe(9_999).hasPrefix("errno 9999"))
    }
}

@Suite struct SendFailureTrackerTests {
    private let t0 = ContinuousClock.now

    @Test func eachErrnoIsNewOnlyTheFirstTime() {
        var tracker = SendFailureTracker()
        #expect(tracker.record(successes: 3, failures: [ENOBUFS: 2, EAGAIN: 1], at: t0) == [EAGAIN, ENOBUFS].sorted())
        #expect(tracker.record(successes: 0, failures: [ENOBUFS: 5], at: t0 + .seconds(1)).isEmpty)
        #expect(tracker.record(successes: 0, failures: [EPERM: 1], at: t0 + .seconds(2)) == [EPERM])
        #expect(tracker.counts[ENOBUFS] == 7 && tracker.successes == 3)
    }

    @Test func aFatalErrorNeedsToPersistWithNoSendSucceeding() {
        var tracker = SendFailureTracker()
        tracker.record(successes: 0, failures: [EADDRNOTAVAIL: 4], at: t0)
        #expect(tracker.persistentFatal(at: t0 + .seconds(1), after: .seconds(2)) == nil)
        #expect(tracker.persistentFatal(at: t0 + .milliseconds(2_000), after: .seconds(2)) == EADDRNOTAVAIL)
        // Any success breaks the run (a Wi-Fi rejoin that fixed the address), and the clock starts again.
        tracker.record(successes: 1, failures: [:], at: t0 + .seconds(3))
        #expect(tracker.persistentFatal(at: t0 + .seconds(10), after: .seconds(2)) == nil)
        tracker.record(successes: 0, failures: [ENETDOWN: 1], at: t0 + .seconds(11))
        #expect(tracker.persistentFatal(at: t0 + .seconds(12), after: .seconds(2)) == nil)
        #expect(tracker.persistentFatal(at: t0 + .seconds(13), after: .seconds(2)) == ENETDOWN)
    }

    @Test func transientErrorsNeverEndASession() {
        var tracker = SendFailureTracker()
        for second in 0..<30 { tracker.record(successes: 0, failures: [ENOBUFS: 10], at: t0 + .seconds(second)) }
        #expect(tracker.persistentFatal(at: t0 + .seconds(60), after: .seconds(2)) == nil)
    }
}

/// A replay (the newest GOP) is spread at twice the negotiated bit rate; live frames never wait.
@Suite struct CatchUpPacerTests {
    private let t0 = ContinuousClock.now

    @Test func noBitrateMeansNoPacing() {
        var pacer = CatchUpPacer(maxBitrateKbps: nil, factor: 2)
        #expect(pacer.delay(bytes: 1_000_000, pts: 0, now: t0) == .zero)
        #expect(pacer.delay(bytes: 1_000_000, pts: 0.008, now: t0) == .zero)
        var zero = CatchUpPacer(maxBitrateKbps: 0, factor: 2)
        #expect(zero.delay(bytes: 1_000_000, pts: 0, now: t0) == .zero)
    }

    @Test func aReplayIsSpreadAtTwiceTheBitrate() {
        // 800 kbit/s negotiated: 200 kB/s paced. The replay's frames are packed 8 ms apart on the media timeline and all
        // arrive at once.
        var pacer = CatchUpPacer(maxBitrateKbps: 800, factor: 2)
        var waits: [Duration] = []
        var now = t0
        let keyframe = pacer.delay(bytes: 60_000, pts: 0, now: now)   // the first frame (a keyframe): never held back
        #expect(keyframe == .zero)
        for index in 1..<40 {
            let wait = pacer.delay(bytes: 5_000, pts: Double(index) * 0.008, now: now)
            waits.append(wait)
            now += wait   // the session sleeps, then sends
        }
        #expect(waits.prefix(3).allSatisfy { $0 == .zero }, "the first 30 ms of media pass unpaced")
        // 5 kB at 200 kB/s: each held-back frame waits 25 ms.
        let held = waits.filter { $0 > .zero }
        #expect(held.count > 5 && held.allSatisfy { abs(($0 - .milliseconds(25)) / .milliseconds(1)) < 1 }, "\(waits)")
        // Waiting stops costing the viewer anything once the wall clock has caught up with the media timeline (0.31 s here).
        let total = (now - t0) / .seconds(1)
        #expect(total > 0.15 && total < 0.32, "replay took \(total) s")
    }

    @Test func liveFramesNeverWaitEvenWhenTheyExceedTheBitrate() {
        var pacer = CatchUpPacer(maxBitrateKbps: 800, factor: 2)
        var now = t0
        // A source at 8 Mbit/s (10x the negotiated rate) delivering in real time: media time keeps pace with the clock.
        for index in 0..<100 {
            #expect(pacer.delay(bytes: 33_000, pts: Double(index) / 30, now: now) == .zero, "frame \(index)")
            now += .seconds(1.0 / 30)
        }
    }
}

/// `ControllerReceptionMonitor`: the receiver reports of a controller that receives nothing, and of one that does.
@Suite struct ControllerReceptionMonitorTests {
    private let t0 = ContinuousClock.now
    private let ssrc: UInt32 = 0xAAAA_0001

    private func at(_ seconds: Double) -> ContinuousClock.Instant { t0 + .seconds(seconds) }

    private func monitor(_ timings: LiveStreamTimings = LiveStreamTimings()) -> ControllerReceptionMonitor {
        ControllerReceptionMonitor(videoSSRC: ssrc, timings: timings, startedAt: t0)
    }

    private func block(sequence: UInt32, fractionLost: UInt8 = 0, ssrc: UInt32? = nil) -> RTCPReportBlock {
        RTCPReportBlock(ssrc: ssrc ?? self.ssrc, fractionLost: fractionLost, extendedHighestSequence: sequence)
    }

    /// Video flows at 30 packets per second from `start`.
    private func feed(_ monitor: inout ControllerReceptionMonitor, until end: Double, every interval: Double = 0.5, from start: Double = 0.2,
                      blocks: (Double) -> [RTCPReportBlock]) {
        var time = start
        monitor.videoSent(total: 1, at: at(0.1))
        while time <= end {
            monitor.videoSent(total: Int(time * 30) + 1, at: at(time))
            monitor.report(blocks: blocks(time), at: at(time))
            time += interval
        }
    }

    @Test func reportsThatNeverMentionOurVideoMakeAControllerBlindAfterThreeSecondsAndAFourSecondSession() {
        var monitor = monitor()
        feed(&monitor, until: 3.4) { _ in [] }
        #expect(monitor.verdict(at: at(3.4)) == nil, "the symptom is under 3 s old")
        feed(&monitor, until: 3.8, from: 3.7) { _ in [] }
        #expect(monitor.verdict(at: at(3.8)) == nil, "the session is under 4 s old")
        monitor.videoSent(total: 130, at: at(4.0))
        monitor.report(blocks: [], at: at(4.0))
        let verdict = monitor.verdict(at: at(4.1))
        #expect(verdict?.symptom == .noReportBlock)
        #expect(verdict.map { $0.since == at(0.2) && $0.reports >= 3 && $0.packetsSentSince >= 30 } == true)
    }

    @Test func receiverReportsBeforeAnyVideoSayNothing() {
        var monitor = monitor()
        for second in stride(from: 0.0, through: 6.0, by: 0.5) { monitor.report(blocks: [], at: at(second)) }
        #expect(monitor.reportsSinceFirstVideo == 0)
        #expect(monitor.verdict(at: at(6.1)) == nil, "the controller was just alive: no video had been sent")
        // Video starts at 6 s: it takes the usual dwell before blindness can be shown.
        monitor.videoSent(total: 60, at: at(6.2))
        monitor.report(blocks: [], at: at(6.5))
        #expect(monitor.verdict(at: at(6.6)) == nil)
    }

    @Test func aHealthyControllerIsNeverFlagged() {
        var monitor = monitor()
        feed(&monitor, until: 60) { time in [block(sequence: UInt32(time * 30), fractionLost: 3)] }
        for second in stride(from: 4.0, through: 60.0, by: 1.0) { #expect(monitor.verdict(at: at(second)) == nil, "at \(second)") }
    }

    @Test func aHighestSequenceThatStaysPutWhileWeSendIsBlind() {
        var monitor = monitor()
        feed(&monitor, until: 6) { _ in [block(sequence: 4_000)] }
        let verdict = monitor.verdict(at: at(6.1))
        #expect(verdict?.symptom == .nothingNew)
        #expect(verdict.map { $0.since == at(0.2) && $0.packetsSentSince >= 50 } == true)
    }

    @Test func aFrozenSequenceWithNothingSentIsAStalledSourceNotABlindController() {
        var monitor = monitor()
        monitor.videoSent(total: 10, at: at(0.1))
        for second in stride(from: 0.5, through: 8.0, by: 0.5) { monitor.report(blocks: [block(sequence: 9)], at: at(second)) }
        #expect(monitor.verdict(at: at(8.1)) == nil, "10 packets in all: nothing was sent while the sequence stood still")
    }

    @Test func almostEverythingLostIsBlindEvenWhenTheSequenceAdvances() {
        var monitor = monitor()
        feed(&monitor, until: 5) { time in [block(sequence: UInt32(time * 30), fractionLost: 240)] }
        #expect(monitor.verdict(at: at(5.1))?.symptom == .heavyLoss)
        // 20 % loss is a bad network, not a blind controller.
        var lossy = self.monitor()
        feed(&lossy, until: 20) { time in [block(sequence: UInt32(time * 30), fractionLost: 51)] }
        #expect(lossy.verdict(at: at(20.1)) == nil)
    }

    @Test func blocksAboutOtherSourcesDoNotCount() {
        var monitor = monitor()
        feed(&monitor, until: 5) { time in [block(sequence: UInt32(time * 30), ssrc: 0xBBBB_0002)] }
        #expect(monitor.verdict(at: at(5.1))?.symptom == .noReportBlock, "a block for the audio stream says nothing about the video")
    }

    @Test func aControllerThatStartsReceivingIsNoLongerBlind() {
        var monitor = monitor()
        feed(&monitor, until: 5) { _ in [] }
        #expect(monitor.verdict(at: at(5.1)) != nil)
        monitor.videoSent(total: 200, at: at(5.2))
        monitor.report(blocks: [block(sequence: 150)], at: at(5.2))
        #expect(monitor.verdict(at: at(5.3)) == nil, "a block about our video with something arriving clears it")
    }

    @Test func fewerThanThreeReportsOrStaleOnesAreNoEvidence() {
        var monitor = monitor()
        monitor.videoSent(total: 100, at: at(0.1))
        monitor.report(blocks: [], at: at(0.5))
        monitor.report(blocks: [], at: at(1.0))
        monitor.videoSent(total: 400, at: at(10))
        #expect(monitor.verdict(at: at(10)) == nil, "two reports are too few")
        var stale = self.monitor()
        feed(&stale, until: 3.5) { _ in [] }
        stale.videoSent(total: 1_000, at: at(30))
        #expect(stale.verdict(at: at(30)) == nil, "the reports stopped 26 s ago: the controller timeout's business")
    }
}

/// Symmetric RTP latches once and does not flap (`DestinationLatch`).
@Suite struct DestinationLatchTests {
    private let t0 = ContinuousClock.now
    private let relatch: Duration = .seconds(5)

    @Test func theFirstPacketDecidesAndAnotherSourceDoesNotFlapTheDestination() {
        var latch = DestinationLatch()
        // The controller advertised A, its first packet (video RTCP) comes from B: the stream moves to B once.
        #expect(latch.observe(source: "10.0.0.8", destination: "10.0.0.7", now: t0, relatchAfter: relatch) == .moved(silentFor: nil))
        // Its audio comes from C (another interface) every 20 ms for 4 s, video RTCP from B every 500 ms: no flapping.
        var decisions: [DestinationLatch.Decision] = []
        for step in 1...200 {
            let now = t0 + .milliseconds(step * 20)
            decisions.append(latch.observe(source: "10.0.0.9", destination: "10.0.0.8", now: now, relatchAfter: relatch))
            if step % 25 == 0 { decisions.append(latch.observe(source: "10.0.0.8", destination: "10.0.0.8", now: now, relatchAfter: relatch)) }
        }
        #expect(!decisions.contains { if case .moved = $0 { true } else { false } }, "the destination never moved again")
        #expect(decisions.filter { $0 == .ignored(first: true) }.count == 1, "one log line")
    }

    @Test func aSourceFollowsOnlyAfterTheLatchedOneWasSilentForTheGap() {
        var latch = DestinationLatch()
        _ = latch.observe(source: "10.0.0.7", destination: "10.0.0.7", now: t0, relatchAfter: relatch)   // decided: the advertised address
        #expect(latch.observe(source: "10.0.0.9", destination: "10.0.0.7", now: t0 + .seconds(4), relatchAfter: relatch) == .ignored(first: true))
        #expect(latch.observe(source: "10.0.0.9", destination: "10.0.0.7", now: t0 + .milliseconds(4_999), relatchAfter: relatch) == .ignored(first: false))
        #expect(latch.observe(source: "10.0.0.9", destination: "10.0.0.7", now: t0 + .seconds(5), relatchAfter: relatch) == .moved(silentFor: .seconds(5)))
        // Now 10.0.0.9 is the destination; the old one is just another source.
        #expect(latch.observe(source: "10.0.0.7", destination: "10.0.0.9", now: t0 + .seconds(6), relatchAfter: relatch) == .ignored(first: true))
    }

    @Test func aPacketFromTheDestinationKeepsItAlive() {
        var latch = DestinationLatch()
        _ = latch.observe(source: "10.0.0.7", destination: "10.0.0.7", now: t0, relatchAfter: relatch)
        for second in 1...30 {   // the destination answers every second: another source is never followed
            _ = latch.observe(source: "10.0.0.7", destination: "10.0.0.7", now: t0 + .seconds(second), relatchAfter: relatch)
            let other = latch.observe(source: "10.0.0.9", destination: "10.0.0.7", now: t0 + .seconds(second) + .milliseconds(10), relatchAfter: relatch)
            #expect({ if case .moved = other { false } else { true } }())
        }
    }

    @Test func addressesAreComparedAsAddresses() {
        var latch = DestinationLatch()
        #expect(latch.observe(source: "::ffff:10.0.0.7", destination: "10.0.0.7", now: t0, relatchAfter: relatch) == .unchanged)
        #expect(latch.observe(source: "fe80::1%en0", destination: "FE80:0:0:0:0:0:0:1", now: t0, relatchAfter: relatch) == .unchanged)
    }
}
