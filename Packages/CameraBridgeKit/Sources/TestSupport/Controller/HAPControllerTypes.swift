import BridgeSupport
import Foundation
import HAP
import HAPCore

/// A controller's long-term identity: pairing identifier + Ed25519 key (research brief §3.2).
/// `longTermKey` is secret: never log it; `HAPControllerStore` keeps it in a 0600 file.
public struct HAPControllerIdentity: Sendable, Codable, Hashable {
    public var pairingID: String
    public var longTermKey: Data

    public init(pairingID: String, longTermKey: Data) {
        self.pairingID = pairingID
        self.longTermKey = longTermKey
    }

    /// A fresh identity: an uppercase UUID string as pairing ID and a new Ed25519 key.
    public static func generate() -> HAPControllerIdentity {
        HAPControllerIdentity(pairingID: UUID().uuidString, longTermKey: HAPLongTermKey().rawRepresentation)
    }

    public func key() throws -> HAPLongTermKey { try HAPLongTermKey(rawRepresentation: longTermKey) }

    public var publicKey: Data { (try? key().publicKey) ?? Data() }
}

/// What pair-setup M6 tells the controller about the accessory (needed for every pair-verify).
public struct HAPAccessoryPairing: Sendable, Codable, Hashable {
    /// The accessory's device ID ("AA:BB:CC:DD:EE:FF").
    public var accessoryPairingID: String
    public var accessoryLongTermPublicKey: Data

    public init(accessoryPairingID: String, accessoryLongTermPublicKey: Data) {
        self.accessoryPairingID = accessoryPairingID
        self.accessoryLongTermPublicKey = accessoryLongTermPublicKey
    }
}

public enum HAPControllerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The connection closed (or was closed) before the answer arrived.
    case closed
    case timedOut
    /// Pair-verify or a pairing-dependent call without a known accessory pairing.
    case notPaired
    /// Pair-setup / pair-verify / pairings step `step` failed; `error` is the accessory's kTLVType_Error, if any.
    case pairing(step: Int, error: UInt8?)
    /// An HTTP status other than the expected one (with the HAP `status` from the JSON body, if any).
    case httpStatus(Int, hapStatus: Int?)
    /// A per-characteristic HAP status (e.g. -70410) for aid.iid.
    case characteristicStatus(aid: UInt64, iid: UInt64, status: Int)
    case malformedResponse(String)
    case notFound(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .closed: "connection closed"
        case .timedOut: "timed out"
        case .notPaired: "not paired with this accessory"
        case .pairing(let step, let error): "pairing failed at M\(step)" + (error.map { " (kTLVError \($0))" } ?? "")
        case .httpStatus(let status, let hapStatus): "HTTP \(status)" + (hapStatus.map { " (HAP status \($0))" } ?? "")
        case .characteristicStatus(let aid, let iid, let status): "characteristic \(aid).\(iid): HAP status \(status)"
        case .malformedResponse(let what): "malformed response: \(what)"
        case .notFound(let what): "not found: \(what)"
        case .invalidArgument(let what): "invalid argument: \(what)"
        }
    }
}

/// aid.iid of one characteristic.
public struct HAPCharacteristicID: Sendable, Hashable, Codable, CustomStringConvertible {
    public var aid: UInt64
    public var iid: UInt64

    public init(aid: UInt64, iid: UInt64) {
        self.aid = aid
        self.iid = iid
    }

    public var description: String { "\(aid).\(iid)" }
}

/// One HTTP response or `EVENT/1.0` notification.
public struct HAPControllerResponse: Sendable {
    public var version: String
    public var status: Int
    public var headers: HTTPHeaders
    public var body: Data

    public var isEvent: Bool { version == "EVENT/1.0" }

    public func json() throws -> HAPJSON {
        do {
            return try HAPJSON.parse(body)
        } catch {
            throw HAPControllerError.malformedResponse("JSON body")
        }
    }

    public func tlv() throws -> TLVReader {
        do {
            return try TLVReader(body)
        } catch {
            throw HAPControllerError.malformedResponse("TLV8 body")
        }
    }

    /// The HAP `status` of a JSON error body (`{"status":-70401}`), if any.
    public var hapStatus: Int? {
        guard !body.isEmpty, let json = try? HAPJSON.parse(body), let status = json["status"]?.intValue else { return nil }
        return Int(status)
    }
}

