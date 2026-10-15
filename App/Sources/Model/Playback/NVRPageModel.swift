import BridgeEngine
import Foundation
import Observation

/// The NVR page's logic: which cameras are on the page (nine at most, in the Overview's order, every one whatever its connection state), the
/// page turner, the hovered tile, and the shared session and timeline. The page opens live; the viewer covering it suspends it.
@MainActor @Observable final class NVRPageModel {
    let panel: NVRPanelModel
    var session: NVRSession { panel.session }

    private(set) var page = 0
    /// Every camera the engine has, as last given to `update(cameras:)`.
    private(set) var allCameras: [CameraStatus] = []
    /// The tile the pointer is over: it gets the exact frame first.
    var hovered: UUID? {
        didSet { panel.session.focus(hovered) }
    }
    /// The viewer covers the page (the page stays mounted; its clock holds and its cells let go).
    private(set) var isCovered = false

    @ObservationIgnored private let defaults: UserDefaults

    init(panel: NVRPanelModel, defaults: UserDefaults) {
        self.panel = panel
        self.defaults = defaults
    }

    // MARK: Cameras and pages

    /// The cameras in the Overview's saved order (read, never written here); the rest follow in the engine's order.
    var arrangedCameras: [CameraStatus] {
        let saved = (defaults.stringArray(forKey: OverviewModel.orderKey) ?? []).compactMap(UUID.init(uuidString:))
        return OverviewOrdering.arrange(allCameras, saved: saved)
    }

    var pageCount: Int { OverviewPaging.pageCount(items: arrangedCameras.count, perPage: NVRGrid.maximumTiles) }
    var pageCameras: [CameraStatus] { OverviewPaging.slice(arrangedCameras, page: page, perPage: NVRGrid.maximumTiles) }
    var canGoBack: Bool { page > 0 }
    var canGoForward: Bool { page < pageCount - 1 }

    func update(cameras: [CameraStatus]) {
        allCameras = cameras
        page = OverviewPaging.clamp(page: page, count: pageCount)
        showPage()
    }

    func goToPage(_ target: Int) {
        let clamped = OverviewPaging.clamp(page: target, count: pageCount)
        guard clamped != page else { return }
        page = clamped
        showPage()
    }

    func nextPage() { goToPage(page + 1) }
    func previousPage() { goToPage(page - 1) }

    private func showPage() {
        let ids = pageCameras.map(\.id)
        if let hovered, !ids.contains(hovered) { self.hovered = nil }
        if !isCovered { session.setCameras(ids) }
        panel.setCameras(ids)
        panel.setClipCameras(arrangedCameras.map(\.id))
    }

    // MARK: Covering

    /// The viewer opens over the page (or closes): the cells let go of their decoders and leases, the clock holds; on the way back live cells go
    /// live again and recorded ones show the exact still at the position, without playing.
    func setCovered(_ covered: Bool) {
        guard covered != isCovered else { return }
        isCovered = covered
        if covered {
            session.suspend()
        } else {
            session.setCameras(pageCameras.map(\.id))
            session.resume()
        }
    }

    /// The viewer opens on a tile at the page's playhead (live when the page is live) and keeps playing if the page played.
    func start(forTile id: UUID) -> ViewerStart {
        session.clock.isLive ? ViewerStart(time: nil, playing: false) : ViewerStart(time: session.clock.position(), playing: session.clock.isPlaying)
    }

    /// The page goes away: every cell stops.
    func stopAll() {
        session.stopAll()
    }
}
