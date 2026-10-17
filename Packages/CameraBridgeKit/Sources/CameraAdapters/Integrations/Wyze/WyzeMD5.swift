import Foundation

/// MD5 (RFC 1321), only for sign-ins whose protocol fixes it: Wyze's login takes the password hashed three times with MD5
/// (`WyzeCloud.passwordHash`), and the IPCamera Web family's takes the MD5 of "username:password" (`IPCamWebClient.encrypted`). It is not
/// used for anything else. Written here because CameraAdapters does not link swift-crypto and the hash must also work on Linux (no
/// CryptoKit or CommonCrypto there).
enum WyzeMD5 {
    /// The 16-byte digest of `bytes`.
    static func digest(_ bytes: some Collection<UInt8>) -> [UInt8] {
        var message = Array(bytes)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 0, to: 64, by: 8) { message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

        var a0: UInt32 = 0x6745_2301
        var b0: UInt32 = 0xEFCD_AB89
        var c0: UInt32 = 0x98BA_DCFE
        var d0: UInt32 = 0x1032_5476
        var words = [UInt32](repeating: 0, count: 16)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let base = chunk + index * 4
                words[index] = UInt32(message[base]) | UInt32(message[base + 1]) << 8 | UInt32(message[base + 2]) << 16 | UInt32(message[base + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for step in 0..<64 {
                var f: UInt32
                let g: Int
                switch step {
                case 0..<16:
                    f = (b & c) | (~b & d)
                    g = step
                case 16..<32:
                    f = (d & b) | (~d & c)
                    g = (5 * step + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d
                    g = (3 * step + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * step) % 16
                }
                f = f &+ a &+ constants[step] &+ words[g]
                a = d
                d = c
                c = b
                b = b &+ ((f << shifts[step]) | (f >> (32 - shifts[step])))
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * UInt32($0))) } }
    }

    /// Lowercase hex of the digest of the UTF-8 bytes of `text`.
    static func hex(_ text: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for byte in digest(text.utf8) {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static let shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]

    /// floor(abs(sin(i + 1)) * 2^32).
    private static let constants: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296)) }
}
