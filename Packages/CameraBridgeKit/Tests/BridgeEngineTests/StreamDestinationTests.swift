import Foundation
import Testing
@testable import BridgeEngine

/// Where a live stream's SRTP goes (`StreamAddress.controllerRoute`): the controller's advertised SetupEndpoints address,
/// unless that is on no network of this machine (an iPhone on a VPN advertises the tunnel's address) and the HAP
/// connection's peer address is.
struct StreamDestinationTests {
    /// A Mac on 192.0.2.0/24 and an IPv6 LAN, with a NordLynx tunnel (the same 10.5.0.2 the iPhone's tunnel has).
    static let interfaces = [
        InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
        InterfaceAddress(interface: "lo0", address: "::1", prefixLength: 128),
        InterfaceAddress(interface: "lo0", address: "fe80::1", prefixLength: 64),
        InterfaceAddress(interface: "en0", address: "192.0.2.5", prefixLength: 24),
        InterfaceAddress(interface: "en0", address: "fe80::aa:bb", prefixLength: 64),
        InterfaceAddress(interface: "en0", address: "fd12:3456:789a::5", prefixLength: 64),
        InterfaceAddress(interface: "en0", address: "2001:db8:1::5", prefixLength: 64),
        InterfaceAddress(interface: "en1", address: "172.16.8.9", prefixLength: 20),
        InterfaceAddress(interface: "utun4", address: "10.5.0.2", prefixLength: 32),
    ]

    private func route(_ advertised: String, peer: String?, zone: String? = nil, ipv6: Bool = false,
                       interfaces: [InterfaceAddress] = StreamDestinationTests.interfaces) -> StreamAddress.ControllerRoute {
        StreamAddress.controllerRoute(advertised: advertised, peer: peer, zone: zone, ipv6: ipv6, interfaces: interfaces)
    }

    // MARK: IPv4

    @Test func anAdvertisedAddressOnASubnetIsUsed() {
        let onLAN = route("192.0.2.20", peer: "192.0.2.20")
        #expect(onLAN.kind == .advertised && onLAN.host == "192.0.2.20" && onLAN.explanation == nil)
        // The advertised address wins even when the peer differs (a second interface of the controller).
        #expect(route("192.0.2.21", peer: "192.0.2.20").host == "192.0.2.21")
        #expect(route("172.16.15.200", peer: "192.0.2.20").host == "172.16.15.200", "inside en1's /20")
        #expect(route("172.16.16.1", peer: "192.0.2.20").host == "192.0.2.20", "just outside en1's /20")
    }

    @Test func anOffSubnetAdvertisedAddressGivesWayToAPeerOnASubnet() {
        // A user's log: HAP from 192.0.2.20, SetupEndpoints says 10.5.0.2.
        let vpn = route("10.5.0.2", peer: "192.0.2.20")
        #expect(vpn.kind == .peerAddress && vpn.host == "192.0.2.20" && vpn.advertised == "10.5.0.2")
        #expect(vpn.explanation == "controller advertised 10.5.0.2 (not on this network, likely a VPN); sending to the HAP connection address 192.0.2.20")
        // 10.5.0.2 is also one of our own addresses (the Mac's tunnel): it is us, not the controller.
        #expect(route("10.5.0.2", peer: "192.0.2.20", interfaces: Self.interfaces).kind == .peerAddress)
        #expect(route("203.0.113.8", peer: "192.0.2.20").host == "192.0.2.20")
        #expect(route("100.64.0.9", peer: "::ffff:192.0.2.20").host == "192.0.2.20", "an IPv4-mapped peer is the IPv4 address")
    }

    @Test func whenNeitherIsOnASubnetTheAdvertisedAddressStays() {
        let neither = route("10.5.0.2", peer: "198.51.100.7")
        #expect(neither.kind == .advertisedOffNetwork && neither.host == "10.5.0.2" && neither.explanation == nil)
        #expect(route("10.5.0.2", peer: nil).kind == .advertisedOffNetwork)
        #expect(route("10.5.0.2", peer: "").host == "10.5.0.2")
        #expect(route("10.5.0.2", peer: "not an address").host == "10.5.0.2")
        // Nothing known about the machine's networks: as before.
        #expect(route("10.5.0.2", peer: "192.0.2.20", interfaces: []).host == "10.5.0.2")
        // An interface whose netmask is unknown vouches for nothing but itself.
        let unknownMask = [InterfaceAddress(interface: "en0", address: "192.0.2.5")]
        #expect(route("10.5.0.2", peer: "192.0.2.20", interfaces: unknownMask).host == "10.5.0.2")
    }

