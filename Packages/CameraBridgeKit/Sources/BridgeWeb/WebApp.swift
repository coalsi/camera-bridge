import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Synchronization

/// How the web interface runs (the daemon fills it from its flags).
public struct WebConfiguration: Sendable {
    /// The bridge's data directory (the web interface keeps `web/auth.json` in it).
    public var dataDirectory: URL
    /// The interface's files; nil serves only the API.
    public var staticDirectory: URL?
    public var port: UInt16
    /// Listen on 127.0.0.1 only (development and tests).
    public var loopbackOnly: Bool
    /// Host names (besides IP addresses, `localhost`, `*.local`, `*.home.arpa` and names without a dot) that may be used in the address.
    public var allowedHosts: [String]
    /// When set, first-run setup asks for it (the image prints it on the console), so a stranger on the network cannot take over a new bridge.
    public var setupToken: String?
    public var product: String
    public var version: String
    public var build: String
    public var passwordIterations: Int
    /// Add `Secure` to the session cookie (when a TLS front end is in use).
    public var secureCookies: Bool
    /// How often the event stream looks at the bridge while somebody listens.
    public var eventInterval: Duration
    /// How often the live preview takes a picture.
    public var liveFrameInterval: Duration
    public var maximumLiveStreams: Int
    public var maximumEventStreams: Int
    /// A preview ends after this long; the page starts it again while it is open.
    public var liveLifetime: Duration
    /// List the demo camera (a test pattern) among the camera types.
    public var offersDemoCamera: Bool
    public var diagnosticsContext: @Sendable (_ launched: Date) -> DiagnosticsContext
    public var limits: HTTPServer.Limits

    public init(dataDirectory: URL, staticDirectory: URL? = nil, port: UInt16 = 80, loopbackOnly: Bool = false, allowedHosts: [String] = [],
                setupToken: String? = nil, product: String = "Camera Bridge OS", version: String = "0.1", build: String = "development",
                passwordIterations: Int = AuthStore.defaultIterations, secureCookies: Bool = false) {
        self.dataDirectory = dataDirectory
        self.staticDirectory = staticDirectory
        self.port = port
        self.loopbackOnly = loopbackOnly
        self.allowedHosts = allowedHosts
        self.setupToken = setupToken
        self.product = product
        self.version = version
        self.build = build
        self.passwordIterations = passwordIterations
        self.secureCookies = secureCookies
        eventInterval = .milliseconds(500)
        liveFrameInterval = .milliseconds(700)
        maximumLiveStreams = 6
        maximumEventStreams = 24
        liveLifetime = .seconds(900)
        offersDemoCamera = true
        limits = HTTPServer.Limits()
        diagnosticsContext = { launched in
            var context = DiagnosticsContext.current(appVersion: version, appBuild: build, macModel: "unknown", launched: launched)
            context.appName = product
            return context
        }
    }
}

/// What a handler sees of its request.
struct RequestContext: Sendable {
    var request: HTTPRequest
    var params: [String: String]
    var session: AuthStore.Session?
    var sessionToken: String?

    func uuid(_ name: String) throws -> UUID {
        guard let text = params[name], let id = UUID(uuidString: text) else { throw APIError.notFound("There is no camera with this identifier.") }
        return id
    }
}

/// A problem the API answers with: a status, a short code for the page's code and a sentence for the person.
struct APIError: Error {
    var status: Int
    var code: String
    var message: String
    var field: String?
    var headers: [(String, String)] = []

    static func badRequest(_ message: String, field: String? = nil) -> APIError {
        APIError(status: 400, code: "invalid", message: message, field: field)
    }

    static func notFound(_ message: String = "That doesn’t exist.") -> APIError {
        APIError(status: 404, code: "not_found", message: message)
    }

    static func conflict(_ code: String, _ message: String) -> APIError {
        APIError(status: 409, code: code, message: message)
    }

    static func unavailable(_ message: String) -> APIError {
        APIError(status: 503, code: "unavailable", message: message)
    }
}

