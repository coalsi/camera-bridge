import Foundation

/// A Session Description (RFC 4566 / RFC 8866) as returned by `DESCRIBE`. Parsing is lenient about unknown lines and
/// line endings (`\r\n` or `\n`) and strict about the parts CameraBridge relies on (`m=` lines).
public struct SDPSession: Sendable {
    public var media: [SDPMedia]
    /// Session-level attributes (`a=` lines before the first `m=` line), in order. Flags have a nil value.
    public var attributes: [(String, String?)]

    public init(media: [SDPMedia]) {
        self.init(media: media, attributes: [])
    }

    public init(media: [SDPMedia], attributes: [(String, String?)]) {
        self.media = media
        self.attributes = attributes
    }

    /// Session-level `a=control` (aggregate control URL, often `*`).
    public var control: String? { attributes.first { $0.0.lowercased() == "control" }?.1 }

    /// Throws `RTSPError.protocolError` for text without any SDP line and for malformed `m=` lines.
    public static func parse(_ sdp: String) throws -> SDPSession {
        var sessionAttributes: [(String, String?)] = []
        var media: [SDPMedia] = []
        var sawSDPLine = false

        for rawLine in sdp.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count >= 2, let equals = line.firstIndex(of: "="), line.distance(from: line.startIndex, to: equals) == 1 else {
                continue
            }
            let type = line[line.startIndex]
            let value = String(line[line.index(after: equals)...])
            switch type {
            case "v":
                sawSDPLine = true
            case "m":
                sawSDPLine = true
                media.append(try parseMediaLine(value))
            case "a":
                sawSDPLine = true
                let attribute = parseAttribute(value)
                if media.isEmpty {
                    sessionAttributes.append(attribute)
                } else {
                    media[media.count - 1].attributes.append(attribute)
                }
            case "o", "s", "t", "c", "b", "i", "e", "u", "p", "k", "z", "r":
                sawSDPLine = true
            default:
                continue
            }
        }
        guard sawSDPLine else { throw RTSPError.protocolError("not an SDP document") }

        let sessionDirection = sessionAttributes.lazy.compactMap { SDPMedia.direction(ofAttribute: $0.0) }.last
        for index in media.indices {
            let own = media[index].attributes.lazy.compactMap { SDPMedia.direction(ofAttribute: $0.0) }.last
            media[index].direction = own ?? sessionDirection
        }
        return SDPSession(media: media, attributes: sessionAttributes)
    }

    /// `m=<media> <port>[/<count>] <proto> <fmt> ...`; non-numeric formats (e.g. `webrtc-datachannel`) are skipped.
    private static func parseMediaLine(_ value: String) throws -> SDPMedia {
        let fields = value.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3 else { throw RTSPError.protocolError("malformed SDP m= line") }
        let portText = fields[1].split(separator: "/", maxSplits: 1).first ?? ""
        guard let port = Int(portText), (0...65_535).contains(port) else {
            throw RTSPError.protocolError("malformed SDP m= port")
        }
        let formats = fields.dropFirst(3).compactMap { UInt8($0) }.filter { $0 < 128 }
        var media = SDPMedia(type: String(fields[0]).lowercased(), port: port, formats: Array(formats))
        media.proto = String(fields[2])
        return media
    }

    private static func parseAttribute(_ value: String) -> (String, String?) {
        guard let colon = value.firstIndex(of: ":") else { return (value, nil) }
        return (String(value[..<colon]), String(value[value.index(after: colon)...]))
    }
}

/// One `m=` section. `attributes` are the section's own `a=` lines; `direction` is its `sendonly` / `recvonly` /
/// `sendrecv` / `inactive` attribute, inherited from the session level when the section has none.
public struct SDPMedia: Sendable {
    public var type: String
    public var port: Int
    public var formats: [UInt8]
    public var attributes: [(String, String?)]
    public var direction: String?
    /// Transport protocol, e.g. `RTP/AVP`.
    public var proto: String = "RTP/AVP"

    public init(type: String, port: Int, formats: [UInt8], attributes: [(String, String?)] = [], direction: String? = nil) {
        self.type = type
        self.port = port
        self.formats = formats
        self.attributes = attributes
        self.direction = direction
    }

    /// `a=control` of this section.
    public var control: String? { attributeValues("control").first }

    /// Values of every attribute named `name` (case-insensitive); flags yield "".
    public func attributeValues(_ name: String) -> [String] {
        let key = name.lowercased()
        return attributes.filter { $0.0.lowercased() == key }.map { $0.1 ?? "" }
    }

    /// `a=rtpmap` for `payloadType`, or the RFC 3551 static assignment for well-known payload types.
    /// Encoding names are uppercased; a missing channel count is 1.
    public func rtpmap(for payloadType: UInt8) -> SDPRTPMap? {
        for value in attributeValues("rtpmap") {
            let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, UInt8(parts[0]) == payloadType else { continue }
            let codec = parts[1].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = codec.first, !name.isEmpty else { continue }
            let clockRate = codec.count > 1 ? Int(codec[1]) ?? 0 : 0
            let channels = codec.count > 2 ? max(1, Int(codec[2]) ?? 1) : 1
            return SDPRTPMap(encoding: name.uppercased(), clockRate: clockRate, channels: channels)
        }
        return SDPRTPMap.staticPayloadTypes[payloadType]
    }

    /// `a=fmtp` parameters for `payloadType` with lowercased keys (`key=value` pairs separated by `;`; the value is
    /// everything after the first `=`, so base64 padding survives). Empty when there is no fmtp line.
    public func fmtp(for payloadType: UInt8) -> [String: String] {
        for value in attributeValues("fmtp") {
            let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count >= 1, UInt8(parts[0]) == payloadType else { continue }
            guard parts.count == 2 else { return [:] }
            var result: [String: String] = [:]
            for pair in parts[1].split(separator: ";") {
                let trimmed = pair.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let equals = trimmed.firstIndex(of: "=") {
                    let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                    result[key] = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                } else {
                    result[trimmed.lowercased()] = ""
                }
            }
            return result
        }
        return [:]
    }

    static func direction(ofAttribute name: String) -> String? {
        let lower = name.lowercased()
        return ["sendonly", "recvonly", "sendrecv", "inactive"].contains(lower) ? lower : nil
    }
}

/// An `a=rtpmap` entry: `<encoding>/<clock rate>[/<channels>]`.
public struct SDPRTPMap: Sendable, Equatable {
    public var encoding: String
    public var clockRate: Int
    public var channels: Int

    public init(encoding: String, clockRate: Int, channels: Int = 1) {
        self.encoding = encoding
        self.clockRate = clockRate
        self.channels = channels
    }

    /// RFC 3551 §6 static payload types that cameras use without an rtpmap line.
    static let staticPayloadTypes: [UInt8: SDPRTPMap] = [
        0: SDPRTPMap(encoding: "PCMU", clockRate: 8000),
        3: SDPRTPMap(encoding: "GSM", clockRate: 8000),
        4: SDPRTPMap(encoding: "G723", clockRate: 8000),
        8: SDPRTPMap(encoding: "PCMA", clockRate: 8000),
        9: SDPRTPMap(encoding: "G722", clockRate: 8000),
        14: SDPRTPMap(encoding: "MPA", clockRate: 90_000),
        18: SDPRTPMap(encoding: "G729", clockRate: 8000),
        26: SDPRTPMap(encoding: "JPEG", clockRate: 90_000),
        32: SDPRTPMap(encoding: "MPV", clockRate: 90_000),
        33: SDPRTPMap(encoding: "MP2T", clockRate: 90_000),
    ]
}
