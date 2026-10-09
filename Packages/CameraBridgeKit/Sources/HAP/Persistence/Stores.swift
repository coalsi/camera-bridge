import BridgeSupport
import Foundation
import HAPCore
import Synchronization

public struct Pairing: Sendable, Codable, Hashable {
    public var identifier: String
    public var publicKey: Data
    public var isAdmin: Bool

    public init(identifier: String, publicKey: Data, isAdmin: Bool) {
        self.identifier = identifier
        self.publicKey = publicKey
        self.isAdmin = isAdmin
    }
}

public struct HAPIdentity: Sendable, Codable {
    public var deviceID: DeviceID
    /// Ed25519 raw private key.
    public var longTermKey: Data
    public var setupCode: SetupCode
    public var setupID: String

    public init(deviceID: DeviceID, longTermKey: Data, setupCode: SetupCode, setupID: String) {
        self.deviceID = deviceID
        self.longTermKey = longTermKey
        self.setupCode = setupCode
        self.setupID = setupID
    }

    /// Random device ID, new Ed25519 key, non-trivial setup code and random setup ID.
    public static func generate() -> HAPIdentity {
        HAPIdentity(deviceID: .random(), longTermKey: HAPLongTermKey().rawRepresentation, setupCode: .random(),
                    setupID: SetupPayload.randomSetupID())
    }
}

public struct HAPPersistentState: Sendable, Codable {
    public var pairings: [Pairing]
    public var configNumber: UInt32
    public var configHash: String
    public var iids: [String: UInt64]
    public var nextIID: UInt64
    public var aids: [String: UInt64]
    public var nextAID: UInt64
    /// For controllers (e.g. selected recording configuration).
    public var extras: [String: Data]

    /// Unpaired, c# 1, iids from 2 (AccessoryInformation is 1), bridged aids from 2.
    public init() {
        pairings = []
        configNumber = 1
        configHash = ""
        iids = [:]
        nextIID = 2
        aids = [:]
        nextAID = 2
        extras = [:]
    }
}

public protocol HAPStore: Sendable {
    func loadIdentity() throws -> HAPIdentity?
    func saveIdentity(_ identity: HAPIdentity) throws
    func loadState() throws -> HAPPersistentState?
    func saveState(_ state: HAPPersistentState) throws
    func deleteAll() throws
    /// Names the identity this store holds for `loadOrCreateIdentity()` and `replaceIdentity()`, which change it under a
    /// process-wide lock per name: two stores over the same identity (the engine's and the accessory server's, both
    /// `FileHAPStore`s over one Keychain account) never both create one, where the Keychain would keep only the last.
    /// Default `""`: every store without a name of its own shares one lock. `FileHAPStore`: its secret store account.
    var identityLockName: String { get }
}

/// Process-wide locks for identity creation, one per `HAPStore.identityLockName`.
enum HAPIdentityLocks {
    private final class Lock: Sendable {
        let mutex = Mutex(())
    }

    private static let locks = Mutex<[String: Lock]>([:])

    static func withLock<T: Sendable>(_ name: String, _ body: () throws -> T) throws -> T {
        let lock = locks.withLock { locks in
            if let existing = locks[name] { return existing }
            let created = Lock()
            locks[name] = created
            return created
        }
        return try lock.mutex.withLock { _ in try body() }
    }
}

extension HAPStore {
    public var identityLockName: String { "" }

    /// The stored identity, or a new one (saved before it is returned) when none is stored.
    ///
    /// Pairings found without their identity belonged to the lost one (a reset or lost Keychain, a data directory
    /// restored without it): controllers know only its device ID and key, so they could never verify again, and the
    /// accessory would advertise itself as paired (`sf=0`) and refuse pair-setup. They are removed from the state, before
    /// the new identity is saved, so a failure in between never leaves a new identity next to them; the rest of the state
    /// (identifiers, `c#`, extras) stays. Research brief §4 ("Keys missing"): the accessory must then be removed from the
    /// Home app and added again. `discardedPairings` counts the removed pairings (0 normally).
    ///
    /// Runs under the process-wide lock of `identityLockName`: when the identity is missing, another store over the same
    /// one (the engine reading a setup code while the camera's accessory server starts) finds the identity this call
    /// created instead of making a second one (the secret store keeps only the last write).
    public func loadOrCreateIdentity() throws -> (identity: HAPIdentity, created: Bool, discardedPairings: Int) {
        try HAPIdentityLocks.withLock(identityLockName) {
            if let stored = try loadIdentity() { return (stored, false, 0) }
            var discarded = 0
            if var state = try loadState(), !state.pairings.isEmpty {
                discarded = state.pairings.count
                state.pairings = []
                try saveState(state)
            }
            let identity = HAPIdentity.generate()
            try saveIdentity(identity)
            return (identity, true, discarded)
        }
    }

    /// Replaces the identity with a new one (device ID, long-term key, setup code and setup ID: to controllers a new
    /// accessory) and removes every pairing (Reset Pairing: a setup code that was shared or seen pairs nothing
    /// afterwards). The pairings go first, so a failure in between never leaves them next to the new identity; the rest
    /// of the state (identifiers, `c#`, extras) stays. Under the same lock as `loadOrCreateIdentity()`.
    @discardableResult
    public func replaceIdentity() throws -> HAPIdentity {
        try HAPIdentityLocks.withLock(identityLockName) {
            if var state = try loadState(), !state.pairings.isEmpty {
                state.pairings = []
                try saveState(state)
            }
            let identity = HAPIdentity.generate()
            try saveIdentity(identity)
            return identity
        }
    }
}

