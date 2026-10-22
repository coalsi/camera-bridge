import BridgeEngine
import Crypto
import Foundation

/// The box's Ed25519 key pair for the Camera Bridge website (`SecureAddressService`). The private key (its 32-byte seed) lives in the
/// secret store as `plugin.box-identity` and in nothing else: not `config.json`, logs, answers of the web API or the state file.
struct BoxIdentity: Sendable {
    static let secretID = "box-identity"
    let key: Curve25519.Signing.PrivateKey

    init(key: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()) { self.key = key }

    /// The stored identity, or nil when none is stored (or it is damaged).
    static func load(from backend: any BridgeBackend) async throws -> BoxIdentity? {
        guard let data = try await backend.pluginSecret(id: secretID), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { return nil }
        return BoxIdentity(key: key)
    }

    func store(in backend: any BridgeBackend) async throws {
        try await backend.setPluginSecret(id: Self.secretID, key.rawRepresentation)
    }

    /// Base64 of the raw 32-byte public key: what `register` takes.
    var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }

    /// The private key as PKCS#8 PEM, for the root helper's `openssl` to sign with (it goes to the root-only job folder and is removed
    /// when the job ends).
    var privateKeyPEM: String {
        let der = Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]) + key.rawRepresentation
        let base64 = der.base64EncodedString()
        return "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----\n"
    }
}
