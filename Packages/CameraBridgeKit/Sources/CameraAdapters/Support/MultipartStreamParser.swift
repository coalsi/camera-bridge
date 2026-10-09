import BridgeSupport
import Foundation

struct MultipartPart: Sendable, Equatable {
    var headers: HTTPHeaders
    var body: Data

    var contentType: String? { headers["Content-Type"] }

    /// XML part (by Content-Type, or by content when the type is missing).
    var isXML: Bool {
        if let contentType { return contentType.lowercased().contains("xml") }
        return body.first == UInt8(ascii: "<")
    }
}

enum MultipartParseError: Error, Equatable, Sendable {
    case partTooLarge(Int)
    case headerTooLarge
    case noBoundary
}

/// Incremental `multipart/mixed` reader for long-lived streams (Hikvision `alertStream`).
///
/// The boundary comes from the Content-Type header, and a literal `--boundary` line is accepted too (older NVRs
/// announce one boundary and send another). A part's `Content-Length` decides where it ends, so binary JPEG parts
/// that contain boundary-like bytes are skipped correctly; a part without Content-Length ends at the next delimiter
/// line (`--boundary` or `--boundary--` plus optional blanks, nothing else — a line that only starts like one is body).
/// Its search resumes where the previous chunk's ended, so an unsized part costs linear time. Lines before the first
/// boundary and closing boundaries are ignored.
struct MultipartStreamParser: Sendable {
    static let maximumPartSize = 8 << 20
    static let maximumHeaderBytes = 16 * 1024
    static let maximumPreamble = 1 << 20

    private enum State: Sendable {
        case seekingBoundary
        case headers(HTTPHeaders, bytes: Int)
        case body(HTTPHeaders, length: Int?)
    }

    let boundary: String
    private var buffer = Data()
    private var state = State.seekingBoundary
    /// `\n--<boundary>` for the announced and the literal boundary.
    private let delimiters: [Data]
    /// Offset into `buffer` where the delimiter search of an unsized body resumes (earlier bytes hold none).
    private var scanOffset = 0

    init(contentType: String?) {
        boundary = Self.boundary(fromContentType: contentType)
        delimiters = Set([boundary, "boundary"]).sorted().map { Data("\n--\($0)".utf8) }
    }

