import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a camera answered to an ISAPI write (`ResponseStatus`).
enum ISAPIWriteAnswer: Sendable, Equatable {
    /// `statusCode` 1 (or a 2xx answer without a status document).
    case ok
    /// `statusCode` 7 ("Reboot Required"): the setting is taken and applies after the camera restarts. Camera Bridge never restarts it.
    case rebootRequired
}

/// An ISAPI write the camera refused, in the camera's own words ("Invalid Operation (notSupport)").
struct ISAPIRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    var words: String
    /// The camera says it does not have this setting (HTTP 404, `notSupport`).
    var isNotSupported: Bool
    var description: String { words }
}

/// The ISAPI documents "Set up for Camera Bridge" reads and writes: the clock (`/ISAPI/System/time`), its time server
/// (`/ISAPI/System/time/ntpServers/1`), and the network features (`/ISAPI/System/Network/capabilities`, UPnP, EZVIZ / Hik-Connect).
/// Every write is a read-modify-write of the camera's own document, text-level like the encoder's: only the element changed differs.
extension HikvisionISAPI {
    static let timePath = "/ISAPI/System/time"
    static let ntpServerPath = "/ISAPI/System/time/ntpServers/1"
    static let networkCapabilitiesPath = "/ISAPI/System/Network/capabilities"
    static let upnpPaths = ["/ISAPI/System/Network/UPnP"]
    /// Hik-Connect (EZVIZ cloud): the path differs between firmwares.
    static let cloudPaths = ["/ISAPI/System/Network/EZVIZ", "/ISAPI/System/Network/Ezviz"]

    /// The document at `path` as text; nil when the camera has no such resource (HTTP 404, 405, 501, or a `notSupport` status).
    func document(_ path: String) async throws -> String? {
        let (data, response) = try await rawSend(path, method: "GET", body: nil)
        switch response.statusCode {
        case 200..<300:
            guard let text = String(data: data, encoding: .utf8) else { throw CameraAdapterError.invalidResponse("\(path): not UTF-8") }
            if let status = Self.responseStatus(data), status.code != 1 { return nil }   // a status document instead of the resource
            return text
        case 401: throw CameraAdapterError.unauthorized
        case 404, 405, 501: return nil
        default:
            guard let status = Self.responseStatus(data) else { throw CameraAdapterError.httpStatus(response.statusCode) }
            if status.isNotSupported { return nil }
            throw ISAPIRefusal(words: status.words, isNotSupported: false)
        }
    }

