import Foundation
import MediaCore

/// Where the box cuts the small picture of a light for the Sky Watcher's grid: the page's own close-up (`closeUpRect` in linux/web/js/screens/sky-model.js)
/// of the still around the light's path, and the whole picture for a light that crossed more of the sky than a close-up holds.
///
/// This is a copy of that rule, and the page draws the light's path over the thumbnail with *its* copy, so the two must give the same rectangle to
/// the pixel: `SkyCloseUpTests` checks this one against hundreds of the page's own answers (Tests/BridgeEngineTests/Fixtures/sky-closeup-vectors.json,
/// made from the page's functions by linux/web-tests/support/sky-closeup-vectors.mjs). Change one and you change the other. The arithmetic is the
/// page's, step for step, in the same order.
enum SkyCloseUp {
    /// The close-up's shape (16:9), its smallest size and its padding, in the still's own pixels (`CLOSE_UP` in the page: a still is the whole picture,
    /// at most 1920 wide).
    static let aspect = 16.0 / 9.0
    static let minimumWidth = 160.0
    static let minimumHeight = 90.0
    static let padding = 0.5
    /// The page reads at most this many points of a path.
    static let maximumPoints = 256

    /// A rectangle of the still, in its pixels, to two decimals as the page rounds it.
    struct Rect: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    /// The close-up of a still of `width` × `height` pixels: the rectangle around `path`'s box with half its size more on every side, at least
    /// 160 × 90, of the close-up's 16:9 shape, as big as the picture at most, and inside it (moved in from an edge or a corner, never cut). A single
    /// point is a box of no size: the smallest close-up, centred on it. nil when there is none to give: no picture size, no point, or a light that crossed
    /// more of the sky than a close-up holds (the whole picture is its view). Points that are not numbers are left out, as the page leaves them.
    static func rect(path: [SkyPathPoint], width: Int, height: Int) -> Rect? {
        guard width > 0, height > 0 else { return nil }
        let points = path.filter { $0.t.isFinite && $0.x.isFinite && $0.y.isFinite }.prefix(maximumPoints)
        guard !points.isEmpty else { return nil }
        let across = Double(width), down = Double(height)
        let xs = points.map { min(1, max(0, $0.x)) * across }
        let ys = points.map { min(1, max(0, $0.y)) * down }
        guard let left = xs.min(), let right = xs.max(), let top = ys.min(), let bottom = ys.max() else { return nil }
        var w = max((right - left) * (1 + 2 * padding), minimumWidth)
        var h = max((bottom - top) * (1 + 2 * padding), minimumHeight)
        if w / h > aspect { h = w / aspect } else { w = h * aspect }
        let fit = min(1, across / w, down / h)   // no bigger than the picture, in the same shape
        w *= fit
        h *= fit
        if right - left > w + 0.01 || bottom - top > h + 0.01 { return nil }
        let x = min(max((left + right) / 2 - w / 2, 0), across - w)
        let y = min(max((top + bottom) / 2 - h / 2, 0), down - h)
        return Rect(x: twoDecimals(x), y: twoDecimals(y), width: twoDecimals(w), height: twoDecimals(h))
    }

    /// The close-up in whole pixels inside the picture (`thumbRect` in the page): what is cut. nil when there is no close-up.
    static func pixels(path: [SkyPathPoint], width: Int, height: Int) -> ImageCrop? {
        guard let rect = rect(path: path, width: width, height: height) else { return nil }
        let w = min(width, max(1, Int(rect.width.rounded())))
        let h = min(height, max(1, Int(rect.height.rounded())))
        return ImageCrop(x: min(max(0, Int(rect.x.rounded())), width - w), y: min(max(0, Int(rect.y.rounded())), height - h), width: w, height: h)
    }

    /// `Math.round(value * 100) / 100` (the values here are never negative).
    private static func twoDecimals(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
