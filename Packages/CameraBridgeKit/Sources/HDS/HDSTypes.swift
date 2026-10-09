import Foundation

/// Ordered dictionary: encoding order matters on the wire (goldens), so equality is order-sensitive — two
/// dictionaries are equal when they hold the same (key, value) pairs in the same order. Duplicate keys can only come
/// from a decoder (`pairs` keeps them all); like a HAP-NodeJS (JavaScript) object, the `subscript` reads the last
/// value, and setting the key keeps a single entry at the first one's position.
public struct HDSDictionary: Sendable, Equatable, Sequence {
    public private(set) var pairs: [(String, HDSValue)]

    public init(_ pairs: [(String, HDSValue)] = []) {
        self.pairs = pairs
    }

    /// Get: last value for `key`. Set: replaces in place (at the first occurrence, dropping later duplicates),
    /// appends new keys, `nil` removes every occurrence.
    public subscript(key: String) -> HDSValue? {
        get { pairs.last { $0.0 == key }?.1 }
        set {
            guard let newValue else {
                pairs.removeAll { $0.0 == key }
                return
            }
            guard let index = pairs.firstIndex(where: { $0.0 == key }) else {
                pairs.append((key, newValue))
                return
            }
            pairs[index].1 = newValue
            let rest = pairs.index(after: index)
            if pairs[rest...].contains(where: { $0.0 == key }) {
                pairs.replaceSubrange(rest..., with: pairs[rest...].filter { $0.0 != key })
            }
        }
    }

    public var count: Int { pairs.count }

    public func makeIterator() -> IndexingIterator<[(String, HDSValue)]> {
        pairs.makeIterator()
    }

    public static func == (lhs: HDSDictionary, rhs: HDSDictionary) -> Bool {
        lhs.pairs.count == rhs.pairs.count && zip(lhs.pairs, rhs.pairs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

public indirect enum HDSValue: Sendable, Equatable {
    case null, bool(Bool), int(Int64), float(Double), string(String), data(Data), uuid(UUID), date(Date)
    case array([HDSValue]), dictionary(HDSDictionary)
}

public enum HDSStatus: Int64, Sendable {
    case success = 0, outOfMemory, timeout, headerError, payloadError, missingProtocol, protocolSpecificError
}

public enum HDSProtocolReason: Int64, Sendable, Error {
    case normal = 0, notAllowed, busy, cancelled, unsupported, unexpectedFailure, timeout, badData, protocolError, invalidConfiguration
}

public struct HDSMessage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case event
        case request(id: Int64)
        case response(id: Int64, status: HDSStatus)
    }

    public var kind: Kind
    public var protocolName: String
    public var topic: String
    public var body: HDSDictionary

    public init(kind: Kind, protocolName: String, topic: String, body: HDSDictionary = HDSDictionary()) {
        self.kind = kind
        self.protocolName = protocolName
        self.topic = topic
        self.body = body
    }
}

/// Malformed HDS-encoded values (`HDSCodec.decode`) or values too deeply nested to encode.
public enum HDSCodecError: Error, Equatable, Sendable {
    /// The input ended inside a value (including a length prefix larger than the remaining bytes).
    case truncated
    /// 0x00 or an unassigned tag.
    case invalidTag(UInt8)
    /// 0x03 where a value was expected (top level, count-form containers, dictionary values).
    case unexpectedTerminator
    /// A back-reference (0xA0–0xCF) to a value index that was not decoded (yet).
    case invalidBackReference(Int)
    /// A dictionary key that is not a string.
    case nonStringKey
    /// More than `HDSCodec.maximumDepth` nested arrays/dictionaries.
    case nestingTooDeep
    /// `HDSCodec.decode` found bytes after the first complete value.
    case trailingBytes(Int)
}

/// Frame and payload codec errors (`HDSFrameCodec`).
public enum HDSFrameError: Error, Equatable, Sendable {
    /// Keys must be 32 bytes (ChaCha20-Poly1305).
    case invalidKeyLength
    /// The frame header is not 4 bytes.
    case invalidFrameHeader
    case unsupportedFrameType(UInt8)
    /// Payload longer than `HDSFrameCodec.maximumPayloadLength` (0xFFFFF).
    case payloadTooLarge(Int)
    /// The body is not the header's length plus the 16-byte tag.
    case lengthMismatch
    /// Wrong key, wrong counter, or tampered header/ciphertext/tag.
    case authenticationFailed
    /// The encoded payload header exceeds 255 bytes (its length is a single byte).
    case headerTooLong(Int)
    /// The payload is empty or shorter than its header-length byte says.
    case truncatedPayload
    /// A header that is not a dictionary ("header") or lacks a valid field ("protocol", "topic", "id", "status").
    case invalidHeader(String)
    case invalidStatus(Int64)
    /// The message part is not a dictionary.
    case invalidMessage
    /// The header or message failed to decode.
    case codec(HDSCodecError)
}

/// Errors from `DataStreamConnection` / `DataStreamServer`.
public enum HDSConnectionError: Error, Equatable, Sendable {
    /// The connection (or server) is closed; queued and pending operations fail with this.
    case closed
    /// No response to `sendRequest` within its timeout (the connection is closed, brief §3.8).
    case timeout
    /// `sendResponse(to:)` was given a message that is not a request.
    case notARequest
}
