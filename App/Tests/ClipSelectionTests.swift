import Foundation
import Testing

@Suite struct ClipSelectionTests {
    private func calendar(_ zone: String, locale: String = "en_US") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        calendar.locale = Locale(identifier: locale)
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) ?? .distantPast
    }

    /// The system's time formats put a narrow no-break space before AM and PM; the tests compare with plain spaces.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private let origin = Date(timeIntervalSince1970: 1_000)

    // MARK: Range, duration, minimum

    @Test func eitherOrderGivesTheSameRange() {
        let later = origin.addingTimeInterval(90)
        let forward = ClipSelection(start: origin, end: later, cameras: [UUID()])
        let backward = ClipSelection(start: later, end: origin, cameras: forward.cameras)
        #expect(forward.range == origin...later && backward.range == origin...later)
        #expect(forward.duration == 90 && backward.duration == 90, "a duration is never negative")
    }

    @Test func aClipIsExportableFromOneSecondWhenACameraIsChosen() {
        let camera = UUID()
        #expect(ClipSelection.minimumDuration == 1)
        #expect(!ClipSelection(start: origin, end: origin, cameras: [camera]).isExportable, "no length at all")
        #expect(!ClipSelection(start: origin, end: origin.addingTimeInterval(0.99), cameras: [camera]).isExportable)
        #expect(ClipSelection(start: origin, end: origin.addingTimeInterval(1), cameras: [camera]).isExportable, "exactly the minimum")
        #expect(ClipSelection(start: origin.addingTimeInterval(1), end: origin, cameras: [camera]).isExportable, "the end before the start counts the same")
        #expect(!ClipSelection(start: origin, end: origin.addingTimeInterval(60), cameras: []).isExportable, "a clip needs a camera")
    }

    // MARK: Clamping

    @Test func clampingLeavesAClipInsideTheRecordingsAlone() {
        let oldest = origin, newest = origin.addingTimeInterval(1_000)
        let inside = ClipSelection(start: origin.addingTimeInterval(100), end: origin.addingTimeInterval(200), cameras: [UUID()])
        #expect(inside.clamped(oldest: oldest, newest: newest) == inside)
        #expect(inside.clamped(oldest: newest, newest: oldest) == inside, "bounds in the wrong order change nothing")
    }

    @Test func clampingFollowsRetentionAndTheNewestPicture() {
        let oldest = origin, newest = origin.addingTimeInterval(1_000), camera = UUID()
        let retention = ClipSelection(start: origin.addingTimeInterval(-50), end: origin.addingTimeInterval(200), cameras: [camera])
        let moved = retention.clamped(oldest: oldest, newest: newest)
        #expect(moved.start == oldest && moved.end == retention.end, "the start was deleted: it moves to the oldest picture")
        let live = ClipSelection(start: origin.addingTimeInterval(900), end: origin.addingTimeInterval(1_030), cameras: [camera])
        let held = live.clamped(oldest: oldest, newest: newest)
        #expect(held.start == live.start && held.end == newest, "the end waits at the newest picture")
        #expect(moved.cameras == [camera] && held.cameras == [camera], "the cameras are untouched")
    }

    @Test func clampingKeepsTheStartAsTheStartWhenTheEndIsBefore() {
        let oldest = origin, newest = origin.addingTimeInterval(1_000)
        let backwards = ClipSelection(start: origin.addingTimeInterval(1_040), end: origin.addingTimeInterval(-10), cameras: [UUID()])
        let clamped = backwards.clamped(oldest: oldest, newest: newest)
        #expect(clamped.start == newest && clamped.end == oldest)
        #expect(clamped.range == oldest...newest)
    }

    @Test func aClipEntirelyBeforeTheRecordingsCollapsesAndIsNotExportable() {
        let oldest = origin, newest = origin.addingTimeInterval(1_000)
        let gone = ClipSelection(start: origin.addingTimeInterval(-500), end: origin.addingTimeInterval(-100), cameras: [UUID()])
        let clamped = gone.clamped(oldest: oldest, newest: newest)
        #expect(clamped.start == oldest && clamped.end == oldest && clamped.duration == 0 && !clamped.isExportable)
    }

    // MARK: Cameras

    @Test func togglingTakesACameraOutAndPutsItBackLast() {
        let ids = [UUID(), UUID(), UUID()]
        let all = ClipSelection(start: origin, end: origin.addingTimeInterval(60), cameras: ids)
        let without = all.toggling(ids[1])
        #expect(without.cameras == [ids[0], ids[2]])
        #expect(without.start == all.start && without.end == all.end, "only the cameras change")
        #expect(without.toggling(ids[1]).cameras == [ids[0], ids[2], ids[1]], "back in, at the end of the list")
        #expect(without.toggling(UUID()).cameras.count == 3)
    }

    @Test func theLastCameraStaysSoAClipAlwaysHasOne() {
        let first = UUID(), second = UUID()
        let one = ClipSelection(start: origin, end: origin.addingTimeInterval(60), cameras: [first])
        #expect(one.toggling(first) == one, "the only camera cannot be taken out")
        let two = one.toggling(second)
        #expect(two.cameras == [first, second])
        let last = two.toggling(first)
        #expect(last.cameras == [second])
        #expect(last.toggling(second) == last, "and again the last one stays")
    }

    // MARK: Summary

    @Test func theSummaryNamesTheRangeInTheCallersCalendarAndZone() {
        let pacific = calendar("America/Los_Angeles")
        let selection = ClipSelection(start: date(pacific, 2026, 10, 12, 14, 2, 10), end: date(pacific, 2026, 10, 12, 14, 5, 42), cameras: [UUID()])
        #expect(plain(selection.summary(calendar: pacific)) == "Oct 12, 2026, 2:02:10 PM to 2:05:42 PM")
        #expect(plain(selection.summary(calendar: calendar("UTC"))) == "Oct 12, 2026, 9:02:10 PM to 9:05:42 PM", "the same instants, read in another zone")
        let backwards = ClipSelection(start: selection.end, end: selection.start, cameras: selection.cameras)
        #expect(backwards.summary(calendar: pacific) == selection.summary(calendar: pacific), "earlier first, whichever way the end was moved")
    }

    @Test func aTwentyFourHourCalendarReadsTheSameWayAsThePlayhead() {
        let british = calendar("Europe/London", locale: "en_GB")
        let selection = ClipSelection(start: date(british, 2026, 10, 12, 14, 2, 10), end: date(british, 2026, 10, 12, 14, 5, 42), cameras: [UUID()])
        #expect(plain(selection.summary(calendar: british)) == "12 Oct 2026, 14:02:10 to 14:05:42")
    }

    @Test func aClipAcrossMidnightGivesTheEndItsOwnDate() {
        let utc = calendar("UTC")
        let across = ClipSelection(start: date(utc, 2026, 10, 12, 23, 58, 30), end: date(utc, 2026, 10, 13, 0, 3, 5), cameras: [UUID()])
        #expect(plain(across.summary(calendar: utc)) == "Oct 12, 2026, 11:58:30 PM to Oct 13, 2026, 12:03:05 AM")
        // Midnight is the viewer's own: the same clip is on one day in Los Angeles.
        let pacific = calendar("America/Los_Angeles")
        #expect(plain(across.summary(calendar: pacific)) == "Oct 12, 2026, 4:58:30 PM to 5:03:05 PM")
        // and a clip that is on one UTC day crosses a Los Angeles midnight.
        let late = ClipSelection(start: date(utc, 2026, 10, 12, 6, 58, 30), end: date(utc, 2026, 10, 12, 7, 3, 5), cameras: [UUID()])
        #expect(plain(late.summary(calendar: pacific)) == "Oct 11, 2026, 11:58:30 PM to Oct 12, 2026, 12:03:05 AM")
    }
}
