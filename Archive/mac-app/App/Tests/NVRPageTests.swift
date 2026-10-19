import BridgeEngine
import CameraAdapters
import CoreGraphics
import Foundation
import Testing

@Suite struct NVRGridTests {
    @Test func theColumnsAreWhateverGivesTheLargestSixteenByNineTiles() {
        let wide = CGSize(width: 1_600, height: 800), tall = CGSize(width: 600, height: 1_400), square = CGSize(width: 900, height: 900)
        #expect(NVRGrid.fit(count: 1, available: wide).columns == 1)
        #expect(NVRGrid.fit(count: 2, available: wide).columns == 2, "side by side in a wide window")
        #expect(NVRGrid.fit(count: 2, available: tall).columns == 1, "stacked in a tall one")
        #expect(NVRGrid.fit(count: 4, available: wide) == NVRGrid.fit(count: 4, available: wide))
        #expect(NVRGrid.fit(count: 4, available: square).columns == 2 && NVRGrid.fit(count: 4, available: square).rows == 2)
        #expect(NVRGrid.fit(count: 9, available: wide).columns == 3 && NVRGrid.fit(count: 9, available: wide).rows == 3)
        let five = NVRGrid.fit(count: 5, available: wide)
        #expect(five.columns <= 3 && five.columns * five.rows >= 5)
        #expect(NVRGrid.fit(count: 7, available: tall).columns <= NVRGrid.maximumColumns)
    }

    @Test func everyTileIsSixteenByNineAndTheGridFitsTheRoom() {
        for count in 1...9 {
            for available in [CGSize(width: 1_100, height: 560), CGSize(width: 1_700, height: 760), CGSize(width: 700, height: 900)] {
                let fit = NVRGrid.fit(count: count, available: available)
                #expect(abs(fit.tileSize.width / fit.tileSize.height - 16.0 / 9) < 0.001)
                #expect(fit.tileSize.width * CGFloat(fit.columns) + NVRGrid.spacing * CGFloat(fit.columns - 1) <= available.width + 0.5, "\(count) in \(available)")
                #expect(fit.tileSize.height * CGFloat(fit.rows) + NVRGrid.spacing * CGFloat(fit.rows - 1) <= available.height + 0.5, "\(count) in \(available)")
            }
        }
    }

    @Test func moreThanNineAreNeverOnOnePageAndNoneMeansOne() {
        #expect(NVRGrid.fit(count: 12, available: CGSize(width: 1_600, height: 900)).columns <= 3)
        let none = NVRGrid.fit(count: 0, available: CGSize(width: 1_600, height: 900))
        #expect(none.columns == 1 && none.tileSize.width > 0)
    }
}

@MainActor @Suite struct NVRTileStateTests {
    private func state(_ coverage: CellCoverage, shows: Bool = false, recording: ArchiveRecordingState = .recording, overlay: LiveOverlay = .none,
                       requested: Date? = nil) -> NVRTileState {
        NVRTileState.make(coverage: coverage, showsPicture: shows, recording: recording, overlay: overlay, requested: requested)
    }

    @Test func aTileShowsAPictureUnlessSomethingIsToBeSaid() {
        #expect(state(.recorded, shows: true) == .none && state(.live) == .none)
        #expect(state(.loading) == .loading && state(.loading, shows: true) == .none, "a picture that is there stays, whatever is loading")
        #expect(state(.live, overlay: .offline) == .live(.offline) && state(.live, overlay: .connecting) == .live(.connecting))
    }

