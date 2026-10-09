import BridgeEngine
import CoreGraphics
import Foundation

/// How the Overview arranges its tiles: Auto (the responsive grid that scrolls) or a fixed number of columns and rows that
/// fits the window exactly, with the cameras beyond it on further pages. Remembered across launches.
struct OverviewLayout: Equatable, Codable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case auto, grid1, grid2, grid3, grid4, custom
        var id: String { rawValue }
    }

    /// Columns and rows a custom layout can have.
    static let customRange = 1...6

    var mode: Mode = .auto
    var customColumns = 3
    var customRows = 2

    init(mode: Mode = .auto, customColumns: Int = 3, customRows: Int = 2) {
        self.mode = mode
        self.customColumns = Self.clamp(customColumns)
        self.customRows = Self.clamp(customRows)
    }

    static func clamp(_ value: Int) -> Int { min(customRange.upperBound, max(customRange.lowerBound, value)) }

    /// Columns × rows of a fixed layout; nil for Auto.
    var grid: (columns: Int, rows: Int)? {
        switch mode {
        case .auto: nil
        case .grid1: (1, 1)
        case .grid2: (2, 2)
        case .grid3: (3, 3)
        case .grid4: (4, 4)
        case .custom: (Self.clamp(customColumns), Self.clamp(customRows))
        }
    }

    /// Tiles per page; nil for Auto, which has one scrolling page.
    var perPage: Int? { grid.map { $0.columns * $0.rows } }

    /// The layout's name in the menu and on its button: "Auto", "2×2", "Custom 3×2".
    var title: String {
        switch mode {
        case .auto: String(localized: "Auto")
        case .grid1: "1×1"
        case .grid2: "2×2"
        case .grid3: "3×3"
        case .grid4: "4×4"
        case .custom: String(localized: "Custom \(Self.clamp(customColumns))×\(Self.clamp(customRows))")
        }
    }

    /// The layout ⌘1…⌘4 pick.
    static func forShortcut(_ digit: Int) -> OverviewLayout? {
        switch digit {
        case 1: OverviewLayout(mode: .grid1)
        case 2: OverviewLayout(mode: .grid2)
        case 3: OverviewLayout(mode: .grid3)
        case 4: OverviewLayout(mode: .grid4)
        default: nil
        }
    }
}

/// Pages of a fixed layout.
enum OverviewPaging {
    /// How many pages `items` take at `perPage` per page (at least one; Auto has one).
    static func pageCount(items: Int, perPage: Int?) -> Int {
        guard let perPage, perPage > 0 else { return 1 }
        return max(1, (items + perPage - 1) / perPage)
    }

    /// `page` brought into 0..<count.
    static func clamp(page: Int, count: Int) -> Int { min(max(0, page), max(0, count - 1)) }

    /// The items on `page`.
    static func slice<T>(_ items: [T], page: Int, perPage: Int?) -> [T] {
        guard let perPage, perPage > 0 else { return items }
        let count = pageCount(items: items.count, perPage: perPage)
        let start = clamp(page: page, count: count) * perPage
        guard start < items.count else { return [] }
        return Array(items[start..<min(items.count, start + perPage)])
    }
}

/// The order the person gave the tiles by dragging them.
enum OverviewOrdering {
    /// `cameras` in the saved order; cameras not in it (added since) follow in their own order, saved ids that are gone are ignored.
    static func arrange(_ cameras: [CameraStatus], saved: [UUID]) -> [CameraStatus] {
        let position = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let known = cameras.filter { position[$0.id] != nil }.sorted { position[$0.id, default: 0] < position[$1.id, default: 0] }
        return known + cameras.filter { position[$0.id] == nil }
    }

    /// `order` with `id` moved to where `target` is (list semantics: it takes the place of the tile it is dropped on).
    static func moving(_ id: UUID, onto target: UUID, in order: [UUID]) -> [UUID] {
        guard id != target, let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return order }
        var result = order
        result.remove(at: from)
        result.insert(id, at: to)
        return result
    }

    /// Whether the Overview hides `status` while "Show Offline Cameras" is off: a camera that does not answer or is switched off.
    static func isOffline(_ status: CameraStatus) -> Bool {
        switch status.connection {
        case .offline, .disabled: true
        case .online, .connecting, .idle: false
        }
    }
}

/// How big the tiles of a fixed layout are for the room they have, and how much of their info area still fits.
enum OverviewGridMetrics {
    /// What is shown under a tile's picture.
    enum Density: Equatable {
        /// Name and status, address and viewers, last motion and recording.
        case full
        /// One line: name and status dot.
        case compact
        /// Nothing (the name is drawn on the picture).
        case hidden
    }

    static let fullInfoHeight: CGFloat = 108
    static let compactInfoHeight: CGFloat = 34
    static let fullMinimumWidth: CGFloat = 300
    static let compactMinimumWidth: CGFloat = 190

    /// Space between tiles: roomy for a few big ones, tight for many small ones.
    static func spacing(columns: Int, rows: Int) -> CGFloat { columns * rows >= 12 ? 10 : 16 }

    struct Fit: Equatable {
        var tileWidth: CGFloat
        /// The 16:9 picture's height.
        var pictureHeight: CGFloat
        var density: Density
        var spacing: CGFloat
        var infoHeight: CGFloat { density == .full ? OverviewGridMetrics.fullInfoHeight : (density == .compact ? OverviewGridMetrics.compactInfoHeight : 0) }
        var tileHeight: CGFloat { pictureHeight + infoHeight }
    }

    /// The largest 16:9 tiles that fit `columns`×`rows` of them (info area included) into `available`, with as much info as the
    /// tile's width allows: full, then one line, then none. The grid is centered by the caller.
    static func fit(available: CGSize, columns: Int, rows: Int) -> Fit {
        let spacing = spacing(columns: columns, rows: rows)
        let cellWidth = (available.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let cellHeight = (available.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
        for (density, info, minimum) in [(Density.full, fullInfoHeight, fullMinimumWidth), (.compact, compactInfoHeight, compactMinimumWidth)] {
            let width = min(cellWidth, (cellHeight - info) * 16 / 9)
            if width >= minimum { return Fit(tileWidth: width, pictureHeight: width * 9 / 16, density: density, spacing: spacing) }
        }
        let width = max(1, min(cellWidth, cellHeight * 16 / 9))
        return Fit(tileWidth: width, pictureHeight: width * 9 / 16, density: .hidden, spacing: spacing)
    }
}
