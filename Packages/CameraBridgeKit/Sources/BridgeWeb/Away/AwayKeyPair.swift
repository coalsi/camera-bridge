import Crypto
import Foundation

/// A WireGuard key pair: base64 of 32 bytes each, as `wg genkey` and `wg pubkey` write them. A device's private key is held in memory only; it
/// is never written to a file or a log.
struct AwayKeyPair: Sendable {
    let privateKey: String
    let publicKey: String

    /// Random bytes, clamped as `wg genkey` clamps them, so the key is the same on every tool that reads it.
    init() {
        var bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        bytes[0] &= 248
        bytes[31] &= 127
        bytes[31] |= 64
        // A 32-byte private key always derives; the force is for the type system, not for a case that can happen.
        self.init(bytes: bytes)!
    }

    /// The pair for a private key given as base64; nil when it is not 32 bytes. The key is used as given: X25519 clamps while it derives (RFC
    /// 7748), so an unclamped key still gives the public key the other end expects.
    init?(privateKey base64: String) {
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        self.init(bytes: Array(data))
    }

    private init?(bytes: [UInt8]) {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) else { return nil }
        privateKey = Data(bytes).base64EncodedString()
        publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    }
}
