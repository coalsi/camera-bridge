import Foundation

/// Single-block DES encryption (FIPS 46-3), ECB, encryption only: what the IP camera web API's login token needs (`IPCWebToken`).
/// Not a general cipher (no decryption, no other modes, no padding scheme): DES is long broken, and nothing else in Camera Bridge
/// may use it. Portable Swift, no platform crypto.
enum IPCWebDES {
    /// Encrypts `data` (its length a multiple of 8) block by block with the 8-byte `key`; nil for any other length.
    static func encryptECB(key: [UInt8], _ data: [UInt8]) -> [UInt8]? {
        guard key.count == 8, data.count % 8 == 0 else { return nil }
        let subkeys = Self.subkeys(Self.word(key[...]))
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var start = 0
        while start < data.count {
            let block = encrypt(Self.word(data[start..<start + 8]), subkeys: subkeys)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: block >> UInt64(shift))) }
            start += 8
        }
        return out
    }

    /// One 64-bit block (the first byte in the high bits).
    static func encrypt(_ block: UInt64, key: UInt64) -> UInt64 {
        encrypt(block, subkeys: subkeys(key))
    }

    private static func encrypt(_ block: UInt64, subkeys: [UInt64]) -> UInt64 {
        let permuted = permute(block, width: 64, initialPermutation)
        var left = UInt32(truncatingIfNeeded: permuted >> 32)
        var right = UInt32(truncatingIfNeeded: permuted)
        for subkey in subkeys {
            (left, right) = (right, left ^ feistel(right, subkey))
        }
        return permute(UInt64(right) << 32 | UInt64(left), width: 64, finalPermutation)
    }

    /// The 16 round keys (48 bits each).
    private static func subkeys(_ key: UInt64) -> [UInt64] {
        let chosen = permute(key, width: 64, permutedChoice1)
        var c = UInt32(truncatingIfNeeded: chosen >> 28) & 0x0FFF_FFFF
        var d = UInt32(truncatingIfNeeded: chosen) & 0x0FFF_FFFF
        return rotations.map { rotation in
            c = ((c << rotation) | (c >> (28 - rotation))) & 0x0FFF_FFFF
            d = ((d << rotation) | (d >> (28 - rotation))) & 0x0FFF_FFFF
            return permute(UInt64(c) << 28 | UInt64(d), width: 56, permutedChoice2)
        }
    }

    private static func feistel(_ half: UInt32, _ subkey: UInt64) -> UInt32 {
        let mixed = permute(UInt64(half), width: 32, expansion) ^ subkey
        var out: UInt32 = 0
        for box in 0..<8 {
            let six = Int(truncatingIfNeeded: mixed >> UInt64(42 - 6 * box)) & 0x3F
            let row = (six >> 4) & 0x2 | six & 0x1
            let column = (six >> 1) & 0xF
            out = out << 4 | UInt32(sBoxes[box][row * 16 + column])
        }
        return UInt32(truncatingIfNeeded: permute(UInt64(out), width: 32, permutation))
    }

    /// Bit `table[i]` of `input` (bits numbered 1… from the most significant of `width`) becomes bit i+1 of the result.
    private static func permute(_ input: UInt64, width: Int, _ table: [UInt8]) -> UInt64 {
        var out: UInt64 = 0
        for position in table {
            out = out << 1 | (input >> UInt64(width - Int(position))) & 1
        }
        return out
    }

    private static func word(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }

    // MARK: FIPS 46-3 tables

    private static let initialPermutation: [UInt8] = [
        58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
        62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
        57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
        61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
    ]

    private static let finalPermutation: [UInt8] = [
        40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
        38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
        36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
        34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
    ]

    private static let expansion: [UInt8] = [
        32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
        16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
    ]

    private static let permutation: [UInt8] = [
        16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
        2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
    ]

    private static let permutedChoice1: [UInt8] = [
        57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18,
        10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22,
        14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4,
    ]

    private static let permutedChoice2: [UInt8] = [
        14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32,
    ]

    private static let rotations: [UInt32] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]

    private static let sBoxes: [[UInt8]] = [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
         0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
         4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
         15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
         3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
         0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
         13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
         13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
         13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
         1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
         13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
         10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
         3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
         14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
         4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
         11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
         10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
         9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
         4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
         13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
         1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
         6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
         1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
         7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
         2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ]
}

/// The IP camera web API's sign-in values: the username and the password (as typed, not hashed), each DES-ECB encrypted with the key
/// "WebLogin" after zero-padding to a multiple of 8 bytes, in lowercase hex ("admin" → `52851dbd7918bbae`; "" → ""). The camera's own
/// page computes it per character code, so the text is taken as ISO-8859-1: a character above U+00FF has no such value (nil), and the
/// camera is then reached through ONVIF only. A token is as good as the password: never logged, never put in an error.
enum IPCWebToken {
    static let key: [UInt8] = Array("WebLogin".utf8)

    static func make(_ text: String) -> String? {
        var bytes: [UInt8] = []
        for scalar in text.unicodeScalars {
            guard scalar.value <= 0xFF else { return nil }
            bytes.append(UInt8(scalar.value))
        }
        if bytes.isEmpty { return "" }
        bytes += [UInt8](repeating: 0, count: (8 - bytes.count % 8) % 8)
        guard let encrypted = IPCWebDES.encryptECB(key: key, bytes) else { return nil }
        return encrypted.map { String(format: "%02x", $0) }.joined()
    }
}
