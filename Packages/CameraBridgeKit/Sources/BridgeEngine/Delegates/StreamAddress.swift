import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One IP address configured on a network interface (zone stripped).
struct InterfaceAddress: Sendable, Equatable {
    var interface: String
    var address: String
    /// The length of the interface's network prefix (netmask bits), nil when unknown (then only the address itself is
    /// known to be on that network). Not part of the identity: two entries are equal for the same interface and address.
    var prefixLength: Int?
    /// IPv6 only: an RFC 4941 temporary (privacy) address. Short lived and never advertised in Bonjour: a controller cannot
    /// be told to reach us there.
    var isTemporary: Bool
    /// IPv6 only: past its preferred lifetime (a new address replaced it); existing flows may use it, new ones should not.
    var isDeprecated: Bool

    init(interface: String, address: String, prefixLength: Int? = nil, isTemporary: Bool = false, isDeprecated: Bool = false) {
        self.interface = interface
        self.address = StreamAddress.canonical(address)
        self.prefixLength = prefixLength
        self.isTemporary = isTemporary
        self.isDeprecated = isDeprecated
    }

    static func == (lhs: InterfaceAddress, rhs: InterfaceAddress) -> Bool {
        lhs.interface == rhs.interface && lhs.address == rhs.address
    }

    var isIPv6: Bool { address.contains(":") }
    /// fe80::/10: needs a scope, which the SetupEndpoints address cannot carry (`StreamAddress.controllerHost` gives a
    /// controller's the HAP connection's zone).
    var isLinkLocal: Bool { StreamAddress.isLinkLocal(address) }
}

/// The accessory address of a live stream (research brief §3.5, HAP-NodeJS `getLocalAddress`): an address of the family
/// the controller asked for, on the interface its HAP connection arrived on. The HAP connection's own address when it
/// is of that family (IPv6: unless it is link-local and the interface has an address without a scope); else the
/// interface's first IPv4 address, or its best IPv6 address without a scope (`preferredIPv6`; a link-local one only when
/// there is no other). Without such an address the connection's address is answered (RTPStreamManagement then refuses the
/// setup).
enum StreamAddress {
    /// `controller`: the address the controller put in SetupEndpoints, which an IPv6 answer prefers to share a /64 with.
    static func accessoryAddress(localAddress: String, ipv6: Bool, interfaces: [InterfaceAddress], controller: String? = nil) -> String {
        let local = canonical(localAddress)
        let localIsIPv6 = local.contains(":")
        if localIsIPv6 == ipv6, !(ipv6 && isLinkLocal(local)) { return local }
        guard let interface = interfaces.first(where: { $0.address == local })?.interface else { return local }
        let candidates = interfaces.filter { $0.interface == interface && $0.isIPv6 == ipv6 }
        if !ipv6 { return candidates.first?.address ?? local }
        if let routable = preferredIPv6(candidates, controller: controller) { return routable.address }
        if localIsIPv6 { return local }
        return candidates.first?.address ?? local
    }

    /// The IPv6 address of `candidates` a controller is most likely to reach us at: one in the controller's /64, else a stable
    /// global address, else a stable unique local one (fc00::/7); temporary (privacy) and deprecated addresses only when
    /// nothing else is routable (`getifaddrs` lists them in no useful order: a ULA, or a temporary address that is about to
    /// expire, may come before the global address, and a controller sent there waits its 30 s for video that never comes).
    /// Link-local addresses are never chosen here (they need a scope). nil when there is none.
    static func preferredIPv6(_ candidates: [InterfaceAddress], controller: String?) -> InterfaceAddress? {
        let routable = candidates.filter { $0.isIPv6 && !$0.isLinkLocal }
        let stable = routable.filter { !$0.isTemporary && !$0.isDeprecated }
        let notDeprecated = routable.filter { !$0.isDeprecated }
        let pool = !stable.isEmpty ? stable : (!notDeprecated.isEmpty ? notDeprecated : routable)
        if let controller, !isLinkLocal(controller), let wanted = addressBytes(controller), wanted.count == 16,
           let sameNetwork = pool.first(where: { addressBytes($0.address).map { samePrefix($0, wanted, bits: 64) } ?? false }) {
            return sameNetwork
        }
        func isUniqueLocal(_ address: InterfaceAddress) -> Bool { addressBytes(address.address).map { $0[0] & 0xFE == 0xFC } ?? false }
        return pool.first { !isUniqueLocal($0) } ?? pool.first
    }

