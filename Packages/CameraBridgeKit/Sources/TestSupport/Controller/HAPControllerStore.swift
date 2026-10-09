import Foundation

/// Where a controller keeps its identity and pairings on disk (`cbctl`: `~/.cbctl/`, or `$CBCTL_HOME`).
///
/// - `controller.json`: the controller identity (pairing ID + Ed25519 private key) — secret.
/// - `accessories.json`: paired accessories (host, port, accessory pairing ID and public key), most recent last.
///
/// The store creates its directory 0700 and writes both files 0600. An existing directory is used as is only when no
/// other user can access it (its permissions are never changed: `--home ~/Shared` must not silently tighten a shared
/// folder, and no secret is written into one). Nothing here is ever printed or logged.
public struct HAPControllerStore: Sendable {
    public struct StoredAccessory: Sendable, Codable, Hashable {
        public var host: String
        public var port: UInt16
        public var pairing: HAPAccessoryPairing
        public var name: String?
        public var pairedAt: Date

        public init(host: String, port: UInt16, pairing: HAPAccessoryPairing, name: String? = nil, pairedAt: Date = Date()) {
            self.host = host
            self.port = port
            self.pairing = pairing
            self.name = name
            self.pairedAt = pairedAt
        }

        public var endpoint: String { HostPort(host: host, port: port).description }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `$CBCTL_HOME` if set, else `~/.cbctl`.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["CBCTL_HOME"], !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cbctl", directoryHint: .isDirectory)
    }

    private var identityURL: URL { directory.appending(path: "controller.json") }
    private var accessoriesURL: URL { directory.appending(path: "accessories.json") }

    // MARK: Identity

    public func loadIdentity() throws -> HAPControllerIdentity? {
        guard let data = try readIfPresent(identityURL) else { return nil }
        do {
            return try JSONDecoder().decode(HAPControllerIdentity.self, from: data)
        } catch {
            throw HAPControllerStoreError.corrupt(identityURL.lastPathComponent)
        }
    }

    /// The stored identity, or a new one (saved) on first use.
    public func loadOrCreateIdentity() throws -> HAPControllerIdentity {
        if let identity = try loadIdentity() { return identity }
        let identity = HAPControllerIdentity.generate()
        try write(try JSONEncoder().encode(identity), to: identityURL)
        return identity
    }

    // MARK: Accessories

    public func accessories() throws -> [StoredAccessory] {
        guard let data = try readIfPresent(accessoriesURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([StoredAccessory].self, from: data)
        } catch {
            throw HAPControllerStoreError.corrupt(accessoriesURL.lastPathComponent)
        }
    }

    /// Adds or replaces (same accessory ID or same host:port) and makes it the most recent.
    public func save(_ accessory: StoredAccessory) throws {
        var all = try accessories().filter {
            $0.pairing.accessoryPairingID != accessory.pairing.accessoryPairingID && !($0.host == accessory.host && $0.port == accessory.port)
        }
        all.append(accessory)
        try saveAll(all)
    }

    public func remove(accessoryPairingID: String) throws {
        try saveAll(try accessories().filter { $0.pairing.accessoryPairingID != accessoryPairingID })
    }

    /// `target` = "host:port" or an accessory ID; nil = the most recently paired accessory.
    public func accessory(matching target: String?) throws -> StoredAccessory {
        let all = try accessories()
        guard let target else {
            guard let last = all.last else { throw HAPControllerStoreError.noPairing }
            return last
        }
        if let endpoint = HostPort(parsing: target),
           let match = all.last(where: { $0.port == endpoint.port && HostPort.sameHost($0.host, endpoint.host) }) {
            return match
        }
        if let match = all.last(where: { $0.pairing.accessoryPairingID.caseInsensitiveCompare(target) == .orderedSame }) { return match }
        throw HAPControllerStoreError.unknownAccessory(target)
    }

    private func saveAll(_ accessories: [StoredAccessory]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(try encoder.encode(accessories), to: accessoriesURL)
    }

    // MARK: Files

    /// Creates the directory (0700) if it does not exist; otherwise checks that it is private (no group or other
    /// permissions) and throws `insecureDirectory` if not. Never changes an existing directory. `write` calls it; call
    /// it first to fail before doing something that must be stored afterwards.
    public func prepareDirectory() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let mode = (try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            guard mode & 0o077 == 0 else { throw HAPControllerStoreError.insecureDirectory(directory.path) }
            return
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)   // ours: created just now
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Writes atomically into the private directory, then restricts the file to 0600.
    private func write(_ data: Data, to url: URL) throws {
        try prepareDirectory()
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum HAPControllerStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case noPairing
    case unknownAccessory(String)
    case corrupt(String)
    /// An existing store directory that other users can access (it is never chmodded).
    case insecureDirectory(String)

    public var description: String {
        switch self {
        case .noPairing: "no paired accessory (run `cbctl pair <host:port> <setup-code>` first)"
        case .unknownAccessory(let target): "no stored pairing for \(target)"
        case .corrupt(let file): "\(file) is unreadable"
        case .insecureDirectory(let path): "\(path) is accessible by other users; use a private directory (chmod 700) or a new path"
        }
    }
}

/// "host:port", "[v6]:port" (IP literals or names; no scheme).
public struct HostPort: Sendable, Hashable, CustomStringConvertible {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), port > 0, !host.isEmpty else { return nil }
            self.init(host: host, port: port)
            return
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let port = UInt16(parts[1]), port > 0 else { return nil }
        self.init(host: String(parts[0]), port: port)
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    static func sameHost(_ lhs: String, _ rhs: String) -> Bool { lhs.caseInsensitiveCompare(rhs) == .orderedSame }
}
