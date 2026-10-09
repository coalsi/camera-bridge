import BridgeSupport
import Foundation
import Synchronization

public enum SubscriptionStart: Sendable {
    /// Every sample from now on, as it arrives (delta frames and audio included).
    case live
    /// Waits for the next keyframe; samples before it (audio included) are not delivered.
    case nextKeyframe
    /// Replays the ring from the newest keyframe that arrived at least `duration` ago (or the oldest keyframe held),
    /// then continues live. With an empty ring it behaves like `.nextKeyframe`.
    case prebuffer(Duration)
}

public struct MediaSubscription: Sendable {
    public let samples: AsyncStream<MediaSample>
    public let cancel: @Sendable () -> Void
    /// How many of the first `samples` are the replay of the ring (`.prebuffer`), queued before the subscription
    /// returned; everything after them is live. 0 for `.live` and `.nextKeyframe`.
    public let replayCount: Int

    public init(samples: AsyncStream<MediaSample>, cancel: @escaping @Sendable () -> Void, replayCount: Int = 0) {
        self.samples = samples
        self.cancel = cancel
        self.replayCount = replayCount
    }
}

/// Per-camera fan-out with a GOP ring for prebuffering.
///
/// The ring holds whole GOPs (a keyframe plus every later sample until the next keyframe, in arrival order) and
/// keeps the oldest GOP only while the next one arrived after `newest arrival − retention`, so it always covers at
/// least `retention` once that much has arrived, and always starts on a keyframe. Samples before the first keyframe
/// are not retained. A hard cap of `maximumRingBytes` drops the oldest GOPs (even the current one) if a camera's GOP
/// is pathologically long.
///
/// Ring trimming and `.prebuffer` measure time on the hub's own monotonic clock, from when each keyframe arrived, never
/// from the samples' `wallClock`: RTSP wall clocks are the camera's clock (RTCP sender reports, accepted within 3 s of
/// arrival), and a camera clock running behind would make keyframes look older than they are and shorten the prebuffer.
///
/// Each subscriber has its own bounded queue (`bufferLimit` samples) that overflows by whole GOPs (`GOPQueue`): a
/// consumer that falls behind loses its oldest GOP, or what it has queued when that is one GOP, and the next sample it
/// meets after the gap is a keyframe; deltas are skipped until the next keyframe when nothing was left to resume from.
/// An overflow is logged as one warning (at most one per `overflowLogInterval` per subscriber). A `.prebuffer`
/// subscriber's queue also holds its replay (`bufferLimit` + the replay's sample count), because the replay is queued
/// before the consumer runs: a replay longer than `bufferLimit` (long prebuffer, high frame rate, small limit) would
/// otherwise overflow with its own starting keyframe.
/// Cancelling a subscription, finishing its consumer task or dropping the stream removes the subscriber immediately.
public actor MediaHub {
    /// Upper bound on the bytes held by the ring (about 30 s of 16 Mbps video).
    static let maximumRingBytes = 64 << 20

    private struct GOP {
        /// When the keyframe arrived, on the hub's clock.
        let arrival: ContinuousClock.Instant
        var samples: [MediaSample]
        var byteCount: Int
    }

    private let retention: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let wallNow: @Sendable () -> Date
    private let offsetTracker = WallClockOffsetTracker()
    private let log: Log
    private let subscribers = SubscriberRegistry()

    private var ring: [GOP] = []
    private var ringBytes = 0
    private var newestArrival: ContinuousClock.Instant?
    private var nextSubscriberID: UInt64 = 0
    private var capWarningLogged = false
    /// At most one overflow warning per subscriber in this time.
    private let overflowLogInterval: Duration

    private var latestVideoFormat: VideoFormat?
    private var latestAudioFormat: AudioFormat?
    private var latestKeyframe: EncodedVideoFrame?
    private var latestVideoArrival: ContinuousClock.Instant?
    /// When `latestKeyframe` arrived, on the hub's clock.
    private var latestKeyframeArrival: ContinuousClock.Instant?
    /// Presentation times (seconds) of the most recent video frames / keyframes, strictly increasing.
    private var recentVideoTimes: [Double] = []
    private var recentKeyframeTimes: [Double] = []

    public init(retention: Duration = .seconds(12)) {
        self.init(retention: retention, now: { ContinuousClock.now })
    }

    /// `now` is the clock that stamps arrivals for trimming and `.prebuffer` (tests).
    init(retention: Duration = .seconds(12), now: @escaping @Sendable () -> ContinuousClock.Instant,
         wallNow: @escaping @Sendable () -> Date = { Date() }, overflowLogInterval: Duration = .seconds(10),
         logCategory: String = "MediaHub") {
        self.retention = retention
        self.now = now
        self.wallNow = wallNow
        self.overflowLogInterval = overflowLogInterval
        log = Log(category: logCategory)
    }

    public func ingest(_ sample: MediaSample) {
        let arrival = now()
        if case .video(let frame) = sample { offsetTracker.record(lag: wallNow().timeIntervalSince(frame.wallClock)) }
        record(sample, arrival: arrival)
        retain(sample, arrival: arrival)
        deliver(sample)
    }

    /// .prebuffer(d): starts at the newest keyframe that arrived at least d ago (or the oldest keyframe held), then live.
    /// The subscriber's queue holds `bufferLimit` samples plus the replay (see the type's documentation).
    public func subscribe(from start: SubscriptionStart = .nextKeyframe, bufferLimit: Int = 900) -> MediaSubscription {
        var replay: ArraySlice<GOP> = []
        if case .prebuffer(let duration) = start, let first = replayStart(before: duration) { replay = ring[first...] }
        let replayCount = replay.reduce(0) { $0 + $1.samples.count }
        let capacity = max(1, bufferLimit) + replayCount
        let id = nextSubscriberID
        nextSubscriberID += 1
        let registry = subscribers
        let queue = GOPQueue<MediaSample>(capacity: capacity, isKeyframe: { $0.isKeyframeSample }, onTerminate: { registry.remove(id) })
        var subscriber = Subscriber(queue: queue, state: .awaitingKeyframe)
        switch start {
        case .live:
            subscriber.state = .live
        case .nextKeyframe:
            break
        case .prebuffer:
            if !replay.isEmpty {
                subscriber.state = .started
                for gop in replay {
                    for sample in gop.samples { yield(sample, to: &subscriber, id: id) }
                }
            }
        }
        registry.insert(subscriber, id: id)
        return MediaSubscription(samples: queue.makeStream(), cancel: { queue.finish(); registry.remove(id) }, replayCount: replayCount)
    }

    public var videoFormat: VideoFormat? { latestVideoFormat }
    public var audioFormat: AudioFormat? { latestAudioFormat }
    public var lastKeyframe: EncodedVideoFrame? { latestKeyframe }

    /// When the newest video frame arrived on the hub's monotonic clock (`ContinuousClock` outside tests); nil before the first
    /// one and after a `discontinuity()` until the reconnected source delivers. The health check of a live stream asks it:
    /// a source that delivers has frames arriving within a second or two.
    public var lastVideoArrival: ContinuousClock.Instant? { latestVideoArrival }

    /// The video frames of the newest GOP held, in arrival order: the newest keyframe and every video frame after it (a
    /// snapshot decodes forward through them to the newest picture, a rebuilt live view replays them). Empty before the first
    /// keyframe and after a `discontinuity()` until the reconnected source delivers one.
    public func newestGOP() -> [EncodedVideoFrame] {
        guard let gop = ring.last else { return [] }
        return gop.samples.compactMap { sample in
            if case .video(let frame) = sample { frame } else { nil }
        }
    }

    /// `lastKeyframe` with the moment it arrived on the hub's monotonic clock (`ContinuousClock` outside tests). Its age
    /// is `ContinuousClock.now - arrival`; the frame's `wallClock` may be the camera's clock (RTSP sender reports), which
    /// can run seconds off the Mac's.
    public var lastKeyframeArrival: (frame: EncodedVideoFrame, arrival: ContinuousClock.Instant)? {
        guard let latestKeyframe, let latestKeyframeArrival else { return nil }
        return (latestKeyframe, latestKeyframeArrival)
    }

    /// What to add to a video frame's `wallClock` to get the Mac's clock at its capture: the smallest (arrival − `wallClock`)
    /// of the recent frames, which is the camera clock's error (RTSP sender reports map to the camera's clock when it is
    /// within 3 s of the Mac's) plus the shortest network delay seen. 0 for a source whose `wallClock` is the Mac's arrival
    /// time, and until frames arrived. Readable from any thread (the overlay's clock asks for it at every picture).
    public nonisolated var wallClockOffset: TimeInterval { offsetTracker.offset }

    /// Frames per second over the most recent (up to 90) video decode times (`dts ?? pts`).
    public var measuredFrameRate: Double? {
        guard recentVideoTimes.count >= 2, let first = recentVideoTimes.first, let last = recentVideoTimes.last, last > first else { return nil }
        return Double(recentVideoTimes.count - 1) / (last - first)
    }

    /// Mean keyframe spacing over the most recent (up to 4) keyframes' presentation times.
    public var measuredGOPDuration: Duration? {
        guard recentKeyframeTimes.count >= 2, let first = recentKeyframeTimes.first, let last = recentKeyframeTimes.last, last > first else { return nil }
        return .seconds((last - first) / Double(recentKeyframeTimes.count - 1))
    }

    /// Source reconnected: clears the ring, the formats, the last keyframe and the measurements, keeps subscribers.
    /// Subscribers that started at a keyframe wait for the next one again (`.live` subscribers are unaffected). The
    /// formats are those of the reconnected source once it delivers: one without audio leaves `audioFormat` nil (a
    /// recording then records silence instead of declaring an audio track that never gets a sample).
    public func discontinuity() {
        ring.removeAll()
        ringBytes = 0
        newestArrival = nil
        latestVideoFormat = nil
        latestAudioFormat = nil
        latestKeyframe = nil
        latestKeyframeArrival = nil
        latestVideoArrival = nil
        recentVideoTimes.removeAll()
        recentKeyframeTimes.removeAll()
        offsetTracker.restart()
        subscribers.restartAtNextKeyframe()
    }

    public var subscriberCount: Int { subscribers.count }

    // MARK: - Ring

    private func record(_ sample: MediaSample, arrival: ContinuousClock.Instant) {
        switch sample {
        case .video(let frame):
            latestVideoFormat = frame.format
            latestVideoArrival = arrival
            // Decode times: presentation times of B-frames step back, which would restart the window at every one.
            Self.append((frame.dts ?? frame.pts).seconds, to: &recentVideoTimes, keeping: 90)
            if frame.isKeyframe {
                latestKeyframe = frame
                latestKeyframeArrival = arrival
                Self.append(frame.pts.seconds, to: &recentKeyframeTimes, keeping: 4)
            }
        case .audio(let frame):
            latestAudioFormat = frame.format
        }
    }

    /// Keeps a strictly increasing window; a timestamp that does not increase (new timeline) restarts it.
    private static func append(_ time: Double, to times: inout [Double], keeping limit: Int) {
        if let last = times.last, time <= last { times.removeAll() }
        times.append(time)
        if times.count > limit { times.removeFirst(times.count - limit) }
    }

    private func retain(_ sample: MediaSample, arrival: ContinuousClock.Instant) {
        let size = Self.byteCount(of: sample)
        if case .video(let frame) = sample, frame.isKeyframe {
            ring.append(GOP(arrival: arrival, samples: [sample], byteCount: size))
        } else if !ring.isEmpty {
            ring[ring.count - 1].samples.append(sample)
            ring[ring.count - 1].byteCount += size
        } else {
            return   // nothing before the first keyframe is retained
        }
        ringBytes += size
        newestArrival = max(newestArrival ?? arrival, arrival)
        trim()
    }

    private func trim() {
        if let newest = newestArrival {
            while ring.count > 1, newest - ring[1].arrival >= retention { dropOldestGOP() }
        }
        if ringBytes > Self.maximumRingBytes {
            if !capWarningLogged {
                capWarningLogged = true
                log.warning("GOP ring exceeded \(Self.maximumRingBytes >> 20) MB; dropping old GOPs (camera keyframe interval too long?)")
            }
            while ringBytes > Self.maximumRingBytes, !ring.isEmpty { dropOldestGOP() }
        }
    }

    private func dropOldestGOP() {
        ringBytes -= ring.removeFirst().byteCount
    }

    private static func byteCount(of sample: MediaSample) -> Int {
        switch sample {
        case .video(let frame): frame.nalUnits.reduce(0) { $0 + $1.count }
        case .audio(let frame): frame.data.count
        }
    }

    /// Index of the newest GOP whose keyframe arrived at least `duration` ago, else the oldest; nil if the ring is empty.
    private func replayStart(before duration: Duration) -> Int? {
        guard !ring.isEmpty else { return nil }
        let current = now()
        return ring.lastIndex { current - $0.arrival >= duration } ?? 0
    }

    // MARK: - Fan-out

    private func deliver(_ sample: MediaSample) {
        let isKeyframe: Bool
        if case .video(let frame) = sample { isKeyframe = frame.isKeyframe } else { isKeyframe = false }
        for (id, original) in subscribers.snapshot() {
            var subscriber = original
            if subscriber.state == .awaitingKeyframe {
                guard isKeyframe else { continue }
                subscriber.state = .started
            }
            yield(sample, to: &subscriber, id: id)
            if subscriber != original { subscribers.update(subscriber, id: id) }
        }
    }

    private func yield(_ sample: MediaSample, to subscriber: inout Subscriber, id: UInt64) {
        let push = subscriber.queue.push(sample)
        guard push.overflowed else { return }
        subscriber.dropped += push.dropped
        if push.awaitingKeyframe { subscriber.state = .awaitingKeyframe }
        let current = now()
        if let last = subscriber.lastOverflowLog, current - last < overflowLogInterval {
            subscriber.suppressedOverflows += 1
            return
        }
        subscriber.lastOverflowLog = current
        let more = subscriber.suppressedOverflows > 0 ? " (\(subscriber.suppressedOverflows) more overflows since the last warning)" : ""
        subscriber.suppressedOverflows = 0
        log.warning("subscriber \(id) is not keeping up: dropped \(push.dropped) queued samples (the oldest GOP); "
                    + (push.awaitingKeyframe ? "resuming at the next keyframe" : "the next sample it reads is a keyframe") + more)
    }
}

