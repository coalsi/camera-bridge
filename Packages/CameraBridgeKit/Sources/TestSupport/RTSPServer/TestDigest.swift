import BridgeSupport
import Foundation

/// Server-side HTTP/RTSP authentication for test servers, written independently of `DigestAuthenticator`
/// (own MD5, RFC 1321) so a client bug cannot hide behind shared code.
public enum TestDigest {
    /// Lowercase hex MD5 of `data` (RFC 1321).
    public static func md5Hex(_ data: Data) -> String {
        md5(data).map { String(format: "%02x", $0) }.joined()
    }

    public static func md5Hex(_ text: String) -> String { md5Hex(Data(text.utf8)) }

    /// Verifies an `Authorization: Digest …` value (MD5; RFC 2069 without qop, or RFC 2617 qop=auth).
    public static func verify(authorization: String?, method: String, credentials: HTTPCredentials, realm: String, nonce: String) -> Bool {
        guard let authorization, authorization.lowercased().hasPrefix("digest ") else { return false }
        let p = parameters(String(authorization.dropFirst(7)))
        guard p["username"] == credentials.username, p["realm"] == realm, p["nonce"] == nonce, let uri = p["uri"],
              let response = p["response"]?.lowercased() else { return false }
        if let algorithm = p["algorithm"], algorithm.uppercased() != "MD5" { return false }
        let ha1 = md5Hex("\(credentials.username):\(realm):\(credentials.password)")
        let ha2 = md5Hex("\(method):\(uri)")
        if let qop = p["qop"] {
            guard qop == "auth", let nc = p["nc"], let cnonce = p["cnonce"] else { return false }
            return response == md5Hex("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
        }
        return response == md5Hex("\(ha1):\(nonce):\(ha2)")
    }

    /// Verifies an `Authorization: Basic …` value.
    public static func verifyBasic(authorization: String?, credentials: HTTPCredentials) -> Bool {
        guard let authorization, authorization.lowercased().hasPrefix("basic ") else { return false }
        let encoded = authorization.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard let decoded = Data(base64Encoded: encoded) else { return false }
        return String(decoding: decoded, as: UTF8.self) == "\(credentials.username):\(credentials.password)"
    }

    /// `name=value` / `name="quoted"` pairs of a credentials string (lowercased names).
    static func parameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " || text[index] == "," { index = text.index(after: index) }
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            let name = text[index..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            index = text.index(after: equals)
            var value = ""
            if index < text.endIndex, text[index] == "\"" {
                index = text.index(after: index)
                while index < text.endIndex, text[index] != "\"" {
                    if text[index] == "\\" { index = text.index(after: index); guard index < text.endIndex else { break } }
                    value.append(text[index])
                    index = text.index(after: index)
                }
                if index < text.endIndex { index = text.index(after: index) }
            } else {
                let end = text[index...].firstIndex(of: ",") ?? text.endIndex
                value = text[index..<end].trimmingCharacters(in: .whitespaces)
                index = end
            }
            result[name] = value
        }
        return result
    }

    // MARK: MD5 (RFC 1321)

    private static let shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    private static let constants: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296)) }

    static func md5(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 0, to: 64, by: 8) { message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

        var a0: UInt32 = 0x6745_2301, b0: UInt32 = 0xEFCD_AB89, c0: UInt32 = 0x98BA_DCFE, d0: UInt32 = 0x1032_5476
        for chunk in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let base = chunk + i * 4
                words[i] = UInt32(message[base]) | UInt32(message[base + 1]) << 8 | UInt32(message[base + 2]) << 16 | UInt32(message[base + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ constants[i] &+ words[g]
                a = d
                d = c
                c = b
                b = b &+ ((f << shifts[i]) | (f >> (32 - shifts[i])))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32($0 * 8)) } }
    }
}
