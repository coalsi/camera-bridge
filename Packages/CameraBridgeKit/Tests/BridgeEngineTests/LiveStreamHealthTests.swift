import BridgeSupport
import Foundation
import MediaCore
import RTP
import Testing
@testable import BridgeEngine

/// The live stream's health ladder on a virtual clock (audit 2 F3): every rule is a function of the metrics at a tick, so the
/// tests step seconds without waiting.
@Suite struct LiveStreamHealthTests {
    private let timing = LiveStreamTiming.standard   // recover at 4 s, end at 12 s (start) / 10 s (stall)

    private func metrics(at seconds: Double, packets: Int = 0, silentFor: Double? = nil, hubAge: Double? = 0.03, transcoding: Bool = true,
                         sinceKeyframe: Double? = 1) -> LiveStreamMetrics {
        LiveStreamMetrics(elapsed: .seconds(seconds), videoPackets: packets, sinceVideoPacket: silentFor.map { .seconds($0) }, hubAge: hubAge.map { .seconds($0) },
                          transcoding: transcoding, sinceKeyframeOut: sinceKeyframe.map { .seconds($0) }, hubFrameRate: 30, codecs: "decoder hardware, encoder hardware")
    }

    private func texts(_ actions: [LiveStreamHealth.Action]) -> [String] {
        actions.map { action in
            switch action {
            case .info(let text), .warning(let text), .end(let text), .rebuild(let text): text
            case .forceKeyframe: "forceKeyframe"
            }
        }
    }

    // MARK: Start

    @Test func nothingHappensBeforeTheRecoveryTimeAtStart() {
        var health = LiveStreamHealth(timing: timing)
        for second in stride(from: 1.0, through: 3.9, by: 0.5) {
            #expect(health.evaluate(metrics(at: second)) == [], "at \(second) s")
        }
    }

    @Test func noPictureAtFourSecondsWhileTheCameraDeliversForcesAKeyframeAndRebuildsOnce() {
        var health = LiveStreamHealth(timing: timing)
        let actions = health.evaluate(metrics(at: 4))
        #expect(actions.contains(.forceKeyframe))
        #expect(actions.contains { if case .rebuild = $0 { true } else { false } })
        let warning = texts(actions).first { $0.contains("no picture") && $0.contains("rebuilding") }
        #expect(warning != nil && warning!.contains("30 fps") && warning!.contains("decoder hardware, encoder hardware"), "\(texts(actions))")
        #expect(health.summary.hasPrefix("recovering"))
        // Once only.
        #expect(health.evaluate(metrics(at: 5)) == [])
        #expect(health.evaluate(metrics(at: 11.9)) == [])
    }

    @Test func stillNothingAtTheStartLimitEndsTheStreamWithOneReasonLine() {
        var health = LiveStreamHealth(timing: timing)
        _ = health.evaluate(metrics(at: 4))
        let actions = health.evaluate(metrics(at: 12))
        let end = actions.compactMap { action -> String? in if case .end(let reason) = action { reason } else { nil } }
        #expect(end.count == 1 && end[0].contains("no picture was produced") && end[0].contains("recovery did not help"))
        #expect(health.summary.hasPrefix("ended"))
        #expect(health.evaluate(metrics(at: 13)) == [], "an ended stream is not evaluated again")
    }

    @Test func aCameraThatDoesNotDeliverIsWaitedForAndEndsWithItsOwnReason() {
        var health = LiveStreamHealth(timing: timing)
        let waiting = health.evaluate(metrics(at: 4, hubAge: nil))
        #expect(waiting.count == 1 && texts(waiting)[0].contains("no frame since it connected"), "\(texts(waiting))")
        #expect(!waiting.contains(.forceKeyframe), "nothing to rebuild when there is no source")
        #expect(health.evaluate(metrics(at: 8, hubAge: nil)) == [], "told once")
        let end = health.evaluate(metrics(at: 12, hubAge: nil))
        #expect(texts(end).contains { $0.contains("camera delivered no picture") })
        #expect(end.contains { if case .end = $0 { true } else { false } })
    }

