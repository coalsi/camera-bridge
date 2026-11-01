import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

public enum HTTPClientError: Error, Equatable, Sendable {
    case notHTTPResponse
    /// `data(for:)` stopped reading an answer whose body is (or announces, with Content-Length) more than `limit` bytes.
    case bodyTooLarge(limit: Int)
}

/// URLSession wrapper that answers Basic/Digest challenges with the given credentials (per-instance session + delegate).
///
/// Challenges are answered by this class rather than by URLSession, so Digest `SHA-256` works, the last challenge per
/// host is reused preemptively (nonce count incremented), and every request costs one round trip once authenticated.
/// URLSession's own challenge handling is suppressed (it would silently re-send each 401'd request once): the session
/// delegate cancels the HTTP auth challenge and captures the 401 response instead.
/// Wrong credentials cause exactly one authenticated attempt; the 401 is then returned to the caller.
/// A host that asked for Digest is never answered with Basic during the client's life (`BasicDowngradeGuard`: a host
/// impersonating the camera would read the password from it); its Basic-only 401 is returned to the caller.
///
/// Camera answers are hostile input: `data(for:)` keeps at most `maximumBodySize` body bytes (a longer body, or a longer
/// Content-Length, cancels the request with `HTTPClientError.bodyTooLarge`) and each of its round trips must end within
/// `timeout` (`URLError(.timedOut)`), so a camera answering with an endless body can neither exhaust memory nor hold its
/// caller forever.
///
/// Redirects are followed, as URLSession does by default (a camera behind one still answers), unless the client is made with
/// `followsRedirects: false`: then a 3xx answer is the answer, and the request (its headers, its body) goes to no other address. The AI
/// client is made so: a key saved for one service must never travel to the address a redirect names.
///
/// Portable: bodies use delegate callbacks (no `URLSession.AsyncBytes`, which is Darwin-only).
///
/// Plain `http://` requests go through `PlainHTTP` on a raw connection instead of URLSession once a transport is set for them
/// (`routePlainHTTP(through:)`: the Linux daemon, where URLSession keeps libdispatch busy while it waits for an answer). They behave
/// as above; a redirect is followed by this client then (at most `maximumRedirects` in a row, `URLError(.httpTooManyRedirects)`
/// beyond), as URLSession would: 303, and 301/302 after a POST, become a GET without a body, and the Authorization header goes only
/// to the same host. HTTPS always takes URLSession.
public final class AuthenticatingHTTPClient: Sendable {
    private enum CachedAuth: Sendable {
        case basic
        case digest(DigestChallenge, DigestAuthenticator)
    }

    /// The `data(for:)` body limit of the contract initializer: camera API, SOAP and snapshot answers are far smaller.
    public static let defaultMaximumBodySize = 16 << 20

    /// Redirects of plain-HTTP requests followed in a row.
    static let maximumRedirects = 10

    /// The transport every client's plain-HTTP requests take (`routePlainHTTP(through:)`); nil: URLSession.
    private static let plainHTTPTransport = Mutex<(any NetworkTransport)?>(nil)

    /// A route for plain-HTTP requests made in this task (tests: the Linux daemon's route without changing every client's).
    @TaskLocal package static var plainHTTPRoute: (any NetworkTransport)?

    /// Sends every client's plain `http://` requests through `transport` (`PlainHTTP`) instead of URLSession; nil goes back to
    /// URLSession. The Linux daemon does at start: swift-corelibs-foundation's URLSession keeps the write source it made to send
    /// a request, which wakes libdispatch again and again while the answer is awaited (an ONVIF pull, an event stream, HTTP-FLV).
    package static func routePlainHTTP(through transport: (any NetworkTransport)?) {
        plainHTTPTransport.withLock { $0 = transport }
    }

