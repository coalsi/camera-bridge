import Foundation

/// Why the age rule ("keep recordings for N days") deletes nothing for now (`ArchiveStorageStatus.ageRulePause`). The size rule goes on throughout.
public struct ArchiveAgeRulePause: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// The clock jumped forward by more than 10 minutes between two passes of retention: the age rule waits a day.
        case clockJumped
        /// The system has not said that its clock is synchronized yet, and it has been running for less than a day.
        case clockNotSynchronized
    }

    public var reason: Reason
    /// When the pause ends at the latest, by the box's own clock (to the second). A clock that is synchronized meanwhile ends a
    /// `clockNotSynchronized` pause sooner.
    public var until: Date

    public init(reason: Reason, until: Date) {
        self.reason = reason
        self.until = until
    }
}

/// Whether the clock can be trusted to age recordings out (review of 2026-11-09, C1 and I1; the rulings of 2026-11-11). The age rule deletes every
/// file that ended before "now minus the keep time", on both drives, with the camera events and the Sky Watcher's logs, and nothing undoes it: a
/// clock that jumps ahead makes everything look old. The box's chrony steps the clock whenever it is more than a second off, at any time, and a
/// box without the internet lives on its own clock. So:
///
/// - **A forward jump pauses the age rule.** At each pass the offset between the wall clock and a clock nobody sets (`monotonic`) is kept. When the
///   wall clock has moved more than `jumpLimit` further than the monotonic clock since the last pass, the age rule pauses for `pauseLength` of
///   monotonic time (a second jump in that time starts the day again). A jump back changes nothing: an earlier "now" ages out less.
/// - **The age rule waits for a clock that is known to be right**: until the system says its clock is synchronized, or it has been running for
///   `unsynchronizedWait`, whichever comes first (`uptime` is the system's). Once either happened it no longer asks.
/// - A file dated in the future is not aged until its time comes, and nothing else waits for it.
///
/// If a jump was a correction, the cost is footage kept up to a day longer than the keep time. Pure: the store feeds it the clocks.
struct AgeRuleClock: Sendable, Equatable {
    /// How much further the wall clock may move than the monotonic clock between two passes before it counts as a jump.
    static let jumpLimit: TimeInterval = 600
    /// How long, on the monotonic clock, the age rule pauses after a jump.
    static let pauseLength: TimeInterval = 86_400
    /// How long the system must have been running before the age rule runs on a clock it never said was synchronized.
    static let unsynchronizedWait: TimeInterval = 86_400

    /// What changed in one look, for the log: a pause or a wait starts or ends (each said once).
    enum Change: Equatable, Sendable {
        case pauseStarted(jump: TimeInterval, until: Date)
        case pauseEnded
        case waitStarted(until: Date)
        /// `synchronized`: the system said so (else the system has been running for a day).
        case waitEnded(synchronized: Bool)
    }

    /// The wall clock minus the monotonic clock at the last look.
    private(set) var lastOffset: TimeInterval?
    /// The monotonic time a jump's pause ends, and that end by the wall clock (for the status).
    private(set) var pausedUntil: TimeInterval?
    private var pauseEndsAt: Date?
    /// The clock was said to be synchronized, or the system has been running long enough: no more waiting.
    private(set) var clockKnown = false
    /// While waiting for the clock: when the wait ends at the latest, by the wall clock.
    private var waitEndsAt: Date?

    /// The age rule may delete now.
    var allowsAging: Bool { pausedUntil == nil && clockKnown }

    /// Why the age rule deletes nothing now (a jump's pause first: it is the one the person can do nothing about); nil while it runs.
    var pause: ArchiveAgeRulePause? {
        if let pauseEndsAt { return ArchiveAgeRulePause(reason: .clockJumped, until: pauseEndsAt) }
        if let waitEndsAt { return ArchiveAgeRulePause(reason: .clockNotSynchronized, until: waitEndsAt) }
        return nil
    }

    /// Whether the next look needs to ask the system if its clock is synchronized (only until it has said so, and within the first day).
    func needsSynchronization(uptime: TimeInterval) -> Bool {
        !clockKnown && uptime < Self.unsynchronizedWait
    }

    /// One look at the clocks, at the start of a pass. `synchronized` is what the system says (read only when `needsSynchronization`).
    mutating func check(wall: Date, monotonic: TimeInterval, uptime: TimeInterval, synchronized: Bool) -> [Change] {
        var changes: [Change] = []
        let offset = wall.timeIntervalSince1970 - monotonic
        if let lastOffset, offset - lastOffset > Self.jumpLimit {
            if pausedUntil == nil { changes.append(.pauseStarted(jump: offset - lastOffset, until: Self.second(wall.addingTimeInterval(Self.pauseLength)))) }
            pausedUntil = monotonic + Self.pauseLength
            pauseEndsAt = Self.second(wall.addingTimeInterval(Self.pauseLength))
        }
        lastOffset = offset
        if let end = pausedUntil, monotonic >= end {
            pausedUntil = nil
            pauseEndsAt = nil
            changes.append(.pauseEnded)
        }
        if !clockKnown {
            let ranLongEnough = uptime >= Self.unsynchronizedWait
            if ranLongEnough || synchronized {
                clockKnown = true
                if waitEndsAt != nil { changes.append(.waitEnded(synchronized: !ranLongEnough)) }
                waitEndsAt = nil
            } else if waitEndsAt == nil {
                let end = Self.second(wall.addingTimeInterval(Self.unsynchronizedWait - uptime))
                waitEndsAt = end
                changes.append(.waitStarted(until: end))
            }
        }
        return changes
    }

    /// `date` to the whole second, so the status does not change with every look.
    private static func second(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