    @Test func aStaleHubCountsAsOffline() {
        var health = LiveStreamHealth(timing: timing)
        let actions = health.evaluate(metrics(at: 5, hubAge: 3))   // the camera's last frame was 3 s ago: past the 2 s window
        #expect(!actions.contains(.forceKeyframe))
        #expect(texts(actions).contains { $0.contains("not delivering") })
    }

    // MARK: Stall

    @Test func aStallAtFourSecondsRecoversAndEightToTenEndsIt() {
        var health = LiveStreamHealth(timing: timing)
        #expect(health.evaluate(metrics(at: 30, packets: 900, silentFor: 0)) == [])
        #expect(health.summary == "ok")
        #expect(health.evaluate(metrics(at: 33, packets: 900, silentFor: 3)) == [], "3 s of silence is not enough")
        let recover = health.evaluate(metrics(at: 34, packets: 900, silentFor: 4))
        #expect(recover.contains(.forceKeyframe) && recover.contains { if case .rebuild = $0 { true } else { false } })
        #expect(texts(recover).contains { $0.contains("attempt 1") })
        #expect(health.evaluate(metrics(at: 35, packets: 900, silentFor: 5)) == [])
        let second = health.evaluate(metrics(at: 38, packets: 900, silentFor: 8))
        #expect(second.contains(.forceKeyframe), "another recovery 4 s later")
        let end = health.evaluate(metrics(at: 40, packets: 900, silentFor: 10))
        #expect(end.contains { if case .end(let reason) = $0 { reason.contains("recovery did not help") } else { false } })
    }

    @Test func videoThatResumesResetsTheLadder() {
        var health = LiveStreamHealth(timing: timing)
        _ = health.evaluate(metrics(at: 34, packets: 900, silentFor: 4))
        #expect(health.summary.hasPrefix("recovering"))
        #expect(health.evaluate(metrics(at: 35, packets: 930, silentFor: 0)) == [])
        #expect(health.summary == "ok")
        // A later stall gets a full ladder again.
        #expect(health.evaluate(metrics(at: 60, packets: 930, silentFor: 4)).contains(.forceKeyframe))
    }

    @Test func aStallWhileTheCameraStoppedDeliveringIsNotRebuiltAndEndsAtTheLimit() {
        var health = LiveStreamHealth(timing: timing)
        let first = health.evaluate(metrics(at: 34, packets: 900, silentFor: 4, hubAge: 4))
        #expect(!first.contains(.forceKeyframe) && texts(first).contains { $0.contains("camera stopped delivering") })
        #expect(health.evaluate(metrics(at: 36, packets: 900, silentFor: 6, hubAge: 6)) == [])
        let end = health.evaluate(metrics(at: 40, packets: 900, silentFor: 10, hubAge: 10))
        #expect(end.contains { if case .end(let reason) = $0 { reason.contains("stopped delivering") } else { false } })
    }

    @Test func aPassthroughStallAsksForAKeyframeButHasNothingToRebuild() {
        var health = LiveStreamHealth(timing: timing)
        let actions = health.evaluate(metrics(at: 34, packets: 900, silentFor: 4, transcoding: false))
        #expect(actions.contains(.forceKeyframe))
        #expect(!actions.contains { if case .rebuild = $0 { true } else { false } })
    }

    // MARK: Keyframe cadence

    @Test func aTranscodingStreamWithoutKeyframesGetsOneForcedAndEndsAtTenSeconds() {
        var health = LiveStreamHealth(timing: timing)
        #expect(health.evaluate(metrics(at: 30, packets: 900, silentFor: 0, sinceKeyframe: 5.9)) == [])
        let forced = health.evaluate(metrics(at: 31, packets: 960, silentFor: 0, sinceKeyframe: 6))
        #expect(forced.contains(.forceKeyframe) && texts(forced).contains { $0.contains("no keyframe for 6.0 s") })
        #expect(health.evaluate(metrics(at: 32, packets: 990, silentFor: 0, sinceKeyframe: 7)) == [], "not again within 4 s")
        let end = health.evaluate(metrics(at: 35, packets: 1_050, silentFor: 0, sinceKeyframe: 10))
        #expect(end.contains { if case .end(let reason) = $0 { reason.contains("no keyframe") } else { false } })
    }

