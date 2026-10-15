import BridgeEngine
import Foundation
import Observation

/// One camera in the NVR (the camera page's single cell, or a tile of the grid): a renderer that is given to the camera's live feed or to its
/// recorded playback, one at a time, and what the person should be told about it.
///
/// Live to recorded: the feed keeps its picture on stop (`keepsPictureOnStop`), `stopAndWait` returns when nothing of it can reach the renderer,
/// and only then does playback start; its first keyframe replaces the picture. Recorded to live: playback goes idle (awaited), the feed starts and
/// resets the renderer, and the first live keyframe replaces the picture. No `clear()`, so there is no blank frame and no snapshot flash, and at
/// most one producer writes to the renderer at any time.
@MainActor @Observable final class NVRCell {
    enum Owner: Equatable {
        case live
        case recorded
    }

    let cameraID: UUID
    let sink: any ArchiveVideoSink
    let playback: CellPlayback
    /// The camera's live feed; nil for a cell that has no live view (tests).
    let feed: LiveFeed?
    /// Live or recorded picture visible: `feed.hasPicture || playback.hasPicture`. The NVR views own their opacity.
    var showsPicture: Bool { (feed?.hasPicture ?? false) || hasRecordedPicture }
    private(set) var coverage: CellCoverage = .loading
    /// `playback.hasPicture` as of the last change it reported (so views that read `showsPicture` are redrawn).
    private var hasRecordedPicture = false
    /// Who draws now (and who is about to, during a handoff).
    private(set) var owner = Owner.live
    /// Live video was paused (`freezeLive`): the last picture stays until live video starts again.
    private(set) var isLiveFrozen = false

    @ObservationIgnored private var generation = 0
    /// The feed is being stopped and awaited; desires wait in `pending` until playback may start.
    @ObservationIgnored private var handingOff = false
    var isHandingOff: Bool { handingOff }
    @ObservationIgnored private var pending: PlaybackDesire?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var onCoverageChange: (@MainActor () -> Void)?

    init(cameraID: UUID, sink: any ArchiveVideoSink, playback: CellPlayback, feed: LiveFeed? = nil) {
        self.cameraID = cameraID
        self.sink = sink
        self.playback = playback
        self.feed = feed
        feed?.keepsPictureOnStop = true
        playback.setChangeHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Called when the session wants to hear about coverage changes (a gap).
    func setCoverageHandler(_ handler: (@MainActor () -> Void)?) { onCoverageChange = handler }

    // MARK: Producers

    /// The cell shows live video (the feed runs unless the cell is suspended).
    func startLive() {
        generation += 1
        handingOff = false
        isLiveFrozen = false
        owner = .live
        pending = nil
        feed?.isSuspended = isSuspended
        feed?.isWanted = true
        refresh()
    }

    /// Recorded video: playback is given `desire`. From live, the feed is stopped first and awaited.
    func show(_ desire: PlaybackDesire) {
        guard !isSuspended else {
            pending = desire
            return
        }
        switch owner {
        case .recorded:
            if handingOff { pending = desire } else { playback.request(desire) }
        case .live:
            pending = desire
            handOffToRecorded()
        }
    }

    private func handOffToRecorded() {
        guard let feed, feed.isWanted || feed.phase != .stopped else {
            owner = .recorded   // no live view to wait for
            if let desire = pending { playback.request(desire) }
            pending = nil
            return
        }
        generation += 1
        let mine = generation
        owner = .recorded
        handingOff = true
        refresh()
        Task { @MainActor [weak self] in
            await feed.stopAndWait()
            guard let self, mine == generation else { return }
            handingOff = false
            if let desire = pending { playback.request(desire) }
            pending = nil
            refresh()
        }
    }

    /// Back to live video: playback stops (awaited), then the feed starts again on the same renderer.
    func goLive() {
        generation += 1
        let mine = generation
        pending = nil
        handingOff = false
        guard owner == .recorded else {
            startLive()
            return
        }
        Task { @MainActor [weak self] in
            await self?.playback.idle()
            guard let self, mine == generation else { return }
            startLive()
        }
    }

    /// The viewer covers the page, or the window is hidden: nothing plays or decodes, and no lease on the camera is held.
    func suspend() {
        generation += 1
        handingOff = false
        isSuspended = true
        feed?.isSuspended = true
        playback.cancel()
        let mine = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            await playback.waitUntilIdle()
            // Nothing is shown while the page is covered: the renderer lets go of its pictures. (A cell resumed meanwhile keeps what it has.)
            guard mine == generation, owner == .recorded else { return }
            sink.clear()
            playback.forgetPicture()
            refresh()
        }
        refresh()
    }

    /// Back after `suspend`: live video runs again; recorded video shows the exact still at the remembered desire (it does not start playing).
    func resume(stillAt desire: PlaybackDesire?) {
        generation += 1
        isSuspended = false
        feed?.isSuspended = false
        if owner == .recorded, let desire {
            var still = desire
            still.playing = false
            still.precision = .exact
            playback.request(still)
        } else if let pending {
            show(pending)
        }
        refresh()
    }

    /// Pausing live video where there is no recording to pause on: the feed stops and its last picture stays.
    func freezeLive() {
        guard owner == .live, let feed else { return }
        feed.isWanted = false
        isLiveFrozen = true
    }

    /// The cell is going away: nothing of it may reach the renderer after this task is done.
    func dispose() async {
        generation += 1
        playback.setChangeHandler(nil)
        feed?.keepsPictureOnStop = false
        await feed?.stopAndWait()
        await playback.stop()
    }

    // MARK: State

    func refresh() {
        if playback.hasPicture != hasRecordedPicture { hasRecordedPicture = playback.hasPicture }
        let coverage: CellCoverage = owner == .live ? .live : playback.coverage
        if coverage != self.coverage {
            self.coverage = coverage
            onCoverageChange?()
        }
    }
}
