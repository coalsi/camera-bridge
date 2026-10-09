import Foundation

/// MSB-first bit reader with Exp-Golomb codes (ITU-T H.264 §9.1) over bytes — for parameter sets an RBSP, i.e. with
/// emulation prevention already removed. Every read is bounds-checked and throws instead of trapping.
///
/// The package's only bit reader: MediaCore's SPS/VUI parsing, H.264 slice headers (`NALUnits.h264SliceType`, for
/// BridgeEngine's B-frame detection), `AudioSpecificConfig`, and RTSP's RFC 3640 AU headers use it.
package struct BitReader {
    package enum Failure: Error {
        /// The data ran out.
        case exhausted
        /// A read wider than 64 bits, an Exp-Golomb code longer than 32 bits, or (thrown by parsers) a value outside
        /// its syntax element's range.
        case invalid
    }

    private let bytes: [UInt8]
    /// Bits read (or skipped) so far.
    package private(set) var position = 0

    package init(_ data: Data) {
        bytes = [UInt8](data)
    }

    package init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    package var bitsRemaining: Int { bytes.count * 8 - position }

    /// The next `count` (0…64) bits, MSB first. Nothing is consumed when it throws.
    package mutating func bits(_ count: Int) throws(Failure) -> UInt64 {
        guard count >= 0, count <= 64 else { throw .invalid }
        guard count <= bitsRemaining else { throw .exhausted }
        var value: UInt64 = 0
        for _ in 0..<count {
            value = value << 1 | UInt64((bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1)
            position += 1
        }
        return value
    }

    package mutating func flag() throws(Failure) -> Bool { try bits(1) == 1 }

    package mutating func skip(_ count: Int) throws(Failure) {
        guard count >= 0, count <= bitsRemaining else { throw .exhausted }
        position += count
    }

    /// ue(v): at most 31 leading zeros (values up to 2³² − 2); 32 or more is `.invalid`.
    package mutating func ue() throws(Failure) -> UInt32 {
        var leadingZeros = 0
        while try bits(1) == 0 {
            leadingZeros += 1
            guard leadingZeros < 32 else { throw .invalid }
        }
        guard leadingZeros > 0 else { return 0 }
        let suffix = try bits(leadingZeros)
        return UInt32((UInt64(1) << UInt64(leadingZeros)) - 1 + suffix)
    }

    /// se(v): code numbers 0, 1, 2, 3, 4, … are 0, 1, −1, 2, −2, … (|value| < 2³¹, so it always fits).
    package mutating func se() throws(Failure) -> Int32 {
        let code = Int64(try ue())
        return Int32(code % 2 == 0 ? -(code / 2) : (code + 1) / 2)
    }
}
