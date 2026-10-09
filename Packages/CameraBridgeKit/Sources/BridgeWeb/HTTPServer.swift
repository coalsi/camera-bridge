import BridgeSupport
import Foundation
import Synchronization

/// An HTTP/1.1 server over the injected `NetworkTransport` (so it runs the same on macOS, on Linux and in tests over a
/// loopback socket).
///
/// - Keep-alive with pipelining; `Connection: close` and HTTP/1.0 close after the answer.
/// - Requests are parsed by `HTTPRequestParser` with a head limit and a body limit (`Limits`): an oversized head answers 431,
///   an oversized body 413 before the body is read, a chunked request body 501, a malformed message 400; the connection
///   closes after each of those.
/// - A new connection must send its first byte within `firstByteTimeout`, a request must arrive completely within
///   `requestTimeout` of its first byte (408 otherwise), and an idle keep-alive connection closes after `idleTimeout`, so a
///   client trickling bytes cannot hold a slot. At most `maxConnections` are open (and `maxConnectionsPerAddress` per peer):
///   a newcomer closes the oldest connection that is not answering a request, and is refused when every slot is busy.
/// - A streaming answer (`HTTPResponse.Body.stream`: server-sent events, multipart JPEG) is chunked, ends with the closure and
///   closes the connection. The server watches the connection while it streams, so a client that leaves ends the closure's
///   task (cancellation) at once; a client that stops reading is dropped after `writeTimeout`.
/// - A listener the platform stops on its own is replaced (same port, with backoff).
public actor HTTPServer {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public struct Limits: Sendable {
        public var maxBodySize = 256 * 1024
        public var maxHeadSize = 16 * 1024
        public var maxHeaderCount = 64
        public var maxConnections = 128
        public var maxConnectionsPerAddress = 48
        public var firstByteTimeout: Duration = .seconds(10)
        public var requestTimeout: Duration = .seconds(20)
        public var idleTimeout: Duration = .seconds(30)
        public var writeTimeout: Duration = .seconds(20)
        public var maxRequestsPerConnection = 1_000
        public var relistenDelay: Duration = .seconds(1)
        public var relistenMaximumDelay: Duration = .seconds(30)

        public init() {}
    }

    /// One accepted connection and whether it is answering a request (a busy one is never evicted).
    private final class Slot: Sendable {
        let connection: any TCPConnection
        let sequence: UInt64
        let busy = Mutex(false)
        let task = Mutex<Task<Void, Never>?>(nil)

        init(connection: any TCPConnection, sequence: UInt64) {
            self.connection = connection
            self.sequence = sequence
        }
    }

    private let port: UInt16
    private let loopbackOnly: Bool
    private let transport: any NetworkTransport
    private let limits: Limits
    private let handler: Handler
    private let log = Log(category: "web")
    private var listener: (any TCPListener)?
    private var acceptTask: Task<Void, Never>?
    private var relistenTask: Task<Void, Never>?
    private var slots: [UUID: Slot] = [:]
    private var sequence: UInt64 = 0
    private var generation = 0
    private var starting: Task<UInt16, any Error>?

    public init(port: UInt16, loopbackOnly: Bool = false, transport: any NetworkTransport, limits: Limits = Limits(),
                handler: @escaping Handler) {
        self.port = port
        self.loopbackOnly = loopbackOnly
        self.transport = transport
        self.limits = limits
        self.handler = handler
    }

    deinit {
        listener?.close()
        acceptTask?.cancel()
        relistenTask?.cancel()
        for slot in slots.values {
            slot.connection.close()
            slot.task.withLock { $0?.cancel() }
        }
    }

    /// The port the server listens on; nil while stopped (or listening again after its listener failed).
    public var boundPort: UInt16? { listener?.port }

    /// Connections currently open (tests).
    public var connectionCount: Int { slots.count }

    /// Starts listening and returns the port (the ephemeral one when the server was made with port 0).
    @discardableResult
    public func start() async throws -> UInt16 {
        if let listener { return listener.port }
        if let starting { return try await starting.value }
        let task = Task { try await self.bind(port: self.port) }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func bind(port: UInt16) async throws -> UInt16 {
        let generation = generation
        let listener = try await transport.listen(port: port, loopbackOnly: loopbackOnly)
        guard generation == self.generation else {
            listener.close()
            throw TransportError.closed
        }
        self.listener = listener
        acceptTask = makeAcceptTask(for: listener)
        relistenTask?.cancel()
        relistenTask = nil
        log.info("web interface listening on port \(listener.port)\(loopbackOnly ? " (loopback only)" : "")")
        return listener.port
    }

    public func stop() async {
        generation += 1
        starting = nil
        relistenTask?.cancel()
        relistenTask = nil
        listener?.close()
        listener = nil
        acceptTask?.cancel()
        acceptTask = nil
        let open = Array(slots.values)
        slots.removeAll()
        for slot in open {
            slot.connection.close()
            slot.task.withLock { $0?.cancel() }
        }
    }

    // MARK: Accepting

    private func makeAcceptTask(for listener: any TCPListener) -> Task<Void, Never> {
        Task { [weak self] in
            for await connection in listener.connections {
                guard let self else {
                    connection.close()
                    continue
                }
                await self.accept(connection)
            }
            guard !Task.isCancelled else { return }
            await self?.listenerStopped(listener)
        }
    }

    private func listenerStopped(_ failed: any TCPListener) {
        guard let current = listener, current === failed else { return }
        let previousPort = failed.port
        failed.close()
        listener = nil
        acceptTask = nil
        log.error("web interface listener on port \(previousPort) stopped; listening again")
        let (generation, initial, maximum) = (generation, limits.relistenDelay, limits.relistenMaximumDelay)
        relistenTask?.cancel()
        relistenTask = Task { [weak self] in
            var delay = initial
            while !Task.isCancelled {
                guard let finished = await self?.relistenAttempt(port: previousPort, generation: generation), !finished else { return }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, maximum)
            }
        }
    }

    /// True once there is nothing more to try (listening, or stopped).
    private func relistenAttempt(port: UInt16, generation: Int) async -> Bool {
        guard generation == self.generation, listener == nil else { return true }
        do {
            _ = try await bind(port: self.port != 0 ? self.port : port)
            return true
        } catch {
            guard generation == self.generation else { return true }
            log.error("web interface could not listen again on port \(port): \(Redact.string(String(describing: error))); retrying")
            return false
        }
    }

    private func accept(_ connection: any TCPConnection) {
        guard listener != nil else {
            connection.close()
            return
        }
        let address = connection.remoteAddress
        // Per peer: close this peer's oldest idle connection to admit the newcomer, else refuse the newcomer.
        while slots.values.filter({ $0.connection.remoteAddress == address }).count >= limits.maxConnectionsPerAddress {
            guard evictOldest(where: { $0.connection.remoteAddress == address }) else {
                log.debug("web connection from \(address) refused: it already has \(limits.maxConnectionsPerAddress) busy connections")
                connection.close()
                return
            }
        }
        while slots.count >= limits.maxConnections {
            guard evictOldest(where: { _ in true }) else {
                log.debug("web connection from \(address) refused: \(limits.maxConnections) busy connections")
                connection.close()
                return
            }
        }
        sequence += 1
        let slot = Slot(connection: connection, sequence: sequence)
        let id = connection.id
        let (handler, limits, log) = (handler, limits, log)
        slots[id] = slot
        let task = Task { [weak self] in
            await Self.serve(slot, handler: handler, limits: limits, log: log)
            await self?.finished(id)
        }
        slot.task.withLock { $0 = task }
    }

    private func evictOldest(where matches: (Slot) -> Bool) -> Bool {
        guard let (id, oldest) = slots.filter({ !$0.value.busy.withLock { $0 } && matches($0.value) })
            .min(by: { $0.value.sequence < $1.value.sequence }) else { return false }
        slots[id] = nil
        oldest.connection.close()
        oldest.task.withLock { $0?.cancel() }
        return true
    }

    private func finished(_ id: UUID) {
        slots[id] = nil
    }

    // MARK: Serving one connection

    private static func serve(_ slot: Slot, handler: Handler, limits: Limits, log: Log) async {
        let connection = slot.connection
        defer { connection.close() }
        var parser = HTTPRequestParser(maxBodySize: limits.maxBodySize, maxHeadSize: limits.maxHeadSize, maxHeaderCount: limits.maxHeaderCount)
        var requestStart: ContinuousClock.Instant?
        var served = 0
        while !Task.isCancelled {
            let limit: Duration
            if let requestStart {
                limit = limits.requestTimeout - (.now - requestStart)
            } else {
                limit = served == 0 ? limits.firstByteTimeout : limits.idleTimeout
            }
            guard limit > .zero else {
                await sendError(connection, status: 408, limits: limits)
                return
            }
            let data: Data?
            do {
                data = try await withDeadline(limit) { try await connection.receive(maximumLength: 16 * 1024) }
            } catch is DeadlineExceeded {
                if requestStart != nil { await sendError(connection, status: 408, limits: limits) }
                return
            } catch {
                return
            }
            guard let data else { return }
            if data.isEmpty { continue }
            if requestStart == nil { requestStart = .now }
            let requests: [(head: HTTPRequestHead, body: Data)]
            do {
                requests = try parser.feed(data)
            } catch {
                let status: Int
                switch error as? HTTPParseError {
                case .headTooLarge: status = 431
                case .bodyTooLarge: status = 413
                case .unsupportedTransferEncoding: status = 501
                default: status = 400
                }
                await sendError(connection, status: status, limits: limits)
                return
            }
            if requests.isEmpty { continue }
            requestStart = parser.pendingHead == nil ? nil : .now
            for (head, body) in requests {
                served += 1
                slot.busy.withLock { $0 = true }
                defer { slot.busy.withLock { $0 = false } }
                let request = HTTPRequest(method: head.method, target: head.target, version: head.version, headers: head.headers, body: body,
                                          remoteAddress: connection.remoteAddress)
                var response = await handler(request)
                let wantsClose = head.version != "HTTP/1.1" || head.headers["Connection"]?.lowercased().contains("close") == true
                    || served >= limits.maxRequestsPerConnection
                if head.method == "HEAD", case .stream = response.body { response.body = .data(Data()) }
                switch response.body {
                case .data(let payload):
                    if wantsClose { response.headers["Connection"] = "close" }
                    var out = HTTPSerializer.response(status: response.status, headers: stamped(response.headers), body: payload)
                    if head.method == "HEAD" { out = out.prefix(out.count - payload.count).withUnsafeBytes { Data($0) } }
                    do { try await send(out, on: connection, limits: limits) } catch { return }
                    if wantsClose { return }
                case .stream(let body):
                    await stream(response, body: body, request: head, connection: connection, limits: limits)
                    return
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: any TCPConnection, limits: Limits) async throws {
        try await withDeadline(limits.writeTimeout) { try await connection.send(data) }
    }

    private static func sendError(_ connection: any TCPConnection, status: Int, limits: Limits) async {
        var headers = HTTPHeaders([("Content-Type", "text/plain; charset=utf-8"), ("Connection", "close")])
        headers = stamped(headers)
        let text = HTTPSerializer.reasonPhrase(for: status) + "\n"
        try? await send(HTTPSerializer.response(status: status, headers: headers, body: Data(text.utf8)), on: connection, limits: limits)
    }

    /// Chunked answer until `body` returns; the connection closes afterwards.
    private static func stream(_ response: HTTPResponse, body: @escaping @Sendable (ResponseStream) async throws -> Void,
                               request: HTTPRequestHead, connection: any TCPConnection, limits: Limits) async {
        var headers = response.headers
        let chunked = request.version == "HTTP/1.1"
        if chunked { headers["Transfer-Encoding"] = "chunked" }
        headers["Connection"] = "close"
        headers["Content-Length"] = nil
        var head = "HTTP/1.1 \(response.status) \(HTTPSerializer.reasonPhrase(for: response.status))\r\n"
        for (name, value) in stamped(headers) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        do { try await send(Data(head.utf8), on: connection, limits: limits) } catch { return }
        let sink = ResponseStream { data in
            if chunked {
                var chunk = Data("\(String(data.count, radix: 16))\r\n".utf8)
                chunk.append(data)
                chunk.append(contentsOf: [0x0D, 0x0A])
                try await send(chunk, on: connection, limits: limits)
            } else {
                try await send(data, on: connection, limits: limits)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await body(sink)
                    if chunked { try await send(Data("0\r\n\r\n".utf8), on: connection, limits: limits) }
                } catch {}
            }
            group.addTask {
                // The client leaving (or closing its side) ends the answer; whatever it sends meanwhile is ignored.
                while !Task.isCancelled {
                    guard (try? await connection.receive(maximumLength: 1_024)) != nil else { return }
                }
            }
            await group.next()
            connection.close()
            group.cancelAll()
        }
    }

    /// `Date` on every answer.
    private static func stamped(_ headers: HTTPHeaders) -> HTTPHeaders {
        var headers = headers
        if headers["Date"] == nil { headers["Date"] = HTTPDate.string(from: Date()) }
        return headers
    }
}

/// RFC 9110 `Date` / `Last-Modified` values ("Thu, 08 Oct 2026 12:00:00 GMT"), without a locale-dependent formatter.
enum HTTPDate {
    private static let cache = Mutex<(second: Int, text: String)>((-1, ""))
    private static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func string(from date: Date) -> String {
        let second = Int(date.timeIntervalSince1970.rounded(.down))
        if let cached = cache.withLock({ $0.second == second ? $0.text : nil }) { return cached }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: Date(timeIntervalSince1970: Double(second)))
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        let year = String(format: "%04d", parts.year ?? 1970)
        let text = "\(days[((parts.weekday ?? 1) - 1) % 7]), \(two(parts.day ?? 1)) \(months[((parts.month ?? 1) - 1) % 12]) \(year) "
            + "\(two(parts.hour ?? 0)):\(two(parts.minute ?? 0)):\(two(parts.second ?? 0)) GMT"
        cache.withLock { $0 = (second, text) }
        return text
    }
}
