import Foundation

/// The clip a person has chosen on the timeline: where it starts and ends (the end may be before the start) and which cameras are saved. Plain
/// values, so the clip bar, the export and the tests all read the same numbers; the panel builds one when the bar needs it and Export freezes it.
nonisolated struct ClipSelection: Equatable, Sendable {
    var start: Date
    var end: Date
    /// The cameras to save, in the order their files are written.
    var cameras: [UUID]

    /// A clip shorter than this is not exported (the engine's planner refuses it too).
    static let minimumDuration: TimeInterval = 1

    /// Earlier to later, whichever way the person moved the end.
    var range: ClosedRange<Date> { min(start, end)...max(start, end) }
    var duration: TimeInterval { range.upperBound.timeIntervalSince(range.lowerBound) }
    var isExportable: Bool { duration >= Self.minimumDuration && !cameras.isEmpty }

    /// Both ends brought inside the recordings (retention may have deleted the start while the person chose); the start stays the start and the end
    /// stays the end. Bounds in the wrong order change nothing.
    func clamped(oldest: Date, newest: Date) -> ClipSelection {
        guard oldest <= newest else { return self }
        var result = self
        result.start = min(max(start, oldest), newest)
        result.end = min(max(end, oldest), newest)
        return result
    }

    /// Takes `camera` out when it is in and puts it last when it is not. The last camera cannot be taken out: a clip needs one.
    func toggling(_ camera: UUID) -> ClipSelection {
        var result = self
        if let index = cameras.firstIndex(of: camera) {
            guard cameras.count > 1 else { return self }
            result.cameras.remove(at: index)
        } else {
            result.cameras.append(camera)
        }
        return result
    }

    /// "Oct 12, 2026, 2:02:10 PM to 2:05:42 PM": the range in the person's own calendar, zone and language; the end names its date only when it
    /// falls on another day.
    func summary(calendar: Calendar) -> String {
        let range = range
        func stamp(_ date: Date) -> String {
            let day = date.formatted(date: .abbreviated, time: .omitted, in: calendar)
            let time = date.formatted(date: .omitted, time: .standard, in: calendar)
            return String(localized: "\(day), \(time)")
        }
        let from = stamp(range.lowerBound)
        let to = calendar.isDate(range.lowerBound, inSameDayAs: range.upperBound)
            ? range.upperBound.formatted(date: .omitted, time: .standard, in: calendar) : stamp(range.upperBound)
        return String(localized: "\(from) to \(to)")
    }
}
