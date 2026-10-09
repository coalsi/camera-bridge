import Foundation

/// HAP TLV8 (type, 1-byte length, value). Values longer than 255 bytes are carried as consecutive items of the
/// same type; every fragment but the last is exactly 255 bytes long.
public enum TLV8 {
    public struct Item: Sendable, Equatable {
        public var type: UInt8
        public var value: Data
        public init(_ type: UInt8, _ value: Data) {
            self.type = type
            self.value = value
        }
    }

    /// Encodes items in order, splitting values longer than 255 bytes into consecutive same-type items.
    public static func encode(_ items: [Item]) -> Data {
        var out = Data()
        for item in items {
            let value = item.value
            if value.isEmpty {
                out.append(item.type)
                out.append(0)
                continue
            }
            var offset = value.startIndex
            while offset < value.endIndex {
                let length = min(255, value.endIndex - offset)
                out.append(item.type)
                out.append(UInt8(length))
                out.append(value[offset..<(offset + length)])
                offset += length
            }
        }
        return out
    }

    /// Decodes items in order. A 255-byte item followed by an item of the same type is a fragment and is merged
    /// with it; every other item (including separators) is returned as-is.
    public static func decode(_ data: Data) throws(TLV8Error) -> [Item] {
        var items: [Item] = []
        var index = data.startIndex
        var lastWasFullFragment = false
        while index < data.endIndex {
            guard data.endIndex - index >= 2 else { throw .truncated }
            let type = data[index]
            let length = Int(data[index + 1])
            let valueStart = index + 2
            guard data.endIndex - valueStart >= length else { throw .invalidLength(type) }
            let value = data[valueStart..<(valueStart + length)]
            if lastWasFullFragment, let last = items.last, last.type == type {
                items[items.count - 1].value.append(value)
            } else {
                items.append(Item(type, Data(value)))
            }
            lastWasFullFragment = length == 255
            index = valueStart + length
        }
        return items
    }

    /// Splits a list at separator items (`FF 00` for pairing lists; camera TLVs use `00 00`).
    /// Empty groups are dropped.
    public static func splitList(_ items: [Item], separator: UInt8 = 0xFF) -> [[Item]] {
        var groups: [[Item]] = []
        var current: [Item] = []
        for item in items {
            if item.type == separator && item.value.isEmpty {
                if !current.isEmpty { groups.append(current) }
                current = []
            } else {
                current.append(item)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}

public enum TLV8Error: Error, Equatable {
    case truncated
    case missing(UInt8)
    case invalidLength(UInt8)
}

/// Ordered TLV8 builder. Scalars are little-endian as HAP requires.
public struct TLVBuilder: Sendable {
    public private(set) var items: [TLV8.Item] = []

    public init() {}

    public mutating func add(_ type: UInt8, _ value: Data) { items.append(TLV8.Item(type, value)) }
    public mutating func add(_ type: UInt8, uint8: UInt8) { add(type, Data([uint8])) }
    public mutating func add(_ type: UInt8, uint16LE: UInt16) { add(type, Self.littleEndian(uint16LE)) }
    public mutating func add(_ type: UInt8, uint32LE: UInt32) { add(type, Self.littleEndian(uint32LE)) }
    public mutating func add(_ type: UInt8, uint64LE: UInt64) { add(type, Self.littleEndian(uint64LE)) }
    public mutating func add(_ type: UInt8, float32LE: Float) { add(type, Self.littleEndian(float32LE.bitPattern)) }
    public mutating func add(_ type: UInt8, string: String) { add(type, Data(string.utf8)) }
    public mutating func add(_ type: UInt8, tlv: TLVBuilder) { add(type, tlv.data) }

    /// Pairing-style list separator `FF 00`.
    public mutating func addSeparator() { addSeparator(type: 0xFF) }

    /// List separator with an explicit type (camera configuration TLVs use `00 00`).
    public mutating func addSeparator(type: UInt8) { add(type, Data()) }

    public var data: Data { TLV8.encode(items) }

    static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

/// Read access to decoded TLV8 items.
public struct TLVReader: Sendable {
    public let items: [TLV8.Item]

    public init(_ data: Data) throws(TLV8Error) {
        items = try TLV8.decode(data)
    }

    public init(items: [TLV8.Item]) {
        self.items = items
    }

    /// First item of `type`.
    public func data(_ type: UInt8) -> Data? { items.first { $0.type == type }?.value }

    public func all(_ type: UInt8) -> [Data] { items.filter { $0.type == type }.map(\.value) }

    public func uint8(_ type: UInt8) -> UInt8? {
        guard let d = data(type), d.count == 1, let byte = d.first else { return nil }
        return byte
    }

    /// Accepts 1- or 2-byte encodings.
    public func uint16LE(_ type: UInt8) -> UInt16? { unsigned(type, allowed: [1, 2]).map { UInt16(truncatingIfNeeded: $0) } }

    /// Accepts 1-, 2- or 4-byte encodings.
    public func uint32LE(_ type: UInt8) -> UInt32? { unsigned(type, allowed: [1, 2, 4]).map { UInt32(truncatingIfNeeded: $0) } }

    /// Accepts 1-, 2-, 4- or 8-byte encodings.
    public func uint64LE(_ type: UInt8) -> UInt64? { unsigned(type, allowed: [1, 2, 4, 8]) }

    public func float32LE(_ type: UInt8) -> Float? {
        guard let d = data(type), d.count == 4 else { return nil }
        let bits = d.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Float(bitPattern: bits)
    }

    public func string(_ type: UInt8) -> String? {
        guard let d = data(type) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// The value of `type` decoded as a nested TLV, or nil when absent.
    public func nested(_ type: UInt8) throws(TLV8Error) -> TLVReader? {
        guard let d = data(type) else { return nil }
        return try TLVReader(d)
    }

    public func require(_ type: UInt8) throws(TLV8Error) -> Data {
        guard let d = data(type) else { throw .missing(type) }
        return d
    }

    private func unsigned(_ type: UInt8, allowed: Set<Int>) -> UInt64? {
        guard let d = data(type), allowed.contains(d.count) else { return nil }
        return d.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}
