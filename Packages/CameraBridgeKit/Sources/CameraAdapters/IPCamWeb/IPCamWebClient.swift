import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

// The IPCamera Web family (docs/integrations/ipcamera-web.md): OEM cameras whose web page is titled "IPCamera Web" (the owner's N801B-RB-IRC-WM701,
// ONVIF manufacturer "A_ONVIF_CAMERA"). Camera Bridge uses their own API next to ONVIF to read what can reach outside the home (the maker's
// cloud, DDNS, RTMP, extra services, video without a password) and for three steps of "Set up for Camera Bridge".

/// Per camera address (scheme, host, web port): whether the address showed the family's sign-in page, and whether the camera refused
/// Camera Bridge's sign-in. A refusal stops every request to the address until the camera's next start in the bridge (`ONVIFDriver
/// .makeNightVision`), so a wrong password is never tried twice. Shared by every client of the address.
final class IPCamWebLatch: Sendable {
    static let shared = IPCamWebLatch()
    private struct State {
        var tripped: Set<String> = []
        var family: Set<String> = []
    }
    private let state = Mutex(State())

    static func key(_ endpoint: CameraEndpoint) -> String { "\(endpoint.httpScheme)://\(endpoint.urlHost):\(endpoint.httpPort)" }

    func isTripped(_ key: String) -> Bool { state.withLock { $0.tripped.contains(key) } }

    /// True the first time (the caller says so in the log once).
    @discardableResult
    func trip(_ key: String) -> Bool { state.withLock { $0.tripped.insert(key).inserted } }

    func isFamily(_ key: String) -> Bool { state.withLock { $0.family.contains(key) } }

    func markFamily(_ key: String) { state.withLock { _ = $0.family.insert(key) } }

    func reset(_ key: String) {
        state.withLock { state in
            state.tripped.remove(key)
            state.family.remove(key)
        }
    }
}

/// The camera's web server did not answer its sign-in page or script (a transport error, a timeout, or a 5xx, as while the camera starts):
/// whether it is of the family is not known yet. Nothing is kept, so the next check asks again.
struct IPCamWebNoAnswer: Error, Equatable, CustomStringConvertible {
    var description: String { "the camera’s web server did not answer" }
}

/// The camera answered a call with an error code (`<root><code>N</code><error>…</error></root>`).
struct IPCamWebCameraError: Error, Equatable, CustomStringConvertible {
    /// "no option": the camera has no such feature.
    static let noOption = 532229
    /// The session is no longer known: signed in again once.
    static let sessionExpired = 531203
    /// A sign-in answered this way is signed in too.
    static let alreadySignedIn = 531355

    var code: Int
    var description: String { "the camera answered error \(code)" }
}

/// A camera of the family whose API cannot be used now: its features say why and change nothing.
struct IPCamWebUnavailable: Error, Equatable, LocalizedError, CustomStringConvertible {
    static let paused = IPCamWebUnavailable(reason: "the camera refused Camera Bridge’s sign-in, so Camera Bridge stopped asking it until the camera "
                                            + "restarts in the bridge")
    static let noCredentials = IPCamWebUnavailable(reason: "Camera Bridge has no username or password for this camera")
    static let noSession = IPCamWebUnavailable(reason: "the camera signed in without giving a session")

    let reason: String

    var description: String { reason }
    var errorDescription: String? { reason }
}

