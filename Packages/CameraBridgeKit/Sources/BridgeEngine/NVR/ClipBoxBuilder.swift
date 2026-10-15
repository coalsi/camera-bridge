import Foundation

/// Big-endian ISO/IEC 14496-12 box serializer for the clip writer. FMP4's own `BoxWriter` is internal to that module; this one is the small part of it
/// the writer needs. Sizes are back-patched when a box's body returns, so every box built with it stays below 4 GiB (the sample tables of a clip,
/// at most 7,200 s of video, are a few megabytes).
package struct ClipBoxBuilder {
    private(set) var bytes: [UInt8] = []

    package init(capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    package var count: Int { bytes.count }
    package var data: Data { Data(bytes) }

    package mutating func u8(_ value: UInt8) { bytes.append(value) }

    package mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    package mutating func u24(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        u16(UInt16(truncatingIfNeeded: value))
    }

    package mutating func u32(_ value: UInt32) {
        u16(UInt16(truncatingIfNeeded: value >> 16))
        u16(UInt16(truncatingIfNeeded: value))
    }

    package mutating func u64(_ value: UInt64) {
        u32(UInt32(truncatingIfNeeded: value >> 32))
        u32(UInt32(truncatingIfNeeded: value))
    }

    package mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }

    /// Four-character code: the first four ASCII bytes of `code`, space-padded when shorter.
    package mutating func fourCC(_ code: String) {
        var encoded = Array(code.utf8.prefix(4))
        while encoded.count < 4 { encoded.append(0x20) }
        bytes.append(contentsOf: encoded)
    }

    package mutating func append(_ data: Data) { bytes.append(contentsOf: data) }
    package mutating func zeros(_ count: Int) { bytes.append(contentsOf: repeatElement(0, count: count)) }

    /// `size | type | body`.
    package mutating func box(_ type: String, _ body: (inout ClipBoxBuilder) throws -> Void) rethrows {
        let start = bytes.count
        u32(0)
        fourCC(type)
        try body(&self)
        let size = UInt32(truncatingIfNeeded: bytes.count - start)
        bytes[start] = UInt8(truncatingIfNeeded: size >> 24)
        bytes[start + 1] = UInt8(truncatingIfNeeded: size >> 16)
        bytes[start + 2] = UInt8(truncatingIfNeeded: size >> 8)
        bytes[start + 3] = UInt8(truncatingIfNeeded: size)
    }

    /// `size | type | version | flags(24) | body`.
    package mutating func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: (inout ClipBoxBuilder) throws -> Void) rethrows {
        try box(type) { builder in
            builder.u8(version)
            builder.u24(flags)
            try body(&builder)
        }
    }

    /// The 3×3 identity transformation matrix (16.16 and 2.30 fixed point).
    package mutating func identityMatrix() {
        for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { u32(value) }
    }
}
