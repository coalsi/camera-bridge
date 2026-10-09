// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// (Tag table and back-reference semantics from lib/datastream/DataStreamParser.ts; research brief §3.8. The HAP-NodeJS
// bugs listed there are not ported: 0x2F decodes as 39, short data decodes, int64 is written in full.)

import Foundation

/// HomeKit Data Stream value codec (research brief §3.8).
///
/// The encoder writes one canonical form per value: −1 → 0x07, 0…39 → 0x08+n, then int8/16/32/64 by range;
/// strings and data of ≤ 32 bytes in the short form, otherwise with the smallest 1/2/4/8-byte length prefix;
/// arrays and dictionaries of ≤ 14 items in the count form, otherwise terminated; floats as float64. It never emits
/// back-references (0xA0–0xCF). The decoder accepts every tag class, including back-references.
public enum HDSCodec {
    /// Arrays/dictionaries may nest this deep (a hostile `DF DF DF …` cannot exhaust the stack).
    public static let maximumDepth = 64

    public static func encode(_ value: HDSValue) throws -> Data {
        var writer = HDSWriter()
        try writer.write(value)
        return writer.data
    }

    /// Decodes exactly one value; bytes after it are an error (`trailingBytes`).
    public static func decode(_ data: Data) throws -> HDSValue {
        var reader = HDSReader(data)
        let value = try reader.readValue()
        guard reader.isAtEnd else { throw HDSCodecError.trailingBytes(reader.remaining) }
        return value
    }
}

enum HDSTag {
    static let trueValue: UInt8 = 0x01
    static let falseValue: UInt8 = 0x02
    static let terminator: UInt8 = 0x03
    static let null: UInt8 = 0x04
    static let uuid: UInt8 = 0x05
    static let date: UInt8 = 0x06
    static let minusOne: UInt8 = 0x07
    static let smallIntegers: ClosedRange<UInt8> = 0x08...0x2F
    static let int8: UInt8 = 0x30
    static let int16: UInt8 = 0x31
    static let int32: UInt8 = 0x32
    static let int64: UInt8 = 0x33
    static let float32: UInt8 = 0x35
    static let float64: UInt8 = 0x36
    static let shortString: ClosedRange<UInt8> = 0x40...0x60
    static let prefixedString: ClosedRange<UInt8> = 0x61...0x64
    static let nulTerminatedString: UInt8 = 0x6F
    static let shortData: ClosedRange<UInt8> = 0x70...0x90
    static let prefixedData: ClosedRange<UInt8> = 0x91...0x94
    static let terminatedData: UInt8 = 0x9F
    static let backReference: ClosedRange<UInt8> = 0xA0...0xCF
    static let countedArray: ClosedRange<UInt8> = 0xD0...0xDE
    static let terminatedArray: UInt8 = 0xDF
    static let countedDictionary: ClosedRange<UInt8> = 0xE0...0xEE
    static let terminatedDictionary: UInt8 = 0xEF

    /// Largest length of the short string/data forms and of the count-form containers.
    static let shortLengthLimit = 32
    static let countLimit = 14
}

/// Appends canonical HDS encodings. Also used by the payload codec to force int64 header fields.
struct HDSWriter {
    private(set) var bytes: [UInt8] = []

    var data: Data { Data(bytes) }
    var count: Int { bytes.count }

    mutating func write(_ value: HDSValue) throws {
        try write(value, depth: 0)
    }

    private mutating func write(_ value: HDSValue, depth: Int) throws {
        switch value {
        case .null: bytes.append(HDSTag.null)
        case .bool(let flag): bytes.append(flag ? HDSTag.trueValue : HDSTag.falseValue)
        case .int(let number): writeInteger(number)
        case .float(let number):
            bytes.append(HDSTag.float64)
            appendLittleEndian(number.bitPattern)
        case .string(let text): writeString(text)
        case .data(let data): writeLengthPrefixed(data, shortBase: HDSTag.shortData.lowerBound, prefixBase: HDSTag.prefixedData.lowerBound)
        case .uuid(let uuid):
            bytes.append(HDSTag.uuid)
            withUnsafeBytes(of: uuid.uuid) { bytes.append(contentsOf: $0) }   // RFC 4122 byte order = big-endian
        case .date(let date):
            bytes.append(HDSTag.date)
            appendLittleEndian(date.timeIntervalSinceReferenceDate.bitPattern)   // seconds since 2001-01-01
        case .array(let items):
            guard depth < HDSCodec.maximumDepth else { throw HDSCodecError.nestingTooDeep }
            let counted = items.count <= HDSTag.countLimit
            bytes.append(counted ? HDSTag.countedArray.lowerBound + UInt8(items.count) : HDSTag.terminatedArray)
            for item in items { try write(item, depth: depth + 1) }
            if !counted { bytes.append(HDSTag.terminator) }
        case .dictionary(let dictionary):
            guard depth < HDSCodec.maximumDepth else { throw HDSCodecError.nestingTooDeep }
            let counted = dictionary.pairs.count <= HDSTag.countLimit
            bytes.append(counted ? HDSTag.countedDictionary.lowerBound + UInt8(dictionary.pairs.count) : HDSTag.terminatedDictionary)
            for (key, item) in dictionary.pairs {
                writeString(key)
                try write(item, depth: depth + 1)
            }
            if !counted { bytes.append(HDSTag.terminator) }
        }
    }

