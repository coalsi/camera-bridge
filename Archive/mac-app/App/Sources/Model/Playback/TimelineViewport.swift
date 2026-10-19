import CoreGraphics
import Foundation

/// What the timeline can show: from the oldest recording to now. `minDuration` is the narrowest window (60 s).
nonisolated struct TimelineLimits: Equatable, Sendable {
    var oldest: Date
    var now: Date
    var minDuration: TimeInterval = 60
    /// `now - oldest`, at least `minDuration`.
    var maxDuration: TimeInterval { max(minDuration, now.timeIntervalSince(oldest)) }
}

/// The part of time the timeline shows: `duration` seconds from `start`. A live viewport ends `liveMargin` of its length after now, so the
/// playhead at the live edge has room to its right.
nonisolated struct TimelineViewport: Equatable, Sendable {
    static let liveMargin = 0.04

    var start: Date
    var duration: TimeInterval
    var end: Date { start.addingTimeInterval(duration) }

    func x(for time: Date, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time.timeIntervalSince(start) / duration) * width
    }

    func time(atX x: CGFloat, width: CGFloat) -> Date {
        guard width > 0 else { return start }
        return start.addingTimeInterval(Double(x / width) * duration)
    }

    /// The viewport of `duration` seconds that follows live: it ends `liveMargin` of its length after `now`.
    static func live(duration: TimeInterval, now: Date) -> TimelineViewport {
        TimelineViewport(start: now.addingTimeInterval(-duration * (1 - liveMargin)), duration: duration)
    }

    /// Whether this viewport is at the live edge (to within half a second).
    func isLive(now: Date) -> Bool {
        start.timeIntervalSince(Self.live(duration: duration, now: now).start) >= -0.5
    }

    /// `factor` above 1 zooms in around `anchor`, which keeps its screen position; clamped to `limits`. Zooming out never narrows the window,
    /// and never widens it beyond the recordings (or what it already shows).
    func zoomed(by factor: Double, anchor: Date, limits: TimelineLimits) -> TimelineViewport {
        guard factor.isFinite, factor > 0, duration > 0 else { return self }
        let fraction = anchor.timeIntervalSince(start) / duration
        let widest = max(limits.maxDuration, duration, limits.minDuration)
        let newDuration = min(max(duration / factor, limits.minDuration), widest)
        return TimelineViewport(start: anchor.addingTimeInterval(-fraction * newDuration), duration: newDuration).clamped(to: limits)
    }

    func panned(by seconds: TimeInterval, limits: TimelineLimits) -> TimelineViewport {
        TimelineViewport(start: start.addingTimeInterval(seconds), duration: duration).clamped(to: limits)
    }

    /// The start kept between the oldest recording and the live edge (when the window is wider than the recordings, only the live position fits).
    func clamped(to limits: TimelineLimits) -> TimelineViewport {
        let latest = Self.live(duration: duration, now: limits.now).start
        let earliest = min(limits.oldest, latest)
        return TimelineViewport(start: min(max(start, earliest), latest), duration: duration)
    }

    /// `preset` for a timeline whose playhead is at `playhead`: from live it follows live; from the past it centres on the playhead; All is
    /// oldest to now (at least ten minutes).
    static func make(_ preset: ZoomPreset, playhead: Date, isLive: Bool, limits: TimelineLimits) -> TimelineViewport {
        if preset == .all {
            let duration = max(600, limits.now.timeIntervalSince(limits.oldest) / (1 - liveMargin))
            return TimelineViewport(start: limits.oldest, duration: duration).clamped(to: limits)
        }
        let duration = preset.duration ?? 600
        if isLive { return live(duration: duration, now: limits.now) }
        return TimelineViewport(start: playhead.addingTimeInterval(-duration / 2), duration: duration).clamped(to: limits)
    }
}

nonisolated enum ZoomPreset: String, CaseIterable, Sendable {
    case tenMinutes, hour, sixHours, day, all

    /// The key the choice is remembered under (`UserDefaults`).
    static let storageKey = "nvrZoomPreset"

    /// nil for `.all` (oldest to now, at least 10 minutes).
    var duration: TimeInterval? {
        switch self {
        case .tenMinutes: 600
        case .hour: 3_600
        case .sixHours: 21_600
        case .day: 86_400
        case .all: nil
        }
    }

    /// The button's label.
    var title: String {
        switch self {
        case .tenMinutes: String(localized: "10 min")
        case .hour: String(localized: "1 h")
        case .sixHours: String(localized: "6 h")
        case .day: String(localized: "24 h")
        case .all: String(localized: "All")
        }
    }

    static func stored(in defaults: UserDefaults) -> ZoomPreset {
        defaults.string(forKey: storageKey).flatMap(ZoomPreset.init(rawValue:)) ?? .hour
    }

    func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
