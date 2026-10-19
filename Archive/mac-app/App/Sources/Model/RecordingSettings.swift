import BridgeEngine
import Foundation

/// The numbers and sentences of Settings › Recording: the choices, what lowering a limit would delete, how long the drive holds and whether it is
/// the limit. Pure, so it is tested. Gigabytes are decimal (1e9 bytes), as in `BridgeSettings.nvrMaxSizeGB`; free space and the floor are binary.
nonisolated enum RecordingSettings {
    static let keepDaysChoices = [1, 3, 7, 14, 30, 90]
    static let maxSizeChoices = [100, 250, 500, 1_000, 2_000, 4_000, 8_000]
    /// 4 Mbps, the usual main stream: a camera records this many gigabytes a day per megabit per second (10.8).
    static let gigabytesPerDayPerMegabit = 10.8

    /// `fixed`, plus `current` when it is not in the list (a value from a hand-edited configuration still shows).
    static func choices(_ fixed: [Int], including current: Int) -> [Int] {
        fixed.contains(current) ? fixed : (fixed + [current]).sorted()
    }

    static func keepLabel(_ days: Int) -> String {
        days == 1 ? String(localized: "1 day") : String(localized: "\(days) days")
    }

    static func sizeLabel(_ gigabytes: Int) -> String {
        gigabytes >= 1_000 && gigabytes % 1_000 == 0 ? String(localized: "\(gigabytes / 1_000) TB") : String(localized: "\(gigabytes) GB")
    }

    static func bytes(_ value: UInt64, locale: Locale = .current) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .decimal).locale(locale))
    }

    // MARK: Lowering a limit

    /// About how many bytes the retention rules would delete at once with these limits: the size rule (used above the effective maximum) or the age
    /// rule (the share of the footage older than the cutoff, by time), whichever is more. An estimate on purpose, shown as "about".
    static func bytesToDelete(keepDays: Int, maxSizeGB: Int, storage: ArchiveStorageStatus?, now: Date) -> UInt64 {
        guard let storage, storage.usedBytes > 0 else { return 0 }
        let cap = storage.effectiveMaximumBytes(maxSizeGB: maxSizeGB)
        let bySize = storage.usedBytes > cap ? storage.usedBytes - cap : 0
        var byAge: UInt64 = 0
        if let oldest = storage.oldest, let newest = storage.newest, newest > oldest {
            let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
            if oldest < cutoff {
                let share = min(1, cutoff.timeIntervalSince(oldest) / newest.timeIntervalSince(oldest))
                byAge = UInt64(Double(storage.usedBytes) * share)
            }
        }
        return max(bySize, byAge)
    }

    /// The question to ask before a limit is lowered, or nil when nothing (under a gigabyte) would be deleted.
    static func deletionWarning(keepDays: Int, maxSizeGB: Int, storage: ArchiveStorageStatus?, now: Date, locale: Locale = .current) -> String? {
        let bytes = bytesToDelete(keepDays: keepDays, maxSizeGB: maxSizeGB, storage: storage, now: now)
        guard bytes >= ArchiveConstants.gigabyte else { return nil }
        return String(localized: "This deletes about \(Self.bytes(bytes, locale: locale)) of the oldest recordings. It can’t be undone.")
    }

    // MARK: What the drive holds

    /// "Using 212 GB of up to 500 GB."
    static func usageLine(storage: ArchiveStorageStatus?, maxSizeGB: Int, locale: Locale = .current) -> String? {
        guard let storage else { return nil }
        let limit = bytes(storage.effectiveMaximumBytes(maxSizeGB: maxSizeGB), locale: locale)
        return String(localized: "Using \(bytes(storage.usedBytes, locale: locale)) of up to \(limit).")
    }

    /// "1.2 TB free of 2 TB on this drive."
    static func driveLine(storage: ArchiveStorageStatus?, locale: Locale = .current) -> String? {
        guard let storage, storage.totalBytes > 0 else { return nil }
        return String(localized: "\(bytes(storage.freeBytes, locale: locale)) free of \(bytes(storage.totalBytes, locale: locale)) on this drive.")
    }

    /// A warning when the drive, not the limit, decides how much is kept: "This drive has room for about 90 GB of recordings, less than the
    /// limit. Recording pauses when it is full."
    static func roomWarning(storage: ArchiveStorageStatus?, maxSizeGB: Int, locale: Locale = .current) -> String? {
        guard let storage, storage.totalBytes > 0 else { return nil }
        let room = storage.roomBytes, chosen = UInt64(max(0, maxSizeGB)) * ArchiveConstants.gigabyte
        guard room < chosen else { return nil }
        return String(localized: "This drive has room for about \(bytes(room, locale: locale)) of recordings, less than the limit above. Recording pauses when it is full.")
    }

    /// Gigabytes a day the recording cameras write: measured from what is stored when at least an hour is, else from the cameras' bit rates.
    static func gigabytesPerDay(storage: ArchiveStorageStatus?, cameras: [CameraStatus]) -> Double? {
        if let storage, let oldest = storage.oldest, let newest = storage.newest, newest.timeIntervalSince(oldest) >= 3_600, storage.usedBytes > 0 {
            return Double(storage.usedBytes) / 1e9 / (newest.timeIntervalSince(oldest) / 86_400)
        }
        let kilobits = cameras.filter { $0.nvr.state != .off }.compactMap { $0.mainStreamInfo?.bitrateKbps }
        guard !kilobits.isEmpty else { return nil }
        return Double(kilobits.reduce(0, +)) / 1_000 * gigabytesPerDayPerMegabit
    }

    /// "About 43 GB a day, so 500 GB holds about 11 days." Never a promise of the days in "Keep for".
    static func holdsLine(storage: ArchiveStorageStatus?, cameras: [CameraStatus], maxSizeGB: Int, locale: Locale = .current) -> String? {
        guard let perDay = gigabytesPerDay(storage: storage, cameras: cameras), perDay >= 0.1 else { return nil }
        let capacityGB = storage.map { Double($0.effectiveMaximumBytes(maxSizeGB: maxSizeGB)) / 1e9 } ?? Double(maxSizeGB)
        let days = capacityGB / perDay
        let rate = perDay.formatted(.number.precision(.significantDigits(2)).locale(locale))
        let held = days >= 10 ? Int(days.rounded()).formatted(.number.locale(locale)) : days.formatted(.number.precision(.significantDigits(2)).locale(locale))
        return String(localized: "The cameras recording now write about \(rate) GB a day, so this much holds about \(held) days.")
    }

    /// Recording stops while the Mac sleeps: worth a line when a camera records and Keep Mac Awake is off.
    static func suggestsKeepAwake(anyCameraRecording: Bool, keepsAwake: Bool) -> Bool { anyCameraRecording && !keepsAwake }
}
