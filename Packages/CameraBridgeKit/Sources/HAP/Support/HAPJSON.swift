import Foundation

public enum HAPJSONError: Error, Equatable, Sendable {
    case invalid(offset: Int)
    case tooDeep
}

/// A JSON value with the distinctions HAP needs (integer vs float vs bool, ordered object members) and a
/// deterministic serializer (`sortedKeys` for the configuration hash). Portable: no JSONSerialization / NSNumber.
public enum HAPJSON: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    /// Only for integers above `Int64.max`.
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([HAPJSON])
    case object(HAPJSONObject)

    // MARK: Accessors

    public subscript(key: String) -> HAPJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> HAPJSON? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var arrayValue: [HAPJSON]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var objectValue: HAPJSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    /// Integers, and doubles with an integral value that fits.
    public var intValue: Int64? {
        switch self {
        case .int(let value): value
        case .uint(let value): value <= UInt64(Int64.max) ? Int64(value) : nil
        case .double(let value): (value.rounded() == value && abs(value) < 9.2e18) ? Int64(value) : nil
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .uint(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    /// An unsigned integer (aid, iid) as `.int` when it fits, else `.uint`.
    static func unsigned(_ value: UInt64) -> HAPJSON {
        value <= UInt64(Int64.max) ? .int(Int64(value)) : .uint(value)
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var isNumber: Bool {
        switch self {
        case .int, .uint, .double: true
        default: false
        }
    }
}

/// Ordered JSON object. Equality ignores member order.
public struct HAPJSONObject: Sendable, Equatable {
    public private(set) var pairs: [(key: String, value: HAPJSON)]

    public init(_ pairs: [(String, HAPJSON)] = []) {
        self.pairs = pairs.map { (key: $0.0, value: $0.1) }
    }

    public var keys: [String] { pairs.map(\.key) }

    public subscript(key: String) -> HAPJSON? {
        get { pairs.first { $0.key == key }?.value }
        set {
            if let index = pairs.firstIndex(where: { $0.key == key }) {
                if let newValue { pairs[index].value = newValue } else { pairs.remove(at: index) }
            } else if let newValue {
                pairs.append((key: key, value: newValue))
            }
        }
    }

    public static func == (lhs: HAPJSONObject, rhs: HAPJSONObject) -> Bool {
        guard lhs.pairs.count == rhs.pairs.count else { return false }
        for (key, value) in lhs.pairs {
            guard let other = rhs[key], other == value else { return false }
        }
        return true
    }
}

extension HAPJSON: Equatable {
    /// Numbers compare by value across `int`/`uint`/`double`.
    public static func == (lhs: HAPJSON, rhs: HAPJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.uint(let a), .uint(let b)): return a == b
        case (.int(let a), .uint(let b)), (.uint(let b), .int(let a)): return a >= 0 && UInt64(a) == b
        default:
            if lhs.isNumber, rhs.isNumber, let a = lhs.doubleValue, let b = rhs.doubleValue { return a == b }
            return false
        }
    }
}

extension HAPJSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: HAPJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, HAPJSON)...) { self = .object(HAPJSONObject(elements)) }
}

// MARK: - Serialization

