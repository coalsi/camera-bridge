import BridgeEngine
import Foundation

/// Away from home's pure rules: nothing here reads the network, the clock or a file, so every choice can be pinned by a test.
enum AwayRules {
    /// The one UDP port, the same constant the request to the system carries.
    static let port = AwayRequest.port
    static let mtu = 1280
    /// The WireGuard app's devices; phones that use the Camera Bridge app are counted separately, by their pairing.
    static let maximumWireGuardDevices = 20
    /// Second octets the tunnel never lands on: 0, 1 and 10 are common home networks, 42 is the setup hotspot, 255 is the broadcast end.
    static let reservedSecondOctets: Set<Int> = [0, 1, 10, 42, 255]

    // MARK: The tunnel's network

    /// A random "10.A.B.0/24". A is never reserved, and never the second octet of a 10.x address in `addresses` (the box's and the cameras'):
    /// the tunnel's /24 would take the route to a home network that shares its /16. An entry may carry a "/length" as the network reports
    /// its prefixes, so only the text after "10." up to the next "." or "/" is read.
    static func chooseSubnet(avoiding addresses: [String], using generator: inout some RandomNumberGenerator) -> String {
        var excluded = reservedSecondOctets
        for entry in addresses where entry.hasPrefix("10.") {
            let rest = entry.dropFirst(3)
            if let octet = Int(rest.prefix { $0 != "." && $0 != "/" }) { excluded.insert(octet) }
        }
        let first = (0...255).filter { !excluded.contains($0) }
        // The list is never empty in practice (256 values, less the reserved five and the few networks of a home). If it were, the fallback is a
        // reserved octet that the request's own check refuses, which is better than a crash.
        let a = first.randomElement(using: &generator) ?? 1
        return "10.\(a).\(Int.random(in: 0...255, using: &generator)).0/24"
    }

    /// "10.A.B." of a subnet written "10.A.B.0/24".
    private static func stem(_ subnet: String) -> String {
        String(subnet.split(separator: ".", omittingEmptySubsequences: false).prefix(3).joined(separator: ".")) + "."
    }

    static func boxAddress(subnet: String) -> String { stem(subnet) + "1" }

    /// The lowest address from .2 to .254 that is not in `taken`; nil when all are.
    static func nextDeviceAddress(subnet: String, taken: [String]) -> String? {
        let used = Set(taken), stem = stem(subnet)
        return (2...254).lazy.map { stem + String($0) }.first { !used.contains($0) }
    }

    // MARK: The box's own address

    /// The address to publish. Candidates are addresses the website takes (`websiteTakes`) that are neither temporary nor deprecated. The
    /// previous address wins while it is among them: two addresses whose lifetimes leapfrog (SLAAC beside DHCPv6, or the old and new prefix)
    /// would otherwise swap every few minutes and use up the website's changes. It is found by its text, since its preferred lifetime differs
    /// on every read. Otherwise the longest preferred lifetime wins (`UInt32.max` is forever), and a tie goes to the lowest address text.
    static func stableAddress(among addresses: [AwayAddress], previous: String?) -> AwayAddress? {
        let candidates = addresses.filter { candidate in
            guard !candidate.isTemporary, !candidate.isDeprecated, let bytes = StreamAddress.addressBytes(candidate.address) else { return false }
            return websiteTakes(bytes)
        }
        if let previous {
            let wanted = StreamAddress.canonical(previous)
            if let kept = candidates.first(where: { StreamAddress.canonical($0.address) == wanted }) { return kept }
        }
        return candidates.min { lhs, rhs in
            lhs.preferredLifetime != rhs.preferredLifetime ? lhs.preferredLifetime > rhs.preferredLifetime : lhs.address < rhs.address
        }
    }