/// A client of one camera's IPCamera Web API. Every call is an HTTP `GET` without a body on the web port: the sign-in
/// `/cgi/auth.cgi?act=auth&auth=123456&data=<xml>&guid=<ms>`, reads `/cgi/<name>.cgi?get=<what>&auth=<session>&guid=<ms>`, writes
/// `…?set=<what>&auth=<session>&data=<xml>&guid=<ms>` (every value percent-encoded); answers are `<root>…</root>`. The sign-in value
/// (`encrypted(username:password:)`) can be turned back into nothing better than the password's hash, but it is still the camera's
/// login: it goes only to a camera whose page and sign-in script, loaded without it, are the family's (`showsItsPage()`), and never
/// while the camera's logins are paused (`ONVIFLoginGuard`, shared with ONVIF: the same account). The session is kept and reused; a call
/// answered "session expired" signs in once more. A refused sign-in trips the address's `IPCamWebLatch` and pauses the camera's logins.
/// One HTTP client for the client's life; 10 s per request. Nothing the camera answers, no session and no sign-in value is ever logged.
actor IPCamWebClient {
    static let pageTitle = "IPCamera Web"
    /// The sign-in page names its script relatively (`../js/script/land.js`).
    static let pageScript = "js/script/land.js"
    static let signInScript = "/js/script/land.js"
    /// What the sign-in script holds: the sign-in call.
    static let signInMarker = "auth.cgi?act=auth"
    /// The RC4 key of the sign-in value, from the camera's own page.
    static let signInKey = Array("pwnsd".utf8)
    /// The `auth` the sign-in call carries before there is a session.
    static let signInAuth = "123456"

    let endpoint: CameraEndpoint
    private let credentials: HTTPCredentials?
    /// Camera Bridge has a password for the camera (the video password step needs one).
    nonisolated let hasPassword: Bool
    private let http: AuthenticatingHTTPClient
    private let latch: IPCamWebLatch
    private let key: String
    /// `ONVIFLoginGuard`'s keys for this camera ("host:port" of the web port and of the ONVIF port): one account behind both.
    private let loginKeys: [String]
    private let log: Log
    private var session: String?
    private var signingIn: Task<String, any Error>?
    /// What `showsItsPage()` found once the camera answered.
    private var probed: Bool?
    /// The camera's web server did not answer a page check (`IPCamWebNoAnswer`) during this client's life.
    private(set) var unanswered = false

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, cameraID: UUID? = nil, timeout: Duration = .seconds(10),
         latch: IPCamWebLatch = .shared) {
        self.endpoint = endpoint
        self.credentials = credentials
        hasPassword = credentials.map { !$0.password.isEmpty } ?? false
        http = AuthenticatingHTTPClient(credentials: nil, timeout: timeout)
        self.latch = latch
        key = IPCamWebLatch.key(endpoint)
        loginKeys = Self.loginKeys(endpoint)
        log = Log(category: "ipcam-web", cameraID: cameraID)
    }

    static func loginKeys(_ endpoint: CameraEndpoint) -> [String] {
        let web = "\(endpoint.host):\(endpoint.httpPort)", onvif = "\(endpoint.host):\(endpoint.onvifPort ?? endpoint.httpPort)"
        return web == onvif ? [web] : [web, onvif]
    }

    /// The sign-in value: the lowercase MD5 of "username:password" (`WyzeMD5`, the same RFC 1321 hash), encrypted with RC4 under "pwnsd",
    /// in lowercase hex.
    static func encrypted(username: String, password: String) -> String {
        IPCamWebRC4.hex(IPCamWebRC4.apply(key: signInKey, to: Array(WyzeMD5.hex(username + ":" + password).utf8)))
    }

    /// `text` with every byte outside the unreserved characters (letters, digits, `-._~`) as `%XX`, so the camera reads the XML exactly.
    static func percentEncoded(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    // MARK: Which cameras are asked

    /// Whether the camera's web server is the family's: `GET /` (no credentials) is titled "IPCamera Web" and names `js/script/land.js`, and
    /// that script holds the sign-in call. Remembered for the address (`IPCamWebLatch.isFamily`). A 2xx without them, or a 4xx, is
    /// another camera (kept for this client's life); no answer (a transport error, a timeout, a 5xx) throws `IPCamWebNoAnswer`: not known yet.
    func showsItsPage() async throws -> Bool {
        if latch.isFamily(key) { return true }
        if let probed { return probed }
        guard let page = try await load("/"), Self.isSignInPage(page) else {
            log.debug("The camera's web page is not the IPCamera Web family's")
            probed = false
            return false
        }
        guard let script = try await load(Self.signInScript), script.contains(Self.signInMarker) else {
            log.debug("The camera's web page is titled like the IPCamera Web family's, but its sign-in script is not theirs")
            probed = false
            return false
        }
        latch.markFamily(key)
        probed = true
        log.info("The camera's web page is the IPCamera Web family's")
        return true
    }

    /// The page's title is the family's and it loads the family's script.
    static func isSignInPage(_ html: String) -> Bool {
        guard let open = html.range(of: "<title>", options: .caseInsensitive),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex) else { return false }
        return html[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines) == pageTitle && html.contains(pageScript)
    }

    /// `path` without credentials: its first 64 KiB, nil for an answer that is not 2xx (and below 500).
    private func load(_ path: String) async throws -> String? {
        guard let url = endpoint.httpURL(path: path) else { return nil }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.data(for: CameraHTTP.request(url))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            unanswered = true
            throw IPCamWebNoAnswer()
        }
        guard response.statusCode < 500 else {
            unanswered = true
            throw IPCamWebNoAnswer()
        }
        guard (200..<300).contains(response.statusCode) else { return nil }
        return String(decoding: data.prefix(64 << 10), as: UTF8.self)
    }

    // MARK: Calls

    /// `get=<what>`: the whole answer; nil when the camera has no such option (532229).
    func read(_ what: String, cgi: String = "network") async throws -> String? {
        do {
            return try await call(cgi, op: "get", what: what, data: nil)
        } catch let error as IPCamWebCameraError where error.code == IPCamWebCameraError.noOption {
            return nil
        }
    }

    /// `set=<what>` with `<?xml version='1.0'?><root>` + `element` + `</root>`, as the camera's page writes it.
    func write(_ what: String, element: String, cgi: String = "network") async throws {
        _ = try await call(cgi, op: "set", what: what, data: "<?xml version='1.0'?><root>\(element)</root>")
    }

    /// One call with the session (signing in first when there is none); a "session expired" answer signs in once more and asks again.
    private func call(_ cgi: String, op: String, what: String, data: String?) async throws -> String {
        for attempt in 0..<2 {
            let current = try await validSession()
            var items = [(op, what), ("auth", current)]
            if let data { items.append(("data", data)) }
            items.append(("guid", Self.millis()))
            let answer = try await send("/cgi/\(cgi).cgi", items)
            guard answer.contains("<root") else { throw CameraAdapterError.invalidResponse("\(op) \(what): not the camera's answer") }
            if let code = Self.code(in: answer), code != 0 {
                if code == IPCamWebCameraError.sessionExpired, attempt == 0 {
                    if session == current { session = nil }
                    continue
                }
                throw IPCamWebCameraError(code: code)
            }
            return answer
        }
        throw IPCamWebCameraError(code: IPCamWebCameraError.sessionExpired)
    }

    private func validSession() async throws -> String {
        if let session { return session }
        if let signingIn { return try await signingIn.value }
        let task = Task { try await self.signIn() }
        signingIn = task
        defer { if signingIn == task { signingIn = nil } }
        return try await task.value
    }

    /// Signs in: only to a camera of the family, never while its logins are paused or after it refused one.
    private func signIn() async throws -> String {
        guard let credentials else { throw IPCamWebUnavailable.noCredentials }
        guard try await showsItsPage() else { throw CameraAdapterError.unsupported("the camera is not of the IPCamera Web family") }
        guard !latch.isTripped(key) else { throw IPCamWebUnavailable.paused }
        if let until = loginKeys.compactMap({ ONVIFLoginGuard.shared.blockedUntil(host: $0) }).max() { throw CameraAdapterError.lockedOut(until: until) }
        let data = "<?xml version='1.0'?><root><mode>1</mode><encrypt>\(Self.encrypted(username: credentials.username, password: credentials.password))</encrypt></root>"
        let answer = try await send("/cgi/auth.cgi", [("act", "auth"), ("auth", Self.signInAuth), ("data", data), ("guid", Self.millis())])
        let code = Self.code(in: answer)
        if code == 0 || code == IPCamWebCameraError.alreadySignedIn {
            guard let id = Self.text("authid", in: answer), !id.isEmpty else { throw IPCamWebUnavailable.noSession }
            session = id
            log.debug("Signed in to the camera's web API")
            return id
        }
        refused("the camera refused the sign-in")
        for key in loginKeys { ONVIFLoginGuard.shared.recordRejection(host: key) }
        throw CameraAdapterError.unauthorized
    }

    /// One `GET`. The URL holds the session or the sign-in value: it is never put in an error or the log.
    private func send(_ path: String, _ items: [(String, String)]) async throws -> String {
        guard !latch.isTripped(key) else { throw IPCamWebUnavailable.paused }
        let query = items.map { "\($0.0)=\(Self.percentEncoded($0.1))" }.joined(separator: "&")
        guard let base = endpoint.httpURL(path: path), let url = URL(string: base.absoluteString + "?" + query) else {
            throw CameraAdapterError.invalidResponse("invalid camera address")
        }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.data(for: CameraHTTP.request(url))
        } catch {
            throw CameraHTTP.sanitized(error)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            refused("HTTP \(response.statusCode)")
            for key in loginKeys { ONVIFLoginGuard.shared.recordRejection(host: key) }
            throw CameraAdapterError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else { throw CameraAdapterError.httpStatus(response.statusCode) }
        return String(decoding: data, as: UTF8.self)
    }

    private func refused(_ why: String) {
        guard latch.trip(key) else { return }
        log.warning("The camera's web API refused Camera Bridge's sign-in (\(why)): Camera Bridge stops asking it until the camera restarts in the "
                    + "bridge, so the camera does not lock its account")
    }

    /// The answer's `<code>`, nil when it has none.
    static func code(in answer: String) -> Int? {
        text("code", in: answer).flatMap { Int($0) }
    }

    /// The trimmed text of the first `name` element of `answer`.
    static func text(_ name: String, in answer: String) -> String? {
        guard let element = IPCWebXML.element(name, in: answer), let open = element.firstIndex(of: ">"),
              let close = element.range(of: "</", options: .backwards), open < close.lowerBound else { return nil }
        return element[element.index(after: open)..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func millis() -> String { String(Int64(Date().timeIntervalSince1970 * 1000)) }
}
