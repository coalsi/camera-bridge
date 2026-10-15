import BridgeEngine
import CoreGraphics
import Foundation
import Observation

/// The timeline and transport of one NVR screen (the camera page's viewer, the NVR page): the session that drives the cells, the viewport, the
/// waveform data, and the conversions between points and times. The views draw it; the screens' models (`NVRPageModel`, the viewer) own one.
@MainActor @Observable final class NVRPanelModel {
    /// A group of pictures longer than this is called coarse to scrub (a smart-codec camera): "Keyframes every N s: scrubbing is coarse."
    static let coarseGOP: TimeInterval = 4

    let session: NVRSession
    let timeline: TimelineModel
    let activity: TimelineActivityModel
    /// The width of the track in points, as last reported by the view.
    private(set) var width: CGFloat = 0
    private(set) var cameraIDs: [UUID] = []
    /// The oldest recording of the cameras shown; nil when none has any.
    private(set) var oldest: Date?
    /// The longest typical keyframe interval of the cameras shown.
    private(set) var typicalGOP: TimeInterval?
    /// Today's date as the panel sees it (the Mac's clock; tests give their own).
    @ObservationIgnored private let wall: @Sendable () -> Date
    @ObservationIgnored private let archive: any ArchiveReading
    @ObservationIgnored private let defaults: UserDefaults

    /// Saves the clip the person chooses; nil where clips are not offered (the screens' tests).
    let clipExport: ClipExportModel?
    /// Where the chosen clip starts: set by Save Clip, nil when no clip is being chosen. The end is the playhead.
    private(set) var clipStart: Date?
    /// The cameras the clip saves (a subset of `clipAvailable`; one on the camera page).
    private(set) var clipCameras: [UUID] = []
    /// Every camera a clip can be made of, on every page, in the order their files are written.
    private(set) var clipAvailable: [UUID] = []
    /// The engine's plan for the chosen clip: its size, where it really starts and what to tell the person; nil until the first plan.
    private(set) var clipPreview: ClipPreview?
    @ObservationIgnored private var clipPreviewTask: Task<Void, Never>?
    @ObservationIgnored private var clipPreviewKey: ClipSelection?

    init(archive: any ArchiveReading, session: NVRSession, defaults: UserDefaults, clipExport: ClipExportModel? = nil, wall: @escaping @Sendable () -> Date = { Date() }) {
        self.archive = archive
        self.session = session
        self.defaults = defaults
        self.clipExport = clipExport
        self.wall = wall
        activity = TimelineActivityModel(archive: archive)
        // Live, at the preset the person used last (an hour the first time); `refresh` corrects it once the extents are known.
        let now = wall()
        timeline = TimelineModel(viewport: .live(duration: 3_600, now: now))
        timeline.select(ZoomPreset.stored(in: defaults), playhead: now, isLive: true, limits: TimelineLimits(oldest: now.addingTimeInterval(-86_400), now: now))
    }

    var hasRecordings: Bool { oldest != nil }
    var isCoarse: Bool { (typicalGOP ?? 0) > Self.coarseGOP }

    func limits(now: Date? = nil) -> TimelineLimits {
        let now = now ?? wall()
        return TimelineLimits(oldest: oldest ?? now.addingTimeInterval(-3_600), now: now)
    }

    /// The cameras the panel shows (their activity is combined). The session's cells are the owner's business.
    func setCameras(_ ids: [UUID]) {
        cameraIDs = ids
        activity.setCameras(ids)
        readExtents()
    }

    func setWidth(_ width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        activity.update(viewport: timeline.viewport, width: width)
    }

    /// The engine's storage pause as of the last `refresh`: when it goes from a pause to none, the drive is back and the session is told at once.
    @ObservationIgnored private var lastStoragePause: ArchivePause?

    /// About twice a second while the screen is visible: reads the extents, keeps the viewport where it belongs, asks for fresh activity, and lets
    /// the session look at the recordings drive again if it lost it (`storagePause` is `engine.nvrStorage?.pause`: nil means recording works).
    func refresh(storagePause: ArchivePause? = nil) {
        let driveBack = lastStoragePause != nil && storagePause == nil
        lastStoragePause = storagePause
        session.recheckDrive(driveBack: driveBack, driveMissing: storagePause == .folderMissing)
        let now = wall()
        readExtents()
        timeline.tick(now: now, playhead: session.position, limits: limits(now: now))
        activity.update(viewport: timeline.viewport, width: width)
        activity.catalogMayHaveChanged()
        refreshClipPreview()
    }

    private func readExtents() {
        let extents = cameraIDs.compactMap { archive.extent(camera: $0) }
        let oldest = extents.map(\.oldest).min()
        if oldest != self.oldest { self.oldest = oldest }
        let gop = extents.compactMap(\.typicalGOP).max()
        if gop != typicalGOP { typicalGOP = gop }
    }

    // MARK: Presets, zoom, pan

    var preset: ZoomPreset? { timeline.preset }

    func select(_ preset: ZoomPreset) {
        preset.store(in: defaults)
        let now = wall()
        timeline.select(preset, playhead: session.position, isLive: session.clock.isLive, limits: limits(now: now))
        activity.update(viewport: timeline.viewport, width: width)
    }

    func zoom(by factor: Double, aroundX x: CGFloat) {
        timeline.zoom(by: factor, aroundX: x, width: width, limits: limits())
        activity.update(viewport: timeline.viewport, width: width)
    }

    func pan(byPoints points: CGFloat) {
        timeline.pan(byPoints: points, width: width, limits: limits())
        activity.update(viewport: timeline.viewport, width: width)
    }