    /// Smallest canonical integer form.
    mutating func writeInteger(_ number: Int64) {
        switch number {
        case -1:
            bytes.append(HDSTag.minusOne)
        case 0...39:
            bytes.append(HDSTag.smallIntegers.lowerBound + UInt8(number))
        case Int64(Int8.min)...Int64(Int8.max):
            bytes.append(HDSTag.int8)
            appendLittleEndian(Int8(number))
        case Int64(Int16.min)...Int64(Int16.max):
            bytes.append(HDSTag.int16)
            appendLittleEndian(Int16(number))
        case Int64(Int32.min)...Int64(Int32.max):
            bytes.append(HDSTag.int32)
            appendLittleEndian(Int32(number))
        default:
            writeInt64(number)
        }
    }

    /// Always the 9-byte int64 form (HDS headers write `id` and `status` this way, brief §3.8 goldens).
    mutating func writeInt64(_ number: Int64) {
        bytes.append(HDSTag.int64)
        appendLittleEndian(number)
    }

    mutating func writeString(_ text: String) {
        writeLengthPrefixed(Array(text.utf8), shortBase: HDSTag.shortString.lowerBound, prefixBase: HDSTag.prefixedString.lowerBound)
    }

    /// Count-form dictionary header; the caller writes exactly `count` key/value pairs.
    mutating func writeDictionaryHeader(count: Int) {
        precondition(count <= HDSTag.countLimit, "count-form dictionaries hold at most 14 entries")
        bytes.append(HDSTag.countedDictionary.lowerBound + UInt8(count))
    }

    private mutating func writeLengthPrefixed(_ content: some Collection<UInt8>, shortBase: UInt8, prefixBase: UInt8) {
        let length = content.count
        if length <= HDSTag.shortLengthLimit {
            bytes.append(shortBase + UInt8(length))
        } else if length <= Int(UInt8.max) {
            bytes.append(prefixBase)
            bytes.append(UInt8(length))
        } else if length <= Int(UInt16.max) {
            bytes.append(prefixBase + 1)
            appendLittleEndian(UInt16(length))
        } else if length <= Int(UInt32.max) {
            bytes.append(prefixBase + 2)
            appendLittleEndian(UInt32(length))
        } else {
            bytes.append(prefixBase + 3)
            appendLittleEndian(UInt64(length))
        }
        bytes.append(contentsOf: content)
    }

    private mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }
}

/// Sequential HDS decoder over one buffer. Values that HAP-NodeJS's reader remembers for back-references are
/// remembered here in the same order: booleans, integers, floats, dates, strings, data and UUIDs (not null,
/// containers, terminators or back-references themselves).
struct HDSReader {
    private let bytes: [UInt8]
    private var index = 0
    private var remembered: [HDSValue] = []

