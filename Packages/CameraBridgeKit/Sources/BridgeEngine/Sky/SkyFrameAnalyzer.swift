import Foundation
import MediaCore

// MARK: - What a picture shows

/// A light found in one analysed picture: a blob of pixels that stand out from the sky's background. Positions are in pixels of the
/// analysed picture: x from its left edge and y from its top, pixel (i, j) covering i…i+1 and j…j+1 (so its centre is at i + 0.5, j + 0.5).
struct SkyDetection: Sendable, Equatable {
    /// The blob's centre, weighted by how far each of its pixels stands out.
    var x: Double
    var y: Double
    /// Its pixels.
    var area: Int
    /// How far it stands out in all: the sum of its pixels' difference from the background (luma levels × pixels of the analysed picture;
    /// darker than the sky counted positive for a dark blob).
    var flux: Double
    /// The largest difference of one of its pixels (luma levels).
    var peak: Double
    /// Its long axis over its short one, from its second moments (1 for a round blob, about 9 for a 1×9 streak).
    var elongation: Double
    /// The direction of its long axis (degrees, 0..<180) from the picture's x axis towards its y axis (down).
    var orientation: Double
    /// How far its peak stands above its four neighbours, as a share of the peak: 1 for a sharp point, less for a blurred one (a bug close
    /// to the lens is out of focus). A light seen through a lens spreads onto its neighbours (a dot's is about 0.6); a camera's
    /// single-pixel sensor speckle does not (about 1).
    var sharpness: Double
    /// Brighter than the background (the only kind found at night); false: darker (by day: a bird against the sky).
    var brighter: Bool
    /// The lens it was seen through: 0, or 1 for the right half of a dual camera (blobs are found per half, never across the seam).
    var lens: Int = 0
    /// In the low-trust band around a dual camera's seam (`SkyCameraModel.seamBand`): kept and followed, never used for aiming.
    var inSeamBand: Bool = false
    /// Its peak in the smoothed difference over the threshold it passed (1 and up). The sky's Gaussian noise stays under about 1.4, but a
    /// camera's single-pixel speckle can stand far higher: a light at 2 or more is one no noise makes only when it is not a lone sharp
    /// pixel (`SkyTracker.isStrong`).
    var significance: Double = 1
    /// The pieces of one blob that a dual camera's seam cut apart share this number (unique within the picture); nil for a blob the seam
    /// did not cut. Each piece has its own centre (`x`, `y`, in its own lens's half) and the whole blob's `area`, `flux`, `peak`,
    /// `elongation`, `orientation`, `sharpness` and `significance`: they are one light, and a track that takes one piece takes them all.
    var seamGroup: Int? = nil
    /// What stands still in the sky by the detection: how far the slow background (minutes: `SkyFrameAnalyzer.slowRate`) stands at its
    /// brightest within 10 px of the detection's peak (its darkest, for a darker blob) above its tile's sky level, in that tile's σ; and the
    /// same within 3 px (right under it). A star, a wire or a lamp stands high; a passing light leaves almost nothing. Each is 0 when that
    /// spot stands less than a quarter as high as the detection stands over the fast background (a fixed thing is in the slow background as
    /// high as it flickers or more; a light, a few hundredths of itself). The tracker keeps no track that sat on something fixed all along.
    var fixedRise: Double = 0
    var fixedRiseUnder: Double = 0
}

/// Where nothing is looked for in a picture, in the camera's original picture's coordinates (`PixelPoint`).
struct SkyMask: Sendable, Equatable {
    struct Circle: Sendable, Equatable {
        var center: PixelPoint
        /// A part of the picture's width (so a circle is round in pixels).
        var radius: Double
    }

    /// The bottom rows of the picture, this percentage of them (0…100): the ground and the skyline.
    var groundPercent: Int = 0
    /// Every pixel the camera model sees below this elevation (degrees). Given by the caller once the aim is good (1°); applies only with
    /// `model`.
    var belowElevation: Double? = nil
    /// The Sun within 15° while it is up (`sunCircles`), and later the Moon, stars and planets.
    var excluded: [Circle] = []
    /// The camera model: the lenses whose directions `belowElevation` is judged by, and how the picture is split between them (a dual
    /// camera's halves are analysed apart). Nil: one lens, and no horizon mask.
    var model: SkyCameraModel? = nil
}

extension SkyMask {
    /// The Sun is masked within this many degrees…
    static let sunRadiusDegrees = 15.0
    /// …while it is above this elevation (the end of civil twilight).
    static let sunMaskedAbove = SunEphemeris.darkElevation

    /// The Sun's circles at `date`: one for each lens whose part of the picture comes within 15° of it, while it is above −6°; none
    /// otherwise.
    static func sunCircles(at date: Date, observer: SkyObserver, model: SkyCameraModel, pictureWidth: Int, pictureHeight: Int) -> [Circle] {
        let sun = SunEphemeris.direction(at: date, observer: observer)
        guard sun.elevation > sunMaskedAbove else { return [] }
        return circles(around: sun, radiusDegrees: sunRadiusDegrees, model: model, pictureWidth: pictureWidth, pictureHeight: pictureHeight)
    }

    /// The circles that cover `radiusDegrees` around `direction`, one for each lens that sees part of that disc in its part of the picture:
    /// centred where the lens sees `direction` (inside the picture or not), as wide as the disc's edge is from there (the median over 36
    /// points of the edge). A lens counts when the direction, or one of those points, falls in its part.
    static func circles(around direction: SkyDirection, radiusDegrees: Double, model: SkyCameraModel, pictureWidth: Int,
                        pictureHeight: Int) -> [Circle] {
        guard direction.azimuth.isFinite, direction.elevation.isFinite, radiusDegrees.isFinite, radiusDegrees > 0 else { return [] }
        let aspect = Double(max(1, pictureHeight)) / Double(max(1, pictureWidth))
        let centre = SkyMath.unitVector(direction)
        // Two directions at right angles to the centre, for the disc's edge.
        let helper = abs(centre.z) < 0.9 ? SIMD3(0.0, 0, 1) : SIMD3(1.0, 0, 0)
        let across = SkyMath.cross(centre, helper) / SkyMath.length(SkyMath.cross(centre, helper))
        let along = SkyMath.cross(across, centre)
        let radius = radiusDegrees * SkyMath.radians
        let edge = (0..<36).map { step -> SkyDirection in
            let angle = Double(step) * Double.pi / 18
            return SkyMath.direction(of: centre * cos(radius) + (across * cos(angle) + along * sin(angle)) * sin(radius))
        }
        var result: [Circle] = []
        for lens in 0..<model.lensCount {
            guard let middle = model.project(direction, lens: lens) else { continue }
            let part: ClosedRange<Double> = model.layout == .dual ? (lens == 0 ? 0...model.seam : model.seam...1) : 0...1
            func inside(_ point: PixelPoint) -> Bool { part.contains(point.x) && (0...1).contains(point.y) }
            var distances: [Double] = []
            var reaches = inside(middle)
            for point in edge.compactMap({ model.project($0, lens: lens) }) {
                let dx = point.x - middle.x, dy = (point.y - middle.y) * aspect
                distances.append((dx * dx + dy * dy).squareRoot())
                if inside(point) { reaches = true }
            }
            guard reaches, distances.count >= 18 else { continue }
            distances.sort()
            result.append(Circle(center: middle, radius: distances[distances.count / 2]))
        }
        return result
    }
}

