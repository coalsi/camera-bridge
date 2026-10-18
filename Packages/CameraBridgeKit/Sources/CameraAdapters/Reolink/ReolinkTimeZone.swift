import Foundation

/// A Reolink camera's time zone as its HTTP API has it (v8 guide §3.1.5–3.1.6, `GetTime` / `SetTime`): `Time.timeZone`, an offset in
/// seconds, and `Dst`, the daylight-saving switch (`enable`) with its rule: `startMon` 1…12, `startWeek` 1…5 (5: the last), `startWeekday`
/// 0…6 (0: Sunday, as reolink_aio reads it), `startHour`, `startMin`, `startSec`, the same for `end…`, and `offset`, the shift in hours
/// (1 or 2). POSIX TZ rules ("M3.2.0/2") map onto these fields one to one.
///
/// The sign of `timeZone`: the guide's range (-46800…43200) runs from UTC+13 to UTC−12, so it counts west of UTC, as POSIX does, and so
/// does reolink_aio's zone with daylight saving (its zone without daylight saving reads the other way). A camera's own clock settles it:
/// `GetTime`'s `Time` is the camera's local time, so a camera whose local time is UTC plus `timeZone` counts east (`countsEast`), and is
/// read and written its way. Never written with the other sign.
struct ReolinkTimeZone: Equatable {
    /// Seconds west of UTC (POSIX's sign), whatever the camera's sign.
    var standardWest: Int
    /// The daylight-saving rule, the `Dst` fields below as numbers; nil when the zone has none (or the camera's switch is off).
    var rule: [String: Int]?

    static let ruleKeys = ["startMon", "startWeek", "startWeekday", "startHour", "startMin", "startSec",
                           "endMon", "endWeek", "endWeekday", "endHour", "endMin", "endSec", "offset"]

    init(standardWest: Int, rule: [String: Int]?) {
        self.standardWest = standardWest
        self.rule = rule
    }

    /// The zone a POSIX TZ string describes; nil for one Reolink's fields cannot carry: a daylight-saving shift other than 1 or 2 hours, a
    /// rule that is not "Mm.w.d", a change outside the day's 24 hours.
    init?(posix: String) {
        guard let parsed = HikvisionTimeZone.parse(posix) else { return nil }
        standardWest = parsed.standardSeconds
        guard let dst = parsed.dst else {
            rule = nil
            return
        }
        let shift = parsed.standardSeconds - dst.offsetSeconds   // POSIX offsets are west-positive: summer time is less west
        guard shift == 3600 || shift == 7200, let start = Self.fields(dst.start, at: dst.startTime, "start"),
              let end = Self.fields(dst.end, at: dst.endTime, "end") else { return nil }
        rule = start.merging(end) { first, _ in first }.merging(["offset": shift / 3600]) { first, _ in first }
    }

    /// "M3.2.0" at 7200 s as `start` fields: `startMon` 3, `startWeek` 2, `startWeekday` 0, `startHour` 2, `startMin` 0, `startSec` 0.
    private static func fields(_ date: String, at time: Int, _ prefix: String) -> [String: Int]? {
        let parts = date.dropFirst().split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard date.hasPrefix("M"), parts.count == 3, let month = parts[0], let week = parts[1], let weekday = parts[2],
              (1...12).contains(month), (1...5).contains(week), (0...6).contains(weekday), (0..<86_400).contains(time) else { return nil }
        return ["\(prefix)Mon": month, "\(prefix)Week": week, "\(prefix)Weekday": weekday,
                "\(prefix)Hour": time / 3600, "\(prefix)Min": time / 60 % 60, "\(prefix)Sec": time % 60]
    }

    /// The camera's zone from `GetTime`'s value; nil without `Time.timeZone` or `Dst.enable`. `countsEast`: as `countsEast(_:now:)` found.
    init?(camera value: JSONValue, countsEast: Bool) {
        guard let zone = value["Time"]?["timeZone"]?.int, let enable = value["Dst"]?["enable"]?.int else { return nil }
        standardWest = countsEast ? -zone : zone
        guard enable != 0, let dst = value["Dst"]?.object else {
            rule = nil
            return
        }
        var rule: [String: Int] = [:]
        for key in Self.ruleKeys { if let number = dst[key]?.int { rule[key] = number } }
        self.rule = rule
    }

