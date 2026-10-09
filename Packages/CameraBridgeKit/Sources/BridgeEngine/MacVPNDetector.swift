import Foundation

/// Whether this Mac is connected to a VPN, from its network interfaces and routing table (`getifaddrs`, the kernel's
/// route dump): an active tunnel interface (`utun`, `ipsec`, `ppp`, `tun`, `tap`, `wg`) with an address of its own that
/// carries the default route, or one with a NordLynx-style address (10.5.0.0/16, as NordVPN's NordLynx and its
/// meshnet-less relatives hand out). A `utun` that has only a link-local address is one of the system's own (iCloud
/// Private Relay, Continuity) and no VPN; a tunnel that carries only some routes (Tailscale without an exit node) is
/// none either. The same reasoning works without the routing table (`defaultRouteInterfaces` nil): any addressed IPv4
/// tunnel counts.
public struct MacVPNStatus: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// A tunnel interface carries the default route (a full-tunnel VPN).
        case defaultRoute
        /// A tunnel interface has an address in 10.5.0.0/16 (NordLynx).
        case nordLynxAddress
        /// A tunnel interface with an IPv4 address; the routing table could not be read.
        case tunnelInterface
    }

    /// The tunnel interface ("utun4").
    public var interface: String
    /// Its address, when it has one.
    public var address: String?
    public var reason: Reason

    public init(interface: String, address: String?, reason: Reason) {
        self.interface = interface
        self.address = address
        self.reason = reason
    }
}

public enum MacVPNDetector {
    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg", "nordlynx", "gpd"]