/// What one analysed picture gave.
struct SkyFrameResult: Sendable {
    var detections: [SkyDetection]
    /// More than 20 % of the picture changed at once (the IR-cut filter, an exposure step, headlights): the background starts again from
    /// this picture and nothing is found for 2 s.
    var globalChange: Bool
    /// More than 200 blobs: the picture is noise (rain, snow, a sensor at its limit), and gives no detections.
    var noisy: Bool
}

// MARK: - The mask on a picture's pixels

/// A `SkyMask` laid on a picture's pixels (1: nothing is looked for there), worked out again only when the mask or the size changes. The
/// ground and the horizon, which change only with the aim, are kept apart from the circles, which move with the Sun: a moving circle costs
/// one copy and its own pixels, not the horizon's directions again. The picture's outermost row and column on each side are always
/// masked: the 3×3 smoothing has no neighbours past them, so their noise is up to 1.7 times the rest's (0.625σ against 0.375σ at a corner)
/// and the tile's threshold would let it through.
struct SkyMaskRaster: Sendable {
    private(set) var pixels: [UInt8] = []
    private var current: Current?
    private var fixed: [UInt8] = []
    private var fixedKey: FixedKey?

    private struct Current: Equatable, Sendable {
        var mask: SkyMask
        var width: Int
        var height: Int
    }

    private struct FixedKey: Equatable, Sendable {
        var width: Int
        var height: Int
        var groundRows: Int
        var belowElevation: Double?
        var model: SkyCameraModel?
    }

    /// The horizon mask's directions are worked out on a grid this many pixels apart, per lens, and filled in between.
    static let elevationGrid = 8

    /// Lays `mask` on a picture `width` × `height`; true when the pixels changed.
    @discardableResult
    mutating func update(_ mask: SkyMask, width: Int, height: Int) -> Bool {
        let wanted = Current(mask: mask, width: width, height: height)
        if wanted == current { return false }
        let horizon = mask.model != nil && mask.belowElevation?.isFinite == true
        let key = FixedKey(width: width, height: height, groundRows: Self.groundRows(mask.groundPercent, height: height),
                           belowElevation: horizon ? mask.belowElevation : nil, model: horizon ? mask.model : nil)
        if key != fixedKey {
            fixed = Self.fixedPart(key)
            fixedKey = key
        }
        var pixels = fixed
        for circle in mask.excluded { Self.stamp(circle, into: &pixels, width: width, height: height) }
        self.pixels = pixels
        current = wanted
        return true
    }

    /// The ground's rows: `percent` (0…100) of `height`, rounded.
    static func groundRows(_ percent: Int, height: Int) -> Int {
        Int((Double(max(0, height)) * Double(min(100, max(0, percent))) / 100).rounded())
    }

    private static func fixedPart(_ key: FixedKey) -> [UInt8] {
        let width = key.width, height = key.height
        var pixels = [UInt8](repeating: 0, count: max(0, width * height))
        let firstGround = max(0, height - key.groundRows)
        for index in (firstGround * width)..<(height * width) { pixels[index] = 1 }
        // The frame the smoothing cannot see past.
        if width > 0 && height > 0 {
            for x in 0..<width {
                pixels[x] = 1
                pixels[(height - 1) * width + x] = 1
            }
            for y in 0..<height {
                pixels[y * width] = 1
                pixels[y * width + width - 1] = 1
            }
        }
        if let limit = key.belowElevation, let model = key.model {
            markBelow(limit, model: model, width: width, rows: firstGround, into: &pixels)
        }
        return pixels
    }

