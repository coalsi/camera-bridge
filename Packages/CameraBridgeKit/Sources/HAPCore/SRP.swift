import BigInt
import Crypto
import Foundation

public enum SRPError: Error, Equatable {
    case invalidPublicKey
    case proofMismatch
    case notReady
}

/// SRP-6a with the RFC 5054 3072-bit group, g = 5, SHA-512, as used by HAP pair-setup (research brief §3.2):
/// k = H(N ‖ PAD(g)), u = H(PAD(A) ‖ PAD(B)), x = H(s ‖ H(I ‖ ":" ‖ P)), K = H(PAD(S)),
/// M1 = H(H(N) ⊕ H(g) ‖ H(I) ‖ s ‖ A ‖ B ‖ K), M2 = H(A ‖ M1 ‖ K). A and B are hashed as transmitted (384 bytes).
enum SRPGroup {
    static let byteCount = 384

    static let N: BigUInt = {
        let hex = """
            FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD\
            EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED\
            EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F\
            83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B\
            E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510\
            15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
            ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C\
            BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
            """
        guard let n = BigUInt(hex, radix: 16) else { preconditionFailure("invalid RFC 5054 group constant") }
        return n
    }()

    static let g = BigUInt(5)
    static let montgomery = MontgomeryContext(modulus: N)

    /// base^exponent mod N (Montgomery; no secret-dependent branches or table indexing).
    static func power(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt { montgomery.power(base, exponent) }
    /// (a · b) mod N.
    static func multiply(_ a: BigUInt, _ b: BigUInt) -> BigUInt { montgomery.multiply(a, b) }
    /// (a + b) mod N.
    static func add(_ a: BigUInt, _ b: BigUInt) -> BigUInt { montgomery.add(a, b) }
    static var modulusBytes: Data { pad(N) }

    /// k = H(N ‖ PAD(g))
    static let k: BigUInt = BigUInt(H(pad(N), pad(g)))

    /// H(N) ⊕ H(g) with g unpadded.
    static let hNxorHg: Data = {
        let hn = H(pad(N))
        let hg = H(g.serialize())
        return Data(zip(hn, hg).map { $0 ^ $1 })
    }()

    static func H(_ parts: Data...) -> Data {
        var hasher = SHA512()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    /// Big-endian, left-padded to 384 bytes.
    static func pad(_ value: BigUInt) -> Data {
        let bytes = value.serialize()
        if bytes.count >= byteCount { return bytes.suffix(byteCount) }
        return Data(count: byteCount - bytes.count) + bytes
    }

    static func x(username: String, password: String, salt: Data) -> BigUInt {
        BigUInt(H(salt, H(Data("\(username):\(password)".utf8))))
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func proof(username: String, salt: Data, A: Data, B: Data, K: Data) -> Data {
        H(hNxorHg, H(Data(username.utf8)), salt, A, B, K)
    }
}

/// Accessory side of SRP-6a (pair-setup M2/M4). Not Sendable: confine to one actor.
public final class SRPServer {
    public let salt: Data
    private let username: String
    private let verifier: BigUInt
    private let b: BigUInt
    private let B: BigUInt
    private let paddedB: Data
    private var clientA: Data?
    private var K: Data?

    public init(username: String = "Pair-Setup", password: String, salt: Data? = nil, privateValue: Data? = nil) {
        let salt = salt ?? SRPGroup.randomBytes(16)
        self.salt = salt
        self.username = username
        let x = SRPGroup.x(username: username, password: password, salt: salt)
        verifier = SRPGroup.power(SRPGroup.g, x)
        var secret = BigUInt(privateValue ?? SRPGroup.randomBytes(32))
        if secret.isZero { secret = BigUInt(SRPGroup.randomBytes(32)) + 1 }
        b = secret
        B = SRPGroup.add(SRPGroup.multiply(SRPGroup.k, verifier), SRPGroup.power(SRPGroup.g, secret))   // kv + g^b
        paddedB = SRPGroup.pad(B)
    }

    /// B, 384 bytes.
    public var publicKey: Data { paddedB }

    /// K (64 bytes), available after `setClientPublicKey`.
    public var sessionKey: Data? { K }

    public func setClientPublicKey(_ a: Data) throws(SRPError) {
        guard !a.isEmpty, a.count <= SRPGroup.byteCount else { throw .invalidPublicKey }
        let A = BigUInt(a)
        guard !(A % SRPGroup.N).isZero else { throw .invalidPublicKey }
        let u = BigUInt(SRPGroup.H(SRPGroup.pad(A), paddedB))
        guard !u.isZero else { throw .invalidPublicKey }
        let S = SRPGroup.power(SRPGroup.multiply(A, SRPGroup.power(verifier, u)), b)   // (A·v^u)^b
        K = SRPGroup.H(SRPGroup.pad(S))
        clientA = a
    }

    /// Verifies M1 and returns M2.
    public func verifyClientProof(_ m1: Data) throws(SRPError) -> Data {
        guard let a = clientA, let K else { throw .notReady }
        let expected = SRPGroup.proof(username: username, salt: salt, A: a, B: paddedB, K: K)
        guard SRPGroup.constantTimeEqual(expected, m1) else { throw .proofMismatch }
        return SRPGroup.H(a, m1, K)
    }
}

/// Controller side of SRP-6a (for test controllers and tools).
public final class SRPClient {
    private let A: Data
    private let M1: Data
    private let K: Data

    public init(username: String = "Pair-Setup", password: String, salt: Data, serverPublicKey: Data, privateValue: Data? = nil) throws(SRPError) {
        guard !serverPublicKey.isEmpty, serverPublicKey.count <= SRPGroup.byteCount else { throw .invalidPublicKey }
        let B = BigUInt(serverPublicKey)
        guard !(B % SRPGroup.N).isZero else { throw .invalidPublicKey }
        var a = BigUInt(privateValue ?? SRPGroup.randomBytes(32))
        if a.isZero { a = BigUInt(SRPGroup.randomBytes(32)) + 1 }
        let paddedA = SRPGroup.pad(SRPGroup.power(SRPGroup.g, a))
        let paddedB = SRPGroup.pad(B)
        let u = BigUInt(SRPGroup.H(paddedA, paddedB))
        guard !u.isZero else { throw .invalidPublicKey }
        let x = SRPGroup.x(username: username, password: password, salt: salt)
        let gx = SRPGroup.power(SRPGroup.g, x)
        let kgx = SRPGroup.multiply(SRPGroup.k, gx)
        let base = (B % SRPGroup.N + SRPGroup.N - kgx) % SRPGroup.N
        let S = SRPGroup.power(base, a + u * x)
        let K = SRPGroup.H(SRPGroup.pad(S))
        self.A = paddedA
        self.K = K
        self.M1 = SRPGroup.proof(username: username, salt: salt, A: paddedA, B: paddedB, K: K)
    }

    /// A, 384 bytes.
    public var publicKey: Data { A }
    /// M1.
    public var proof: Data { M1 }
    /// K, 64 bytes.
    public var sessionKey: Data { K }

    public func verifyServerProof(_ m2: Data) -> Bool {
        SRPGroup.constantTimeEqual(SRPGroup.H(A, M1, K), m2)
    }
}