extension HAPJSON {
    /// Compact UTF-8 JSON. `sortedKeys` orders object members by key (canonical form).
    public func serialized(sortedKeys: Bool = false) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        write(into: &out, sortedKeys: sortedKeys)
        return Data(out)
    }

    private func write(into out: inout [UInt8], sortedKeys: Bool) {
        switch self {
        case .null:
            out += Array("null".utf8)
        case .bool(let value):
            out += Array((value ? "true" : "false").utf8)
        case .int(let value):
            out += Array(String(value).utf8)
        case .uint(let value):
            out += Array(String(value).utf8)
        case .double(let value):
            out += Array(Self.format(value).utf8)
        case .string(let value):
            Self.writeString(value, into: &out)
        case .array(let values):
            out.append(UInt8(ascii: "["))
            for (index, value) in values.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                value.write(into: &out, sortedKeys: sortedKeys)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let object):
            out.append(UInt8(ascii: "{"))
            let pairs = sortedKeys ? object.pairs.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) } : object.pairs
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                Self.writeString(pair.key, into: &out)
                out.append(UInt8(ascii: ":"))
                pair.value.write(into: &out, sortedKeys: sortedKeys)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    /// Shortest round-trip form; integral values without a fraction; non-finite values as `null`.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    private static func writeString(_ string: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out += [UInt8(ascii: "\\"), UInt8(ascii: "\"")]
            case UInt8(ascii: "\\"): out += [UInt8(ascii: "\\"), UInt8(ascii: "\\")]
            case 0x0A: out += [UInt8(ascii: "\\"), UInt8(ascii: "n")]
            case 0x0D: out += [UInt8(ascii: "\\"), UInt8(ascii: "r")]
            case 0x09: out += [UInt8(ascii: "\\"), UInt8(ascii: "t")]
            case 0x00..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                out += [UInt8(ascii: "\\"), UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"), hex[Int(byte >> 4)], hex[Int(byte & 0xF)]]
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

// MARK: - Parsing

extension HAPJSON {
    static let maximumDepth = 64

    /// Strict RFC 8259 parser (UTF-8, one top-level value, no trailing garbage, nesting ≤ 64).
    public static func parse(_ data: Data) throws(HAPJSONError) -> HAPJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw .invalid(offset: parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
        }

        func fail() -> HAPJSONError { .invalid(offset: index) }

        mutating func expect(_ literal: String) throws(HAPJSONError) {
            for byte in literal.utf8 {
                guard current == byte else { throw fail() }
                index += 1
            }
        }

        mutating func parseValue(depth: Int) throws(HAPJSONError) -> HAPJSON {
            guard depth < HAPJSON.maximumDepth else { throw .tooDeep }
            guard let byte = current else { throw fail() }
            switch byte {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"):
                try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return try parseNumber()
            default:
                throw fail()
            }
        }

        mutating func parseObject(depth: Int) throws(HAPJSONError) -> HAPJSON {
            index += 1
            var object = HAPJSONObject()
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\"") else { throw fail() }
                let key = try parseString()
                skipWhitespace()
                guard current == UInt8(ascii: ":") else { throw fail() }
                index += 1
                skipWhitespace()
                object[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard let byte = current else { throw fail() }
                index += 1
                if byte == UInt8(ascii: "}") { return .object(object) }
                guard byte == UInt8(ascii: ",") else { throw fail() }
            }
        }

        mutating func parseArray(depth: Int) throws(HAPJSONError) -> HAPJSON {
            index += 1
            var values: [HAPJSON] = []
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            while true {
                skipWhitespace()
                values.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard let byte = current else { throw fail() }
                index += 1
                if byte == UInt8(ascii: "]") { return .array(values) }
                guard byte == UInt8(ascii: ",") else { throw fail() }
            }
        }

        mutating func parseHex4() throws(HAPJSONError) -> UInt32 {
            guard index + 4 <= bytes.count else { throw fail() }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw fail()
                }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        mutating func parseString() throws(HAPJSONError) -> String {
            index += 1   // opening quote
            var out: [UInt8] = []
            while true {
                guard let byte = current else { throw fail() }
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let string = String(validating: out, as: UTF8.self) else { throw fail() }
                    return string
                case UInt8(ascii: "\\"):
                    guard let escape = current else { throw fail() }
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                    case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                    case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try parseHex4()
                        if (0xD800...0xDBFF).contains(scalar) {
                            guard current == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") else { throw fail() }
                            index += 2
                            let low = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw fail() }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(scalar) {
                            throw fail()
                        }
                        guard let unicode = Unicode.Scalar(scalar) else { throw fail() }
                        out += Array(String(Character(unicode)).utf8)
                    default:
                        throw fail()
                    }
                case 0x00..<0x20:
                    throw fail()
                default:
                    out.append(byte)
                }
            }
        }

        mutating func parseNumber() throws(HAPJSONError) -> HAPJSON {
            let start = index
            if current == UInt8(ascii: "-") { index += 1 }
            guard let first = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { throw fail() }
            if first == UInt8(ascii: "0") {
                index += 1
            } else {
                while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
            }
            var isInteger = true
            if current == UInt8(ascii: ".") {
                isInteger = false
                index += 1
                guard let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { throw fail() }
                while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                isInteger = false
                index += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
                guard let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { throw fail() }
                while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if isInteger {
                if let value = Int64(text) { return .int(value) }
                if let value = UInt64(text) { return .uint(value) }
            }
            guard let value = Double(text), value.isFinite else { throw fail() }
            return .double(value)
        }
    }
}
