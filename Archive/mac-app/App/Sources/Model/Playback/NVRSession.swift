import BridgeEngine
import Foundation
import Observation

/// The camera page and the NVR grid share this type: one clock, one to nine cells. It turns what a person does (drag the timeline, press play, go
/// live) into desires for the cells, and the live and recorded pictures of every cell take turns on the cell's one renderer (`NVRCell`).
///
/// Nothing here does I/O: `scrub(to:)` writes the newest target into each cell's mailbox and returns. While the pointer moves the cells show
/// keyframes; `exactDelay` after the last move (and on release) they are asked for the exact frame, the hovered tile first. Release plays; a release
/// within `PlaybackClock.liveSnap` of now, or after it, goes live.
@MainActor @Observable final class NVRSession {
    static let maximumCells = 9
    /// The pointer must rest this long before the exact frame is asked for.
    static let exactDelay: TimeInterval = 0.08

    let clock: PlaybackClock
    /// The tile the pointer is over: it gets the exact frame first.
    private(set) var focused: UUID?
    /// Sound is off until the person turns it on (single-camera view only).
    var isMuted = true {
        didSet {
            for cell in cells {
                cell.playback.setAudio(!isMuted)
                cell.feed?.isMuted = isMuted
            }
        }
    }
    private(set) var cells: [NVRCell] = []
    private(set) var isScrubbing = false
    private(set) var isSuspended = false
    /// Cells that can show sound (the single-camera view): the others never ask for it.
    var wantsAudio = false

    @ObservationIgnored private let archive: any ArchiveReading
    @ObservationIgnored private let makeSink: @MainActor () -> any ArchiveVideoSink
    @ObservationIgnored private let now: @Sendable () -> TimeInterval
    @ObservationIgnored private let sleep: @Sendable (_ until: TimeInterval) async throws -> Void
    @ObservationIgnored private let liveOpener: LiveVideoOpener?
    @ObservationIgnored private let liveStream: LiveVideoStream
    @ObservationIgnored private let frames: (any RecordedFrameSource)?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var exactTask: Task<Void, Never>?
    /// What the engine last said about the recordings folder (`recheckDrive`): read by the cells, which cannot tell a drive that is away from a gap.
    @ObservationIgnored let drive = DriveFlag()
    /// The newest target and whether the cells were playing, for `resume`.
    @ObservationIgnored private var lastDesire: PlaybackDesire?
    @ObservationIgnored private var wasLiveBeforeSuspend = true
    /// A cell lost the recordings drive while the clock played: the clock stands still at `position` (no picture runs away from it) and playing
    /// goes on from there when the drive is back (Mac spec 13: "the clock pauses; recovery within 5 s of the drive returning").
    private(set) var driveHold: DriveHold?
    /// How often a held session asks the cell that lost the drive to read again (the engine's own check of the drive runs every 5 s).
    static let driveRetryInterval: TimeInterval = 5

    struct DriveHold: Equatable {
        var position: Date
        /// `now()` when the cells were last asked.
        var lastTry: TimeInterval
    }

    /// `liveOpener` nil: no live view (the cells only show recorded video). `liveStream`: the grid reads sub streams, the camera page the main stream.
    init(archive: any ArchiveReading, clock: PlaybackClock, makeSink: @escaping @MainActor () -> any ArchiveVideoSink,
         now: @escaping @Sendable () -> TimeInterval, sleep: @escaping @Sendable (_ until: TimeInterval) async throws -> Void,
         liveOpener: LiveVideoOpener? = nil, liveStream: LiveVideoStream = .sub, frames: (any RecordedFrameSource)? = nil) {
        self.archive = archive
        self.clock = clock
        self.makeSink = makeSink
        self.now = now
        self.sleep = sleep
        self.liveOpener = liveOpener
        self.liveStream = liveStream
        self.frames = frames
    }

    /// Read by a `TimelineView`, not through observation churn.
    var position: Date { clock.position() }

    func cell(for id: UUID) -> NVRCell? { cells.first { $0.cameraID == id } }

    // MARK: Cameras

    /// At most `maximumCells`; cells that leave are stopped and their live leases released; new cells join the clock's state (live, or a still
    /// at the position).
    func setCameras(_ ids: [UUID]) {
        let wanted = Array(ids.prefix(Self.maximumCells))
        let leaving = cells.filter { !wanted.contains($0.cameraID) }
        for cell in leaving { Task { await cell.dispose() } }
        var kept: [NVRCell] = []
        for id in wanted {
            if let existing = cell(for: id) {
                kept.append(existing)
            } else {
                let created = makeCell(id)
                kept.append(created)
                join(created)
            }
        }
        cells = kept
        if let focused, !wanted.contains(focused) { self.focused = nil }
    }

