import BridgeSupport
import Foundation

/// How many descriptions were asked of the AI service on each of the last days, by the day's name in the bridge's time zone ("2026-10-18"), so
/// the daily limit survives a restart: `<data>/ai/usage.json`, mode 0600 in a folder of 0700, `{"days":{"2026-10-18":12,…},"v":1}`. The last
/// `daysKept` days are kept (today and the week before it), and any day after today (a clock that was wrong when it was counted); a file
/// that cannot be read starts the count again at zero.
struct AIUsage: Codable, Equatable, Sendable {
    static let version = 1
    static let daysKept = 8

    var v = AIUsage.version
    var days: [String: Int] = [:]

    /// Descriptions asked for on the day of `date` in `zone`.
    func count(on date: Date, in zone: TimeZone) -> Int {
        days[Self.dayName(date, in: zone)] ?? 0
    }

    /// Descriptions asked for on the day of `date` and the six days before it.
    func lastSevenDays(_ date: Date, in zone: TimeZone) -> Int {
        Self.dayNames(endingAt: date, count: 7, in: zone).reduce(0) { $0 + (days[$1] ?? 0) }
    }

    /// One more on the day of `date`. Only days older than `daysKept` days before it are forgotten: a day after `date` stays, so a clock that
    /// is wrong when the bridge starts (before the time is set) cannot wipe the week that was saved. (Day names sort as dates do.)
    mutating func add(at date: Date, in zone: TimeZone) {
        if let oldest = Self.dayNames(endingAt: date, count: Self.daysKept, in: zone).last {
            days = days.filter { $0.key >= oldest }
        }
        days[Self.dayName(date, in: zone), default: 0] += 1
    }

    /// "2026-10-18": the calendar day of `date` in `zone`.
    static func dayName(_ date: Date, in zone: TimeZone) -> String {
        let parts = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The names of the `count` days ending with the day of `date`, newest first. Days are counted on the calendar, so a 23- or 25-hour day
    /// (daylight saving time) is one day.
    static func dayNames(endingAt date: Date, count: Int, in zone: TimeZone) -> [String] {
        let calendar = calendar(zone)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        return (0..<count).map { offset in dayName(calendar.date(byAdding: .day, value: -offset, to: noon) ?? noon, in: zone) }
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    // MARK: The file

    /// The counts in `url`; none when there is no file. One that cannot be read is logged (by its name) and counts as none.
    static func load(from url: URL, log: Log) -> AIUsage {
        guard PrivateFiles.exists(url) else { return AIUsage() }
        do {
            let usage = try JSONDecoder().decode(AIUsage.self, from: Data(contentsOf: url))
            return AIUsage(days: usage.days.filter { $0.value > 0 })
        } catch {
            log.warning("The AI descriptions' daily count (\(url.lastPathComponent)) could not be read; it starts again at zero")
            return AIUsage()
        }
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFiles.prepareDirectory(url.deletingLastPathComponent())
        try PrivateFiles.write(try encoder.encode(self), to: url)
    }
}