extension MediaSample {
    /// A video keyframe (audio and delta frames are not).
    public var isKeyframeSample: Bool {
        if case .video(let frame) = self { frame.isKeyframe } else { false }
    }
}

private struct Subscriber: Sendable, Equatable {
    enum State: Sendable { case live, awaitingKeyframe, started }

    let queue: GOPQueue<MediaSample>
    var state: State
    var dropped = 0
    /// When the overflow warning was last logged (hub clock), and the overflows since that were not logged.
    var lastOverflowLog: ContinuousClock.Instant?
    var suppressedOverflows = 0

    static func == (lhs: Subscriber, rhs: Subscriber) -> Bool {
        lhs.state == rhs.state && lhs.dropped == rhs.dropped && lhs.lastOverflowLog == rhs.lastOverflowLog
            && lhs.suppressedOverflows == rhs.suppressedOverflows
    }
}

/// Subscribers, shared with each continuation's termination handler so cancellation removes them synchronously.
/// Queues are only pushed to outside the lock (terminating one runs its termination handler, which locks).
private final class SubscriberRegistry: Sendable {
    private let entries = Mutex<[UInt64: Subscriber]>([:])

    var count: Int { entries.withLock { $0.count } }

    func insert(_ subscriber: Subscriber, id: UInt64) { entries.withLock { $0[id] = subscriber } }

