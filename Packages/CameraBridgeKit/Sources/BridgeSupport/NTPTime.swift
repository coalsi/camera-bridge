import Foundation

/// NTP 64-bit timestamps (32.32 fixed point, seconds since 1900-01-01 UTC) as used by RTCP sender reports.
public enum NTPTime {
    /// Seconds between the NTP epoch (1900) and the Unix epoch (1970).
    static let unixEpochOffset: Double = 2_208_988_800

    /// Seconds per NTP era (2^32).
    static let eraLength: Double = 4_294_967_296

    /// Never traps: dates before 1900 and non-finite dates map to 0; dates after 2036 wrap into later NTP eras
    /// (RFC 5905 §6: only the seconds within the era are carried).
    public static func timestamp(for date: Date) -> UInt64 {
        let total = date.timeIntervalSince1970 + unixEpochOffset
        guard total.isFinite, total > 0 else { return 0 }
        let seconds = total.truncatingRemainder(dividingBy: eraLength)   // 0 ≤ seconds < 2^32
        let whole = seconds.rounded(.down)
        let high = UInt64(whole)
        let low = min(UInt64(((seconds - whole) * eraLength).rounded()), 0xFFFF_FFFF)
        return (high << 32) | low
    }

    public static func date(from ntp: UInt64) -> Date {
        let seconds = Double(ntp >> 32) + Double(ntp & 0xFFFF_FFFF) / eraLength
        return Date(timeIntervalSince1970: seconds - unixEpochOffset)
    }
}
