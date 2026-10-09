// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// (Frame layout, key derivation and payload headers from lib/datastream/DataStreamServer.ts; research brief §3.8.)

import Foundation
import HAPCore

/// Frame and payload codec; public so TestSupport can build an HDS client.
///
/// - Keys: HKDF-SHA512 over the pair-verify shared secret, salt = controllerKeySalt ‖ accessoryKeySalt, info
///   `HDS-Read-Encryption-Key` (accessory→controller) / `HDS-Write-Encryption-Key` (controller→accessory), 32 bytes.
/// - Frame: `[0x01][payload length, 24-bit BE][ChaCha20-Poly1305 ciphertext][16-byte tag]`; AAD = the 4-byte header;
///   nonce = `00000000 ‖ LE64(counter)`, one counter per direction starting at 0. Payload ≤ 0xFFFFF bytes.
/// - Payload: `[header length u8][header][message]`, both encoded dictionaries. Headers: event `{protocol, event}`,
///   request `{protocol, request, id}`, response `{protocol, response, id, status}`; `id`/`status` are written as int64.
public enum HDSFrameCodec {
    public static let maximumPayloadLength = 0xFFFFF
    static let frameType: UInt8 = 0x01
    static let headerLength = 4
    static let tagLength = 16

    static let accessoryToControllerInfo = "HDS-Read-Encryption-Key"
    static let controllerToAccessoryInfo = "HDS-Write-Encryption-Key"

    public static func deriveKeys(sharedSecret: Data, controllerKeySalt: Data, accessoryKeySalt: Data) -> (accessoryToController: Data, controllerToAccessory: Data) {
        let salt = controllerKeySalt + accessoryKeySalt
        return (HAPCrypto.hkdfSHA512(inputKey: sharedSecret, salt: salt, info: accessoryToControllerInfo),
                HAPCrypto.hkdfSHA512(inputKey: sharedSecret, salt: salt, info: controllerToAccessoryInfo))
    }

    public static func encodePayload(_ message: HDSMessage) throws -> Data {
        var header = HDSWriter()
        switch message.kind {
        case .event:
            header.writeDictionaryHeader(count: 2)
            writeNames(message, topicKey: "event", into: &header)
        case .request(let id):
            header.writeDictionaryHeader(count: 3)
            writeNames(message, topicKey: "request", into: &header)
            header.writeString("id")
            header.writeInt64(id)
        case .response(let id, let status):
            header.writeDictionaryHeader(count: 4)
            writeNames(message, topicKey: "response", into: &header)
            header.writeString("id")
            header.writeInt64(id)
            header.writeString("status")
            header.writeInt64(status.rawValue)
        }
        guard header.count <= Int(UInt8.max) else { throw HDSFrameError.headerTooLong(header.count) }
        let body = try HDSCodec.encode(.dictionary(message.body))
        var payload = Data(capacity: 1 + header.count + body.count)
        payload.append(UInt8(header.count))
        payload.append(contentsOf: header.bytes)
        payload.append(body)
        return payload
    }

    private static func writeNames(_ message: HDSMessage, topicKey: String, into header: inout HDSWriter) {
        header.writeString("protocol")
        header.writeString(message.protocolName)
        header.writeString(topicKey)
        header.writeString(message.topic)
    }

    /// Like HAP-NodeJS, bytes after the header's first value or the message's first value are ignored, and an absent
    /// message part is an empty dictionary. `event` wins over `request` over `response` if a header has several; a
    /// repeated header key reads as its last value (`HDSDictionary`).
    public static func decodePayload(_ payload: Data) throws -> HDSMessage {
        let (headerValue, headerEnd) = try readHeader(payload)
        let messageValue: HDSValue
        do {
            if headerEnd == payload.endIndex {
                messageValue = .dictionary(HDSDictionary())
            } else {
                var messageReader = HDSReader(payload[headerEnd...])
                messageValue = try messageReader.readValue()
            }
        } catch let error as HDSCodecError {
            throw HDSFrameError.codec(error)
        }
        guard case .dictionary(let header) = headerValue else { throw HDSFrameError.invalidHeader("header") }
        guard case .string(let protocolName)? = header["protocol"] else { throw HDSFrameError.invalidHeader("protocol") }
        guard case .dictionary(let body) = messageValue else { throw HDSFrameError.invalidMessage }

        if case .string(let topic)? = header["event"] {
            return HDSMessage(kind: .event, protocolName: protocolName, topic: topic, body: body)
        }
        if case .string(let topic)? = header["request"] {
            guard case .int(let id)? = header["id"] else { throw HDSFrameError.invalidHeader("id") }
            return HDSMessage(kind: .request(id: id), protocolName: protocolName, topic: topic, body: body)
        }
        if case .string(let topic)? = header["response"] {
            guard case .int(let id)? = header["id"] else { throw HDSFrameError.invalidHeader("id") }
            guard case .int(let rawStatus)? = header["status"] else { throw HDSFrameError.invalidHeader("status") }
            guard let status = HDSStatus(rawValue: rawStatus) else { throw HDSFrameError.invalidStatus(rawStatus) }
            return HDSMessage(kind: .response(id: id, status: status), protocolName: protocolName, topic: topic, body: body)
        }
        throw HDSFrameError.invalidHeader("topic")
    }