    /// Whether the website takes `bytes` (an address's 16 bytes) for an away record, by the same ranges as its own check: global unicast
    /// (2000::/3) less 2001::/23 (IANA's protocol block: Teredo, benchmarking, ORCHID and the rest), 2001:db8::/32 and 3fff::/20 (both for
    /// documentation) and 2002::/16 (6to4). The website refuses any other address every time, so a box that chose one would never fall back to
    /// an address that works.
    static func websiteTakes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16, bytes[0] & 0xE0 == 0x20 else { return false }
        let first = UInt16(bytes[0]) << 8 | UInt16(bytes[1]), second = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        if first == 0x2001 && (second <= 0x01FF || second == 0x0DB8) { return false }
        if first == 0x2002 { return false }
        return !(first == 0x3FFF && second <= 0x0FFF)
    }

    // MARK: Who is away

    /// Whether a device's endpoint is outside the home: not on one of the box's own prefixes ("address/length") and not a private address.
    /// Anything that is not a bare address (nil, empty, "address:port") is not away, so a damaged reading never counts as a trip.
    static func isFromAway(_ endpoint: String?, ownPrefixes: [String]) -> Bool {
        guard let endpoint, let bytes = StreamAddress.addressBytes(endpoint) else { return false }
        if isPrivate(bytes) { return false }
        for prefix in ownPrefixes {
            let parts = prefix.split(separator: "/", maxSplits: 1)
            guard let first = parts.first, let own = StreamAddress.addressBytes(String(first)), own.count == bytes.count else { continue }
            let bits = parts.count > 1 ? Int(parts[1]) ?? own.count * 8 : own.count * 8
            if StreamAddress.samePrefix(bytes, own, bits: bits) { return false }
        }
        return true
    }

    /// The private, loopback, link-local, shared and unspecified ranges. An IPv4-mapped IPv6 address arrives as 4 bytes (`canonical` unmaps it).
    private static func isPrivate(_ b: [UInt8]) -> Bool {
        if b.count == 4 {
            return b[0] == 0 || b[0] == 10 || b[0] == 127 || (b[0] == 172 && b[1] & 0xF0 == 16) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 100 && b[1] & 0xC0 == 64) || (b[0] == 169 && b[1] == 254)
        }
        if b.dropLast().allSatisfy({ $0 == 0 }) { return b[15] <= 1 }   // :: and ::1
        return b[0] & 0xFE == 0xFC || (b[0] == 0xFE && b[1] & 0xC0 == 0x80)
    }

    // MARK: Names

    /// The website's away names only; the rule lives in BoxClient, beside the call that receives one.
    static func isAwayName(_ name: String) -> Bool { BoxClient.isAwayName(name) }

    /// A device's name as the box cleans every name: no control characters, trimmed, at most 60 characters; nil when nothing is left.
    static func cleanedName(_ text: String?) -> String? { AuthStore.cleaned(text) }

    // MARK: The card

    /// The card's state, by the first rule that fits: off (or the problem, when it is off with one), the problem, not looked at yet,
    /// no IPv6 address, no device has connected from away yet, the address changed since the last such connection, else working.
    static func cardState(on: Bool, checked: Bool, problem: String?, address: String?, lastAway: Date?, addressChangedAt: Date?) -> String {
        guard on else { return problem == nil ? "off" : "problem" }
        if problem != nil { return "problem" }
        if !checked { return "checking" }
        if address == nil { return "no_ipv6" }
        guard let lastAway else { return "setup" }
        if let addressChangedAt, addressChangedAt > lastAway { return "address_changed" }
        return "working"
    }

    // MARK: What a phone is given

    /// "[address]:51820" for the box's global IPv6 address; nil without one. The away name holds a TXT record with the address, not an address
    /// record, so a WireGuard app could not resolve it: the endpoint is always the literal address, and the name is not even asked for.
    static func endpoint(address: String?) -> String? {
        guard let address, let bytes = StreamAddress.addressBytes(address), bytes.count == 16 else { return nil }
        return "[\(StreamAddress.canonical(address))]:\(port)"
    }

    /// The WireGuard app's configuration. It has no DNS and no PersistentKeepalive: the device always starts the conversation, and a keepalive
    /// would only cost a phone's battery.
    static func wireGuardConfig(privateKey: String, address: String, boxPublicKey: String, endpoint: String, allowedIPs: [String]) -> String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(address)/32
        MTU = \(mtu)

        [Peer]
        PublicKey = \(boxPublicKey)
        AllowedIPs = \(allowedIPs.joined(separator: ", "))
        Endpoint = \(endpoint)

        """
    }
}
