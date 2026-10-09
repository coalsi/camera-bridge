import Crypto
import Foundation

/// Random tokens, constant-time comparison and the password hash: the small crypto the web interface needs, on swift-crypto
/// only (CryptoKit on macOS, BoringSSL on Linux).
enum Secrets {
    /// `count` bytes from the system's secure random generator.
    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    /// 256 random bits as 43 URL-safe characters.
    static func randomToken() -> String {
        base64URL(randomBytes(32))
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { byte in (byte < 16 ? "0" : "") + String(byte, radix: 16) }.joined()
    }

    static func sha256Hex(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    /// Compares without stopping at the first difference (lengths may leak, contents do not).
    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            difference |= (index < lhs.count ? lhs[index] : 0) ^ (index < rhs.count ? rhs[index] : 0)
        }
        return difference == 0
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEqual(Array(lhs.utf8), Array(rhs.utf8))
    }

    /// The anti-forgery token of a session: HMAC-SHA256 of a label under the session token, so it needs no storage.
    static func csrfToken(forSessionToken token: String) -> String {
        let key = SymmetricKey(data: Data(token.utf8))
        return hex(HMAC<SHA256>.authenticationCode(for: Data("camera-bridge csrf".utf8), using: key))
    }
}

/// PBKDF2-HMAC-SHA256 (RFC 8018), the password hash. The keyed HMAC state is built once and copied per iteration, so each
/// iteration costs two SHA-256 compressions.
enum PBKDF2 {
    static func sha256(password: [UInt8], salt: [UInt8], iterations: Int, length: Int = 32) -> [UInt8] {
        precondition(iterations >= 1 && length >= 1)
        let keyed = HMAC<SHA256>(key: SymmetricKey(data: password))
        var derived: [UInt8] = []
        derived.reserveCapacity(length)
        var blockIndex: UInt32 = 1
        while derived.count < length {
            var first = keyed
            first.update(data: salt)
            first.update(data: [UInt8(blockIndex >> 24), UInt8((blockIndex >> 16) & 0xFF), UInt8((blockIndex >> 8) & 0xFF), UInt8(blockIndex & 0xFF)])
            var u = Array(first.finalize())
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    var next = keyed
                    next.update(data: u)
                    let mac = next.finalize()
                    var index = 0
                    mac.withUnsafeBytes { bytes in
                        for byte in bytes {
                            u[index] = byte
                            t[index] ^= byte
                            index += 1
                        }
                    }
                }
            }
            derived.append(contentsOf: t)
            blockIndex += 1
        }
        return Array(derived.prefix(length))
    }
}

/// A password as stored: the algorithm and its cost travel with the hash, so the cost can rise later without locking anyone out.
struct StoredPassword: Codable, Equatable, Sendable {
    var algorithm: String
    var iterations: Int
    var salt: String
    var hash: String

    static let algorithmName = "pbkdf2-sha256"
    static let defaultIterations = 600_000
    /// The most a stored cost may ask of a login (a damaged or hand-edited file must not hang the daemon).
    static let maximumIterations = 10_000_000

    static func make(password: String, iterations: Int) -> StoredPassword {
        let salt = Secrets.randomBytes(16)
        let hash = PBKDF2.sha256(password: Array(password.utf8), salt: salt, iterations: iterations)
        return StoredPassword(algorithm: algorithmName, iterations: iterations, salt: Data(salt).base64EncodedString(),
                              hash: Data(hash).base64EncodedString())
    }

    func verify(_ password: String) -> Bool {
        guard algorithm == Self.algorithmName, (1...Self.maximumIterations).contains(iterations),
              let salt = Data(base64Encoded: salt), let expected = Data(base64Encoded: hash), !expected.isEmpty else { return false }
        let actual = PBKDF2.sha256(password: Array(password.utf8), salt: Array(salt), iterations: iterations, length: expected.count)
        return Secrets.constantTimeEqual(actual, Array(expected))
    }
}
