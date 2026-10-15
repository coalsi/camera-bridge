import BridgeEngine
import FMP4
import Foundation
import MediaCore
import Synchronization

// The fakes of the NVR playback tests (Mac spec 15): a sink that records what it is given, an archive made of a described timeline and a clock the
// test moves by hand. `NVRFrameFakes.swift` has the frame source that makes frames from that timeline.

// MARK: Virtual time

/// The `now` and `sleep` of a cell, on a clock the test moves. A sleeper wakes when `advance` passes its time; a cancelled sleeper throws, also one
/// that was cancelled before it got as far as sleeping (as `Task.sleep` does: the cancellation is remembered under the lock the registration takes).
nonisolated final class VirtualTime: Sendable {
    private struct Sleeper {
        var id: Int
        var until: TimeInterval
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: TimeInterval
        var nextID = 0
        var sleepers: [Sleeper] = []
        /// Sleepers whose task was cancelled before they were registered.
        var cancelledEarly: Set<Int> = []
    }

    private enum Registration { case resumeNow, cancelled, waiting }

    private let state: Mutex<State>

    init(start: TimeInterval = 1_000) { state = Mutex(State(now: start)) }

    var now: TimeInterval { state.withLock { $0.now } }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }
    var nextWake: TimeInterval? { state.withLock { $0.sleepers.map(\.until).min() } }

    /// Suspends until the clock reaches `until`; returns at once when it has.
    func sleep(until: TimeInterval) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let registration = state.withLock { state -> Registration in
                    if state.cancelledEarly.remove(id) != nil { return .cancelled }
                    if state.now >= until { return .resumeNow }
                    state.sleepers.append(Sleeper(id: id, until: until, continuation: continuation))
                    return .waiting
                }
                switch registration {
                case .resumeNow: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .waiting: break
                }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelledEarly.insert(id)   // not registered yet: the registration will see this
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock and wakes the sleepers whose time has come, earliest first.
    func advance(by seconds: TimeInterval) {
        let target = state.withLock { $0.now + seconds }
        advance(to: target)
    }

    func advance(to target: TimeInterval) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = max(state.now, target)
            let due = state.sleepers.filter { $0.until <= state.now }.sorted { $0.until < $1.until }
            state.sleepers.removeAll { $0.until <= state.now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

// MARK: The sink

/// Records everything a cell gives its renderer, in order, with the virtual time of each call.
nonisolated final class FakeArchiveSink: ArchiveVideoSink {
    struct Show: Equatable {
        var pts: Int64
        var isKeyframe: Bool
        var decodeOnly: Bool
        var uptime: TimeInterval
        /// The frame's place on the wall clock.
        var date: Date { Date(timeIntervalSinceReferenceDate: Double(pts) / 90_000) }
    }

    enum Event: Equatable {
        case show(Show)
        case play(date: Date, uptime: TimeInterval)
        case reset
        case clear
        case silence
    }

    private struct State {
        var events: [Event] = []
        var queued = 0
        var peakQueued = 0
        var restarts = 0
        /// Frames the renderer takes off the queue per `drain`.
        var autoQueue = false
    }

    private let state = Mutex(State())
    private let uptime: @Sendable () -> TimeInterval

    init(uptime: @escaping @Sendable () -> TimeInterval = { 0 }) { self.uptime = uptime }

    var events: [Event] { state.withLock { $0.events } }
    var shows: [Show] { events.compactMap { if case .show(let show) = $0 { show } else { nil } } }
    var displayed: [Show] { shows.filter { !$0.decodeOnly } }
    var resets: Int { events.filter { $0 == .reset }.count }
    var clears: Int { events.filter { $0 == .clear }.count }
    var plays: [(date: Date, uptime: TimeInterval)] { events.compactMap { if case .play(let date, let uptime) = $0 { (date, uptime) } else { nil } } }
    var peakQueued: Int { state.withLock { $0.peakQueued } }

    /// The queue grows with every `show` until `drain` (a renderer that is behind).
    func queueFrames(_ on: Bool) { state.withLock { $0.autoQueue = on } }
    func drain(_ count: Int) { state.withLock { $0.queued = max(0, $0.queued - count) } }
    func setQueued(_ value: Int) { state.withLock { $0.queued = value } }
    func setRestarts(_ value: Int) { state.withLock { $0.restarts = value } }

    var queued: Int { state.withLock { $0.queued } }
    var restarts: Int { state.withLock { $0.restarts } }

    func show(_ frame: EncodedVideoFrame) { show(frame, decodeOnly: false) }

    func show(_ frame: EncodedVideoFrame, decodeOnly: Bool) {
        let entry = Show(pts: frame.pts.converted(to: 90_000).value, isKeyframe: frame.isKeyframe, decodeOnly: decodeOnly, uptime: uptime())
        state.withLock { state in
            state.events.append(.show(entry))
            if state.autoQueue {
                state.queued += 1
                state.peakQueued = max(state.peakQueued, state.queued)
            }
        }
    }

    func play(_ frame: EncodedAudioFrame) {
        let now = uptime()
        state.withLock { $0.events.append(.play(date: frame.wallClock, uptime: now)) }
    }
    func reset() { state.withLock { $0.events.append(.reset) } }
    func silence() { state.withLock { $0.events.append(.silence) } }
    func clear() { state.withLock { $0.events.append(.clear) } }
}

// MARK: The recorded timeline

/// Fragments of one camera as the archive would list them: files that each begin with a keyframe, `gopFragments` fragments to a GOP, with gaps between files.
nonisolated struct FakeTimeline: Sendable {
    struct Run: Sendable {
        var start: Date
        var fragments: Int
        var gopFragments = 1
        var fragmentDuration: TimeInterval = 2
    }

    let camera: UUID
    private(set) var fragments: [ArchiveFragment] = []

    /// 2026-10-10 12:00:00 local-ish: a fixed instant all the tests count from.
    static let origin = Date(timeIntervalSinceReferenceDate: 813_000_000)

    init(camera: UUID, runs: [Run]) {
        self.camera = camera
        for (file, run) in runs.enumerated() {
            let segment = "\(camera.uuidString)/2026-10-10/\(String(format: "%02d", file))-00-00"
            var mediaStart: Int64 = 0
            for index in 0..<run.fragments {
                let back = index % run.gopFragments
                let start = run.start.addingTimeInterval(Double(index) * run.fragmentDuration)
                fragments.append(ArchiveFragment(camera: camera, segment: segment, index: index, start: start, duration: run.fragmentDuration, mediaStart: mediaStart,
                                                 hasKeyframe: back == 0, gopStart: start.addingTimeInterval(-Double(back) * run.fragmentDuration),
                                                 backToKey: back, byteLength: 1_000))
                mediaStart += Int64(run.fragmentDuration * 90_000)
            }
        }
    }

    init(camera: UUID = UUID(), start: Date = FakeTimeline.origin, fragments: Int, gopFragments: Int = 1, fragmentDuration: TimeInterval = 2) {
        self.init(camera: camera, runs: [Run(start: start, fragments: fragments, gopFragments: gopFragments, fragmentDuration: fragmentDuration)])
    }

    var start: Date { fragments.first?.start ?? Self.origin }
    var end: Date { fragments.last?.end ?? Self.origin }
    func fragment(at offset: TimeInterval) -> ArchiveFragment? { fragments.first { $0.start <= start.addingTimeInterval(offset) && start.addingTimeInterval(offset) < $0.end } }
}

nonisolated final class FakeArchiveReader: ArchiveReading {
    private struct State {
        var fragments: [ArchiveFragment]
        var isReady = true
        /// The drive is away: the real archive answers nothing to every lookup (`extent`, `fragment`) while its folder is gone.
        var unreachable = false
        var catalogVersion = 1
        var activityCalls = 0
        var lookups = 0
    }

    private let state: Mutex<State>
    private let activityHandler: Mutex<@Sendable (UUID, Range<Date>, Int) async -> ArchiveActivity>

    init(_ timelines: [FakeTimeline]) {
        state = Mutex(State(fragments: timelines.flatMap(\.fragments).sorted { $0.start < $1.start }))
        activityHandler = Mutex({ _, range, count in
            ArchiveActivity(start: range.lowerBound, binDuration: range.upperBound.timeIntervalSince(range.lowerBound) / Double(max(count, 1)),
                            bins: Array(repeating: .init(coverage: 1, level: 100, peak: 200), count: count), typical: 100, isComplete: true)
        })
    }

    convenience init(_ timeline: FakeTimeline) { self.init([timeline]) }

    var lookups: Int { state.withLock { $0.lookups } }
    var activityCalls: Int { state.withLock { $0.activityCalls } }
    func setReady(_ ready: Bool) { state.withLock { $0.isReady = ready } }
    func setUnreachable(_ unreachable: Bool) { state.withLock { $0.unreachable = unreachable } }
    func setCatalogVersion(_ version: Int) { state.withLock { $0.catalogVersion = version } }
    func setActivity(_ handler: @escaping @Sendable (UUID, Range<Date>, Int) async -> ArchiveActivity) { activityHandler.withLock { $0 = handler } }

    var isReady: Bool { state.withLock { $0.isReady } }
    var catalogVersion: Int { state.withLock { $0.catalogVersion } }

    func activity(camera: UUID, range: Range<Date>, binCount: Int) async -> ArchiveActivity {
        state.withLock { $0.activityCalls += 1 }
        let handler = activityHandler.withLock { $0 }
        return await handler(camera, range, binCount)
    }

    func fragment(camera: UUID, containing time: Date) async -> ArchiveFragment? {
        state.withLock { state in
            state.lookups += 1
            guard state.isReady, !state.unreachable else { return nil }
            return state.fragments.last { $0.camera == camera && $0.start <= time && time < $0.end }
        }
    }

    func fragment(camera: UUID, startingAfter time: Date) async -> ArchiveFragment? {
        state.withLock { state in
            state.lookups += 1
            guard state.isReady, !state.unreachable else { return nil }
            return state.fragments.first { $0.camera == camera && $0.start > time }
        }
    }

    func fragment(camera: UUID, id: String) async -> ArchiveFragment? {
        state.withLock { state in
            state.lookups += 1
            guard state.isReady, !state.unreachable else { return nil }
            return state.fragments.first { $0.camera == camera && $0.id == id }
        }
    }

    func read(_ fragment: ArchiveFragment, _ part: ArchiveReadPart) async throws -> Data {
        throw ArchiveError.unreadable("The fake archive has no bytes; tests use FakeFrameSource.")
    }

    func extent(camera: UUID) -> ArchiveExtent? {
        state.withLock { state in
            guard !state.unreachable else { return nil }
            let mine = state.fragments.filter { $0.camera == camera }
            guard let first = mine.first, let last = mine.last else { return nil }
            return ArchiveExtent(oldest: first.start, newest: last.end)
        }
    }
}