    private func makeCell(_ id: UUID) -> NVRCell {
        let sink = makeSink()
        var feed: LiveFeed?
        if let liveOpener {
            let created = LiveFeed(cameraID: id, stream: liveStream, wantsAudio: wantsAudio, displayWidth: liveStream == .main ? 3_000 : nil, sink: sink,
                                   open: liveOpener)
            created.isMuted = isMuted
            feed = created
        }
        let playback = CellPlayback(sink: sink, archive: archive, camera: id, clock: clock, now: now, sleep: sleep, frames: frames, drive: drive)
        playback.setAudio(wantsAudio && !isMuted)
        let cell = NVRCell(cameraID: id, sink: sink, playback: playback, feed: feed)
        cell.setCoverageHandler { [weak self] in self?.coverageChanged() }
        return cell
    }

    /// A cell that joins while the clock is live shows live video; otherwise it shows what the others show.
    private func join(_ cell: NVRCell) {
        if isSuspended { return }
        if clock.isLive {
            cell.startLive()
        } else {
            cell.show(PlaybackDesire(target: clock.position(), precision: .exact, playing: clock.isPlaying, epoch: nextEpoch()))
        }
    }

    func focus(_ id: UUID?) { focused = id }

    // MARK: Scrubbing

    func beginScrub() {
        driveHold = nil
        isScrubbing = true
        exactTask?.cancel()
    }

    /// O(1): writes the newest target into every cell's mailbox. No I/O, no decode, no await. The exact frame is asked for `exactDelay` later.
    func scrub(to time: Date) {
        driveHold = nil
        clock.scrub(to: time)
        issue(target: time, precision: .keyframe, playing: false)
        exactTask?.cancel()
        let due = now() + Self.exactDelay   // measured from this call, not from whenever the task gets to run
        exactTask = Task { [weak self, sleep] in
            do { try await sleep(due) } catch { return }
            guard !Task.isCancelled else { return }
            self?.issue(target: time, precision: .exact, playing: false)
        }
    }

    /// Release: plays from the target (`clock.play(from:startingIn: 0.1)`), or goes live within `liveSnap` of now.
    func endScrub() {
        driveHold = nil
        isScrubbing = false
        exactTask?.cancel()
        let position = clock.position()
        if clock.shouldGoLive(releasingAt: position) {
            goLive()
        } else {
            clock.play(from: position, startingIn: PlaybackClock.maximumStartDelay)
            issue(target: position, precision: .exact, playing: true)
        }
    }

    /// A scrub that ends without playing (the viewer opened paused at a time): the exact frame at the target, the clock paused there.
    func finishPausedScrub() {
        driveHold = nil
        isScrubbing = false
        exactTask?.cancel()
        let position = clock.position()
        clock.scrub(to: position)
        issue(target: position, precision: .exact, playing: false)
    }

    // MARK: Transport

    func play() {
        driveHold = nil
        guard !clock.isLive else { return }
        let position = clock.position()
        clock.play(from: position, startingIn: PlaybackClock.maximumStartDelay)
        issue(target: position, precision: .exact, playing: true)
    }

    /// Pauses where the picture is. A live picture pauses on the newest recorded frame when the camera records, else on the frozen live picture.
    func pause() {
        driveHold = nil
        exactTask?.cancel()
        if clock.isLive {
            let edge = cells.compactMap { archive.extent(camera: $0.cameraID)?.newest }.max()
            guard let edge else {
                for cell in cells { cell.freezeLive() }
                return
            }
            let target = min(clock.position(), edge.addingTimeInterval(-0.001))
            clock.scrub(to: target)
            issue(target: target, precision: .exact, playing: false)
            return
        }
        clock.pause()
        issue(target: clock.position(), precision: .exact, playing: false)
    }

    func togglePlay() {
        if clock.isPlaying {
            pause()
        } else if clock.isLive {
            if cells.contains(where: { $0.isLiveFrozen }) { goLive() } else { pause() }
        } else {
            play()
        }
    }

    func goLive() {
        driveHold = nil
        exactTask?.cancel()
        clock.goLive()
        lastDesire = nil
        for cell in cells { cell.goLive() }
    }

