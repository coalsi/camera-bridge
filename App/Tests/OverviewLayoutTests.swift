import BridgeEngine
import CameraAdapters
import CoreGraphics
import Foundation
import Testing

/// The Overview's layout controls: presets and a custom grid, pages, the tiles' size for the room they have, the order the
/// person dragged them into, hidden offline cameras, what is remembered, and that only the showing page plays.
@MainActor @Suite(.timeLimit(.minutes(1))) struct OverviewLayoutTests {
    private func cameras(_ count: Int, offline: Set<Int> = []) -> [CameraStatus] {
        (0..<count).map { index in
            CameraStatus(id: UUID(), name: "Camera \(index + 1)", kind: .camera, vendor: .demo, connection: offline.contains(index) ? .offline("down") : .online)
        }
    }

    private func overview(defaults: UserDefaults, source: FakeLiveSource = FakeLiveSource(), cap: Int = OverviewModel.maximumLiveTiles) -> OverviewModel {
        let model = OverviewModel(defaults: defaults, cap: cap, makeSink: { FakeLiveSink() }, open: source.opener)
        model.isPageVisible = true
        return model
    }

    // MARK: Layout

    @Test func thePresetsAreAutoAndSquareGridsAndACustomOneIsClamped() {
        #expect(OverviewLayout().grid == nil && OverviewLayout().perPage == nil && OverviewLayout().title == "Auto")
        #expect(OverviewLayout(mode: .grid1).grid?.columns == 1 && OverviewLayout(mode: .grid1).perPage == 1)
        #expect(OverviewLayout(mode: .grid2).perPage == 4 && OverviewLayout(mode: .grid3).perPage == 9 && OverviewLayout(mode: .grid4).perPage == 16)
        let custom = OverviewLayout(mode: .custom, customColumns: 5, customRows: 2)
        #expect(custom.grid?.columns == 5 && custom.grid?.rows == 2 && custom.perPage == 10 && custom.title == "Custom 5×2")
        let clamped = OverviewLayout(mode: .custom, customColumns: 0, customRows: 9)
        #expect(clamped.grid?.columns == 1 && clamped.grid?.rows == 6, "columns and rows run from 1 to 6")
        #expect(OverviewLayout(mode: .grid3).title == "3×3")
    }

    @Test func commandOneToFourPickTheSquarePresets() {
        #expect(OverviewLayout.forShortcut(1)?.mode == .grid1 && OverviewLayout.forShortcut(2)?.mode == .grid2)
        #expect(OverviewLayout.forShortcut(3)?.mode == .grid3 && OverviewLayout.forShortcut(4)?.mode == .grid4)
        #expect(OverviewLayout.forShortcut(5) == nil && OverviewLayout.forShortcut(0) == nil)
    }

    // MARK: Paging

    @Test func pagesHoldAsManyTilesAsTheGridHas() {
        #expect(OverviewPaging.pageCount(items: 8, perPage: 4) == 2 && OverviewPaging.pageCount(items: 9, perPage: 4) == 3)
        #expect(OverviewPaging.pageCount(items: 0, perPage: 4) == 1 && OverviewPaging.pageCount(items: 8, perPage: nil) == 1)
        #expect(OverviewPaging.slice(Array(1...9), page: 0, perPage: 4) == [1, 2, 3, 4])
        #expect(OverviewPaging.slice(Array(1...9), page: 2, perPage: 4) == [9])
        #expect(OverviewPaging.slice(Array(1...9), page: 7, perPage: 4) == [9], "a page past the end is the last")
        #expect(OverviewPaging.slice(Array(1...9), page: 3, perPage: nil) == Array(1...9))
        #expect(OverviewPaging.clamp(page: -2, count: 3) == 0 && OverviewPaging.clamp(page: 5, count: 3) == 2)
    }

    @Test func theModelPagesThroughTheCamerasAndRemembersThePage() {
        let scratch = ScratchDefaults()
        let model = overview(defaults: scratch.defaults)
        let list = cameras(8)
        model.update(cameras: list)
        model.layout = OverviewLayout(mode: .grid2)
        #expect(model.pageCount == 2 && model.page == 0 && !model.canGoBack && model.canGoForward)
        #expect(model.pageCameras.map(\.id) == list.prefix(4).map(\.id))
        model.nextPage()
        #expect(model.page == 1 && model.pageDirection == 1 && model.pageCameras.map(\.id) == list.suffix(4).map(\.id))
        model.nextPage()
        #expect(model.page == 1, "there is no page 3")
        model.previousPage()
        #expect(model.page == 0 && model.pageDirection == -1)
        model.goToPage(1)
        let reopened = overview(defaults: scratch.defaults)
        #expect(reopened.layout.mode == .grid2 && reopened.page == 1, "layout and page are remembered")
        reopened.update(cameras: list)
        #expect(reopened.page == 1 && reopened.pageCameras.count == 4)
        // Fewer cameras than the remembered page needs: back to the last page there is.
        reopened.update(cameras: Array(list.prefix(3)))
        #expect(reopened.page == 0)
    }

    @Test func aBiggerGridDropsThePagesItNoLongerNeeds() {
        let model = overview(defaults: ScratchDefaults().defaults)
        model.update(cameras: cameras(8))
        model.layout = OverviewLayout(mode: .grid2)
        model.goToPage(1)
        model.layout = OverviewLayout(mode: .grid3)
        #expect(model.pageCount == 1 && model.page == 0 && model.pageCameras.count == 8)
        model.layout = OverviewLayout()
        #expect(model.pageCount == 1 && model.pageCameras.count == 8, "Auto scrolls one long page")
    }

    // MARK: Tile size

    @Test func fittingTilesIntoTheWindowKeepsThemSixteenByNine() {
        // 2×2 in a roomy window: the width is the limit.
        let roomy = OverviewGridMetrics.fit(available: CGSize(width: 1_200, height: 900), columns: 2, rows: 2)
        #expect(roomy.density == .full && roomy.spacing == 16)
        #expect(abs(roomy.tileWidth - (1_200 - 16) / 2) < 0.5 || abs(roomy.tileHeight * 2 + 16 - 900) < 0.5)
        #expect(abs(roomy.pictureHeight - roomy.tileWidth * 9 / 16) < 0.01)
        #expect(roomy.tileWidth * 2 + 16 <= 1_200.5 && roomy.tileHeight * 2 + 16 <= 900.5, "it fits, with no scrolling")
        // A short, wide window: the height is the limit and the grid is narrower than the window.
        let wide = OverviewGridMetrics.fit(available: CGSize(width: 1_800, height: 500), columns: 2, rows: 2)
        #expect(wide.tileHeight * 2 + wide.spacing <= 500.5 && wide.tileWidth * 2 + wide.spacing < 1_800)
        // 1×1 is one big tile.
        let single = OverviewGridMetrics.fit(available: CGSize(width: 1_000, height: 700), columns: 1, rows: 1)
        #expect(single.density == .full && single.tileHeight <= 700.5 && single.tileWidth <= 1_000.5)
    }

    @Test func theInfoAreaShrinksToOneLineAndThenGoesAsTilesGetSmall() {
        func density(_ columns: Int, _ rows: Int, _ width: CGFloat, _ height: CGFloat) -> OverviewGridMetrics.Density {
            OverviewGridMetrics.fit(available: CGSize(width: width, height: height), columns: columns, rows: rows).density
        }
        #expect(density(2, 2, 1_100, 900) == .full)
        #expect(density(3, 3, 1_100, 900) == .full, "about 322 wide: still room for everything")
        #expect(density(3, 3, 1_100, 800) == .compact, "256 high a tile: the name only")
        #expect(density(4, 4, 1_100, 800) == .compact)
        #expect(density(4, 4, 1_100, 560) == .hidden, "132 high a tile: just the picture")
        #expect(density(6, 6, 1_100, 800) == .hidden)
        // The info area never makes a tile overflow its room.
        for (columns, rows, width, height) in [(3, 3, 1_100.0, 900.0), (4, 4, 1_100, 800), (6, 6, 900, 700), (1, 2, 500, 900), (5, 1, 1_400, 400)] {
            let fit = OverviewGridMetrics.fit(available: CGSize(width: width, height: height), columns: columns, rows: rows)
            #expect(fit.tileWidth * CGFloat(columns) + fit.spacing * CGFloat(columns - 1) <= width + 0.5, "\(columns)×\(rows) fits the width")
            #expect(fit.tileHeight * CGFloat(rows) + fit.spacing * CGFloat(rows - 1) <= height + 0.5, "\(columns)×\(rows) fits the height")
        }
        #expect(OverviewGridMetrics.spacing(columns: 4, rows: 4) < OverviewGridMetrics.spacing(columns: 2, rows: 2))
    }

    // MARK: Order

    @Test func draggedTilesTakeTheirTargetsPlaceAndNewCamerasFollow() {
        let list = cameras(5)
        let ids = list.map(\.id)
        #expect(OverviewOrdering.moving(ids[0], onto: ids[2], in: ids) == [ids[1], ids[2], ids[0], ids[3], ids[4]])
        #expect(OverviewOrdering.moving(ids[4], onto: ids[1], in: ids) == [ids[0], ids[4], ids[1], ids[2], ids[3]])
        #expect(OverviewOrdering.moving(ids[1], onto: ids[1], in: ids) == ids)
        #expect(OverviewOrdering.moving(UUID(), onto: ids[1], in: ids) == ids)
        let saved = [ids[3], UUID(), ids[0]]
        #expect(OverviewOrdering.arrange(list, saved: saved).map(\.id) == [ids[3], ids[0], ids[1], ids[2], ids[4]], "unknown ids are dropped, new cameras follow")
        #expect(OverviewOrdering.arrange(list, saved: []).map(\.id) == ids)
    }

    @Test func theOrderIsRememberedAndDrivesWhatEachPageShows() {
        let scratch = ScratchDefaults()
        let model = overview(defaults: scratch.defaults)
        let list = cameras(6)
        model.update(cameras: list)
        model.layout = OverviewLayout(mode: .grid2)
        model.move(list[5].id, onto: list[0].id)
        #expect(model.pageCameras.map(\.id) == [list[5].id, list[0].id, list[1].id, list[2].id])
        let reopened = overview(defaults: scratch.defaults)
        reopened.update(cameras: list)
        reopened.layout = OverviewLayout(mode: .grid2)
        #expect(reopened.arrangedCameras.map(\.id).first == list[5].id)
    }

    @Test func offlineCamerasCanBeHiddenAndThePreferenceIsRemembered() {
        let scratch = ScratchDefaults()
        let model = overview(defaults: scratch.defaults)
        let list = cameras(6, offline: [1, 4])
        model.update(cameras: list)
        model.layout = OverviewLayout(mode: .grid2)
        #expect(model.showsOfflineCameras && model.arrangedCameras.count == 6 && model.pageCount == 2)
        model.showsOfflineCameras = false
        #expect(model.arrangedCameras.count == 4 && model.pageCount == 1)
        #expect(!model.arrangedCameras.contains { $0.id == list[1].id })
        #expect(!overview(defaults: scratch.defaults).showsOfflineCameras)
        // Connecting and idle cameras are not offline.
        let transient = [CameraStatus(id: UUID(), name: "A", kind: .camera, vendor: .demo, connection: .connecting),
                         CameraStatus(id: UUID(), name: "B", kind: .camera, vendor: .demo, connection: .disabled)]
        #expect(!OverviewOrdering.isOffline(transient[0]) && OverviewOrdering.isOffline(transient[1]))
    }

    // MARK: Live tiles follow the page

    @Test func onlyTheShowingPagePlaysAndTurningThePageSwitchesTheStreams() async {
        let scratch = ScratchDefaults()
        let source = FakeLiveSource()
        let model = overview(defaults: scratch.defaults, source: source)
        let list = cameras(6)
        model.update(cameras: list)
        model.layout = OverviewLayout(mode: .grid2)
        model.playAll = true
        #expect(await settles { model.liveCount == 4 })
        #expect(model.liveIDs == Set(list.prefix(4).map(\.id)), "nothing scrolls in a fixed layout: the page's tiles are the visible ones")
        #expect(await settles { source.opens.count == 4 })
        model.nextPage()
        #expect(model.liveIDs == Set(list.suffix(2).map(\.id)))
        #expect(await settles { list.prefix(4).allSatisfy { !model.isLive($0.id) } && list.suffix(2).allSatisfy { model.isLive($0.id) } })
        model.previousPage()
        #expect(await settles { list.prefix(4).allSatisfy { model.isLive($0.id) } && list.suffix(2).allSatisfy { !model.isLive($0.id) } })
    }

    @Test func aBigGridStillRespectsTheLiveCap() async {
        let source = FakeLiveSource()
        let model = overview(defaults: ScratchDefaults().defaults, source: source, cap: 9)
        let list = cameras(16)
        model.update(cameras: list)
        model.layout = OverviewLayout(mode: .grid4)
        model.playAll = true
        #expect(await settles { model.liveCount == 9 })
        #expect(model.liveIDs == Set(list.prefix(9).map(\.id)), "the first nine of the page in grid order")
    }

    @Test func switchingToAFixedLayoutAndBackKeepsAutoScrollVisibility() {
        let model = overview(defaults: ScratchDefaults().defaults)
        let list = cameras(3)
        model.update(cameras: list)
        model.playAll = true
        #expect(model.liveIDs.isEmpty, "Auto plays what is scrolled into view, and nothing is yet")
        model.setVisible(list[0].id, true)
        #expect(model.liveIDs == [list[0].id])
        model.layout = OverviewLayout(mode: .grid2)
        #expect(model.liveIDs == Set(list.map(\.id)))
        model.layout = OverviewLayout()
        #expect(model.liveIDs == [list[0].id])
    }
}