    /// Marks the pixels of rows 0..<`rows` whose direction (through the lens of their half) is below `limit`, or that have none: each
    /// lens's elevations on a grid over its own columns, bilinear between them (a direction is worked out directly where a grid cell has
    /// a corner without one).
    private static func markBelow(_ limit: Double, model: SkyCameraModel, width: Int, rows: Int, into pixels: inout [UInt8]) {
        guard width > 0, rows > 0 else { return }
        let height = pixels.count / width
        let split = SkyFrameAnalyzer.splitColumn(model, width: width)
        func elevation(_ x: Int, _ y: Int, lens: Int) -> Double {
            let point = PixelPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))
            return model.direction(at: point, lens: lens)?.elevation ?? .nan
        }
        let step = elevationGrid
        for lens in 0..<model.lensCount {
            let columns = lens == 0 ? 0..<split : split..<width
            guard !columns.isEmpty else { continue }
            var xs = Array(stride(from: columns.lowerBound, to: columns.upperBound, by: step))
            if xs.last != columns.upperBound - 1 { xs.append(columns.upperBound - 1) }
            var ys = Array(stride(from: 0, to: rows, by: step))
            if ys.last != rows - 1 { ys.append(rows - 1) }
            var grid = [Double](repeating: .nan, count: xs.count * ys.count)
            for (j, y) in ys.enumerated() {
                for (i, x) in xs.enumerated() { grid[j * xs.count + i] = elevation(x, y, lens: lens) }
            }
            for j in 0..<ys.count {
                let y0 = ys[j], y1 = j + 1 < ys.count ? ys[j + 1] : ys[j]
                let lastRow = j + 1 < ys.count ? ys[j + 1] - 1 : ys[j]
                for y in y0...max(y0, lastRow) {
                    let fy = y1 > y0 ? Double(y - y0) / Double(y1 - y0) : 0
                    for i in 0..<xs.count {
                        let x0 = xs[i], x1 = i + 1 < xs.count ? xs[i + 1] : xs[i]
                        let lastColumn = i + 1 < xs.count ? xs[i + 1] - 1 : xs[i]
                        let j1 = j + 1 < ys.count ? j + 1 : j, i1 = i + 1 < xs.count ? i + 1 : i
                        let corners = (grid[j * xs.count + i], grid[j * xs.count + i1], grid[j1 * xs.count + i], grid[j1 * xs.count + i1])
                        let whole = corners.0.isFinite && corners.1.isFinite && corners.2.isFinite && corners.3.isFinite
                        for x in x0...max(x0, lastColumn) {
                            let value: Double
                            if whole {
                                let fx = x1 > x0 ? Double(x - x0) / Double(x1 - x0) : 0
                                let top = corners.0 + (corners.1 - corners.0) * fx, bottom = corners.2 + (corners.3 - corners.2) * fx
                                value = top + (bottom - top) * fy
                            } else {
                                value = elevation(x, y, lens: lens)
                            }
                            if !(value >= limit) { pixels[y * width + x] = 1 }
                        }
                    }
                }
            }
        }
    }

    private static func stamp(_ circle: SkyMask.Circle, into pixels: inout [UInt8], width: Int, height: Int) {
        guard circle.center.x.isFinite, circle.center.y.isFinite, circle.radius.isFinite, circle.radius > 0, width > 0, height > 0 else { return }
        let cx = circle.center.x * Double(width), cy = circle.center.y * Double(height), r = circle.radius * Double(width)
        let top = max(0, Int((cy - r).rounded(.down))), bottom = min(height - 1, Int((cy + r).rounded(.up)))
        guard top <= bottom else { return }
        for y in top...bottom {
            let dy = Double(y) + 0.5 - cy
            guard abs(dy) <= r else { continue }
            let half = (r * r - dy * dy).squareRoot()
            let left = max(0, Int((cx - half - 0.5).rounded(.up))), right = min(width - 1, Int((cx + half - 0.5).rounded(.down)))
            guard left <= right else { continue }
            for x in left...right { pixels[y * width + x] = 1 }
        }
    }
}

// MARK: - The analyzer

/// Finds the lights in each analysed picture (luma, at most 1920 px wide, at most 5 a second) against a slowly updated background of the
/// sky. Owned by one detector actor: not `Sendable`, and every buffer is allocated once per picture size and reused.
///
/// Per picture:
/// 1. **The difference** from the background (a running mean, 5 % of each picture), which then takes the picture in.
/// 2. **Each tile's level**: where the tile's smoothed difference sat in the previous picture (the mean of its noise sample, each value
///    clipped to the threshold, so a light or a spike moves it little). A sky that brightens or darkens slowly (dusk, an exposure creeping)
///    leaves the running mean behind (0.3 levels a picture leaves it 5.7 behind); the threshold is about this level, so the lag passes
///    nothing. A step of a few levels at once passes a little noise in its first picture only (one picture cannot start a track).
/// 3. **Smoothing.** The difference is smoothed by a 3×3 kernel (1 2 1, 2 4 2, 1 2 1, over 16) before the threshold, a matched filter for
///    the small blurred dot a light makes. A real camera's luma at night is mostly single-pixel speckle, which this cuts many times over
///    (the overnight trial on the owner's camera: 450 blobs a picture to 7 at dusk, 479 to 96 at night, with the same signal on known
///    planes), while a dot keeps about half its peak; a 1-px flicker keeps a quarter.
/// 4. **The threshold**: max(8, 4σ) about the tile's level, σ the robust noise (MAD × 1.4826) of each 64×64 tile's smoothed difference
///    about its level, from a sample of the pixels of the last 25 pictures (worked out again every 25; the first picture after the
///    background starts gives the first σ, and no detections). At night only pixels brighter than the background count; by day darker
///    ones count too (a bird against the sky).
/// 5. **A whole-picture change**: more than 20 % of the unmasked pixels over the threshold about zero (the levels would hide it), either
///    way: the background starts again from the picture, and nothing is found for 10 pictures (2 s at 5 a second).
/// 6. **Blobs**: 8-connected pixels of one kind (brighter or darker), never across a dual camera's seam (each half is its own lens), of
///    1…5000 px; more than 200 make the picture `noisy`, with no detections. Each blob is measured on the unsmoothed difference about its
///    tiles' levels. A blob the seam cuts is a piece in each lens, linked (`SkyDetection.seamGroup`): each piece has its own centre, and the
///    whole blob's measures.
/// 7. **What stands still**: a second, slow background (a running mean over about 1,000 pictures, 3.3 minutes; every tenth row each
///    picture) holds what has stood in the sky for minutes, a star, a wire, a lamp, and not a passing light. Under each detection: how far
///    it stands above its tile's sky level within 10 px and within 3 px (`SkyDetection.fixedRise`, `.fixedRiseUnder`), which the tracker
///    uses to drop tracks that sat on such a thing all along.
final class SkyFrameAnalyzer {
    // MARK: Pinned values

    /// The running mean's weight of each analysed picture.
    static let backgroundRate: Float = 0.05
    static let thresholdFloor: Float = 8
    static let thresholdSigmas: Float = 4
    /// MAD to σ for Gaussian noise.
    static let madScale: Float = 1.4826
    /// The noise tiles are 64×64 (`tileShift`).
    static let tileSize = 64
    static let tileShift = 6
    static let noiseRefreshPictures = 25
    static let maximumArea = 5_000
    static let maximumBlobs = 200
    static let globalChangeShare = 0.2
    /// After a whole-picture change: 2 s at the 5 pictures a second the sky is analysed at.
    static let quietPictures = 10

    // MARK: Builder's values

