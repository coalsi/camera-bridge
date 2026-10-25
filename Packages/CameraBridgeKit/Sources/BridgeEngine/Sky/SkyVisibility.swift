import Foundation
import MediaCore

/// How much of the sky a camera sees right now, judged from its stars: once a minute at night (the Sun below −6°, as the caller says), the
/// background (`SkyFrameAnalyzer.background`) is cut into an 8×4 grid over the sky above the ground, and each cell counts its stars, the
/// local maxima at least 5σ above the sky around them. A cell is visible while it shows at least 30 % of what it shows on a clear night:
/// the 90th percentile of its own counts on past nights. The answer is the visible share of the cells (0…1); unknown (nil) until there have
/// been 3 nights, and by day (weather comes later). Kept by the detector (`Codable`) so what it learned outlives a restart.
///
/// **Pinned:** the 8×4 grid; maxima of 5σ; the 90th percentile; visible at 30 %; 3 nights; once a minute; nil by day.
///
/// **The builder's choices:**
/// - σ is the cell's robust spread (MAD × 1.4826) of the background, at least 1 level (the background is rounded to whole levels, and a
///   running mean is smooth); a maximum stands above the mean of the 16 pixels two away from it (a star's own glow is closer);
/// - a night is a run of night samples, ended by a day sample, a pause of over 6 hours, or 24 hours after it began (a polar night is
///   then a night a day); it counts when it has at least 10 minutes. Tonight's counts are kept as a small histogram per cell
///   (`CountHistogram`), so what is kept does not grow with the night. Each cell keeps the 90th percentile of each of the last 30 nights'
///   counts, and its clear-night level is the 90th percentile of those;
/// - a cell with under a quarter of its pixels unmasked, or that has never shown a star, is not judged.
struct SkyVisibility: Codable, Sendable {
    // MARK: Pinned values

    static let columns = 8
    static let rows = 4
    static let interval: TimeInterval = 60
    static let peakSigmas = 5.0
    static let percentile = 0.9
    static let visibleShare = 0.3
    static let nightsNeeded = 3

    // MARK: Builder's values

    static let nightsKept = 30
    static let minimumMinutes = 10
    static let nightBreak: TimeInterval = 6 * 3_600
    /// A night closes this long after it began, however long the Sun stays down.
    static let longestNight: TimeInterval = 24 * 3_600
    static let minimumSkyShare = 0.25
    static let minimumSigma = 1.0
    static let madScale = 1.4826

    /// Each finished night's 90th percentile of every cell's counts (−1: no sky in that cell that night), oldest first.
    private(set) var nights: [[Double]] = []
    /// Tonight's counts so far: per cell, how many minutes showed each count (none while the cell had no sky); the minutes counted; and
    /// when it began.
    private var tonight: [CountHistogram] = []
    private var tonightMinutes = 0
    private var nightStart: Date?
    private var lastNightSample: Date?
    private var lastCount: Date?
    private var lastResult: Double?
    private var raster = SkyMaskRaster()

    private enum CodingKeys: String, CodingKey {
        case nights, tonightCounts, tonightMinutes, nightStart, lastNightSample, lastCount, lastResult
    }

    init() {}

    /// What was kept (a value saved by another version reads as far as it can: what is missing starts afresh).
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        nights = (try? values.decodeIfPresent([[Double]].self, forKey: .nights)) ?? []
        tonight = (try? values.decodeIfPresent([CountHistogram].self, forKey: .tonightCounts)) ?? []
        tonightMinutes = (try? values.decodeIfPresent(Int.self, forKey: .tonightMinutes)) ?? 0
        nightStart = try? values.decodeIfPresent(Date.self, forKey: .nightStart)
        lastNightSample = try? values.decodeIfPresent(Date.self, forKey: .lastNightSample)
        lastCount = try? values.decodeIfPresent(Date.self, forKey: .lastCount)
        lastResult = try? values.decodeIfPresent(Double.self, forKey: .lastResult)
        if nightStart == nil {
            tonight = []
            tonightMinutes = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(nights, forKey: .nights)
        try values.encode(tonight, forKey: .tonightCounts)
        try values.encode(tonightMinutes, forKey: .tonightMinutes)
        try values.encodeIfPresent(nightStart, forKey: .nightStart)
        try values.encodeIfPresent(lastNightSample, forKey: .lastNightSample)
        try values.encodeIfPresent(lastCount, forKey: .lastCount)
        try values.encodeIfPresent(lastResult, forKey: .lastResult)
    }

