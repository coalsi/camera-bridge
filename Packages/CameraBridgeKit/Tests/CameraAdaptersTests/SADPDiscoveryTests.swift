import Foundation
import Testing
@testable import CameraAdapters

/// Hikvision's SADP (`SADPDiscovery`): the inquiry, the devices' answers (written from SADP's field list, made-up values only: no real
/// camera's data), and the subnet check that tells a camera stuck on another network. No multicast is sent.
@Suite struct SADPDiscoveryTests {
    /// An answer with every field Camera Bridge reads, in SADP's shape.
    static func reply(mac: String = "02-00-5E-00-53-01", address: String = "192.168.1.64", mask: String = "255.255.255.0",
                      gateway: String = "192.168.1.1", dhcp: String = "false", activated: String = "true", model: String = "I91ET",
                      serial: String = "EXAMPLE-SERIAL-0001", httpPort: String = "80") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?><ProbeMatch><Uuid>11111111-2222-3333-4444-555555555555</Uuid><Types>inquiry</Types>\
        <DeviceType>12345</DeviceType><DeviceDescription>\(model)</DeviceDescription><DeviceSN>\(serial)</DeviceSN>\
        <CommandPort>8000</CommandPort><HttpPort>\(httpPort)</HttpPort><MAC>\(mac)</MAC><IPv4Address>\(address)</IPv4Address>\
        <IPv4SubnetMask>\(mask)</IPv4SubnetMask><IPv4Gateway>\(gateway)</IPv4Gateway><DHCP>\(dhcp)</DHCP>\
        <SoftwareVersion>V0.0.0</SoftwareVersion><Activated>\(activated)</Activated></ProbeMatch>
        """.utf8)
    }

    @Test func theInquiryIsSADPs() throws {
        let text = String(decoding: SADPDiscovery.probeMessage(uuid: "ABC-123"), as: UTF8.self)
        #expect(text.hasSuffix("<Probe><Uuid>ABC-123</Uuid><Types>inquiry</Types></Probe>"))
        #expect(SADPDiscovery.multicastGroup == "239.255.255.250" && SADPDiscovery.port == 37020)
    }

    @Test func anAnswerIsReadWhole() throws {
        let device = try #require(SADPDiscovery.parseReply(Self.reply()))
        #expect(device == SADPDevice(mac: "02:00:5e:00:53:01", ipv4Address: "192.168.1.64", subnetMask: "255.255.255.0", gateway: "192.168.1.1",
                                     dhcp: false, activated: true, model: "I91ET", serialNumber: "EXAMPLE-SERIAL-0001", httpPort: 80))
    }

    @Test func anInactiveCameraOnDHCPIsReadSo() throws {
        let device = try #require(SADPDiscovery.parseReply(Self.reply(address: "192.0.2.40", dhcp: "true", activated: "false", httpPort: "8080")))
        #expect(device.activated == false && device.dhcp == true && device.httpPort == 8080)
    }

    @Test func anythingElseIsNoDevice() {
        #expect(SADPDiscovery.parseReply(SADPDiscovery.probeMessage(uuid: "X")) == nil, "the bridge's own inquiry, heard on the group")
        #expect(SADPDiscovery.parseReply(Data("not xml".utf8)) == nil)
        #expect(SADPDiscovery.parseReply(Self.reply(mac: "")) == nil)
        #expect(SADPDiscovery.parseReply(Self.reply(address: "")) == nil)
        #expect(SADPDiscovery.parseReply(Self.reply(address: "192.168.1.256")) == nil)
        let odd = SADPDiscovery.parseReply(Self.reply(dhcp: "maybe", activated: "", model: "", serial: "", httpPort: "99999"))
        #expect(odd?.dhcp == nil && odd?.activated == nil && odd?.model == nil && odd?.serialNumber == nil && odd?.httpPort == nil)
    }

    @Test func oneEntryPerMAC() throws {
        let first = try #require(SADPDiscovery.parseReply(Self.reply()))
        let again = try #require(SADPDiscovery.parseReply(Self.reply(mac: "02:00:5e:00:53:01")))
        let other = try #require(SADPDiscovery.parseReply(Self.reply(mac: "02-00-5E-00-53-02", address: "192.168.1.65")))
        #expect(SADPDiscovery.merge([first, again, other]) == [first, other])
    }

    @Test func theSubnetCheckTellsACameraOnAnotherNetwork() throws {
        let stuck = try #require(SADPDiscovery.parseReply(Self.reply()))
        let home = try #require(SADPDiscovery.parseReply(Self.reply(address: "192.168.77.37")))
        let box: [(address: String, prefixLength: Int?)] = [("192.168.77.2", 22), ("10.9.0.1", nil)]
        #expect(!stuck.isOnNetwork(of: box), "the factory 192.168.1.64 is on none of the box's networks")
        #expect(home.isOnNetwork(of: box))
        #expect(SADPDevice(mac: "m", ipv4Address: "192.168.79.255").isOnNetwork(of: box), "a /22 reaches 192.168.76.0 to 192.168.79.255")
        #expect(!SADPDevice(mac: "m", ipv4Address: "192.168.8.0").isOnNetwork(of: box))
        #expect(!SADPDevice(mac: "m", ipv4Address: "10.9.0.5").isOnNetwork(of: box), "a network without a prefix length matches nothing")
        #expect(SADPDevice(mac: "m", ipv4Address: "192.168.77.2").isOnNetwork(of: [("192.168.77.2", 32)]))
        #expect(!SADPDevice(mac: "m", ipv4Address: "fe80::1").isOnNetwork(of: box))
    }
}