    /// A picture wider or taller than this is not a camera's.
    static let maximumSide = 8_192
    /// The noise histograms: bins of 1/8 level over −32…32 of the smoothed difference.
    static let histogramBins = 512
    static let histogramScale: Float = 8
    static let histogramOrigin: Float = 32
    /// A tile with fewer samples than this takes the median σ of the others.
    static let minimumNoiseSamples = 16
    /// A tile whose picture gave fewer noise samples than this moves its level as the median of the others does.
    static let minimumLevelSamples = 16
    /// The slow background: a running mean of the pictures with a time constant of about 1,000 pictures (3.3 minutes at 5 a second), so a
    /// star, a wire or a lamp builds into it and a passing light does not (a light at 0.05°/s seen at 0.1° a pixel leaves each pixel within
    /// seconds, a few thousandths of the way to building in). Each picture updates every `slowRowStride`th row (a different one of them
    /// each time) by `slowRate` × `slowRowStride`: the same rate as `slowRate` of every row each picture, for a tenth of the work.
    static let slowRate: Float = 0.001
    static let slowRowStride = 10
    /// The slow background's sky level and spread per tile (its median, and its MAD × 1.4826, at least 1 level), from every 8th pixel of every
    /// 8th row that is not masked; a row of tiles is worked out again each picture.
    static let slowSampleStride = 8
    static let minimumSlowSigma: Float = 1
    /// What stands still by a detection is looked for within `anchorRadius` px of its peak (where a fixed point's track wanders onto the noise
    /// around it, and a star drifting with the sky leaves its trail in the slow background) and within `anchorOnRadius` (right under it).
    /// A spot counts only when it stands at least `anchorShare` of the detection's own peak (over the fast background): a passing light puts
    /// a few hundredths of itself in the slow background, so this keeps any light moving faster than about 0.02°/s (at 0.1° a pixel) clear of
    /// it, however bright.
    static let anchorRadius = 10
    static let anchorOnRadius = 3
    static let anchorShare = 0.25
    /// Each row's half-width of the disc of `anchorRadius` (rows −10…10), then of `anchorOnRadius` (rows −3…3).
    static let anchorReach: [Int] = (-anchorRadius...anchorRadius).map { Int(Double(anchorRadius * anchorRadius - $0 * $0).squareRoot()) }
        + (-anchorOnRadius...anchorOnRadius).map { Int(Double(anchorOnRadius * anchorOnRadius - $0 * $0).squareRoot()) }

    // MARK: State

