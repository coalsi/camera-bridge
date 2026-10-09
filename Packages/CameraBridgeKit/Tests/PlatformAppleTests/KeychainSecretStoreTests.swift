#if os(macOS)
import BridgeSupport
import Foundation
import Testing
@testable import PlatformApple

/// Touches the user's login keychain, so it only runs with `CB_KEYCHAIN_TESTS=1`
/// (e.g. `CB_KEYCHAIN_TESTS=1 swift test --filter KeychainSecretStoreTests`). Uses a unique throwaway service name
/// and deletes every item it creates.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CB_KEYCHAIN_TESTS"] == "1", "set CB_KEYCHAIN_TESTS=1 to use the login keychain"),
       .timeLimit(.minutes(1)))
struct KeychainSecretStoreTests {
    @Test func writesReadsOverwritesAndDeletesGenericPasswords() throws {
        let store = KeychainSecretStore(service: "com.coreysilvia.CameraBridge.tests.\(UUID().uuidString)")
        let account = "camera.\(UUID().uuidString)"
        let other = "hap.\(UUID().uuidString)"
        defer {
            try? store.write(nil, account: account)
            try? store.write(nil, account: other)
        }
        #expect(try store.read(account: account) == nil)
        try store.write(Data("first".utf8), account: account)
        #expect(try store.read(account: account) == Data("first".utf8))
        try store.write(Data("second".utf8), account: account)
        #expect(try store.read(account: account) == Data("second".utf8))
        try store.write(Data([0, 1, 2, 255]), account: other)
        #expect(try store.read(account: other) == Data([0, 1, 2, 255]))
        try store.write(nil, account: account)
        #expect(try store.read(account: account) == nil)
        try store.write(nil, account: account)   // deleting a missing item is not an error
        #expect(try store.read(account: other) == Data([0, 1, 2, 255]))
    }

    @Test func servicesAreIsolated() throws {
        let a = KeychainSecretStore(service: "com.coreysilvia.CameraBridge.tests.\(UUID().uuidString)")
        let b = KeychainSecretStore(service: "com.coreysilvia.CameraBridge.tests.\(UUID().uuidString)")
        defer { try? a.write(nil, account: "shared") }
        try a.write(Data("a".utf8), account: "shared")
        #expect(try b.read(account: "shared") == nil)
    }
}

@Suite struct KeychainQueryTests {
    @Test func queriesAreGenericPasswordsScopedToServiceAndAccount() {
        let store = KeychainSecretStore(service: "svc")
        let query = store.baseQuery(account: "camera.1")
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "svc")
        #expect(query[kSecAttrAccount as String] as? String == "camera.1")
        #expect(KeychainSecretStore().service == "com.coreysilvia.CameraBridge")
    }

    /// Keychain failures can reach an alert (adding a camera stores its password): they read as a sentence, not as a
    /// type name.
    @Test func keychainErrorsAreReadable() {
        let error: any Error = KeychainError(status: errSecInteractionNotAllowed)
        let text = (error as? any LocalizedError)?.errorDescription ?? ""
        #expect(text.hasPrefix("The keychain couldn’t store or read the password"))
        #expect(text.contains("\(errSecInteractionNotAllowed)"))
        #expect(!text.contains("KeychainError"))
    }
}
#endif