    private let session: URLSession
    private let sessionDelegate: SessionDelegate
    private let credentials: HTTPCredentials?
    /// At least 1 s: each wait for data, and each `data(for:)` round trip in total.
    private let timeout: Duration
    private let maximumBodySize: Int
    private let cache = Mutex<[String: CachedAuth]>([:])
    /// Hosts that asked for Digest are never answered with Basic (kept when a rejected retry clears `cache`).
    private let downgradeGuard: BasicDowngradeGuard
    /// Plain-HTTP connections in use, closed by `invalidate()`.
    private let plainConnections = PlainConnections()
    private let log = Log(category: "http")

    /// `timeout` bounds each wait for data, and each `data(for:)` round trip in total; `data(for:)` bodies are limited
    /// to `defaultMaximumBodySize`.
    public convenience init(credentials: HTTPCredentials?, timeout: Duration = .seconds(10), allowSelfSignedTLS: Bool = true) {
        self.init(credentials: credentials, timeout: timeout, allowSelfSignedTLS: allowSelfSignedTLS, maximumBodySize: Self.defaultMaximumBodySize)
    }

    /// As the contract initializer, with `data(for:)` bodies limited to `maximumBodySize` bytes (at least 1).
    public convenience init(credentials: HTTPCredentials?, timeout: Duration, allowSelfSignedTLS: Bool, maximumBodySize: Int) {
        self.init(credentials: credentials, timeout: timeout, allowSelfSignedTLS: allowSelfSignedTLS, maximumBodySize: maximumBodySize,
                  downgradeGuard: BasicDowngradeGuard())
    }

    /// `downgradeGuard`: shared with the camera's other clients of the same host (a media source's reconnects), so a
    /// fresh client does not answer Basic after Digest either. `followsRedirects: false`: a redirect is not followed (the 3xx answer
    /// is returned, with its `Location` header); the camera clients keep the default.
    package init(credentials: HTTPCredentials?, timeout: Duration, allowSelfSignedTLS: Bool, maximumBodySize: Int,
                 downgradeGuard: BasicDowngradeGuard, followsRedirects: Bool = true) {
        self.downgradeGuard = downgradeGuard
        self.credentials = credentials
        self.timeout = max(.seconds(1), timeout)
        self.maximumBodySize = max(1, maximumBodySize)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = self.timeout.timeInterval
        #if !os(Linux)
        configuration.waitsForConnectivity = false   // swift-corelibs-foundation: get-only (and false)
        #endif
        sessionDelegate = SessionDelegate(allowSelfSignedTLS: allowSelfSignedTLS, followsRedirects: followsRedirects)
        session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// The whole answer. Throws `HTTPClientError.bodyTooLarge` once the body (or its Content-Length) passes the limit, and
    /// `URLError(.timedOut)` when a round trip (the request, or its authenticated retry) takes longer than `timeout`; the
    /// request is cancelled then. Cancelling the caller cancels the request and throws `CancellationError`.
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await send(prepare(request), capture: credentials != nil)
        guard response.statusCode == 401, let retry = authenticatedRetry(of: request, after: response) else {
            return (data ?? Data(), response)
        }
        let (retryData, retryResponse) = try await send(retry, capture: true)
        if retryResponse.statusCode == 401 { forgetAuth(for: request) }
        return (retryData ?? Data(), retryResponse)
    }

    /// Long-lived streaming body (e.g. Hikvision alertStream, HTTP-FLV). Returns with the response head, which
    /// URLSession reports together with the first body bytes (or EOF); body chunks are yielded as URLSession
    /// receives them and the stream ends on EOF (finishes) or error (throws).
    /// Dropping or cancelling the stream cancels the request. The request timeout applies to each wait for data.
    /// Rejected credentials (or an unanswerable challenge) return the 401 response with an empty body, after exactly
    /// one authenticated attempt.
    public func stream(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        switch try await openStream(prepare(request), capture: credentials != nil) {
        case .opened(let response, let body):
            return (response, body)
        case .challenged(let challenged):
            guard let retry = authenticatedRetry(of: request, after: challenged) else { return (challenged, Self.emptyBody()) }
            switch try await openStream(retry, capture: true) {
            case .opened(let response, let body):
                if response.statusCode == 401 { forgetAuth(for: request) }
                return (response, body)
            case .challenged(let rejected):
                forgetAuth(for: request)
                return (rejected, Self.emptyBody())
            }
        }
    }