    /// The visible share of the sky in `background` at `date` (counted at most once a minute; within the minute, the last answer), or nil:
    /// unknown by day and until 3 nights have been seen.
    mutating func sample(_ background: GrayImage, mask: SkyMask, at date: Date, isNight: Bool) -> Double? {
        guard isNight else {
            closeNight()
            lastResult = nil
            return nil
        }
        if let previous = lastNightSample, date < previous || date.timeIntervalSince(previous) > Self.nightBreak { closeNight() }
        if let start = nightStart, date.timeIntervalSince(start) >= Self.longestNight { closeNight() }
        if let previous = lastCount, date >= previous, date.timeIntervalSince(previous) < Self.interval { return lastResult }
        guard let counts = Self.counts(background, mask: mask, raster: &raster) else { return lastResult }
        if tonight.count != counts.count { tonight = Array(repeating: CountHistogram(), count: counts.count) }
        for (cell, count) in counts.enumerated() where count >= 0 { tonight[cell].add(count) }
        tonightMinutes += 1
        if nightStart == nil { nightStart = date }
        lastCount = date
        lastNightSample = date
        lastResult = visible(counts)
        return lastResult
    }

    /// The share of the judged cells whose count is at least 30 % of their clear-night level; nil before 3 nights, or with no cell to judge.
    private func visible(_ counts: [Int]) -> Double? {
        guard nights.count >= Self.nightsNeeded else { return nil }
        var judged = 0, seen = 0
        for (cell, count) in counts.enumerated() where count >= 0 {
            let past = nights.compactMap { cell < $0.count && $0[cell] >= 0 ? $0[cell] : nil }
            guard past.count >= Self.nightsNeeded else { continue }
            let clear = Self.percentile(past.sorted(), Self.percentile)
            guard clear > 0 else { continue }
            judged += 1
            if Double(count) >= Self.visibleShare * clear { seen += 1 }
        }
        return judged > 0 ? Double(seen) / Double(judged) : nil
    }

    /// The night in progress ends: kept when it had 10 minutes or more.
    private mutating func closeNight() {
        defer {
            tonight = []
            tonightMinutes = 0
            nightStart = nil
            lastNightSample = nil
            lastCount = nil
        }
        guard tonightMinutes >= Self.minimumMinutes, !tonight.isEmpty else { return }
        nights.append(tonight.map { $0.percentile(Self.percentile) ?? -1 })
        if nights.count > Self.nightsKept { nights.removeFirst(nights.count - Self.nightsKept) }
    }

    /// The `share` percentile of sorted `values`, between the two nearest.
    private static func percentile(_ values: [Double], _ share: Double) -> Double {
        guard let first = values.first else { return 0 }
        guard values.count > 1 else { return first }
        let position = share * Double(values.count - 1)
        let low = Int(position.rounded(.down)), high = min(values.count - 1, low + 1)
        return values[low] + (values[high] - values[low]) * (position - Double(low))
    }

    // MARK: Counting stars

    /// Each cell's stars (row by row from the top-left; −1 where too little of the cell is sky), or nil for a picture too small to cut.
    static func counts(_ image: GrayImage, mask: SkyMask, raster: inout SkyMaskRaster) -> [Int]? {
        let width = image.width, height = image.height
        guard width >= 4 * columns, height >= 4 * rows, image.pixels.count >= width * height else { return nil }
        raster.update(mask, width: width, height: height)
        let sky = height - SkyMaskRaster.groundRows(mask.groundPercent, height: height)
        guard sky >= rows else { return Array(repeating: -1, count: columns * rows) }
        let masked = raster.pixels
        return image.pixels.withUnsafeBufferPointer { pixels in
            masked.withUnsafeBufferPointer { mask in
                var counts: [Int] = []
                for row in 0..<rows {
                    for column in 0..<columns {
                        let xs = (column * width / columns)..<((column + 1) * width / columns)
                        let ys = (row * sky / rows)..<((row + 1) * sky / rows)
                        counts.append(stars(in: xs, ys, pixels: pixels, mask: mask, width: width, height: height))
                    }
                }
                return counts
            }
        }
    }

