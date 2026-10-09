import Foundation

/// A tolerant, `Sendable` JSON tree for vendor APIs whose shapes vary by firmware (Reolink).
enum JSONValue: Sendable, Equatable, Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value):
            if Self.isExactInteger(value) { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    /// Integral doubles up to 2^53 print without a fraction (`42`, not `42.0`); anything else (fractions, huge or
    /// non-finite numbers) prints as a `Double`, so camera-supplied numbers can never trap an `Int64` conversion.
    var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value): Self.isExactInteger(value) ? String(Int64(value)) : String(value)
        default: nil
        }
    }

    /// 2^53: every integral double below it converts to `Int64` exactly.
    static let maximumExactInteger = 9_007_199_254_740_992.0

    static func isExactInteger(_ value: Double) -> Bool {
        value.isFinite && value.rounded() == value && abs(value) < maximumExactInteger
    }

    var double: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        case .bool(let value): value ? 1 : 0
        default: nil
        }
    }

    var int: Int? {
        guard let double, double.isFinite, abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    /// Numbers/strings/bools as a flag (`1`, `true`, `"1"`).
    var flag: Bool? { double.map { $0 != 0 } }

    var object: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}
