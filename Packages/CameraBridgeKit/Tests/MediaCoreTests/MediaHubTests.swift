import BridgeSupport
import Foundation
import Synchronization
import Testing
@testable import MediaCore

/// Builds a synthetic camera timeline: video at `fps` with a keyframe every `gop` frames, AAC audio every
/// 1024 samples at 16 kHz, wall clocks relative to `origin`.
private struct Timeline {
    var origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var fps = 30
    var gop = 60
    let video = VideoFormat(codec: .h264, width: 1280, height: 720, parameterSets: [Data([0x67, 1]), Data([0x68, 2])])
    let audio = AudioFormat.aacLC(sampleRate: 16_000, channels: 1)

    func videoFrame(_ index: Int, keyframe: Bool? = nil) -> MediaSample {
        let isKey = keyframe ?? (index % gop == 0)
        return .video(EncodedVideoFrame(format: video, nalUnits: [Data([isKey ? 0x65 : 0x41, UInt8(truncatingIfNeeded: index)])], isKeyframe: isKey,
                                        pts: MediaTime(value: Int64(index * 90_000 / fps), timescale: 90_000),
                                        wallClock: origin.addingTimeInterval(Double(index) / Double(fps))))
    }

    func audioFrame(_ index: Int) -> MediaSample {
        .audio(EncodedAudioFrame(format: audio, data: Data([0x21, UInt8(truncatingIfNeeded: index)]), pts: MediaTime(value: Int64(index * 1024), timescale: 16_000),
                                 sampleCount: 1024, wallClock: origin.addingTimeInterval(Double(index) * 1024 / 16_000)))
    }

    /// Video and audio for [start, end) seconds in wall-clock order.
    func samples(from start: Double = 0, to end: Double) -> [MediaSample] {
        var out: [MediaSample] = []
        var v = Int((start * Double(fps)).rounded(.up))
        var a = Int((start * 16_000 / 1024).rounded(.up))
        while true {
            let vt = Double(v) / Double(fps)
            let at = Double(a) * 1024 / 16_000
            if vt >= end && at >= end { break }
            if vt <= at, vt < end { out.append(videoFrame(v)); v += 1 } else if at < end { out.append(audioFrame(a)); a += 1 } else { out.append(videoFrame(v)); v += 1 }
        }
        return out
    }

