import Foundation

/// The Sun's position, low precision (Meeus, "Astronomical Algorithms", chapter 25): within 0.01°, plenty for sunsets, twilight and
/// whether a satellite is sunlit.
enum SunEphemeris {
    /// The Sun's centre at this elevation is sunset and sunrise: its upper edge on the horizon, with the usual refraction.
    static let horizonElevation = -0.833
    /// Below this elevation the observer is in darkness (the end of civil twilight).
    static let darkElevation = -6.0

    /// The apparent right ascension and declination (degrees, of the date) at `date`. The date is taken as dynamical time: the minute or so
    /// between it and UTC moves the Sun by 0.001°.
    static func equatorial(at date: Date) -> (rightAscension: Double, declination: Double) {
        let t = SkyMath.daysSinceJ2000(date) / 36_525
        let meanLongitude = 280.466_46 + t * (36_000.769_83 + t * 0.000_303_2)
        let meanAnomaly = (357.529_11 + t * (35_999.050_29 - t * 0.000_153_7)) * SkyMath.radians
        let centre = (1.914_602 - t * (0.004_817 + t * 0.000_014)) * sin(meanAnomaly)
            + (0.019_993 - t * 0.000_101) * sin(2 * meanAnomaly) + 0.000_289 * sin(3 * meanAnomaly)
        let node = (125.04 - 1_934.136 * t) * SkyMath.radians
        let longitude = SkyMath.normalizedDegrees(meanLongitude + centre - 0.005_69 - 0.004_78 * sin(node)) * SkyMath.radians
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815_0 + t * (0.000_59 - t * 0.001_813))) / 60) / 60
        let obliquity = (meanObliquity + 0.002_56 * cos(node)) * SkyMath.radians
        let rightAscension = atan2(cos(obliquity) * sin(longitude), cos(longitude)) * SkyMath.degrees
        return (SkyMath.normalizedDegrees(rightAscension), asin(sin(obliquity) * sin(longitude)) * SkyMath.degrees)
    }

    /// Where the Sun's centre is from `observer` at `date` (geometric; compare with `horizonElevation` and `darkElevation`).
    static func direction(at date: Date, observer: SkyObserver) -> SkyDirection {
        let sun = equatorial(at: date)
        return SkyMath.horizontal(rightAscension: sun.rightAscension, declination: sun.declination, at: date, observer: observer)
    }
}

/// Which part of a sky log a view shows: the night (sunset to sunrise) or the day.
public enum SkyLogView: String, Codable, Sendable {
    case night
    case day
}

/// One night at the observer, named after the local date of its sunset.
struct SkyNightWindow: Sendable, Equatable {
    /// "yyyy-MM-dd": the local date of the sunset.
    var name: String
    /// The night's first moment (the Sun's centre below `SunEphemeris.horizonElevation`): nil when the Sun does not set that day (the midnight
    /// sun, or the polar night, when it never rose).
    var sunset: Date?
    /// The first moment after the sunset when the Sun is up again: nil when it does not rise by the end of the next local day (a polar night
    /// begins).
    var sunrise: Date?
}

/// Nights by the Sun's times at the observer, in the local time zone. A night is one window from its sunset to the next sunrise, across
/// midnight and daylight saving time, named after the local date of the sunset; a day the Sun does not set (the midnight sun, the polar
/// night) has no night.
enum SkyNight {
    /// How often the Sun's elevation is looked at when finding a sunset or sunrise; the crossing is then narrowed to under a second.
    static let step: TimeInterval = 600

    /// The night named `name` ("yyyy-MM-dd", the local date of its sunset): its sunset is the Sun's first setting that local day, its sunrise
    /// the next rising, looked for to the end of the following day. A name that is not a date has neither.
    static func window(named name: String, observer: SkyObserver, zone: TimeZone) -> SkyNightWindow {
        let none = SkyNightWindow(name: name, sunset: nil, sunrise: nil)
        guard let day = localDay(named: name, zone: zone), let following = localDay(after: day, zone: zone),
              let sunset = firstCrossing(rising: false, from: day.start, to: day.end, observer: observer) else { return none }
        return SkyNightWindow(name: name, sunset: sunset,
                              sunrise: firstCrossing(rising: true, from: sunset, to: following.end, observer: observer))
    }

    /// The name of the night that contains `date` or, in the day, of the latest one that ended before it (the night that ended that morning).
    /// With no night that day or the day before (the midnight sun, the polar night), the local date of `date` itself.
    static func name(containing date: Date, observer: SkyObserver, zone: TimeZone) -> String {
        let today = dayName(date, zone: zone)
        guard let day = localDay(named: today, zone: zone), let previous = localDay(before: day, zone: zone) else { return today }
        let windows = [today, dayName(previous.middle, zone: zone)].map { window(named: $0, observer: observer, zone: zone) }
        let nights = windows.map { (name: $0.name, night: night(of: $0, zone: zone)) }
        if let containing = nights.first(where: { $0.night?.contains(date) == true }) { return containing.name }
        if let ended = nights.first(where: { ($0.night?.upperBound).map { $0 <= date } == true }) { return ended.name }
        return today
    }

