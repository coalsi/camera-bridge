import BridgeSupport
import Foundation

/// A device that can use Away from home: a phone with the Camera Bridge app (its key is made on the phone) or a WireGuard-app device (its key
/// is made here and handed over once). The private key of the second kind is not kept.
struct AwayDevice: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case app, wireguard }
    var id: String
    var kind: Kind
    var name: String
    var publicKey: String
    var address: String
    var created: Date
    /// The last time the tunnel saw this device handshake from away.
    var lastAwayAt: Date?
}

/// What the daemon keeps about Away from home (`away.json`). It is read leniently: a file from an older version lacks keys, and each missing one
/// takes its default.
struct AwayState: Codable, Equatable, Sendable {
    struct AddressChange: Codable, Equatable, Sendable {
        var at: Date
        var address: String
    }

    var on = false
    var subnet: String?
    var devices: [AwayDevice] = []
    /// The away name the website gave the box; it stays when Away from home is turned off.
    var name: String?
    var lastAddress: String?
    var addressChangedAt: Date?
    /// At most 50, the oldest first.
    var changes: [AddressChange] = []
    var publishedAddress: String?
    var publishedAt: Date?
    var withdrawPending = false
    var websiteFailures = 0
    var websiteWaitUntil: Date?
    var applyPending = false
    var applyError: String?

    static let fileName = "away.json"

    init() {}

    /// Every field uses `decodeIfPresent`: a synthesized decoder throws on a missing key even when the property has a default.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? false
        subnet = try c.decodeIfPresent(String.self, forKey: .subnet)
        devices = try c.decodeIfPresent([AwayDevice].self, forKey: .devices) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name)
        lastAddress = try c.decodeIfPresent(String.self, forKey: .lastAddress)
        addressChangedAt = try c.decodeIfPresent(Date.self, forKey: .addressChangedAt)
        changes = try c.decodeIfPresent([AddressChange].self, forKey: .changes) ?? []
        publishedAddress = try c.decodeIfPresent(String.self, forKey: .publishedAddress)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        withdrawPending = try c.decodeIfPresent(Bool.self, forKey: .withdrawPending) ?? false
        websiteFailures = try c.decodeIfPresent(Int.self, forKey: .websiteFailures) ?? 0
        websiteWaitUntil = try c.decodeIfPresent(Date.self, forKey: .websiteWaitUntil)
        applyPending = try c.decodeIfPresent(Bool.self, forKey: .applyPending) ?? false
        applyError = try c.decodeIfPresent(String.self, forKey: .applyError)
    }

    /// The state in `directory`. A missing file is the default (off). A file that is there but can't be read (its permissions, a disk error) or
    /// doesn't decode is moved to `away.json.unreadable`, so it is kept for a look and the next save never writes over its devices and away
    /// name, and Away from home is off.
    static func load(from directory: URL) -> AwayState {
        let file = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return AwayState() }
        if let data = try? Data(contentsOf: file), let state = try? JSONDecoder.iso.decode(AwayState.self, from: data) { return state }
        let moved = directory.appendingPathComponent(fileName + ".unreadable")
        try? FileManager.default.removeItem(at: moved)
        try? FileManager.default.moveItem(at: file, to: moved)
        return AwayState()
    }

    /// Writes the state, 0600 with sorted keys. False when it could not be written, so a caller that must not lose a change can say so.
    @discardableResult
    func save(to directory: URL) -> Bool {
        guard let data = try? JSONEncoder.iso.encode(self) else { return false }
        return (try? PrivateFiles.write(data, to: directory.appendingPathComponent(Self.fileName))) != nil
    }
}
