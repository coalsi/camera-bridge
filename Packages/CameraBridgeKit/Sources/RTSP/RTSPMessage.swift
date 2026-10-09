import BridgeSupport
import Foundation

/// A response received on the RTSP control connection.
struct RTSPResponse: Sendable, Equatable {
    var status: Int
    var reason: String
    var headers: HTTPHeaders
    var body: Data

    var cseq: Int? { headers["CSeq"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
}

/// A request received on the control connection (servers may send e.g. `GET_PARAMETER` or `OPTIONS`).
struct RTSPRequest: Sendable, Equatable {
    var method: String
    var uri: String
    var headers: HTTPHeaders
    var body: Data
}

enum RTSPIncomingMessage: Sendable, Equatable {
    case response(RTSPResponse)
    case request(RTSPRequest)
    /// RFC 2326 §10.12: `$`, channel, 16-bit length, RTP/RTCP packet.
    case interleaved(channel: UInt8, payload: Data)
}

/// Incremental parser for the byte stream of an RTSP-over-TCP connection: responses, server requests and
/// interleaved binary frames in any order. Accepts `\r\n` and bare `\n` line endings; bounds header and body sizes.
///
/// Junk between messages (some cameras emit it) is skipped without losing `$` frame alignment: bytes are checked
/// against the shape of a start line (`RTSP/<version> …` or `METHOD …`, printable text) as they arrive, and a byte
/// that cannot continue one is skipped at once, so the scan never runs into the binary frames that follow. A complete
/// line that is not a start line is dropped whole, and a message whose header block turns out to contain binary data
/// is dropped from its start line.
struct RTSPMessageParser: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0
    let maxHeaderSize: Int
    let maxBodySize: Int

    init(maxHeaderSize: Int = 64 * 1024, maxBodySize: Int = 4 * 1024 * 1024) {
        self.maxHeaderSize = maxHeaderSize
        self.maxBodySize = maxBodySize
    }

    var bufferedByteCount: Int { buffer.count - start }

    mutating func append(_ data: Data) {
        if start > 0, start >= buffer.count / 2 {
            buffer.removeSubrange(0..<start)
            start = 0
        }
        buffer.append(contentsOf: data)
    }

    /// The next complete message, or nil when more bytes are needed.
    mutating func next() throws -> RTSPIncomingMessage? {
        while start < buffer.count {
            if buffer[start] == 0x24 {   // "$"
                guard buffer.count - start >= 4 else { return nil }
                let length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                guard buffer.count - start >= 4 + length else { return nil }
                let channel = buffer[start + 1]
                let payload = Data(buffer[(start + 4)..<(start + 4 + length)])
                start += 4 + length
                return .interleaved(channel: channel, payload: payload)
            }
            let lineEnd: Int
            switch scanStartLine() {
            case .junk(let resume):
                start = resume
                continue
            case .incomplete:
                if buffer.count - start > maxHeaderSize { throw RTSPError.protocolError("RTSP header too large") }
                return nil
            case .complete(let end):
                lineEnd = end
            }
            let firstLine = String(decoding: buffer[start..<lineEnd], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard let kind = Self.classify(firstLine) else {
                start = lineEnd + 1   // a text line that is not a start line: drop it whole
                continue
            }
            let headerEnd: Int
            let bodyStart: Int
            switch findHeaderEnd(after: lineEnd) {
            case .malformed:
                start = lineEnd + 1   // binary where headers belong: resynchronise after the start line
                continue
            case .incomplete:
                if buffer.count - start > maxHeaderSize { throw RTSPError.protocolError("RTSP header too large") }
                return nil
            case .complete(let end, let body):
                headerEnd = end
                bodyStart = body
            }
            if headerEnd - start > maxHeaderSize { throw RTSPError.protocolError("RTSP header too large") }
            let lines = String(decoding: buffer[lineEnd..<headerEnd], as: UTF8.self)
                .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            var headers = HTTPHeaders()
            for line in lines where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers.add(line[..<colon].trimmingCharacters(in: .whitespaces), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            let contentLength = headers["Content-Length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            guard contentLength >= 0, contentLength <= maxBodySize else { throw RTSPError.protocolError("RTSP body too large") }
            guard buffer.count - bodyStart >= contentLength else { return nil }
            let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
            start = bodyStart + contentLength
            switch kind {
            case .response(let status, let reason):
                return .response(RTSPResponse(status: status, reason: reason, headers: headers, body: body))
            case .request(let method, let uri):
                return .request(RTSPRequest(method: method, uri: uri, headers: headers, body: body))
            }
        }
        return nil
    }

    private enum StartLine {
        case response(Int, String)
        case request(String, String)
    }

    private enum StartLineScan {
        /// No start line begins before `resume` (> `start`): no rescanning of junk, and a `$` there is seen.
        case junk(resume: Int)
        case incomplete
        /// Index of the line's LF.
        case complete(Int)
    }

    private enum HeaderScan {
        case malformed
        case incomplete
        /// Index of the blank line's LF (the header block ends there) and the first body byte.
        case complete(Int, Int)
    }

    /// Whether the bytes at `start` can be the beginning of a start line, as far as they have arrived: a first word of
    /// letters or `_` (a method), or `RTSP/` followed by digits and dots (a version), then a space and printable text
    /// up to the line end. On a mismatch at byte `p`, no start line can begin in `start + 1 ..< p` either (it would
    /// fail at `p` too), except `RTSP/` right before a misplaced `/`.
    private func scanStartLine() -> StartLineScan {
        let rtsp = Array("RTSP".utf8)
        var isVersion = false
        var inFirstWord = true
        var index = start
        func junk(at position: Int) -> StartLineScan { .junk(resume: max(position, start + 1)) }
        while index < buffer.count {
            let byte = buffer[index]
            let offset = index - start
            if inFirstWord {
                switch byte {
                case 0x20:   // a space ends the first word
                    guard offset > 0, !isVersion || offset > rtsp.count + 1 else { return junk(at: index) }
                    inFirstWord = false
                case 0x2F:   // "/" only in "RTSP/"
                    guard !isVersion, offset == rtsp.count, buffer[start..<index].elementsEqual(rtsp) else {
                        let candidate = index - rtsp.count
                        if !isVersion, candidate > start, buffer[candidate..<index].elementsEqual(rtsp) { return .junk(resume: candidate) }
                        return junk(at: index)
                    }
                    isVersion = true
                case 0x30...0x39, 0x2E:   // digits and "." only in the version
                    guard isVersion else { return junk(at: index) }
                case 0x41...0x5A, 0x61...0x7A, 0x5F:   // letters and "_" only in a method (or "RTSP")
                    guard !isVersion else { return junk(at: index) }
                default:
                    return junk(at: index)
                }
            } else {
                if byte == 0x0A { return .complete(index) }
                guard byte >= 0x20 || byte == 0x09 || byte == 0x0D, byte != 0x7F else { return junk(at: index) }
            }
            index += 1
        }
        return .incomplete
    }

    /// Scans the header lines after the start line's LF for the blank line (LF LF or LF CR LF). A control byte other
    /// than CR, LF and TAB means binary data, not headers.
    private func findHeaderEnd(after lineEnd: Int) -> HeaderScan {
        var index = lineEnd
        while index < buffer.count {
            let byte = buffer[index]
            if byte == 0x0A {
                // After a LF: either LF or CR LF ends the header block.
                if index + 1 < buffer.count, buffer[index + 1] == 0x0A { return .complete(index, index + 2) }
                if index + 2 < buffer.count, buffer[index + 1] == 0x0D, buffer[index + 2] == 0x0A { return .complete(index, index + 3) }
            } else if (byte < 0x20 && byte != 0x09 && byte != 0x0D) || byte == 0x7F {
                return .malformed
            }
            index += 1
        }
        return .incomplete
    }

    /// `RTSP/1.0 200 OK` or `METHOD uri RTSP/1.0`.
    private static func classify(_ line: String) -> StartLine? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if line.hasPrefix("RTSP/") {
            guard parts.count >= 2, let status = Int(parts[1]), (100...999).contains(status) else { return nil }
            return .response(status, parts.count > 2 ? String(parts[2]) : "")
        }
        guard parts.count == 3, parts[2].hasPrefix("RTSP/"), parts[0].allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        return .request(String(parts[0]), String(parts[1]))
    }
}

enum RTSPRequestSerializer {
    static func serialize(method: String, uri: String, headers: [(String, String)], body: Data = Data()) -> Data {
        var text = "\(method) \(uri) RTSP/1.0\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if !body.isEmpty { text += "Content-Length: \(body.count)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    static func response(status: Int, reason: String, cseq: String?) -> Data {
        var text = "RTSP/1.0 \(status) \(reason)\r\n"
        if let cseq { text += "CSeq: \(cseq)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// `$` framing for a packet on `channel` (payloads over 65535 bytes are truncated by the 16-bit length field,
    /// so callers keep packets smaller).
    static func interleaved(channel: UInt8, payload: Data) -> Data {
        let length = min(payload.count, Int(UInt16.max))
        var data = Data(capacity: length + 4)
        data.append(contentsOf: [0x24, channel, UInt8(length >> 8), UInt8(length & 0xFF)])
        data.append(payload.prefix(length))
        return data
    }
}

/// Parsers for RTSP header values.
enum RTSPHeaderValues {
    /// `Session: <id>[;timeout=<seconds>]`.
    static func session(_ value: String) -> (id: String, timeout: Duration?)? {
        let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let id = parts.first, !id.isEmpty else { return nil }
        var timeout: Duration?
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "timeout", let seconds = Int(pair[1]), seconds > 0 {
                timeout = .seconds(min(seconds, 86_400))   // a day at most: keeps interval arithmetic sane
            }
        }
        return (id, timeout)
    }

    /// `Transport` parameters by lowercased name (flags map to ""); the first element (protocol) is under "".
    static func transportParameters(_ value: String) -> [String: String] {
        let first = value.split(separator: ",").first.map(String.init) ?? value
        var result: [String: String] = [:]
        for (index, part) in first.split(separator: ";").enumerated() {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if index == 0 { result[""] = trimmed; continue }
            if let equals = trimmed.firstIndex(of: "=") {
                result[trimmed[..<equals].lowercased()] = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            } else {
                result[trimmed.lowercased()] = ""
            }
        }
        return result
    }

    /// `interleaved=a-b` (or `interleaved=a`, meaning a and a+1) of a TCP transport; nil for other transports.
    static func interleavedChannels(_ transport: String) -> (rtp: UInt8, rtcp: UInt8)? {
        let parameters = transportParameters(transport)
        guard let value = parameters["interleaved"] else { return nil }
        let channels = value.split(separator: "-").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
        guard let rtp = channels.first else { return nil }
        return (rtp, channels.count > 1 ? channels[1] : rtp &+ 1)
    }
}
