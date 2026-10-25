import Foundation

/// What the flight sources have said about each aircraft lately: its reports in time order, the last `keep` seconds of them (counted from the
/// newest report that came with the latest `add`, so a clock that steps does not leave it empty or full of the past). The matcher reads an
/// aircraft's history for the time of a track (`tracks(overlapping:)`) and interpolates in it.
///
/// A feed is somebody else's input, so the history is bounded: at most `maximumAircraft` aircraft (the ones heard from longest ago go
/// first) and `maximumReports` reports of each (the oldest go first), and a report that is not a place and a time is not kept. Two reports of
/// one aircraft for the same time are one: the later answer replaces the earlier.
actor FlightHistory {
    static let maximumAircraft = 10_000
    static let maximumReports = 1_200
    /// An aircraft heard from nowhere near a time is not in the answer for it: the oldest position a feed gives is this old.
    static let nearness = AircraftFeedParser.maximumPositionAge
    /// How often (in feed time) the aircraft that have not been heard from are looked for and forgotten.
    static let sweepInterval: TimeInterval = 30

    private let keep: TimeInterval
    private var reports: [String: [AircraftReport]] = [:]
    private var lastSweep: Date?

    init(keep: TimeInterval = 900) {
        self.keep = keep.isFinite ? max(1, keep) : 900
    }

    /// The number of aircraft with a report in the history.
    var aircraftCount: Int { reports.count }

    func add(_ new: [AircraftReport]) {
        let usable = new.filter(Self.isUsable)
        guard let newest = usable.map(\.positionTime).max() else { return }
        let cutoff = newest.addingTimeInterval(-keep)
        var touched = Set<String>()
        for report in usable {
            Self.insert(report, into: &reports[report.hex, default: []])
            touched.insert(report.hex)
        }
        for hex in touched { trim(hex, before: cutoff) }
        if lastSweep.map({ newest.timeIntervalSince($0) >= Self.sweepInterval || newest < $0 }) ?? true {
            lastSweep = newest
            for hex in reports.keys where !touched.contains(hex) { trim(hex, before: cutoff) }
        }
        if reports.count > Self.maximumAircraft {
            // The ones heard from longest ago go; of two heard at the same time, the lower hex.
            let heard = reports.map { (hex: $0.key, last: $0.value.last?.positionTime ?? .distantPast) }
            for stale in heard.sorted(by: { ($0.last, $0.hex) < ($1.last, $1.hex) }).prefix(reports.count - Self.maximumAircraft) {
                reports[stale.hex] = nil
            }
        }
    }

    /// For each aircraft heard from near `range` (within `nearness` of it), its reports inside the range and the nearest one on each side of
    /// it (the last at or before its start, the first at or after its end, when they are near), in time order: what it takes to place the
    /// aircraft at every moment of the range, by interpolating, or by extrapolating from the end.
    func tracks(overlapping range: ClosedRange<Date>) -> [String: [AircraftReport]] {
        let early = range.lowerBound.addingTimeInterval(-Self.nearness), late = range.upperBound.addingTimeInterval(Self.nearness)
        var found: [String: [AircraftReport]] = [:]
        for (hex, list) in reports {
            guard let first = list.first, let last = list.last, last.positionTime >= early, first.positionTime <= late else { continue }
            var from = max(0, Self.firstIndex(in: list, after: range.lowerBound) - 1)
            var to = min(list.count - 1, Self.firstIndex(in: list, atOrAfter: range.upperBound))
            if list[from].positionTime < early { from += 1 }
            if list[to].positionTime > late { to -= 1 }
            if from <= to { found[hex] = Array(list[from...to]) }
        }
        return found
    }

    // MARK: Keeping the reports

    private static func isUsable(_ report: AircraftReport) -> Bool {
        !report.hex.isEmpty && report.latitude.isFinite && (-90.0...90.0).contains(report.latitude) && report.longitude.isFinite
            && (-180.0...180.0).contains(report.longitude) && report.altitudeMeters.isFinite && report.positionTime.timeIntervalSince1970.isFinite
    }

    /// Puts `report` in `list` at its time; a report for that time is replaced. The newest end is the usual place.
    private static func insert(_ report: AircraftReport, into list: inout [AircraftReport]) {
        if let last = list.last, report.positionTime <= last.positionTime {
            let index = firstIndex(in: list, atOrAfter: report.positionTime)
            if list[index].positionTime == report.positionTime { list[index] = report } else { list.insert(report, at: index) }
        } else {
            list.append(report)
        }
        if list.count > maximumReports { list.removeFirst(list.count - maximumReports) }
    }

    /// Forgets the reports of `hex` before `cutoff`, and the aircraft when none is left.
    private func trim(_ hex: String, before cutoff: Date) {
        guard var list = reports[hex] else { return }
        let old = Self.firstIndex(in: list, atOrAfter: cutoff)
        guard old > 0 else { return }
        reports[hex] = nil
        if old < list.count {
            list.removeFirst(old)
            reports[hex] = list
        }
    }

    /// The first index of `list` (in time order) whose report is at or after `time`; the count when there is none.
    private static func firstIndex(in list: [AircraftReport], atOrAfter time: Date) -> Int {
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].positionTime < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The first index whose report is after `time`.
    private static func firstIndex(in list: [AircraftReport], after time: Date) -> Int {
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].positionTime <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
