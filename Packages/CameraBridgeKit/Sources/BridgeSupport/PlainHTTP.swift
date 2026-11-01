import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// One plain-HTTP (`http://`) request on its own TCP connection over a `NetworkTransport`: what `AuthenticatingHTTPClient` sends
/// instead of URLSession wherever it has such a transport (`AuthenticatingHTTPClient.routePlainHTTP(through:)`, the Linux daemon).
///
/// Why not URLSession there: swift-corelibs-foundation keeps the write source it made to send a request until the connection is
/// released, so while it waits for the answer the always-writable socket wakes libdispatch over and over. Two cameras' event
/// connections kept a box's dispatch manager thread at some 60 000 wake-ups a second, half a processor core (Oct 31 2026).
///
/// The request goes out with `Connection: close` (each request has its own connection) and without `Accept-Encoding` (the answer
/// is not compressed). The answer's head is at most `maximumHeadSize` bytes; interim 1xx answers are skipped. Its body ends at
/// its Content-Length, at the last chunk of a chunked body, or when the camera closes the connection; a HEAD request's answer, a
/// 204 and a 304 have none. The body is read from the connection only as it is read (a slow reader holds the camera back, not
/// memory). A wait for the connection, the head or body bytes that lasts `timeout` fails with `URLError(.timedOut)`: one timer
/// per connection, set again only when it runs out, not one per read. An answer cut short fails with `TransportError.closed`,
/// a malformed one with `HTTPClientError.notHTTPResponse`. Dropping the body, or cancelling the task reading it, closes the
/// connection.
package enum PlainHTTP {
    package static let maximumHeadSize = 64 * 1024
    /// Bytes asked of the connection per read.
    static let readSize = 64 * 1024

    /// Whether `request` can go this way: `http` with a host, no user name or password in the URL, no body stream.
    package static func handles(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme?.lowercased() == "http", let host = url.host, !host.isEmpty, url.user == nil,
              url.password == nil, request.httpBodyStream == nil else { return false }
        return true
    }

    /// The request target: the URL's path (`/` when it has none) and query, percent-encoded as given. Also the Digest `uri`.
    package static func requestTarget(_ url: URL?) -> String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "/" }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?" + query }
        return target
    }

    /// Sends `request` (which `handles`) and returns its answer's head with the body still to read. `track` sees the connection
    /// once it is open; false closes it again (the client was invalidated) and fails with `TransportError.closed`.
    package static func open(_ request: URLRequest, transport: any NetworkTransport, timeout: Duration,
                             track: (WatchedConnection) -> Bool = { _ in true }) async throws -> (HTTPURLResponse, PlainHTTPBody) {
        guard let url = request.url, handles(request) else { throw URLError(.unsupportedURL) }
        guard let port = UInt16(exactly: url.port ?? 80), port != 0 else { throw TransportError.failed("HTTP request to an invalid port") }
        let method = (request.httpMethod ?? "GET").uppercased()
        let socket: any TCPConnection
        do {
            socket = try await transport.connect(host: bareHost(url), port: port, timeout: timeout)
        } catch TransportError.timedOut {
            throw URLError(.timedOut)
        }
        let connection = WatchedConnection(socket, timeout: timeout)
        guard track(connection) else {
            connection.close()
            throw TransportError.closed
        }
        do {
            try Task.checkCancellation()
            try await connection.send(wire(for: request, url: url, method: method))
            let (head, rest) = try await readHead(connection)
            let framing = try framing(of: head, method: method)
            guard let response = HTTPURLResponse(url: url, statusCode: head.status, httpVersion: head.version,
                                                 headerFields: headerFields(head.headers)) else { throw HTTPClientError.notHTTPResponse }
            return (response, PlainHTTPBody(connection: connection, framing: framing, pending: rest))
        } catch {
            connection.close()
            throw error
        }
    }

    // MARK: - Request

    static func wire(for request: URLRequest, url: URL, method: String) -> Data {
        let body = request.httpBody ?? Data()
        // Framing and connection headers are this client's; Accept-Encoding is left out, so the answer comes uncompressed.
        let own: Set<String> = ["host", "connection", "content-length", "transfer-encoding", "accept-encoding", "keep-alive", "te", "upgrade"]
        var headers = HTTPHeaders([("Host", hostHeader(url))])
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) where !own.contains(name.lowercased()) {
            headers.add(name, value)
        }
        if headers["User-Agent"] == nil { headers.add("User-Agent", "CameraBridge") }
        if headers["Accept"] == nil { headers.add("Accept", "*/*") }
        headers.add("Connection", "close")
        if !body.isEmpty || ["POST", "PUT", "PATCH"].contains(method) { headers.add("Content-Length", String(body.count)) }
        return HTTPSerializer.request(HTTPRequestHead(method: method, target: requestTarget(url), headers: headers), body: body)
    }

    /// The host without IPv6 brackets.
    static func bareHost(_ url: URL) -> String {
        let host = url.host ?? ""
        return host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    static func hostHeader(_ url: URL) -> String {
        let host = bareHost(url)
        let shown = host.contains(":") ? "[\(host)]" : host
        if let port = url.port, port != 80 { return "\(shown):\(port)" }
        return shown
    }

    // MARK: - Answer

    /// Reads up to the end of the final (non-1xx) answer's head; returns it and the body bytes read with it.
    static func readHead(_ connection: WatchedConnection) async throws -> (HTTPResponseHead, Data) {
        var buffer = Data()
        while true {
            if let (headBytes, rest) = splitHead(buffer) {
                let head = try parseHead(headBytes)
                if (100..<200).contains(head.status) && head.status != 101 {   // 100 Continue and the like: the answer follows
                    buffer = rest
                    continue
                }
                return (head, rest)
            }
            if buffer.count > maximumHeadSize { throw HTTPClientError.notHTTPResponse }
            guard let data = try await connection.receive() else {
                throw buffer.isEmpty ? TransportError.closed : HTTPClientError.notHTTPResponse
            }
            buffer.append(data)
        }
    }

    /// The head (without its blank line) and what follows it, once `buffer` holds a whole head within `maximumHeadSize`.
    /// A head may end its lines with a bare LF, as some cameras do.
    static func splitHead(_ buffer: Data) -> (Data, Data)? {
        let crlf = buffer.range(of: Data("\r\n\r\n".utf8))
        let lf = buffer.range(of: Data("\n\n".utf8))
        guard let end = [crlf, lf].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }),
              end.lowerBound - buffer.startIndex <= maximumHeadSize else { return nil }
        return (Data(buffer[buffer.startIndex..<end.lowerBound]), Data(buffer[end.upperBound...]))
    }

    static func parseHead(_ bytes: Data) throws -> HTTPResponseHead {
        // Split on the line feed byte: as Characters, "\r\n" is one that is not "\n".
        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(decoding: $0.last == 0x0D ? $0.dropLast() : $0, as: UTF8.self) }
        guard let statusLine = lines.first else { throw HTTPClientError.notHTTPResponse }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), parts[1].count == 3, let status = Int(parts[1]), (100...999).contains(status) else {
            throw HTTPClientError.notHTTPResponse
        }
        var fields: [(String, String)] = []
        for line in lines.dropFirst() {
            if let first = line.first, first == " " || first == "\t", !fields.isEmpty {   // a folded line continues the one before
                fields[fields.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            fields.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return HTTPResponseHead(version: String(parts[0]), status: status, reason: parts.count > 2 ? String(parts[2]) : "",
                                headers: HTTPHeaders(fields))
    }

    static func framing(of head: HTTPResponseHead, method: String) throws -> PlainHTTPBody.Framing {
        if method == "HEAD" || head.status == 204 || head.status == 304 || head.status < 200 { return .none }
        let codings = head.headers.values(for: "Transfer-Encoding").flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if !codings.isEmpty { return codings.last == "chunked" ? .chunked : .untilClose }
        let lengths = Set(head.headers.values(for: "Content-Length").flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) })
        guard let text = lengths.first else { return .untilClose }
        guard lengths.count == 1, !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(text) else {
            throw HTTPClientError.notHTTPResponse
        }
        return length == 0 ? .none : .length(length)
    }

    /// The head's fields as `HTTPURLResponse` takes them: a repeated name's values joined with ", ". A camera offering Digest
    /// and Basic in separate WWW-Authenticate lines gets its (first) Digest challenge alone, the one the client answers.
    static func headerFields(_ headers: HTTPHeaders) -> [String: String] {
        var fields: [String: String] = [:]
        var spelling: [String: String] = [:]
        for (name, value) in headers {
            let key = name.lowercased()
            if let existing = spelling[key] {
                fields[existing, default: ""] += ", " + value
            } else {
                spelling[key] = name
                fields[name] = value
            }
        }
        let challenges = headers.values(for: "WWW-Authenticate")
        if challenges.count > 1, let name = spelling["www-authenticate"],
           let digest = challenges.first(where: { $0.lowercased().hasPrefix("digest") }) {
            fields[name] = digest
        }
        return fields
    }
}

