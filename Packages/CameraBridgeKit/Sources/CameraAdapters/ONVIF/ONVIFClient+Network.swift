import BridgeSupport
import Foundation

/// The camera's DNS servers as ONVIF's `GetDNS` reports them.
struct ONVIFDNSSettings: Sendable, Equatable {
    var fromDHCP: Bool
    var searchDomains: [String]
    /// What DHCP gave (`DNSFromDHCP`).
    var dhcpServers: [String]
    /// The servers set by hand (`DNSManual`): IPv4 or IPv6 addresses.
    var manualServers: [String]

    /// The servers the camera uses: DHCP's when it takes them from DHCP, else the ones set by hand.
    var servers: [String] { fromDHCP ? dhcpServers : manualServers }
}

/// The camera's default gateways (`GetNetworkDefaultGateway`).
struct ONVIFDefaultGateway: Sendable, Equatable {
    var ipv4: [String]
    var ipv6: [String]
}

/// An address with its prefix length (`tt:PrefixedIPv4Address` / `tt:PrefixedIPv6Address`).
struct ONVIFPrefixedAddress: Sendable, Equatable {
    var address: String
    var prefixLength: Int?
}

/// One network interface as `GetNetworkInterfaces` reports it. Its hardware (MAC) address is not kept.
struct ONVIFNetworkInterface: Sendable, Equatable {
    var token: String
    var enabled: Bool
    var name: String?
    var mtu: Int?
    var ipv4Enabled: Bool
    /// The IPv4 address comes from DHCP.
    var ipv4DHCP: Bool
    var ipv4Manual: [ONVIFPrefixedAddress]
    var ipv4FromDHCP: ONVIFPrefixedAddress?
    var ipv4LinkLocal: ONVIFPrefixedAddress?
    /// nil when the camera reports no IPv6 section.
    var ipv6Enabled: Bool?
    /// "Auto", "Stateful", "Stateless" or "Off".
    var ipv6DHCP: String?
    /// Set by hand, from DHCP and from router advertisements (link-local ones left out).
    var ipv6Addresses: [ONVIFPrefixedAddress]

    /// The IPv4 address in use: DHCP's when DHCP is on, else the first one set by hand.
    var ipv4Address: ONVIFPrefixedAddress? {
        guard ipv4Enabled else { return nil }
        return ipv4DHCP ? ipv4FromDHCP ?? ipv4Manual.first : ipv4Manual.first
    }
}

/// ONVIF device service: the camera's DNS servers (`GetDNS` / `SetDNS`), and its gateway and network interfaces, read only for now (the
/// internet guard's Seal will set them).
extension ONVIFClient {
    func dns() async throws -> ONVIFDNSSettings {
        let envelope = try await call(deviceServiceURL, body: "<tds:GetDNS/>", action: "http://www.onvif.org/ver10/device/wsdl/GetDNS")
        return Self.parseDNS(try responseBody(envelope, "GetDNSResponse"))
    }

    static func parseDNS(_ body: XMLTree) -> ONVIFDNSSettings {
        let information = body.firstDescendant("DNSInformation") ?? body
        let fromDHCP = information.child("FromDHCP").flatMap { ONVIFNotification.parseBool($0.text) } ?? false
        let search = information.children("SearchDomain").map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return ONVIFDNSSettings(fromDHCP: fromDHCP, searchDomains: search, dhcpServers: addresses(information.children("DNSFromDHCP")),
                                manualServers: addresses(information.children("DNSManual")))
    }

    /// `SetDNS`: each server as an IPv4 or IPv6 address (`DNSManual`), with the search domains (the camera may clear them when they are left
    /// out). Throws `.unsupported` for a server that is not an address, before anything is sent.
    func setDNS(fromDHCP: Bool, servers: [String], searchDomains: [String] = []) async throws {
        var body = "<tds:SetDNS><tds:FromDHCP>\(fromDHCP)</tds:FromDHCP>"
        for domain in searchDomains { body += "<tds:SearchDomain>\(XMLTree.escape(domain))</tds:SearchDomain>" }
        for server in servers {
            if Self.isIPv4(server) {
                body += "<tds:DNSManual><tt:Type>IPv4</tt:Type><tt:IPv4Address>\(server)</tt:IPv4Address></tds:DNSManual>"
            } else if Self.isIPv6(server) {
                body += "<tds:DNSManual><tt:Type>IPv6</tt:Type><tt:IPv6Address>\(server)</tt:IPv6Address></tds:DNSManual>"
            } else {
                throw CameraAdapterError.unsupported("a DNS server is an IPv4 or IPv6 address")
            }
        }
        body += "</tds:SetDNS>"
        _ = try await call(deviceServiceURL, body: body, action: "http://www.onvif.org/ver10/device/wsdl/SetDNS")
    }