    /// The `boundary` parameter of a Content-Type (unquoted); `boundary` when absent.
    static func boundary(fromContentType contentType: String?) -> String {
        guard let contentType else { return "boundary" }
        for parameter in contentType.split(separator: ";") {
            let pair = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0].lowercased() == "boundary" else { continue }
            var value = pair[1]
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if !value.isEmpty { return value }
        }
        return "boundary"
    }

    private func isBoundaryLine(_ line: String) -> (isBoundary: Bool, isClosing: Bool) {
        for candidate in Set([boundary, "boundary"]) {
            if line == "--\(candidate)" { return (true, false) }
            if line == "--\(candidate)--" { return (true, true) }
        }
        return (false, false)
    }

    /// Removes and returns the next line (without CR/LF), or nil when no complete line is buffered.
    private mutating func nextLine() -> String? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        var end = newline
        if end > buffer.startIndex, buffer[buffer.index(before: end)] == 0x0D { end = buffer.index(before: end) }
        let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex...newline)
        return line
    }

    mutating func feed(_ data: Data) throws -> [MultipartPart] {
        buffer.append(data)
        var parts: [MultipartPart] = []
        while true {
            switch state {
            case .seekingBoundary:
                guard let line = nextLine() else {
                    if buffer.count > Self.maximumPreamble { throw MultipartParseError.noBoundary }
                    return parts
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let (isBoundary, isClosing) = isBoundaryLine(trimmed)
                if isBoundary && !isClosing { state = .headers(HTTPHeaders(), bytes: 0) }
            case .headers(var headers, let bytes):
                guard let line = nextLine() else {
                    if bytes + buffer.count > Self.maximumHeaderBytes { throw MultipartParseError.headerTooLarge }
                    return parts
                }
                if line.isEmpty {
                    let length = headers["Content-Length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if let length {
                        guard length >= 0, length <= Self.maximumPartSize else { throw MultipartParseError.partTooLarge(length) }
                    }
                    state = .body(headers, length: length)
                    scanOffset = 0
                } else {
                    let total = bytes + line.utf8.count
                    if total > Self.maximumHeaderBytes { throw MultipartParseError.headerTooLarge }
                    if let colon = line.firstIndex(of: ":") {
                        headers.add(String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                    }
                    state = .headers(headers, bytes: total)
                }
            case .body(let headers, let length):
                if let length {
                    guard buffer.count >= length else { return parts }
                    let end = buffer.index(buffer.startIndex, offsetBy: length)
                    parts.append(MultipartPart(headers: headers, body: Data(buffer[buffer.startIndex..<end])))
                    buffer.removeSubrange(buffer.startIndex..<end)
                    state = .seekingBoundary
                } else {
                    guard let range = nextBoundaryRange() else {
                        if buffer.count > Self.maximumPartSize { throw MultipartParseError.partTooLarge(buffer.count) }
                        return parts
                    }
                    parts.append(MultipartPart(headers: headers, body: Data(buffer[buffer.startIndex..<range.lowerBound])))
                    // Keep the boundary line itself for `.seekingBoundary`.
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    state = .seekingBoundary
                }
            }
        }
    }

    private enum DelimiterCheck { case delimiter, notDelimiter, needMoreData }

    /// Whether the bytes after a `\n--<boundary>` match at `index` complete a delimiter line: `--` (closing), or optional
    /// blanks then CR/LF.
    private func checkDelimiterEnd(at index: Data.Index) -> DelimiterCheck {
        var index = index
        guard index < buffer.endIndex else { return .needMoreData }
        if buffer[index] == UInt8(ascii: "-") {
            let next = buffer.index(after: index)
            guard next < buffer.endIndex else { return .needMoreData }
            return buffer[next] == UInt8(ascii: "-") ? .delimiter : .notDelimiter
        }
        while index < buffer.endIndex, buffer[index] == UInt8(ascii: " ") || buffer[index] == UInt8(ascii: "\t") {
            index = buffer.index(after: index)
        }
        guard index < buffer.endIndex else { return .needMoreData }
        return buffer[index] == 0x0D || buffer[index] == 0x0A ? .delimiter : .notDelimiter
    }

    /// Where an unsized body ends: the range of the line break before the next delimiter line (`\r\n` or `\n`; empty
    /// when the body is empty and the delimiter starts the buffer). Searches from `scanOffset`; nil when the buffered
    /// bytes hold no delimiter yet (`scanOffset` then moves to where the next search must resume).
    private mutating func nextBoundaryRange() -> Range<Data.Index>? {
        if scanOffset == 0 {   // an empty body whose delimiter follows the headers without a line break of its own
            for delimiter in delimiters.map({ $0.dropFirst() }) {
                if delimiter.starts(with: buffer) { return nil }   // too few bytes to tell yet
                guard buffer.starts(with: delimiter) else { continue }
                switch checkDelimiterEnd(at: buffer.startIndex + delimiter.count) {
                case .delimiter: return buffer.startIndex..<buffer.startIndex
                case .needMoreData: return nil
                case .notDelimiter: continue
                }
            }
        }
        var best: Range<Data.Index>?
        var undecided: Data.Index?
        let start = buffer.index(buffer.startIndex, offsetBy: min(scanOffset, buffer.count))
        for delimiter in delimiters {
            var from = start
            while from < buffer.endIndex, let match = buffer.firstRange(of: delimiter, in: from..<buffer.endIndex) {
                if let best, best.upperBound <= match.lowerBound { break }   // cannot beat the earlier delimiter
                let check = checkDelimiterEnd(at: match.upperBound)
                if check == .notDelimiter {
                    from = buffer.index(after: match.lowerBound)
                    continue
                }
                if check == .needMoreData {
                    undecided = min(undecided ?? match.lowerBound, match.lowerBound)
                } else {
                    let hasCR = match.lowerBound > buffer.startIndex && buffer[buffer.index(before: match.lowerBound)] == 0x0D
                    best = (hasCR ? buffer.index(before: match.lowerBound) : match.lowerBound)..<buffer.index(after: match.lowerBound)
                }
                break
            }
        }
        if let best, undecided.map({ best.upperBound <= $0 }) ?? true { return best }
        // Resume at an undecided match, or far enough back that a delimiter split across chunks is still found.
        let longest = delimiters.map(\.count).max() ?? 0
        let resume = undecided ?? best?.lowerBound
        scanOffset = resume.map { buffer.distance(from: buffer.startIndex, to: $0) } ?? max(0, buffer.count - longest)
        return nil
    }
}
