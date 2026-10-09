// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// The setup URI and setup hash (`sh`) algorithms follow HAP-NodeJS `Accessory.setupURI()` and
// `CiaoAdvertiser.computeSetupHash()` as summarised in research brief §3.3.

import Crypto
import Foundation

/// Accessory device identifier, `AA:BB:CC:DD:EE:FF` (always uppercase).
public struct DeviceID: Sendable, Hashable, Codable, CustomStringConvertible {
    private let value: String

    public init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) && $0.allSatisfy(\.isASCII) }) else {
            return nil
        }
        value = string.uppercased()
    }

    public static func random() -> DeviceID {
        var generator = SystemRandomNumberGenerator()
        let text = (0..<6).map { _ in String(format: "%02X", UInt8.random(in: 0...255, using: &generator)) }.joined(separator: ":")
        guard let id = DeviceID(text) else { preconditionFailure("generated device ID is always well-formed") }
        return id
    }

    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = DeviceID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid device ID"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// HAP setup code. `formatted` (`XXX-XX-XXX`) is the SRP password.
public struct SetupCode: Sendable, Hashable, Codable, CustomStringConvertible {
    /// "12345678"
    public let digits: String

    /// Accepts "12345678" or "123-45-678".
    public init?(_ string: String) {
        let raw: String
        if string.count == 10 {
            let chars = Array(string)
            guard chars[3] == "-", chars[6] == "-" else { return nil }
            raw = String(chars[0..<3] + chars[4..<6] + chars[7..<10])
        } else {
            raw = string
        }
        guard raw.count == 8, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        digits = raw
    }

    /// A random code that is never trivial.
    public static func random() -> SetupCode {
        var generator = SystemRandomNumberGenerator()
        while true {
            let text = String(format: "%08u", UInt32.random(in: 0...99_999_999, using: &generator))
            if let code = SetupCode(text), !code.isTrivial { return code }
        }
    }

    /// "123-45-678"
    public var formatted: String {
        let chars = Array(digits)
        return String(chars[0..<3]) + "-" + String(chars[3..<5]) + "-" + String(chars[5..<8])
    }

    /// All-same digits, or a run of consecutive ascending/descending digits (12345678, 87654321, 01234567, …).
    public var isTrivial: Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == 8 else { return true }
        let steps = zip(values.dropFirst(), values).map { $0 - $1 }
        return steps.allSatisfy { $0 == 0 } || steps.allSatisfy { $0 == 1 } || steps.allSatisfy { $0 == -1 }
    }

    public var description: String { formatted }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let code = SetupCode(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid setup code"))
        }
        self = code
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(formatted)
    }
}

public enum AccessoryCategory: UInt16, Sendable, Codable {
    case other = 1, bridge = 2, sensor = 10, ipCamera = 17, videoDoorbell = 18
}

public enum SetupPayload {
    /// `X-HM://` setup URI (IP transport flag) for QR codes. Goldens in research brief §3.3.
    public static func uri(code: SetupCode, setupID: String, category: AccessoryCategory) -> String {
        let codeValue = UInt64(code.digits) ?? 0
        let categoryValue = UInt64(category.rawValue)
        let low = codeValue | (1 << 28) | ((categoryValue & 1) << 31)
        let high = categoryValue >> 1
        let payload = (high << 32) | low
        var encoded = String(payload, radix: 36, uppercase: true)
        if encoded.count < 9 { encoded = String(repeating: "0", count: 9 - encoded.count) + encoded }
        return "X-HM://" + encoded + setupID
    }

    /// mDNS TXT `sh`: base64(SHA-512(setupID ‖ uppercase deviceID)[0..<4]).
    public static func setupHash(setupID: String, deviceID: DeviceID) -> String {
        let digest = SHA512.hash(data: Data((setupID + deviceID.description.uppercased()).utf8))
        return Data(digest.prefix(4)).base64EncodedString()
    }

    /// 4 characters from [0-9A-Z].
    public static func randomSetupID() -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var generator = SystemRandomNumberGenerator()
        return String((0..<4).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }
}