    // MARK: Scrubbing

    /// The time under `x`, within the recordings: not before the oldest, not after now.
    func time(atX x: CGFloat) -> Date {
        let now = wall()
        let raw = timeline.viewport.time(atX: x, width: width)
        return min(max(raw, oldest ?? raw), now)
    }

    func playheadX() -> CGFloat {
        timeline.viewport.x(for: session.position, width: width)
    }

    func beginScrub(atX x: CGFloat) {
        session.beginScrub()
        session.scrub(to: time(atX: x))
    }

    func scrub(toX x: CGFloat) { session.scrub(to: time(atX: x)) }

    /// Letting go plays on from there, or goes live near the live edge; while a clip is being chosen it stays where it is, paused: the playhead is the end.
    func endScrub() {
        if isChoosingClip { session.finishPausedScrub() } else { session.endScrub() }
    }

    /// Go Live: the cells return to live video and the viewport follows live again.
    func goLive() {
        session.goLive()
        let now = wall()
        timeline.select(timeline.preset ?? ZoomPreset.stored(in: defaults), playhead: now, isLive: true, limits: limits(now: now))
        activity.update(viewport: timeline.viewport, width: width)
    }

    /// The viewer opens at `start`: live, or at a time (paused or playing); a time outside the recordings is brought inside them.
    func apply(_ start: ViewerStart?) {
        guard let start, let time = start.time else { return }
        let target = min(max(time, oldest ?? time), wall())
        session.beginScrub()
        session.scrub(to: target)
        if start.playing {
            session.endScrub()
        } else {
            session.finishPausedScrub()
        }
        let now = wall()
        timeline.select(timeline.preset ?? ZoomPreset.stored(in: defaults), playhead: target, isLive: false, limits: limits(now: now))
        activity.update(viewport: timeline.viewport, width: width)
    }

    // MARK: Saving a clip

    /// A clip is being chosen: Save Clip set its start and the playhead is its end.
    var isChoosingClip: Bool { clipStart != nil }

    /// Why Save Clip cannot be used now, as a sentence; nil when it can.
    var saveClipUnavailableReason: String? {
        guard let clipExport else { return String(localized: "Clips are not available here.") }
        if clipExport.isBusy { return String(localized: "A clip is being saved.") }
        if !hasRecordings { return String(localized: "Nothing is recorded yet.") }
        return nil
    }

    /// Where the clip ends: the playhead, or the newest recorded moment while the picture is live.
    var clipEnd: Date { session.clock.isLive ? wall() : session.position }

    /// The clip as chosen now, both ends inside the recordings; nil when none is being chosen.
    var clipSelection: ClipSelection? {
        guard let clipStart else { return nil }
        let now = wall()
        return ClipSelection(start: clipStart, end: clipEnd, cameras: clipCameras).clamped(oldest: oldest ?? now, newest: now)
    }

    /// Every camera a clip can be made of; the choice keeps the cameras that are still there and, when it would be empty, takes them all.
    func setClipCameras(_ ids: [UUID]) {
        clipAvailable = ids
        let kept = clipCameras.filter(ids.contains)
        clipCameras = kept.isEmpty ? ids : kept
    }

    /// Save Clip (key C): the clip starts at the playhead; pressed again, it starts there instead.
    func beginClip() {
        guard saveClipUnavailableReason == nil else { return }
        clipExport?.dismissResult()
        clipStart = min(clipEnd, wall())
        if clipCameras.isEmpty { clipCameras = clipAvailable }
        clipPreview = nil
        clipPreviewKey = nil
        refreshClipPreview()
    }

    /// Cancel (Esc): the selection is dropped, nothing is written.
    func cancelClip() {
        clipStart = nil
        clipPreview = nil
        clipPreviewKey = nil
        clipPreviewTask?.cancel()
        clipPreviewTask = nil
    }

    func toggleClipCamera(_ id: UUID) {
        guard isChoosingClip, clipAvailable.contains(id) else { return }
        if let index = clipCameras.firstIndex(of: id) {
            guard clipCameras.count > 1 else { return }
            clipCameras.remove(at: index)
        } else {
            clipCameras = clipAvailable.filter { clipCameras.contains($0) || $0 == id }
        }
        refreshClipPreview()
    }

    func setAllClipCameras() {
        clipCameras = clipAvailable
        refreshClipPreview()
    }

    func includesInClip(_ id: UUID) -> Bool { clipCameras.contains(id) }

    /// Export Clip (Return): freezes the choice and saves it. A saved clip ends the choosing; a failed or cancelled one keeps it, so the person can try again.
    func exportClip() async {
        guard let clipExport, let selection = clipSelection, selection.isExportable, !clipExport.isBusy else { return }
        await clipExport.export(selection)
        if case .finished = clipExport.state { cancelClip() }
    }

    /// Asks the engine for the plan of the clip as it is now, a moment after it stops changing (about twice a second the panel looks; the plan reads
    /// fragment headers only).
    private func refreshClipPreview() {
        guard let clipExport, let selection = clipSelection else { return }
        var key = selection
        key.end = Date(timeIntervalSinceReferenceDate: (selection.end.timeIntervalSinceReferenceDate / 2).rounded() * 2)
        guard key != clipPreviewKey, !clipExport.isBusy else { return }
        clipPreviewKey = key
        clipPreviewTask?.cancel()
        clipPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let preview = await clipExport.preview(selection)
            guard !Task.isCancelled, let self, self.clipPreviewKey == key else { return }
            self.clipPreview = preview
        }
    }
}
