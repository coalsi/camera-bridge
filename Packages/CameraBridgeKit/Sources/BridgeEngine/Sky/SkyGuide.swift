import Foundation

/// How interesting an unexplained light is (`SkyGuide`): the log ranks the unexplained by it.
public enum SkyPriority: String, Codable, Sendable, CaseIterable {
    case high, medium, low
}

/// The guide to the unexplained (the owner's request of 2026-10-25): every light that nothing explains gets a priority and its reasons, short
/// plain phrases the page shows, the most telling first.
///
/// - **High** when it is unusual against the planes and satellites at its height (`SkyBaseline.unusual`): it crossed faster (`faster`), looks
///   larger (`larger`), stopped suddenly or turned sharply (when the shape can be trusted); or when it moved together with other lights
///   (`SkyFormations`, when the log is read).
/// - **Medium** when it only looks brighter; when it is a long, low, steady light that is neither a plane's nor a satellite's (followed 20 s
///   or more, at its middle under 15° up, neither blinking nor flashing like a strobe: on the owner's camera every long, low light the rules
///   left blinked, and was a distant plane); or when it appeared and stayed on one spot for seconds (2 to 60 s, ending within 0.7°
///   of where it began: the overnight prototype's "barely moved", 8 of its pixels; kept only when bright, Ruling S29), as the overnight test's
///   strangest lights did (a glint, a landing light pointed this way; one the owner called a meteor coming straight at the camera).
/// - **Low** otherwise, and always when the rules doubt it is a light at all (`SkyRules.doubt`): the doubt is its reason.
///
/// Before the camera has learned its sky the comparisons are against the plan's defaults, and the reasons say so ("typical planes").
enum SkyGuide {
    static let lowLongest: TimeInterval = 20
    static let lowHighest = 15.0
    static let spotShortest: TimeInterval = 2
    static let spotLongest: TimeInterval = 60
    static let spotFarthest = 0.7

    struct Assessment: Sendable, Equatable {
        var priority: SkyPriority
        var reasons: [String]
    }

    /// The priority and reasons of an unexplained light: `unusual` and `speedVsPlanes` as the baseline found them, `learned` whether that was
    /// against what the camera learned (else the defaults), `doubt` why the rules doubt it is a light.
    static func assess(_ m: SkyMeasures, unusual: [SkyUnusualReason], speedVsPlanes: Double?, learned: Bool, doubt: String?) -> Assessment {
        if let doubt { return Assessment(priority: .low, reasons: [doubt]) }
        var reasons: [String] = []
        if unusual.contains(.faster) { reasons.append(fasterReason(m, speedVsPlanes: speedVsPlanes, learned: learned)) }
        if unusual.contains(.larger) { reasons.append(learned ? "Looks larger than planes here" : "Looks larger than typical planes") }
        if unusual.contains(.suddenStop) { reasons.append("Stopped suddenly") }
        if unusual.contains(.sharpTurn) { reasons.append("Turned sharply") }
        if unusual.contains(.brighter) { reasons.append("Looks brighter than planes and satellites here") }
        if !reasons.isEmpty {
            return Assessment(priority: unusual.contains(where: { $0 != .brighter }) ? .high : .medium, reasons: reasons)
        }
        let middle = (m.elevation + m.elevationEnd) / 2
        if m.duration >= lowLongest && middle < lowHighest && !m.blinks && SkyRules.strobe(m) == nil {
            return Assessment(priority: .medium, reasons: ["Long, low and steady, but not like a plane or a satellite"])
        }
        if (spotShortest...spotLongest).contains(m.duration) && m.straightness * m.speed * m.duration <= spotFarthest {
            return Assessment(priority: .medium, reasons: ["Appeared and stayed on one spot for seconds"])
        }
        if m.duration < SkyRules.steadyShortest && m.straightness >= SkyRules.steadyStraightness && m.duration >= 1 {
            return Assessment(priority: .low, reasons: ["Too short to tell a plane from a satellite"])
        }
        if m.duration < 1 { return Assessment(priority: .low, reasons: ["Too short to tell what it was"]) }
        return Assessment(priority: .low, reasons: ["Nothing unusual about it"])
    }

    /// "Fast across the sky (about 6× a plane at that height)"; before learning, against the default speed planes stay under ("about 3×
    /// typical planes").
    static func fasterReason(_ m: SkyMeasures, speedVsPlanes: Double?, learned: Bool) -> String {
        if learned, let ratio = speedVsPlanes, ratio.isFinite, ratio > 0 {
            return "Fast across the sky (about \(times(ratio)) a plane at that height)"
        }
        return "Fast across the sky (about \(times(m.speed / SkyBaseline.defaultSpeed95)) typical planes)"
    }

    /// "6×", "2.5×": whole above 3, to a half below.
    static func times(_ ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else { return "1×" }
        if ratio >= 3 { return "\(Int(ratio.rounded()))×" }
        let half = (ratio * 2).rounded() / 2
        return half == half.rounded() ? "\(Int(half))×" : String(format: "%.1f×", locale: Locale(identifier: "en_US_POSIX"), half)
    }
}