    @Test func passthroughHasNoKeyframeCadenceRule() {
        var health = LiveStreamHealth(timing: timing)
        #expect(health.evaluate(metrics(at: 40, packets: 900, silentFor: 0, transcoding: false, sinceKeyframe: 30)) == [])
    }

    // MARK: Self-check verdicts

    @Test func aFailedProbeRebuildsOnceAndTwoInARowEnd() {
        var health = LiveStreamHealth(timing: timing)
        let first = health.noteProbe(.failed("the keyframe does not decode", definitive: false))
        #expect(first.contains { if case .rebuild = $0 { true } else { false } })
        #expect(!first.contains { if case .end = $0 { true } else { false } })
        let second = health.noteProbe(.failed("the keyframe does not decode", definitive: false))
        #expect(texts(second).contains { $0.hasPrefix("live self-check FAILED") })
        #expect(second.contains { if case .end = $0 { true } else { false } })
    }

    @Test func aPassingProbeForgivesAnEarlierFailure() {
        var health = LiveStreamHealth(timing: timing)
        _ = health.noteProbe(.failed("x", definitive: false))
        _ = health.noteProbe(.passed("ok"))
        #expect(!health.noteProbe(.failed("x", definitive: false)).contains { if case .end = $0 { true } else { false } })
    }

    @Test func aDefinitiveFailureEndsAtOnce() {
        var health = LiveStreamHealth(timing: timing)
        let actions = health.noteProbe(.failed("the keyframe is 320×240, not the 480×270 the controller selected", definitive: true))
        #expect(actions.contains { if case .end = $0 { true } else { false } })
    }

    @Test func aBlankPictureRebuildsOnceAndEndsOnTheSecond() {
        var health = LiveStreamHealth(timing: timing)
        let first = health.noteProbe(.blank("the picture sent is all zero (it would show green) while the camera's picture is real"))
        #expect(first.contains { if case .rebuild = $0 { true } else { false } })
        #expect(health.noteProbe(.blank("again")).contains { if case .end = $0 { true } else { false } })
    }

    @Test func anInconclusiveProbeSaysNothing() {
        var health = LiveStreamHealth(timing: timing)
        #expect(health.noteProbe(.inconclusive("no decoder")) == [])
    }
}

/// What a failing transcoder leads to (audit 2 F2).
@Suite struct TranscodeFailureLadderTests {
    private var timing: LiveStreamTiming {
        var timing = LiveStreamTiming.standard
        timing.failureEnd = .seconds(3)
        timing.rebuildSpacing = .milliseconds(500)
        return timing
    }

    @Test func theFirstFailureDropsTheFrameAndTheSecondRebuilds() {
        var ladder = TranscodeFailureLadder(timing: timing)
        let start = ContinuousClock.now
        #expect(ladder.failed(keyframe: false, at: start, error: "e") == .drop)
        #expect(ladder.isFirstOfIncident)
        #expect(ladder.failed(keyframe: false, at: start + .milliseconds(33), error: "e") == .rebuild(software: false))
    }

    @Test func aKeyframeThatFailedRebuildsWithASoftwareDecoder() {
        var ladder = TranscodeFailureLadder(timing: timing)
        let start = ContinuousClock.now
        _ = ladder.failed(keyframe: true, at: start, error: "e")
        #expect(ladder.failed(keyframe: true, at: start + .milliseconds(33), error: "e") == .rebuild(software: true))
    }