    init(_ data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool { index >= bytes.count }
    var remaining: Int { bytes.count - index }

    /// Reads one value; a terminator here is `unexpectedTerminator`.
    mutating func readValue() throws -> HDSValue {
        try readValue(depth: 0)
    }

    private enum Element {
        case value(HDSValue)
        case terminator
    }

    private mutating func readValue(depth: Int) throws -> HDSValue {
        guard case .value(let value) = try readElement(depth: depth) else { throw HDSCodecError.unexpectedTerminator }
        return value
    }

    private mutating func readKey(depth: Int) throws -> Element {
        let element = try readElement(depth: depth)
        if case .value(let key) = element {
            guard case .string = key else { throw HDSCodecError.nonStringKey }
        }
        return element
    }

    private mutating func readElement(depth: Int) throws -> Element {
        let tag = try readByte()
        switch tag {
        case HDSTag.trueValue: return .value(remember(.bool(true)))
        case HDSTag.falseValue: return .value(remember(.bool(false)))
        case HDSTag.terminator: return .terminator
        case HDSTag.null: return .value(.null)
        case HDSTag.uuid:
            let raw = Array(try take(16))   // zero-based (a slice keeps the buffer's indices)
            let uuid = UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                                   raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
            return .value(remember(.uuid(uuid)))
        case HDSTag.date:
            let seconds = Double(bitPattern: try readLittleEndian(UInt64.self))
            return .value(remember(.date(Date(timeIntervalSinceReferenceDate: seconds))))
        case HDSTag.minusOne: return .value(remember(.int(-1)))
        case HDSTag.smallIntegers: return .value(remember(.int(Int64(tag - HDSTag.smallIntegers.lowerBound))))
        case HDSTag.int8: return .value(remember(.int(Int64(try readLittleEndian(Int8.self)))))
        case HDSTag.int16: return .value(remember(.int(Int64(try readLittleEndian(Int16.self)))))
        case HDSTag.int32: return .value(remember(.int(Int64(try readLittleEndian(Int32.self)))))
        case HDSTag.int64: return .value(remember(.int(try readLittleEndian(Int64.self))))
        case HDSTag.float32: return .value(remember(.float(Double(Float(bitPattern: try readLittleEndian(UInt32.self))))))
        case HDSTag.float64: return .value(remember(.float(Double(bitPattern: try readLittleEndian(UInt64.self)))))
        case HDSTag.shortString:
            return .value(remember(.string(utf8(try take(Int(tag - HDSTag.shortString.lowerBound))))))
        case HDSTag.prefixedString:
            let length = try readLength(prefixBytes: 1 << Int(tag - HDSTag.prefixedString.lowerBound))
            return .value(remember(.string(utf8(try take(length)))))
        case HDSTag.nulTerminatedString:
            return .value(remember(.string(utf8(try take(upTo: 0x00)))))
        case HDSTag.shortData:
            return .value(remember(.data(Data(try take(Int(tag - HDSTag.shortData.lowerBound))))))
        case HDSTag.prefixedData:
            let length = try readLength(prefixBytes: 1 << Int(tag - HDSTag.prefixedData.lowerBound))
            return .value(remember(.data(Data(try take(length)))))
        case HDSTag.terminatedData:
            return .value(remember(.data(Data(try take(upTo: HDSTag.terminator)))))
        case HDSTag.backReference:
            let reference = Int(tag - HDSTag.backReference.lowerBound)
            guard reference < remembered.count else { throw HDSCodecError.invalidBackReference(reference) }
            return .value(remembered[reference])
        case HDSTag.countedArray:
            guard depth < HDSCodec.maximumDepth else { throw HDSCodecError.nestingTooDeep }
            var items: [HDSValue] = []
            for _ in 0..<Int(tag - HDSTag.countedArray.lowerBound) { items.append(try readValue(depth: depth + 1)) }
            return .value(.array(items))
        case HDSTag.terminatedArray:
            guard depth < HDSCodec.maximumDepth else { throw HDSCodecError.nestingTooDeep }
            var items: [HDSValue] = []
            while case .value(let item) = try readElement(depth: depth + 1) { items.append(item) }
            return .value(.array(items))
        case HDSTag.countedDictionary:
            guard depth < HDSCodec.maximumDepth else { throw HDSCodecError.nestingTooDeep }
            var pairs: [(String, HDSValue)] = []
            for _ in 0..<Int(tag - HDSTag.countedDictionary.lowerBound) {
                guard case .value(.string(let key)) = try readKey(depth: depth + 1) else { throw HDSCodecError.unexpectedTerminator }
                pairs.append((key, try readValue(depth: depth + 1)))
            }
            return .value(.dictionary(HDSDictionary(pairs)))
        case HDSTag.terminatedDictionary:
            guard depth < HDSCodec.maximumDepth else { throw HDSCodecError.nestingTooDeep }
            var pairs: [(String, HDSValue)] = []
            while case .value(.string(let key)) = try readKey(depth: depth + 1) {
                pairs.append((key, try readValue(depth: depth + 1)))
            }
            return .value(.dictionary(HDSDictionary(pairs)))
        default:
            throw HDSCodecError.invalidTag(tag)   // 0x00, 0x34, 0x37–0x3F, 0x65–0x6E, 0x95–0x9E, 0xF0–0xFF
        }
    }

    private mutating func remember(_ value: HDSValue) -> HDSValue {
        remembered.append(value)
        return value
    }

    private mutating func readByte() throws -> UInt8 {
        guard index < bytes.count else { throw HDSCodecError.truncated }
        defer { index += 1 }
        return bytes[index]
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count <= remaining else { throw HDSCodecError.truncated }
        defer { index += count }
        return bytes[index..<(index + count)]
    }

    /// Bytes up to (not including) `terminator`, which is consumed.
    private mutating func take(upTo terminator: UInt8) throws -> ArraySlice<UInt8> {
        guard let end = bytes[index...].firstIndex(of: terminator) else { throw HDSCodecError.truncated }
        defer { index = end + 1 }
        return bytes[index..<end]
    }

    private mutating func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let raw = try take(MemoryLayout<T>.size)
        return raw.reversed().reduce(T.zero) { $0 << 8 | T(truncatingIfNeeded: $1) }
    }

    /// Unsigned 1/2/4/8-byte little-endian length; never larger than the remaining input.
    private mutating func readLength(prefixBytes: Int) throws -> Int {
        let raw = try take(prefixBytes)
        let length = raw.reversed().reduce(UInt64.zero) { $0 << 8 | UInt64($1) }
        guard length <= UInt64(remaining) else { throw HDSCodecError.truncated }
        return Int(length)
    }

    /// Invalid sequences become U+FFFD, like HAP-NodeJS (`Buffer.toString("utf8")`).
    private func utf8(_ raw: ArraySlice<UInt8>) -> String {
        String(decoding: raw, as: UTF8.self)
    }
}
