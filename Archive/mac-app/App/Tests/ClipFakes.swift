import BridgeEngine
import Foundation
import Synchronization

// The doubles of the clip tests: a value that can be read from any task, a clock the test moves, a point where a fake waits for the test, the
// engine's exporter and the person at the Save panel.

/// A value several tasks read and write.
nonisolated final class Guarded<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result { storage.withLock { body(&$0) } }
}

/// The `now` of the model under test. Each reading moves it on by `step` (0: it stands still until `advance`).
nonisolated final class ManualClock: Sendable {
    private let time: Mutex<Date>
    private let step: TimeInterval

    init(step: TimeInterval = 0, start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        time = Mutex(start)
        self.step = step
    }

    func now() -> Date {
        time.withLock { time in
            defer { time = time.addingTimeInterval(step) }
            return time
        }
    }

    func advance(by seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// A point where a fake waits for the test: `wait()` suspends until `open()`. Once opened it stays open. Unlike `Gate` it can be used from any task.
nonisolated final class Latch: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state -> Bool in
                if !state.isOpen { state.waiters.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let waiting = state.waiters
            state.waiters = []
            return waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// Stops a fake at its checkpoints one by one: the fake calls `arrive()` at each, and the test lets it through with `release()` once it has looked at
/// the model. A cancelled task leaves `arrive()` with `CancellationError`, so a held export can be cancelled; one that nobody lets through gives up after
/// 30 seconds, so a test that went wrong fails instead of waiting for ever.
nonisolated final class Turnstile: Sendable {
    struct GaveUp: Error {}

    private let counts = Mutex((reached: 0, allowed: 0))

    /// How many times the fake has arrived.
    var reached: Int { counts.withLock { $0.reached } }

    func arrive() async throws {
        let number = counts.withLock { counts -> Int in
            counts.reached += 1
            return counts.reached
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while counts.withLock({ $0.allowed }) < number {
            guard ContinuousClock.now < deadline else { throw GaveUp() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Lets one arrival through (the one that is waiting, or the next).
    func release() { counts.withLock { $0.allowed += 1 } }

    /// Lets every arrival through from now on.
    func releaseAll() { counts.withLock { $0.allowed = .max } }
}

/// The engine's `ClipExporting` as a test double: it plans from a table and writes recognizable bytes through the sink it is given, in chunks, and
/// the test can make it wait, fail or report odd progress at any chunk. Like the engine it stops with `ClipError.cancelled` when its task is cancelled.
nonisolated final class FakeClipExporter: ClipExporting {
    /// What one camera has recorded in the range the test asks about.
    struct Footage: Sendable {
        struct Part: Sendable {
            var bytes: Int64
            /// How far before the chosen start the part's first picture is.
            var leadIn: TimeInterval = 0
        }

        var parts: [Part]
        var gaps: [ClipGap] = []
        var soundOmitted = false
        /// File names to put in the plan instead of the engine's (a hostile engine, a collision); one per part.
        var fileNames: [String]?

        static func bytes(_ bytes: Int64, leadIn: TimeInterval = 0) -> Footage { Footage(parts: [Part(bytes: bytes, leadIn: leadIn)]) }
    }

    /// Where the exporter is when `afterChunk` is called: chunk `chunk` of `count` of part `part` of `camera` is in the sink.
    struct Checkpoint: Sendable, Equatable {
        var camera: UUID
        var part: Int
        var chunk: Int
        var count: Int
    }

    private struct State {
        var footage: [UUID: Result<Footage, ClipError>] = [:]
        var requests: [ClipRequest] = []
        var exports: [Checkpoint] = []
        var chunks = 4
        var onPlan: @Sendable (ClipRequest) async throws -> Void = { _ in }
        var afterChunk: @Sendable (Checkpoint) async throws -> Void = { _ in }
        var reported: @Sendable (_ written: Int64, _ bytes: Int64, Checkpoint) -> Int64 = { written, _, _ in written }
    }

    private let state = Mutex(State())

    // MARK: Setting it up

    func setFootage(_ footage: Footage, for camera: UUID) { state.withLock { $0.footage[camera] = .success(footage) } }
    func setPlanError(_ error: ClipError, for camera: UUID) { state.withLock { $0.footage[camera] = .failure(error) } }
    /// The chunks each part is written in.
    func setChunks(_ count: Int) { state.withLock { $0.chunks = count } }
    /// Called when a plan is asked for, before it answers.
    func setOnPlan(_ hook: @escaping @Sendable (ClipRequest) async throws -> Void) { state.withLock { $0.onPlan = hook } }
    /// Called after each chunk is written and its progress reported; may wait, or throw to make the export fail there.
    func setAfterChunk(_ hook: @escaping @Sendable (Checkpoint) async throws -> Void) { state.withLock { $0.afterChunk = hook } }
    /// What `progress` is told once `written` of `bytes` are in the sink (the truth unless a test lies).
    func setReported(_ report: @escaping @Sendable (_ written: Int64, _ bytes: Int64, Checkpoint) -> Int64) { state.withLock { $0.reported = report } }

    // MARK: What it was asked

    /// The plan requests, in order.
    var requests: [ClipRequest] { state.withLock { $0.requests } }
    /// Every chunk written, in order.
    var exports: [Checkpoint] { state.withLock { $0.exports } }
    /// The parts exported, in order (a part is listed once however many chunks it had).
    var exportedParts: [(camera: UUID, part: Int)] {
        var seen: [(camera: UUID, part: Int)] = []
        for point in exports where !seen.contains(where: { $0.camera == point.camera && $0.part == point.part }) { seen.append((point.camera, point.part)) }
        return seen
    }

    // MARK: ClipExporting

    func plan(_ request: ClipRequest) async throws -> ClipPlan {
        let (outcome, hook) = state.withLock { state -> (Result<Footage, ClipError>?, @Sendable (ClipRequest) async throws -> Void) in
            state.requests.append(request)
            return (state.footage[request.camera], state.onPlan)
        }
        try await hook(request)
        if Task.isCancelled { throw ClipError.cancelled }
        guard let footage = try outcome?.get() else { throw ClipError.nothingRecorded }
        let parts = footage.parts.enumerated().map { offset, part in
            ClipPart(index: offset + 1, count: footage.parts.count, start: request.start.addingTimeInterval(-part.leadIn), end: request.end, leadIn: part.leadIn,
                     byteCount: part.bytes, sampleCount: 100,
                     fileName: footage.fileNames?[offset] ?? ClipFileName.part(cameraName: request.cameraName, start: request.start, end: request.end,
                                                                               partIndex: offset + 1, partCount: footage.parts.count, timeZone: request.timeZone))
        }
        return ClipPlan(request: request, parts: parts, gaps: footage.gaps, soundOmitted: footage.soundOmitted)
    }

    func export(_ plan: ClipPlan, part: Int, to sink: any ClipSink, progress: @Sendable (Int64) -> Void) async throws {
        let camera = plan.request.camera
        let bytes = plan.parts[part - 1].byteCount
        let (chunks, hook, report) = state.withLock { ($0.chunks, $0.afterChunk, $0.reported) }
        var written: Int64 = 0
        for chunk in 1...chunks {
            if Task.isCancelled { throw ClipError.cancelled }
            let size = chunk == chunks ? bytes - written : bytes / Int64(chunks)
            try await sink.write(Data(repeating: UInt8(truncatingIfNeeded: chunk), count: Int(size)))
            written += size
            let point = Checkpoint(camera: camera, part: part, chunk: chunk, count: chunks)
            state.withLock { $0.exports.append(point) }
            progress(report(written, bytes, point))
            try await hook(point)
        }
    }
}

/// The person at the Save panel and at the folder panel: answers with what the test sets, and remembers what it was asked.
@MainActor final class FakeClipDestinations: ClipDestinationPicking {
    /// The file the person chooses in the Save panel (nil: Cancel).
    var file: URL?
    /// The folder the person chooses in the folder panel (nil: Cancel).
    var folder: URL?
    /// While set, the panel stays up until the latch opens.
    var hold: Latch?
    private(set) var fileRequests: [(suggestedName: String, startingIn: URL?)] = []
    private(set) var folderRequests: [URL?] = []

    @MainActor func pickFile(suggestedName: String, startingIn: URL?) async -> URL? {
        fileRequests.append((suggestedName, startingIn))
        await hold?.wait()
        return file
    }

    @MainActor func pickFolder(startingIn: URL?) async -> URL? {
        folderRequests.append(startingIn)
        await hold?.wait()
        return folder
    }
}