    /// The stars in one cell: unmasked local maxima (a flat top counted once) at least 5σ above the mean of the 16 pixels two away.
    private static func stars(in xs: Range<Int>, _ ys: Range<Int>, pixels: UnsafeBufferPointer<UInt8>, mask: UnsafeBufferPointer<UInt8>,
                              width: Int, height: Int) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        for y in ys {
            for x in xs where mask[y * width + x] == 0 {
                histogram[Int(pixels[y * width + x])] += 1
                total += 1
            }
        }
        guard total > 0, Double(total) >= minimumSkyShare * Double(xs.count * ys.count) else { return -1 }
        func median(_ counts: [Int], _ total: Int) -> Int {
            var seen = 0
            for (value, count) in counts.enumerated() {
                seen += count
                if 2 * seen >= total { return value }
            }
            return counts.count - 1
        }
        let middle = median(histogram, total)
        var spread = [Int](repeating: 0, count: 256)
        for (value, count) in histogram.enumerated() where count > 0 { spread[abs(value - middle)] += count }
        let sigma = max(minimumSigma, madScale * Double(median(spread, total)))
        let rise = peakSigmas * sigma
        var stars = 0
        for y in max(ys.lowerBound, 2)..<min(ys.upperBound, height - 2) {
            for x in max(xs.lowerBound, 2)..<min(xs.upperBound, width - 2) {
                let index = y * width + x
                let value = pixels[index]
                guard mask[index] == 0, Double(value) - Double(middle) >= rise else { continue }
                guard value > pixels[index - width - 1], value > pixels[index - width], value > pixels[index - width + 1], value > pixels[index - 1],
                      value >= pixels[index + 1], value >= pixels[index + width - 1], value >= pixels[index + width],
                      value >= pixels[index + width + 1] else { continue }
                var ring = 0
                for step in -2...2 { ring += Int(pixels[index - 2 * width + step]) + Int(pixels[index + 2 * width + step]) }
                for step in -1...1 { ring += Int(pixels[index + step * width - 2]) + Int(pixels[index + step * width + 2]) }
                if Double(value) - Double(ring) / 16 >= rise { stars += 1 }
            }
        }
        return stars
    }
}

/// How many minutes of a night showed each count of one cell's stars, kept small however long the night: a bin for each count up to 31,
/// then eight bins for each doubling up to 1023 (each a sixteenth to an eighth of its counts wide), and one for 1024 or more: at most 73
/// numbers. Its percentiles read the counts as spread evenly through each bin, so they are exact up to 31 and within a bin's width
/// beyond.
struct CountHistogram: Codable, Sendable, Equatable {
    static let exact = 32
    static let binsPerDoubling = 8
    static let top = 1_024
    static let binCount = exact + 5 * binsPerDoubling + 1

    /// The minutes in each bin; bins past the last one used are not kept.
    private(set) var bins: [Int] = []

    init() {}

    init(from decoder: Decoder) throws {
        bins = try decoder.singleValueContainer().decode([Int].self).prefix(Self.binCount).map { max(0, $0) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bins)
    }

    /// The minutes counted.
    var total: Int { bins.reduce(0, +) }

    /// One more minute showing `count` (a count below 0 is not one).
    mutating func add(_ count: Int) {
        guard count >= 0 else { return }
        let bin = Self.bin(of: count)
        if bins.count <= bin { bins += Array(repeating: 0, count: bin + 1 - bins.count) }
        bins[bin] += 1
    }

    /// The bin that holds `count` (0 or more).
    static func bin(of count: Int) -> Int {
        if count < exact { return count }
        if count >= top { return binCount - 1 }
        let doubling = Int.bitWidth - 1 - count.leadingZeroBitCount       // 5…9
        let step = doubling - 3                                            // the bin's width is 2^step
        return exact + (doubling - 5) * binsPerDoubling + (count >> step) - binsPerDoubling
    }

    /// The counts bin `index` holds: its lowest, and how many there are.
    static func range(of index: Int) -> (lowest: Int, width: Int) {
        if index < exact { return (index, 1) }
        if index >= binCount - 1 { return (top, 1) }
        let doubling = 5 + (index - exact) / binsPerDoubling, step = doubling - 3
        return ((binsPerDoubling + (index - exact) % binsPerDoubling) << step, 1 << step)
    }

    /// The `share` percentile of the counts (between the two nearest, as for a sorted list), nil with none.
    func percentile(_ share: Double) -> Double? {
        let total = total
        guard total > 0 else { return nil }
        let position = min(1, max(0, share)) * Double(total - 1)
        let low = Int(position.rounded(.down))
        let lower = value(at: low), upper = value(at: min(total - 1, low + 1))
        return lower + (upper - lower) * (position - Double(low))
    }

    /// The `rank`th smallest count (0 the smallest), the counts of a bin spread evenly over it.
    private func value(at rank: Int) -> Double {
        var before = 0
        for (index, minutes) in bins.enumerated() where minutes > 0 {
            if rank < before + minutes {
                let range = Self.range(of: index)
                guard range.width > 1 else { return Double(range.lowest) }
                return Double(range.lowest) + Double(range.width - 1) * (Double(rank - before) + 0.5) / Double(minutes)
            }
            before += minutes
        }
        return Double(Self.range(of: max(0, bins.count - 1)).lowest)
    }
}
