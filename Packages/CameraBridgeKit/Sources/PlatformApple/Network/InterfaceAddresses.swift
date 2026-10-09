#if os(macOS)
import Foundation

/// One address of a network interface, as `getifaddrs` lists it.
struct InterfaceAddress: Equatable, Sendable, CustomStringConvertible {
    var interface: String
    var address: String
    var prefixLength: Int
    var isIPv6: Bool

    var description: String { "\(interface) \(address)/\(prefixLength)" }
}

/// What the Mac's own Ethernet and Wi-Fi interfaces (`en*`) hold right now: the addresses Home's controllers reach the
/// accessories at. A DHCP renewal that hands out another address, a new IPv6 prefix or a moved network changes this
/// although the gateway and the interface names stay (`NetworkPathSignature`).
enum InterfaceAddresses {
    /// `IN6_IFF_TEMPORARY`: privacy addresses rotate daily; not an address a controller is told to use, and its rotation
    /// does not say the network changed. Deprecation is not a reason to drop an address either: a prefix whose preferred
    /// lifetime runs out and is renewed flips `IN6_IFF_DEPRECATED` back and forth while the address stays put.
    private static let ignoredIPv6Flags: Int32 = 0x0080

    /// `en*` interfaces that are up and running: IPv4 addresses, and IPv6 addresses that are neither link-local, unique
    /// local (fc00::/7) nor temporary. Sorted, so two snapshots compare equal. Unique local prefixes are left out because
    /// home hubs announce them for Thread (each HomePod or Apple TV acting as a border router advertises one, and they
    /// deprecate and renew them every few seconds to minutes): field report 2026-10-04, a Mac whose two unique local /64 addresses
    /// flipped deprecated on every router advertisement made every camera reconnect every 10-60 s.
    static func stable() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        let socket6 = socket(AF_INET6, SOCK_DGRAM, 0)
        defer { if socket6 >= 0 { close(socket6) } }
        var found: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(entry.pointee.ifa_flags)
            guard name.hasPrefix("en"), flags & IFF_UP != 0, flags & IFF_RUNNING != 0, let address = entry.pointee.ifa_addr,
                  let netmask = entry.pointee.ifa_netmask else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var sin = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(text.count)) != nil else { continue }
                found.append(InterfaceAddress(interface: name, address: String(cString: text), prefixLength: UInt32(bigEndian: mask).nonzeroBitCount,
                                              isIPv6: false))
            case AF_INET6:
                var sin6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                guard !isLinkLocal(sin6.sin6_addr), !isUniqueLocal(sin6.sin6_addr), socket6 >= 0,
                      let flags6 = ipv6Flags(of: sin6, on: name, socket: socket6),
                      flags6 & ignoredIPv6Flags == 0 else { continue }
                let prefix = netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { mask in
                    withUnsafeBytes(of: mask.pointee.sin6_addr) { $0.reduce(0) { $0 + $1.nonzeroBitCount } }
                }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &sin6.sin6_addr, &text, socklen_t(text.count)) != nil else { continue }
                found.append(InterfaceAddress(interface: name, address: String(cString: text), prefixLength: prefix, isIPv6: true))
            default:
                continue
            }
        }
        return found.sorted { ($0.interface, $0.address) < ($1.interface, $1.address) }
    }

    private static func isLinkLocal(_ address: in6_addr) -> Bool {
        withUnsafeBytes(of: address) { $0[0] == 0xFE && ($0[1] & 0xC0) == 0x80 }
    }

    /// fc00::/7 (unique local addresses).
    static func isUniqueLocal(_ address: in6_addr) -> Bool {
        withUnsafeBytes(of: address) { ($0[0] & 0xFE) == 0xFC }
    }

    /// `SIOCGIFAFLAG_IN6` (`_IOWR('i', 73, struct in6_ifreq)`, a function-like macro Swift does not import): the address's
    /// `IN6_IFF_*` flags, nil when the kernel does not know the address any more.
    private static func ipv6Flags(of address: sockaddr_in6, on interface: String, socket: Int32) -> Int32? {
        var request = in6_ifreq()
        withUnsafeMutableBytes(of: &request.ifr_name) { buffer in
            for (index, byte) in interface.utf8.enumerated() where index < buffer.count - 1 { buffer[index] = byte }
        }
        request.ifr_ifru.ifru_addr = address
        let command = UInt(0xC000_0000) | UInt(MemoryLayout<in6_ifreq>.size & 0x1FFF) << 16 | UInt(UInt8(ascii: "i")) << 8 | 73
        guard ioctl(socket, command, &request) == 0 else { return nil }
        return request.ifr_ifru.ifru_flags6
    }

    /// Whether `address` (an IPv4 or IPv6 literal) is on the same network as one of `addresses`.
    static func isOnLink(_ address: String, among addresses: [InterfaceAddress]) -> Bool {
        if address.contains(":") {
            // An IPv6 gateway is a link-local address (fe80::, on an interface's zone) or one in a prefix we hold.
            let lower = address.lowercased()
            if lower.hasPrefix("fe80") {
                let zone = lower.split(separator: "%", maxSplits: 1).dropFirst().first.map(String.init)
                return zone.map { $0.hasPrefix("en") } ?? true
            }
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
