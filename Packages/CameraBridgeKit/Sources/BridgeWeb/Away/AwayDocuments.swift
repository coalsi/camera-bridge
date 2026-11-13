import Foundation

// The documents Away from home answers, exactly as the spec fixes them ("Interfaces between the parts",
// docs/superpowers/specs/2026-11-12-away-from-home-design.md): the page and the iPhone app are built against these names. Every key is written,
// `null` when there is no value (a synthesized encoder would leave the key out), and dates are ISO 8601 with the encoder the routes use.

/// The Settings card's document (`GET /api/v1/away`).
struct AwayCard: Encodable, Equatable, Sendable {
    /// A device that can use Away from home, as the card lists it.
    struct Device: Encodable, Equatable, Sendable {
        /// A phone's is its pairing's id; a WireGuard-app device's is 32 random hex characters. The page removes a device by it.
        var id: String
        /// `app` (a phone with the Camera Bridge app) or `wireguard` (a device with the WireGuard app).
        var kind: String
        var name: String
        /// The tunnel's latest handshake with the device, from anywhere.
        var lastHandshake: Date?
        /// The latest handshake that came from outside the home.
        var lastAwayAt: Date?

        private enum CodingKeys: String, CodingKey { case id, kind, name, lastHandshake, lastAwayAt }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(kind, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(OrNull(lastHandshake), forKey: .lastHandshake)
            try container.encode(OrNull(lastAwayAt), forKey: .lastAwayAt)
        }
    }

    var on: Bool
    /// `off`, `checking`, `no_ipv6`, `setup`, `working`, `address_changed` or `problem` (`AwayRules.cardState`).
    var state: String
    /// What failed, in a sentence.
    var problem: String?
    var port: Int
    /// The box's global IPv6 address, the one the router step names.
    var address: String?
    /// The away name the website gave the box.
    var name: String?
    /// `eero` when the home's router is one, so the card can give that router's own steps.
    var router: String?
    var addressChangedAt: Date?
    var devices: [Device]

    private enum CodingKeys: String, CodingKey { case on, state, problem, port, address, name, router, addressChangedAt, devices }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(on, forKey: .on)
        try container.encode(state, forKey: .state)
        try container.encode(OrNull(problem), forKey: .problem)
        try container.encode(port, forKey: .port)
        try container.encode(OrNull(address), forKey: .address)
        try container.encode(OrNull(name), forKey: .name)
        try container.encode(OrNull(router), forKey: .router)
        try container.encode(OrNull(addressChangedAt), forKey: .addressChangedAt)
        try container.encode(devices, forKey: .devices)
    }
}

/// What a paired iPhone needs for its VPN (`POST` and `GET /api/v1/viewer/away`).
struct TunnelDocument: Encodable, Equatable, Sendable {
    struct Endpoint: Encodable, Equatable, Sendable {
        /// The away name, which holds a TXT record with the box's address; null until the website has given one.
        var host: String?
        var port: Int
        /// The box's global IPv6 address, the phone's fallback when the name can't be read.
        var addresses: [String]

        private enum CodingKeys: String, CodingKey { case host, port, addresses }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(OrNull(host), forKey: .host)
            try container.encode(port, forKey: .port)
            try container.encode(addresses, forKey: .addresses)
        }
    }

    var boxPublicKey: String
    var endpoint: Endpoint
    /// The phone's tunnel address, "10.a.b.N/32".
    var address: String
    /// The box's tunnel address and its home address (which the secure name points at), each "/32": all the phone sends through the tunnel.
    var routes: [String]
    var secureURL: String
    var mtu: Int
}

/// Why an Away from home call did not go through. The routes answer each with its own status and sentence.
enum AwayFailure: Error, Equatable, Sendable {
    /// This system has no Away from home (no `cb-away`, or no network to read: a development daemon or an older image).
    case unavailable
    case off
    /// The secure address has no name or no home address yet, so a phone could not reach the box by its secure name.
    case secureAddressOff
    case badKey
    /// This phone has no device key.
    case notSetUp
    case badName
    /// 20 WireGuard-app devices already, or no free address left in the tunnel's subnet.
    case tooManyDevices
    /// The box has no global IPv6 address, so a WireGuard-app device would have no endpoint.
    case noAddress
    /// The system has not reported the box's WireGuard key yet.
    case notReady
    case noSuchDevice
    /// The system did not take the change; the sentence says why. An added device or a new key is taken back. A removal is kept, and every look
    /// tries it again until the system takes it.
    case system(String)
}
