import Foundation

/// Names and ids that must be the same everywhere: the file key and fragment id, and the folder layout's name patterns.
public enum ArchiveIdentity {
    /// FNV-1a, 64 bit (offset basis 0xcbf29ce484222325, prime 0x100000001b3).
    public static func fnv1a64(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// The first 12 characters of the hash's 16-digit lowercase hex (its high 48 bits) of the segment path's UTF-8 bytes.
    public static func fileKey(forSegment segment: String) -> String {
        let digits = String(fnv1a64(segment.utf8), radix: 16)
        return String((String(repeating: "0", count: 16 - digits.count) + digits).prefix(12))
    }

    public static func fragmentID(fileKey: String, index: Int) -> String { "\(fileKey).\(index)" }

    /// `<12 lowercase hex>.<index>` with an index of 1 to 7 digits and no leading zero; anything else is nil.
    public static func parseFragmentID(_ id: String) -> (fileKey: String, index: Int)? {
        guard let match = id.wholeMatch(of: /([0-9a-f]{12})\.(0|[1-9][0-9]{0,6})/), let index = Int(match.output.2) else { return nil }
        return (String(match.output.1), index)
    }
}

/// The folder layout `<root>/<camera directory>/<yyyy-MM-dd>/<HH-mm-ss>.mp4` (+ `.cbidx`), in local time (Mac spec 4.1).
public enum ArchiveLayout {
    /// "2026-10-10": four digits, a month 01-12 and a day 01-31.
    public static func isDateDirectoryName(_ name: String) -> Bool {
        guard let match = name.wholeMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})/), let month = Int(match.output.2), let day = Int(match.output.3) else { return false }
        return (1...12).contains(month) && (1...31).contains(day)
    }

    /// "13-24-05", or "13-24-05-2" when that second already has a file (a recorder that started again within the second).
    public static func isOwnFileBaseName(_ name: String) -> Bool {
        guard let match = name.wholeMatch(of: /([0-9]{2})-([0-9]{2})-([0-9]{2})(-[1-9][0-9]{0,2})?/),
              let hour = Int(match.output.1), let minute = Int(match.output.2), let second = Int(match.output.3) else { return false }
        return hour < 24 && minute < 60 && second < 61
    }

    /// "<camera directory>/<date directory>/<base name>".
    public static func segment(cameraDirectory: String, dateDirectory: String, baseName: String) -> String {
        "\(cameraDirectory)/\(dateDirectory)/\(baseName)"
    }

    /// Splits a segment into its three parts; nil unless each part is a plain name (no "/", no "." or ".." component) and the
    /// last two match the patterns above.
    public static func parseSegment(_ segment: String) -> (cameraDirectory: String, dateDirectory: String, baseName: String)? {
        let parts = segment.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, parts[0] != ".", parts[0] != "..", !parts[0].contains("\0"),
              isDateDirectoryName(parts[1]), isOwnFileBaseName(parts[2]) else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}
