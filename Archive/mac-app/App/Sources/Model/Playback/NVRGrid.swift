import CoreGraphics
import Foundation

/// The NVR page's grid: at most nine 16:9 tiles on a page, in the number of columns (one to three) that gives the largest tiles. No info area.
nonisolated enum NVRGrid {
    static let maximumTiles = 9
    static let maximumColumns = 3
    static let spacing: CGFloat = 10

    struct Fit: Equatable {
        var columns: Int
        var rows: Int
        /// The 16:9 tile.
        var tileSize: CGSize
    }

    /// The columns (at most 3) for `count` tiles in `available` that make the tiles largest; the fewer columns win a tie.
    static func fit(count: Int, available: CGSize, spacing: CGFloat = NVRGrid.spacing) -> Fit {
        let count = min(max(count, 1), maximumTiles)
        var best = Fit(columns: 1, rows: count, tileSize: .zero)
        for columns in 1...min(maximumColumns, count) {
            let rows = (count + columns - 1) / columns
            let cellWidth = (available.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let cellHeight = (available.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            let width = max(0, min(cellWidth, cellHeight * 16 / 9))
            if width > best.tileSize.width + 0.5 { best = Fit(columns: columns, rows: rows, tileSize: CGSize(width: width, height: width * 9 / 16)) }
        }
        return best
    }
}