    /// Cancels outstanding tasks and releases the session. The client must not be used afterwards.
    public func invalidate() {
        session.invalidateAndCancel()
        plainConnections.invalidate()
    }

    // MARK: - Internals

    /// Runs one buffered round trip within `timeout`. With `capture`, an HTTP auth challenge cancels the task and its 401
    /// response is returned with a nil body instead of letting URLSession re-send the request.
    private func send(_ request: URLRequest, capture: Bool) async throws -> (Data?, HTTPURLResponse) {
        do {
            return try await withDeadline(timeout) { try await self.collect(request, capture: capture) }
        } catch is DeadlineExceeded {
            throw URLError(.timedOut)
        }
    }

    /// One round trip, through `PlainHTTP` (following its redirects) or URLSession. With `capture`, a 401 with a challenge is
    /// returned with a nil body.
    private func collect(_ request: URLRequest, capture: Bool) async throws -> (Data?, HTTPURLResponse) {
        var request = request
        for _ in 0...Self.maximumRedirects {
            guard let transport = plainTransport(for: request) else { return try await collectThroughSession(request, capture: capture) }
            let answer = try await collectPlain(request, transport: transport, capture: capture)
            guard let next = redirection(of: request, by: answer.1) else { return answer }
            request = next
        }
        throw URLError(.httpTooManyRedirects)
    }

    /// One plain-HTTP round trip: the body is read up to `maximumBodySize` (one announced as longer is not read at all).
    private func collectPlain(_ request: URLRequest, transport: any NetworkTransport, capture: Bool) async throws -> (Data?, HTTPURLResponse) {
        let (response, body) = try await PlainHTTP.open(request, transport: transport, timeout: timeout, track: plainConnections.add)
        defer { body.close() }
        if capture, Self.isChallenge(response) { return (nil, response) }
        if let length = body.expectedLength, length > maximumBodySize { throw HTTPClientError.bodyTooLarge(limit: maximumBodySize) }
        var data = Data()
        while let chunk = try await body.next() {
            guard chunk.count <= maximumBodySize - data.count else { throw HTTPClientError.bodyTooLarge(limit: maximumBodySize) }
            data.append(chunk)
        }
        return (data, response)
    }