/// A characteristic value change pushed in an `EVENT/1.0` message.
public struct HAPCharacteristicEvent: Sendable, Equatable {
    public var id: HAPCharacteristicID
    public var value: HAPJSON

    public init(id: HAPCharacteristicID, value: HAPJSON) {
        self.id = id
        self.value = value
    }
}

/// One item of a GET /characteristics answer: a value or a HAP status.
public struct HAPCharacteristicReadResult: Sendable, Equatable {
    public var id: HAPCharacteristicID
    public var value: HAPJSON?
    /// 0 unless the accessory reported an error for this item.
    public var status: Int
    /// Present when requested with `ev=1`.
    public var eventsEnabled: Bool?

    public init(id: HAPCharacteristicID, value: HAPJSON?, status: Int, eventsEnabled: Bool? = nil) {
        self.id = id
        self.value = value
        self.status = status
        self.eventsEnabled = eventsEnabled
    }
}

/// One item of a PUT /characteristics request.
public struct HAPCharacteristicWrite: Sendable, Equatable {
    public var id: HAPCharacteristicID
    public var value: HAPJSON?
    public var events: Bool?
    /// `"r": true` — ask for a write-response value (SetupDataStreamTransport).
    public var wantsResponse: Bool

    public init(id: HAPCharacteristicID, value: HAPJSON? = nil, events: Bool? = nil, wantsResponse: Bool = false) {
        self.id = id
        self.value = value
        self.events = events
        self.wantsResponse = wantsResponse
    }

    /// A tlv8/data value (sent base64-encoded).
    public static func data(_ id: HAPCharacteristicID, _ data: Data, wantsResponse: Bool = false) -> HAPCharacteristicWrite {
        HAPCharacteristicWrite(id: id, value: .string(data.base64EncodedString()), wantsResponse: wantsResponse)
    }

    var json: HAPJSON {
        var pairs: [(String, HAPJSON)] = [("aid", jsonUnsigned(id.aid)), ("iid", jsonUnsigned(id.iid))]
        if let value { pairs.append(("value", value)) }
        if let events { pairs.append(("ev", .bool(events))) }
        if wantsResponse { pairs.append(("r", .bool(true))) }
        return .object(HAPJSONObject(pairs))
    }
}

/// One item of a PUT /characteristics answer (204 → every status 0, no values).
public struct HAPCharacteristicWriteResult: Sendable, Equatable {
    public var id: HAPCharacteristicID
    public var status: Int
    /// The write-response value (`"r": true`).
    public var value: HAPJSON?

    public init(id: HAPCharacteristicID, status: Int, value: HAPJSON? = nil) {
        self.id = id
        self.status = status
        self.value = value
    }
}

/// An entry of the accessory's pairing list (`/pairings` List).
public struct HAPPairingEntry: Sendable, Equatable {
    public var identifier: String
    public var publicKey: Data
    public var isAdmin: Bool

    public init(identifier: String, publicKey: Data, isAdmin: Bool) {
        self.identifier = identifier
        self.publicKey = publicKey
        self.isAdmin = isAdmin
    }
}

func jsonUnsigned(_ value: UInt64) -> HAPJSON {
    value <= UInt64(Int64.max) ? .int(Int64(value)) : .uint(value)
}

extension HAPJSON {
    /// A non-negative JSON integer as UInt64.
    var unsignedValue: UInt64? {
        switch self {
        case .int(let value): value >= 0 ? UInt64(value) : nil
        case .uint(let value): value
        case .double(let value): (value >= 0 && value.rounded() == value && value < 1.8e19) ? UInt64(value) : nil
        default: nil
        }
    }

    /// A base64 string value (tlv8/data characteristics) as bytes.
    public var base64Data: Data? {
        guard case .string(let text) = self else { return nil }
        return Data(base64Encoded: text)
    }

    /// A bool characteristic value, which HAP accessories send as 0/1 or true/false.
    public var hapBool: Bool? {
        switch self {
        case .bool(let value): value
        case .int(let value) where value == 0 || value == 1: value == 1
        case .double(let value) where value == 0 || value == 1: value == 1
        default: nil
        }
    }
}
