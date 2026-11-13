import Foundation
import Testing
@testable import BridgeEngine

/// The IPv4 addresses a plugin or the secure address takes for "this machine's network".
struct LocalAddressesTests {
    /// Away from home's `wg-away` holds 10.a.b.1. Taken as the home address while the LAN address is briefly gone (a DHCP renewal), it
    /// would be sent to the website and kept, and the secure name would then fail at home.
    @Test func tunnelInterfacesAreNotTheMachinesNetwork() {
        let entries = [InterfaceAddress(interface: "lo", address: "127.0.0.1"),
                       InterfaceAddress(interface: "enp1s0", address: "192.168.77.5"),
                       InterfaceAddress(interface: "wg-away", address: "10.77.12.1"),
                       InterfaceAddress(interface: "utun4", address: "10.8.0.2"),
                       InterfaceAddress(interface: "enp1s0", address: "2001:db8::5")]
        #expect(BridgeEngine.localIPv4Addresses(among: entries) == ["192.168.77.5"])
    }
}
