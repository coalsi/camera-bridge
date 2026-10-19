import Foundation
import Testing
@testable import BridgeEngine

/// The daily count (`AIUsage`): kept per calendar day in the bridge's zone, and only days older than the window are forgotten. Final review M5:
/// a clock that is wrong at boot (before chrony has synced) must not wipe the week that was saved.
@Suite struct AIUsageTests {
    static let zone = TimeZone(identifier: "America/Los_Angeles")!
    /// Monday 19 October 2026, 9:30 AM in Los Angeles.
    static let monday = Date(timeIntervalSince1970: 1_792_427_400)
    static let saved = ["2026-10-12": 4, "2026-10-13": 5, "2026-10-14": 6, "2026-10-15": 7, "2026-10-16": 8, "2026-10-17": 9, "2026-10-18": 10]

    @Test func daysOlderThanTheWindowAreForgottenAndTheRestKept() {
        var usage = AIUsage(days: Self.saved.merging(["2026-10-11": 3, "2026-09-01": 2]) { $1 })
        usage.add(at: Self.monday, in: Self.zone)
        #expect(usage.days == Self.saved.merging(["2026-10-19": 1]) { $1 }, "today and the seven days before it stay; older days go")
        #expect(usage.count(on: Self.monday, in: Self.zone) == 1)
        #expect(usage.lastSevenDays(Self.monday, in: Self.zone) == 1 + 10 + 9 + 8 + 7 + 6 + 5)
    }

    @Test func aWrongClockAtBootDoesNotWipeTheSavedWeek() {
        var usage = AIUsage(days: Self.saved)
        // The clock still says 1 January 2025 (before the time is set): one description is counted on that day.
        let wrong = Date(timeIntervalSince1970: 1_735_732_800)
        usage.add(at: wrong, in: Self.zone)
        #expect(usage.days["2025-01-01"] == 1)
        for (day, count) in Self.saved { #expect(usage.days[day] == count, "\(day) is still there") }

        // The clock is right again: today starts from what is really counted, and the week is whole.
        usage.add(at: Self.monday, in: Self.zone)
        #expect(usage.count(on: Self.monday, in: Self.zone) == 1)
        #expect(usage.lastSevenDays(Self.monday, in: Self.zone) == 1 + 10 + 9 + 8 + 7 + 6 + 5)
        #expect(usage.days["2025-01-01"] == nil, "the day the wrong clock made is older than the window now")
    }

    @Test func aClockSetBackKeepsTheLaterDays() {
        var usage = AIUsage(days: Self.saved)
        usage.add(at: Date(timeIntervalSince1970: Self.monday.timeIntervalSince1970 - 3 * 86_400), in: Self.zone)   // Friday 16 October
        #expect(usage.days["2026-10-17"] == 9 && usage.days["2026-10-18"] == 10, "days after the clock's day stay")
        #expect(usage.days["2026-10-16"] == 9, "and the clock's own day counts on from its saved number")
    }
}