    /// Whether an interface name is a tunnel's (`utun4`, `ipsec0`, `wg0`).
    static func isTunnelName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return tunnelPrefixes.contains { lower.hasPrefix($0) }
    }

    /// The VPN this Mac is on, nil when none. `interfaces`: the addresses of the interfaces that are up
    /// (`StreamAddress.interfaceAddresses`); `defaultRouteInterfaces`: the interfaces that carry the default route (all
    /// of the 0.0.0.0/0 route, or both halves 0.0.0.0/1 and 128.0.0.0/1 that VPN clients install instead), nil when the
    /// routing table could not be read.
    static func detect(interfaces: [InterfaceAddress], defaultRouteInterfaces: Set<String>?) -> MacVPNStatus? {
        let tunnels = interfaces.filter { isTunnelName($0.interface) && usable($0) }
        guard !tunnels.isEmpty else { return nil }
        if let defaultRouteInterfaces, let carrier = tunnels.first(where: { defaultRouteInterfaces.contains($0.interface) }) {
            return MacVPNStatus(interface: carrier.interface, address: carrier.address, reason: .defaultRoute)
        }
        if let nord = tunnels.first(where: { isNordLynx($0.address) }) {
            return MacVPNStatus(interface: nord.interface, address: nord.address, reason: .nordLynxAddress)
        }
        if defaultRouteInterfaces == nil, let tunnel = tunnels.first(where: { !$0.isIPv6 }) {
            return MacVPNStatus(interface: tunnel.interface, address: tunnel.address, reason: .tunnelInterface)
        }
        return nil
    }

    /// The tunnel address is one of its own: an IPv4 address (not link-local 169.254/16), or an IPv6 one that is not
    /// link-local (fe80::/10).
    private static func usable(_ interface: InterfaceAddress) -> Bool {
        if interface.isIPv6 { return !interface.isLinkLocal }
        guard let bytes = StreamAddress.addressBytes(interface.address) else { return false }
        return !(bytes[0] == 169 && bytes[1] == 254)
    }

    private static func isNordLynx(_ address: String) -> Bool {
        guard let bytes = StreamAddress.addressBytes(address), bytes.count == 4 else { return false }
        return bytes[0] == 10 && bytes[1] == 5
    }

    /// The running Mac's VPN, nil when none (or on a platform without the system calls).
    public static func current() -> MacVPNStatus? {
        detect(interfaces: StreamAddress.interfaceAddresses(), defaultRouteInterfaces: systemDefaultRouteInterfaces())
    }

    /// The interfaces that carry the IPv4 default route (see `detect`), nil when the kernel's routing table cannot be read
    /// (`StreamAddress.routeDump`: the system calls live there, with the other Darwin-only code).
    static func systemDefaultRouteInterfaces() -> Set<String>? {
        guard let dump = StreamAddress.routeDump() else { return nil }
        return defaultRouteInterfaces(inRouteDump: dump, interfaceName: StreamAddress.interfaceName(index:))
    }

    // The kernel's route dump (`NET_RT_DUMP`): a sequence of `rt_msghdr` (92 bytes on Darwin) each followed by the
    // socket addresses its `rtm_addrs` bits name, in bit order (destination, gateway, netmask, …), each padded to 4 bytes.
    /// `AF_INET`, the second byte of a BSD socket address.
    private static let addressFamilyInternet: UInt8 = 2
    private static let routeHeaderSize = 92
    private static let routeFlagUp: Int32 = 0x1
    private static let routeFlagInterfaceScope: Int32 = 0x1000000

    /// One IPv4 route of the kernel's table: the network (`destination`, `prefixLength` leading bits) and the interface it
    /// leaves through.
    struct InterfaceRoute: Sendable, Equatable {
        var destination: [UInt8]
        var prefixLength: Int
        var interface: String

        /// Whether the route covers `address` (4 bytes).
        func covers(_ address: [UInt8]) -> Bool {
            StreamAddress.samePrefix(destination, address, bits: prefixLength)
        }
    }

    /// The up, interface-unscoped IPv4 routes of a route dump, with the name of the interface each uses (routes of an interface
    /// `interfaceName` does not know are left out). A route without a netmask is a host route (/32), except the default one.
    static func routes(inRouteDump dump: [UInt8], interfaceName: (Int) -> String?) -> [InterfaceRoute] {
        var routes: [InterfaceRoute] = []
        var offset = 0
        while offset + routeHeaderSize <= dump.count {
            let messageLength = Int(dump[offset]) | Int(dump[offset + 1]) << 8
            guard messageLength >= routeHeaderSize, offset + messageLength <= dump.count else { break }
            defer { offset += messageLength }
            let index = Int(dump[offset + 4]) | Int(dump[offset + 5]) << 8
            let flags = readInt32(dump, at: offset + 8)
            let addresses = readInt32(dump, at: offset + 12)
            guard flags & routeFlagUp != 0, flags & routeFlagInterfaceScope == 0, addresses & 1 != 0 else { continue }
            var cursor = offset + routeHeaderSize
            let end = offset + messageLength
            var destination: [UInt8]?
            var mask: [UInt8]?
            for bit in 0..<3 where addresses & (1 << Int32(bit)) != 0 {
                guard cursor < end else { break }
                let length = Int(dump[cursor])
                let slice = Array(dump[cursor..<min(cursor + length, end)])
                if bit == 0 { destination = slice }
                if bit == 2 { mask = slice }
                cursor += length == 0 ? 4 : 1 + ((length - 1) | 3)
            }
            guard let destination, destination.count >= 2, destination[1] == Self.addressFamilyInternet, let name = interfaceName(index) else { continue }
            var address = Array(destination.dropFirst(4).prefix(4))
            while address.count < 4 { address.append(0) }
            let prefix = mask == nil ? (address == [0, 0, 0, 0] ? 0 : 32) : prefixLength(ofMask: mask)
            routes.append(InterfaceRoute(destination: address, prefixLength: prefix, interface: name))
        }
        return routes
    }

    /// The interfaces that carry the IPv4 default route in a route dump: an unscoped 0.0.0.0/0, or both halves 0.0.0.0/1 and
    /// 128.0.0.0/1 (the way VPN clients override the default route without replacing it), through the same interface.
    static func defaultRouteInterfaces(inRouteDump dump: [UInt8], interfaceName: (Int) -> String?) -> Set<String> {
        var whole = Set<String>()
        var lowHalf = Set<String>()
        var highHalf = Set<String>()
        for route in routes(inRouteDump: dump, interfaceName: interfaceName) {
            switch (route.destination.map { Int($0) }, route.prefixLength) {
            case ([0, 0, 0, 0], 0): whole.insert(route.interface)
            case ([0, 0, 0, 0], 1): lowHalf.insert(route.interface)
            case ([128, 0, 0, 0], 1): highHalf.insert(route.interface)
            default: break
            }
        }
        return whole.union(lowHalf.intersection(highHalf))
    }

    /// The prefix length of a route's netmask socket address (its address bytes start after the 4-byte header and are cut
    /// off after the last non-zero byte); a route without one covers everything (prefix 0).
    private static func prefixLength(ofMask mask: [UInt8]?) -> Int {
        guard let mask, mask.count > 4 else { return 0 }
        var bits = 0
        for byte in mask.dropFirst(4).prefix(4) {
            if byte == 0xFF { bits += 8; continue }
            var rest = byte
            while rest & 0x80 != 0 { bits += 1; rest <<= 1 }
            break
        }
        return bits
    }

    private static func readInt32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        Int32(bitPattern: UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
    }
}
