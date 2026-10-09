import BridgeSupport
import Foundation
import HAPCore
import Synchronization
import Testing
@testable import HAP

/// Plan W1-1 item 14.
@Suite struct StoreTests {
    private func sampleState() -> HAPPersistentState {
        var state = HAPPersistentState()
        state.pairings = [Pairing(identifier: "ctrl", publicKey: Data(repeating: 1, count: 32), isAdmin: true)]
        state.configNumber = 7
        state.configHash = "abc"
        state.iids = ["85": 9]
        state.nextIID = 10
        state.aids = ["s1": 2]
        state.nextAID = 3
        state.extras = ["x": Data([1, 2])]
        return state
    }

    private func assertEqual(_ a: HAPPersistentState?, _ b: HAPPersistentState) {
        #expect(a?.pairings == b.pairings && a?.configNumber == b.configNumber && a?.configHash == b.configHash)
        #expect(a?.iids == b.iids && a?.nextIID == b.nextIID && a?.aids == b.aids && a?.nextAID == b.nextAID && a?.extras == b.extras)
    }

    /// A secret store whose reads can be made to fail like a locked Keychain (`errSecInteractionNotAllowed`).
    private final class LockableSecrets: SecretStore {
        struct Locked: Error {}
        private let inner = InMemorySecretStore()
        let locked = Mutex(false)

        func read(account: String) throws -> Data? {
            if locked.withLock({ $0 }) { throw Locked() }
            return try inner.read(account: account)
        }

        func write(_ data: Data?, account: String) throws { try inner.write(data, account: account) }
    }

    /// Hardening plan WS-C 8 (audit B6): the identity was read from the Keychain at every publish, and a locked keychain
    /// threw, which stopped the camera's whole runtime. The identity this process already had is used while the Keychain
    /// refuses; a store that never had one still fails, and deleting the identity forgets it.
    @Test func aKeychainThatRefusesTheReadFallsBackToTheIdentityTheProcessAlreadyHad() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "HAPStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = LockableSecrets()
        let account = "hap.cache-\(UUID().uuidString)"
        let store = FileHAPStore(directory: directory, secretStore: secrets, account: account)
        let identity = HAPIdentity.generate()
        try store.saveIdentity(identity)

        secrets.locked.withLock { $0 = true }
        // Another store object over the same account (the next start's) gets it too.
        let again = FileHAPStore(directory: directory, secretStore: secrets, account: account)
        #expect(try again.loadIdentity()?.deviceID == identity.deviceID)
        #expect(try again.loadOrCreateIdentity().created == false, "a refused read is not a missing identity: none is created")
        secrets.locked.withLock { $0 = false }
        #expect(try again.loadIdentity()?.deviceID == identity.deviceID)

        // Never read in this process: nothing to fall back to, the refusal is the answer.
        secrets.locked.withLock { $0 = true }
        let stranger = FileHAPStore(directory: directory, secretStore: secrets, account: "hap.never-read-\(UUID().uuidString)")
        #expect(throws: LockableSecrets.Locked.self) { try stranger.loadIdentity() }
        // Deleting forgets it.
        secrets.locked.withLock { $0 = false }
        try store.deleteAll()
        secrets.locked.withLock { $0 = true }
        #expect(throws: LockableSecrets.Locked.self) { try store.loadIdentity() }
    }

    @Test func inMemoryStoreRoundTrip() throws {
        let store = InMemoryHAPStore()
        #expect(try store.loadIdentity() == nil)
        #expect(try store.loadState() == nil)
        let identity = HAPIdentity.generate()
        try store.saveIdentity(identity)
        try store.saveState(sampleState())
        #expect(try store.loadIdentity()?.deviceID == identity.deviceID)
        assertEqual(try store.loadState(), sampleState())
        try store.deleteAll()
        #expect(try store.loadIdentity() == nil)
        #expect(try store.loadState() == nil)
    }

    @Test func fileStoreKeepsIdentityInSecretStoreAndStateInPrivateFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "HAPStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "hap/camera", directoryHint: .isDirectory)
        let secrets = InMemorySecretStore()
        let store = FileHAPStore(directory: directory, secretStore: secrets, account: "hap.test")
        #expect(try store.loadIdentity() == nil)
        #expect(try store.loadState() == nil)

        let identity = HAPIdentity.generate()
        try store.saveIdentity(identity)
        try store.saveState(sampleState())

        let secret = try #require(try secrets.read(account: "hap.test"))
        let decoded = try JSONDecoder().decode(HAPIdentity.self, from: secret)
        #expect(decoded.longTermKey == identity.longTermKey && decoded.setupCode == identity.setupCode)

        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(directoryMode == 0o700)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(files == ["state.json"])
        let stateURL = directory.appending(path: "state.json")
        let fileMode = try FileManager.default.attributesOfItem(atPath: stateURL.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        let stateText = try String(contentsOf: stateURL, encoding: .utf8)
        #expect(!stateText.contains(identity.longTermKey.base64EncodedString()))
        #expect(!stateText.contains(identity.setupCode.formatted))

        // A second store over the same directory and secret store sees the same data.
        let reopened = FileHAPStore(directory: directory, secretStore: secrets, account: "hap.test")
        #expect(try reopened.loadIdentity()?.deviceID == identity.deviceID)
        assertEqual(try reopened.loadState(), sampleState())

        var updated = sampleState()
        updated.configNumber = 8
        try reopened.saveState(updated)
        #expect(try store.loadState()?.configNumber == 8)
        let modeAfterRewrite = try FileManager.default.attributesOfItem(atPath: stateURL.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(modeAfterRewrite == 0o600)

        try store.deleteAll()
        #expect(try store.loadIdentity() == nil)
        #expect(try store.loadState() == nil)
        #expect(try secrets.read(account: "hap.test") == nil)
    }

    /// The store writes through BridgeSupport's `PrivateFiles` (one policy with the engine's configuration): every
    /// directory it creates is 0700, an existing directory is left as it is, `state.json` is always 0600.
    @Test func fileStoreSharesThePrivateFilePolicy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "HAPStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        func mode(_ url: URL) throws -> Int? {
            (try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int).map { $0 & 0o777 }
        }
        let fresh = root.appending(path: "hap/fresh", directoryHint: .isDirectory)
        try FileHAPStore(directory: fresh, secretStore: InMemorySecretStore(), account: "hap.fresh").saveState(sampleState())
        #expect(try mode(root.appending(path: "hap", directoryHint: .isDirectory)) == 0o700)
        #expect(try mode(fresh) == 0o700)

        let existing = root.appending(path: "hap/existing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o750])
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: existing.path(percentEncoded: false))
        try FileHAPStore(directory: existing, secretStore: InMemorySecretStore(), account: "hap.existing").saveState(sampleState())
        #expect(try mode(existing) == 0o750)
        #expect(try mode(existing.appending(path: "state.json")) == 0o600)
    }

    @Test func fileStoreRejectsCorruptState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "HAPStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHAPStore(directory: directory, secretStore: InMemorySecretStore(), account: "hap.corrupt")
        try store.saveState(HAPPersistentState())
        try Data("{not json".utf8).write(to: directory.appending(path: "state.json"))
        #expect(throws: (any Error).self) { try store.loadState() }
    }
}
