#if DEBUG
import Foundation

/// Debug builds only: the numbers `NVRProbe` writes (`<data>/probe/*.json`) and `Tools/nvr_soak_report.py` judges against the budgets of
/// the Mac spec section 14. Nearest-rank percentiles: the value at rank `ceil(p / 100 x n)` of the sorted samples, so a p95 is a sample
/// that really happened and never an interpolation between two.
nonisolated struct ProbeSummary: Codable, Equatable, Sendable {
    var count: Int
    var min: Double
    var p50: Double
    var p95: Double
    var p99: Double
    var max: Double
    var mean: Double
}

nonisolated enum ProbeStatistics {
    /// Nearest-rank percentile of already sorted values; `percent` 0...100. nil for no values.
    static func percentile(sorted values: [Double], _ percent: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let rank = Int((percent / 100 * Double(values.count)).rounded(.up))
        return values[Swift.min(values.count, Swift.max(1, rank)) - 1]
    }

    static func summary(_ values: [Double]) -> ProbeSummary? {
        let sorted = values.filter(\.isFinite).sorted()
        guard let first = sorted.first, let last = sorted.last, let p50 = percentile(sorted: sorted, 50),
              let p95 = percentile(sorted: sorted, 95), let p99 = percentile(sorted: sorted, 99) else { return nil }
        return ProbeSummary(count: sorted.count, min: first, p50: p50, p95: p95, p99: p99, max: last, mean: sorted.reduce(0, +) / Double(sorted.count))
    }

    /// Milliseconds between two `DispatchTime.uptimeNanoseconds` readings.
    static func milliseconds(from start: UInt64, to end: UInt64) -> Double { Double(end &- start) / 1_000_000 }

    /// Pictures per second: how many different values `pictures` shows over `seconds` (consecutive repeats are one picture).
    static func distinctPictureRate(_ pictures: [Int], seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        var count = 0
        var last: Int?
        for picture in pictures where picture != last {
            count += 1
            last = picture
        }
        return Double(count) / seconds
    }

    /// The longest time any value in `times` (ascending, seconds) waited for the next one, counting from `start` to the first and from the last to `end`.
    static func longestGap(_ times: [Double], from start: Double, to end: Double) -> Double {
        var previous = start
        var worst = 0.0
        for time in times {
            worst = Swift.max(worst, time - previous)
            previous = time
        }
        return Swift.max(worst, end - previous)
    }
}
#endif