/// Compatibility alias: the secret store protocol lives in BridgeSupport (`SecretStore`), as does `InMemorySecretStore`.
public typealias HAPSecretStore = SecretStore

/// Process-local store (tests, previews).
public final class InMemoryHAPStore: HAPStore {
    private let contents = Mutex<(identity: HAPIdentity?, state: HAPPersistentState?)>((nil, nil))

    public init() {}

    public func loadIdentity() throws -> HAPIdentity? { contents.withLock { $0.identity } }
    public func saveIdentity(_ identity: HAPIdentity) throws { contents.withLock { $0.identity = identity } }
    public func loadState() throws -> HAPPersistentState? { contents.withLock { $0.state } }
    public func saveState(_ state: HAPPersistentState) throws { contents.withLock { $0.state = state } }
    public func deleteAll() throws { contents.withLock { $0 = (nil, nil) } }
}

public enum HAPStoreError: Error, Equatable, Sendable {
    case writeFailed(String)
}

/// The identity each secret store account last held in this process, so a Keychain that refuses a read (locked, busy,
/// `errSecInteractionNotAllowed` right after wake or login) does not take an accessory down: the accessory keeps the
/// identity it already had. Written by every successful read and save, cleared by `deleteAll`.
enum HAPIdentityCache {
    private static let identities = Mutex<[String: HAPIdentity]>([:])

    static func identity(for name: String) -> HAPIdentity? { identities.withLock { $0[name] } }
    static func remember(_ identity: HAPIdentity, for name: String) { identities.withLock { $0[name] = identity } }
    static func forget(_ name: String) { identities.withLock { $0[name] = nil } }
}

/// Pairings/state as `state.json` (0600) in `directory` (created 0700; an existing one is left as it is — BridgeSupport
/// `PrivateFiles`, the same policy as the engine's configuration); the identity (device ID, setup code and the Ed25519
/// long-term key) as JSON in the `SecretStore` under `account` — the Keychain in the app. Writes are atomic.
public final class FileHAPStore: HAPStore {
    private let directory: URL
    private let secretStore: any SecretStore
    private let account: String
    private let lock = Mutex(())

    /// JSON files in `directory` (0700/0600). `secretStore` (BridgeSupport.SecretStore) holds the identity incl. the
    /// long-term key under `account` (e.g. `hap.<uuid>`) — the Keychain in the app.
    public init(directory: URL, secretStore: any SecretStore, account: String) {
        self.directory = directory
        self.secretStore = secretStore
        self.account = account
    }

    private var stateURL: URL { directory.appending(path: "state.json", directoryHint: .notDirectory) }

    /// Every `FileHAPStore` over the same secret store account shares one identity lock.
    public var identityLockName: String { "FileHAPStore.\(account)" }

    /// Reads the Keychain item; when the Keychain refuses (a locked or busy keychain: not "item not found"), the identity this
    /// process read or saved before is used instead, and the refusal is logged once per account until a read works again.
    public func loadIdentity() throws -> HAPIdentity? {
        let data: Data?
        do {
            data = try secretStore.read(account: account)
        } catch {
            guard let remembered = HAPIdentityCache.identity(for: identityLockName) else { throw error }
            if HAPIdentityReadFailures.noteFailure(identityLockName) {
                Log(category: "hap").warning("The HomeKit identity of \(account) could not be read (\(error)); using the one this app already had")
            }
            return remembered
        }
        HAPIdentityReadFailures.noteSuccess(identityLockName)
        guard let data else { return nil }
        let identity = try JSONDecoder().decode(HAPIdentity.self, from: data)
        HAPIdentityCache.remember(identity, for: identityLockName)
        return identity
    }

    public func saveIdentity(_ identity: HAPIdentity) throws {
        try secretStore.write(try JSONEncoder().encode(identity), account: account)
        HAPIdentityCache.remember(identity, for: identityLockName)
    }

    public func loadState() throws -> HAPPersistentState? {
        try lock.withLock { _ in
            let path = stateURL.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return try JSONDecoder().decode(HAPPersistentState.self, from: Data(contentsOf: stateURL))
        }
    }

    public func saveState(_ state: HAPPersistentState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try lock.withLock { _ in
            do {
                try PrivateFiles.prepareDirectory(directory)
                try PrivateFiles.write(data, to: stateURL)
            } catch PrivateFiles.Failure.createFailed(let name) {
                throw HAPStoreError.writeFailed(name)
            }
        }
    }

    public func deleteAll() throws {
        try lock.withLock { _ in
            let path = stateURL.path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        }
        try secretStore.write(nil, account: account)
        HAPIdentityCache.forget(identityLockName)
    }
}

/// Logs a refused identity read once until a read works again (an accessory restarts a few times while the keychain is locked).
enum HAPIdentityReadFailures {
    private static let failing = Mutex<Set<String>>([])

    /// True the first time since the last success.
    static func noteFailure(_ name: String) -> Bool { failing.withLock { $0.insert(name).inserted } }
    static func noteSuccess(_ name: String) { failing.withLock { _ = $0.remove(name) } }
}
