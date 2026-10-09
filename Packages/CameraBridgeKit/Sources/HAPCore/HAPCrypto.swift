import Crypto
import Foundation

public enum HAPCryptoError: Error, Equatable, Sendable {
    case invalidKeyLength
    case invalidNonceLength
    case truncated
    case authenticationFailed
    case invalidPublicKey
}

/// HAP primitives: HKDF-SHA512, ChaCha20-Poly1305 with HAP nonces, SHA-256 (swift-crypto).
public enum HAPCrypto {
    /// The 32-byte SHA-256 digest of `data` (configuration hash `c#`, HAPCamera's recording-configuration hash).
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func hkdfSHA512(inputKey: Data, salt: String, info: String, outputByteCount: Int = 32) -> Data {
        hkdfSHA512(inputKey: inputKey, salt: Data(salt.utf8), info: info, outputByteCount: outputByteCount)
    }

    public static func hkdfSHA512(inputKey: Data, salt: Data, info: String, outputByteCount: Int = 32) -> Data {
        let key = HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: inputKey), salt: salt,
                                         info: Data(info.utf8), outputByteCount: outputByteCount)
        return key.withUnsafeBytes { Data($0) }
    }

    /// 4 zero bytes followed by the 8 ASCII bytes of `label` (e.g. "PS-Msg05"); shorter labels are zero-padded.
    public static func nonce(label: String) -> Data {
        var bytes = Array(label.utf8.prefix(8))
        bytes += Array(repeating: 0, count: 8 - bytes.count)
        return Data([0, 0, 0, 0] + bytes)
    }

    /// 4 zero bytes followed by the little-endian 64-bit counter.
    public static func nonce(counter: UInt64) -> Data {
        var data = Data([0, 0, 0, 0])
        withUnsafeBytes(of: counter.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Returns ciphertext ‖ 16-byte tag.
    public static func chachaSeal(_ plaintext: Data, key: Data, nonce: Data, aad: Data = Data()) throws -> Data {
        let (symmetricKey, chachaNonce) = try parameters(key: key, nonce: nonce)
        let box = try ChaChaPoly.seal(plaintext, using: symmetricKey, nonce: chachaNonce, authenticating: aad)
        return box.ciphertext + box.tag
    }

    /// Opens ciphertext ‖ 16-byte tag. Throws `HAPCryptoError.authenticationFailed` on any tag mismatch.
    public static func chachaOpen(_ sealed: Data, key: Data, nonce: Data, aad: Data = Data()) throws -> Data {
        let (symmetricKey, chachaNonce) = try parameters(key: key, nonce: nonce)
        guard sealed.count >= 16 else { throw HAPCryptoError.truncated }
        let split = sealed.endIndex - 16
        do {
            let box = try ChaChaPoly.SealedBox(nonce: chachaNonce, ciphertext: sealed[sealed.startIndex..<split], tag: sealed[split...])
            return try ChaChaPoly.open(box, using: symmetricKey, authenticating: aad)
        } catch {
            throw HAPCryptoError.authenticationFailed
        }
    }

    private static func parameters(key: Data, nonce: Data) throws -> (SymmetricKey, ChaChaPoly.Nonce) {
        guard key.count == 32 else { throw HAPCryptoError.invalidKeyLength }
        guard nonce.count == 12, let chachaNonce = try? ChaChaPoly.Nonce(data: nonce) else { throw HAPCryptoError.invalidNonceLength }
        return (SymmetricKey(data: key), chachaNonce)
    }
}

/// Ephemeral X25519 key pair for pair-verify (accessory and test controllers).
public struct X25519KeyPair: Sendable {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public init(rawRepresentation: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// Raw 32-byte X25519 shared secret with the peer's public key.
    public func sharedSecret(with peerPublicKey: Data) throws -> Data {
        guard peerPublicKey.count == 32, let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey) else {
            throw HAPCryptoError.invalidPublicKey
        }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }
}

/// Ed25519 long-term key (accessory LTSK/LTPK).
public struct HAPLongTermKey: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    public init() {
        privateKey = Curve25519.Signing.PrivateKey()
    }

    public init(rawRepresentation: Data) throws {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    public func signature(for data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }

    public static func isValidSignature(_ signature: Data, for data: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}