/// The body of a `PlainHTTP` answer, read from its connection as it is read. The connection closes at the end of the body, on an
/// error, on `close()`, and when the body is released.
package actor PlainHTTPBody {
    enum Framing: Sendable, Equatable {
        case none
        case length(Int)
        case chunked
        case untilClose
    }

    private let connection: WatchedConnection
    private let framing: Framing
    private var pending: Data
    private var remaining = 0
    private var decoder = ChunkedDecoder()
    private var ended = false
    /// The Content-Length, when the answer has one (0 when it has no body).
    package nonisolated let expectedLength: Int?

    init(connection: WatchedConnection, framing: Framing, pending: Data) {
        self.connection = connection
        self.framing = framing
        self.pending = pending
        switch framing {
        case .none:
            expectedLength = 0
            ended = true
            connection.close()
        case .length(let length):
            expectedLength = length
            remaining = length
        case .chunked, .untilClose:
            expectedLength = nil
        }
    }

    deinit {
        connection.close()
    }

    /// The next body bytes (never empty); nil at the end of the body. Throws `CancellationError` when the reading task is cancelled.
    package func next() async throws -> Data? {
        while !ended {
            if !pending.isEmpty {
                let data = pending
                pending = Data()
                let body = try take(data)
                if !body.isEmpty { return body }
                continue
            }
            guard let data = try await connection.receive() else {
                guard framing == .untilClose else {
                    connection.close()
                    throw TransportError.closed   // the camera hung up before the end of the body
                }
                ended = true
                break
            }
            pending = data
        }
        connection.close()
        return nil
    }

    /// Closes the connection; a read in progress, and later ones, fail.
    package nonisolated func close() {
        connection.close()
    }

    /// The body as a stream (what `stream(for:)` hands over): it ends quietly when the task reading it is cancelled, and dropping
    /// it releases the body, which closes the connection.
    package nonisolated func stream() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(unfolding: { () async throws -> Data? in
            do {
                return try await self.next()
            } catch is CancellationError {
                return nil
            }
        })
    }

    private func take(_ data: Data) throws -> Data {
        switch framing {
        case .none:
            ended = true
            return Data()
        case .untilClose:
            return data
        case .length:
            let count = min(remaining, data.count)
            remaining -= count
            if remaining == 0 { ended = true }
            return count == data.count ? data : Data(data.prefix(count))
        case .chunked:
            let decoded = decoder.feed(data)
            if decoder.isMalformed { throw HTTPClientError.notHTTPResponse }
            if decoder.isFinished { ended = true }
            return decoded
        }
    }
}