private struct ErrorBody: Encodable {
    var error: String
    var message: String
    var field: String?
}

extension HTTPResponse {
    /// A JSON answer (`Cache-Control: no-store`: the API's answers are never kept).
    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONEncoder.iso.encode(value)) ?? Data("null".utf8)
        var response = HTTPResponse(status: status, contentType: "application/json; charset=utf-8", data: data)
        response.headers["Cache-Control"] = "no-store"
        return response
    }

    static func error(_ error: APIError) -> HTTPResponse {
        var response = json(ErrorBody(error: error.code, message: error.message, field: error.field), status: error.status)
        for (name, value) in error.headers { response.headers[name] = value }
        return response
    }
}

/// The web interface: the API under `/api/v1` and the interface's files, as a function from request to response. `WebService` puts it
/// behind an `HTTPServer`; tests call `handle` directly or over a loopback socket.
///
/// Security, in the order a request meets it:
/// 1. **Host header.** Only an IP address, `localhost`, a `.local` or `.home.arpa` name, a name without a dot, or a name in
///    `allowedHosts` is served, so a web page on the internet cannot reach the bridge through the visitor's browser by pointing a
///    name of its own at the bridge's address (DNS rebinding).
/// 2. **Setup.** Until the administrator's password exists, the API answers only the status, the session probe and setup itself.
/// 3. **Session.** Every other API call needs the `cb_session` cookie (256 random bits, `HttpOnly`, `SameSite=Strict`).
/// 4. **Cross-site requests.** A request that changes anything must have an `Origin` (or `Sec-Fetch-Site`) of this same site, and a
///    signed-in one must carry the session's `X-CSRF-Token`; a body must be `application/json`.
/// 5. **Headers on every answer.** A strict Content-Security-Policy (own files only), `nosniff`, no referrer, no framing, no
///    cross-origin reads; API answers are `no-store`.
public final class WebApp: Sendable {
    static let cookieName = "cb_session"

    let configuration: WebConfiguration
    let backend: any BridgeBackend
    let system: any SystemControlling
    let auth: AuthStore
    let logs: LogFeed
    let hub: EventHub
    let files: StaticFiles
    let launched: Date
    let log = Log(category: "web")
    private let streams = Mutex(StreamCounts())
    let nestSignIns = Mutex<[String: NestSignIn]>([:])

    struct StreamCounts {
        var live = 0
        var events = 0
    }

    public init(configuration: WebConfiguration, backend: any BridgeBackend, system: any SystemControlling, logs: LogFeed, auth: AuthStore? = nil) {
        self.configuration = configuration
        self.backend = backend
        self.system = system
        self.logs = logs
        self.auth = auth ?? AuthStore(directory: configuration.dataDirectory, iterations: configuration.passwordIterations)
        hub = EventHub(backend: backend, interval: configuration.eventInterval)
        files = StaticFiles(directory: configuration.staticDirectory)
        launched = Date()
    }

    func startEvents() {
        hub.start()
    }

    func stopEvents() {
        hub.stop()
    }

    // MARK: Stream slots

    func takeLiveSlot() -> Bool {
        streams.withLock { counts in
            guard counts.live < configuration.maximumLiveStreams else { return false }
            counts.live += 1
            return true
        }
    }

    func releaseLiveSlot() {
        streams.withLock { $0.live = max(0, $0.live - 1) }
    }

    func takeEventSlot() -> Bool {
        streams.withLock { counts in
            guard counts.events < configuration.maximumEventStreams else { return false }
            counts.events += 1
            return true
        }
    }

    func releaseEventSlot() {
        streams.withLock { $0.events = max(0, $0.events - 1) }
    }

