import BridgeEngine
import FMP4
import Foundation
import MediaCore
import Synchronization

nonisolated enum ScrubPrecision: Sendable, Equatable { case keyframe, exact }

/// What a cell should show. The newest desire wins (latest wins); staleness means a newer desire exists, never the clock.
nonisolated struct PlaybackDesire: Sendable, Equatable {
    var target: Date
    var precision: ScrubPrecision
    var playing: Bool
    var epoch: Int
}

nonisolated enum CellCoverage: Sendable, Equatable {
    case live
    case recorded
    case loading
    /// A gap: `next` is the start of the next recording (nil: none); `recordingOff`: Record is off for the camera.
    case noRecording(next: Date?, recordingOff: Bool)
    case driveMissing
    case unreadable
}

/// One camera's playback worker: exactly one detached `.userInitiated` task consumes the newest desire (Mac spec 8.3 to 8.5). It holds the current
/// parsed fragment and at most one read-ahead (about 6 MB of compressed data).
///
/// `request` is O(1): it stores the desire in a mailbox and wakes the task. The task shows a recorded picture through the sink in the way the live
/// path does, and primes the decoder with frames marked decode-only:
///
/// - A scrub target in a GOP the sink is already decoding, ahead of what was given to it, is reached by giving the frames in between (decode-only)
///   and the target frame (displayable), with no flush and no new keyframe read. Anything else resets the sink (the picture stays), shows the GOP's
///   keyframe (a keyframe desire, or a lead-in longer than `previewDeltaBudget` frames) and then, for an exact desire, the frames up to the target.
/// - A playing desire shows the exact still and then each frame when its time comes, reading the next fragment ahead.
/// - Reads are not cancelled; a stale run stops before starting a read and every few frames, and a keyframe it already read is still shown, so a
///   target that keeps moving cannot starve the picture.
nonisolated final class CellPlayback: Sendable {
    /// Time after the last displayable frame before the sink is reset, so a flush never kills a picture still being decoded (benchmark B2 sets it).
    static let previewDwell: TimeInterval = 0.03
    /// The same for a picture wider than the Mac's hardware H.264 decoder takes (4096): it is decoded in software, about 50 ms for a key picture of a
    /// 4256x1888 camera here, which a 30 ms dwell cut off at every step of a drag, so those cameras showed nothing until the person let go.
    static let softwareDecodeDwell: TimeInterval = 0.15
    static let hardwareDecodeMaximumWidth = 4_096
    /// A lead-in of at most this many frames goes straight to the exact frame, without the keyframe preview (benchmark B1 sets it).
    static let previewDeltaBudget = 12
    /// The cell never lets the sink's queue grow beyond this, and waits until it falls to `resumeQueued`.
    static let maximumQueued = 120
    static let resumeQueued = 60
    static let backPressurePoll: TimeInterval = 0.004
    /// The next fragment is read when less than this much video is left.
    static let readAhead: TimeInterval = 3
    /// Later than this behind the clock, a delta frame is given decode-only until the cell is on time again; later than `lateResync`, playback restarts at the playhead.
    static let lateDecodeOnly: TimeInterval = 0.120
    static let lateResync: TimeInterval = 0.5
    /// Audio is given to the player this much before it is due (the player starts its own timeline that far ahead).
    static let audioLead: TimeInterval = 0.12
    static let defaultFrameInterval: TimeInterval = 1.0 / 25
    /// At the end of the recordings a playing cell asks again every `endPollInterval`, at most `endPollLimit` times.
    static let endPollInterval: TimeInterval = 0.25
    static let endPollLimit = 120

    /// `sleep` for the app: until `systemUptime` reaches the given value.
    static let systemSleep: @Sendable (TimeInterval) async throws -> Void = { until in
        let delay = until - ProcessInfo.processInfo.systemUptime
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    }

    private let mailbox: Mailbox
    private let task: Task<Void, Never>

    /// `frames`: where recorded frames come from (nil: the archive's bytes through the FMP4 parsers).
    init(sink: any ArchiveVideoSink, archive: any ArchiveReading, camera: UUID, clock: PlaybackClock,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (_ until: TimeInterval) async throws -> Void = CellPlayback.systemSleep,
         frames: (any RecordedFrameSource)? = nil, drive: DriveFlag = DriveFlag()) {
        let mailbox = Mailbox()
        self.mailbox = mailbox
        let worker = Worker(sink: sink, archive: archive, camera: camera, clock: clock, now: now, sleep: sleep,
                            source: frames ?? ArchiveFrameSource(archive: archive), mailbox: mailbox, drive: drive)
        task = Task.detached(priority: .userInitiated) { await worker.run() }
    }

    deinit {
        mailbox.shutDown()
        task.cancel()
    }

    /// O(1): stores `desire` (a mailbox with a one-slot wake). No I/O, no decode, no await.
    func request(_ desire: PlaybackDesire) {
        mailbox.post(desire)
    }

    var coverage: CellCoverage { mailbox.coverage }

    /// No desire is waiting and nothing is running (the session's quiescence checks, and tests).
    var isIdle: Bool { mailbox.isIdle }

    /// A picture of recorded video is on screen.
    var hasPicture: Bool { mailbox.hasPicture }

    /// The sound of the recording is given to the sink (from the next fragment on). Off by default; only the single-camera view turns it on.
    func setAudio(_ on: Bool) {
        mailbox.setAudio(on)
    }

    /// Called (from the cell's task) when `coverage` or `hasPicture` changed.
    func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        mailbox.setChangeHandler(handler)
    }

    /// Drops the desire: the cell stops at its next check (a read in flight finishes first). Not waiting; `waitUntilIdle()` does.
    func cancel() {
        mailbox.post(nil)
    }

    /// Returns when the cell is doing nothing: after `cancel()`, no `sink.show` happens any more.
    func waitUntilIdle() async {
        await mailbox.waitUntilIdle()
    }

    /// The renderer was cleared by the caller: this cell no longer has a picture on screen.
    func forgetPicture() {
        mailbox.reset()
    }

    /// `cancel()` and wait: no `sink.show` happens after this returns. The cell stays alive for the next desire, and shows nothing of its own
    /// (`hasPicture` false, coverage `.loading`).
    func idle() async {
        cancel()
        await waitUntilIdle()
        mailbox.reset()
    }

    /// Stops the task and waits for it: no `sink.show` happens after this returns.
    func stop() async {
        mailbox.shutDown()
        await task.value
    }
}