/// A TCP connection whose every wait (a send, a read) fails with `URLError(.timedOut)` after `timeout`: one timer for the whole
/// connection, which closes it then. A cancelled waiting task closes the connection and gets `CancellationError`.
package final class WatchedConnection: Sendable {
    private let connection: any TCPConnection
    private let timeout: Duration
    private let watch = Watch()

    private final class Watch: Sendable {
        struct State {
            var waitingSince: ContinuousClock.Instant?
            var timedOut = false
            var closed = false
            var timer: Task<Void, Never>?
            var onClose: (@Sendable () -> Void)?
        }
        let state = Mutex(State())
    }

    init(_ connection: any TCPConnection, timeout: Duration) {
        self.connection = connection
        self.timeout = timeout
    }

    func send(_ data: Data) async throws {
        try await waiting { try await self.connection.send(data) }
    }

    /// Bytes as soon as any arrive; nil at the camera's end of the connection.
    func receive() async throws -> Data? {
        try await waiting { try await self.connection.receive(maximumLength: PlainHTTP.readSize) }
    }

    /// Runs once, when the connection closes (or at once if it has).
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let closed = watch.state.withLock { state -> Bool in
            if !state.closed { state.onClose = handler }
            return state.closed
        }
        if closed { handler() }
    }

    /// Idempotent.
    func close() {
        let (timer, onClose) = watch.state.withLock { state in
            state.closed = true
            defer {
                state.timer = nil
                state.onClose = nil
            }
            return (state.timer, state.onClose)
        }
        timer?.cancel()
        connection.close()
        onClose?()
    }

    private func waiting<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        let needsTimer = watch.state.withLock { state -> Bool in
            state.waitingSince = .now
            return state.timer == nil && !state.closed
        }
        if needsTimer {
            let timer = Task { [watch, connection, timeout] in await Self.expire(watch, connection: connection, after: timeout) }
            let kept = watch.state.withLock { state -> Bool in
                guard state.timer == nil, !state.closed else { return false }
                state.timer = timer
                return true
            }
            if !kept { timer.cancel() }
        }
        defer { watch.state.withLock { $0.waitingSince = nil } }
        do {
            return try await withTaskCancellationHandler(operation: operation, onCancel: { [connection] in connection.close() })
        } catch {
            if watch.state.withLock({ $0.timedOut }) { throw URLError(.timedOut) }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// The connection's timer: wakes when the current wait would have lasted `timeout`, and closes the connection if it has.
    private static func expire(_ watch: Watch, connection: any TCPConnection, after timeout: Duration) async {
        while !Task.isCancelled {
            let since = watch.state.withLock { $0.waitingSince } ?? .now
            try? await Task.sleep(until: since + timeout, clock: .continuous)
            let expired = watch.state.withLock { state -> Bool in
                guard !state.closed, let waiting = state.waitingSince, ContinuousClock.now - waiting >= timeout else { return false }
                state.timedOut = true
                return true
            }
            if expired {
                connection.close()
                return
            }
        }
    }
}