    // MARK: Handling

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        var response = await dispatch(request)
        Self.addSecurityHeaders(to: &response, isAPI: request.path.hasPrefix("/api/"))
        log.debug("\(request.method) \(request.path) -> \(response.status)")
        return response
    }

    private func dispatch(_ request: HTTPRequest) async -> HTTPResponse {
        guard Self.hostAllowed(request, extra: configuration.allowedHosts) else {
            return .text("Unrecognised host name. Use the bridge’s IP address or its .local name.\n", status: 421)
        }
        let path = request.path
        guard path == "/api" || path.hasPrefix("/api/") else { return files.response(for: request) }
        do {
            return try await api(request)
        } catch let error as APIError {
            return .error(error)
        } catch let error as DecodingError {
            return .error(Self.badRequest(for: error))
        } catch let problem as SetupProblem {
            return .error(.badRequest(problem.message, field: problem.field))
        } catch {
            log.error("\(request.method) \(path) failed: \(ErrorText.logDescription(error))")
            return .error(APIError(status: 500, code: "internal", message: ErrorText.describe(error)))
        }
    }

    // MARK: API dispatch

    private func api(_ request: HTTPRequest) async throws -> HTTPResponse {
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2, segments[0] == "api", segments[1] == "v1" else { throw APIError.notFound("This address isn’t part of the API.") }
        let route: Route, params: [String: String]
        switch Router.match(method: request.method == "HEAD" ? "GET" : request.method, segments: Array(segments.dropFirst(2)), routes: Self.routes) {
        case .found(let found, let matched):
            (route, params) = (found, matched)
        case .methodNotAllowed(let allowed):
            throw APIError(status: 405, code: "method_not_allowed", message: "That isn’t possible here.", headers: [("Allow", allowed.joined(separator: ", "))])
        case .notFound:
            throw APIError.notFound("This address isn’t part of the API.")
        }
        let unsafe = !["GET", "HEAD"].contains(request.method)
        if unsafe {
            guard Self.originAllowed(request, secure: configuration.secureCookies) else {
                throw APIError(status: 403, code: "cross_origin", message: "This request came from another site, so it was refused.")
            }
            if !request.body.isEmpty {
                let type = (request.headers["Content-Type"] ?? "").lowercased()
                guard type.hasPrefix("application/json") else {
                    throw APIError(status: 415, code: "unsupported_media_type", message: "Send JSON with Content-Type: application/json.")
                }
            }
        }
        var context = RequestContext(request: request, params: params)
        let configured = await auth.isConfigured
        if let token = request.cookies[Self.cookieName], let session = await auth.session(token: token) {
            context.session = session
            context.sessionToken = token
        }
        if route.access == .session {
            guard configured else { throw APIError(status: 403, code: "setup_required", message: "Set the administrator password first.") }
            guard let session = context.session else {
                throw APIError(status: 401, code: "unauthorized", message: "Sign in to continue.", headers: [("Set-Cookie", Self.clearedCookie())])
            }
            if unsafe {
                guard let presented = request.headers["X-CSRF-Token"], Secrets.constantTimeEqual(presented, session.csrfToken) else {
                    throw APIError(status: 403, code: "csrf", message: "This page is out of date. Reload it and try again.")
                }
            }
        }
        return try await route.handler(self, context)
    }

    // MARK: Cookies

    func sessionCookie(token: String, secure: Bool) -> String {
        "\(Self.cookieName)=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(Int(AuthStore.absoluteLifetime))" + (secure || configuration.secureCookies ? "; Secure" : "")
    }

    static func clearedCookie() -> String {
        "\(cookieName)=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
    }

    // MARK: Request checks

    /// Whether the address in the `Host` header may reach the bridge (see the type's documentation).
    static func hostAllowed(_ request: HTTPRequest, extra: [String]) -> Bool {
        guard let name = request.hostName?.lowercased(), !name.isEmpty else { return request.version == "HTTP/1.0" }
        if extra.contains(where: { $0.lowercased() == name }) { return true }
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".local.") || name.hasSuffix(".home.arpa") { return true }
        if name.contains(":") { return name.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" || $0.isLetter } }   // IPv6
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return true }   // IPv4
        if !name.contains(".") { return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }   // a name on the local network
        return false
    }

    /// A request that changes something must come from this site: its `Origin` names the host it was sent to, or (no Origin) the
    /// browser says it is same-origin; a client that is no browser sends neither.
    static func originAllowed(_ request: HTTPRequest, secure: Bool = false) -> Bool {
        if let origin = request.headers["Origin"] {
            guard let range = origin.range(of: "://"), let host = request.headers["Host"],
                  origin[..<range.lowerBound].lowercased() == (secure ? "https" : "http") else { return false }
            return authority(String(origin[range.upperBound...])) == authority(host)
        }
        if let site = request.headers["Sec-Fetch-Site"]?.lowercased() { return site == "same-origin" || site == "none" }
        return true
    }

    private static func authority(_ text: String) -> String {
        var value = text.lowercased().trimmingCharacters(in: .whitespaces)
        if value.hasSuffix(":80") { value.removeLast(3) }
        return value
    }

    static func addSecurityHeaders(to response: inout HTTPResponse, isAPI: Bool) {
        response.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; "
            + "font-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Cross-Origin-Opener-Policy"] = "same-origin"
        response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
        response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
        if isAPI, response.headers["Cache-Control"] == nil { response.headers["Cache-Control"] = "no-store" }
    }

    /// A decoding error as the sentence the page shows, without quoting what was sent.
    static func badRequest(for error: DecodingError) -> APIError {
        func name(_ path: [any CodingKey]) -> String? {
            let text = path.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
            return text.isEmpty ? nil : text
        }
        switch error {
        case .keyNotFound(let key, _):
            return .badRequest("“\(key.stringValue)” is missing.", field: key.stringValue)
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let field = name(context.codingPath)
            return .badRequest(field.map { "“\($0)” has the wrong kind of value." } ?? "The request isn’t what was expected.", field: field)
        case .dataCorrupted(let context):
            let field = name(context.codingPath)
            return .badRequest(field.map { "“\($0)” isn’t one of the allowed values." } ?? "The request isn’t valid JSON.", field: field)
        @unknown default:
            return .badRequest("The request isn’t what was expected.")
        }
    }

    // MARK: Body helpers

    func decode<T: Decodable>(_ type: T.Type, from context: RequestContext) throws -> T {
        guard !context.request.body.isEmpty else { throw APIError.badRequest("The request has no body.") }
        do {
            return try JSONDecoder.iso.decode(type, from: context.request.body)
        } catch let error as DecodingError {
            throw Self.badRequest(for: error)
        } catch {
            throw APIError.badRequest("The request isn’t valid JSON.")
        }
    }
}

