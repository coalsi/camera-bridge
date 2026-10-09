import Foundation

public enum HAPFormat: String, Sendable, Codable {
    case bool, uint8, uint16, uint32, uint64, int, float, string, tlv8, data
}

public struct HAPPermissions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let pairedRead = HAPPermissions(rawValue: 1 << 0)
    public static let pairedWrite = HAPPermissions(rawValue: 1 << 1)
    public static let events = HAPPermissions(rawValue: 1 << 2)
    public static let additionalAuthorization = HAPPermissions(rawValue: 1 << 3)
    public static let timedWrite = HAPPermissions(rawValue: 1 << 4)
    public static let hidden = HAPPermissions(rawValue: 1 << 5)
    public static let writeResponse = HAPPermissions(rawValue: 1 << 6)

    /// JSON `perms` strings in canonical order: pr, pw, ev, aa, tw, hd, wr.
    public var jsonStrings: [String] {
        let table: [(HAPPermissions, String)] = [
            (.pairedRead, "pr"), (.pairedWrite, "pw"), (.events, "ev"), (.additionalAuthorization, "aa"),
            (.timedWrite, "tw"), (.hidden, "hd"), (.writeResponse, "wr"),
        ]
        return table.filter { contains($0.0) }.map(\.1)
    }
}

public enum HAPUnit: String, Sendable {
    case celsius, percentage, arcdegrees, lux, seconds
}

/// A characteristic value. `tlv8` and `data` formats use `.data`.
public enum HAPValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case data(Data)

    /// Bools, and integers as `!= 0`.
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .int(let i): i != 0
        case .uint(let u): u != 0
        default: nil
        }
    }

    /// Signed/unsigned integers (when representable) and bools as 0/1.
    public var intValue: Int64? {
        switch self {
        case .int(let i): i
        case .uint(let u): u <= UInt64(Int64.max) ? Int64(u) : nil
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }

    /// Floats and integers.
    public var doubleValue: Double? {
        switch self {
        case .float(let d): d
        case .int(let i): Double(i)
        case .uint(let u): Double(u)
        default: nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var dataValue: Data? {
        if case .data(let d) = self { return d }
        return nil
    }
}

public enum HAPStatus: Int, Error, Sendable {
    case success = 0
    case insufficientPrivileges = -70401, serviceCommunicationFailure = -70402, resourceBusy = -70403
    case readOnly = -70404, writeOnly = -70405, notificationNotSupported = -70406, outOfResource = -70407
    case operationTimedOut = -70408, resourceDoesNotExist = -70409, invalidValue = -70410
    case insufficientAuthorization = -70411, notAllowedInCurrentState = -70412
}

/// Apple base UUID suffix for short-form HAP types.
let hapBaseUUIDSuffix = "-0000-1000-8000-0026BB765291"

func hapFullUUID(_ uuid: String) -> String {
    if uuid.count <= 8, uuid.allSatisfy(\.isHexDigit) {
        return String(repeating: "0", count: 8 - uuid.count) + uuid.uppercased() + hapBaseUUIDSuffix
    }
    return uuid.uppercased()
}
