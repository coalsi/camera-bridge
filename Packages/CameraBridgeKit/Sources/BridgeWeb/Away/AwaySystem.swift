import Foundation

/// The `away-set` request: what the daemon asks the system's `cb-away` to keep (docs/superpowers/specs/2026-11-12-away-from-home-design.md,
/// "Daemon → root"). Every key is always written (`subnet` as `null` when there is none), sorted: `{"on","peers","port","subnet"}`.
public struct AwayRequest: Codable, Sendable, Equatable {
    public struct Peer: Codable, Sendable, Equatable, Hashable {
        public var publicKey: String
        public var address: String

        public init(publicKey: String, address: String) {
            self.publicKey = publicKey
            self.address = address
        }
    }

    /// The one UDP port Away from home listens on.
    public static let port = 51820
    /// At most this many devices; the system checks it again.
    public static let maximumPeers = 64

    public var on: Bool
    public var port: Int
    public var subnet: String?
    public var peers: [Peer]

    /// The port is always `AwayRequest.port`.
    public init(on: Bool, subnet: String?, peers: [Peer]) {
        self.on = on
        port = Self.port
        self.subnet = subnet
        self.peers = peers
    }

    private enum CodingKeys: String, CodingKey { case on, port, subnet, peers }

    /// A synthesized encoder leaves `subnet` out when there is none; the interface has every key, with `null` for an absent value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(on, forKey: .on)
        try container.encode(port, forKey: .port)
        try container.encode(subnet, forKey: .subnet)
        try container.encode(peers, forKey: .peers)
    }

    /// `cb-away`'s rules (it checks the same again as root) as a sentence; nil when the request is off or fine. The octets are written
    /// plainly (no leading zeros), the subnet is a /24 inside 10.0.0.0/8 that is none of the networks the box or its setup use, and every
    /// device is a key and a distinct address from .2 to .254 in that subnet.
    public var problem: String? {
        guard on else { return nil }
        guard port == Self.port else { return "The port must be \(Self.port)." }
        guard let subnet, let network = Self.network(of: subnet) else { return "Away from home needs a network of its own inside 10.0.0.0/8." }
        guard ![0, 1, 10, 42, 255].contains(network.a) else { return "That network is one the box already uses." }
        guard peers.count <= Self.maximumPeers else { return "At most \(Self.maximumPeers) devices can use Away from home." }
        var keys = Set<String>(), addresses = Set<String>()
        for peer in peers {
            guard Self.isPublicKey(peer.publicKey) else { return "A device’s key isn’t a WireGuard key." }
            guard let address = Self.address(of: peer.address), address.a == network.a, address.b == network.b, (2...254).contains(address.n) else {
                return "A device’s address isn’t one of the network’s .2 to .254."
            }
            guard keys.insert(peer.publicKey).inserted else { return "A device is listed twice." }
            guard addresses.insert(peer.address).inserted else { return "Two devices have one address." }
        }
        return nil
    }

    /// Base64 of exactly 32 bytes, written the one way base64 writes them (43 characters and a `=` whose last digit holds no stray bits).
    public static func isPublicKey(_ text: String) -> Bool {
        guard text.utf8.count == 44, let data = Data(base64Encoded: text), data.count == 32 else { return false }
        return data.base64EncodedString() == text
    }

    private static func octet(_ text: Substring) -> Int? {
        guard (1...3).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }), text.count == 1 || text.first != "0", let value = Int(text), value <= 255 else { return nil }
        return value
    }

    private static func network(of text: String) -> (a: Int, b: Int)? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "10", parts[3] == "0/24", let a = octet(parts[1]), let b = octet(parts[2]) else { return nil }
        return (a, b)
    }

    private static func address(of text: String) -> (a: Int, b: Int, n: Int)? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "10", let a = octet(parts[1]), let b = octet(parts[2]), let n = octet(parts[3]) else { return nil }
        return (a, b, n)
    }
}

/// What the system says about Away from home (`status/away.json`), cleaned: an unknown state reads as `failed`, a message is one line
/// without control characters, and a missing list of devices is empty.
public struct AwayStatus: Codable, Sendable, Equatable {
    public struct Peer: Codable, Sendable, Equatable {
        public var publicKey: String
        /// Epoch seconds; 0 is never.
        public var latestHandshake: Int
        /// The device's address as the tunnel last saw it, without brackets and port.
        public var endpoint: String?

        public init(publicKey: String, latestHandshake: Int, endpoint: String?) {
            self.publicKey = publicKey
            self.latestHandshake = latestHandshake
            self.endpoint = endpoint
        }
    }

    /// `ok`, `failed` or `off`.
    public var state: String
    public var message: String?
    /// The box's WireGuard public key, once it has one.
    public var publicKey: String?
    public var port: Int
    /// `eero` when the home's router is one, which does not forward a port from outside.
    public var router: String?
    public var peers: [Peer]
    /// Epoch seconds.
    public var updated: Int

    public init(state: String, message: String?, publicKey: String?, port: Int, router: String?, peers: [Peer], updated: Int) {
        self.state = state
        self.message = message
        self.publicKey = publicKey
        self.port = port
        self.router = router
        self.peers = peers
        self.updated = updated
    }

    /// Away from home is off (also what a system with the helper but no status file yet is).
    public static let off = AwayStatus(state: "off", message: nil, publicKey: nil, port: AwayRequest.port, router: nil, peers: [], updated: 0)
}
