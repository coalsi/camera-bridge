import Foundation
import Testing
@testable import BridgeEngine

/// Which of the Mac's addresses a live stream uses and how it reads the network (`StreamAddress`, `MacVPNDetector`): the IPv6
/// address answered to a controller, subnets held by two interfaces, own and routed addresses, and the interfaces a blind session
/// scopes its sockets to.
struct StreamAddressSelectionTests {
    private func v6(_ interface: String, _ address: String, temporary: Bool = false, deprecated: Bool = false) -> InterfaceAddress {
        InterfaceAddress(interface: interface, address: address, prefixLength: 64, isTemporary: temporary, isDeprecated: deprecated)
    }

    // MARK: The IPv6 accessory address

    /// A user's Mac: getifaddrs lists a ULA before the global address, plus a deprecated and a current temporary one.
    private var dualStackEN0: [InterfaceAddress] {
        [v6("en0", "fe80::10d8:11ba:b93c:fb02"),
         v6("en0", "fdbc:e5e1:d077:1:4dd:a8cb:37a0:c167"),
         v6("en0", "2001:db8:4:7000:f85c:b64:c6a7:1965", temporary: true, deprecated: true),
         v6("en0", "2001:db8:4:7000:a967:91d4:868d:a198", temporary: true),
         v6("en0", "2001:db8:4:7000:40b:e3c3:fe43:6f1d"),
         v6("en0", "fd00:db8:a:b:28:5d6a:e4d:d132")]
    }

    @Test func theStableGlobalAddressBeatsALeadingULAAndTheTemporaryOnes() {
        let chosen = StreamAddress.preferredIPv6(dualStackEN0, controller: nil)
        #expect(chosen?.address == "2001:db8:4:7000:40b:e3c3:fe43:6f1d")
        // Through the accessory address entry point: the HAP connection came over IPv4, the controller wants IPv6.
        let interfaces = dualStackEN0 + [InterfaceAddress(interface: "en0", address: "192.0.2.69", prefixLength: 24)]
        #expect(StreamAddress.accessoryAddress(localAddress: "192.0.2.69", ipv6: true, interfaces: interfaces) == "2001:db8:4:7000:40b:e3c3:fe43:6f1d")
    }