    /// PUTs `document` to `path` and reads the camera's `ResponseStatus`. Throws `ISAPIRefusal` with the camera's words when it refuses.
    func write(_ path: String, document: String) async throws -> ISAPIWriteAnswer {
        let (data, response) = try await rawSend(path, method: "PUT", body: Data(document.utf8))
        if response.statusCode == 401 { throw CameraAdapterError.unauthorized }
        let status = Self.responseStatus(data)
        if let status {
            switch status.code {
            case 1: return .ok
            case 7: return .rebootRequired
            default: throw ISAPIRefusal(words: status.words, isNotSupported: status.isNotSupported)
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ISAPIRefusal(words: "HTTP \(response.statusCode)", isNotSupported: [404, 405, 501].contains(response.statusCode))
        }
        return .ok
    }

    private func rawSend(_ path: String, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let request = CameraHTTP.request(try url(path), method: method, body: body, contentType: body == nil ? nil : "application/xml")
        do {
            return try await http.data(for: request)
        } catch {
            throw CameraHTTP.sanitized(error)
        }
    }

    /// An ISAPI `ResponseStatus` document: its code and the camera's words. nil when `data` is not one.
    static func responseStatus(_ data: Data) -> (code: Int, words: String, isNotSupported: Bool)? {
        guard let tree = try? XMLTree.parse(data), tree.matches("ResponseStatus"), let code = tree.string("statusCode").flatMap({ Int($0) }) else { return nil }
        let string = tree.string("statusString")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sub = tree.string("subStatusCode")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words = [string.isEmpty ? "status \(code)" : string, sub.isEmpty || sub.lowercased() == "ok" ? nil : "(\(sub))"]
            .compactMap { $0 }.joined(separator: " ")
        return (code, words, sub.lowercased().contains("notsupport"))
    }

    /// The first `<name>` element's text in `document` (any namespace prefix-free ISAPI document), trimmed; nil when absent.
    static func elementText(_ name: String, in document: String) -> String? {
        guard let tree = try? XMLTree.parse(Data(document.utf8)) else { return nil }
        let node = tree.matches(name) ? tree : tree.firstDescendant(name)
        return node?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `document` with the first `<name>` element's text replaced, or with the element added before `</root>` when it is missing and `add`
    /// is set. nil when it is missing (and not added).
    static func settingElement(_ name: String, to value: String, in document: String, addingBefore closingTag: String? = nil) -> String? {
        if let replaced = replacingElement(name, in: document, with: XMLTree.escape(value)) { return replaced }
        guard let closingTag, let close = document.range(of: closingTag, options: [.caseInsensitive, .backwards]) else { return nil }
        var result = document
        result.insert(contentsOf: "<\(name)>\(XMLTree.escape(value))</\(name)>", at: close.lowerBound)
        return result
    }

    /// Whether the network capabilities document says the camera has `flag` (`isSupportUPnP`, `isSupportEZVIZ`): nil when it does not say.
    static func capability(_ flag: String, in document: String?) -> Bool? {
        guard let document, let text = elementText(flag, in: document) else { return nil }
        return ONVIFNotification.parseBool(text)
    }
}

/// Hikvision's own time zone text: POSIX-like, with full `h:mm:ss` offsets and the daylight-saving shift written after the second name
/// ("CST+7:00:00", "CST+6:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00"). Hikvision names every zone "CST" and its summer time "DST".
enum HikvisionTimeZone {
    /// The ISAPI form of a POSIX TZ string; nil for one it cannot carry (Julian-day rules).
    static func isapi(fromPosix posix: String) -> String? {
        guard let parsed = parse(posix) else { return nil }
        var text = "CST" + offset(parsed.standardSeconds)
        guard let dst = parsed.dst else { return text }
        let shift = parsed.standardSeconds - dst.offsetSeconds   // POSIX offsets are west-positive: summer time is one hour less
        guard shift > 0, shift <= 3 * 3600 else { return nil }
        text += "DST" + clock(shift) + ",\(dst.start)/\(clock(dst.startTime)),\(dst.end)/\(clock(dst.endTime))"
        return text
    }

    /// Two time zone texts mean the same zone (names ignored; offsets compared in seconds).
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = parse(lhs), let b = parse(rhs) else { return lhs == rhs }
        return a == b
    }

    struct Parsed: Equatable {
        struct DST: Equatable {
            var offsetSeconds: Int
            var start: String
            var startTime: Int
            var end: String
            var endTime: Int
        }
        var standardSeconds: Int
        var dst: DST?
    }

    /// Parses POSIX ("MST7MDT,M3.2.0,M11.1.0") and Hikvision ("CST+7:00:00DST01:00:00,M3.2.0/02:00:00,…") forms alike: Hikvision's text after
    /// the second name is the shift (01:00:00), POSIX's is an offset; a value of at most three hours after a second name is read as a shift
    /// when the text uses `h:mm:ss` offsets.
    static func parse(_ text: String) -> Parsed? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first, !head.isEmpty else { return nil }
        var index = head.startIndex
        func name() -> Bool {
            let start = index
            if index < head.endIndex, head[index] == "<" {
                guard let close = head[index...].firstIndex(of: ">") else { return false }
                index = head.index(after: close)
            } else {
                while index < head.endIndex, head[index].isLetter { index = head.index(after: index) }
            }
            return index > start
        }
        func number() -> Int? {
            let start = index
            while index < head.endIndex, "+-0123456789:".contains(head[index]) { index = head.index(after: index) }
            return seconds(String(head[start..<index]))
        }
        guard name() else { return nil }
        let offsetStart = index
        guard let standard = number() else { return nil }
        let hikvisionStyle = head[offsetStart..<index].contains(":")
        guard index < head.endIndex else { return parts.count == 1 ? Parsed(standardSeconds: standard, dst: nil) : nil }
        guard name() else { return nil }
        var dstOffset = standard - 3600
        if index < head.endIndex {
            guard let value = number(), index == head.endIndex else { return nil }
            dstOffset = hikvisionStyle ? standard - value : value
        }
        guard parts.count == 3 else { return nil }
        func rule(_ text: String) -> (String, Int)? {
            let pieces = text.split(separator: "/", maxSplits: 1).map(String.init)
            guard let date = pieces.first, date.hasPrefix("M"), date.dropFirst().split(separator: ".").count == 3 else { return nil }
            let time = pieces.count == 2 ? seconds(pieces[1]) : 7200
            return time.map { (date, $0) }
        }
        guard let start = rule(parts[1]), let end = rule(parts[2]) else { return nil }
        return Parsed(standardSeconds: standard, dst: .init(offsetSeconds: dstOffset, start: start.0, startTime: start.1, end: end.0, endTime: end.1))
    }

    /// "+7", "-5:30", "7:00:00" → seconds (west-positive, as written).
    static func seconds(_ text: String) -> Int? {
        var body = Substring(text)
        var sign = 1
        if body.first == "+" { body = body.dropFirst() } else if body.first == "-" { sign = -1; body = body.dropFirst() }
        let fields = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let values = fields.compactMap { Int($0) }
        guard values.count == fields.count, values[0] <= 167, values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let total = values[0] * 3600 + (values.count > 1 ? values[1] * 60 : 0) + (values.count > 2 ? values[2] : 0)
        return sign * total
    }

    /// "+7:00:00", "-5:30:00".
    static func offset(_ seconds: Int) -> String {
        (seconds < 0 ? "-" : "+") + {
            let value = abs(seconds)
            return "\(value / 3600):" + String(format: "%02d:%02d", value / 60 % 60, value % 60)
        }()
    }

    /// "01:00:00", "02:00:00".
    static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
