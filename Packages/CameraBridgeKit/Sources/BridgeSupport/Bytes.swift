import Foundation

extension Data {
    /// Parses hexadecimal text (case-insensitive; whitespace ignored). Returns nil on odd length or non-hex characters.
    public init?(hex: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8?
        for c in hex.utf8 {
            let nibble: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = c - UInt8(ascii: "A") + 10
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"): continue
            default: return nil
            }
            if let h = high {
                bytes.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        guard high == nil else { return nil }
        self.init(bytes)
    }

    /// Lowercase hexadecimal representation.
    public var hexString: String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

public enum ByteError: Error, Equatable {
    case truncated(needed: Int, available: Int)
}

/// Sequential big/little-endian reader over `Data` (works on slices). Failed reads consume nothing.
public struct ByteReader: Sendable {
    private let data: Data
    private var offset: Int   // absolute index into `data`

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }
    public var isAtEnd: Bool { offset >= data.endIndex }

    private mutating func take(_ count: Int) throws -> Range<Int> {
        guard count >= 0, count <= remaining else {
            throw ByteError.truncated(needed: count, available: remaining)
        }
        let range = offset..<(offset + count)
        offset += count
        return range
    }

    private mutating func readUnsigned<T: FixedWidthInteger & UnsignedInteger>(_ byteCount: Int, bigEndian: Bool, as: T.Type) throws -> T {
        let range = try take(byteCount)
        var value: T = 0
        if bigEndian {
            for i in range { value = value << 8 | T(data[i]) }
        } else {
            for i in range.reversed() { value = value << 8 | T(data[i]) }
        }
        return value
    }

    public mutating func readUInt8() throws -> UInt8 { data[try take(1).lowerBound] }
    public mutating func readUInt16BE() throws -> UInt16 { try readUnsigned(2, bigEndian: true, as: UInt16.self) }
    public mutating func readUInt16LE() throws -> UInt16 { try readUnsigned(2, bigEndian: false, as: UInt16.self) }
    public mutating func readUInt24BE() throws -> UInt32 { try readUnsigned(3, bigEndian: true, as: UInt32.self) }
    public mutating func readUInt32BE() throws -> UInt32 { try readUnsigned(4, bigEndian: true, as: UInt32.self) }
    public mutating func readUInt32LE() throws -> UInt32 { try readUnsigned(4, bigEndian: false, as: UInt32.self) }
    public mutating func readUInt64BE() throws -> UInt64 { try readUnsigned(8, bigEndian: true, as: UInt64.self) }
    public mutating func readUInt64LE() throws -> UInt64 { try readUnsigned(8, bigEndian: false, as: UInt64.self) }

    /// Returns a copy (indices start at 0).
    public mutating func readBytes(_ count: Int) throws -> Data {
        Data(data[try take(count)])
    }

    public mutating func skip(_ count: Int) throws {
        _ = try take(count)
    }
}

/// Appending big/little-endian writer.
public struct ByteWriter: Sendable {
    public private(set) var data: Data

    public init() { data = Data() }

    public mutating func write(_ v: UInt8) { data.append(v) }
    public mutating func writeUInt16BE(_ v: UInt16) { append(v, byteCount: 2, bigEndian: true) }
    public mutating func writeUInt16LE(_ v: UInt16) { append(v, byteCount: 2, bigEndian: false) }
    public mutating func writeUInt24BE(_ v: UInt32) { append(v & 0x00FF_FFFF, byteCount: 3, bigEndian: true) }
    public mutating func writeUInt32BE(_ v: UInt32) { append(v, byteCount: 4, bigEndian: true) }
    public mutating func writeUInt32LE(_ v: UInt32) { append(v, byteCount: 4, bigEndian: false) }
    public mutating func writeUInt64BE(_ v: UInt64) { append(v, byteCount: 8, bigEndian: true) }
    public mutating func writeUInt64LE(_ v: UInt64) { append(v, byteCount: 8, bigEndian: false) }
    public mutating func write(_ d: Data) { data.append(d) }

    private mutating func append<T: FixedWidthInteger & UnsignedInteger>(_ value: T, byteCount: Int, bigEndian: Bool) {
        for i in 0..<byteCount {
            let shift = bigEndian ? (byteCount - 1 - i) * 8 : i * 8
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
