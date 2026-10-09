#if os(Linux)
import Foundation
import Glibc

/// One address of a network interface.
public struct InterfaceAddress: Equatable, Sendable, CustomStringConvertible {
    public var interface: String
    public var address: String
    public var prefixLength: Int
    public var isIPv6: Bool

    public init(interface: String, address: String, prefixLength: Int, isIPv6: Bool) {
        self.interface = interface
        self.address = address
        self.prefixLength = prefixLength
        self.isIPv6 = isIPv6
    }

    public var description: String { "\(interface) \(address)/\(prefixLength)" }
}

/// What the box's own Ethernet and Wi-Fi interfaces hold right now: the addresses Home's controllers reach the accessories at.
/// A DHCP renewal that hands out another address, a new IPv6 prefix or a moved network changes this although the interface
/// names stay (`NetworkSignature`).
public enum InterfaceAddresses {
    /// Interfaces that carry the LAN: Ethernet (`eth0`, `eno1`, `enp3s0`, `ens18`) and Wi-Fi (`wlan0`, `wlp2s0`). Loopback,
    /// containers (`docker0`, `veth*`, `br-*`), VM bridges (`virbr*`), tunnels (`tun*`, `wg*`, `tailscale0`) and the like say
    /// nothing about the LAN and come and go.
    public static func isLANInterface(_ name: String) -> Bool {
        ["eth", "en", "wlan", "wl"].contains { name.hasPrefix($0) }
    }

    /// Addresses of the LAN interfaces that are up and running: IPv4 addresses, and IPv6 addresses that are neither link-local,
    /// unique local (fc00::/7), temporary nor still being checked for duplicates. Sorted, so two snapshots compare equal. Unique
    /// local prefixes are left out because home hubs announce them for Thread (each HomePod or Apple TV acting as a border router
    /// advertises one, and they deprecate and renew them every few seconds to minutes); deprecation is not a reason to drop a
    /// global address either: a prefix whose preferred lifetime runs out and is renewed flips `IFA_F_DEPRECATED` back and forth
    /// while the address stays put.
    public static func stable() -> [InterfaceAddress] {
        stable(kernel: Netlink.dumpAddresses(), names: interfaceNames(), running: runningInterfaces())
    }

    /// `stable()` on given data (tests).
    static func stable(kernel: [KernelAddress], names: [UInt32: String], running: Set<String>) -> [InterfaceAddress] {
        var found: [InterfaceAddress] = []
        for item in kernel {
            guard let name = names[item.interfaceIndex], isLANInterface(name), running.contains(name) else { continue }
            if item.family == AF_INET {
                found.append(InterfaceAddress(interface: name, address: item.bytes.map(String.init).joined(separator: "."),
                                              prefixLength: item.prefixLength, isIPv6: false))
            } else if item.family == AF_INET6 {
                let ignoredFlags = KernelAddress.temporary | KernelAddress.tentative | KernelAddress.duplicateFailed
                guard item.flags & ignoredFlags == 0, !isLinkLocal(item.bytes), !isUniqueLocal(item.bytes) else { continue }
                var raw = in6_addr()
                withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: item.bytes) }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &raw, &text, socklen_t(text.count)) != nil else { continue }
                found.append(InterfaceAddress(interface: name, address: String(cString: text), prefixLength: item.prefixLength, isIPv6: true))
            }
        }
        return found.sorted { ($0.interface, $0.address) < ($1.interface, $1.address) }
    }

    static func isLinkLocal(_ address: [UInt8]) -> Bool {
        address.count == 16 && address[0] == 0xFE && (address[1] & 0xC0) == 0x80
    }

    /// fc00::/7 (unique local addresses).
    static func isUniqueLocal(_ address: [UInt8]) -> Bool {
        address.count == 16 && (address[0] & 0xFE) == 0xFC
    }

    /// Interface index → name.
    static func interfaceNames() -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        guard let list = if_nameindex() else { return names }
        defer { if_freenameindex(list) }
        var cursor = list
        while cursor.pointee.if_index != 0 {
            names[cursor.pointee.if_index] = String(cString: cursor.pointee.if_name)
            cursor += 1
        }
        return names
    }

    /// Names of the interfaces that are up and running (carrier present).
    static func runningInterfaces() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var running: Set<String> = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = entry.pointee.ifa_flags
            if flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0 { running.insert(String(cString: entry.pointee.ifa_name)) }
        }
        return running
    }

    /// The IPv4 default gateway (`/proc/net/route`), nil when there is none.
    static func defaultGateway() -> String? {
        guard let table = try? String(contentsOfFile: "/proc/net/route", encoding: .utf8) else { return nil }
        for line in table.split(separator: "\n").dropFirst() {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            // Iface Destination Gateway Flags ...; the default route has destination 0 and the gateway flag (RTF_GATEWAY = 2).
            guard fields.count > 3, fields[1] == "00000000", let flags = Int(fields[3], radix: 16), flags & 2 != 0,
                  isLANInterface(String(fields[0])), let gateway = UInt32(fields[2], radix: 16) else { continue }
            let octets = withUnsafeBytes(of: gateway) { Array($0) }   // little endian: the first octet is first in memory
            return octets.map(String.init).joined(separator: ".")
        }
        return nil
    }

    /// Whether `address` (an IPv4 or IPv6 literal) is on the same network as one of `addresses`.
    static func isOnLink(_ address: String, among addresses: [InterfaceAddress]) -> Bool {
        if address.contains(":") {
            let lower = address.lowercased()
            if lower.hasPrefix("fe80") { return true }   // link-local: on the interface's own link
            return addresses.contains { $0.isIPv6 && sharePrefix(lower, $0.address.lowercased(), length: $0.prefixLength, bytes: 16, family: AF_INET6) }
        }
        return addresses.contains { !$0.isIPv6 && sharePrefix(address, $0.address, length: $0.prefixLength, bytes: 4, family: AF_INET) }
    }

    private static func sharePrefix(_ a: String, _ b: String, length: Int, bytes: Int, family: Int32) -> Bool {
        var left = [UInt8](repeating: 0, count: 16), right = [UInt8](repeating: 0, count: 16)
        guard inet_pton(family, a, &left) == 1, inet_pton(family, b, &right) == 1 else { return false }
        var remaining = max(0, min(length, bytes * 8))
        for index in 0..<bytes where remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF00 >> bits)
            if left[index] & mask != right[index] & mask { return false }
            remaining -= bits
        }
        return true
    }
}
#endif