    /// The time a view of `window`'s log covers. The night: sunset to sunrise, or to the end of its local day when the Sun does not rise
    /// by the end of the next one; empty (one instant, the local day's end) when there is no sunset. The day: the local day the night is named
    /// after, midnight to midnight (23 or 25 hours across a daylight saving change).
    static func span(_ window: SkyNightWindow, view: SkyLogView, zone: TimeZone) -> ClosedRange<Date> {
        let day = localDay(of: window, zone: zone)
        switch view {
        case .day: return day.start...day.end
        case .night: return night(of: window, zone: zone) ?? day.end...day.end
        }
    }

    // MARK: Local days

    /// "yyyy-MM-dd": the local date of `date` in `zone` (the Gregorian calendar). A date the calendar cannot place (not a number, or more
    /// than 30,000 years away) gets "0000-00-00", which names no night.
    static func dayName(_ date: Date, zone: TimeZone) -> String {
        guard isPlaceable(date) else { return "0000-00-00" }
        let parts = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Whether the calendar can be asked about `date`.
    private static func isPlaceable(_ date: Date) -> Bool {
        abs(date.timeIntervalSince1970) < 1e12
    }

    /// The local day named "yyyy-MM-dd" in `zone`: its first moment, its noon and the next day's first moment (23, 24 or 25 hours after the
    /// first). Nil for a name that is not a date.
    static func localDay(named name: String, zone: TimeZone) -> (start: Date, middle: Date, end: Date)? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.map(\.count) == [4, 2, 2], parts.allSatisfy({ $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let noon = calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              dayName(noon, zone: zone) == name else { return nil }
        return localDay(around: noon, zone: zone)
    }

    /// The local day around `noon` (any moment of it).
    private static func localDay(around noon: Date, zone: TimeZone) -> (start: Date, middle: Date, end: Date)? {
        let calendar = calendar(zone)
        guard isPlaceable(noon), let next = calendar.date(byAdding: .day, value: 1, to: noon) else { return nil }
        let start = calendar.startOfDay(for: noon), end = calendar.startOfDay(for: next)
        return start < end ? (start, noon, end) : nil
    }

    private static func localDay(after day: (start: Date, middle: Date, end: Date), zone: TimeZone) -> (start: Date, middle: Date, end: Date)? {
        calendar(zone).date(byAdding: .day, value: 1, to: day.middle).flatMap { localDay(around: $0, zone: zone) }
    }

    private static func localDay(before day: (start: Date, middle: Date, end: Date), zone: TimeZone) -> (start: Date, middle: Date, end: Date)? {
        calendar(zone).date(byAdding: .day, value: -1, to: day.middle).flatMap { localDay(around: $0, zone: zone) }
    }

    /// The local day a window is named after; one that is not a date falls back to its sunset's day, and without one to a single instant.
    private static func localDay(of window: SkyNightWindow, zone: TimeZone) -> (start: Date, end: Date) {
        if let day = localDay(named: window.name, zone: zone) { return (day.start, day.end) }
        let moments = [window.sunset, window.sunrise].compactMap { $0 }.filter(isPlaceable)
        if let moment = moments.first, let day = localDay(around: moment, zone: zone) { return (day.start, day.end) }
        let moment = moments.first ?? Date(timeIntervalSince1970: 0)
        return (moment, moment)
    }

    /// A window's night: sunset to sunrise, or to the end of its local day without a sunrise; nil without a sunset.
    private static func night(of window: SkyNightWindow, zone: TimeZone) -> ClosedRange<Date>? {
        guard let sunset = window.sunset, isPlaceable(sunset) else { return nil }
        let end = window.sunrise.flatMap { isPlaceable($0) ? $0 : nil } ?? localDay(of: window, zone: zone).end
        return sunset...max(sunset, end)
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    // MARK: The Sun's crossings

    /// The first moment in `start…end` at which the Sun's centre passes `SunEphemeris.horizonElevation`, going down (`rising` false, a
    /// sunset: the first moment below) or up (a sunrise: the first moment at or above). Sampled every `step`, then halved to 0.15 s.
    static func firstCrossing(rising: Bool, from start: Date, to end: Date, observer: SkyObserver) -> Date? {
        func crossed(_ moment: Date) -> Bool {
            (SunEphemeris.direction(at: moment, observer: observer).elevation >= SunEphemeris.horizonElevation) == rising
        }
        var before = start
        var beforeCrossed = crossed(start)
        while before < end {
            let after = min(before.addingTimeInterval(step), end)
            let afterCrossed = crossed(after)
            if !beforeCrossed && afterCrossed {
                var low = before, high = after
                for _ in 0..<12 {
                    let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                    if crossed(middle) { high = middle } else { low = middle }
                }
                return high
            }
            before = after
            beforeCrossed = afterCrossed
        }
        return nil
    }
}
