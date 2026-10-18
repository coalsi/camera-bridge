import Foundation

/// RC4 (the stream cipher, key scheduling then the keystream XORed in), only for the IPCamera Web family's sign-in: its page sends the MD5 of
/// "username:password" in uppercase hex, encrypted with RC4 under the key "pwnsd" (`IPCamWebClient.encrypted(username:password:)`). The
/// protocol fixes it; it protects nothing (the key is in the camera's own page) and is not used for anything else. Portable: no CryptoKit
/// or CommonCrypto.
enum IPCamWebRC4 {
    /// `bytes` encrypted (or decrypted: the same operation) under `key`. An empty key gives the bytes back unchanged.
    static func apply(key: [UInt8], to bytes: [UInt8]) -> [UInt8] {
        guard !key.isEmpty else { return bytes }
        var state = (0...255).map { UInt8($0) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(state[i]) + Int(key[i % key.count])) & 0xFF
            state.swapAt(i, j)
        }
        var i = 0
        j = 0
        return bytes.map { byte in
            i = (i + 1) & 0xFF
            j = (j + Int(state[i])) & 0xFF
            state.swapAt(i, j)
            return byte ^ state[(Int(state[i]) + Int(state[j])) & 0xFF]
        }
    }

    /// Two lowercase hex digits per byte.
    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