// MARK: - Mailbox

/// What the main actor and the cell's task share.
private nonisolated final class Mailbox: Sendable {
    nonisolated struct Job {
        var desire: PlaybackDesire
        var sequence: Int
    }

    private nonisolated struct State {
        var desire: PlaybackDesire?
        /// +1 for every desire and every idle: a run is stale when this has changed.
        var sequence = 0
        var taken = 0
        var busy = false
        var isShutDown = false
        var coverage = CellCoverage.loading
        var hasPicture = false
        var wantsAudio = false
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
        var onChange: (@Sendable () -> Void)?
        /// The sleep the task is in (a frame's time, the dwell, the renderer's back-pressure): a new desire cuts it short. Reads are never cancelled.
        var nap: Task<Void, any Error>?
        /// A desire arrived while the task was busy: it looks again before it sleeps. One slot, however many desires came.
        var wakePending = false
        /// The task, asleep in `waitForWake()`. A one-slot wake made by hand, not an `AsyncStream`: the stream's `yield` cost most of the time `scrub(to:)` spends
        /// on the main thread (measured with sample(1): 80 of 104 samples of `NVRSession.issue`, 9 cells at 120 Hz).
        var wakeWaiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())

    var coverage: CellCoverage { state.withLock { $0.coverage } }
    var isIdle: Bool { state.withLock { !$0.busy && ($0.desire == nil || $0.taken == $0.sequence) } }
    var hasPicture: Bool { state.withLock { $0.hasPicture } }
    var wantsAudio: Bool { state.withLock { $0.wantsAudio } }

    func post(_ desire: PlaybackDesire?) {
        let (waiter, nap) = state.withLock { state -> (CheckedContinuation<Bool, Never>?, Task<Void, any Error>?) in
            guard !state.isShutDown else { return (nil, nil) }
            state.desire = desire
            state.sequence += 1
            guard let waiter = state.wakeWaiter else {
                state.wakePending = true
                return (nil, state.nap)
            }
            state.wakeWaiter = nil
            return (waiter, state.nap)
        }
        nap?.cancel()
        waiter?.resume(returning: true)
    }

    /// Sleeps until a desire has been posted since the last wake (true) or the mailbox is shut down (false). One consumer: the cell's task.
    func waitForWake() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answer = state.withLock { state -> Bool? in
                if state.isShutDown { return false }
                if state.wakePending {
                    state.wakePending = false
                    return true
                }
                state.wakeWaiter = continuation
                return nil
            }
            if let answer { continuation.resume(returning: answer) }
        }
    }

    func setNap(_ nap: Task<Void, any Error>?) { state.withLock { $0.nap = nap } }

    /// The newest desire if the task has not taken it yet; nil (and idle) otherwise.
    func take() -> Job? {
        let (job, waiters) = state.withLock { state -> (Job?, [CheckedContinuation<Void, Never>]) in
            if !state.isShutDown, let desire = state.desire, state.taken != state.sequence {
                state.taken = state.sequence
                state.busy = true
                return (Job(desire: desire, sequence: state.sequence), [])
            }
            state.busy = false
            defer { state.idleWaiters = [] }
            return (nil, state.idleWaiters)
        }
        for waiter in waiters { waiter.resume() }
        return job
    }

    func isCurrent(_ sequence: Int) -> Bool {
        state.withLock { $0.sequence == sequence && !$0.isShutDown }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if !state.busy || state.isShutDown { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func shutDown() {
        let (waiters, nap, sleeper) = state.withLock { state -> ([CheckedContinuation<Void, Never>], Task<Void, any Error>?, CheckedContinuation<Bool, Never>?) in
            state.isShutDown = true
            state.desire = nil
            state.sequence += 1
            defer { state.idleWaiters = []; state.wakeWaiter = nil }
            return (state.idleWaiters, state.nap, state.wakeWaiter)
        }
        nap?.cancel()
        sleeper?.resume(returning: false)
        for waiter in waiters { waiter.resume() }
    }

    func setCoverage(_ coverage: CellCoverage) {
        notify { state in
            guard state.coverage != coverage else { return false }
            state.coverage = coverage
            return true
        }
    }

    func setHasPicture(_ value: Bool) {
        notify { state in
            guard state.hasPicture != value else { return false }
            state.hasPicture = value
            return true
        }
    }

    /// An idle cell shows nothing of its own: the live feed (or nothing) has the layer.
    func reset() {
        notify { state in
            guard state.hasPicture || state.coverage != .loading else { return false }
            state.hasPicture = false
            state.coverage = .loading
            return true
        }
    }

    func setAudio(_ on: Bool) { state.withLock { $0.wantsAudio = on } }
    func setChangeHandler(_ handler: (@Sendable () -> Void)?) { state.withLock { $0.onChange = handler } }

    private func notify(_ change: (inout State) -> Bool) {
        let handler = state.withLock { state -> (@Sendable () -> Void)? in change(&state) ? state.onChange : nil }
        handler?()
    }
}

// MARK: - Worker

private actor Worker {
    /// What has been given to the sink since its last reset, and where the next frame comes from.
    nonisolated struct Cursor {
        /// The fragment `frames` belongs to.
        var fragment: ArchiveFragment
        var info: FMP4InitInfo
        var frames: [EncodedVideoFrame]
        /// The fragment's sound, when a playing desire asked for it.
        var audio: [EncodedAudioFrame] = []
        /// `frames` holds every frame of the fragment (false after a keyframe preview, which read only the first).
        var loadedAll: Bool
        /// `frames[..<next]` were given to the sink.
        var next: Int
        /// The index of the frame given as displayable last (nil: none since the reset).
        var displayed: Int?
        /// The id of the keyframe fragment that governs the GOP.
        var gopID: String
        var restarts: Int
        var resets: Int

        var lastEnqueuedTicks: Int64? { next > 0 && next <= frames.count ? frames[next - 1].pts.converted(to: 90_000).value : nil }
    }

    nonisolated enum PlayOutcome {
        case resync(Date)
        case finished
    }

    nonisolated enum PrefetchResult: Sendable {
        case none
        case ready(ArchiveFragment, FMP4InitInfo, DecodedFragment)
        case failed(ArchiveFragment, any Error)
    }

    /// The cursor is no good for this target: reset and start at the keyframe.
    nonisolated struct NeedsRestart: Error {}

    let sink: any ArchiveVideoSink
    let archive: any ArchiveReading
    let camera: UUID
    let clock: PlaybackClock
    let now: @Sendable () -> TimeInterval
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let source: any RecordedFrameSource
    let mailbox: Mailbox
    let drive: DriveFlag

    var cursor: Cursor?
    var infos: [String: FMP4InitInfo] = [:]
    var intervals: [String: TimeInterval] = [:]
    var lastDisplayAt = -TimeInterval.infinity
    var ownResets = 0
    /// Decoder failures (`sink.restarts` changes during play) in a row in one group of pictures: the id of its keyframe fragment and how many.
    /// Two in one group skip to the next one (Mac spec 13); a group that is played to its end without a failure of its own starts again at zero.
    var failedGOP: (id: String, count: Int)?
    /// The `sink.restarts` value that has already been counted as a failure (a restart is counted once, however many checks see it).
    var accountedRestarts = 0

    init(sink: any ArchiveVideoSink, archive: any ArchiveReading, camera: UUID, clock: PlaybackClock, now: @escaping @Sendable () -> TimeInterval,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void, source: any RecordedFrameSource, mailbox: Mailbox, drive: DriveFlag) {
        self.drive = drive
        self.sink = sink
        self.archive = archive
        self.camera = camera
        self.clock = clock
        self.now = now
        self.sleep = sleep
        self.source = source
        self.mailbox = mailbox
    }

    /// `sleep(until)` that a new desire (or `idle()`, or `stop()`) cuts short with a `CancellationError`: a read in flight is not touched.
    private func nap(until: TimeInterval, sequence: Int) async throws {
        let sleeper = Task { [sleep] in try await sleep(until) }
        mailbox.setNap(sleeper)
        defer { mailbox.setNap(nil) }
        // A desire that came in before the nap was registered did not see it: look again.
        guard mailbox.isCurrent(sequence) else {
            sleeper.cancel()
            throw CancellationError()
        }
        try await withTaskCancellationHandler {
            try await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
    }

    func run() async {
        while await mailbox.waitForWake() {
            while let job = mailbox.take() {
                await handle(job.desire, job.sequence)
            }
        }
        _ = mailbox.take()   // idle: releases anybody waiting in `idle()`
    }

    // MARK: Desires

    private func handle(_ desire: PlaybackDesire, _ sequence: Int) async {
        if !desire.playing { sink.silence() }   // sound is only heard while playing
        var target = desire.target
        while mailbox.isCurrent(sequence) {
            do {
                try await present(target, precision: desire.playing ? .exact : desire.precision, withAudio: desire.playing && mailbox.wantsAudio, sequence: sequence)
                guard desire.playing, mailbox.isCurrent(sequence) else { return }
                switch try await play(sequence: sequence) {
                case .resync(let date): target = date
                case .finished: return
                }
            } catch is CancellationError {
                return
            } catch {
                fail(error)
                return
            }
        }
    }

    private func fail(_ error: any Error) {
        switch error {
        case let error as ArchiveError:
            switch error {
            case .fileGone, .timedOut: mailbox.setCoverage(.driveMissing)
            case .unreadable, .noKeyframe: mailbox.setCoverage(.unreadable)
            }
        default:
            mailbox.setCoverage(.unreadable)
        }
    }

    // MARK: Scrubbing

    /// Shows the picture at `target`: the keyframe of its GOP (`.keyframe`) or the exact frame.
    private func present(_ target: Date, precision: ScrubPrecision, withAudio: Bool, sequence: Int) async throws {
        guard archive.isReady else {
            mailbox.setCoverage(.loading)
            return
        }
        var target = target
        let fragment: ArchiveFragment
        if let found = await archive.fragment(camera: camera, containing: target) {
            fragment = found
        } else {
            let next = await archive.fragment(camera: camera, startingAfter: target)
            let before = await archive.fragment(camera: camera, containing: target.addingTimeInterval(-ArchiveConstants.gapThreshold))
            if let before, let next, next.start.timeIntervalSince(before.end) < ArchiveConstants.gapThreshold {
                // A gap under a second (one file ends, the next begins) is continuous: hold the picture.
                if mailbox.hasPicture { return }
                target = before.end.addingTimeInterval(-0.001)
                fragment = before
            } else {
                // The archive answers nothing both for a gap and for a drive that is away: the engine's word decides which (it keeps the picture).
                mailbox.setCoverage(drive.isMissing ? .driveMissing : .noRecording(next: next?.start, recordingOff: false))
                return
            }
        }
        guard mailbox.isCurrent(sequence) else { return }
        let keyID = fragment.hasKeyframe ? fragment.id : ArchiveIdentity.fragmentID(fileKey: fragment.fileKey, index: fragment.index - fragment.backToKey)
        let ticks = Self.ticks(of: target)

        // Forward in the GOP the sink is decoding: no flush, no keyframe read.
        if let current = cursor, current.gopID == keyID, current.restarts == sink.restarts, current.resets == ownResets,
           let last = current.lastEnqueuedTicks, last <= ticks {
            let between = Double(ticks - last) / 90_000 / (intervals[fragment.fileKey] ?? CellPlayback.defaultFrameInterval)
            if precision == .exact || between <= Double(CellPlayback.previewDeltaBudget) {
                do {
                    try await advance(to: fragment, ticks: ticks, withAudio: withAudio, sequence: sequence)
                    mailbox.setCoverage(.recorded)
                    return
                } catch is NeedsRestart {}
            }
        }
        try await restart(at: fragment, keyID: keyID, target: target, ticks: ticks, precision: precision, withAudio: withAudio, sequence: sequence)
    }

    private func restart(at fragment: ArchiveFragment, keyID: String, target: Date, ticks: Int64, precision: ScrubPrecision, withAudio: Bool,
                         sequence: Int) async throws {
        if precision == .keyframe, let current = cursor, current.gopID == keyID, current.displayed == 0,
           current.restarts == sink.restarts, current.resets == ownResets {
            mailbox.setCoverage(.recorded)   // this GOP's keyframe is on screen already
            return
        }
        // A flush must not kill a picture that is still being decoded.
        let dwell = infos.values.contains { $0.video.width > CellPlayback.hardwareDecodeMaximumWidth } ? CellPlayback.softwareDecodeDwell : CellPlayback.previewDwell
        let earliest = lastDisplayAt + dwell
        if now() < earliest {
            try await nap(until: earliest, sequence: sequence)
            guard mailbox.isCurrent(sequence) else { return }
        }
        sink.reset()
        ownResets += 1
        cursor = nil
        if failedGOP?.id != keyID { failedGOP = nil }   // the person moved to another group: a fresh count
        let key: ArchiveFragment
        if fragment.hasKeyframe {
            key = fragment
        } else if let found = await archive.fragment(camera: camera, id: keyID) {
            key = found
        } else {
            throw ArchiveError.fileGone   // retention removed the start of this GOP
        }
        let info = try await initInfo(for: key)
        let interval = intervals[key.fileKey] ?? CellPlayback.defaultFrameInterval
        let leadIn = target.timeIntervalSince(key.start) / interval
        var made = Cursor(fragment: key, info: info, frames: [], loadedAll: false, next: 0, displayed: nil, gopID: keyID, restarts: sink.restarts, resets: ownResets)
        if precision == .keyframe || leadIn > Double(CellPlayback.previewDeltaBudget) {
            guard mailbox.isCurrent(sequence) else { return }
            let frame = try await source.keyframe(of: key, info: info)
            // Shown even if a newer desire arrived during the read: a target that keeps moving would otherwise never get a picture.
            sink.show(frame, decodeOnly: false)
            lastDisplayAt = now()
            mailbox.setHasPicture(true)
            made.frames = [frame]
            made.next = 1
            made.displayed = 0
            cursor = made
            mailbox.setCoverage(.recorded)
            if precision == .keyframe { return }
        } else {
            cursor = made
        }
        guard mailbox.isCurrent(sequence) else { return }
        do {
            try await advance(to: fragment, ticks: ticks, withAudio: withAudio, sequence: sequence)
        } catch is NeedsRestart {
            throw ArchiveError.unreadable("The recording has no picture at this time.")
        }
        mailbox.setCoverage(.recorded)
    }

    /// Gives the sink the frames from the cursor to the frame at `ticks` in `target` (decode-only, the last one displayable). Progress is kept in
    /// `cursor` even when the run is cut short.
    private func advance(to target: ArchiveFragment, ticks: Int64, withAudio: Bool, sequence: Int) async throws {
        guard var c = cursor else { throw NeedsRestart() }
        defer { cursor = c }
        while true {
            if !c.loadedAll {
                guard mailbox.isCurrent(sequence) else { return }
                let decoded = try await source.frames(of: c.fragment, info: c.info, withAudio: withAudio && c.fragment.id == target.id)
                c.frames = decoded.video
                c.audio = decoded.audio
                c.loadedAll = true
                if !decoded.video.isEmpty { intervals[c.fragment.fileKey] = c.fragment.duration / Double(decoded.video.count) }
            }
            if c.fragment.id == target.id {
                guard let chosen = Self.chosenIndex(in: c.frames, ticks: ticks) else { throw ArchiveError.unreadable("The fragment has no frames.") }
                if chosen < c.next {
                    if c.displayed == chosen { return }   // the target frame is on screen already
                    throw NeedsRestart()
                }
                guard await give(upTo: chosen, from: &c, sequence: sequence) else { return }
                await waitForRoom(sequence)
                sink.show(c.frames[chosen], decodeOnly: false)
                lastDisplayAt = now()
                mailbox.setHasPicture(true)
                c.next = chosen + 1
                c.displayed = chosen
                return
            }
            // Not the target's fragment: finish it, then the one after it in the file.
            guard await give(upTo: c.frames.count, from: &c, sequence: sequence), mailbox.isCurrent(sequence) else { return }
            guard let following = await archive.fragment(camera: camera, id: ArchiveIdentity.fragmentID(fileKey: c.fragment.fileKey, index: c.fragment.index + 1)) else {
                throw ArchiveError.fileGone
            }
            c.fragment = following
            c.frames = []
            c.audio = []
            c.loadedAll = false
            c.next = 0
        }
    }

    /// Frames `c.next..<end` to the sink, decode-only, waiting while the sink is far behind. False when a newer desire stopped it.
    private func give(upTo end: Int, from c: inout Cursor, sequence: Int) async -> Bool {
        var sinceCheck = 0
        while c.next < end {
            guard await waitForRoom(sequence) else { return false }
            sink.show(c.frames[c.next], decodeOnly: true)
            c.next += 1
            sinceCheck += 1
            if sinceCheck == 4 {
                sinceCheck = 0
                guard mailbox.isCurrent(sequence) else { return false }
            }
        }
        return true
    }

    /// Back-pressure: above `maximumQueued` frames waiting in the sink, wait (4 ms poll) until it is down to `resumeQueued`.
    @discardableResult
    private func waitForRoom(_ sequence: Int) async -> Bool {
        guard sink.queued >= CellPlayback.maximumQueued else { return true }
        while sink.queued > CellPlayback.resumeQueued {
            guard mailbox.isCurrent(sequence) else { return false }
            do {
                try await nap(until: now() + CellPlayback.backPressurePoll, sequence: sequence)
            } catch {
                return false
            }
        }
        return true
    }

    private func initInfo(for fragment: ArchiveFragment) async throws -> FMP4InitInfo {
        if let known = infos[fragment.fileKey] { return known }
        let info = try await source.initInfo(for: fragment)
        if infos.count >= 8 { infos.removeAll() }
        infos[fragment.fileKey] = info
        return info
    }

    // MARK: Playing

    private func play(sequence: Int) async throws -> PlayOutcome {
        var prefetch: Task<PrefetchResult, Never>?
        do {
            let outcome = try await pace(sequence: sequence, prefetch: &prefetch)
            _ = await prefetch?.value   // at most one read in flight: the next desire starts after it
            return outcome
        } catch {
            _ = await prefetch?.value
            throw error
        }
    }

    private func pace(sequence: Int, prefetch: inout Task<PrefetchResult, Never>?) async throws -> PlayOutcome {
        guard var c = cursor else { return .finished }
        defer { cursor = c }
        let state = clock.state
        guard state.mode == .playing else { return .finished }
        // The sound of the fragment the playhead is in, from the playhead on.
        let playhead = clock.position(atUptime: now())
        var audio = c.audio
        var nextAudio = audio.firstIndex { Self.date(of: $0) >= playhead } ?? audio.count
        var endPolls = 0
        var damaged = 0
        var needsKeyframe = false   // the fragment before the next one was damaged: only a GOP that starts afterwards can be decoded
        while mailbox.isCurrent(sequence) {
            if sink.restarts != c.restarts {
                if noteDecoderFailure(in: Self.keyID(of: c.fragment)) >= 2 {
                    // The second failure in one group of pictures (Mac spec 13): it cannot be decoded here, so skip to the next group that starts with
                    // a keyframe. The picture stays and the cell says so; the path is the one of a damaged fragment, and the renderer, which waits for a
                    // keyframe after a restart, picks up at the next group.
                    mailbox.setCoverage(.unreadable)
                    damaged += 1
                    guard damaged <= 5 else { return .finished }
                    needsKeyframe = true
                    prefetch?.cancel()   // a fragment of the same group may already be on its way: the next one must start a group
                    prefetch = nil
                    c.restarts = sink.restarts
                    c.frames = []
                    c.next = 0
                    continue
                }
                return .resync(clock.position(atUptime: now()))
            }
            let wantsAudio = mailbox.wantsAudio
            let interval = intervals[c.fragment.fileKey] ?? CellPlayback.defaultFrameInterval

            // Read the next fragment ahead while less than `readAhead` seconds of video are left.
            if prefetch == nil, let last = c.frames.last {
                let end = Self.date(of: last).addingTimeInterval(interval)
                if end.timeIntervalSince(clock.position(atUptime: now())) < CellPlayback.readAhead {
                    prefetch = startPrefetch(after: c.fragment, withAudio: wantsAudio, needsKeyframe: needsKeyframe)
                }
            }

            // The fragment is used up: the prefetched one, or none yet.
            if c.next >= c.frames.count {
                if prefetch == nil { prefetch = startPrefetch(after: c.fragment, withAudio: wantsAudio, needsKeyframe: needsKeyframe) }
                let result = await prefetch?.value ?? .none
                prefetch = nil
                switch result {
                case .ready(let fragment, let info, let decoded):
                    let crossesGap = fragment.start.timeIntervalSince(c.fragment.end) >= ArchiveConstants.gapThreshold
                    if crossesGap, !needsKeyframe { mailbox.setCoverage(.noRecording(next: fragment.start, recordingOff: false)) }   // skipping a damaged group is not a gap: the cell goes on saying `unreadable`
                    infos[fragment.fileKey] = info
                    if !decoded.video.isEmpty { intervals[fragment.fileKey] = fragment.duration / Double(decoded.video.count) }
                    if failedGOP?.id != Self.keyID(of: fragment) { failedGOP = nil }   // another group: a fresh count
                    c.fragment = fragment
                    c.info = info
                    c.frames = decoded.video
                    c.loadedAll = true
                    c.next = 0
                    c.gopID = fragment.id
                    audio = decoded.audio
                    nextAudio = 0
                    damaged = 0
                    needsKeyframe = false
                    endPolls = 0
                    // Wait here, holding the picture, until the playhead reaches the recording after a gap.
                    if crossesGap, !decoded.video.isEmpty {
                        let due = PlaybackClock.uptime(of: Self.date(of: decoded.video[0]), in: state)
                        guard await sleepChecking(until: due - CellPlayback.audioLead, sequence: sequence) else { return .finished }
                    }
                case .failed(let fragment, let error):
                    // A damaged fragment: say so, skip it, and go on with the next one.
                    fail(error)
                    damaged += 1
                    needsKeyframe = true
                    guard damaged <= 5 else { return .finished }
                    c.fragment = fragment
                    c.frames = []
                    c.next = 0
                    continue
                case .none:
                    // The end of the recordings, or the drive: the archive answers nothing for both. With the drive away the cell says so and stops (the
                    // session holds the clock and asks again); at the end it asks again for a while (the recorder writes a fragment every 2.5 s).
                    if drive.isMissing {
                        mailbox.setCoverage(.driveMissing)
                        return .finished
                    }
                    mailbox.setCoverage(.noRecording(next: nil, recordingOff: false))
                    endPolls += 1
                    guard endPolls <= CellPlayback.endPollLimit else { return .finished }
                    guard await sleepChecking(until: now() + CellPlayback.endPollInterval, sequence: sequence) else { return .finished }
                    continue
                }
                if c.frames.isEmpty { continue }
            }

            let frame = c.frames[c.next]
            let due = PlaybackClock.uptime(of: Self.date(of: frame), in: state)

            // Sound goes to the player a little before it is due.
            if wantsAudio {
                while nextAudio < audio.count {
                    let audioDue = PlaybackClock.uptime(of: Self.date(of: audio[nextAudio]), in: state) - CellPlayback.audioLead
                    guard audioDue <= now() else { break }
                    sink.play(audio[nextAudio])
                    nextAudio += 1
                }
            }

            let late = now() - due
            if late > CellPlayback.lateResync { return .resync(clock.position(atUptime: now())) }
            if late > CellPlayback.lateDecodeOnly, !frame.isKeyframe {
                guard await waitForRoom(sequence) else { return .finished }
                sink.show(frame, decodeOnly: true)   // catch up: decode it, do not show it
                c.next += 1
                continue
            }
            if late < 0 {
                var wakeAt = due
                if wantsAudio, nextAudio < audio.count {
                    wakeAt = min(wakeAt, PlaybackClock.uptime(of: Self.date(of: audio[nextAudio]), in: state) - CellPlayback.audioLead)
                }
                do { try await nap(until: wakeAt, sequence: sequence) } catch { return .finished }
                continue   // time moved: look again (a newer desire, audio that came due)
            }
            guard await waitForRoom(sequence) else { return .finished }
            sink.show(frame, decodeOnly: false)
            lastDisplayAt = now()
            mailbox.setHasPicture(true)
            mailbox.setCoverage(.recorded)
            c.displayed = c.next
            c.next += 1
        }
        return .finished
    }

    /// The fragment after `fragment` (from the next keyframe on), read in a task of its own: the one read a playing cell has in flight.
    private func startPrefetch(after fragment: ArchiveFragment, withAudio: Bool, needsKeyframe: Bool) -> Task<PrefetchResult, Never> {
        let archive = archive, source = source, camera = camera, known = infos
        return Task {
            guard var next = await archive.fragment(camera: camera, startingAfter: fragment.start) else { return .none }
            var hops = 0
            while needsKeyframe, !next.hasKeyframe, hops < 64 {   // a damaged fragment before it: wait for a GOP that can be decoded
                guard let following = await archive.fragment(camera: camera, startingAfter: next.start) else { return .none }
                next = following
                hops += 1
            }
            do {
                let info: FMP4InitInfo
                if let cached = known[next.fileKey] {
                    info = cached
                } else {
                    info = try await source.initInfo(for: next)
                }
                return .ready(next, info, try await source.frames(of: next, info: info, withAudio: withAudio))
            } catch {
                return .failed(next, error)
            }
        }
    }

    /// Sleeps until `until` in steps of at most half a second; false when a newer desire arrived or the cell was stopped.
    private func sleepChecking(until: TimeInterval, sequence: Int) async -> Bool {
        while mailbox.isCurrent(sequence) {
            let remaining = until - now()
            if remaining <= 0 { return true }
            do { try await nap(until: now() + min(remaining, 0.5), sequence: sequence) } catch { return false }
        }
        return false
    }

    // MARK: Decoder failures

    /// The id of the fragment that holds the keyframe governing `fragment` (the fragment itself when it starts a group of pictures).
    static func keyID(of fragment: ArchiveFragment) -> String {
        fragment.hasKeyframe ? fragment.id : ArchiveIdentity.fragmentID(fileKey: fragment.fileKey, index: fragment.index - fragment.backToKey)
    }

    /// The renderer restarted by itself (its decoder failed, or it lost frames) while group `gopID` was playing: counts it once, and says how many
    /// times in a row that group has failed.
    private func noteDecoderFailure(in gopID: String) -> Int {
        let restarts = sink.restarts
        if restarts != accountedRestarts {
            accountedRestarts = restarts
            failedGOP = (gopID, failedGOP?.id == gopID ? (failedGOP?.count ?? 0) + 1 : 1)
        }
        return failedGOP?.id == gopID ? (failedGOP?.count ?? 0) : 0
    }

    // MARK: Times

    /// Wall ticks since 2001 at 90 kHz: the unit of `EncodedVideoFrame.pts` for recorded frames.
    static func ticks(of date: Date) -> Int64 {
        Int64((date.timeIntervalSinceReferenceDate * 90_000).rounded())
    }

    static func date(of frame: EncodedVideoFrame) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(frame.pts.converted(to: 90_000).value) / 90_000)
    }

    /// A recorded audio frame's instant is its `wallClock` (the slicer sets it to the frame's place on the same time line as the video).
    static func date(of frame: EncodedAudioFrame) -> Date {
        frame.wallClock
    }

    /// The frame to show for `ticks`: the one with the largest presentation time not after it (the first frame when none is).
    static func chosenIndex(in frames: [EncodedVideoFrame], ticks: Int64) -> Int? {
        var best: Int?
        var bestTicks = Int64.min
        for (index, frame) in frames.enumerated() {
            let value = frame.pts.converted(to: 90_000).value
            if value <= ticks, value >= bestTicks {
                best = index
                bestTicks = value
            }
        }
        return best ?? (frames.isEmpty ? nil : 0)
    }
}