    /// Starts a data task whose callbacks go to a `BufferedTask`; returns at completion (or with the captured 401).
    private func collectThroughSession(_ request: URLRequest, capture: Bool) async throws -> (Data?, HTTPURLResponse) {
        let task = session.dataTask(with: request)
        let handler = BufferedTask(captureHTTPAuth: capture, limit: maximumBodySize)
        sessionDelegate.register(handler, for: task)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handler.awaitCompletion(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Opens a streaming request through `PlainHTTP` (following its redirects) or URLSession; returns at the response head (or the
    /// captured 401).
    private func openStream(_ request: URLRequest, capture: Bool) async throws -> StreamOpening {
        var request = request
        for _ in 0...Self.maximumRedirects {
            guard let transport = plainTransport(for: request) else { return try await openSessionStream(request, capture: capture) }
            let (response, body) = try await PlainHTTP.open(request, transport: transport, timeout: timeout, track: plainConnections.add)
            if capture, Self.isChallenge(response) {
                body.close()
                return .challenged(response)
            }
            guard let next = redirection(of: request, by: response) else { return .opened(response, body.stream()) }
            body.close()
            request = next
        }
        throw URLError(.httpTooManyRedirects)
    }

    /// Starts a data task whose callbacks go to a `StreamTask`; returns at the response head (or the captured 401).
    private func openSessionStream(_ request: URLRequest, capture: Bool) async throws -> StreamOpening {
        let task = session.dataTask(with: request)
        let handler = StreamTask(captureHTTPAuth: capture)
        handler.onBodyTermination { task.cancel() }
        sessionDelegate.register(handler, for: task)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handler.awaitOpening(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The transport for `request` when it goes through `PlainHTTP`.
    private func plainTransport(for request: URLRequest) -> (any NetworkTransport)? {
        guard PlainHTTP.handles(request) else { return nil }
        return Self.plainHTTPRoute ?? Self.plainHTTPTransport.withLock { $0 }
    }

    private static func isChallenge(_ response: HTTPURLResponse) -> Bool {
        response.statusCode == 401 && response.value(forHTTPHeaderField: "WWW-Authenticate") != nil
    }

    /// The request a plain-HTTP redirect leads to, made as URLSession makes it; nil when the client does not follow redirects or
    /// the answer is not one.
    private func redirection(of request: URLRequest, by response: HTTPURLResponse) -> URLRequest? {
        guard sessionDelegate.followsRedirects, [301, 302, 303, 307, 308].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location, relativeTo: request.url)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var next = request
        next.url = url
        let method = (request.httpMethod ?? "GET").uppercased()
        if (response.statusCode == 303 && method != "HEAD") || ([301, 302].contains(response.statusCode) && method == "POST") {
            next.httpMethod = "GET"
            next.httpBody = nil
            next.setValue(nil, forHTTPHeaderField: "Content-Type")
        }
        if Self.hostKey(url) != Self.hostKey(request.url) { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        return next
    }

    private static func emptyBody() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private static func hostKey(_ url: URL?) -> String {
        guard let url else { return "" }
        return "\(url.scheme ?? ""):\(url.host ?? ""):\(url.port ?? -1)"
    }

    private static func digestURI(_ url: URL?) -> String {
        PlainHTTP.requestTarget(url)
    }

    /// Applies the timeout and any cached (preemptive) authorization.
    private func prepare(_ request: URLRequest) -> URLRequest {
        var request = request
        request.timeoutInterval = timeout.timeInterval
        guard let credentials, request.value(forHTTPHeaderField: "Authorization") == nil else { return request }
        let key = Self.hostKey(request.url)
        let header: String? = cache.withLock { cache in
            switch cache[key] {
            case .basic:
                return BasicAuth.header(credentials)
            case .digest(let challenge, var authenticator):
                let value = authenticator.authorization(for: challenge, method: request.httpMethod ?? "GET", uri: Self.digestURI(request.url),
                                                        body: request.httpBody ?? Data())
                cache[key] = .digest(challenge, authenticator)
                return value
            case nil:
                return nil
            }
        }
        if let header { request.setValue(header, forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Builds the authenticated retry for a 401 and caches the scheme for later requests.
    /// Nil when there are no credentials or the challenge cannot be answered: also a Basic challenge from a host that
    /// asked for Digest before (`BasicDowngradeGuard`).
    private func authenticatedRetry(of request: URLRequest, after response: HTTPURLResponse) -> URLRequest? {
        guard let credentials, request.value(forHTTPHeaderField: "Authorization") == nil,
              let challengeText = response.value(forHTTPHeaderField: "WWW-Authenticate") else { return nil }
        let key = Self.hostKey(request.url)
        var retry = request
        retry.timeoutInterval = timeout.timeInterval
        if let challenge = DigestChallenge.parse(challengeText) {
            downgradeGuard.digestRequested(by: key)
            let header: String = cache.withLock { cache in
                var authenticator = DigestAuthenticator(credentials: credentials)
                if case .digest(_, let existing) = cache[key] { authenticator = existing }
                let value = authenticator.authorization(for: challenge, method: request.httpMethod ?? "GET", uri: Self.digestURI(request.url),
                                                        body: request.httpBody ?? Data())
                cache[key] = .digest(challenge, authenticator)
                return value
            }
            retry.setValue(header, forHTTPHeaderField: "Authorization")
            return retry
        }
        if challengeText.range(of: #"(^|[\s,])basic(\s|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            guard downgradeGuard.mayAnswerBasic(from: key, log: log) else { return nil }
            cache.withLock { $0[key] = .basic }
            retry.setValue(BasicAuth.header(credentials), forHTTPHeaderField: "Authorization")
            return retry
        }
        log.debug("Unsupported authentication challenge from \(key)")
        return nil
    }

    private func forgetAuth(for request: URLRequest) {
        let key = Self.hostKey(request.url)
        _ = cache.withLock { $0.removeValue(forKey: key) }
    }
}

/// The plain-HTTP connections a client has open; `invalidate()` closes them, and any opened after it.
private final class PlainConnections: Sendable {
    private struct State {
        var invalidated = false
        var open: [ObjectIdentifier: WatchedConnection] = [:]
    }
    private let state = Mutex(State())

    /// False once invalidated.
    func add(_ connection: WatchedConnection) -> Bool {
        let id = ObjectIdentifier(connection)
        connection.onClose { [weak self] in self?.state.withLock { _ = $0.open.removeValue(forKey: id) } }
        return state.withLock { state -> Bool in
            guard !state.invalidated else { return false }
            state.open[id] = connection
            return true
        }
    }

    func invalidate() {
        let open = state.withLock { state -> [WatchedConnection] in
            state.invalidated = true
            defer { state.open = [:] }
            return Array(state.open.values)
        }
        for connection in open { connection.close() }
    }
}

// MARK: - Delegates

/// Server-trust handling for the session delegate's session- and task-level challenges. Self-signed certificates
/// (cameras) are accepted when allowed; returns false for any other challenge.
private func handleServerTrust(_ challenge: URLAuthenticationChallenge, allowSelfSignedTLS: Bool,
                               completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Bool {
    #if canImport(Darwin)
    let space = challenge.protectionSpace
    guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else { return false }
    if allowSelfSignedTLS, let trust = space.serverTrust {
        completionHandler(.useCredential, URLCredential(trust: trust))
    } else {
        completionHandler(.performDefaultHandling, nil)
    }
    return true
    #else
    return false   // FoundationNetworking has no server-trust challenges; self-signed TLS is not accepted there yet.
    #endif
}

/// One data task's callbacks, routed by `SessionDelegate`.
private protocol TaskHandler: AnyObject, Sendable {
    /// Whether an HTTP Basic/Digest challenge is captured (its 401 kept and the task cancelled, so the client answers
    /// it) instead of left to URLSession (which then delivers the 401).
    var captureHTTPAuth: Bool { get }
    func captureChallenge(_ response: HTTPURLResponse)
    func didReceive(response: URLResponse) -> URLSession.ResponseDisposition
    /// False cancels the task.
    func didReceive(data: Data) -> Bool
    func didComplete(error: (any Error)?)
}

/// State of one `data(for:)` data task: collects at most `limit` body bytes. A longer body, or a Content-Length above
/// `limit`, fails the request with `bodyTooLarge` at once (dropping what was collected) and cancels the task.
private final class BufferedTask: TaskHandler {
    typealias Answer = (Data?, HTTPURLResponse)

    let captureHTTPAuth: Bool
    let limit: Int
    private struct State {
        var continuation: CheckedContinuation<Answer, any Error>?
        /// The outcome while no continuation waits for it (the task may end before the caller is suspended).
        var pending: Result<Answer, any Error>?
        var settled = false
        var response: HTTPURLResponse?
        var capturedChallenge: HTTPURLResponse?
        var body = Data()
    }
    private let state = Mutex(State())

    init(captureHTTPAuth: Bool, limit: Int) {
        self.captureHTTPAuth = captureHTTPAuth
        self.limit = limit
    }

    func awaitCompletion(_ continuation: CheckedContinuation<Answer, any Error>) {
        let pending = state.withLock { state -> Result<Answer, any Error>? in
            defer { state.pending = nil }
            if state.pending == nil { state.continuation = continuation }
            return state.pending
        }
        if let pending { continuation.resume(with: pending) }
    }

    func captureChallenge(_ response: HTTPURLResponse) {
        state.withLock { $0.capturedChallenge = response }
    }

    func didReceive(response: URLResponse) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            settle(.failure(HTTPClientError.notHTTPResponse))
            return .cancel
        }
        if http.expectedContentLength > Int64(limit) {
            settle(.failure(HTTPClientError.bodyTooLarge(limit: limit)))
            return .cancel
        }
        state.withLock { $0.response = http }
        return .allow
    }

    func didReceive(data: Data) -> Bool {
        let fits = state.withLock { state -> Bool in
            guard !state.settled, data.count <= limit - state.body.count else { return false }
            state.body.append(data)
            return true
        }
        if !fits { settle(.failure(HTTPClientError.bodyTooLarge(limit: limit))) }
        return fits
    }

    func didComplete(error: (any Error)?) {
        let (response, challenge, body) = state.withLock { ($0.response, $0.capturedChallenge, $0.body) }
        if let challenge {
            settle(.success((nil, challenge)))
        } else if let error {
            settle(.failure(error))
        } else if let response {
            settle(.success((body, response)))
        } else {
            settle(.failure(HTTPClientError.notHTTPResponse))
        }
    }

    /// The first outcome is the caller's; the collected body is released.
    private func settle(_ outcome: Result<Answer, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Answer, any Error>? in
            guard !state.settled else { return nil }
            state.settled = true
            state.body = Data()
            defer { state.continuation = nil }
            if state.continuation == nil { state.pending = outcome }
            return state.continuation
        }
        continuation?.resume(with: outcome)
    }
}

/// Result of starting a streaming request.
private enum StreamOpening: Sendable {
    case opened(HTTPURLResponse, AsyncThrowingStream<Data, any Error>)
    /// The server answered 401 with a challenge; the task was cancelled before any body was read.
    case challenged(HTTPURLResponse)
}

/// State of one `stream(for:)` data task, fed by `SessionDelegate` callbacks.
private final class StreamTask: TaskHandler {
    let captureHTTPAuth: Bool
    private let bodyContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private struct State {
        var opening: CheckedContinuation<StreamOpening, any Error>?
        var capturedChallenge: HTTPURLResponse?
        /// Handed to the caller with the response and not retained afterwards, so dropping it terminates the stream.
        var body: AsyncThrowingStream<Data, any Error>?
        /// The first response was delivered: further ones are the parts of a `multipart/x-mixed-replace` response.
        var answered = false
    }
    private let state: Mutex<State>

    init(captureHTTPAuth: Bool) {
        self.captureHTTPAuth = captureHTTPAuth
        let (body, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        bodyContinuation = continuation
        state = Mutex(State(body: body))
    }

    /// Called when the consumer drops or cancels the body stream (or it finishes).
    func onBodyTermination(_ handler: @escaping @Sendable () -> Void) {
        bodyContinuation.onTermination = { _ in handler() }
    }

    func awaitOpening(_ continuation: CheckedContinuation<StreamOpening, any Error>) {
        state.withLock { $0.opening = continuation }
    }

    func captureChallenge(_ response: HTTPURLResponse) {
        state.withLock { $0.capturedChallenge = response }
    }

    func didReceive(response: URLResponse) -> URLSession.ResponseDisposition {
        let (opening, body, answered) = state.withLock { state in
            defer { state.opening = nil; state.body = nil; state.answered = true }
            return (state.opening, state.body, state.answered)
        }
        if answered {
            // A `multipart/x-mixed-replace` response (Dahua and DoorBird event streams, MJPEG): URLSession ends each part with a
            // new response and hands over the part bodies without their boundaries. The stream stays open; a line break marks
            // where one part ended, so line-oriented readers never see two parts run together.
            bodyContinuation.yield(Data([0x0A]))
            return .allow
        }
        // The first part of such a response may arrive as a plain `URLResponse` (its headers are the part's): the server answered 200.
        let http = (response as? HTTPURLResponse) ?? response.url.flatMap {
            HTTPURLResponse(url: $0, statusCode: 200, httpVersion: "HTTP/1.1",
                            headerFields: response.mimeType.map { ["Content-Type": $0] } ?? [:])
        }
        guard let http, let opening, let body else {
            opening?.resume(throwing: HTTPClientError.notHTTPResponse)
            bodyContinuation.finish(throwing: HTTPClientError.notHTTPResponse)
            return .cancel
        }
        if captureHTTPAuth, http.statusCode == 401, http.value(forHTTPHeaderField: "WWW-Authenticate") != nil {
            // Where URLSession reports no HTTP auth challenge to the delegate (swift-corelibs-foundation) the 401 arrives as an
            // ordinary response: it is the captured challenge, and its body is not read.
            opening.resume(returning: .challenged(http))
            bodyContinuation.finish()
            return .cancel
        }
        opening.resume(returning: .opened(http, body))
        return .allow
    }

    func didReceive(data: Data) -> Bool {
        bodyContinuation.yield(data)
        return true
    }

    func didComplete(error: (any Error)?) {
        let (opening, challenge) = state.withLock { state in
            defer { state.opening = nil; state.body = nil }
            return (state.opening, state.capturedChallenge)
        }
        if let opening {
            if let challenge {
                opening.resume(returning: .challenged(challenge))
            } else {
                opening.resume(throwing: error ?? HTTPClientError.notHTTPResponse)
            }
            bodyContinuation.finish()
        } else if let error {
            bodyContinuation.finish(throwing: error)
        } else {
            bodyContinuation.finish()
        }
    }
}

/// Session delegate: server trust for every task, whether a redirect is followed, and challenge/response/data/completion routing to each task's handler
/// (`BufferedTask` for `data(for:)`, `StreamTask` for `stream(for:)`).
private final class SessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let allowSelfSignedTLS: Bool
    let followsRedirects: Bool
    private let handlers = Mutex<[Int: any TaskHandler]>([:])

    init(allowSelfSignedTLS: Bool, followsRedirects: Bool) {
        self.allowSelfSignedTLS = allowSelfSignedTLS
        self.followsRedirects = followsRedirects
    }

    func register(_ handler: any TaskHandler, for task: URLSessionTask) {
        handlers.withLock { $0[task.taskIdentifier] = handler }
    }

    private func handler(for task: URLSessionTask) -> (any TaskHandler)? {
        handlers.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if handleServerTrust(challenge, allowSelfSignedTLS: allowSelfSignedTLS, completionHandler: completionHandler) { return }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if handleServerTrust(challenge, allowSelfSignedTLS: allowSelfSignedTLS, completionHandler: completionHandler) { return }
        if let handler = handler(for: task), handler.captureHTTPAuth,
           let response = challenge.failureResponse as? HTTPURLResponse, response.statusCode == 401 {
            handler.captureChallenge(response)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    /// A redirect is followed (URLSession's own default: the request as it proposes it) unless the client refuses them: then the 3xx
    /// response itself completes the task, and nothing is sent to the address it names.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(followsRedirects ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        completionHandler(handler(for: dataTask)?.didReceive(response: response) ?? .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = handler(for: dataTask), handler.didReceive(data: data) else {
            dataTask.cancel()
            return
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let handler = handlers.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        handler?.didComplete(error: error)
    }
}
