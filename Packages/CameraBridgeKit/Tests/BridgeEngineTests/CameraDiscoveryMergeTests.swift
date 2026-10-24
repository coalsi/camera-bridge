import CameraAdapters
import Foundation
import Testing
@testable import BridgeEngine

/// The camera search: WS-Discovery's cameras and SADP's merged (`BridgeEngine.mergedDiscovery`), a camera SADP finds on none of the
/// box's networks marked so. Made-up addresses only.
@Suite struct CameraDiscoveryMergeTests {
    private let interfaces = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
                              InterfaceAddress(interface: "utun3", address: "192.168.1.200", prefixLength: 24),
                              InterfaceAddress(interface: "en0", address: "192.168.77.2", prefixLength: 22)]

    @Test func sadpAddsWhatONVIFDidNotSee() {
        let onvif = [DiscoveredCamera(host: "192.168.77.30", name: "Porch", xAddrs: [URL(string: "http://192.168.77.30/onvif/device_service")!])]
        let sadp = [SADPDevice(mac: "02:00:5e:00:53:01", ipv4Address: "192.168.77.30", activated: true, model: "I91ET", httpPort: 80),
                    SADPDevice(mac: "02:00:5e:00:53:02", ipv4Address: "192.168.1.64", dhcp: false, activated: true, model: "I91ET"),
                    SADPDevice(mac: "02:00:5e:00:53:03", ipv4Address: "192.168.78.9", activated: false, model: "DS-2CD", httpPort: 8080)]
        let merged = BridgeEngine.mergedDiscovery(onvif: onvif, sadp: sadp, interfaces: interfaces)
        #expect(merged.map(\.host) == ["192.168.77.30", "192.168.1.64", "192.168.78.9"])
        #expect(merged[0].name == "Porch" && merged[0].hardware == "I91ET" && merged[0].activated == true && merged[0].onAnotherNetwork == nil)
        #expect(merged[1].onAnotherNetwork == true, "the factory address is on none of the box's networks (a tunnel's does not count)")
        #expect(merged[2].onAnotherNetwork == nil && merged[2].activated == false && merged[2].httpPort == 8080)
    }

    @Test func withoutSADPAnswersTheListIsONVIFs() {
        let onvif = [DiscoveredCamera(host: "192.168.77.30")]
        #expect(BridgeEngine.mergedDiscovery(onvif: onvif, sadp: [], interfaces: interfaces) == onvif)
    }
}
