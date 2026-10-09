import BridgeEngine
import CameraAdapters
import Foundation
import Testing

/// The Overview's logic: which tiles are live (Play All, a tile's own button, the cap, what is on screen), the grid's columns,
/// the remembered preference, and the texts under a tile.
@MainActor @Suite(.timeLimit(.minutes(1))) struct OverviewModelTests {
    private func cameras(_ count: Int, offline: Set<Int> = []) -> [CameraStatus] {
        (0..<count).map { index in
            CameraStatus(id: UUID(), name: "Camera \(index + 1)", kind: .camera, vendor: .demo,
                         connection: offline.contains(index) ? .offline("down") : .online)
        }
    }

    private func overview(defaults: UserDefaults, source: FakeLiveSource, cap: Int = OverviewModel.maximumLiveTiles) -> OverviewModel {
        let model = OverviewModel(defaults: defaults, cap: cap, makeSink: { FakeLiveSink() }, open: source.opener)
        model.isPageVisible = true
        return model
    }

    /// The model's cameras, all scrolled into view.
    private func show(_ cameras: [CameraStatus], in model: OverviewModel) {
        model.update(cameras: cameras)
        for camera in cameras { model.setVisible(camera.id, true) }
    }

    // MARK: Plan

    @Test func theNinthLiveTileIsTheLastOne() {
        let ids = (0..<12).map { _ in UUID() }
        let plan = OverviewModel.plan(order: ids, visible: Set(ids), online: Set(ids), playAll: true, manual: [:], cap: OverviewModel.maximumLiveTiles)
        #expect(OverviewModel.maximumLiveTiles == 9)
        #expect(plan == Set(ids.prefix(9)), "the first nine in the grid's order")
    }

    @Test func onlyVisibleOnlineTilesThatWantToPlayAreLive() {
        let ids = (0..<5).map { _ in UUID() }
        let plan = OverviewModel.plan(order: ids, visible: [ids[0], ids[1], ids[2], ids[3]], online: [ids[0], ids[2], ids[3], ids[4]], playAll: true,
                                      manual: [ids[3]: false], cap: 9)
        #expect(plan == [ids[0], ids[2]], "ids[1] is offline, ids[3] was paused, ids[4] is scrolled away")
        let alone = OverviewModel.plan(order: ids, visible: Set(ids), online: Set(ids), playAll: false, manual: [ids[1]: true], cap: 9)
        #expect(alone == [ids[1]], "a tile's own play button works without Play All")
        #expect(OverviewModel.plan(order: ids, visible: Set(ids), online: Set(ids), playAll: false, manual: [:], cap: 9).isEmpty)
    }

    @Test func aTileThatChoseToPlayAlsoCountsAgainstTheCap() {
        let ids = (0..<4).map { _ in UUID() }
        let plan = OverviewModel.plan(order: ids, visible: Set(ids), online: Set(ids), playAll: false, manual: Dictionary(uniqueKeysWithValues: ids.map { ($0, true) }), cap: 2)
        #expect(plan == Set(ids.prefix(2)))
    }

    @Test func theGridHasTwoToFourColumnsByWidth() {
        #expect(OverviewModel.columns(forWidth: 560) == 2, "never fewer than two")
        #expect(OverviewModel.columns(forWidth: 739) == 2, "the narrowest window")
        #expect(OverviewModel.columns(forWidth: 872) == 3)
        #expect(OverviewModel.columns(forWidth: 1_239) == 4)
        #expect(OverviewModel.columns(forWidth: 3_000) == 4, "never more than four")
    }

    // MARK: Model

    @Test func tilesShowSnapshotsUntilPlayAllIsSwitchedOnAndThePreferenceIsRemembered() async {
        let scratch = ScratchDefaults()
        let source = FakeLiveSource()
        let model = overview(defaults: scratch.defaults, source: source)
        let list = cameras(3)
        show(list, in: model)
        #expect(!model.playAll && model.liveCount == 0 && source.opens.isEmpty)

        model.playAll = true
        #expect(await settles { source.opens.count == 3 })
        #expect(source.opens.allSatisfy { $0.stream == .sub && !$0.audio }, "grid tiles read the sub stream, without sound")
        #expect(model.liveCount == 3)
        #expect(scratch.defaults.bool(forKey: OverviewModel.playAllKey))

        let reopened = overview(defaults: scratch.defaults, source: FakeLiveSource())
        #expect(reopened.playAll, "remembered across launches")

        model.playAll = false
        #expect(await settles { source.openCount == 0 })
        #expect(!scratch.defaults.bool(forKey: OverviewModel.playAllKey))
    }

    @Test func atMostNineTilesAreLiveAndTheRestStayAsSnapshots() async {
        let scratch = ScratchDefaults()
        let source = FakeLiveSource()
        let model = overview(defaults: scratch.defaults, source: source)
        let list = cameras(12)
        show(list, in: model)
        model.playAll = true
        #expect(await settles { source.opens.count == 9 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(source.opens.count == 9 && model.liveCount == 9)
        let live = Set(source.opens.map(\.camera))
        #expect(live == Set(list.prefix(9).map(\.id)))
        model.stopAll()
        #expect(await settles { source.openCount == 0 })
    }

    @Test func aTileScrolledOutOfViewStopsAndReleasesItsStream() async {
        let scratch = ScratchDefaults()
        let source = FakeLiveSource()
        let model = overview(defaults: scratch.defaults, source: source)
        let list = cameras(3)
        show(list, in: model)
        model.playAll = true
        #expect(await settles { source.openCount == 3 })

        model.setVisible(list[2].id, false)
        #expect(await settles { source.openCount == 2 }, "the lease of the tile that left the screen is released")
        #expect(model.feeds[list[2].id]?.isWanted == false && model.liveCount == 2)
        model.setVisible(list[2].id, true)
        #expect(await settles { source.openCount == 3 }, "and taken again when it scrolls back")
        model.stopAll()
    }

    @Test func nothingPlaysWhileThePageOrTheWindowCannotBeSeen() async {
        let scratch = ScratchDefaults()
        let source = FakeLiveSource()
        let model = overview(defaults: scratch.defaults, source: source)
        show(cameras(2), in: model)
        model.playAll = true
        #expect(await settles { source.openCount == 2 })

        model.isWindowVisible = false   // minimised, covered, or the app hidden
        #expect(await settles { source.openCount == 0 })
        model.isWindowVisible = true
        #expect(await settles { source.openCount == 2 })

        model.isPageVisible = false   // another page, or the viewer covers it
        #expect(await settles { source.openCount == 0 })
        model.isPageVisible = true
        #expect(await settles { source.openCount == 2 })
        model.stopAll()
        #expect(await settles { source.openCount == 0 })
    }

    @Test func aTilesOwnButtonOverridesPlayAllForThatTileOnly() async {
        let scratch = ScratchDefaults()
        let source = FakeLiveSource()
        let model = overview(defaults: scratch.defaults, source: source)
        let list = cameras(3)
        show(list, in: model)
        model.toggle(list[1].id)   // snapshots: play one tile
        #expect(await settles { source.openCount == 1 })
        #expect(source.opens.first?.camera == list[1].id)

        model.playAll = true       // the toggle speaks for every tile again
        #expect(await settles { source.openCount == 3 })
        model.toggle(list[0].id)   // pause one tile while Play All is on
        #expect(await settles { source.openCount == 2 })
        #expect(model.feeds[list[0].id]?.isWanted == false)
        model.stopAll()
    }

    @Test func offlineCamerasAreNeverLeasedAndStartWhenTheyComeBack() async {
        let scratch = ScratchDefaults()
        let source = FakeLiveSource()
        let model = overview(defaults: scratch.defaults, source: source)
        var list = cameras(2, offline: [1])
        show(list, in: model)
        model.playAll = true
        #expect(await settles { source.openCount == 1 })
        #expect(source.opens.map(\.camera) == [list[0].id])

        list[1].connection = .online
        model.update(cameras: list)
        #expect(await settles { source.openCount == 2 })
        model.stopAll()
    }

    @Test func aRemovedCameraEndsItsFeed() async {
        let scratch = ScratchDefaults()
        let source = FakeLiveSource()
        let model = overview(defaults: scratch.defaults, source: source)
        let list = cameras(2)
        show(list, in: model)
        model.playAll = true
        #expect(await settles { source.openCount == 2 })
        model.update(cameras: [list[0]])
        #expect(await settles { source.openCount == 1 })
        #expect(model.feeds[list[1].id] == nil)
        model.stopAll()
    }

    // MARK: Texts

    @Test func overlaysSayWhyAPictureIsNotLive() {
        #expect(LiveOverlay.current(connection: .online, phase: .stopped, isWanted: false) == .none)
        #expect(LiveOverlay.current(connection: .online, phase: .live, isWanted: true) == .none)
        #expect(LiveOverlay.current(connection: .online, phase: .connecting, isWanted: true) == .connecting)
        #expect(LiveOverlay.current(connection: .online, phase: .stalled, isWanted: true) == .reconnecting)
        #expect(LiveOverlay.current(connection: .online, phase: .unavailable, isWanted: true) == .offline)
        #expect(LiveOverlay.current(connection: .offline("down"), phase: .stopped, isWanted: false) == .offline, "also on a snapshot")
        #expect(LiveOverlay.current(connection: .connecting, phase: .stopped, isWanted: false) == .connecting)
        #expect(LiveOverlay.current(connection: .disabled, phase: .stopped, isWanted: false) == .disabled)
        #expect(LiveOverlay.offline.title == "Offline" && LiveOverlay.none.title == nil)
    }

    @Test func tileTextsFollowTheCamerasState() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var status = CameraStatus(id: UUID(), name: "Driveway", kind: .camera, vendor: .hikvision, connection: .online)
        #expect(OverviewTileText.lastMotion(in: status) == nil)
        #expect(OverviewTileText.motionLine(status, now: now) == "No motion yet")
        #expect(OverviewTileText.recordingLine(status) == "Not recording")

        status.recentEvents = [CameraEventRecord(name: "Motion", date: now.addingTimeInterval(-3_600)), CameraEventRecord(name: "Person", date: now.addingTimeInterval(-60)),
                               CameraEventRecord(name: "Motion", date: now.addingTimeInterval(-300))]
        #expect(OverviewTileText.lastMotion(in: status) == now.addingTimeInterval(-300), "the newest motion, not the newest event")
        #expect(OverviewTileText.motionLine(status, now: now).hasPrefix("Motion "))
        status.motionActive = true
        #expect(OverviewTileText.motionLine(status, now: now) == "Motion now")

        status.recordingEnabled = true
        #expect(OverviewTileText.recording(status) == .armed && OverviewTileText.recordingLine(status) == "Records on motion")
        status.recordingNow = true
        #expect(OverviewTileText.recording(status) == .recording && OverviewTileText.recordingLine(status) == "Recording now")
    }

    @Test func theLiveViewTileCountsHomeKitAndAppViewersApart() {
        func status(home: Int, app: Int) -> CameraStatus {
            CameraStatus(id: UUID(), name: "Driveway", kind: .camera, vendor: .hikvision, connection: .online, liveViewers: home, appViewers: app)
        }
        #expect(StatusText.viewersValue(status(home: 0, app: 0)) == "No viewers" && StatusText.viewersDetail(status(home: 0, app: 0)) == "Nobody is watching right now")
        #expect(StatusText.viewersValue(status(home: 1, app: 0)) == "1 viewer" && StatusText.viewersDetail(status(home: 1, app: 0)) == "Watching in the Home app")
        #expect(StatusText.viewersDetail(status(home: 0, app: 1)) == "1 viewer in Camera Bridge")
        #expect(StatusText.viewersDetail(status(home: 0, app: 2)) == "2 viewers in Camera Bridge")
        #expect(StatusText.viewersValue(status(home: 2, app: 1)) == "3 viewers")
        #expect(StatusText.viewersDetail(status(home: 2, app: 1)) == "2 in the Home app · 1 in Camera Bridge")
    }

    @Test func qualityMapsToStreamsAndSnapshotsAreNamedByCameraAndTime() {
        #expect(LiveQuality.allCases.map(\.stream) == [.automatic, .main, .sub])
        var status = CameraStatus(id: UUID(), name: "Driveway", kind: .camera, vendor: .hikvision)
        status.mainStreamInfo = SourceStreamInfo(codec: "h264", width: 2688, height: 1520, fps: 20)
        status.subStreamInfo = SourceStreamInfo(codec: "h264", width: 640, height: 360, fps: 15)
        #expect(LiveQuality.caption(stream: .main, status: status) == "Main stream · 2688×1520")
        #expect(LiveQuality.caption(stream: .sub, status: status) == "Sub stream · 640×360")
        #expect(LiveQuality.caption(stream: nil, status: status) == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(SnapshotFileName.make(cameraName: "Driveway", date: date, calendar: calendar) == "Driveway 2026-10-03 at 04.00.00.jpg")
        #expect(SnapshotFileName.make(cameraName: "Front/Door: A", date: date, calendar: calendar).hasPrefix("Front-Door- A "), "no path separators")
        #expect(SnapshotFileName.make(cameraName: "  ", date: date, calendar: calendar).hasPrefix("Camera "))
    }
}
