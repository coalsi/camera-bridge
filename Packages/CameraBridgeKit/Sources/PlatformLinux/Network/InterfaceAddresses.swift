#if os(Linux)
import BridgeSupport
import Foundation
import Glibc
import Synchronization

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

/// A global unicast IPv6 address (2000::/3) as the kernel holds it, with the flags it sets. Which one is the stable address is for the
/// caller to choose: temporary and deprecated ones are listed and marked, not dropped.
public struct GlobalIPv6Address: Equatable, Sendable {
    public var interface: String
    public var address: String
    public var prefixLength: Int
    /// Seconds the address stays preferred; `UInt32.max` is forever.
    public var preferredLifetime: UInt32
    public var isTemporary: Bool
    public var isDeprecated: Bool

    public init(interface: String, address: String, prefixLength: Int, preferredLifetime: UInt32, isTemporary: Bool, isDeprecated: Bool) {
        self.interface = interface
        self.address = address
        self.prefixLength = prefixLength
        self.preferredLifetime = preferredLifetime
        self.isTemporary = isTemporary
        self.isDeprecated = isDeprecated
    }
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

    /// The interface that holds the IPv6 default route (`/proc/self/net/ipv6_route`), nil when there is none. It reads `/proc/self/net`, not
    /// `/proc/net`: the daemon's unit has `ProcSubset=pid`, which hides `/proc/net` (a link outside the pid subset) but keeps `/proc/self/net`.
    public static func ipv6DefaultRouteInterface() -> String? {
        ipv6DefaultRouteInterface(file: "/proc/self/net/ipv6_route")
    }

    /// `ipv6DefaultRouteInterface()` from `file` (tests give one that can't be read).
    static func ipv6DefaultRouteInterface(file: String) -> String? {
        let table: String
        do {
            table = try String(contentsOfFile: file, encoding: .utf8)
        } catch {
            // Without the table the box has no IPv6 default route as far as Away from home can tell, and its card says the home has no
            // IPv6: the log says why, once, since this is asked every 30 s.
            if routeTableUnreadable.withLock({ logged in defer { logged = true }; return !logged }) {
                Log(category: "network").warning("\(file) can't be read (\(error.localizedDescription)), so the IPv6 default route is unknown")
            }
            return nil
        }
        return ipv6DefaultRouteInterface(routeTable: table)
    }

    /// Whether an unreadable IPv6 route table was logged already.
    private static let routeTableUnreadable = Mutex(false)

    /// `ipv6DefaultRouteInterface()` on given text (tests). A line is: destination, prefix length, source, source length, next hop, metric,
    /// reference count, use count, flags, interface; all numbers hexadecimal. The lowest metric on a LAN interface wins, as the kernel would choose.
    static func ipv6DefaultRouteInterface(routeTable: String) -> String? {
        var best: (metric: UInt32, interface: String)?
        for line in routeTable.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 10, fields[0].allSatisfy({ $0 == "0" }), fields[1] == "00",
                  let metric = UInt32(fields[5], radix: 16), let flags = UInt32(fields[8], radix: 16) else { continue }
            // RTF_UP set and RTF_REJECT clear: lo carries an unreachable default that is no way out.
            guard flags & 0x1 != 0, flags & 0x200 == 0 else { continue }
            let interface = String(fields[9])
            guard isLANInterface(interface) else { continue }
            if best == nil || metric < best!.metric { best = (metric, interface) }
        }
        return best?.interface
    }

    /// The global unicast IPv6 addresses of the interface with the IPv6 default route, in address order.
    public static func globalIPv6() -> [GlobalIPv6Address] {
        globalIPv6(kernel: Netlink.dumpAddresses(), names: interfaceNames(), defaultInterface: ipv6DefaultRouteInterface())
    }

    /// `globalIPv6()` on given data (tests). Addresses still in duplicate detection or that failed it are left out: they are not usable yet or ever.
    /// Temporary and deprecated ones stay, marked, because the choice between them belongs to BridgeWeb. Nothing without a default-route interface.
    static func globalIPv6(kernel: [KernelAddress], names: [UInt32: String], defaultInterface: String?) -> [GlobalIPv6Address] {
        guard let defaultInterface else { return [] }
        var found: [GlobalIPv6Address] = []
        let candidates = kernel.filter { $0.family == AF_INET6 && $0.bytes.count == 16 && names[$0.interfaceIndex] == defaultInterface }
        for item in candidates.sorted(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) }) {
            guard item.bytes[0] & 0xE0 == 0x20, item.flags & (KernelAddress.tentative | KernelAddress.duplicateFailed) == 0 else { continue }
            var raw = in6_addr()
            withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: item.bytes) }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &raw, &text, socklen_t(text.count)) != nil else { continue }
            found.append(GlobalIPv6Address(interface: defaultInterface, address: String(cString: text), prefixLength: item.prefixLength,
                                           preferredLifetime: item.preferredLifetime ?? .max, isTemporary: item.flags & KernelAddress.temporary != 0,
                                           isDeprecated: item.flags & KernelAddress.deprecated != 0))
        }
        return found
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

    /// The IPv4 default gateway (`/proc/self/net/route`), nil when there is none. `/proc/self/net`, as for the IPv6 route: the daemon's
    /// `ProcSubset=pid` hides `/proc/net`, which left the gateway out of `NetworkSignature` on the box.
    static func defaultGateway() -> String? {
        guard let table = try? String(contentsOfFile: "/proc/self/net/route", encoding: .utf8) else { return nil }
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
