import BridgeEngine
import CoreGraphics
import Foundation
import Observation

/// The Overview page's logic: which tiles are live, how many columns the grid has, the remembered Play All preference and
/// the tile texts. The views only draw what it decides.
///
/// Tiles show snapshots until they are told to play. Play All makes every tile live; a tile's own play/pause overrides it
/// for that tile. Only tiles that are on screen (scrolled into view), online, and within the cap (`maximumLiveTiles`, in
/// the grid's order) are live, and none while the page or the window cannot be seen: each live tile is a lease on its
/// camera's sub stream, a hardware decode and a drawn layer.
@MainActor
@Observable
final class OverviewModel {
    static let playAllKey = "overviewPlayAll"
    static let layoutKey = "overviewLayout"
    static let pageKey = "overviewPage"
    static let orderKey = "overviewOrder"
    static let showsOfflineKey = "overviewShowsOffline"
    /// At most this many tiles are live at once.
    nonisolated static let maximumLiveTiles = 9
    /// A tile is at least this wide; the grid has two to four columns.
    nonisolated static let minimumTileWidth: CGFloat = 280
    nonisolated static let tileSpacing: CGFloat = 16

    typealias SinkFactory = @MainActor () -> any LiveVideoSink

    /// Play All is on (remembered across launches).
    var playAll: Bool {
        didSet {
            guard playAll != oldValue else { return }
            defaults.set(playAll, forKey: Self.playAllKey)
            manual = [:]   // the toggle speaks for every tile again
            reconcile()
        }
    }
    /// The page can be seen (it is the selected page).
    var isPageVisible = false {
        didSet { if isPageVisible != oldValue { reconcile() } }
    }
    /// The window can be seen (`WindowActivity`).
    var isWindowVisible = true {
        didSet { if isWindowVisible != oldValue { reconcile() } }
    }