    @Test func theControllersOwnPrefixWinsWhenItHoldsAStableAddress() {
        // The controller is on the ULA network: that is the address it can reach us at without a router.
        #expect(StreamAddress.preferredIPv6(dualStackEN0, controller: "fd00:db8:a:b:aaaa::1")?.address == "fd00:db8:a:b:28:5d6a:e4d:d132")
        #expect(StreamAddress.preferredIPv6(dualStackEN0, controller: "2001:db8:4:7000::77")?.address == "2001:db8:4:7000:40b:e3c3:fe43:6f1d",
                "same /64 as the controller, and never the temporary address that shares it")
        // A controller elsewhere (a link-local or foreign address) falls back to the global address.
        #expect(StreamAddress.preferredIPv6(dualStackEN0, controller: "fe80::1")?.address == "2001:db8:4:7000:40b:e3c3:fe43:6f1d")
        #expect(StreamAddress.preferredIPv6(dualStackEN0, controller: "2001:db8::5")?.address == "2001:db8:4:7000:40b:e3c3:fe43:6f1d")
    }

    @Test func aULAIsChosenOnlyWithoutAGlobalAddressAndTemporaryOnesOnlyAsALastResort() {
        let noGlobal = [v6("en0", "fe80::1"), v6("en0", "fdbc:e5e1:d077:1::5"), v6("en0", "fd00::9", temporary: true)]
        #expect(StreamAddress.preferredIPv6(noGlobal, controller: nil)?.address == "fdbc:e5e1:d077:1::5")
        let onlyTemporary = [v6("en0", "fe80::1"), v6("en0", "2001:db8::aa", temporary: true, deprecated: true), v6("en0", "2001:db8::bb", temporary: true)]
        #expect(StreamAddress.preferredIPv6(onlyTemporary, controller: nil)?.address == "2001:db8::bb", "a current temporary beats a deprecated one")
        let onlyLinkLocal = [v6("en0", "fe80::1")]
        #expect(StreamAddress.preferredIPv6(onlyLinkLocal, controller: nil) == nil)
        #expect(StreamAddress.preferredIPv6([], controller: "2001:db8::1") == nil)
    }

    @Test func addressFlagsDoNotChangeWhichInterfaceAddressesAreTheSame() {
        let plain = InterfaceAddress(interface: "en0", address: "2001:db8::1")
        let temporary = InterfaceAddress(interface: "en0", address: "2001:db8::1", isTemporary: true, isDeprecated: true)
        #expect(plain == temporary)
    }

    @Test func theMachinesAddressesCarryFlagsWithoutBreakingTheOthers() {
        let addresses = StreamAddress.interfaceAddresses()
        #expect(addresses.filter { !$0.isIPv6 }.allSatisfy { !$0.isTemporary && !$0.isDeprecated })
        #expect(addresses.filter { $0.isIPv6 && $0.isLinkLocal }.allSatisfy { !$0.isTemporary && !$0.isDeprecated })
        #expect(addresses.first { $0.address == "::1" }.map { !$0.isTemporary && !$0.isDeprecated } == true)
        #expect(addresses.contains { $0.address == "127.0.0.1" })
    }

    // MARK: One subnet, two interfaces

    @Test func twoInterfacesOnOneSubnetAreFound() {
        let interfaces = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
                          InterfaceAddress(interface: "en0", address: "192.0.2.69", prefixLength: 24),
                          InterfaceAddress(interface: "en1", address: "192.0.2.25", prefixLength: 24),
                          InterfaceAddress(interface: "en5", address: "10.1.2.3", prefixLength: 24),
                          InterfaceAddress(interface: "utun4", address: "192.0.2.77", prefixLength: 24),
                          InterfaceAddress(interface: "en0", address: "fe80::1", prefixLength: 64)]
        let shared = StreamAddress.sharedSubnets(interfaces)
        #expect(shared == [StreamAddress.SharedSubnet(network: "192.0.2.0/24", interfaces: ["en0", "en1"], addresses: ["192.0.2.69", "192.0.2.25"],
                                                      members: ["en0 192.0.2.69", "en1 192.0.2.25"])])
        // Two addresses on one interface are not two interfaces; a /16 and a /24 of different networks are not shared.
        let alias = [InterfaceAddress(interface: "en0", address: "10.0.0.5", prefixLength: 24), InterfaceAddress(interface: "en0", address: "10.0.0.6", prefixLength: 24),
                     InterfaceAddress(interface: "en1", address: "10.0.1.5", prefixLength: 24)]
        #expect(StreamAddress.sharedSubnets(alias).isEmpty)
        // Without a netmask nothing is known to be shared.
        #expect(StreamAddress.sharedSubnets([InterfaceAddress(interface: "en0", address: "10.0.0.5"), InterfaceAddress(interface: "en1", address: "10.0.0.6")]).isEmpty)
        // The network text of an unaligned prefix.
        let wide = StreamAddress.sharedSubnets([InterfaceAddress(interface: "en0", address: "172.16.9.5", prefixLength: 20),
                                                InterfaceAddress(interface: "en1", address: "172.16.12.7", prefixLength: 20)])
        #expect(wide.first?.network == "172.16.0.0/20")
    }

    @Test func aBlindSessionFlipsFirstToTheOwnerThenNothingThenTheOtherInterface() {
        let interfaces = [InterfaceAddress(interface: "en0", address: "192.0.2.69", prefixLength: 24),
                          InterfaceAddress(interface: "en1", address: "192.0.2.25", prefixLength: 24)]
        // Bound only: the owner's scope, then the routing table's choice, then the other interface.
        #expect(StreamingHandler.recoveryScopes(source: "192.0.2.25", scopedTo: nil, interfaces: interfaces) == ["en1", nil, "en0"])
        // Already scoped to the owner: unscoped first, then the other.
        #expect(StreamingHandler.recoveryScopes(source: "192.0.2.25", scopedTo: "en1", interfaces: interfaces) == [nil, "en0"])
        // One interface: only the owner / unscoped steps.
        #expect(StreamingHandler.recoveryScopes(source: "192.0.2.69", scopedTo: nil, interfaces: Array(interfaces.prefix(1))) == ["en0", nil])
        // The wildcard (no source) or an address that is not ours: nothing to flip.
        #expect(StreamingHandler.recoveryScopes(source: nil, scopedTo: nil, interfaces: interfaces).isEmpty)
        #expect(StreamingHandler.recoveryScopes(source: "203.0.113.9", scopedTo: nil, interfaces: interfaces).isEmpty)
    }

    // MARK: Own, routed and tunnel addresses

    private let lan = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
                       InterfaceAddress(interface: "en0", address: "192.0.2.5", prefixLength: 24),
                       InterfaceAddress(interface: "utun4", address: "10.5.0.2", prefixLength: 32)]

    @Test func theMacsOwnLANAddressIsLocalButItsTunnelAddressIsNot() {
        #expect(StreamAddress.isOnLocalNetwork("192.0.2.5", interfaces: lan), "the Home app on this very Mac")
        #expect(!StreamAddress.isOnLocalNetwork("10.5.0.2", interfaces: lan), "NordLynx hands every device 10.5.0.2: the far end is not us")
        // On a LAN interface and a tunnel at once: the LAN interface vouches for it.
        let both = lan + [InterfaceAddress(interface: "en1", address: "10.5.0.2", prefixLength: 24)]
        #expect(StreamAddress.isOnLocalNetwork("10.5.0.2", interfaces: both))
    }

    @Test func aRouteThroughALANInterfaceMakesAnAddressLocalButARouteThroughATunnelDoesNot() {
        let routes = [MacVPNDetector.InterfaceRoute(destination: [10, 20, 0, 0], prefixLength: 16, interface: "en0"),
                      MacVPNDetector.InterfaceRoute(destination: [10, 99, 0, 0], prefixLength: 16, interface: "utun4"),
                      MacVPNDetector.InterfaceRoute(destination: [0, 0, 0, 0], prefixLength: 0, interface: "en0"),
                      MacVPNDetector.InterfaceRoute(destination: [172, 16, 0, 0], prefixLength: 4, interface: "en0"),
                      MacVPNDetector.InterfaceRoute(destination: [10, 30, 1, 1], prefixLength: 32, interface: "lo0")]
        #expect(StreamAddress.isOnLocalNetwork("10.20.30.40", interfaces: lan, routes: routes), "a routed subnet (an IoT VLAN)")
        #expect(!StreamAddress.isOnLocalNetwork("10.20.30.40", interfaces: lan, routes: []))
        #expect(!StreamAddress.isOnLocalNetwork("10.99.1.1", interfaces: lan, routes: routes), "through a tunnel it is a VPN's network")
        #expect(!StreamAddress.isOnLocalNetwork("8.8.8.8", interfaces: lan, routes: routes), "the default route covers everything: it vouches for nothing")
        #expect(!StreamAddress.isOnLocalNetwork("172.20.1.1", interfaces: lan, routes: routes), "a /4 is no network of ours")
        #expect(!StreamAddress.isOnLocalNetwork("10.30.1.1", interfaces: lan, routes: routes), "loopback routes do not count")
    }

    @Test func theRouteTheHAPConnectionComesFromIsUsedAsAdvertised() {
        // No interface subnet, no route: only the HAP connection's own address vouches for it.
        let route = StreamAddress.controllerRoute(advertised: "172.20.1.9", peer: "172.20.1.9", zone: nil, ipv6: false, interfaces: lan)
        #expect(route.kind == .advertised && route.host == "172.20.1.9")
        // A VPN client's tunnel address with the HAP connection on the LAN is still the fallback.
        let vpn = StreamAddress.controllerRoute(advertised: "172.20.1.9", peer: "192.0.2.9", zone: nil, ipv6: false, interfaces: lan)
        #expect(vpn.kind == .peerAddress && vpn.host == "192.0.2.9")
        // A routed advertised address with a LAN peer: used as advertised through the route.
        let routes = [MacVPNDetector.InterfaceRoute(destination: [172, 20, 0, 0], prefixLength: 16, interface: "en0")]
        #expect(StreamAddress.controllerRoute(advertised: "172.20.1.9", peer: "192.0.2.9", zone: nil, ipv6: false, interfaces: lan, routes: routes).kind == .advertised)
    }

    // MARK: Reading the routing table

    /// One route message as the kernel dumps it (see `NetworkNoticeTests`).
    private func routeMessage(destination: [UInt8], mask: [UInt8]?, interfaceIndex: Int, flags: Int32 = 0x1 | 0x2) -> [UInt8] {
        func sockaddr(_ address: [UInt8], length: Int) -> [UInt8] {
            var bytes = [UInt8(length), 2, 0, 0] + address
            bytes += [UInt8](repeating: 0, count: max(0, length - bytes.count))
            let padded = length == 0 ? 4 : 1 + ((length - 1) | 3)
            return bytes + [UInt8](repeating: 0, count: padded - bytes.count)
        }
        var addresses: Int32 = 1
        var payload = sockaddr(destination, length: 16)
        if let mask {
            addresses |= 4
            payload += sockaddr(mask, length: 4 + mask.count)
        }
        var header = [UInt8](repeating: 0, count: 92)
        let length = 92 + payload.count
        header[0] = UInt8(length & 0xFF); header[1] = UInt8(length >> 8)
        header[4] = UInt8(interfaceIndex & 0xFF); header[5] = UInt8(interfaceIndex >> 8)
        for (offset, value) in [(8, flags), (12, addresses)] {
            let raw = UInt32(bitPattern: value)
            for byte in 0..<4 { header[offset + byte] = UInt8((raw >> (8 * UInt32(byte))) & 0xFF) }
        }
        return header + payload
    }

    @Test func routesAreReadFromARouteDumpWithTheirPrefixAndInterface() {
        let names = [4: "en0", 21: "utun4"]
        let dump = routeMessage(destination: [0, 0, 0, 0], mask: nil, interfaceIndex: 4)
            + routeMessage(destination: [192, 168, 4, 0], mask: [255, 255, 255], interfaceIndex: 4)
            + routeMessage(destination: [10, 20, 0, 0], mask: [255, 255], interfaceIndex: 4)
            + routeMessage(destination: [192, 168, 4, 77], mask: nil, interfaceIndex: 4)   // a host route
            + routeMessage(destination: [10, 5, 0, 0], mask: [255, 255], interfaceIndex: 21)
            + routeMessage(destination: [10, 6, 0, 0], mask: [255, 255], interfaceIndex: 99)   // an interface we cannot name
            + routeMessage(destination: [10, 7, 0, 0], mask: [255, 255], interfaceIndex: 4, flags: 0x2)   // not up
            + routeMessage(destination: [10, 8, 0, 0], mask: [255, 255], interfaceIndex: 4, flags: 0x1 | 0x1000000)   // interface scoped
        let routes = MacVPNDetector.routes(inRouteDump: dump, interfaceName: { names[$0] })
        #expect(routes == [MacVPNDetector.InterfaceRoute(destination: [0, 0, 0, 0], prefixLength: 0, interface: "en0"),
                           MacVPNDetector.InterfaceRoute(destination: [192, 168, 4, 0], prefixLength: 24, interface: "en0"),
                           MacVPNDetector.InterfaceRoute(destination: [10, 20, 0, 0], prefixLength: 16, interface: "en0"),
                           MacVPNDetector.InterfaceRoute(destination: [192, 168, 4, 77], prefixLength: 32, interface: "en0"),
                           MacVPNDetector.InterfaceRoute(destination: [10, 5, 0, 0], prefixLength: 16, interface: "utun4")])
        #expect(routes[2].covers([10, 20, 3, 4]) && !routes[2].covers([10, 21, 3, 4]))
        #expect(MacVPNDetector.routes(inRouteDump: [], interfaceName: { names[$0] }).isEmpty)
        #expect(MacVPNDetector.routes(inRouteDump: [1, 2, 3], interfaceName: { names[$0] }).isEmpty)
    }

    @Test func theSystemsRoutingTableYieldsRoutes() {
        #if canImport(Darwin)
        let routes = StreamAddress.routeTable()
        #expect(!routes.isEmpty, "a Mac always has its loopback and LAN routes")
        #expect(routes.allSatisfy { $0.destination.count == 4 && (0...32).contains($0.prefixLength) && !$0.interface.isEmpty })
        #endif
    }
}
