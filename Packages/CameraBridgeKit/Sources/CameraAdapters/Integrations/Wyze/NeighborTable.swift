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
        return completeEntries(in: table).last { $0.mac == wanted }?.address
    }

    /// The IPv4 address of every complete entry of `table` (Linux `/proc/net/arp`): the hosts that answered the box on its own networks,
    /// in the table's order, each once. An entry is complete when its flags say so (`0x2`) and its MAC is neither all zeros nor the
    /// broadcast address; entries of any address range are listed, and what to do with them is the caller's (the sky detector's feed
    /// finder keeps the private ones). An IPv6 entry is not an IPv4 address and is left out.
    public static func ipv4s(in table: String) -> [String] {
        var seen = Set<String>()
        return completeEntries(in: table).compactMap { entry in
            entry.mac != "ffffffffffff" && seen.insert(entry.address).inserted ? entry.address : nil
        }
    }

    /// The contents of `/proc/net/arp` on Linux; nil elsewhere (or when it cannot be read).
    public static func read() -> String? {
        #if os(Linux)
        return try? String(contentsOfFile: "/proc/net/arp", encoding: .utf8)
        #else
        return nil
        #endif
    }

    /// The table's complete IPv4 entries, in order: the address as written and the MAC as twelve lowercase hex digits (never all zeros).
    private static func completeEntries(in table: String) -> [(address: String, mac: String)] {
        var entries: [(address: String, mac: String)] = []
        for line in table.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 4, isIPv4(fields[0]) else { continue }   // also skips the header
            let flags = fields[2].lowercased()
            guard flags.hasPrefix("0x"), let value = Int(flags.dropFirst(2), radix: 16), value & 0x2 != 0 else { continue }
            guard let mac = normalized(String(fields[3])), mac != "000000000000" else { continue }
            entries.append((String(fields[0]), mac))
        }
        return entries
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