// MARK: - Routes

struct Route: Sendable {
    enum Access { case open, session }

    let method: String
    let pattern: [String]
    let access: Access
    let takesBody: Bool
    let handler: @Sendable (WebApp, RequestContext) async throws -> HTTPResponse

    init(_ method: String, _ path: String, _ access: Access = .session, takesBody: Bool = false,
         handler: @escaping @Sendable (WebApp, RequestContext) async throws -> HTTPResponse) {
        self.method = method
        self.pattern = path.split(separator: "/").map(String.init)
        self.access = access
        self.takesBody = takesBody
        self.handler = handler
    }
}

enum Router {
    enum Match {
        case found(Route, [String: String])
        case methodNotAllowed([String])
        case notFound
    }

    static func match(method: String, segments: [String], routes: [Route]) -> Match {
        var allowed: [String] = []
        for route in routes {
            guard let params = params(route.pattern, segments) else { continue }
            if route.method == method { return .found(route, params) }
            if !allowed.contains(route.method) { allowed.append(route.method) }
        }
        return allowed.isEmpty ? .notFound : .methodNotAllowed(allowed)
    }

    private static func params(_ pattern: [String], _ segments: [String]) -> [String: String]? {
        guard pattern.count == segments.count else { return nil }
        var result: [String: String] = [:]
        for (expected, actual) in zip(pattern, segments) {
            if expected.hasPrefix(":") {
                guard let decoded = actual.removingPercentEncoding, !decoded.isEmpty else { return nil }
                result[String(expected.dropFirst())] = decoded
            } else if expected != actual {
                return nil
            }
        }
        return result
    }
}