    func defaultGateway() async throws -> ONVIFDefaultGateway {
        let envelope = try await call(deviceServiceURL, body: "<tds:GetNetworkDefaultGateway/>",
                                      action: "http://www.onvif.org/ver10/device/wsdl/GetNetworkDefaultGateway")
        return Self.parseDefaultGateway(try responseBody(envelope, "GetNetworkDefaultGatewayResponse"))
    }

    static func parseDefaultGateway(_ body: XMLTree) -> ONVIFDefaultGateway {
        let gateway = body.firstDescendant("NetworkGateway") ?? body
        func texts(_ name: String) -> [String] {
            gateway.children(name).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return ONVIFDefaultGateway(ipv4: texts("IPv4Address"), ipv6: texts("IPv6Address"))
    }

    func networkInterfaces() async throws -> [ONVIFNetworkInterface] {
        let envelope = try await call(deviceServiceURL, body: "<tds:GetNetworkInterfaces/>",
                                      action: "http://www.onvif.org/ver10/device/wsdl/GetNetworkInterfaces")
        return Self.parseNetworkInterfaces(try responseBody(envelope, "GetNetworkInterfacesResponse"))
    }

    static func parseNetworkInterfaces(_ body: XMLTree) -> [ONVIFNetworkInterface] {
        func flag(_ node: XMLTree?, _ name: String) -> Bool? { node?.child(name).flatMap { ONVIFNotification.parseBool($0.text) } }
        func prefixed(_ node: XMLTree) -> ONVIFPrefixedAddress? {
            let address = node.string("Address")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !address.isEmpty else { return nil }
            return ONVIFPrefixedAddress(address: address, prefixLength: node.string("PrefixLength").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        }
        return body.children("NetworkInterfaces").map { entry in
            let ipv4 = entry.child("IPv4"), config4 = ipv4?.child("Config")
            let ipv6 = entry.child("IPv6"), config6 = ipv6?.child("Config")
            let name = entry.string("Info", "Name")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let ipv6Addresses = ["Manual", "FromDHCP", "FromRA"].flatMap { config6?.children($0) ?? [] }.compactMap(prefixed)
            return ONVIFNetworkInterface(
                token: entry.attribute("token") ?? "", enabled: flag(entry, "Enabled") ?? false, name: name?.isEmpty == false ? name : nil,
                mtu: entry.string("Info", "MTU").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
                ipv4Enabled: flag(ipv4, "Enabled") ?? false, ipv4DHCP: flag(config4, "DHCP") ?? false,
                ipv4Manual: (config4?.children("Manual") ?? []).compactMap(prefixed), ipv4FromDHCP: config4?.child("FromDHCP").flatMap(prefixed),
                ipv4LinkLocal: config4?.child("LinkLocal").flatMap(prefixed), ipv6Enabled: flag(ipv6, "Enabled"),
                ipv6DHCP: config6?.string("DHCP")?.trimmingCharacters(in: .whitespacesAndNewlines), ipv6Addresses: ipv6Addresses)
        }
    }

    /// The addresses of `tt:IPAddress` entries (`DNSManual`, `DNSFromDHCP`), empty ones left out.
    private static func addresses(_ entries: [XMLTree]) -> [String] {
        entries.compactMap { entry in
            let value = (entry.string("IPv4Address") ?? entry.string("IPv6Address"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
    }

    static func isIPv6(_ text: String) -> Bool { ipv6Groups(text) != nil }

    /// An IPv6 address's eight 16-bit groups ("::" expanded, a trailing IPv4 part as two groups); nil when `text` is not one (zone IDs
    /// such as `%eth0` are not taken).
    static func ipv6Groups(_ text: String) -> [UInt16]? {
        guard text.contains(":"), text.count <= 45 else { return nil }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        var sides: [[UInt16]] = []
        for (index, half) in halves.enumerated() {
            var groups: [UInt16] = []
            let parts = half.isEmpty ? [] : half.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            for (position, part) in parts.enumerated() {
                if position == parts.count - 1, index == halves.count - 1, part.contains(".") {
                    guard isIPv4(part) else { return nil }
                    let bytes = part.split(separator: ".").compactMap { UInt16($0) }
                    groups += [bytes[0] << 8 | bytes[1], bytes[2] << 8 | bytes[3]]
                    continue
                }
                guard (1...4).contains(part.count), part.allSatisfy(\.isHexDigit), let value = UInt16(part, radix: 16) else { return nil }
                groups.append(value)
            }
            sides.append(groups)
        }
        let count = sides.reduce(0) { $0 + $1.count }
        if sides.count == 1 { return count == 8 ? sides[0] : nil }
        guard count < 8 else { return nil }
        return sides[0] + Array(repeating: 0, count: 8 - count) + sides[1]
    }

    /// Two server addresses are the same: IPv6 ones compared group by group (any case, "::" or not), others as written.
    static func sameAddress(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines), b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if let left = ipv6Groups(a), let right = ipv6Groups(b) { return left == right }
        return a == b
    }
}
