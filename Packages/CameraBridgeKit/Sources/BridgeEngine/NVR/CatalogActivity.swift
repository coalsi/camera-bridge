import Foundation

/// Activity bins from pieces of recorded video (Mac spec 7, "Activity"). Pure: the store gathers the pieces from rollups (bins of a minute or
/// more) or from fragment tables (finer bins) and this adds them up.
enum CatalogActivity {
    /// A piece of recorded video with the non-keyframe bytes in it. Its bytes are taken as spread evenly over it.
    struct Interval: Equatable, Sendable {
        var startMs: Int64
        var endMs: Int64
        var nonKeyBytes: Double
        /// The busiest fragment's non-keyframe bytes per second inside it.
        var peakRate: Double
    }

    /// The pieces of a closed or open file that `rollups` describe, cut at `visibleEndMs` (where a later-starting file takes over). A rollup
    /// covers the first `coveredMs` milliseconds of its minute; when the cut falls inside it only the part before the cut counts, with its
    /// share of the bytes.
    static func intervals(rollups: [CBIndexRollup], fileStartMs: Int64, visibleEndMs: Int64) -> [Interval] {
        var result: [Interval] = []
        result.reserveCapacity(rollups.count)
        for (minute, rollup) in rollups.enumerated() where rollup.coveredMs > 0 {
            let start = fileStartMs + Int64(minute) * CBIndexRollups.minuteMs
            let end = min(start + Int64(rollup.coveredMs), visibleEndMs)
            guard end > start else { continue }
            let share = Double(end - start) / Double(rollup.coveredMs)
            result.append(Interval(startMs: start, endMs: end, nonKeyBytes: Double(rollup.nonKeyBytes) * share, peakRate: Double(rollup.peakRate)))
        }
        return result
    }

    /// The pieces of a file from its fragment table, cut at `visibleEndMs`.
    static func intervals(table: [CBIndexFragmentRecord], fileStartMs: Int64, fileEndMs: Int64, visibleEndMs: Int64) -> [Interval] {
        var result: [Interval] = []
        result.reserveCapacity(table.count)
        for (index, record) in table.enumerated() {
            let start = fileStartMs + Int64(record.wallDeltaMs)
            let fullEnd = index + 1 < table.count ? fileStartMs + Int64(table[index + 1].wallDeltaMs) : fileEndMs
            let end = min(fullEnd, visibleEndMs)
            guard end > start, fullEnd > start else { continue }
            let share = Double(end - start) / Double(fullEnd - start)
            result.append(Interval(startMs: start, endMs: end, nonKeyBytes: Double(record.nonKeyBytes) * share,
                                   peakRate: Double(record.nonKeyBytes) * 1_000 / Double(fullEnd - start)))
        }
        return result
    }

    /// `binCount` bins of `binMs` milliseconds from `rangeStartMs`. A bin's `coverage` is the part of it with video, `level` the mean
    /// non-keyframe bytes per second over that part (so `level x coverage x bin length` is the bytes in the bin), `peak` the busiest piece's.
    static func bins(rangeStartMs: Int64, binMs: Double, binCount: Int, intervals: [Interval]) -> [ArchiveActivity.Bin] {
        guard binCount > 0, binMs > 0 else { return [] }
        var covered = [Double](repeating: 0, count: binCount)
        var bytes = [Double](repeating: 0, count: binCount)
        var peak = [Double](repeating: 0, count: binCount)
        let rangeLength = binMs * Double(binCount)
        for interval in intervals {
            let start = Double(interval.startMs - rangeStartMs)
            let end = Double(interval.endMs - rangeStartMs)
            guard end > start, end > 0, start < rangeLength else { continue }
            let length = end - start
            var bin = max(0, Int(start / binMs))
            while bin < binCount, Double(bin) * binMs < end {
                let low = max(start, Double(bin) * binMs)
                let high = min(end, Double(bin + 1) * binMs)
                if high > low {
                    covered[bin] += high - low
                    bytes[bin] += interval.nonKeyBytes * (high - low) / length
                    peak[bin] = max(peak[bin], interval.peakRate)
                }
                bin += 1
            }
        }
        return (0..<binCount).map { bin in
            let seconds = covered[bin] / 1_000
            return ArchiveActivity.Bin(coverage: min(1, covered[bin] / binMs), level: seconds > 0 ? bytes[bin] / seconds : 0, peak: peak[bin])
        }
    }

    /// The median non-keyframe bytes per second over the recorded minutes (those with at least 30 s of video); nil under 30 such minutes
    /// (`ArchiveConstants.typicalMinimumRecorded`: 30 minutes of recorded video).
    static func typical(minutes: [(coveredMs: Int, nonKeyBytes: UInt32)]) -> Double? {
        let rates = minutes.filter { $0.coveredMs >= 30_000 }.map { Double($0.nonKeyBytes) / (Double($0.coveredMs) / 1_000) }.sorted()
        guard Double(rates.count) * 60 >= ArchiveConstants.typicalMinimumRecorded else { return nil }
        let middle = rates.count / 2
        return rates.count.isMultiple(of: 2) ? (rates[middle - 1] + rates[middle]) / 2 : rates[middle]
    }
}
