import Foundation
import Synchronization

/// The bridge's time zone, for the clock times Camera Bridge words for people ("Camera Bridge waits until 9:19 AM") and the zone it hands
/// the box (the internet guard's "today"): `BridgeSettings.timeZone`, which the engine sets here when it loads its configuration and when
/// the setting changes. It is not the process's zone: Camera Bridge OS runs in UTC, and the engine leaves the process's zone as it is at
/// launch (the recorder names its folders in it). No zone chosen: the process's.
package enum BridgeTime {
    private static let chosen = Mutex<TimeZone?>(nil)

    /// A zone for one task and what it awaits, ahead of the chosen one (tests: they run side by side in one process, and the chosen zone
    /// is the process's).
    @TaskLocal package static var taskZone: TimeZone?

    /// The bridge's zone now.
    package static var zone: TimeZone {
        taskZone ?? chosen.withLock { $0 } ?? .current
    }

    /// Makes the zone named `identifier` (IANA, "America/Phoenix") the bridge's; nil or a name the system does not know: the process's.
    package static func use(_ identifier: String?) {
        let picked = zone(named: identifier)
        chosen.withLock { $0 = picked }
    }

    /// The zone named `identifier`; nil for nil, an empty name or one the system does not know.
    package static func zone(named identifier: String?) -> TimeZone? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return TimeZone(identifier: identifier)
    }

    /// "9:19 AM": `date`'s time of day, short, in `zone` (the bridge's when nil) and in `locale`'s style.
    package static func clock(_ date: Date, in zone: TimeZone? = nil, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone ?? self.zone))
    }
}
