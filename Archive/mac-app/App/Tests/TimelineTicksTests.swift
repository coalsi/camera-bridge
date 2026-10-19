import CoreGraphics
import Foundation
import Testing

@Suite struct TimelineTicksTests {
    private func calendar(_ zone: String, locale: String = "en_GB") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        calendar.locale = Locale(identifier: locale)
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) ?? .distantPast
    }

    @Test func theStepIsTheSmallestOneWithEnoughRoom() {
        let viewport = TimelineViewport(start: Date(timeIntervalSinceReferenceDate: 0), duration: 600)   // 10 minutes over 1000 pt: 0.6 s per point
        #expect(TimelineTicks.step(for: viewport, width: 1_000, minSpacing: 80) == 60, "80 pt is 48 s: the next step is a minute")
        #expect(TimelineTicks.step(for: viewport, width: 1_000, minSpacing: 40) == 30)
        #expect(TimelineTicks.step(for: TimelineViewport(start: .distantPast, duration: 86_400 * 4_000), width: 800, minSpacing: 80) == 7_776_000, "never above a quarter")
        #expect(TimelineTicks.step(for: viewport, width: 0, minSpacing: 80) == 7_776_000)
    }

    @Test func minuteTicksFallOnWholeMinutesWithTheHourMarkedMajor() {
        let calendar = calendar("America/Los_Angeles")
        let start = date(calendar, 2026, 10, 10, 13, 24, 30)
        let ticks = TimelineTicks.make(viewport: TimelineViewport(start: start, duration: 3_600), width: 800, calendar: calendar, minSpacing: 80)
        // 3600 s over 800 pt: 4.5 s per point, 80 pt = 360 s: the step is 10 minutes.
        #expect(ticks.map(\.label) == ["13:30", "13:40", "13:50", "14:00", "14:10", "14:20"])
        #expect(ticks.map(\.isMajor) == [false, false, false, true, false, false])
        #expect(ticks.first?.time == date(calendar, 2026, 10, 10, 13, 30))
    }

    @Test func secondTicksSayTheSecondAndMarkTheMinute() {
        let calendar = calendar("America/Los_Angeles")
        let start = date(calendar, 2026, 10, 10, 13, 24, 57)
        let ticks = TimelineTicks.make(viewport: TimelineViewport(start: start, duration: 60), width: 600, calendar: calendar, minSpacing: 80)
        // 60 s over 600 pt: 0.1 s per point, 80 pt = 8 s: the step is 10 s.
        #expect(ticks.map(\.label) == ["13:25:00", "13:25:10", "13:25:20", "13:25:30", "13:25:40", "13:25:50"])
        #expect(ticks.map(\.isMajor) == [true, false, false, false, false, false])
    }

    @Test func hourTicksFollowTheLocalClockAndMidnightShowsTheDate() {
        let calendar = calendar("America/Los_Angeles")
        let start = date(calendar, 2026, 10, 10, 21, 0)
        let ticks = TimelineTicks.make(viewport: TimelineViewport(start: start, duration: 6 * 3_600), width: 720, calendar: calendar, minSpacing: 80)
        // 21600 s over 720 pt = 30 s per point; 80 pt = 2400 s: the step is 1 hour.
        #expect(ticks.map(\.label) == ["21:00", "22:00", "23:00", "11 Oct", "01:00", "02:00", "03:00"])
        #expect(ticks[3].time == date(calendar, 2026, 10, 11, 0) && ticks[3].isMajor, "midnight is major and carries the date")
        #expect(ticks.filter(\.isMajor).count == 1)
    }

    @Test func springForwardHasNoTwoOClock() {
        let calendar = calendar("America/Los_Angeles")   // 2026-03-08: 02:00 does not exist
        let start = date(calendar, 2026, 3, 8, 0, 0)
        let end = date(calendar, 2026, 3, 8, 6, 0)
        #expect(end.timeIntervalSince(start) == 5 * 3_600, "the day lost an hour")
        let ticks = TimelineTicks.make(viewport: TimelineViewport(start: start, duration: end.timeIntervalSince(start)), width: 600, calendar: calendar, minSpacing: 80)
        #expect(ticks.map(\.label) == ["8 Mar", "01:00", "03:00", "04:00", "05:00", "06:00"])
        #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $1.time.timeIntervalSince($0.time) == 3_600 }, "hour ticks are an elapsed hour apart")
    }

    @Test func fallBackHasTwoOneOClocks() {
        let calendar = calendar("America/Los_Angeles")   // 2026-11-01: 01:00 happens twice
        let start = date(calendar, 2026, 11, 1, 0, 0)
        let end = start.addingTimeInterval(7 * 3_600)    // 00:00 PDT to 06:00 PST
        let ticks = TimelineTicks.make(viewport: TimelineViewport(start: start, duration: end.timeIntervalSince(start)), width: 700, calendar: calendar, minSpacing: 80)
        #expect(ticks.map(\.label) == ["1 Nov", "01:00", "01:00", "02:00", "03:00", "04:00", "05:00", "06:00"])
        #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $1.time.timeIntervalSince($0.time) == 3_600 })
    }

    @Test func dayTicksAreLocalMidnightsAndAcrossDSTTheyAreStillMidnights() {
        let calendar = calendar("America/Los_Angeles")
        let start = date(calendar, 2026, 10, 30, 12, 0)
        let ticks = TimelineTicks.make(viewport: TimelineViewport(start: start, duration: 5 * 86_400), width: 500, calendar: calendar, minSpacing: 80)
        // 5 days over 500 pt: 864 s per point, 80 pt = 69120 s: the step is one day.
        let midnights = [date(calendar, 2026, 10, 31), date(calendar, 2026, 11, 1), date(calendar, 2026, 11, 2), date(calendar, 2026, 11, 3), date(calendar, 2026, 11, 4)]
        #expect(ticks.map(\.time) == midnights, "the 25 hour day does not move the following midnights")
        #expect(ticks.map(\.isMajor) == [false, true, false, false, false], "the first of the month is major")
    }

    @Test func aHalfHourZoneAlignsMinutesToItsOwnClock() {
        let calendar = calendar("Asia/Kolkata")   // UTC+5:30
        let start = date(calendar, 2026, 10, 10, 9, 10)
        let ticks = TimelineTicks.make(viewport: TimelineViewport(start: start, duration: 7_200), width: 800, calendar: calendar, minSpacing: 80)
        // 7200 s over 800 pt: 9 s per point, 80 pt = 720 s: 15 minutes. The window ends at 11:10.
        #expect(ticks.map(\.label) == ["09:15", "09:30", "09:45", "10:00", "10:15", "10:30", "10:45", "11:00"])
    }

    @Test func monthAndQuarterStepsLandOnTheFirstOfAMonth() {
        let calendar = calendar("America/Los_Angeles")
        let start = date(calendar, 2026, 1, 15)
        let ticks = TimelineTicks.make(viewport: TimelineViewport(start: start, duration: 380 * 86_400), width: 1_000, calendar: calendar)
        #expect(ticks.allSatisfy { calendar.component(.day, from: $0.time) == 1 && calendar.component(.hour, from: $0.time) == 0 })
        #expect(ticks.count >= 4 && ticks.count <= 14)
        #expect(ticks.first(where: \.isMajor).map { calendar.component(.month, from: $0.time) } == 1, "January is major")
    }

    @Test func aWeekStepStartsOnTheCalendarsFirstWeekday() {
        let calendar = calendar("America/Los_Angeles", locale: "en_US")   // weeks start on Sunday
        let start = date(calendar, 2026, 9, 1)
        let ticks = TimelineTicks.make(viewport: TimelineViewport(start: start, duration: 20 * 86_400), width: 300, calendar: calendar, minSpacing: 80)
        #expect(!ticks.isEmpty && ticks.allSatisfy { calendar.component(.weekday, from: $0.time) == 1 && calendar.component(.hour, from: $0.time) == 0 })
    }

    @Test func everyTickIsInsideTheViewportAndTheListIsBounded() {
        let calendar = calendar("Europe/Berlin")
        let durations: [TimeInterval] = [30, 600, 5_400, 86_400, 9 * 86_400, 400 * 86_400]
        for duration in durations {
            let viewport = TimelineViewport(start: date(calendar, 2026, 10, 10, 3, 17, 41), duration: duration)
            let ticks = TimelineTicks.make(viewport: viewport, width: 1_000, calendar: calendar)
            #expect(ticks.allSatisfy { $0.time >= viewport.start && $0.time <= viewport.end }, "\(duration)")
            #expect(ticks.count <= 14, "\(duration): \(ticks.count) ticks in 1000 pt at 80 pt spacing")
            #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $0.time < $1.time })
        }
    }
}