    @Test func noRecordingNamesTheTimeAndTheNextRecordingOrSaysRecordingIsOff() {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000), next = at.addingTimeInterval(600)
        #expect(state(.noRecording(next: next, recordingOff: false), requested: at) == .noRecording(at: at, next: next))
        #expect(state(.noRecording(next: nil, recordingOff: false), requested: at) == .noRecording(at: at, next: nil))
        #expect(state(.noRecording(next: nil, recordingOff: false), recording: .off) == .recordingOff, "nothing newer and Record is off")
        #expect(state(.noRecording(next: next, recordingOff: false), recording: .off, requested: at) == .noRecording(at: at, next: next), "older footage exists: a gap, not 'off'")
        #expect(state(.noRecording(next: nil, recordingOff: true)) == .recordingOff)
    }

    @Test func driveTroubleAndDamageHaveTheirOwnWords() {
        #expect(state(.driveMissing) == .driveMissing && state(.unreadable) == .unreadable)
        #expect(NVRTileState.driveMissing.title == "The recordings drive isn’t connected")
        #expect(NVRTileState.unreadable.title == "Can’t play this recording")
        #expect(NVRTileState.recordingOff.title == "Recording is off for this camera")
        #expect(NVRTileState.none.title == nil && NVRTileState.loading.title == "Loading…")
        #expect(NVRTileState.live(.offline).title == "Offline")
    }

    @Test func theDetailLineGivesTimesInTheViewersOwnZone() {
        let zone = TimeZone(identifier: "UTC") ?? .gmt, english = Locale(identifier: "en_GB")
        let at = Date(timeIntervalSince1970: 1_760_099_000), next = at.addingTimeInterval(125)
        let both = NVRTileState.noRecording(at: at, next: next).detail(timeZone: zone, locale: english)
        #expect(both?.contains("12:23:20") == true && both?.contains("12:25:25") == true, "\(both ?? "nil")")
        #expect(NVRTileState.noRecording(at: at, next: nil).detail(timeZone: zone, locale: english)?.contains("12:23:20") == true)
        #expect(NVRTileState.noRecording(at: nil, next: nil).detail() == nil && NVRTileState.loading.detail() == nil)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct NVRPageModelTests {
    private func statuses(_ count: Int) -> [CameraStatus] {
        (0..<count).map { CameraStatus(id: UUID(), name: "Camera \($0)", kind: .camera, vendor: .rtsp, connection: $0 % 3 == 2 ? .offline("No answer") : .online) }
    }

    private func model(cameras: [CameraStatus], saved: [UUID] = []) -> (NVRPageModel, SessionHarness, ScratchDefaults) {
        let harness = SessionHarness(cameraCount: 0, withLive: false)
        let scratch = ScratchDefaults()
        if !saved.isEmpty { scratch.defaults.set(saved.map(\.uuidString), forKey: OverviewModel.orderKey) }
        let panel = NVRPanelModel(archive: harness.archive, session: harness.session, defaults: scratch.defaults, wall: harness.wallClosure)
        let model = NVRPageModel(panel: panel, defaults: scratch.defaults)
        model.update(cameras: cameras)
        return (model, harness, scratch)
    }

    @Test func nineCamerasToAPageInTheOverviewsOrderEveryOneWhateverItsConnection() {
        let cameras = statuses(11)
        let saved = Array(cameras.reversed().prefix(3)).map(\.id)   // the person dragged the last three to the front
        let (model, _, scratch) = model(cameras: cameras, saved: saved)
        _ = scratch
        #expect(model.pageCount == 2 && model.pageCameras.count == 9)
        #expect(model.pageCameras.prefix(3).map(\.id) == saved, "the Overview's saved order, read and never written")
        #expect(model.pageCameras.contains { if case .offline = $0.connection { true } else { false } }, "recorded footage needs no connection")
        #expect(model.session.cells.map(\.cameraID) == model.pageCameras.map(\.id))
        model.nextPage()
        #expect(model.page == 1 && model.pageCameras.count == 2 && model.session.cells.count == 2 && !model.canGoForward && model.canGoBack)
        model.nextPage()
        #expect(model.page == 1)
        model.previousPage()
        #expect(model.page == 0 && model.session.cells.count == 9)
        #expect(scratch.defaults.stringArray(forKey: OverviewModel.orderKey) == saved.map(\.uuidString))
        model.stopAll()
    }

    @Test func aPageThatNoLongerExistsIsLeftWhenCamerasGo() {
        let cameras = statuses(11)
        let (model, _, scratch) = model(cameras: cameras)
        _ = scratch
        model.nextPage()
        model.update(cameras: Array(cameras.prefix(4)))
        #expect(model.page == 0 && model.pageCount == 1 && model.session.cells.count == 4)
        model.stopAll()
    }

    @Test func theHoveredTileGetsTheExactFrameFirstAndIsForgottenWhenItLeavesThePage() {
        let cameras = statuses(11)
        let (model, _, scratch) = model(cameras: cameras)
        _ = scratch
        let third = model.pageCameras[2].id
        model.hovered = third
        #expect(model.session.focused == third && model.session.ordered().first?.cameraID == third)
        model.nextPage()
        #expect(model.hovered == nil && model.session.focused == nil)
        model.stopAll()
    }

    @Test func theViewerCoveringThePageSuspendsItAndUncoveringBringsItBack() {
        let cameras = statuses(3)
        let (model, harness, scratch) = model(cameras: cameras)
        _ = scratch
        model.session.beginScrub()
        model.session.scrub(to: harness.wallStart.addingTimeInterval(-7_200))
        model.session.endScrub()
        model.setCovered(true)
        #expect(model.isCovered && model.session.isSuspended && harness.clock.state.mode == .paused, "the clock holds at its position")
        model.setCovered(true)
        model.setCovered(false)
        #expect(!model.session.isSuspended && model.session.cells.count == 3 && harness.clock.state.mode == .paused, "back without playing")
        model.stopAll()
    }

    @Test func aTileOpensTheViewerAtThePagesPositionAndLiveOpensLive() {
        let cameras = statuses(2)
        let (model, harness, scratch) = model(cameras: cameras)
        _ = scratch
        #expect(model.start(forTile: cameras[0].id) == ViewerStart(time: nil, playing: false), "the page is live: the viewer is live")
        let target = harness.wallStart.addingTimeInterval(-7_200)
        model.session.beginScrub()
        model.session.scrub(to: target)
        #expect(model.start(forTile: cameras[0].id) == ViewerStart(time: target, playing: false))
        model.session.endScrub()
        #expect(model.start(forTile: cameras[0].id).time == target && model.start(forTile: cameras[0].id).playing)
        model.stopAll()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct NVRPanelModelTests {
    private func panel(_ harness: SessionHarness, scratch: ScratchDefaults) -> NVRPanelModel {
        let panel = NVRPanelModel(archive: harness.archive, session: harness.session, defaults: scratch.defaults, wall: harness.wallClosure)
        harness.session.setCameras(harness.cameras)
        panel.setCameras(harness.cameras)
        panel.setWidth(1_000)
        return panel
    }

    @Test func theExtentsDecideWhetherAnythingIsRecordedAndTheLimits() {
        let harness = SessionHarness(cameraCount: 2, withLive: false)
        let scratch = ScratchDefaults()
        let panel = panel(harness, scratch: scratch)
        #expect(panel.hasRecordings && panel.oldest == harness.timelines[0].start)
        #expect(panel.limits().oldest == harness.timelines[0].start && panel.limits().now == harness.wallNow)
        let empty = NVRPanelModel(archive: harness.archive, session: harness.session, defaults: scratch.defaults, wall: harness.wallClosure)
        empty.setCameras([UUID()])
        #expect(!empty.hasRecordings, "a camera with no recording: the timeline is disabled and the viewer stays live")
        harness.session.stopAll()
    }

    @Test func theEnginesStoragePauseClearingAsksTheHeldSessionToReadAgainAtOnce() async {
        let harness = SessionHarness(cameraCount: 1, withLive: false)
        let scratch = ScratchDefaults()
        let panel = panel(harness, scratch: scratch)
        harness.session.beginScrub()
        harness.session.scrub(to: harness.date(8.0))
        harness.session.endScrub()
        await harness.until(advancing: false) { harness.sink(0).displayed.count >= 2 }
        harness.time.advance(by: 1.0)
        harness.source.failEverything(with: ArchiveError.fileGone)
        await harness.until { harness.session.driveHold != nil }
        #expect(harness.session.driveHold != nil && harness.clock.state.mode == .paused)
        await harness.settle()                                                 // the still that the hold asked for is read, and fails again: the drive is still gone
        harness.source.failEverything(with: nil)
        panel.refresh(storagePause: .folderMissing)                           // the engine still says the folder is missing
        await harness.settle()
        #expect(harness.session.driveHold != nil, "no hurry: the retry period has not passed")
        panel.refresh(storagePause: nil)                                      // the engine says recording works again: ask now
        await harness.until { harness.clock.isPlaying }
        #expect(harness.clock.isPlaying && harness.session.driveHold == nil)
        harness.session.stopAll()
    }

    @Test func thePresetIsRememberedAndTheTimelineStartsLive() {
        let harness = SessionHarness(cameraCount: 1, withLive: false)
        let scratch = ScratchDefaults()
        let panel = panel(harness, scratch: scratch)
        #expect(panel.timeline.preset == .hour && panel.timeline.followsLive, "an hour the first time")
        panel.select(.sixHours)
        #expect(panel.timeline.viewport.duration == 21_600 && ZoomPreset.stored(in: scratch.defaults) == .sixHours)
        let again = NVRPanelModel(archive: harness.archive, session: harness.session, defaults: scratch.defaults, wall: harness.wallClosure)
        #expect(again.timeline.preset == .sixHours, "and the next screen opens on it")
        harness.session.stopAll()
    }

    @Test func aPointOnTheTrackIsATimeWithinTheRecordings() {
        let harness = SessionHarness(cameraCount: 1, withLive: false)
        let scratch = ScratchDefaults()
        let panel = panel(harness, scratch: scratch)
        panel.select(.day)
        let viewport = panel.timeline.viewport
        #expect(panel.time(atX: 500) == viewport.time(atX: 500, width: 1_000).clamped(low: panel.oldest, high: harness.wallNow))
        #expect(panel.time(atX: -200) == panel.oldest, "left of the oldest recording: the oldest")
        #expect(panel.time(atX: 5_000) == harness.wallNow, "right of now: now")
        harness.session.stopAll()
    }

    @Test func draggingScrubsAndReleaseGoesOnPlayingOrLive() {
        let harness = SessionHarness(cameraCount: 1, withLive: false)
        let scratch = ScratchDefaults()
        let panel = panel(harness, scratch: scratch)
        panel.select(.day)
        panel.beginScrub(atX: 400)
        panel.scrub(toX: 420)
        #expect(harness.clock.state.mode == .paused && harness.clock.position() == panel.time(atX: 420))
        panel.endScrub()
        #expect(harness.clock.isPlaying || harness.clock.isLive)
        panel.goLive()
        #expect(harness.clock.isLive && panel.timeline.followsLive)
        harness.session.stopAll()
    }

    @Test func theViewerOpensLiveOrAtATimeInsideTheRecordings() {
        let harness = SessionHarness(cameraCount: 1, withLive: false)
        let scratch = ScratchDefaults()
        let panel = panel(harness, scratch: scratch)
        panel.apply(nil)
        panel.apply(ViewerStart(time: nil, playing: false))
        #expect(harness.clock.isLive)
        let inside = harness.timelines[0].start.addingTimeInterval(40)
        panel.apply(ViewerStart(time: inside, playing: true))
        #expect(harness.clock.isPlaying && harness.clock.state.wall == inside && !panel.timeline.followsLive)
        panel.apply(ViewerStart(time: harness.timelines[0].start.addingTimeInterval(-9_999), playing: false))
        #expect(harness.clock.state.mode == .paused && harness.clock.position() == harness.timelines[0].start, "before the oldest: the oldest")
        harness.session.stopAll()
    }

    @Test func aLongGroupOfPicturesIsCalledCoarse() {
        let harness = SessionHarness(cameraCount: 1, withLive: false)
        let scratch = ScratchDefaults()
        let panel = panel(harness, scratch: scratch)
        #expect(!panel.isCoarse, "the fake archive does not know the interval")
        #expect(NVRPanelModel.coarseGOP == 4)
        harness.session.stopAll()
    }
}

extension Date {
    fileprivate func clamped(low: Date?, high: Date) -> Date { Swift.min(Swift.max(self, low ?? self), high) }
}