    @Test func aTranscoderThatFailsEveryFrameIsRebuiltAtMostEveryHalfSecondThenTheStreamEnds() {
        var ladder = TranscodeFailureLadder(timing: timing)
        let start = ContinuousClock.now
        var rebuilds = 0
        var end: String?
        for frame in 0..<200 {   // 30 fps for 6.6 s
            let step = ladder.failed(keyframe: false, at: start + .milliseconds(frame * 33), error: "-12915")
            switch step {
            case .rebuild: rebuilds += 1
            case .end(let reason): end = end ?? reason
            case .drop: break
            }
            if end != nil { break }
        }
        #expect((4...8).contains(rebuilds), "\(rebuilds) rebuilds, not one per frame")
        #expect(end?.contains("without producing a frame") == true && end?.contains("-12915") == true, "\(end ?? "never ended")")
    }

    @Test func aFrameThatSucceedsEndsTheIncident() {
        var ladder = TranscodeFailureLadder(timing: timing)
        let start = ContinuousClock.now
        _ = ladder.failed(keyframe: false, at: start, error: "e")
        ladder.succeeded(at: start + .milliseconds(40))
        #expect(ladder.failed(keyframe: false, at: start + .seconds(10), error: "e") == .drop, "a new incident starts with a drop, not a rebuild or the end")
    }
}

/// The self-check's structural half (no decoder): packetization, marker bits, parameter sets, profile, size.
@Suite struct LiveSelfCheckStructureTests {
    /// A real SPS (640×360 Main level 3.1 as VideoToolbox writes it) and PPS.
    private static let sps = Data([0x67, 0x4D, 0x40, 0x1F, 0x96, 0x54, 0x05, 0x01, 0xED, 0x80, 0x88, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03, 0x01, 0xE4, 0x60, 0xC6, 0x58])
    private static let pps = Data([0x68, 0xEE, 0x3C, 0x80])

    private func format() throws -> VideoFormat {
        try #require(VideoFormat.h264(sps: Self.sps, pps: Self.pps))
    }

    private func frames(count: Int = 5, bytes: Int = 3_000) throws -> [EncodedVideoFrame] {
        let format = try format()
        return (0..<count).map { index in
            var slice = Data(repeating: UInt8(index + 1), count: bytes)
            slice[0] = index == 0 ? 0x65 : 0x41
            return EncodedVideoFrame(format: format, nalUnits: [slice], isKeyframe: index == 0, pts: MediaTime(value: Int64(index * 3_000), timescale: 90_000),
                                     wallClock: Date())
        }
    }

    private func expectation(_ format: VideoFormat) -> LiveSelfCheck.Expectation {
        LiveSelfCheck.Expectation(width: format.width, height: format.height, maximumProfileRank: 1, payloadType: 99, maxPacketSize: 1200, inputPicture: nil,
                                  transcoded: true)
    }

    @Test func aWellFormedStreamPasses() throws {
        let sample = try frames()
        #expect(LiveSelfCheck.structuralFailure(frames: sample, expectation: expectation(sample[0].format)) == nil)
    }

    @Test func aKeyframeOfAnotherSizeThanSelectedFails() throws {
        let sample = try frames()
        var wrong = expectation(sample[0].format)
        wrong.width = 480
        wrong.height = 270
        let failure = LiveSelfCheck.structuralFailure(frames: sample, expectation: wrong)
        #expect(failure?.contains("not the 480×270 the controller selected") == true, "\(failure ?? "passed")")
    }

    @Test func aProfileAboveTheSelectedOneFails() throws {
        let sample = try frames()
        var baseline = expectation(sample[0].format)
        baseline.maximumProfileRank = 0   // the controller selected Baseline; the stream is Main
        #expect(LiveSelfCheck.structuralFailure(frames: sample, expectation: baseline)?.contains("above the one the controller selected") == true)
    }

    @Test func aPassthroughStreamIsNotHeldToTheSelectedSizeOrProfile() throws {
        let sample = try frames()
        var passthrough = expectation(sample[0].format)
        passthrough.transcoded = false
        passthrough.width = 1
        passthrough.maximumProfileRank = 0
        #expect(LiveSelfCheck.structuralFailure(frames: sample, expectation: passthrough) == nil)
    }