    /// Whether the camera counts `Time.timeZone` east of UTC: its local time (`Time`'s `year`…`sec`) is UTC plus `timeZone` (with its
    /// daylight-saving shift, while that is on) within 15 minutes of `now`, and not UTC minus it. A clock that fits neither way (it is off,
    /// or `timeZone` is 0) keeps the guide's sign, west.
    static func countsEast(_ value: JSONValue, now: Date) -> Bool {
        guard let time = value["Time"], let zone = time["timeZone"]?.int, zone != 0, let year = time["year"]?.int, let month = time["mon"]?.int,
              let day = time["day"]?.int, let hour = time["hour"]?.int, let minute = time["min"]?.int, let second = time["sec"]?.int else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        guard let local = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else {
            return false
        }
        let ahead = local.timeIntervalSince(now)
        let shift = value["Dst"]?["enable"]?.int == 1 ? Double((value["Dst"]?["offset"]?.int ?? 1) * 3600) : 0
        func fits(_ east: Double) -> Bool { abs(ahead - east) <= 900 || (shift > 0 && abs(ahead - east - shift) <= 900) }
        return fits(Double(zone)) && !fits(Double(-zone))
    }

    /// Whether the camera has this zone: the same standard offset, and daylight saving with the same rule, or none on both.
    func matches(_ wanted: ReolinkTimeZone) -> Bool {
        standardWest == wanted.standardWest && rule == wanted.rule
    }

    /// "UTC−7", "UTC+1 with daylight saving"; "… with daylight saving on other dates" when only the rule differs from `wanted`'s.
    func text(against wanted: ReolinkTimeZone? = nil) -> String {
        let offset = CameraSetupText.zone("UTC" + HikvisionTimeZone.offset(standardWest))
        guard rule != nil else { return offset }
        let otherDates = wanted.map { $0.standardWest == standardWest && $0.rule != nil && $0.rule != rule } ?? false
        return offset + (otherDates ? " with daylight saving on other dates" : " with daylight saving")
    }

    /// `SetTime`'s `param` that gives the camera (`GetTime`'s value) `wanted`: `Dst` as read with `enable` and, for a zone with daylight saving,
    /// its rule; `Time` with only `timeZone` (in the camera's sign). Each is sent only when it changes (every `SetTime` field is optional in the
    /// guide; the camera's clock itself is never written). nil when nothing changes.
    static func setTimeParam(_ value: JSONValue, wanted: ReolinkTimeZone, countsEast: Bool) -> JSONValue? {
        var param: [String: JSONValue] = [:]
        let dst = value["Dst"]?.object ?? [:]
        var edited = dst
        edited["enable"] = .number(wanted.rule == nil ? 0 : 1)
        for (key, number) in wanted.rule ?? [:] { edited[key] = .number(Double(number)) }
        if edited != dst { param["Dst"] = .object(edited) }
        let zone = countsEast ? -wanted.standardWest : wanted.standardWest
        if value["Time"]?["timeZone"]?.int != zone { param["Time"] = .object(["timeZone": .number(Double(zone))]) }
        return param.isEmpty ? nil : .object(param)
    }

    /// What Restore needs, as the camera has it: `timeZone` (in the camera's own sign) and every number of `Dst` ("Dst.enable", "Dst.startMon",
    /// …). nil without `Time.timeZone`.
    static func saved(_ value: JSONValue) -> [String: Int]? {
        guard let zone = value["Time"]?["timeZone"]?.int else { return nil }
        var saved = ["timeZone": zone]
        for (key, item) in value["Dst"]?.object ?? [:] {
            if let number = item.int { saved["Dst.\(key)"] = number }
        }
        return saved
    }

    /// `SetTime`'s `param` that puts back what `saved` kept: `Dst` as read with the saved numbers, `Time` with the saved `timeZone`; each
    /// only when it differs. nil when the camera already has it all.
    static func restoreParam(_ value: JSONValue, saved: [String: Int]) -> JSONValue? {
        var param: [String: JSONValue] = [:]
        let dst = value["Dst"]?.object ?? [:]
        var edited = dst
        for (key, number) in saved where key.hasPrefix("Dst.") { edited[String(key.dropFirst(4))] = .number(Double(number)) }
        if edited != dst { param["Dst"] = .object(edited) }
        if let zone = saved["timeZone"], value["Time"]?["timeZone"]?.int != zone { param["Time"] = .object(["timeZone": .number(Double(zone))]) }
        return param.isEmpty ? nil : .object(param)
    }
}