    /// The grid's layout: Auto, or columns × rows with pages (remembered).
    var layout: OverviewLayout {
        didSet {
            guard layout != oldValue else { return }
            if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: Self.layoutKey) }
            page = OverviewPaging.clamp(page: page, count: pageCount)
            reconcile()
        }
    }
    /// The page of a fixed layout that is showing, from 0 (remembered).
    private(set) var page: Int {
        didSet {
            guard page != oldValue else { return }
            defaults.set(page, forKey: Self.pageKey)
            reconcile()
        }
    }
    /// Which way the last page change went (+1 forward, −1 back): the slide's direction.
    private(set) var pageDirection = 1
    /// "Show Offline Cameras" (remembered): off hides the cameras that don't answer or are switched off.
    var showsOfflineCameras: Bool {
        didSet {
            guard showsOfflineCameras != oldValue else { return }
            defaults.set(showsOfflineCameras, forKey: Self.showsOfflineKey)
            page = OverviewPaging.clamp(page: page, count: pageCount)
            reconcile()
        }
    }
    /// The cameras in the order the person dragged them into (remembered), for those not in it the engine's order.
    private(set) var savedOrder: [UUID] {
        didSet { defaults.set(savedOrder.map(\.uuidString), forKey: Self.orderKey) }
    }
    /// Every camera the engine has, as last given to `update(cameras:)`.
    private(set) var allCameras: [CameraStatus] = []

    /// How many tiles are live (or connecting) now.
    private(set) var liveCount = 0
    /// The tiles' feeds, made on first use by `feed(for:)` (never observed: a tile's body asks for its feed).
    @ObservationIgnored private(set) var feeds: [UUID: LiveFeed] = [:]
    @ObservationIgnored private var online: Set<UUID> = []
    @ObservationIgnored private var visible: Set<UUID> = []
    /// Tiles whose own play/pause overrides Play All (true: play, false: paused).
    @ObservationIgnored private var manual: [UUID: Bool] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let open: LiveVideoOpener
    @ObservationIgnored private let makeSink: SinkFactory
    @ObservationIgnored private let cap: Int

    init(defaults: UserDefaults, cap: Int = OverviewModel.maximumLiveTiles, makeSink: @escaping SinkFactory, open: @escaping LiveVideoOpener) {
        self.defaults = defaults
        self.cap = cap
        self.makeSink = makeSink
        self.open = open
        playAll = defaults.bool(forKey: Self.playAllKey)
        layout = defaults.data(forKey: Self.layoutKey).flatMap { try? JSONDecoder().decode(OverviewLayout.self, from: $0) } ?? OverviewLayout()
        page = max(0, defaults.integer(forKey: Self.pageKey))
        showsOfflineCameras = defaults.object(forKey: Self.showsOfflineKey) as? Bool ?? true
        savedOrder = (defaults.stringArray(forKey: Self.orderKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    // MARK: Layout, pages and order

    /// The cameras the grid shows, in the person's order, without the offline ones when they are hidden.
    var arrangedCameras: [CameraStatus] {
        let arranged = OverviewOrdering.arrange(allCameras, saved: savedOrder)
        return showsOfflineCameras ? arranged : arranged.filter { !OverviewOrdering.isOffline($0) }
    }

    /// How many pages the fixed layout has (one for Auto).
    var pageCount: Int { OverviewPaging.pageCount(items: arrangedCameras.count, perPage: layout.perPage) }

    /// The cameras on the page that is showing (all of them for Auto).
    var pageCameras: [CameraStatus] { OverviewPaging.slice(arrangedCameras, page: page, perPage: layout.perPage) }

    var canGoBack: Bool { page > 0 }
    var canGoForward: Bool { page < pageCount - 1 }

    /// Shows page `target` (counted from 0, kept within the pages there are).
    func goToPage(_ target: Int) {
        let clamped = OverviewPaging.clamp(page: target, count: pageCount)
        guard clamped != page else { return }
        pageDirection = clamped > page ? 1 : -1
        page = clamped
    }

    func nextPage() { goToPage(page + 1) }
    func previousPage() { goToPage(page - 1) }

    /// The tile `id` was dropped on tile `target`: it takes that tile's place and the order is remembered.
    func move(_ id: UUID, onto target: UUID) {
        let current = OverviewOrdering.arrange(allCameras, saved: savedOrder).map(\.id)
        let moved = OverviewOrdering.moving(id, onto: target, in: current)
        guard moved != current else { return }
        savedOrder = moved
        reconcile()
    }

    // MARK: Plan

    /// The tiles that are live: those that want to play (their own choice, else Play All), are on screen and online, in grid
    /// order, at most `cap`. Pure (tested).
    nonisolated static func plan(order: [UUID], visible: Set<UUID>, online: Set<UUID>, playAll: Bool, manual: [UUID: Bool], cap: Int) -> Set<UUID> {
        var chosen: Set<UUID> = []
        for id in order where visible.contains(id) && online.contains(id) && (manual[id] ?? playAll) {
            guard chosen.count < cap else { break }
            chosen.insert(id)
        }
        return chosen
    }

    /// The grid's columns for a content width: as many as fit at the minimum tile width, two to four.
    nonisolated static func columns(forWidth width: CGFloat) -> Int {
        let fit = Int(((width + tileSpacing) / (minimumTileWidth + tileSpacing)).rounded(.down))
        return min(4, max(2, fit))
    }

    /// The tiles that can be seen: those scrolled into view in Auto, those on the showing page in a fixed layout (nothing
    /// scrolls there, and the other pages' streams stop).
    private var seen: Set<UUID> {
        layout.grid == nil ? visible : Set(pageCameras.map(\.id))
    }

    /// The live tiles right now.
    var liveIDs: Set<UUID> {
        guard isPageVisible, isWindowVisible else { return [] }
        let order = layout.grid == nil ? arrangedCameras.map(\.id) : pageCameras.map(\.id)
        return Self.plan(order: order, visible: seen, online: online, playAll: playAll, manual: manual, cap: cap)
    }

    /// Tile `id` wants to play (its own choice or Play All) whether or not it is on screen or online.
    func wantsToPlay(_ id: UUID) -> Bool { manual[id] ?? playAll }

    /// Tile `id` is live (or connecting) now.
    func isLive(_ id: UUID) -> Bool { feeds[id]?.isWanted == true }

    /// A tile's own play/pause button.
    func toggle(_ id: UUID) {
        manual[id] = !wantsToPlay(id)
        reconcile()
    }

    // MARK: Inputs from the page

    /// The grid's cameras, in order. Feeds of removed cameras end.
    func update(cameras: [CameraStatus]) {
        allCameras = cameras
        online = Set(cameras.filter { $0.connection == .online }.map(\.id))
        let ids = Set(cameras.map(\.id))
        if !cameras.isEmpty { page = OverviewPaging.clamp(page: page, count: pageCount) }
        for id in feeds.keys where !ids.contains(id) {
            feeds[id]?.stop()
            feeds[id] = nil
            visible.remove(id)
            manual[id] = nil
        }
        reconcile()
    }

    /// A tile scrolled into or out of view.
    func setVisible(_ id: UUID, _ isVisible: Bool) {
        if isVisible { visible.insert(id) } else { visible.remove(id) }
        reconcile()
    }

    /// The tile's feed, made on first use.
    func feed(for id: UUID) -> LiveFeed {
        if let feed = feeds[id] { return feed }
        let feed = LiveFeed(cameraID: id, stream: .sub, sink: makeSink(), open: open)
        feeds[id] = feed
        return feed
    }

    /// Every tile stops (the page or the window went away).
    func stopAll() {
        isPageVisible = false
        for feed in feeds.values { feed.stop() }
    }

    private func reconcile() {
        let live = liveIDs
        if live.count != liveCount { liveCount = live.count }
        for id in live { feed(for: id).isWanted = true }
        for (id, feed) in feeds where !live.contains(id) { feed.isWanted = false }
    }
}

/// The texts of a tile's info area.
enum OverviewTileText {
    /// When the camera last saw motion: its newest "Motion" event, else its last event if that was motion-like. nil when it has
    /// not reported any.
    static func lastMotion(in status: CameraStatus) -> Date? {
        if let event = status.recentEvents.last(where: { $0.name == "Motion" }) { return event.date }
        if status.lastEvent == "Motion" { return status.lastEventDate }
        return nil
    }

    /// "Motion 5 minutes ago", "No motion yet", or "Motion now" while it is active.
    static func motionLine(_ status: CameraStatus, now: Date) -> String {
        if status.motionActive { return String(localized: "Motion now") }
        guard let date = lastMotion(in: status) else { return String(localized: "No motion yet") }
        return String(localized: "Motion \(StatusText.timeAgo(date, now: now))")
    }

    /// The recording state: running now, armed (HomeKit Secure Video records on motion), or off.
    enum Recording: Equatable {
        case recording, armed, off
    }

    static func recording(_ status: CameraStatus) -> Recording {
        if status.recordingNow { return .recording }
        return status.recordingEnabled ? .armed : .off
    }

    static func recordingLine(_ status: CameraStatus) -> String {
        switch recording(status) {
        case .recording: String(localized: "Recording now")
        case .armed: String(localized: "Records on motion")
        case .off: String(localized: "Not recording")
        }
    }
}
