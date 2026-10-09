#if os(macOS)
import BridgeSupport
import Foundation
import Security

/// `SecretStore` over generic-password items in the file-based (login) keychain: `kSecAttrService` = `service`,
/// `kSecAttrAccount` = the account (e.g. `camera.<uuid>`, `hap.<uuid>`). The data-protection keychain is not used
/// because it requires a provisioning profile (-34018 in ad-hoc builds).
public final class KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "com.coreysilvia.CameraBridge") {
        self.service = service
    }

    public func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecInternalError) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func write(_ data: Data?, account: String) throws {
        guard let data else {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        if try update(data, account: account) { return }
        var item = baseQuery(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "CameraBridge (\(account))"
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, try update(data, account: account) { return }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// False if the item does not exist yet.
    private func update(_ data: Data, account: String) throws -> Bool {
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw KeychainError(status: status)
        }
    }

    func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

/// A Security framework status other than success / not found. Readable (`LocalizedError`): adding or editing a
/// camera stores its password, so the app may show this in an alert.
public struct KeychainError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var description: String {
        "Keychain error \(status): \(message)"
    }

    public var errorDescription: String? {
        "The keychain couldn’t store or read the password (\(message.trimmingCharacters(in: CharacterSet(charactersIn: "."))), error \(status))."
    }

    private var message: String {
        SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
    }
}
#endif
