import CoreGraphics
import Foundation

/// The ruler of the timeline: ticks from a fixed table of steps (1 s to 3 months), so labels fall on round times in the person's own calendar.
nonisolated enum TimelineTicks {
    struct Tick: Equatable, Sendable {
        var time: Date
        var label: String
        /// The tick where a larger unit changes: a new minute (steps under a minute), hour (under an hour), day (under a day) or month.
        var isMajor: Bool
    }

    /// 1 s to a quarter. The last two are calendar months and quarters (their length is only a size for choosing).
    static let steps: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200, 10_800, 21_600, 43_200, 86_400, 172_800, 604_800,
                                        2_592_000, 7_776_000]

    /// The smallest step whose ticks are at least `minSpacing` points apart.
    static func step(for viewport: TimelineViewport, width: CGFloat, minSpacing: CGFloat) -> TimeInterval {
        guard width > 0, viewport.duration > 0 else { return steps[steps.count - 1] }
        let secondsPerPoint = viewport.duration / Double(width)
        return steps.first { $0 / secondsPerPoint >= Double(minSpacing) } ?? steps[steps.count - 1]
    }

    /// A fixed step table (1 s to 3 months) with at least `minSpacing` points between ticks, aligned to local calendar boundaries for steps of
    /// an hour or more (correct on DST days: an hour that happens twice has two ticks, an hour that is skipped has none).
    static func make(viewport: TimelineViewport, width: CGFloat, calendar: Calendar, minSpacing: CGFloat = 80) -> [Tick] {
        let step = step(for: viewport, width: width, minSpacing: minSpacing)
        let formats = Formats(calendar: calendar)
        var times: [Date] = []
        if step < 3_600 {
            // A whole-hour DST shift cannot move a tick: every step under an hour divides an hour. A zone with a half-hour offset is aligned by its offset.
            let offset = Double(calendar.timeZone.secondsFromGMT(for: viewport.start))
            var tick = ((viewport.start.timeIntervalSince1970 + offset) / step).rounded(.up) * step - offset
            while tick <= viewport.end.timeIntervalSince1970, times.count < 10_000 {
                times.append(Date(timeIntervalSince1970: tick))
                tick += step
            }
        } else if var hour = calendar.dateInterval(of: .hour, for: viewport.start)?.start {
            var steps = 0
            while hour <= viewport.end, steps < 24 * 800 {
                if hour >= viewport.start, isBoundary(hour, step: step, calendar: calendar) { times.append(hour) }
                guard let next = calendar.date(byAdding: .hour, value: 1, to: hour), next > hour else { break }
                hour = next
                steps += 1
            }
        }
        return times.map { time in
            let parts = calendar.dateComponents([.hour, .minute, .second, .day, .month], from: time)
            let isMidnight = parts.hour == 0 && parts.minute == 0 && parts.second == 0
            let isMajor: Bool
            let label: String
            if step < 60 {
                isMajor = parts.second == 0
                label = formats.timeWithSeconds.string(from: time)
            } else if step < 3_600 {
                isMajor = parts.minute == 0 && parts.second == 0
                label = formats.time.string(from: time)
            } else if step < 86_400 {
                isMajor = isMidnight
                label = isMidnight ? formats.date.string(from: time) : formats.time.string(from: time)
            } else if step < 2_592_000 {
                isMajor = parts.day == 1
                label = formats.date.string(from: time)
            } else {
                isMajor = parts.month == 1
                label = formats.monthYear.string(from: time)
            }
            return Tick(time: time, label: label, isMajor: isMajor)
        }
    }

    /// Whether the hour boundary `time` is a tick of an hour-or-longer `step`: the hour is a multiple of it (up to 12 h), local midnight (a day),
    /// every second day, midnight on the calendar's first weekday, or midnight on the first of a month (every third month for the longest step).
    private static func isBoundary(_ time: Date, step: TimeInterval, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .weekday, .day, .month], from: time)
        let hour = parts.hour ?? 0
        switch step {
        case ..<86_400: return hour % Int(step / 3_600) == 0
        case 86_400: return hour == 0
        case 172_800: return hour == 0 && calendar.ordinality(of: .day, in: .era, for: time).map { $0 % 2 == 0 } == true
        case ..<2_592_000: return hour == 0 && parts.weekday == calendar.firstWeekday
        case ..<7_776_000: return hour == 0 && parts.day == 1
        default: return hour == 0 && parts.day == 1 && ((parts.month ?? 1) - 1) % 3 == 0
        }
    }

    private struct Formats {
        let timeWithSeconds: DateFormatter
        let time: DateFormatter
        let date: DateFormatter
        let monthYear: DateFormatter

        init(calendar: Calendar) {
            func formatter(_ template: String) -> DateFormatter {
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.locale = calendar.locale ?? .current
                formatter.setLocalizedDateFormatFromTemplate(template)
                return formatter
            }
            timeWithSeconds = formatter("jmmss")
            time = formatter("jmm")
            date = formatter("MMMd")
            monthYear = formatter("MMMy")
        }
    }
}

extension Date {
    /// This date in the person's own calendar, zone and language.
    nonisolated func formatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle, in calendar: Calendar) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone))
    }
}
