import BridgeEngine
import Foundation

/// The activity waveform of the timeline: one column per bin of the activity answer, for one camera or for all cameras of the NVR page.
///
/// The signal is the recorded video's non-keyframe bytes per second: it follows activity on variable-bitrate and smart-codec streams and is a flat
/// line on a constant-bitrate camera. A camera's "normal" is one number, the median of its last 24 hours (`ArchiveActivity.typical`, nil under
/// 30 minutes of video); there is no time-of-day baseline, because the footage it would be built from is what retention deletes.
nonisolated struct WaveformColumns: Equatable, Sendable {
    /// One entry per column: 0...1, how much of the column has recorded video (0 in every camera: a gap, drawn hatched).
    var coverage: [Double]
    /// One entry per column: the activity relative to normal (1 is the camera's typical level), the largest over the cameras that recorded.
    var level: [Double]

    static let empty = WaveformColumns(coverage: [], level: [])

    /// The columns of `activities` (one answer per camera, all asked for the same bins), `max over cameras of level / normal`. A camera whose
    /// `typical` is nil is judged against a quarter of its own p99 (at least 250 B/s), so a young archive still draws.
    static func combine(_ activities: [ArchiveActivity]) -> WaveformColumns {
        guard let count = activities.map({ $0.bins.count }).min(), count > 0 else { return .empty }
        let normals = activities.map(normal(of:))
        var coverage = [Double](repeating: 0, count: count)
        var level = [Double](repeating: 0, count: count)
        for (activity, normal) in zip(activities, normals) {
            for index in 0..<count {
                let bin = activity.bins[index]
                guard bin.coverage > 0 else { continue }
                coverage[index] = max(coverage[index], min(bin.coverage, 1))
                level[index] = max(level[index], bin.level / normal)
            }
        }
        return WaveformColumns(coverage: coverage, level: level)
    }

    /// The level one camera counts as normal, in bytes per second.
    static func normal(of activity: ArchiveActivity) -> Double {
        if let typical = activity.typical, typical > 0 { return typical }
        let recorded = activity.bins.filter { $0.coverage > 0 }.map(\.level)
        return max(WaveformScale.percentile99(recorded), WaveformScale.levelFloor) / 4
    }
}

nonisolated enum WaveformScale {
    /// The lowest p99 a young archive is scaled to (1 KB/s), so quiet noise is not stretched to full height.
    static let levelFloor = 1_000.0
    /// A bar above this many times normal is drawn amber (and is also taller than the dashed normal line, so colour is never the only signal).
    static let highActivity = 1.5

    /// `4 x typical`, or the p99 of `visibleLevels` with a 1 KB/s floor when `typical` is nil. With levels already relative to normal (the
    /// combined columns), pass a typical of 1: the reference is 4, and normal sits at half height.
    static func reference(typical: Double?, visibleLevels: [Double]) -> Double {
        if let typical, typical > 0 { return 4 * typical }
        return max(percentile99(visibleLevels), levelFloor)
    }

    /// `sqrt(min(level / reference, 1))`, drawn mirrored about the centre line.
    static func height(level: Double, reference: Double) -> Double {
        guard level > 0, reference > 0 else { return 0 }
        return (min(level / reference, 1)).squareRoot()
    }

    static func percentile99(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((0.99 * Double(sorted.count)).rounded(.up)) - 1)]
    }
}