    /// The header value and the index where the message part starts.
    private static func readHeader(_ payload: Data) throws -> (HDSValue, Data.Index) {
        guard let first = payload.first else { throw HDSFrameError.truncatedPayload }
        let headerEnd = payload.startIndex + 1 + Int(first)
        guard headerEnd <= payload.endIndex else { throw HDSFrameError.truncatedPayload }
        do {
            var headerReader = HDSReader(payload[(payload.startIndex + 1)..<headerEnd])
            return (try headerReader.readValue(), headerEnd)
        } catch let error as HDSCodecError {
            throw HDSFrameError.codec(error)
        }
    }

    /// What a payload that `decodePayload` rejects still tells about itself.
    enum PartialHeader: Equatable {
        /// A request header with its protocol, topic and integer id (so its message part is what failed).
        case request(id: Int64, protocolName: String, topic: String)
        /// A response header with an integer id (its status or message part failed).
        case response(id: Int64)
    }

    /// Nil for events and for headers without a readable integer id (or, for requests, protocol and topic).
    static func partialHeader(_ payload: Data) -> PartialHeader? {
        guard case (.dictionary(let header), _)? = try? readHeader(payload), case .int(let id)? = header["id"] else { return nil }
        if case .string? = header["event"] { return nil }
        if case .string(let topic)? = header["request"] {
            guard case .string(let protocolName)? = header["protocol"] else { return nil }
            return .request(id: id, protocolName: protocolName, topic: topic)
        }
        if case .string? = header["response"] { return .response(id: id) }
        return nil
    }

    /// [0x01][len24][ct][tag]
    public static func sealFrame(_ payload: Data, key: Data, counter: UInt64) throws -> Data {
        guard key.count == 32 else { throw HDSFrameError.invalidKeyLength }
        guard payload.count <= maximumPayloadLength else { throw HDSFrameError.payloadTooLarge(payload.count) }
        let length = payload.count
        let header = Data([frameType, UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 8),
                           UInt8(truncatingIfNeeded: length)])
        return header + (try HAPCrypto.chachaSeal(payload, key: key, nonce: HAPCrypto.nonce(counter: counter), aad: header))
    }

    /// `header` is the 4-byte frame header, `body` the ciphertext followed by the 16-byte tag.
    public static func openFrame(header: Data, body: Data, key: Data, counter: UInt64) throws -> Data {
        guard key.count == 32 else { throw HDSFrameError.invalidKeyLength }
        guard header.count == headerLength else { throw HDSFrameError.invalidFrameHeader }
        let bytes = Array(header)
        guard bytes[0] == frameType else { throw HDSFrameError.unsupportedFrameType(bytes[0]) }
        let length = payloadLength(bytes)
        guard length <= maximumPayloadLength else { throw HDSFrameError.payloadTooLarge(length) }
        guard body.count == length + tagLength else { throw HDSFrameError.lengthMismatch }
        do {
            return try HAPCrypto.chachaOpen(body, key: key, nonce: HAPCrypto.nonce(counter: counter), aad: header)
        } catch {
            throw HDSFrameError.authenticationFailed
        }
    }

    static func payloadLength(_ header: [UInt8]) -> Int {
        Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
    }
}

/// One complete frame as it arrived: the 4-byte header and the ciphertext ‖ tag.
struct HDSRawFrame: Sendable, Equatable {
    let header: Data
    let body: Data
}

/// Splits a TCP byte stream into frames. Frames of a type other than 0x01 are skipped (HAP-NodeJS ignores them).
struct HDSFrameAssembler: Sendable {
    private var buffer: [UInt8] = []
    /// Start of the unread bytes. Consumed frames are dropped on the next `append` (one move per read, however many
    /// frames it held), not one by one.
    private var readIndex = 0

    var bufferedByteCount: Int { buffer.count - readIndex }

    mutating func append(_ data: Data) {
        if readIndex > 0 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
        buffer.append(contentsOf: data)
    }

    /// The next complete type-1 frame, or nil until more bytes arrive. Throws `payloadTooLarge` for a length field
    /// above `maximumPayloadLength` (default 0xFFFFF; the connection must then be closed).
    mutating func nextFrame(maximumPayloadLength: Int = HDSFrameCodec.maximumPayloadLength) throws -> HDSRawFrame? {
        let headerLength = HDSFrameCodec.headerLength
        while buffer.count - readIndex >= headerLength {
            let start = readIndex
            let header = Array(buffer[start..<(start + headerLength)])
            let length = HDSFrameCodec.payloadLength(header)
            guard length <= maximumPayloadLength else { throw HDSFrameError.payloadTooLarge(length) }
            let end = start + headerLength + length + HDSFrameCodec.tagLength
            guard end <= buffer.count else { return nil }
            let frame = header[0] == HDSFrameCodec.frameType
                ? HDSRawFrame(header: Data(header), body: Data(buffer[(start + headerLength)..<end]))
                : nil
            if end == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                readIndex = 0
            } else {
                readIndex = end
            }
            if let frame { return frame }
        }
        return nil
    }
}