    /// Interfaces of one subnet (IPv4, known prefix, not loopback, link-local or a tunnel): the Mac is on that network twice.
    struct SharedSubnet: Equatable {
        /// "192.0.2.0/24".
        var network: String
        /// The interfaces holding an address in it, in the order listed.
        var interfaces: [String]
        var addresses: [String]
        /// "en0 192.0.2.69" per address, for text.
        var members: [String]
    }

    /// Subnets that two or more interfaces hold an address in (Ethernet and Wi-Fi both on the home network).
    static func sharedSubnets(_ interfaces: [InterfaceAddress]) -> [SharedSubnet] {
        var found: [(bits: Int, base: [UInt8], members: [InterfaceAddress])] = []
        for entry in interfaces where !entry.isIPv6 {
            guard let bits = entry.prefixLength, bits > 0, bits < 32, let bytes = addressBytes(entry.address), bytes.count == 4,
                  !isLoopback(entry.address), !(bytes[0] == 169 && bytes[1] == 254), !MacVPNDetector.isTunnelName(entry.interface) else { continue }
            if let index = found.firstIndex(where: { $0.bits == bits && samePrefix($0.base, bytes, bits: bits) }) {
                found[index].members.append(entry)
            } else {
                found.append((bits, bytes, [entry]))
            }
        }
        return found.compactMap { subnet in
            let names = subnet.members.map(\.interface).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            guard names.count >= 2 else { return nil }
            var network = subnet.base
            for index in 0..<4 {
                let kept = max(0, min(8, subnet.bits - 8 * index))
                network[index] &= kept == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - kept))
            }
            return SharedSubnet(network: network.map(String.init).joined(separator: ".") + "/\(subnet.bits)", interfaces: names,
                                addresses: subnet.members.map(\.address), members: subnet.members.map { "\($0.interface) \($0.address)" })
        }
    }

    /// Where a live stream's packets go: the controller's SetupEndpoints address, which is text without a scope. A
    /// link-local one (fe80::/10: a controller whose HAP connection runs over link-local names its own) is reachable only
    /// through its interface — `sendto` from the wildcard sockets fails with EHOSTUNREACH — so it gets the zone of the HAP
    /// connection (`zone`), else that of the interface our `localAddress` is on (`interfaces`, read only then). Other
    /// addresses, one that already has a zone, and one whose interface is unknown are used as they are.
    static func controllerHost(_ address: String, zone: String?, localAddress: String, interfaces: () -> [InterfaceAddress]) -> String {
        guard address.contains(":"), !address.contains("%"), isLinkLocal(address) else { return address }
        if let zone, !zone.isEmpty { return "\(address)%\(zone)" }
        let local = canonical(localAddress)
        guard let interface = interfaces().first(where: { $0.address == local })?.interface else { return address }
        return "\(address)%\(interface)"
    }

    /// Whether `localAddress` needs the interface list to answer a request of the `ipv6` family.
    static func needsInterfaces(localAddress: String, ipv6: Bool) -> Bool {
        let local = canonical(localAddress)
        return local.contains(":") != ipv6 || (ipv6 && isLinkLocal(local))
    }

    /// IPv6 address flags (`SIOCGIFAFLAG_IN6`): `IN6_IFF_DEPRECATED` and `IN6_IFF_TEMPORARY`. Darwin only; elsewhere every
    /// address counts as stable (Linux keeps the same flags in /proc/net/if_inet6, which a port reads here).
    private struct AddressFlags {
        #if canImport(Darwin)
        private let descriptor = socket(AF_INET6, SOCK_DGRAM, 0)
        /// `_IOWR('i', 73, struct in6_ifreq)`: the macro does not import into Swift.
        private let request = UInt(0xC000_0000) | UInt(MemoryLayout<in6_ifreq>.size & 0x1FFF) << 16 | UInt(UInt8(ascii: "i")) << 8 | 73

        func close() {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
        }

        func flags(of address: UnsafeMutablePointer<sockaddr>, interface: String) -> (temporary: Bool, deprecated: Bool) {
            guard descriptor >= 0 else { return (false, false) }
            var query = in6_ifreq()
            withUnsafeMutableBytes(of: &query.ifr_name) { buffer in
                for (index, byte) in interface.utf8.prefix(buffer.count - 1).enumerated() { buffer[index] = byte }
            }
            address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { query.ifr_ifru.ifru_addr = $0.pointee }
            guard ioctl(descriptor, request, &query) == 0 else { return (false, false) }
            let bits = query.ifr_ifru.ifru_flags6
            return (bits & Int32(IN6_IFF_TEMPORARY) != 0, bits & Int32(IN6_IFF_DEPRECATED) != 0)
        }
        #else
        func close() {}

        func flags(of address: UnsafeMutablePointer<sockaddr>, interface: String) -> (temporary: Bool, deprecated: Bool) { (false, false) }
        #endif
    }

    /// Every address configured on an interface that is up (`getifaddrs`).
    static func interfaceAddresses() -> [InterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        let addressFlags = AddressFlags()
        defer { addressFlags.close() }
        var result: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, UInt32(entry.pointee.ifa_flags) & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                guard inet_ntop(AF_INET, &ipv4, &text, socklen_t(text.count)) != nil else { continue }
            case AF_INET6:
                var ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                guard inet_ntop(AF_INET6, &ipv6, &text, socklen_t(text.count)) != nil else { continue }
            default:
                continue
            }
            let literal = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let isIPv6 = Int32(address.pointee.sa_family) == AF_INET6
            let flags = isIPv6 && !isLinkLocal(literal) ? addressFlags.flags(of: address, interface: name) : (temporary: false, deprecated: false)
            result.append(InterfaceAddress(interface: name, address: literal, prefixLength: prefixLength(of: entry.pointee.ifa_netmask),
                                           isTemporary: flags.temporary, isDeprecated: flags.deprecated))
        }
        return result
    }

    /// The kernel's IPv4 routing table as `NET_RT_DUMP` returns it (`MacVPNDetector` reads it), nil when it cannot be read or
    /// there is no such interface on this platform.
    static func routeDump() -> [UInt8]? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(length))
        #else
        return nil
        #endif
    }

    /// The name of the interface with this index ("en0"), nil when there is none.
    static func interfaceName(index: Int) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The number of leading one bits of an interface netmask (`ifa_netmask`), nil without one or for a mask that is not
    /// a contiguous prefix.
    private static func prefixLength(of mask: UnsafeMutablePointer<sockaddr>?) -> Int? {
        guard let mask else { return nil }
        let bytes: [UInt8]
        switch Int32(mask.pointee.sa_family) {
        case AF_INET:
            let raw = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            bytes = withUnsafeBytes(of: raw) { Array($0) }
        case AF_INET6:
            let raw = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            bytes = withUnsafeBytes(of: raw) { Array($0) }
        default:
            return nil
        }
        var bits = 0
        var counting = true
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                let one = (byte >> UInt8(shift)) & 1 == 1
                if one { if counting { bits += 1 } else { return nil } } else { counting = false }
            }
        }
        return bits
    }

    /// The address without a zone (`%en0`), IPv4-mapped IPv6 as IPv4, IPv6 in its canonical text form.
    static func canonical(_ address: String) -> String {
        var bare = address
        if bare.hasPrefix("["), bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        if let percent = bare.firstIndex(of: "%") { bare = String(bare[..<percent]) }
        guard bare.contains(":") else { return bare }
        var raw = in6_addr()
        guard inet_pton(AF_INET6, bare, &raw) == 1 else { return bare.lowercased() }
        let bytes = withUnsafeBytes(of: raw) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return bytes[12..<16].map(String.init).joined(separator: ".")
        }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &raw, &text, socklen_t(text.count)) != nil else { return bare.lowercased() }
        return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func isLinkLocal(_ address: String) -> Bool {
        let lower = address.lowercased()
        return lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb")
    }

    // MARK: - Choosing where a stream goes

    /// The raw bytes of a numeric address: 4 (IPv4) or 16 (IPv6), nil when it is not one.
    static func addressBytes(_ address: String) -> [UInt8]? {
        let text = canonical(address)
        if text.contains(":") {
            var raw = in6_addr()
            guard inet_pton(AF_INET6, text, &raw) == 1 else { return nil }
            return withUnsafeBytes(of: raw) { Array($0) }
        }
        var raw = in_addr()
        guard inet_pton(AF_INET, text, &raw) == 1 else { return nil }
        return withUnsafeBytes(of: raw) { Array($0) }
    }

    /// Whether the first `bits` bits of both byte strings agree (and they are of one family).
    static func samePrefix(_ lhs: [UInt8], _ rhs: [UInt8], bits: Int) -> Bool {
        guard lhs.count == rhs.count, bits >= 0, bits <= lhs.count * 8 else { return false }
        let whole = bits / 8
        guard lhs.prefix(whole) == rhs.prefix(whole) else { return false }
        let rest = bits % 8
        guard rest > 0 else { return true }
        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - rest))
        return lhs[whole] & mask == rhs[whole] & mask
    }

    static func isLoopback(_ address: String) -> Bool {
        guard let bytes = addressBytes(address) else { return false }
        if bytes.count == 4 { return bytes[0] == 127 }
        return bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
    }

    /// Whether `address` lies on a network one of this machine's interfaces is attached to, so a packet to it is sent
    /// to a neighbour and not through some tunnel: inside an interface's subnet (`prefixLength`; unknown means only the
    /// interface's own address, which is excluded below), loopback always, and an IPv6 link-local address when an
    /// interface (the one named by the address's own zone, else `zone`, when there is one) has a link-local address of
    /// its own. An address this machine itself holds on a tunnel interface is not "on the network": a controller
    /// advertising it is on the far side of a tunnel whose far end happens to carry the same address as ours (NordLynx
    /// hands every device 10.5.0.2). One it holds on a LAN interface is the Mac itself (the Home app on this very Mac asks
    /// for a stream): local. An IPv4 address that no interface subnet holds but a specific route of the routing table
    /// (`routes`, `routeTable()`) covers through a LAN interface (a second subnet or an IoT VLAN behind the router, reached
    /// through a static route) is local too: a controller there is no VPN client. A route through a tunnel never counts.
    static func isOnLocalNetwork(_ address: String, zone: String? = nil, interfaces: [InterfaceAddress],
                                 routes: [MacVPNDetector.InterfaceRoute] = []) -> Bool {
        let host = canonical(address)
        guard let bytes = addressBytes(host) else { return false }
        if isLoopback(host) { return true }
        let holders = interfaces.filter { $0.address == host }
        if !holders.isEmpty { return holders.contains { !MacVPNDetector.isTunnelName($0.interface) } }
        if bytes.count == 16, isLinkLocal(host) {
            let named = address.firstIndex(of: "%").map { String(address[address.index(after: $0)...]) }
            let scope = [named, zone].compactMap { $0 }.first { !$0.isEmpty }
            return interfaces.contains { $0.isIPv6 && $0.isLinkLocal && (scope == nil || $0.interface == scope) }
        }
        for interface in interfaces where interface.isIPv6 == (bytes.count == 16) {
            guard let prefix = interface.prefixLength, prefix > 0, let local = addressBytes(interface.address) else { continue }
            if samePrefix(bytes, local, bits: prefix) { return true }
        }
        return bytes.count == 4 && routes.contains {
            $0.prefixLength >= 8 && $0.covers(bytes) && $0.interface != "lo0" && !MacVPNDetector.isTunnelName($0.interface)
        }
    }

    /// The kernel's IPv4 routing table (`routeDump`); empty when it cannot be read.
    static func routeTable() -> [MacVPNDetector.InterfaceRoute] {
        guard let dump = routeDump() else { return [] }
        return MacVPNDetector.routes(inRouteDump: dump, interfaceName: interfaceName(index:))
    }

    /// Whether an off-network controller address looks like the address of a VPN tunnel (the app tells the person so): an
    /// IPv4 address (a tunnel's is private, 100.64/10 or 10.x like NordLynx's), or an IPv6 unique local one (fc00::/7).
    /// A global IPv6 address that merely is not in a prefix of ours is not taken for one.
    static func looksLikeTunnelAddress(_ address: String) -> Bool {
        guard let bytes = addressBytes(address) else { return false }
        if bytes.count == 4 { return !isLoopback(address) }
        return bytes[0] & 0xFE == 0xFC
    }

    /// A predicate: whether `other` names the same address as `address` (zones, brackets and IPv4-mapped spellings ignored).
    private static func isSameAddress(_ address: String) -> (String) -> Bool {
        let wanted = canonical(address)
        return { !$0.isEmpty && canonical($0) == wanted && addressBytes(wanted) != nil && !isLinkLocal(wanted) }
    }

    /// Where a live stream's SRTP goes (see `controllerRoute`).
    struct ControllerRoute: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// The controller's advertised address is on one of our networks: used as it is.
            case advertised
            /// The advertised address is on no network of ours (a VPN address) but the HAP connection's peer is: the stream
            /// goes to the peer's address.
            case peerAddress
            /// Neither is on a network of ours (or the peer is unusable): the advertised address, as before.
            case advertisedOffNetwork
        }

        /// The SetupEndpoints address, as the controller wrote it.
        var advertised: String
        /// The address to send to (without a zone; `controllerHost` scopes a link-local one).
        var host: String
        var kind: Kind

        /// The INFO line for a substitution, nil for the other routes.
        var explanation: String? {
            guard kind == .peerAddress else { return nil }
            return "controller advertised \(advertised) (not on this network, likely a VPN); sending to the HAP connection address \(host)"
        }

        /// How the destination was chosen, for the diagnostics trace.
        var summary: String {
            switch kind {
            case .advertised: "advertised \(advertised), on this network"
            case .peerAddress: "advertised \(advertised) is not on this network (VPN?): sent to the HAP connection address \(host)"
            case .advertisedOffNetwork: "advertised \(advertised), not on this network and no usable HAP connection address"
            }
        }
    }

    /// Picks the RTP destination (HAP-NodeJS and Scrypted do the same): the controller's advertised address when one of our
    /// interface networks holds it; else the HAP connection's peer address when that is on one of our networks, of the
    /// family of the stream (our UDP sockets are of that family) — an iPhone on a VPN advertises the tunnel's address
    /// while its HAP connection arrives over the LAN; else the advertised address, as before.
    /// An address the HAP connection itself comes from is reachable, whatever the interface subnets say (a controller on a routed
    /// subnet), so it is used as advertised.
    static func controllerRoute(advertised: String, peer: String?, zone: String?, ipv6: Bool, interfaces: [InterfaceAddress],
                                routes: [MacVPNDetector.InterfaceRoute] = []) -> ControllerRoute {
        if isOnLocalNetwork(advertised, zone: zone, interfaces: interfaces, routes: routes) || (peer.map(isSameAddress(advertised)) ?? false) {
            return ControllerRoute(advertised: advertised, host: advertised, kind: .advertised)
        }
        if let peer, !peer.isEmpty, let bytes = addressBytes(peer), (bytes.count == 16) == ipv6,
           isOnLocalNetwork(peer, zone: zone, interfaces: interfaces, routes: routes) {
            return ControllerRoute(advertised: advertised, host: canonical(peer), kind: .peerAddress)
        }
        return ControllerRoute(advertised: advertised, host: advertised, kind: .advertisedOffNetwork)
    }
}