    func remove(_ id: UInt64) { _ = entries.withLock { $0.removeValue(forKey: id) } }

    /// Subscribers in subscription order.
    func snapshot() -> [(UInt64, Subscriber)] {
        entries.withLock { entries in entries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
    }

    /// Stores `subscriber` if it is still registered (it may have been cancelled meanwhile).
    func update(_ subscriber: Subscriber, id: UInt64) {
        entries.withLock { entries in
            if entries[id] != nil { entries[id] = subscriber }
        }
    }

    func restartAtNextKeyframe() {
        entries.withLock { entries in
            for (id, subscriber) in entries where subscriber.state == .started { entries[id]?.state = .awaitingKeyframe }
        }
    }
}

/// The smallest recent (arrival − `wallClock`) of a hub's video frames (`MediaHub.wallClockOffset`).
private final class WallClockOffsetTracker: Sendable {
    /// Frames the minimum is taken over (3 s at 30 fps).
    static let window = 90
    /// A frame whose `wallClock` is further than this from its arrival carries no usable time (synthetic or broken).
    static let usable: TimeInterval = 86_400

    private struct State {
        var lags: [TimeInterval] = []
        var offset: TimeInterval = 0
    }

    private let state = Mutex(State())

    var offset: TimeInterval { state.withLock { $0.offset } }

    func record(lag: TimeInterval) {
        guard lag.isFinite, lag.magnitude < Self.usable else { return }
        state.withLock { state in
            state.lags.append(lag)
            if state.lags.count > Self.window { state.lags.removeFirst(state.lags.count - Self.window) }
            state.offset = state.lags.min() ?? 0
        }
    }

    /// Source reconnected: the next frames decide again (the last offset stays until they arrive).
    func restart() {
        state.withLock { $0.lags.removeAll() }
    }
}