    func time(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
}

/// A settable "now" for the hub, in seconds on the local timeline (the default `Timeline` origin is local 0).
private final class TestClock: Sendable {
    /// The local timeline's origin as a date (`Timeline`'s default origin).
    static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let base = ContinuousClock.now
    let seconds: Mutex<Double>
    init(_ seconds: Double = 0) { self.seconds = Mutex(seconds) }
    func set(_ newValue: Double) { seconds.withLock { $0 = newValue } }
    var now: @Sendable () -> ContinuousClock.Instant { { [self] in base + .seconds(seconds.withLock { $0 }) } }
}

/// Ingests `samples` as a live source delivers them: each arrives (on `clock`) at its capture time on the local
/// timeline, i.e. its wall clock minus `cameraClockOffset` (camera clock − local clock), plus `latency`.
private func feed(_ samples: [MediaSample], to hub: MediaHub, clock: TestClock, cameraClockOffset: Double = 0, latency: Double = 0) async {
    for sample in samples {
        clock.set(sample.wallClock.timeIntervalSince(TestClock.origin) - cameraClockOffset + latency)
        await hub.ingest(sample)
    }
}

extension MediaSample {
    fileprivate var isVideoKeyframe: Bool { if case .video(let frame) = self { frame.isKeyframe } else { false } }
    fileprivate var isAudio: Bool { if case .audio = self { true } else { false } }
    fileprivate var tag: String {
        switch self {
        case .video(let frame): "\(frame.isKeyframe ? "K" : "v")\(frame.nalUnits[0][1])"
        case .audio(let frame): "a\(frame.data[1])"
        }
    }
}

/// Collects exactly `count` samples (or fewer if the stream ends).
private func take(_ count: Int, from stream: AsyncStream<MediaSample>) async -> [MediaSample] {
    var out: [MediaSample] = []
    guard count > 0 else { return out }
    for await sample in stream {
        out.append(sample)
        if out.count == count { break }
    }
    return out
}

@Suite(.timeLimit(.minutes(1))) struct MediaHubTests {
    @Test func nextKeyframeWaitsForAKeyframeAndDropsEarlierAudio() async {
        let t = Timeline()
        let hub = MediaHub()
        let subscription = await hub.subscribe(from: .nextKeyframe)
        await hub.ingest(t.videoFrame(1))          // delta before any keyframe
        await hub.ingest(t.audioFrame(0))          // audio before the first delivered keyframe
        await hub.ingest(t.videoFrame(60))         // keyframe
        await hub.ingest(t.audioFrame(1))
        await hub.ingest(t.videoFrame(61))
        let received = await take(3, from: subscription.samples)
        #expect(received.map(\.tag) == ["K60", "a1", "v61"])
        subscription.cancel()
    }

    /// Review finding (W4 round 2): a live view measured the last keyframe's age from its wall clock (for RTSP the
    /// camera's clock). The hub now tells when the keyframe arrived on its own monotonic clock, whatever the frame's
    /// wall clock says, and forgets it at a discontinuity.
    @Test func lastKeyframeArrivalIsOnTheHubsClock() async throws {
        let t = Timeline()
        let clock = TestClock()
        let hub = MediaHub(now: clock.now)
        #expect(await hub.lastKeyframeArrival == nil)
        // The keyframe's wall clock says local 0 (a camera clock 5 s behind ours); it arrives at 5 on the hub's clock.
        clock.set(5)
        await hub.ingest(t.videoFrame(0))
        clock.set(6.5)
        await hub.ingest(t.videoFrame(1))   // a delta frame does not move it
        let latest = try #require(await hub.lastKeyframeArrival)
        #expect(latest.frame.isKeyframe && latest.frame.wallClock == t.time(0))
        #expect(clock.now() - latest.arrival == .seconds(1.5))
        await hub.discontinuity()
        #expect(await hub.lastKeyframeArrival == nil)
    }

    @Test func liveDeliversEverySampleFromNowOn() async {
        let t = Timeline()
        let hub = MediaHub()
        await hub.ingest(t.videoFrame(0))
        let subscription = await hub.subscribe(from: .live)
        await hub.ingest(t.videoFrame(1))
        await hub.ingest(t.audioFrame(0))
        await hub.ingest(t.videoFrame(2))
        #expect(await take(3, from: subscription.samples).map(\.tag) == ["v1", "a0", "v2"])
        subscription.cancel()
    }

    @Test func prebufferStartsAtTheNewestKeyframeAtOrBeforeNowMinusDuration() async {
        let t = Timeline()   // 30 fps, keyframe every 2 s
        let clock = TestClock()
        let hub = MediaHub(retention: .seconds(12), now: clock.now)
        let history = t.samples(to: 12)
        await feed(history, to: hub, clock: clock)
        clock.set(12)

        // now − 4 s = 8 s → the keyframe at exactly 8 s (≤) starts the replay.
        let four = await hub.subscribe(from: .prebuffer(.seconds(4)))
        let expected = history.drop { $0.wallClock < t.time(8) || !$0.isVideoKeyframe }
        let replay = await take(expected.count, from: four.samples)
        #expect(replay.first?.tag == "K240" && replay.first?.wallClock == t.time(8))
        #expect(replay.map(\.tag) == expected.map(\.tag))
        // Then live.
        await hub.ingest(t.videoFrame(360))
        #expect(await take(1, from: four.samples).map(\.tag) == [t.videoFrame(360).tag])
        four.cancel()

        // now − 3 s = 9 s → still the keyframe at 8 s (newest ≤ 9 s).
        let three = await hub.subscribe(from: .prebuffer(.seconds(3)))
        #expect(await take(1, from: three.samples).first?.wallClock == t.time(8))
        three.cancel()

        // Longer than the ring → the oldest keyframe held (0 s).
        let long = await hub.subscribe(from: .prebuffer(.seconds(60)))
        #expect(await take(1, from: long.samples).first?.tag == "K0")
        long.cancel()
    }

    /// Review finding: RTSP wall clocks are the camera's (RTCP sender reports, accepted within 3 s of arrival), so a
    /// camera clock running behind made keyframes look older than they are and shortened the HKSV prebuffer (one
    /// running ahead lengthened it). The replay is measured on the hub's own clock, from when the samples arrived.
    @Test(arguments: [-2.9, -1.0, 0, 2.5]) func prebufferIsMeasuredFromArrivalNotTheCameraClock(cameraClockOffset: Double) async {
        let t = Timeline(origin: TestClock.origin.addingTimeInterval(cameraClockOffset))   // camera clock = local + offset
        let clock = TestClock()
        let hub = MediaHub(retention: .seconds(12), now: clock.now)
        await feed(t.samples(to: 12), to: hub, clock: clock, cameraClockOffset: cameraClockOffset)
        clock.set(12.5)   // away from the keyframes' arrival times (the offset dates are not exact in floating point)
        // now − 4 s = local 8.5 s → the keyframe that arrived at 8 s (frame 240), whatever its wall clock says.
        let subscription = await hub.subscribe(from: .prebuffer(.seconds(4)))
        #expect(await take(1, from: subscription.samples).first?.tag == "K240")
        subscription.cancel()
    }

    /// Samples that arrive now count as new, even with wall clocks seconds in the past: everything held arrived less
    /// than 4 s ago, so a 4 s prebuffer replays from the oldest keyframe; `.zero` from the newest.
    @Test func prebufferUsesTheHubsClockByDefault() async {
        let t = Timeline(origin: Date().addingTimeInterval(-6))   // wall clocks from 6 s ago up to now
        let hub = MediaHub()
        for sample in t.samples(to: 6) { await hub.ingest(sample) }
        let four = await hub.subscribe(from: .prebuffer(.seconds(4)))
        #expect(await take(1, from: four.samples).first?.tag == "K0")
        four.cancel()
        let zero = await hub.subscribe(from: .prebuffer(.zero))
        #expect(await take(1, from: zero.samples).first?.tag == "K120")
        zero.cancel()
    }

    @Test func prebufferOnAnEmptyRingWaitsForTheNextKeyframe() async {
        let t = Timeline()
        let hub = MediaHub(now: TestClock(0).now)
        let subscription = await hub.subscribe(from: .prebuffer(.seconds(4)))
        await hub.ingest(t.audioFrame(0))
        await hub.ingest(t.videoFrame(1))
        await hub.ingest(t.videoFrame(60))
        #expect(await take(1, from: subscription.samples).map(\.tag) == ["K60"])
        subscription.cancel()
    }

    @Test func retentionTrimsWholeGOPsByArrival() async {
        let t = Timeline()
        let clock = TestClock()
        let hub = MediaHub(retention: .seconds(6), now: clock.now)
        await feed(t.samples(to: 20), to: hub, clock: clock)
        // Newest sample arrived at ≈ 19.97 s; the ring keeps whole GOPs covering at least 6 s: GOPs from 12 s (the
        // next GOP, 14 s, arrived after 19.97 − 6 = 13.97 s).
        let subscription = await hub.subscribe(from: .prebuffer(.seconds(100)))
        let first = await take(1, from: subscription.samples).first
        #expect(first?.isVideoKeyframe == true)
        #expect(first?.wallClock == t.time(12))
        subscription.cancel()
        #expect(await hub.lastKeyframe?.pts == MediaTime.seconds(18))
    }

    @Test func slowSubscriberIsBoundedDropsItsGOPAndWarns() async {
        let warnings = WarningSink()
        let token = LogHub.addSink(warnings)
        defer { LogHub.removeSink(token) }
        let t = Timeline()
        let hub = MediaHub()
        let subscription = await hub.subscribe(from: .nextKeyframe, bufferLimit: 10)
        for index in 0..<70 { await hub.ingest(t.videoFrame(index)) }   // K0, 59 deltas, K60, 9 deltas: nobody reads
        // The first GOP overflowed the queue and went whole; the next one (a keyframe first) is what the consumer reads.
        subscription.cancel()
        var received: [MediaSample] = []
        for await sample in subscription.samples { received.append(sample) }
        #expect(received.map(\.tag) == ["K60"] + (61..<70).map { "v\($0)" })
        #expect(warnings.entries.withLock { $0.contains { $0.category == "MediaHub" && $0.level == .warning && $0.message.contains("dropped") } })
    }

    /// A replay longer than `bufferLimit` (a long prebuffer, a high frame rate or a small limit) still arrives whole,
    /// starting on its keyframe: the subscriber's buffer holds the replay plus `bufferLimit` live samples.
    @Test func prebufferLongerThanTheBufferLimitArrivesWhole() async {
        let t = Timeline()   // 30 fps, keyframe every 2 s, AAC at 16 kHz: about 91 samples per GOP
        let clock = TestClock()
        let hub = MediaHub(retention: .seconds(12), now: clock.now)
        let history = t.samples(to: 12)
        await feed(history, to: hub, clock: clock)
        let subscription = await hub.subscribe(from: .prebuffer(.seconds(60)), bufferLimit: 100)
        #expect(history.count > 500)
        let replay = await take(history.count, from: subscription.samples)
        #expect(replay.first?.tag == "K0")
        #expect(replay.map(\.tag) == history.map(\.tag))   // nothing dropped
        // Afterwards the queue stays bounded (replay + bufferLimit samples): a stalled consumer loses whole GOPs and what it
        // reads after the gap is a keyframe.
        for index in 360..<1_400 { await hub.ingest(t.videoFrame(index, keyframe: index % 60 == 0)) }
        subscription.cancel()
        var backlog: [MediaSample] = []
        for await sample in subscription.samples { backlog.append(sample) }
        #expect(backlog.count <= history.count + 100)
        #expect(backlog.first?.isVideoKeyframe == true)
        #expect(backlog.last?.tag == t.videoFrame(1_399, keyframe: false).tag)
    }

    @Test func ringIsCappedAt64MB() async {
        let warnings = WarningSink()
        let token = LogHub.addSink(warnings)
        defer { LogHub.removeSink(token) }
        let t = Timeline()
        let hub = MediaHub(retention: .seconds(12), now: TestClock(4).now)
        let payload = Data(count: 1 << 20)   // one shared 1 MiB buffer: the ring counts it per frame
        for index in 0..<100 {
            let frame = EncodedVideoFrame(format: t.video, nalUnits: [Data([0x65, UInt8(index)]), payload], isKeyframe: true,
                                          pts: MediaTime(value: Int64(index * 3_000), timescale: 90_000), wallClock: t.time(Double(index) / 30))
            await hub.ingest(.video(frame))
        }
        // 3.3 s of 1 MiB keyframes (within retention): only the newest 63 GOPs (63 × (1 MiB + 2 B) ≤ 64 MiB) are kept.
        let subscription = await hub.subscribe(from: .prebuffer(.seconds(60)), bufferLimit: 10)
        let replay = await take(63, from: subscription.samples)
        #expect(replay.first?.tag == "K37" && replay.last?.tag == "K99")
        subscription.cancel()
        #expect(warnings.entries.withLock { $0.contains { $0.category == "MediaHub" && $0.level == .warning && $0.message.contains("exceeded") } })
    }

    @Test func discontinuityClearsTheRingButKeepsSubscribers() async {
        let t = Timeline()
        let hub = MediaHub(now: TestClock(10).now)
        let live = await hub.subscribe(from: .nextKeyframe)
        for sample in t.samples(to: 4) { await hub.ingest(sample) }
        #expect(await hub.lastKeyframe != nil)
        await hub.discontinuity()
        #expect(await hub.subscriberCount == 1)
        #expect(await hub.lastKeyframe == nil)
        #expect(await hub.measuredFrameRate == nil)
        #expect(await hub.measuredGOPDuration == nil)

        // The ring is empty: a prebuffer subscriber waits for the next keyframe.
        let late = await hub.subscribe(from: .prebuffer(.seconds(4)))
        // The existing subscriber also restarts at a keyframe (the reconnected source's timeline is new).
        await hub.ingest(t.audioFrame(500))
        await hub.ingest(t.videoFrame(901))
        await hub.ingest(t.videoFrame(900))
        await hub.ingest(t.audioFrame(501))
        #expect(await take(2, from: late.samples).map(\.tag) == ["K132", "a245"])   // tags are the low byte of the index
        var liveTags = await take(1, from: live.samples).map(\.tag)
        // Drain what the live subscriber got before the discontinuity, then check the restart.
        while liveTags.last != "K132" { liveTags += await take(1, from: live.samples).map(\.tag) }
        #expect(await take(1, from: live.samples).map(\.tag) == ["a245"])
        live.cancel()
        late.cancel()
    }

    /// Review finding: a reconnected source may bring other media (camera audio switched off, a fallback without
    /// audio). Recordings choose their audio track from `audioFormat`, so a format kept from before the reconnect
    /// declared an AAC track that never got a sample instead of silent AAC.
    @Test func discontinuityForgetsTheFormats() async {
        let t = Timeline()
        let hub = MediaHub()
        for sample in t.samples(to: 1) { await hub.ingest(sample) }
        #expect(await hub.videoFormat == t.video)
        #expect(await hub.audioFormat == t.audio)
        await hub.discontinuity()
        #expect(await hub.videoFormat == nil)
        #expect(await hub.audioFormat == nil)
        // The reconnected source sends video only.
        for index in 0..<31 { await hub.ingest(t.videoFrame(index)) }
        #expect(await hub.videoFormat == t.video)
        #expect(await hub.audioFormat == nil)
    }

    @Test func measuresFrameRateAndGOPDuration() async throws {
        let t = Timeline(fps: 25, gop: 50)
        let hub = MediaHub()
        #expect(await hub.measuredFrameRate == nil)
        #expect(await hub.measuredGOPDuration == nil)
        for sample in t.samples(to: 9) { await hub.ingest(sample) }
        let fps = try #require(await hub.measuredFrameRate)
        #expect(abs(fps - 25) < 0.01)
        let gop = try #require(await hub.measuredGOPDuration)
        #expect(abs(gop / .seconds(1) - 2) < 0.001)
    }

    /// Review finding (B-frames): presentation times step back in decode order, which restarted the measurement window at
    /// every B-frame (a 25 fps camera measured at a third to a half of that, and the transcoder decimated to it). The
    /// frame rate is measured on decode times.
    @Test func measuresTheFrameRateOfAReorderedStreamOnDecodeTimes() async throws {
        let hub = MediaHub()
        let format = VideoFormat(codec: .h264, width: 1280, height: 720, parameterSets: [Data([0x67, 1]), Data([0x68, 2])])
        // VideoToolbox's B-pyramid in decode order: I0 P4 B2 b1 b3 P8 B6 b5 b7 …, decoded two frames ahead.
        let groups: [Int] = (1..<40).flatMap { (group: Int) -> [Int] in [4 * group + 4, 4 * group + 2, 4 * group + 1, 4 * group + 3] }
        let display: [Int] = [0, 4, 2, 1, 3] + groups
        let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for (index, number) in display.enumerated() {
            let pts = MediaTime(value: Int64(number * 3_600), timescale: 90_000)
            let dts = MediaTime(value: Int64((index - 2) * 3_600), timescale: 90_000)
            await hub.ingest(.video(EncodedVideoFrame(format: format, nalUnits: [Data([index == 0 ? 0x65 : 0x41, 0])], isKeyframe: index == 0, pts: pts,
                                                      dts: dts == pts ? nil : dts, wallClock: origin.addingTimeInterval(Double(index) / 25))))
        }
        let fps = try #require(await hub.measuredFrameRate)
        #expect(abs(fps - 25) < 0.01, "measured \(fps) fps")
    }

    @Test func tracksFormatsAndTheLastKeyframe() async {
        let t = Timeline()
        let hub = MediaHub()
        #expect(await hub.videoFormat == nil)
        #expect(await hub.audioFormat == nil)
        #expect(await hub.lastKeyframe == nil)
        await hub.ingest(t.videoFrame(0))
        await hub.ingest(t.audioFrame(0))
        await hub.ingest(t.videoFrame(1))
        #expect(await hub.videoFormat == t.video)
        #expect(await hub.audioFormat == t.audio)
        #expect(await hub.lastKeyframe?.nalUnits == [Data([0x65, 0])])
        await hub.ingest(t.videoFrame(60))
        #expect(await hub.lastKeyframe?.pts == MediaTime.seconds(2))
    }

    @Test func cancelRemovesTheSubscriberAndFinishesItsStream() async {
        let hub = MediaHub()
        let first = await hub.subscribe(from: .live)
        let second = await hub.subscribe(from: .nextKeyframe)
        #expect(await hub.subscriberCount == 2)
        first.cancel()
        #expect(await hub.subscriberCount == 1)
        var iterator = first.samples.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        second.cancel()
        #expect(await hub.subscriberCount == 0)
    }

    @Test func droppingTheConsumerTaskRemovesTheSubscriber() async {
        let t = Timeline()
        let hub = MediaHub()
        let subscription = await hub.subscribe(from: .live)
        let consumer = Task { for await _ in subscription.samples {} }
        await hub.ingest(t.videoFrame(0))
        consumer.cancel()
        await consumer.value
        #expect(await hub.subscriberCount == 0)
    }

    @Test func fansOutToEverySubscriber() async {
        let t = Timeline()
        let hub = MediaHub()
        let subscriptions = await [hub.subscribe(from: .nextKeyframe), hub.subscribe(from: .live), hub.subscribe(from: .prebuffer(.zero))]
        for index in 0..<5 { await hub.ingest(t.videoFrame(index)) }
        for subscription in subscriptions {
            #expect(await take(5, from: subscription.samples).map(\.tag) == ["K0", "v1", "v2", "v3", "v4"])
            subscription.cancel()
        }
    }
}

private final class WarningSink: LogSink {
    let entries = Mutex<[LogEntry]>([])
    func record(_ entry: LogEntry) {
        entries.withLock { $0.append(entry) }
    }
}
