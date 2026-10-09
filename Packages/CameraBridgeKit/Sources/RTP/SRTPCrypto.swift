import Crypto
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#elseif canImport(_CryptoExtras)
import _CryptoExtras
#endif

/// AES-128 in counter mode with a full 128-bit big-endian counter (RFC 3711 §4.1.1 AES-CM; the counter never wraps
/// within one SRTP packet). CommonCrypto on Apple platforms, swift-crypto `_CryptoExtras` elsewhere.
enum AESCounterMode {
    /// XORs the keystream that starts at counter block `iv` into `data[data.startIndex + offset ..< data.endIndex]`.
    static func apply(key: Data, iv: Data, to data: inout Data, from offset: Int) throws {
        guard key.count == 16, iv.count == 16, offset >= 0, offset <= data.count else { throw SRTPError.malformed }
        let count = data.count - offset
        guard count > 0 else { return }
        #if canImport(CommonCrypto)
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                        ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard created == CCCryptorStatus(kCCSuccess), let cryptor else { throw SRTPError.malformed }
        defer { CCCryptorRelease(cryptor) }
        let status = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
            guard let base = buffer.baseAddress else { return CCCryptorStatus(kCCParamError) }
            var moved = 0
            let region = base + offset
            return CCCryptorUpdate(cryptor, region, count, region, count, &moved)
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw SRTPError.malformed }
        #elseif canImport(_CryptoExtras)
        let start = data.startIndex + offset
        let output = try AES._CTR.encrypt(data[start...], using: SymmetricKey(data: key), nonce: AES._CTR.Nonce(nonceBytes: iv))
        data.replaceSubrange(start..., with: output)
        #else
        #error("SRTP needs CommonCrypto or swift-crypto _CryptoExtras for AES-CTR")
        #endif
    }

    /// `count` bytes of raw keystream (the AES-CM PRF of RFC 3711 §4.3.3).
    static func keystream(key: Data, iv: Data, count: Int) throws -> Data {
        var data = Data(count: max(0, count))
        try apply(key: key, iv: iv, to: &data, from: 0)
        return data
    }
}

/// One direction's session keys for SRTP (labels 0/1/2) or SRTCP (labels 3/4/5), key derivation rate 0
/// (RFC 3711 §4.3.1–4.3.3): 128-bit cipher key, 160-bit HMAC-SHA1 key, 112-bit salt.
struct SRTPSessionKeys: Sendable {
    static let tagLength = 10

    let encryptionKey: Data
    let authenticationKey: Data
    let salt: Data

    init(masterKey: Data, masterSalt: Data, rtcp: Bool) throws {
        guard masterKey.count == 16, masterSalt.count == 14 else { throw SRTPError.malformed }
        let key = Data(masterKey)
        let salt = Data(masterSalt)
        let base: UInt8 = rtcp ? 3 : 0
        encryptionKey = try Self.derive(masterKey: key, masterSalt: salt, label: base, count: 16)
        authenticationKey = try Self.derive(masterKey: key, masterSalt: salt, label: base + 1, count: 20)
        self.salt = try Self.derive(masterKey: key, masterSalt: salt, label: base + 2, count: 14)
    }

    /// x = (label ‖ r) XOR master_salt with r = 0 (rate 0), right-aligned; output = AES-CM keystream from x · 2^16.
    private static func derive(masterKey: Data, masterSalt: Data, label: UInt8, count: Int) throws -> Data {
        var iv = [UInt8](masterSalt) + [0, 0]
        iv[7] ^= label
        return try AESCounterMode.keystream(key: masterKey, iv: Data(iv), count: count)
    }

    /// IV = (salt · 2^16) XOR (SSRC · 2^64) XOR (index · 2^16) (RFC 3711 §4.1.1).
    func iv(ssrc: UInt32, index: UInt64) -> Data {
        var iv = [UInt8](salt) + [0, 0]
        for i in 0..<4 { iv[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> (24 - 8 * i)) }
        for i in 0..<6 { iv[8 + i] ^= UInt8(truncatingIfNeeded: index >> (40 - 8 * i)) }
        return Data(iv)
    }

    /// HMAC-SHA1 over `message` (‖ ROC for SRTP), truncated to 80 bits.
    func tag(for message: Data, rolloverCounter: UInt32? = nil) -> Data {
        var hmac = HMAC<Insecure.SHA1>(key: SymmetricKey(data: authenticationKey))
        hmac.update(data: message)
        if let rolloverCounter {
            hmac.update(data: [UInt8(truncatingIfNeeded: rolloverCounter >> 24), UInt8(truncatingIfNeeded: rolloverCounter >> 16),
                               UInt8(truncatingIfNeeded: rolloverCounter >> 8), UInt8(truncatingIfNeeded: rolloverCounter)])
        }
        return Data(Data(hmac.finalize()).prefix(Self.tagLength))
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

/// 64-entry sliding replay window over packet indices (RFC 3711 §3.3.2).
struct ReplayWindow: Sendable {
    static let size: UInt64 = 64

    private(set) var highest: UInt64?
    private var bitmap: UInt64 = 0   // bit n set ⇔ index (highest − n) was accepted

    /// True when `index` is newer than the window or inside it and not seen yet.
    func allows(_ index: UInt64) -> Bool {
        guard let highest, index <= highest else { return true }
        let age = highest - index
        return age < Self.size && bitmap & (1 << age) == 0
    }

    mutating func accept(_ index: UInt64) {
        guard let current = highest else {
            highest = index
            bitmap = 1
            return
        }
        if index > current {
            let shift = index - current
            bitmap = shift >= Self.size ? 1 : (bitmap << shift) | 1
            highest = index
        } else if current - index < Self.size {
            bitmap |= 1 << (current - index)
        }
    }
}

/// Per-SSRC SRTP rollover state (RFC 3711 §3.3.1 index estimation), shared by sender and receiver.
struct SRTPStreamState: Sendable {
    private(set) var rolloverCounter: UInt32 = 0
    private(set) var highestSequence: UInt16
    private(set) var replay = ReplayWindow()

    init(firstSequence: UInt16) {
        highestSequence = firstSequence
    }

    /// The guessed ROC `v` and 48-bit index for `sequence`; nil when the packet would precede ROC 0.
    func estimate(_ sequence: UInt16) -> (rolloverCounter: UInt32, index: UInt64)? {
        let s = Int(sequence)
        let last = Int(highestSequence)
        var v = Int64(rolloverCounter)
        if last < 32_768 {
            if s - last > 32_768 { v -= 1 }
        } else if last - 32_768 > s {
            v += 1
        }
        guard let roc = UInt32(exactly: v) else { return nil }
        return (roc, UInt64(roc) << 16 | UInt64(sequence))
    }

    mutating func commit(rolloverCounter v: UInt32, sequence: UInt16, index: UInt64) {
        if v == rolloverCounter &+ 1, v != 0 {
            rolloverCounter = v
            highestSequence = sequence
        } else if v == rolloverCounter, sequence > highestSequence {
            highestSequence = sequence
        }
        replay.accept(index)
    }
}