    @Test func loopbackIsAlwaysLocal() {
        #expect(route("127.0.0.1", peer: "127.0.0.1", interfaces: []).kind == .advertised)
        #expect(route("::1", peer: "::1", ipv6: true, interfaces: []).kind == .advertised)
        #expect(route("10.5.0.2", peer: "127.0.0.1", interfaces: []).host == "127.0.0.1")
    }

    @Test func thePeerMustBeOfTheStreamsAddressFamily() {
        // An IPv4 stream cannot be sent to an IPv6 peer (the sockets are IPv4), and the reverse.
        #expect(route("10.5.0.2", peer: "fd12:3456:789a::77", ipv6: false).host == "10.5.0.2")
        #expect(route("fd00:bad::2", peer: "192.0.2.20", ipv6: true).host == "fd00:bad::2")
    }

    // MARK: IPv6

    @Test func ipv6AdvertisedOnASubnetIsUsed() {
        let onLAN = route("fd12:3456:789a::77", peer: "fd12:3456:789a::78", ipv6: true)
        #expect(onLAN.kind == .advertised && onLAN.host == "fd12:3456:789a::77")
        #expect(route("2001:db8:1::abcd", peer: "fd12:3456:789a::78", ipv6: true).host == "2001:db8:1::abcd")
        #expect(route("2001:db8:2::1", peer: "fd12:3456:789a::78", ipv6: true).host == "fd12:3456:789a::78", "other /64")
    }

    @Test func anOffSubnetIPv6AdvertisedAddressGivesWayToThePeer() {
        let vpn = route("fd00:dead:beef::2", peer: "2001:db8:1::99", ipv6: true)
        #expect(vpn.kind == .peerAddress && vpn.host == "2001:db8:1::99" && vpn.advertised == "fd00:dead:beef::2")
        #expect(vpn.explanation?.contains("sending to the HAP connection address 2001:db8:1::99") == true)
        // The peer's text is canonical: no zone, lower case.
        #expect(route("fd00:dead:beef::2", peer: "FD12:3456:789A::99%en0", ipv6: true).host == "fd12:3456:789a::99")
        #expect(route("fd00:dead:beef::2", peer: "2001:db8:99::1", ipv6: true).kind == .advertisedOffNetwork)
    }

    @Test func linkLocalAddressesNeedALinkLocalInterface() {
        // An fe80 controller on the LAN: its (unscoped) advertised address is on-link, and kept (the zone is added later).
        #expect(route("fe80::1c:2d", peer: "fe80::1c:2d", zone: "en0", ipv6: true).kind == .advertised)
        // The advertised address is a VPN's global one, the HAP connection ran over link-local: the peer goes, with its zone
        // applied by `controllerHost`.
        let vpn = route("fd00:dead:beef::2", peer: "fe80::1c:2d%en0", zone: "en0", ipv6: true)
        #expect(vpn.kind == .peerAddress && vpn.host == "fe80::1c:2d")
        #expect(StreamAddress.controllerHost(vpn.host, zone: "en0", localAddress: "fe80::aa:bb", interfaces: { Self.interfaces }) == "fe80::1c:2d%en0")
        // The zone must name an interface that has a link-local address.
        #expect(route("fd00:dead:beef::2", peer: "fe80::1c:2d", zone: "utun4", ipv6: true).kind == .advertisedOffNetwork)
        // No link-local address on any interface: nothing is on-link.
        let noLinkLocal = Self.interfaces.filter { !($0.isIPv6 && $0.isLinkLocal) }
        #expect(route("fd00:dead:beef::2", peer: "fe80::1c:2d", zone: "en0", ipv6: true, interfaces: noLinkLocal).kind == .advertisedOffNetwork)
    }

    @Test func subnetMathHandlesUnalignedPrefixes() {
        #expect(StreamAddress.samePrefix([192, 168, 4, 20], [192, 168, 4, 5], bits: 24))
        #expect(!StreamAddress.samePrefix([192, 168, 5, 20], [192, 168, 4, 5], bits: 24))
        #expect(StreamAddress.samePrefix([172, 16, 15, 1], [172, 16, 8, 9], bits: 20))
        #expect(!StreamAddress.samePrefix([172, 16, 16, 1], [172, 16, 8, 9], bits: 20))
        #expect(StreamAddress.samePrefix([1, 2, 3, 4], [9, 9, 9, 9], bits: 0))
        #expect(!StreamAddress.samePrefix([1, 2, 3, 4], [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16], bits: 8), "different families")
    }

    @Test func theMachinesInterfacesCarryPrefixLengths() {
        let addresses = StreamAddress.interfaceAddresses()
        let loopback = addresses.first { $0.address == "127.0.0.1" }
        #expect(loopback?.prefixLength == 8)
        // Every real IPv4 interface address has a netmask.
        #expect(addresses.filter { !$0.isIPv6 }.allSatisfy { $0.prefixLength != nil })
    }
}