    @Test func aFrameWithoutPictureDataFails() throws {
        var sample = try frames()
        sample[0].nalUnits = [Data([0x06, 0x01, 0x02])]   // SEI only
        #expect(LiveSelfCheck.structuralFailure(frames: sample, expectation: expectation(sample[0].format))?.contains("no picture data") == true)
    }

    @Test func largeFramesFragmentAndReassembleIntact() throws {
        let sample = try frames(count: 3, bytes: 40_000)
        #expect(LiveSelfCheck.structuralFailure(frames: sample, expectation: expectation(sample[0].format)) == nil)
    }

    @Test func reassembleHandlesStapSingleAndFragments() {
        let stap = RTPPacket(payloadType: 99, sequenceNumber: 1, timestamp: 0, ssrc: 1, payload: Data([24, 0, 2, 0x67, 1, 0, 2, 0x68, 2]))
        let single = RTPPacket(payloadType: 99, sequenceNumber: 2, timestamp: 0, ssrc: 1, payload: Data([0x41, 9, 9]))
        let start = RTPPacket(payloadType: 99, sequenceNumber: 3, timestamp: 0, ssrc: 1, payload: Data([0x7C, 0x85, 1, 2]))
        let end = RTPPacket(payloadType: 99, sequenceNumber: 4, timestamp: 0, ssrc: 1, payload: Data([0x7C, 0x45, 3, 4]))
        #expect(LiveSelfCheck.reassemble([stap, single, start, end]) == [Data([0x67, 1]), Data([0x68, 2]), Data([0x41, 9, 9]), Data([0x65, 1, 2, 3, 4])])
        #expect(LiveSelfCheck.reassemble([start]) == nil, "a fragment that never ends")
        #expect(LiveSelfCheck.reassemble([end]) == nil, "an end without a start")
    }

    @Test func theProbeSlotIsExclusive() {
        #expect(LiveSelfCheck.tryAcquire())
        #expect(!LiveSelfCheck.tryAcquire(), "one probe in flight in the whole process")
        LiveSelfCheck.release()
        #expect(LiveSelfCheck.tryAcquire())
        LiveSelfCheck.release()
    }

    @Test func theProbePlanTakesTheFirstThreeKeyframesThenOneAMinute() throws {
        var plan = LiveSelfCheckPlan(count: 3, interval: .seconds(60))
        let sample = try frames(count: 3)
        let start = ContinuousClock.now
        var taken = 0
        // Keyframes every 2 s for 3 minutes; each followed by two deltas, so a sample completes at the next keyframe.
        for second in stride(from: 0, to: 180, by: 2) {
            let now = start + .seconds(second)
            if plan.offer(sample[0], at: now) != nil { taken += 1 }
            _ = plan.offer(sample[1], at: now + .milliseconds(33))
            _ = plan.offer(sample[2], at: now + .milliseconds(66))
        }
        // Samples complete one keyframe late: 3 at the start, then at 60 s, 120 s (the one at 180 s is still being collected).
        #expect(taken == 5 || taken == 4, "\(taken) samples in 3 minutes")
        #expect(taken >= 4)
    }

    @Test func aSampleCompletesAtSixteenFramesAndTheStreamChangingDropsOneInTheMaking() throws {
        var plan = LiveSelfCheckPlan(count: 3, interval: .seconds(60))
        let sample = try frames(count: 2)
        let start = ContinuousClock.now
        #expect(plan.offer(sample[0], at: start) == nil)
        var completed: [EncodedVideoFrame]?
        for index in 1..<LiveSelfCheck.framesPerProbe { completed = plan.offer(sample[1], at: start + .milliseconds(index * 33)) ?? completed }
        #expect(completed?.count == LiveSelfCheck.framesPerProbe && completed?.first?.isKeyframe == true)
        // A sample in the making is dropped when the stream's source changes.
        _ = plan.offer(sample[0], at: start + .seconds(2))
        plan.restart()
        #expect(plan.offer(sample[1], at: start + .seconds(2.1)) == nil)
    }
}