    private(set) var width = 0
    private(set) var height = 0
    private var tilesAcross = 0
    private var tiles = 0
    /// The background, a running mean of the pictures (luma levels).
    private var sky = UnsafeMutableBufferPointer<Float>.allocate(capacity: 0)
    /// Per pixel after the threshold: 0 nothing, 1 brighter, 2 darker; the labelling clears what it takes.
    private var state = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 0)
    /// Rows with something over the threshold.
    private var rowsFound = UnsafeMutableBufferPointer<Bool>.allocate(capacity: 0)
    /// Three rows of the horizontally smoothed difference, and one of the difference itself.
    private var ring = UnsafeMutableBufferPointer<Float>.allocate(capacity: 0)
    private var line = UnsafeMutableBufferPointer<Float>.allocate(capacity: 0)
    private var thresholds = UnsafeMutableBufferPointer<Float>.allocate(capacity: 0)
    private var histograms = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: 0)
    /// Each tile's level in this picture, and the last picture's noise sample about it (the sum of its clipped values, and their count),
    /// which moves it for the next (`followLevels`).
    private var levels = UnsafeMutableBufferPointer<Float>.allocate(capacity: 0)
    private var levelSums = UnsafeMutableBufferPointer<Float>.allocate(capacity: 0)
    private var levelCounts = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 0)
    private var levelMoves: [Float] = []
    /// The slow background (luma levels), and its sky level and σ per tile (σ infinite until worked out: nothing there counts as fixed); the row
    /// phase of its next update, and the row of tiles whose level is worked out next.
    private var slowSky = UnsafeMutableBufferPointer<Float>.allocate(capacity: 0)
    private var slowLevels = UnsafeMutableBufferPointer<Float>.allocate(capacity: 0)
    private var slowSigmas = UnsafeMutableBufferPointer<Float>.allocate(capacity: 0)
    private var slowSample: [Float] = []
    private var slowPhase = 0
    private var slowTileRow = 0
    /// Per row: the detection whose blob has a pixel in the left lens's last column (`seamLeft`) or the right lens's first (`seamRight`), or
    /// −1; the rows of the blob being labelled that do; and each detection's sums, for linking a blob's pieces across the seam.
    private var seamLeft = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 0)
    private var seamRight = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 0)
    private var edgeRows: [Int32] = []
    private var sums: [Moments] = []
    private var stack: [Int32] = []
    private var blob: [Int32] = []
    private var raster = SkyMaskRaster()
    private var hasBackground = false
    /// The next picture gives the noise (σ) afresh, and no detections.
    private var noiseStale = true
    private var sinceRefresh = 0
    private var quiet = 0

    init(width: Int, height: Int) {
        resize(width: width, height: height)
    }

    deinit {
        free()
    }

    /// The background as a picture (rounded), for how much sky is visible (`SkyVisibility`): all black before the first picture.
    var background: GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        if hasBackground {
            for index in pixels.indices { pixels[index] = UInt8(clamping: Int(sky[index].rounded())) }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    /// The slow background as a picture (rounded): what has stood in the sky for minutes (stars, wires, lamps).
    var slowBackground: GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        if hasBackground {
            for index in pixels.indices { pixels[index] = UInt8(clamping: Int(slowSky[index].rounded())) }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    /// Starts again: the next picture becomes the background (after a gap in the stream, the old one is stale).
    func reset() {
        hasBackground = false
        quiet = 0
    }

    /// Analyses one picture. A picture of another size starts the analysis again at that size.
    func process(_ image: GrayImage, mask: SkyMask, isNight: Bool) -> SkyFrameResult {
        let nothing = SkyFrameResult(detections: [], globalChange: false, noisy: false)
        guard image.width > 0, image.height > 0, image.width <= Self.maximumSide, image.height <= Self.maximumSide,
              image.pixels.count >= image.width * image.height else { return nothing }
        if image.width != width || image.height != height { resize(width: image.width, height: image.height) }
        raster.update(mask, width: width, height: height)
        return image.pixels.withUnsafeBufferPointer { picture -> SkyFrameResult in
            guard hasBackground else {
                start(from: picture)
                return nothing
            }
            if noiseStale {
                _ = scan(picture, detect: false, night: isNight)
                refreshNoise()
                quiet = max(0, quiet - 1)
                return nothing
            }
            let counts = scan(picture, detect: true, night: isNight)
            sinceRefresh += 1
            if sinceRefresh >= Self.noiseRefreshPictures { refreshNoise() }
            if counts.unmasked > 0 && Double(counts.over) > Self.globalChangeShare * Double(counts.unmasked) {
                start(from: picture)
                quiet = Self.quietPictures
                return SkyFrameResult(detections: [], globalChange: true, noisy: false)
            }
            if quiet > 0 {
                quiet -= 1
                return nothing
            }
            let found = label(picture, model: mask.model)
            return SkyFrameResult(detections: found.detections, globalChange: false, noisy: found.noisy)
        }
    }

    /// The first column of a dual camera's right lens in a picture `width` wide (columns whose centre is left of the seam are the left
    /// lens's, as `SkyCameraModel.lens(at:)` says); `width` for a single lens.
    static func splitColumn(_ model: SkyCameraModel?, width: Int) -> Int {
        guard let model, model.layout == .dual, model.seam.isFinite else { return width }
        return min(width, max(0, Int((model.seam * Double(width) - 0.5).rounded(.up))))
    }

    // MARK: Buffers

    private func resize(width: Int, height: Int) {
        free()
        self.width = max(0, width)
        self.height = max(0, height)
        let pixels = self.width * self.height
        tilesAcross = (self.width + Self.tileSize - 1) >> Self.tileShift
        tiles = tilesAcross * ((self.height + Self.tileSize - 1) >> Self.tileShift)
        sky = .allocate(capacity: pixels)
        sky.initialize(repeating: 0)
        state = .allocate(capacity: pixels)
        state.initialize(repeating: 0)
        rowsFound = .allocate(capacity: self.height)
        rowsFound.initialize(repeating: false)
        ring = .allocate(capacity: 3 * self.width)
        ring.initialize(repeating: 0)
        line = .allocate(capacity: self.width)
        line.initialize(repeating: 0)
        thresholds = .allocate(capacity: tiles)
        thresholds.initialize(repeating: Self.thresholdFloor)
        histograms = .allocate(capacity: tiles * Self.histogramBins)
        histograms.initialize(repeating: 0)
        levels = .allocate(capacity: tiles)
        levels.initialize(repeating: 0)
        levelSums = .allocate(capacity: tiles)
        levelSums.initialize(repeating: 0)
        levelCounts = .allocate(capacity: tiles)
        levelCounts.initialize(repeating: 0)
        levelMoves.reserveCapacity(tiles)
        slowSky = .allocate(capacity: pixels)
        slowSky.initialize(repeating: 0)
        slowLevels = .allocate(capacity: tiles)
        slowLevels.initialize(repeating: 0)
        slowSigmas = .allocate(capacity: tiles)
        slowSigmas.initialize(repeating: .infinity)
        slowSample.reserveCapacity((Self.tileSize / Self.slowSampleStride) * (Self.tileSize / Self.slowSampleStride))
        seamLeft = .allocate(capacity: self.height)
        seamLeft.initialize(repeating: -1)
        seamRight = .allocate(capacity: self.height)
        seamRight.initialize(repeating: -1)
        stack.reserveCapacity(4_096)
        blob.reserveCapacity(Self.maximumArea + 1)
        hasBackground = false
        noiseStale = true
        sinceRefresh = 0
        quiet = 0
    }

    private func free() {
        sky.deallocate()
        state.deallocate()
        rowsFound.deallocate()
        ring.deallocate()
        line.deallocate()
        thresholds.deallocate()
        histograms.deallocate()
        levels.deallocate()
        levelSums.deallocate()
        levelCounts.deallocate()
        slowSky.deallocate()
        slowLevels.deallocate()
        slowSigmas.deallocate()
        seamLeft.deallocate()
        seamRight.deallocate()
    }

    /// The background starts from `picture`; the next picture gives the noise afresh.
    private func start(from picture: UnsafeBufferPointer<UInt8>) {
        for index in 0..<(width * height) { sky[index] = Float(picture[index]) }
        hasBackground = true
        noiseStale = true
        sinceRefresh = 0
        histograms.update(repeating: 0)
        levels.update(repeating: 0)
        levelSums.update(repeating: 0)
        levelCounts.update(repeating: 0)
        for index in 0..<(width * height) { slowSky[index] = Float(picture[index]) }
        slowSigmas.update(repeating: .infinity)
        slowTileRow = 0
    }

    /// Each tile's level for this picture: its level in the last, moved by the mean of the last picture's noise sample about it (each value
    /// clipped to the tile's threshold, so a light or a spike moves it little). A tile with too small a sample moves as the median of the
    /// others. The sample then starts again.
    private func followLevels() {
        levelMoves.removeAll(keepingCapacity: true)
        for tile in 0..<tiles where levelCounts[tile] >= Int32(Self.minimumLevelSamples) {
            levelMoves.append(levelSums[tile] / Float(levelCounts[tile]))
        }
        levelMoves.sort()
        let fallback: Float = levelMoves.isEmpty ? 0 : levelMoves[levelMoves.count / 2]
        for tile in 0..<tiles {
            levels[tile] += levelCounts[tile] >= Int32(Self.minimumLevelSamples) ? levelSums[tile] / Float(levelCounts[tile]) : fallback
        }
        levelSums.update(repeating: 0)
        levelCounts.update(repeating: 0)
    }

    // MARK: The picture's pass

    /// The difference, the background's update, the smoothing, the threshold about each tile's level (when `detect`) and the noise sample
    /// about it, row by row: each row's difference is smoothed across, and the smoothed row above it down, in a ring of three rows. Counts,
    /// over the noise sample (every other pixel of every other row: a quarter of the picture, which gives the share to a tenth of a
    /// percent), the unmasked pixels and those over the threshold about zero, either way: a whole-picture change is what the levels would
    /// hide.
    private func scan(_ picture: UnsafeBufferPointer<UInt8>, detect: Bool, night: Bool) -> (over: Int, unmasked: Int) {
        followLevels()
        let w = width, h = height
        guard w > 0, h > 0, let source = picture.baseAddress, let sky = sky.baseAddress, let state = state.baseAddress,
              let ring = ring.baseAddress, let line = line.baseAddress, let thresholds = thresholds.baseAddress,
              let histograms = histograms.baseAddress, let rowsFound = rowsFound.baseAddress, let levels = levels.baseAddress,
              let levelSums = levelSums.baseAddress, let levelCounts = levelCounts.baseAddress, let slowSky = slowSky.baseAddress
        else { return (0, 0) }
        let rate = Self.backgroundRate, sixteenth: Float = 1.0 / 16
        let across = tilesAcross, shift = Self.tileShift, bins = Self.histogramBins
        let scale = Self.histogramScale, origin = Self.histogramOrigin
        let darker: UInt8 = night ? 0 : 2
        let slowStride = Self.slowRowStride, slowRow = slowPhase, slowStep = Self.slowRate * Float(Self.slowRowStride)
        slowPhase = (slowPhase + 1) % slowStride
        var over = 0, unmasked = 0
        raster.pixels.withUnsafeBufferPointer { maskPixels in
            guard let mask = maskPixels.baseAddress, maskPixels.count >= w * h else { return }
            for y in 0...h {
                if y < h {
                    let row = y &* w
                    let input = source + row, background = sky + row
                    for x in 0..<w {
                        let difference = Float(input[x]) - background[x]
                        line[x] = difference
                        background[x] += rate * difference
                    }
                    if y % slowStride == slowRow {
                        let slow = slowSky + row
                        for x in 0..<w { slow[x] += slowStep * (Float(input[x]) - slow[x]) }
                    }
                    let out = ring + (y % 3) &* w
                    if w == 1 {
                        out[0] = 4 * line[0]
                    } else {
                        out[0] = 3 * line[0] + line[1]
                        var x = 1
                        while x < w - 1 {
                            out[x] = line[x - 1] + 2 * line[x] + line[x + 1]
                            x += 1
                        }
                        out[w - 1] = line[w - 2] + 3 * line[w - 1]
                    }
                }
                let r = y - 1
                guard r >= 0 else { continue }
                let above = ring + (max(r - 1, 0) % 3) &* w
                let middle = ring + (r % 3) &* w
                let below = ring + (min(r + 1, h - 1) % 3) &* w
                let row = r &* w
                let maskRow = mask + row, stateRow = state + row
                let tileRow = (r >> shift) &* across
                var found = false
                if detect {
                    // Brighter or darker than the tile's level by more than its threshold (darker counts only by day).
                    for x in 0..<w {
                        if maskRow[x] != 0 {
                            stateRow[x] = 0
                            continue
                        }
                        let tile = tileRow &+ (x >> shift)
                        let value = (above[x] + 2 * middle[x] + below[x]) * sixteenth - levels[tile]
                        let threshold = thresholds[tile]
                        if value > threshold {
                            stateRow[x] = 1
                            found = true
                        } else if value < -threshold {
                            stateRow[x] = darker
                            found = found || darker != 0
                        } else {
                            stateRow[x] = 0
                        }
                    }
                }
                rowsFound[r] = found
                // The noise sample about the level, every other pixel of every other row: for σ, (clipped) for the next level, and the
                // share of the picture over the threshold about zero. A tile's sums are kept along the row and added at its end.
                if r & 1 == 0 {
                    var tile = tileRow, sum: Float = 0, count: Int32 = 0, changed = 0
                    var x = 0
                    while x < w {
                        let next = tileRow &+ (x >> shift)
                        if next != tile {
                            levelSums[tile] += sum
                            levelCounts[tile] &+= count
                            unmasked &+= Int(count)
                            tile = next
                            sum = 0
                            count = 0
                        }
                        if maskRow[x] == 0 {
                            let raw = (above[x] + 2 * middle[x] + below[x]) * sixteenth
                            let threshold = thresholds[tile]
                            let value = raw - levels[tile]
                            histograms[tile &* bins &+ min(bins - 1, max(0, Int((value + origin) * scale)))] &+= 1
                            sum += min(threshold, max(-threshold, value))
                            count &+= 1
                            if abs(raw) > threshold { changed &+= 1 }
                        }
                        x &+= 2
                    }
                    levelSums[tile] += sum
                    levelCounts[tile] &+= count
                    unmasked &+= Int(count)
                    over &+= changed
                }
            }
        }
        refreshSlowLevels()
        return (over, unmasked)
    }

    /// One row of tiles' sky level and σ in the slow background (the median, and the MAD × 1.4826, at least 1 level), from every 8th pixel of
    /// every 8th row that is not masked; a tile with fewer than 8 such pixels gets no σ (nothing there counts as fixed). Each picture takes the
    /// next row of tiles.
    private func refreshSlowLevels() {
        let w = width, h = height, tileRows = (h + Self.tileSize - 1) >> Self.tileShift
        guard tileRows > 0, let slow = slowSky.baseAddress else { return }
        let row = slowTileRow % tileRows
        slowTileRow = (row + 1) % tileRows
        let step = Self.slowSampleStride, size = Self.tileSize
        raster.pixels.withUnsafeBufferPointer { maskPixels in
            guard let mask = maskPixels.baseAddress, maskPixels.count >= w * h else { return }
            for column in 0..<tilesAcross {
                slowSample.removeAll(keepingCapacity: true)
                var y = row * size + step / 2
                while y < min(h, (row + 1) * size) {
                    var x = column * size + step / 2
                    while x < min(w, (column + 1) * size) {
                        if mask[y * w + x] == 0 { slowSample.append(slow[y * w + x]) }
                        x += step
                    }
                    y += step
                }
                let tile = row * tilesAcross + column
                guard slowSample.count >= 8 else {
                    slowSigmas[tile] = .infinity
                    continue
                }
                slowSample.sort()
                let median = slowSample[slowSample.count / 2]
                for index in slowSample.indices { slowSample[index] = abs(slowSample[index] - median) }
                slowSample.sort()
                slowLevels[tile] = median
                slowSigmas[tile] = max(Self.minimumSlowSigma, Self.madScale * slowSample[slowSample.count / 2])
            }
        }
    }

    /// Each tile's σ from its sample (the median of the smoothed difference about its level, then the median distance from it, × 1.4826)
    /// and its threshold, max(8, 4σ); a tile with too small a sample takes the median σ of the others. The sample then starts again.
    private func refreshNoise() {
        let bins = Self.histogramBins
        var sigmas = [Float](repeating: .nan, count: tiles)
        var cumulative = [Int](repeating: 0, count: bins + 1)
        for tile in 0..<tiles {
            let counts = histograms.baseAddress! + tile * bins
            for bin in 0..<bins { cumulative[bin + 1] = cumulative[bin] + Int(counts[bin]) }
            let total = cumulative[bins]
            guard total >= Self.minimumNoiseSamples else { continue }
            // How many sampled values are at or below `value` (linear within a bin).
            func below(_ value: Double) -> Double {
                let position = (value + Double(Self.histogramOrigin)) * Double(Self.histogramScale)
                if position <= 0 { return 0 }
                if position >= Double(bins) { return Double(total) }
                let bin = Int(position)
                return Double(cumulative[bin]) + Double(counts[bin]) * (position - Double(bin))
            }
            let half = Double(total) / 2
            var low = -Double(Self.histogramOrigin), high = Double(Self.histogramOrigin)
            for _ in 0..<40 {
                let middle = (low + high) / 2
                if below(middle) < half { low = middle } else { high = middle }
            }
            let median = (low + high) / 2
            var near = 0.0, far = 2 * Double(Self.histogramOrigin)
            for _ in 0..<40 {
                let spread = (near + far) / 2
                if below(median + spread) - below(median - spread) < half { near = spread } else { far = spread }
            }
            sigmas[tile] = Self.madScale * Float((near + far) / 2)
        }
        let known = sigmas.filter { !$0.isNaN }.sorted()
        let fallback: Float = known.isEmpty ? 0 : known[known.count / 2]
        for tile in 0..<tiles {
            let sigma = sigmas[tile].isNaN ? fallback : sigmas[tile]
            thresholds[tile] = max(Self.thresholdFloor, Self.thresholdSigmas * sigma)
        }
        histograms.update(repeating: 0)
        sinceRefresh = 0
        noiseStale = false
    }

    // MARK: Blobs

    /// The blobs left by the threshold: 8-connected pixels of one kind, never across the seam; more than 200 is noise. The pieces of a blob
    /// the seam cut are linked afterwards (`linkPieces`).
    private func label(_ picture: UnsafeBufferPointer<UInt8>, model: SkyCameraModel?) -> (detections: [SkyDetection], noisy: Bool) {
        let w = width, h = height
        let split = Self.splitColumn(model, width: w)
        let cut = split > 0 && split < w
        var detections: [SkyDetection] = []
        sums.removeAll(keepingCapacity: true)
        if cut {
            seamLeft.update(repeating: -1)
            seamRight.update(repeating: -1)
        }
        var blobs = 0
        var touching = false
        for r in 0..<h where rowsFound[r] {
            for x in 0..<w {
                let seed = r * w + x
                let kind = state[seed]
                guard kind != 0 else { continue }
                state[seed] = 0
                stack.removeAll(keepingCapacity: true)
                blob.removeAll(keepingCapacity: true)
                edgeRows.removeAll(keepingCapacity: true)
                stack.append(Int32(seed))
                let right = x >= split
                // This lens's column next to the seam.
                let edge = right ? split : split - 1
                var area = 0
                while let next = stack.popLast() {
                    let pixel = Int(next)
                    area += 1
                    if area <= Self.maximumArea { blob.append(next) }
                    let py = pixel / w, px = pixel - py * w
                    if cut && px == edge { edgeRows.append(Int32(py)) }
                    let left = px > 0 && (px - 1 >= split) == right ? px - 1 : px
                    let last = px < w - 1 && (px + 1 >= split) == right ? px + 1 : px
                    for ny in max(py - 1, 0)...min(py + 1, h - 1) {
                        let base = ny * w
                        for nx in left...last where state[base + nx] == kind {
                            state[base + nx] = 0
                            stack.append(Int32(base + nx))
                        }
                    }
                }
                guard area <= Self.maximumArea else { continue }
                blobs += 1
                if blobs > Self.maximumBlobs { return ([], true) }
                let moments = sum(blob, brighter: kind == 1, picture: picture)
                let index = Int32(detections.count)
                for row in edgeRows {
                    if right { seamRight[Int(row)] = index } else { seamLeft[Int(row)] = index }
                }
                touching = touching || !edgeRows.isEmpty
                sums.append(moments)
                detections.append(detection(whole: moments, piece: moments, brighter: kind == 1, lens: right ? 1 : 0, picture: picture,
                                            model: model))
            }
        }
        if touching { linkPieces(&detections, picture: picture, model: model) }
        return (detections, false)
    }

    /// Links the pieces of the blobs a dual camera's seam cut: blobs of one kind with pixels next to each other across it (8-connected,
    /// as they would have been one blob). Each piece keeps its own centre and lens, takes the whole blob's measures, and the pieces share a
    /// `seamGroup`.
    private func linkPieces(_ detections: inout [SkyDetection], picture: UnsafeBufferPointer<UInt8>, model: SkyCameraModel?) {
        let h = height
        var parent = Array(detections.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for r in 0..<h where seamLeft[r] >= 0 {
            let a = Int(seamLeft[r])
            for s in max(r - 1, 0)...min(r + 1, h - 1) where seamRight[s] >= 0 {
                let b = Int(seamRight[s])
                guard detections[a].brighter == detections[b].brighter else { continue }
                let ra = root(a), rb = root(b)
                if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in detections.indices { groups[root(index), default: []].append(index) }
        for (group, pieces) in groups where pieces.count > 1 {
            var whole = Moments()
            for piece in pieces { whole.add(sums[piece]) }
            for piece in pieces {
                var linked = detection(whole: whole, piece: sums[piece], brighter: detections[piece].brighter, lens: detections[piece].lens,
                                       picture: picture, model: model)
                linked.seamGroup = group
                detections[piece] = linked
            }
        }
    }

    /// A blob's sums over its pixels, on the unsmoothed difference from the background before this picture's update, about each pixel's
    /// tile's level: what its measures come from, and what the pieces of a blob the seam cut add up to.
    private struct Moments {
        var area = 0
        var flux = 0.0
        var peak = -Double.infinity
        var peakIndex = 0
        /// Positions weighted by how far each pixel stands out…
        var weights = 0.0, sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0, sumXY = 0.0
        /// …and every pixel alike, for a blob where nothing stands out (it cannot happen past the threshold, but the numbers must stay
        /// finite).
        var plainX = 0.0, plainY = 0.0, plainXX = 0.0, plainYY = 0.0, plainXY = 0.0

        mutating func add(_ other: Moments) {
            area += other.area
            flux += other.flux
            if other.peak > peak {
                peak = other.peak
                peakIndex = other.peakIndex
            }
            weights += other.weights; sumX += other.sumX; sumY += other.sumY; sumXX += other.sumXX; sumYY += other.sumYY; sumXY += other.sumXY
            plainX += other.plainX; plainY += other.plainY; plainXX += other.plainXX; plainYY += other.plainYY; plainXY += other.plainXY
        }

        /// The centre and the second moments about it: weighted, or every pixel alike when nothing stands out.
        var shape: (x: Double, y: Double, xx: Double, yy: Double, xy: Double) {
            let (w, x, y, xx, yy, xy) = weights > 0 ? (weights, sumX, sumY, sumXX, sumYY, sumXY)
                : (Double(max(1, area)), plainX, plainY, plainXX, plainYY, plainXY)
            let cx = x / w, cy = y / w
            return (cx, cy, max(0, xx / w - cx * cx), max(0, yy / w - cy * cy), xy / w - cx * cy)
        }
    }

    /// The difference of pixel `index` from the background before this picture's update (the update took 5 % of it, so it is the difference
    /// now over 0.95), about its tile's level; darker counted positive for a dark blob.
    private func difference(_ index: Int, sign: Double, picture: UnsafeBufferPointer<UInt8>) -> Double {
        let y = index / width, x = index - y * width
        let level = Double(levels[(y >> Self.tileShift) * tilesAcross + (x >> Self.tileShift)])
        return sign * (Double(Float(picture[index]) - sky[index]) / Double(1 - Self.backgroundRate) - level)
    }

    private func sum(_ pixels: [Int32], brighter: Bool, picture: UnsafeBufferPointer<UInt8>) -> Moments {
        let w = width
        let sign: Double = brighter ? 1 : -1
        var moments = Moments()
        for item in pixels {
            let index = Int(item)
            let value = difference(index, sign: sign, picture: picture)
            moments.area += 1
            moments.flux += value
            if value > moments.peak {
                moments.peak = value
                moments.peakIndex = index
            }
            let x = Double(index % w) + 0.5, y = Double(index / w) + 0.5
            let weight = max(0, value)
            moments.weights += weight
            moments.sumX += weight * x
            moments.sumY += weight * y
            moments.sumXX += weight * x * x
            moments.sumYY += weight * y * y
            moments.sumXY += weight * x * y
            moments.plainX += x
            moments.plainY += y
            moments.plainXX += x * x
            moments.plainYY += y * y
            moments.plainXY += x * y
        }
        return moments
    }

    /// A detection: the centre of `piece` (the blob, or its part in one lens of a dual camera), and the measures of `whole` (the blob).
    private func detection(whole: Moments, piece: Moments, brighter: Bool, lens: Int, picture: UnsafeBufferPointer<UInt8>,
                           model: SkyCameraModel?) -> SkyDetection {
        let w = width, h = height
        let sign: Double = brighter ? 1 : -1
        let centre = piece.shape, spread = whole.shape
        let half = (((spread.xx - spread.yy) / 2) * ((spread.xx - spread.yy) / 2) + spread.xy * spread.xy).squareRoot()
        let major = (spread.xx + spread.yy) / 2 + half, minor = max(0, (spread.xx + spread.yy) / 2 - half)
        // A pixel's own extent (1/12 of a pixel squared) keeps a one-pixel line finite: a 1×9 streak is 9 long.
        let elongation = ((major + 1.0 / 12) / (minor + 1.0 / 12)).squareRoot()
        var orientation = 0.5 * atan2(2 * spread.xy, spread.xx - spread.yy) * SkyMath.degrees
        if orientation < 0 { orientation += 180 }
        if orientation >= 180 { orientation -= 180 }
        // Sharpness: the peak against its four neighbours.
        let peak = whole.peak, peakIndex = whole.peakIndex
        let py = peakIndex / w, px = peakIndex - py * w
        var around = 0.0, neighbours = 0.0
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] where px + dx >= 0 && px + dx < w && py + dy >= 0 && py + dy < h {
            around += difference((py + dy) * w + px + dx, sign: sign, picture: picture)
            neighbours += 1
        }
        let sharpness = peak > 0 && neighbours > 0 ? min(1, max(0, (peak - around / neighbours) / peak)) : 0
        // Significance: the smoothed difference at the peak over the threshold of its tile.
        var smoothed = 0.0
        for dy in -1...1 {
            for dx in -1...1 {
                let y = min(h - 1, max(0, py + dy)), x = min(w - 1, max(0, px + dx))
                smoothed += Double((2 - abs(dx)) * (2 - abs(dy))) * difference(y * w + x, sign: sign, picture: picture)
            }
        }
        smoothed /= 16
        let tile = (py >> Self.tileShift) * tilesAcross + (px >> Self.tileShift)
        let threshold = Double(thresholds[tile])
        // What stands still here: the slow background's brightest pixel within 10 px of the peak, and within 3 px (its darkest, for a darker
        // blob), against its tile's sky level (in the tile's σ) and against the detection's own peak. The scan reads masked pixels too, on
        // purpose: the slow background takes in the ground and the skyline, so flicker along the skyline reads as fixed.
        let radius = Self.anchorRadius, onRadius = Self.anchorOnRadius, side: Float = brighter ? 1 : -1
        var beside = -Float.infinity, under = -Float.infinity
        if let slow = slowSky.baseAddress {
            Self.anchorReach.withUnsafeBufferPointer { reach in
                for dy in -radius...radius where py + dy >= 0 && py + dy < h {
                    let row = slow + (py + dy) * w
                    var low = max(0, px - reach[dy + radius]), high = min(w - 1, px + reach[dy + radius])
                    for x in low...high { beside = max(beside, side * row[x]) }
                    guard abs(dy) <= onRadius else { continue }
                    let narrow = reach[radius + radius + 1 + dy + onRadius]
                    low = max(0, px - narrow)
                    high = min(w - 1, px + narrow)
                    for x in low...high { under = max(under, side * row[x]) }
                }
            }
        }
        let level = side * slowLevels[tile], sigma = Double(slowSigmas[tile])
        func standing(_ top: Float) -> Double {
            let rise = Double(top - level)
            return sigma.isFinite && rise > 0 && rise >= Self.anchorShare * max(0, peak) ? rise / sigma : 0
        }
        let point = PixelPoint(x: centre.x / Double(w), y: centre.y / Double(h))
        return SkyDetection(x: centre.x, y: centre.y, area: whole.area, flux: max(0, whole.flux), peak: max(0, peak), elongation: elongation,
                            orientation: orientation, sharpness: sharpness, brighter: brighter, lens: lens,
                            inSeamBand: model?.isInSeamBand(point) ?? false, significance: max(0, smoothed / threshold),
                            fixedRise: standing(beside), fixedRiseUnder: standing(under))
    }
}
