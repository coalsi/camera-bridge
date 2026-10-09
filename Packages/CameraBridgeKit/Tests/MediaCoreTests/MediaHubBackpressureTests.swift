import BridgeSupport
import Foundation
import Synchronization
import Testing
@testable import MediaCore

/// A subscriber that falls behind must never decode deltas whose keyframe it lost (audit 2 F1): the hub drops whole GOPs,
/// so every sample a consumer reads after a gap in the stream is a keyframe.
@Suite(.timeLimit(.minutes(1))) struct MediaHubBackpressureTests {
    private static let format = VideoFormat(codec: .h264, width: 1280, height: 720, parameterSets: [Data([0x67, 1]), Data([0x68, 2])])

    /// Frame `index`: a keyframe when `keyframe`; its index is in the first NAL's second byte (indices up to 255) and the PTS.
    private static func frame(_ index: Int, keyframe: Bool) -> MediaSample {
        .video(EncodedVideoFrame(format: format, nalUnits: [Data([keyframe ? 0x65 : 0x41, UInt8(truncatingIfNeeded: index)])], isKeyframe: keyframe,
                                 pts: MediaTime(value: Int64(index * 3_000), timescale: 90_000),
                                 wallClock: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) / 30)))
    }

    private static func audio(_ index: Int) -> MediaSample {
        .audio(EncodedAudioFrame(format: AudioFormat.aacLC(sampleRate: 16_000, channels: 1), data: Data([0x21, UInt8(truncatingIfNeeded: index)]),
                                 pts: MediaTime(value: Int64(index * 1024), timescale: 16_000), sampleCount: 1024,
                                 wallClock: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) * 0.064)))
    }

    /// Frame indices of `samples` (video only) in the order read, with whether each is a keyframe.
    private static func videoIndices(_ samples: [MediaSample]) -> [(index: Int, key: Bool)] {
        samples.compactMap { sample in
            guard case .video(let frame) = sample else { return nil }
            return (Int(frame.nalUnits[0][1]), frame.isKeyframe)
        }
    }

    /// Everything queued, read once the subscription is finished.
    private static func drain(_ subscription: MediaSubscription) async -> [MediaSample] {
        subscription.cancel()
        var out: [MediaSample] = []
        for await sample in subscription.samples { out.append(sample) }
        return out
    }

    /// The invariant: a video sample whose index is not the previous read sample's successor follows a gap and is a keyframe.
    private static func assertEveryGapEndsOnAKeyframe(_ read: [(index: Int, key: Bool)], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(read.first?.key == true, "the first sample read is a keyframe", sourceLocation: sourceLocation)
        for (previous, next) in zip(read, read.dropFirst()) where next.index != previous.index + 1 {
            #expect(next.key, "frame \(next.index) follows a gap after frame \(previous.index) and must be a keyframe", sourceLocation: sourceLocation)
        }
    }

    @Test func aSingleGOPThatOverflowsIsDroppedAndTheConsumerResumesAtTheNextKeyframe() async {
        let hub = MediaHub()
        let subscription = await hub.subscribe(from: .nextKeyframe, bufferLimit: 8)
        // key + 40 P with nobody reading, then key + 5 P.
        await hub.ingest(Self.frame(0, keyframe: true))
        for index in 1...40 { await hub.ingest(Self.frame(index, keyframe: false)) }
        await hub.ingest(Self.frame(41, keyframe: true))
        for index in 42...46 { await hub.ingest(Self.frame(index, keyframe: false)) }
        let read = Self.videoIndices(await Self.drain(subscription))
        #expect(read.map(\.index) == Array(41...46), "the first GOP was dropped whole; the second arrived intact")
        Self.assertEveryGapEndsOnAKeyframe(read)
    }

    @Test func theOldestGOPIsDroppedWhenALaterOneIsQueued() async {
        let hub = MediaHub()
        let subscription = await hub.subscribe(from: .nextKeyframe, bufferLimit: 8)
        // Two GOPs of 4 fill the queue; the next sample drops the first and keeps the second.
        for index in 0..<8 { await hub.ingest(Self.frame(index, keyframe: index % 4 == 0)) }
        await hub.ingest(Self.frame(8, keyframe: false))
        await hub.ingest(Self.frame(9, keyframe: false))
        let read = Self.videoIndices(await Self.drain(subscription))
        #expect(read.map(\.index) == [4, 5, 6, 7, 8, 9])
        Self.assertEveryGapEndsOnAKeyframe(read)
    }

    @Test func aConsumerMidGOPResumesAtAKeyframeNotAtAnOrphanedDelta() async {
        let hub = MediaHub()
        let subscription = await hub.subscribe(from: .nextKeyframe, bufferLimit: 8)
        var iterator = subscription.samples.makeAsyncIterator()
        await hub.ingest(Self.frame(0, keyframe: true))
        for index in 1...5 { await hub.ingest(Self.frame(index, keyframe: false)) }
        var read: [MediaSample] = []
        for _ in 0..<3 { if let sample = await iterator.next() { read.append(sample) } }   // K0 P1 P2: P3.. wait in the queue
        for index in 6...30 { await hub.ingest(Self.frame(index, keyframe: false)) }       // overflows: the rest of the GOP goes
        await hub.ingest(Self.frame(31, keyframe: true))
        await hub.ingest(Self.frame(32, keyframe: false))
        subscription.cancel()
        while let sample = await iterator.next() { read.append(sample) }
        let indices = Self.videoIndices(read)
        #expect(indices.map(\.index) == [0, 1, 2, 31, 32])
        Self.assertEveryGapEndsOnAKeyframe(indices)
    }

    @Test func noGapWhenTheConsumerKeepsUp() async {
        let hub = MediaHub()
        let subscription = await hub.subscribe(from: .nextKeyframe, bufferLimit: 8)
        var iterator = subscription.samples.makeAsyncIterator()
        var read: [MediaSample] = []
        for index in 0..<200 {
            await hub.ingest(Self.frame(index, keyframe: index % 30 == 0))
            if let sample = await iterator.next() { read.append(sample) }
        }
        #expect(Self.videoIndices(read).map(\.index) == Array(0..<200))
        subscription.cancel()
    }

    @Test func aPrebufferReplayLongerThanTheLimitArrivesWholeAndLaterOverflowsByGOP() async {
        let hub = MediaHub()
        // 3 GOPs of 30 frames = 90 held; bufferLimit 10 is far below the replay.
        for index in 0..<90 { await hub.ingest(Self.frame(index, keyframe: index % 30 == 0)) }
        let subscription = await hub.subscribe(from: .prebuffer(.zero), bufferLimit: 10)
        // .zero replays from the newest keyframe at or before now: the whole ring is older than now, so the newest GOP only.
        #expect(subscription.replayCount == 30)
        // The replay fits (replayCount + bufferLimit); 20 more live frames then overflow it.
        for index in 90..<130 { await hub.ingest(Self.frame(index, keyframe: index % 30 == 0)) }
        let read = Self.videoIndices(await Self.drain(subscription))
        #expect(read.first?.index == 60 || read.first?.index == 90, "starts on a keyframe: \(read.first?.index ?? -1)")
        Self.assertEveryGapEndsOnAKeyframe(read)
        #expect(read.count <= 40)
    }

    @Test func aWholeRingReplayIsNotDroppedBeforeTheConsumerRuns() async {
        let hub = MediaHub(retention: .seconds(600))
        for index in 0..<90 { await hub.ingest(Self.frame(index, keyframe: index % 30 == 0)) }
        // A long prebuffer replays every held GOP (90 frames) into a queue limited to 5 live samples + the replay.
        let subscription = await hub.subscribe(from: .prebuffer(.seconds(3_600)), bufferLimit: 5)
        #expect(subscription.replayCount == 90)
        let read = Self.videoIndices(await Self.drain(subscription))
        #expect(read.map(\.index) == Array(0..<90))
    }

    @Test func audioIsDroppedWithTheGOPAndNotQueuedWhileWaitingForAKeyframe() async {
        let hub = MediaHub()
        let subscription = await hub.subscribe(from: .nextKeyframe, bufferLimit: 6)
        await hub.ingest(Self.frame(0, keyframe: true))
        for index in 1...10 {
            await hub.ingest(Self.frame(index, keyframe: false))
            await hub.ingest(Self.audio(index))
        }
        await hub.ingest(Self.frame(11, keyframe: true))
        await hub.ingest(Self.audio(11))
        let read = await Self.drain(subscription)
        let video = Self.videoIndices(read)
        #expect(video.map(\.index) == [11])
        // The audio sample that follows the resumed keyframe is delivered, none from the skipped stretch.
        #expect(read.count == 2)
        if case .audio(let frame) = read.last { #expect(frame.data[1] == 11) } else { Issue.record("expected the audio sample after the keyframe") }
    }

    @Test func anOverflowIsOneWarningNotOnePerFrame() async {
        let sink = WarningSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let clock = Mutex(ContinuousClock.now)
        let base = ContinuousClock.now
        let hub = MediaHub(retention: .seconds(12), now: { clock.withLock { $0 } }, overflowLogInterval: .seconds(10),
                           logCategory: "MediaHubBackpressureTest")
        let subscription = await hub.subscribe(from: .nextKeyframe, bufferLimit: 4)
        // 40 GOPs of 10 frames, 30 fps: each overflows the queue; they span 13 s of the hub's clock.
        for index in 0..<400 {
            clock.withLock { $0 = base + .milliseconds(index * 33) }
            await hub.ingest(Self.frame(index % 250, keyframe: index % 10 == 0))
        }
        subscription.cancel()
        let warnings = sink.entries.withLock { $0.filter { $0.category == "MediaHubBackpressureTest" && $0.level == .warning } }
        #expect(warnings.count >= 1 && warnings.count <= 3, "\(warnings.count) warnings for 13 s of overflow")
        #expect(warnings.first.map { $0.message.contains("dropped") } == true)
    }

    @Test func newestGOPIsTheNewestKeyframeAndTheVideoFramesAfterIt() async {
        let hub = MediaHub()
        let before = (await hub.newestGOP(), await hub.lastVideoArrival)
        #expect(before.0.isEmpty && before.1 == nil)
        await hub.ingest(Self.frame(0, keyframe: false))   // before any keyframe: not held
        for index in 1...4 { await hub.ingest(Self.frame(index, keyframe: index == 1 || index == 3)) }
        await hub.ingest(Self.audio(1))
        await hub.ingest(Self.frame(5, keyframe: false))
        let gop = Self.videoIndices(await hub.newestGOP().map { MediaSample.video($0) })
        #expect(gop.map(\.index) == [3, 4, 5] && gop.first?.key == true, "the newest GOP's video, no audio")
        let arrival = await hub.lastVideoArrival
        #expect(arrival != nil)
        await hub.discontinuity()
        let after = (await hub.newestGOP(), await hub.lastVideoArrival)
        #expect(after.0.isEmpty && after.1 == nil)
    }

    @Test func cancellingTheSubscriptionStillDeliversItsBacklogThenEnds() async {
        let hub = MediaHub()
        let subscription = await hub.subscribe(from: .nextKeyframe, bufferLimit: 8)
        await hub.ingest(Self.frame(0, keyframe: true))
        await hub.ingest(Self.frame(1, keyframe: false))
        subscription.cancel()
        #expect(await hub.subscriberCount == 0)
        await hub.ingest(Self.frame(2, keyframe: false))   // not delivered: the subscriber is gone
        var read: [MediaSample] = []
        for await sample in subscription.samples { read.append(sample) }
        #expect(Self.videoIndices(read).map(\.index) == [0, 1])
    }

    @Test func droppingTheStreamWithoutReadingRemovesTheSubscriber() async {
        let hub = MediaHub()
        do {
            let subscription = await hub.subscribe(from: .live)
            #expect(await hub.subscriberCount == 1)
            _ = subscription.samples   // never iterated; the subscription goes out of scope
        }
        // The stream was released: the queue terminated and left the hub's registry.
        let removed = await eventuallyTrue { await hub.subscriberCount == 0 }
        #expect(removed)
    }

    private func eventuallyTrue(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

/// `GOPQueue` on its own (the hub, the live-view pump and the pipeline's session stream share it).
@Suite(.timeLimit(.minutes(1))) struct GOPQueueTests {
    private struct Unit: Sendable, Equatable {
        var id: Int
        var key: Bool
    }

    private func queue(_ capacity: Int, onTerminate: @escaping @Sendable () -> Void = {}) -> GOPQueue<Unit> {
        GOPQueue(capacity: capacity, isKeyframe: { $0.key }, onTerminate: onTerminate)
    }

    @Test func deliversInOrderAndEndsAfterFinish() async {
        let queue = queue(4)
        let stream = queue.makeStream()
        for id in 0..<3 { #expect(queue.push(Unit(id: id, key: id == 0)).queued) }
        queue.finish()
        var ids: [Int] = []
        for await unit in stream { ids.append(unit.id) }
        #expect(ids == [0, 1, 2])
        #expect(queue.push(Unit(id: 9, key: true)).closed)
    }

    @Test func aWaitingConsumerIsWokenByAPush() async {
        let queue = queue(4)
        let stream = queue.makeStream()
        let consumer = Task { () -> Int? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()?.id
        }
        try? await Task.sleep(for: .milliseconds(50))
        queue.push(Unit(id: 7, key: true))
        #expect(await consumer.value == 7)
    }

    @Test func cancellingTheConsumerTerminatesOnce() async {
        let terminations = Mutex(0)
        let queue = queue(4) { terminations.withLock { $0 += 1 } }
        let stream = queue.makeStream()
        let consumer = Task { for await _ in stream {} }
        try? await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        await consumer.value
        queue.terminate()
        #expect(terminations.withLock { $0 } == 1)
        #expect(queue.push(Unit(id: 1, key: true)).closed)
    }

    @Test func aFullQueueOfOneGOPIsClearedAndRefusesDeltasUntilAKeyframe() {
        let queue = queue(3)
        queue.push(Unit(id: 0, key: true))
        queue.push(Unit(id: 1, key: false))
        queue.push(Unit(id: 2, key: false))
        let refused = queue.push(Unit(id: 3, key: false))
        #expect(refused.dropped == 3 && refused.awaitingKeyframe && !refused.queued)
        let accepted = queue.push(Unit(id: 4, key: true))
        #expect(accepted.queued && !accepted.overflowed)
        #expect(queue.count == 1)
    }
}

private final class WarningSink: LogSink {
    let entries = Mutex<[LogEntry]>([])
    func record(_ entry: LogEntry) {
        entries.withLock { $0.append(entry) }
    }
}