    /// Arrow keys: `seconds` later (or earlier) than the playhead, playing if it played.
    func seek(by seconds: TimeInterval) {
        driveHold = nil
        let target = clock.position().addingTimeInterval(seconds)
        if seconds > 0, clock.shouldGoLive(releasingAt: target) {
            goLive()
            return
        }
        exactTask?.cancel()
        let playing = clock.isPlaying
        if playing {
            clock.play(from: target, startingIn: PlaybackClock.maximumStartDelay)
        } else {
            clock.scrub(to: target)
        }
        issue(target: target, precision: .exact, playing: playing)
    }

    // MARK: Hiding

    /// The viewer covers the page, or the window is hidden: the clock holds where it is (live stays live), every cell releases its decoder and its lease.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        driveHold = nil
        exactTask?.cancel()
        wasLiveBeforeSuspend = clock.isLive
        if clock.isPlaying { clock.pause() }
        for cell in cells { cell.suspend() }
    }

    /// Live cells go live again; recorded cells show the exact still at the clock's position. It does not start playing.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        let still = clock.isLive ? nil : PlaybackDesire(target: clock.position(), precision: .exact, playing: false, epoch: nextEpoch())
        for cell in cells { cell.resume(stillAt: still) }
    }

    /// Every cell stops for good.
    func stopAll() {
        driveHold = nil
        exactTask?.cancel()
        let leaving = cells
        cells = []
        for cell in leaving { Task { await cell.dispose() } }
    }

    // MARK: Desires

    private func nextEpoch() -> Int {
        epoch += 1
        return epoch
    }

    private func issue(target: Date, precision: ScrubPrecision, playing: Bool) {
        let desire = PlaybackDesire(target: target, precision: precision, playing: playing, epoch: nextEpoch())
        lastDesire = desire
        for cell in ordered() { cell.show(desire) }
    }

    /// The cells with the focused one first: the hovered tile gets the exact frame first.
    func ordered() -> [NVRCell] {
        guard let focused, let first = cell(for: focused) else { return cells }
        return [first] + cells.filter { $0 !== first }
    }

    /// A cell lost the recordings drive while the clock plays: the clock stops at the playhead, the cells show the still there (the one that lost
    /// the drive tries to read it again), and `driveHold` remembers where to go on. False when there was nothing to hold.
    @discardableResult
    private func holdForDriveIfNeeded() -> Bool {
        guard driveHold == nil, clock.isPlaying, !isScrubbing, !isSuspended, cells.contains(where: { $0.coverage == .driveMissing }) else { return false }
        let position = clock.position()
        clock.pause()
        driveHold = DriveHold(position: position, lastTry: now())
        issue(target: position, precision: .exact, playing: false)
        return true
    }

    /// About twice a second (`NVRPanelModel.refresh`). With the drive gone, every `driveRetryInterval` seconds, and at once when the engine says
    /// recording works again (`driveBack`), the cells are asked for the still at the playhead again; the one that lost the drive reads it, and when
    /// that works `coverageChanged` plays on. It also catches a cell that already lacked the drive when playing began (its coverage did not change).
    /// `driveMissing`: the engine says the folder is missing (`ArchivePause.folderMissing`). The cells ask it before they call a silent archive a gap.
    func recheckDrive(driveBack: Bool, driveMissing: Bool = false) {
        drive.set(driveMissing)
        guard !isSuspended else { return }
        guard let hold = driveHold else {
            holdForDriveIfNeeded()
            return
        }
        guard driveBack || now() - hold.lastTry >= Self.driveRetryInterval else { return }
        driveHold?.lastTry = now()
        issue(target: hold.position, precision: .exact, playing: false)
    }

    /// Every visible cell is in a gap: the clock jumps to the next recording, or goes live when there is none.
    private func coverageChanged() {
        if let hold = driveHold {
            // Held for the drive: when no cell lacks it any more, play on from where the clock stopped.
            guard !drive.isMissing, !cells.contains(where: { $0.coverage == .driveMissing }) else { return }
            driveHold = nil
            clock.play(from: hold.position, startingIn: PlaybackClock.maximumStartDelay)
            issue(target: hold.position, precision: .exact, playing: true)
            return
        }
        if holdForDriveIfNeeded() { return }
        guard clock.isPlaying, !isScrubbing, !cells.isEmpty else { return }
        var next: Date?
        for cell in cells {
            guard case .noRecording(let start, _) = cell.coverage else { return }
            if let start { next = min(next ?? start, start) }
        }
        if let next {
            clock.play(from: next, startingIn: PlaybackClock.maximumStartDelay)
            issue(target: next, precision: .exact, playing: true)
        } else {
            goLive()
        }
    }
}
