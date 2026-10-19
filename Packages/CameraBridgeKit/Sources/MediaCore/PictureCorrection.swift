import Foundation

/// The per-camera "Straighten the picture" correction: a panorama stitched from two lenses bends its horizon, and this moves
/// that curve onto a straight line, column by column, keeping the picture's top and bottom edges where they are (no crop, no
/// black, same shape). Two numbers describe the horizon the camera shows; both 0 means off. Decoding fills every missing or
/// unreadable key with its default (settings written by an older or newer build never fail to load).
///
/// The formula, for a picture W × H and an output pixel (x, y) (docs/superpowers/specs/2026-10-18-straighten-the-picture-design.md):
///
///     u  = (x − W/2) / (W/2)                                  −1 at the left edge, +1 at the right
///     h  = clamp(0.5 + a·(1 − u²) + b·u, 0.03, 0.97)          the horizon in this column, as a fraction of the height
///     T  = clamp(0.5 + (2/3)·a, 0.03, 0.97)                   the straight line it lands on: the curve's average height
///     f  = y / H
///     fs = f ≤ T ?  f · h / T                                 above the line: [0, T] shows the camera's [0, h]
///                :  h + (f − T) · (1 − h) / (1 − T)           below it:       [T, 1] shows the camera's [h, 1]
///     source = (x, fs · H)                                    sampled bilinearly, vertical only
///
/// Written resolution-free here: `across` = x / W and `down` = f (pixel i's centre is (i + 0.5) / size), and `sourceFraction`
/// is `fs`. The JavaScript copy in the browser and the ffmpeg maps are pinned to this by
/// `Tests/MediaCoreTests/Fixtures/picture-correction-vectors.json`.
public struct PictureCorrection: Sendable, Codable, Equatable, Hashable {
    /// The most Straighten can be set to either way (the card's slider shows −60 to +60).
    public static let straightenLimit = 0.60
    /// The most Level can be set to either way (the card's slider shows −40 to +40).
    public static let levelLimit = 0.40
    /// No correction.
    public static let off = PictureCorrection()
    /// The longest a codec service may take to straighten one snapshot (`MediaCodecs.correctJPEG`: the ffmpeg child is stopped there). The
    /// engine runs the call on a thread of its own and gives up on it a little later (`CorrectedSnapshots.deadline`).
    public static let snapshotTimeout = Duration.seconds(6)

    /// `a`: the horizon's curve. Positive sags in the middle (lower in the picture there), negative rises in the middle.
    public private(set) var straighten: Double
    /// `b`: the horizon's side-to-side tilt. Positive is lower on the right, negative lower on the left.
    public private(set) var level: Double

    /// Values past the limits are clamped, rounded to 0.01 (what the sliders can say), and a value that is not a number is 0.
    public init(straighten: Double = 0, level: Double = 0) {
        self.straighten = Self.normalized(straighten, limit: Self.straightenLimit)
        self.level = Self.normalized(level, limit: Self.levelLimit)
    }

    private static func normalized(_ value: Double, limit: Double) -> Double {
        guard value.isFinite else { return 0 }
        let rounded = (min(limit, max(-limit, value)) * 100).rounded() / 100
        return rounded == 0 ? 0 : rounded    // never a negative zero (it would be written as "-0")
    }

    private enum CodingKeys: String, CodingKey { case straighten, level }

    public init(from decoder: any Decoder) throws {
        self.init()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        func value(_ key: CodingKeys) -> Double {
            ((try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil) ?? 0
        }
        straighten = Self.normalized(value(.straighten), limit: Self.straightenLimit)
        level = Self.normalized(value(.level), limit: Self.levelLimit)
    }

    /// Both sliders at 0: the picture is left as the camera sent it, and nothing anywhere does any work for it.
    public var isOff: Bool { straighten == 0 && level == 0 }

    /// `h`: where the camera's horizon is in the column `across` (0 at the left edge, 1 at the right), as a fraction of the height.
    public func horizon(across: Double) -> Double {
        let u = 2 * across - 1
        return min(0.97, max(0.03, 0.5 + straighten * (1 - u * u) + level * u))
    }

    /// `T`: the height of the straight line the horizon lands on, as a fraction of the height (the curve's average height).
    public var landing: Double {
        min(0.97, max(0.03, 0.5 + 2.0 / 3.0 * straighten))
    }

    /// `fs`: where, as a fraction of the camera's height, the output picture's row `down` (a fraction of the height) in the column
    /// `across` takes its colour from. 0 stays 0 and 1 stays 1; it increases with `down` and always stays inside 0…1.
    public func sourceFraction(across: Double, down: Double) -> Double {
        // The edges are exact (the lower piece's arithmetic can land one step short of 1).
        if down <= 0 { return 0 }
        if down >= 1 { return 1 }
        let h = horizon(across: across)
        let t = landing
        let fs = down <= t ? down * h / t : h + (down - t) * (1 - h) / (1 - t)
        return min(1, max(0, fs))
    }

    /// How much taller than the camera drew them the most stretched rows become: the larger of `T / h` (above the line) and
    /// `(1 − T) / (1 − h)` (below it), over 256 columns at `across` = (i + 0.5) / 256. 1 when off; about 2.7 for Backyard's
    /// (0.40, 0.15), where the ground just below the horizon near the middle is stretched most.
    public var largestStretch: Double {
        let t = landing
        var largest = 1.0
        for column in 0..<256 {
            let h = horizon(across: (Double(column) + 0.5) / 256)
            largest = max(largest, t / h, (1 - t) / (1 - h))
        }
        return largest
    }
}

/// Supplies the correction a transcoder applies, asked for every picture: a change made while a stream runs takes effect at
/// once, and nil (correction off) leaves the picture untouched.
public protocol PictureCorrectionProviding: Sendable {
    var current: PictureCorrection? { get }
}

/// A correction that never changes.
public struct StaticPictureCorrection: PictureCorrectionProviding {
    public var correction: PictureCorrection?
    public init(_ correction: PictureCorrection?) { self.correction = correction }
    public var current: PictureCorrection? { correction.flatMap { $0.isOff ? nil : $0 } }
}
