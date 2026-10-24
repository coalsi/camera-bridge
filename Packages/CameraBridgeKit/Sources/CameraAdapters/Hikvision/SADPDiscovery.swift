import BridgeSupport
import Foundation

/// A camera that answered Hikvision's SADP (Search Active Devices Protocol): Hikvision and its OEMs (ANNKE, HiWatch, LTS…) answer it
/// whatever their address is, so it finds a camera stuck on another subnet (Hikvision's factory 192.168.1.64 after its DHCP went off) and
/// one that has not been set up yet (`activated` false). Its MAC and serial number identify it; they are shown to no one and never logged.
public struct SADPDevice: Sendable, Equatable, Codable {
    /// The hardware address as the camera gives it ("aa-bb-cc-dd-ee-ff"), lowercased with colons.
    public var mac: String
    public var ipv4Address: String
    public var subnetMask: String?
    public var gateway: String?
    /// The camera takes its address from DHCP; nil when it does not say.
    public var dhcp: Bool?
    /// The camera has an admin password (`Activated`); nil when it does not say.
    public var activated: Bool?
    /// Its model, as SADP describes it (`DeviceDescription`, "I91ET").
    public var model: String?
    /// `DeviceSN`.
    public var serialNumber: String?
    /// `HttpPort`, its web page's port; nil when it does not say.
    public var httpPort: Int?

    public init(mac: String, ipv4Address: String, subnetMask: String? = nil, gateway: String? = nil, dhcp: Bool? = nil, activated: Bool? = nil,
                model: String? = nil, serialNumber: String? = nil, httpPort: Int? = nil) {
        self.mac = mac
        self.ipv4Address = ipv4Address
        self.subnetMask = subnetMask
        self.gateway = gateway
        self.dhcp = dhcp
        self.activated = activated
        self.model = model
        self.serialNumber = serialNumber
        self.httpPort = httpPort
    }

    /// Whether `ipv4Address` is on one of `networks` (each an IPv4 address with its prefix length, the bridge's own): false for an address
    /// that is not IPv4 or a network whose prefix is unknown or out of range.
    public func isOnNetwork(of networks: [(address: String, prefixLength: Int?)]) -> Bool {
        guard let camera = SADPDiscovery.ipv4Bytes(ipv4Address) else { return false }
        return networks.contains { network in
            guard let bits = network.prefixLength, (1...32).contains(bits), let own = SADPDiscovery.ipv4Bytes(network.address) else { return false }
            let mask: UInt32 = bits == 32 ? .max : ~(UInt32.max >> UInt32(bits))
            return camera & mask == own & mask
        }
    }
}

/// SADP over UDP multicast (portable; the socket is `MulticastProbe`'s, as WS-Discovery's): an inquiry `Probe` sent to
/// 239.255.255.250:37020, the group's own port bound so the devices' answers to the group are heard, then their `ProbeMatch`es collected
/// until the timeout. Nothing is written to a camera; no login is sent.
public enum SADPDiscovery {
    static let multicastGroup = "239.255.255.250"
    static let port: UInt16 = 37020
    private static let log = Log(category: "discovery")

    public static func discover(timeout: Duration = .seconds(3)) async -> [SADPDevice] {
        let probe = probeMessage(uuid: UUID().uuidString.uppercased())
        let datagrams: [(data: Data, sender: String?)] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: MulticastProbe.run(probe: probe, group: multicastGroup, port: port, timeout: timeout, bindPort: port,
                                                                  label: "SADP"))
            }
        }
        let devices = merge(datagrams.compactMap { parseReply($0.data) })
        log.info("SADP found \(devices.count) device(s)")
        return devices
    }

    /// The inquiry: `<Probe><Uuid>…</Uuid><Types>inquiry</Types></Probe>`.
    static func probeMessage(uuid: String) -> Data {
        Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><Probe><Uuid>\(XMLTree.escape(uuid))</Uuid><Types>inquiry</Types></Probe>".utf8)
    }

    /// One device's answer (a `ProbeMatch` with its `MAC` and `IPv4Address`); nil for anything else: a probe (the bridge's own, or another
    /// searcher's), an answer without an address, text that is not XML.
    static func parseReply(_ data: Data) -> SADPDevice? {
        guard let tree = try? XMLTree.parse(data), tree.matches("ProbeMatch") else { return nil }
        func text(_ name: String) -> String? {
            let value = tree.string(name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        func flag(_ name: String) -> Bool? {
            switch text(name)?.lowercased() {
            case "true", "1": true
            case "false", "0": false
            default: nil
            }
        }
        guard let mac = text("MAC").map(normalizedMAC), !mac.isEmpty, let address = text("IPv4Address"), ipv4Bytes(address) != nil else { return nil }
        return SADPDevice(mac: mac, ipv4Address: address, subnetMask: text("IPv4SubnetMask"), gateway: text("IPv4Gateway"), dhcp: flag("DHCP"),
                          activated: flag("Activated"), model: text("DeviceDescription"), serialNumber: text("DeviceSN"),
                          httpPort: text("HttpPort").flatMap { Int($0) }.flatMap { (1...65535).contains($0) ? $0 : nil })
    }

    /// "AA-BB-CC-DD-EE-FF" → "aa:bb:cc:dd:ee:ff".
    static func normalizedMAC(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    /// One entry per MAC (a device answers on every interface the probe went out of), the first answer kept.
    static func merge(_ devices: [SADPDevice]) -> [SADPDevice] {
        var seen: Set<String> = []
        return devices.filter { seen.insert($0.mac).inserted }
    }

    /// A dotted IPv4 address as a 32-bit number; nil for anything else.
    static func ipv4Bytes(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }
}
