import Foundation

/// The box's neighbour (ARP) table: a Wyze camera's current IPv4 address from its MAC, so a stale cloud address is not trusted.
public enum NeighborTable {
    /// The IPv4 address `table` (Linux `/proc/net/arp`) lists for `mac`. MACs compare without case or separators (Wyze gives
    /// `D03F27A1B2C3`, the table `d0:3f:27:a1:b2:c3`). Incomplete entries (flags `0x0`, an all-zero MAC) are skipped; the last
    /// complete entry wins.
    ///
    ///     IP address       HW type     Flags       HW address            Mask     Device
    ///     192.168.1.20     0x1         0x2         d0:3f:27:a1:b2:c3     *        eth0
    public static func ipv4(forMAC mac: String, in table: String) -> String? {
        guard let wanted = normalized(mac) else { return nil }
        var found: String?
        for line in table.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 4, isIPv4(fields[0]) else { continue }   // also skips the header
            let flags = fields[2].lowercased()
            guard flags.hasPrefix("0x"), let value = Int(flags.dropFirst(2), radix: 16), value & 0x2 != 0 else { continue }
            guard let entry = normalized(String(fields[3])), entry != "000000000000", entry == wanted else { continue }
            found = String(fields[0])
        }
        return found
    }

    /// The contents of `/proc/net/arp` on Linux; nil elsewhere (or when it cannot be read).
    public static func read() -> String? {
        #if os(Linux)
        return try? String(contentsOfFile: "/proc/net/arp", encoding: .utf8)
        #else
        return nil
        #endif
    }

    /// Twelve lowercase hex digits, or nil.
    static func normalized(_ mac: String) -> String? {
        let digits = mac.lowercased().filter { $0 != ":" && $0 != "-" && $0 != "." && !$0.isWhitespace }
        guard digits.count == 12, digits.allSatisfy(\.isHexDigit) else { return nil }
        return digits
    }

    private static func isIPv4(_ text: Substring) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
        }
    }
}