/// Removes HTTP chunked transfer coding from a byte stream (sizes in hex, extensions ignored, trailers dropped). A size line that
/// is not one (or longer than 1 KiB) ends the stream as malformed.
package struct ChunkedDecoder: Sendable {
    private var buffer = Data()
    private var remaining = 0
    private var expectingCRLF = false
    package private(set) var isFinished = false
    /// The stream ended at something that is not chunked coding.
    package private(set) var isMalformed = false

    package init() {}

    package mutating func feed(_ data: Data) -> Data {
        buffer.append(data)
        var output = Data()
        while !isFinished {
            if remaining > 0 {
                let take = min(remaining, buffer.count)
                guard take > 0 else { break }
                output.append(buffer.prefix(take))
                buffer = Data(buffer.dropFirst(take))
                remaining -= take
                if remaining == 0 { expectingCRLF = true }
            } else if expectingCRLF {
                guard buffer.count >= 2 else { break }
                buffer = Data(buffer.dropFirst(2))
                expectingCRLF = false
            } else {
                guard let end = buffer.range(of: Data("\r\n".utf8)) else {
                    if buffer.count > 1024 { malformed() }
                    break
                }
                let line = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer = Data(buffer[end.upperBound...])
                let size = line.split(separator: ";", maxSplits: 1).first.flatMap { Int($0.trimmingCharacters(in: .whitespaces), radix: 16) }
                guard let size, size >= 0 else { malformed(); break }
                if size == 0 { isFinished = true } else { remaining = size }
            }
        }
        return output
    }

    private mutating func malformed() {
        buffer = Data()
        isFinished = true
        isMalformed = true
    }
}
