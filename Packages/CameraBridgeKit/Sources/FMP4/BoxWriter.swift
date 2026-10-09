import Foundation

/// Big-endian ISO/IEC 14496-12 box serializer. Box sizes are back-patched when the body closure returns; callers keep every
/// box below 4 GiB (`FMP4Muxer` checks the only unbounded one, the fragment, before writing it).
struct BoxWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    var count: Int { bytes.count }
    var data: Data { Data(bytes) }

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func u24(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        u16(UInt16(truncatingIfNeeded: value))
    }

    mutating func u32(_ value: UInt32) {
        u16(UInt16(truncatingIfNeeded: value >> 16))
        u16(UInt16(truncatingIfNeeded: value))
    }

    mutating func u64(_ value: UInt64) {
        u32(UInt32(truncatingIfNeeded: value >> 32))
        u32(UInt32(truncatingIfNeeded: value))
    }

    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }

    /// Four-character code; shorter codes are space-padded, longer ones truncated (all call sites pass 4 ASCII letters).
    mutating func fourCC(_ code: String) {
        var encoded = Array(code.utf8.prefix(4))
        while encoded.count < 4 { encoded.append(0x20) }
        bytes.append(contentsOf: encoded)
    }

    mutating func append(_ data: Data) { bytes.append(contentsOf: data) }
    mutating func append(_ data: [UInt8]) { bytes.append(contentsOf: data) }
    mutating func zeros(_ count: Int) { bytes.append(contentsOf: repeatElement(0, count: count)) }

    /// `size | type | body`.
    mutating func box(_ type: String, _ body: (inout BoxWriter) throws -> Void) rethrows {
        let start = bytes.count
        u32(0)
        fourCC(type)
        try body(&self)
        patchU32(at: start, UInt32(truncatingIfNeeded: bytes.count - start))
    }

    /// `size | type | version | flags(24) | body`.
    mutating func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: (inout BoxWriter) throws -> Void) rethrows {
        try box(type) { writer in
            writer.u8(version)
            writer.u24(flags)
            try body(&writer)
        }
    }

    mutating func patchU32(at offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    /// ISO/IEC 14496-12 3×3 identity transformation matrix (16.16 / 2.30 fixed point).
    mutating func identityMatrix() {
        for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { u32(value) }
    }
}