/// Lights that moved together (the owner: "multiple objects moving the same direction-ish, high priority"), found when a night's log is read:
/// two unexplained lights the guide ranked (`SkyEntry.priority`), not doubted, seen at the same time for at least `overlap`, crossing the sky
/// the same way (their headings within `headings`) at a similar speed (within `speedRatio` of each other), near each other (`apart` to
/// `farthest` at the middle of the time they shared: not one light followed twice, and not two lights across the sky that chance sent the same
/// way), not one behind the other on one line within `onePiece` (two pieces of one light: a contrail, a plane's lights), and not begun in the
/// same picture (the camera changing its picture). A group is every light that moves together with all the others; each gets the group's name
/// (`SkyEntry.group`, from its first light), the priority high and the reason first.
///
/// The owner's words were "within the same few minutes": lights one after another minutes apart, on the owner's night of Oct 25, made 70 to 95
/// such "groups" (as the details went) out of fragments of planes and satellites crossing the same way; seen together, 3 (6 lights), and 2 as
/// the box would log that night now.
enum SkyFormations {
    static let overlap: TimeInterval = 1
    static let headings = 20.0
    static let speedRatio = 1.5
    static let apart = 0.5
    static let farthest = 20.0
    static let onePiece = 3.0
    static let reason = "Several lights moving together"

    /// `entries` (in any order) with the lights that moved together marked; the others as they were.
    static func mark(_ entries: [SkyEntry]) -> [SkyEntry] {
        var result = entries
        let candidates = entries.indices.filter { index in
            let entry = entries[index]
            return SkyDisplay.label(entry) == .unexplained && entry.priority != nil && !entry.doubtful && entry.kind == .track
                && entry.measures.speed.isFinite && entry.measures.speed > 0 && entry.end > entry.start
        }.sorted { (entries[$0].start, entries[$0].id) < (entries[$1].start, entries[$1].id) }
        var groups: [[Int]] = []
        // The groups that can still take a light, in the order they were begun, with the earliest end of their members: the lights come in the
        // order they began, and a light moves together only with lights it was seen with for `overlap`, so a group one of whose lights ended
        // before a light's start and `overlap` can take neither it nor any after it (a night of the old lights, sorted, holds many hundreds).
        var open: [(group: Int, ends: Date)] = []
        for index in candidates {
            let entry = entries[index]
            open.removeAll { $0.ends.timeIntervalSince(entry.start) < overlap }
            if let slot = open.firstIndex(where: { groups[$0.group].allSatisfy { together(entries[$0], entry) } }) {
                groups[open[slot].group].append(index)
                open[slot].ends = min(open[slot].ends, entry.end)
            } else {
                groups.append([index])
                open.append((group: groups.count - 1, ends: entry.end))
            }
        }
        for members in groups where members.count >= 2 {
            let name = "g-" + entries[members[0]].id
            for index in members {
                result[index].group = name
                result[index].priority = .high
                result[index].reasons = [reason] + result[index].reasons.filter { $0 != reason }
            }
        }
        return result
    }

    /// Whether two lights moved together.
    static func together(_ a: SkyEntry, _ b: SkyEntry) -> Bool {
        guard a.start != b.start else { return false }
        let from = max(a.start, b.start), to = min(a.end, b.end)
        guard to.timeIntervalSince(from) >= overlap else { return false }
        let slower = min(a.measures.speed, b.measures.speed), faster = max(a.measures.speed, b.measures.speed)
        guard slower > 0, faster / slower <= speedRatio else { return false }
        guard let headingA = heading(a), let headingB = heading(b) else { return false }
        let turn = abs((headingA - headingB).remainder(dividingBy: 360))
        guard turn <= headings else { return false }
        let middle = from.addingTimeInterval(to.timeIntervalSince(from) / 2)
        let here = position(a, at: middle), there = position(b, at: middle)
        let separation = SkyMath.separation(here, there)
        guard separation > apart, separation <= farthest else { return false }
        // One behind the other on its own line, close: two pieces of one light.
        if separation <= onePiece, let line = bearing(from: here, to: there) {
            let off = abs((line - headingA).remainder(dividingBy: 180))
            if off <= headings { return false }
        }
        return true
    }

    /// The bearing (degrees from up the sky, through east) of the great circle from `a` toward `b`; nil when they are one.
    static func bearing(from a: SkyDirection, to b: SkyDirection) -> Double? {
        guard SkyMath.separation(a, b) > 1e-6 else { return nil }
        let u = SkyMath.unitVector(a), v = SkyMath.unitVector(b)
        let radians = SkyMath.radians, az = a.azimuth * radians, el = a.elevation * radians
        let east = SIMD3(cos(az), -sin(az), 0.0)
        let north = SIMD3(-sin(el) * sin(az), -sin(el) * cos(az), cos(el))
        let toward = v - u * SkyMath.dot(u, v)
        return SkyMath.normalizedDegrees(atan2(SkyMath.dot(toward, east), SkyMath.dot(toward, north)) * SkyMath.degrees)
    }

    /// The way a light crossed the sky: the bearing (degrees from up the sky, through east) of the great circle from where it was first seen
    /// toward where it was last seen; nil when it did not move.
    static func heading(_ entry: SkyEntry) -> Double? {
        bearing(from: SkyDirection(azimuth: entry.measures.azimuth, elevation: entry.measures.elevation),
                to: SkyDirection(azimuth: entry.measures.azimuthEnd, elevation: entry.measures.elevationEnd))
    }

    /// Where a light was at `date`, along the great circle from its first direction to its last, at its time's share of the way.
    static func position(_ entry: SkyEntry, at date: Date) -> SkyDirection {
        let start = SkyMath.unitVector(SkyDirection(azimuth: entry.measures.azimuth, elevation: entry.measures.elevation))
        let end = SkyMath.unitVector(SkyDirection(azimuth: entry.measures.azimuthEnd, elevation: entry.measures.elevationEnd))
        let span = entry.end.timeIntervalSince(entry.start)
        let share = span > 0 ? min(1, max(0, date.timeIntervalSince(entry.start) / span)) : 0
        let mixed = start * (1 - share) + end * share
        let length = SkyMath.length(mixed)
        return SkyMath.direction(of: length > 0 ? mixed / length : start)
    }
}
