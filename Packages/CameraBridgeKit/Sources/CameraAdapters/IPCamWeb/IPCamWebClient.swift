import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

// The IPCamera Web family (docs/integrations/ipcamera-web.md): OEM cameras whose web page is titled "IPCamera Web" (the owner's N801B-RB-IRC-WM701,
// ONVIF manufacturer "A_ONVIF_CAMERA"). Camera Bridge uses their own API next to ONVIF to read what can reach outside the home (the maker's
// cloud, DDNS, RTMP, extra services, video without a password) and for three steps of "Set up for Camera Bridge".

/// Per camera address (scheme, host, web port): whether the address showed the family's sign-in page, whether the camera refused
/// Camera Bridge's sign-in, and whether its last sign-in called the password insecure. A refusal stops every request to the address. The
/// camera's next start in the bridge (`cameraStarted`, from `ONVIFDriver.makeNightVision`) gives the sign-in a new try only when the camera's
/// username or password changed since, or 30 minutes after the refusal: a setup run or a settings change that restarts the camera never
/// resends a password the camera refused. Nothing is saved, so a restart of Camera Bridge itself (a reboot, an update) tries once more. The credentials are kept only as the SHA-256 of "username:password", in memory: never logged or saved.
/// Shared by every client of the address.
final class IPCamWebLatch: Sendable {
    static let shared = IPCamWebLatch()
    /// How long a refusal holds through the camera's starts while its username and password stay the same.
    static let refusalHold: TimeInterval = 30 * 60

    private struct Refusal {
        var at: Date
        /// `fingerprint` of the credentials the camera refused.
        var credentials: [UInt8]?
        /// The camera's code when it said why (532374: no privilege).
        var code: Int?
    }
    private struct State {
        var refused: [String: Refusal] = [:]
        var family: Set<String> = []
        var insecurePassword: Set<String> = []
    }
    private let state = Mutex(State())

    static func key(_ endpoint: CameraEndpoint) -> String { "\(endpoint.httpScheme)://\(endpoint.urlHost):\(endpoint.httpPort)" }

    /// The SHA-256 of "username:password" (nil without credentials).
    static func fingerprint(_ credentials: HTTPCredentials?) -> [UInt8]? {
        credentials.map { Hashes.sha256(Data("\($0.username):\($0.password)".utf8)) }
    }

    func isTripped(_ key: String) -> Bool { state.withLock { $0.refused[key] != nil } }

    /// Why nothing is sent to the address now (nil while its sign-in may be tried): the account's want of privilege when the camera said
    /// so (`IPCamWebUnavailable.noPrivilege`), else a refused sign-in (`.paused`).
    func refusal(_ key: String) -> IPCamWebUnavailable? {
        state.withLock { state in
            guard let refusal = state.refused[key] else { return nil }
            return refusal.code == IPCamWebCameraError.noPrivilege ? .noPrivilege : .paused
        }
    }

    /// Keeps the refusal of `credentials`, with the camera's `code` when it gave one. True the first time (the caller says so in the log once).
    @discardableResult
    func trip(_ key: String, credentials: HTTPCredentials?, code: Int? = nil, now: Date = Date()) -> Bool {
        let fingerprint = Self.fingerprint(credentials)
        return state.withLock { state in
            guard state.refused[key] == nil else { return false }
            state.refused[key] = Refusal(at: now, credentials: fingerprint, code: code)
            return true
        }
    }

    /// The camera started in the bridge with `credentials`: its page is checked again, and a refused sign-in gets a new try only with
    /// other credentials, or `refusalHold` after the refusal.
    func cameraStarted(_ key: String, credentials: HTTPCredentials?, now: Date = Date()) {
        let fingerprint = Self.fingerprint(credentials)
        state.withLock { state in
            state.family.remove(key)
            if let refusal = state.refused[key], refusal.credentials != fingerprint || now.timeIntervalSince(refusal.at) >= Self.refusalHold {
                state.refused[key] = nil
            }
        }
    }

    func isFamily(_ key: String) -> Bool { state.withLock { $0.family.contains(key) } }

    func markFamily(_ key: String) { state.withLock { _ = $0.family.insert(key) } }

    /// The camera's last sign-in answered 532379: it signed Camera Bridge in, but calls the password insecure and asks for a stronger one.
    func asksForStrongerPassword(_ key: String) -> Bool { state.withLock { $0.insecurePassword.contains(key) } }

    /// What a sign-in answered about the password. True when the camera starts calling it insecure (the caller says so in the log once).
    @discardableResult
    func signedIn(_ key: String, insecurePassword: Bool) -> Bool {
        state.withLock { state in
            guard insecurePassword else {
                state.insecurePassword.remove(key)
                return false
            }
            return state.insecurePassword.insert(key).inserted
        }
    }

    /// Forgets the address (tests: a fake camera's ephemeral port must not keep what an earlier test left).
    func reset(_ key: String) {
        state.withLock { state in
            state.refused[key] = nil
            state.family.remove(key)
            state.insecurePassword.remove(key)
        }
    }
}

/// The camera's web server did not answer its sign-in page or script (a transport error, a timeout, or a 5xx, as while the camera starts):
/// whether it is of the family is not known yet. Nothing is kept, so the next check asks again.
struct IPCamWebNoAnswer: Error, Equatable, CustomStringConvertible {
    var description: String { "the camera’s web server did not answer" }
}

/// The camera answered a call with an error code (`<root><code>N</code><error>…</error></root>`). The codes are those of the camera's own
/// page (`land.js`, `common.js`).
struct IPCamWebCameraError: Error, Equatable, LocalizedError, CustomStringConvertible {
    /// "no option": the camera has no such feature.
    static let noOption = 532229
    /// The session is not valid (the page goes back to its sign-in): a call signs in once more and asks again, once. A sign-in answered
    /// this way is refused.
    static let invalidSession = 532227
    /// "No Privilege": the account Camera Bridge signs in with may not do this.
    static let noPrivilege = 532374
    /// A sign-in answered this way is signed in, with a session, but the camera calls the password insecure (its page then asks for a new
    /// one: 9 to 16 characters with a letter, a digit and a symbol).
    static let insecurePassword = 532379

    var code: Int
    var description: String {
        code == Self.noPrivilege
            ? "the camera says the account Camera Bridge signs in with may not do this (no privilege); use an administrator account in the camera’s settings"
            : "the camera answered error \(code)"
    }
    var errorDescription: String? { description }
}

/// A camera of the family whose API cannot be used now: its features say why and change nothing.
struct IPCamWebUnavailable: Error, Equatable, LocalizedError, CustomStringConvertible {
    static let paused = IPCamWebUnavailable(reason: "the camera did not take Camera Bridge’s sign-in to its web page, so Camera Bridge stopped "
                                            + "asking it; it tries again once the camera’s username or password changes in Camera Bridge, or "
                                            + "when the camera restarts in the bridge after 30 minutes")
    /// The sign-in refused for want of privilege (532374): the account may not use the camera's web page.
    static let noPrivilege = IPCamWebUnavailable(reason: "the camera says the account Camera Bridge uses has no privilege for its web page (use an "
                                                 + "administrator account in the camera’s settings), so Camera Bridge stopped asking it; it tries "
                                                 + "again once the camera’s username or password changes in Camera Bridge, or when the camera "
                                                 + "restarts in the bridge after 30 minutes")
    static let noCredentials = IPCamWebUnavailable(reason: "Camera Bridge has no username or password for this camera")
    static let noSession = IPCamWebUnavailable(reason: "the camera signed in without giving a session")

    let reason: String

    /// The account may not use the camera's web page (`noPrivilege`): a step this stops is a change the account may not make
    /// (`CameraSetupOutcome.notPermitted`), not a wrong password, so the setup goes on with the steps after it.
    var notPermitted: Bool { self == Self.noPrivilege }

    var description: String { reason }
    var errorDescription: String? { reason }
}

/// A client of one camera's IPCamera Web API. Every call is an HTTP `GET` without a body on the web port: the sign-in
/// `/cgi/auth.cgi?act=auth&auth=123456&data=<xml>&guid=<ms>`, reads `/cgi/<name>.cgi?get=<what>&auth=<session>&guid=<ms>`, writes
/// `…?set=<what>&auth=<session>&data=<xml>&guid=<ms>` (each value encoded as the camera's page's browser sends it: `percentEncoded`);
/// answers are `<root>…</root>`, and one without `<code>` is code 0, as the camera's page reads it (`hXmlVal`'s default). The sign-in
/// value (`encrypted(username:password:)`) can be turned back into nothing better than the password's hash, but it is still the camera's
/// login: it goes only to a camera whose page and sign-in script, loaded without it, are the family's (`showsItsPage()`), and never while
/// the camera's logins are paused (`ONVIFLoginGuard`, shared with ONVIF: the same account).
/// The session is kept and reused; a call answered 532227 (session not valid) signs in once more. A refused sign-in trips the address's
/// `IPCamWebLatch` and stops this API only: the family's ONVIF and RTSP may ask no password at all, so ONVIF's logins go on. One HTTP
/// client for the client's life; 10 s per request. Nothing the camera answers, no session and no sign-in value is ever logged: only the
/// code of a refused sign-in.
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
    /// `ONVIFLoginGuard`'s keys for this camera ("host:port" of the web port and of the ONVIF port): one account behind both, so a paused
    /// ONVIF login stops the sign-in too.
    private let loginKeys: [String]
    private let log: Log
    private var session: String?
    private var signingIn: Task<String, any Error>?
    /// The camera's last sign-in at this address signed Camera Bridge in but called the password insecure (532379), for the security check.
    nonisolated var asksForStrongerPassword: Bool { latch.asksForStrongerPassword(key) }
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

    /// The sign-in value: the MD5 of "username:password" (`WyzeMD5`, the same RFC 1321 hash) in UPPERCASE hex, as the camera's page has it
    /// (its `md5-min.js` uppercases), encrypted with RC4 under "pwnsd", in lowercase hex. A camera never matches the lowercase hash.
    static func encrypted(username: String, password: String) -> String {
        IPCamWebRC4.hex(IPCamWebRC4.apply(key: signInKey, to: Array(WyzeMD5.hex(username + ":" + password).uppercased().utf8)))
    }

    /// What a query value keeps as it is: the bytes the camera's page's browser sends raw. The page appends the XML to the URL unencoded,
    /// and the browser encodes only the WHATWG URL standard's special-query set (controls, space, `"`, `#`, `'`, `<`, `>`, and what is not
    /// ASCII), so `=`, `/`, `?` and `:` go raw. Also encoded here: what would change the query's meaning (`&`, `+`, `%`) and what a URL
    /// can't carry raw (`[`, `\`, `]`, `^`, `` ` ``, `{`, `|`, `}`).
    private static let rawInQuery = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$()*,;:@/?=".utf8)

    /// `text` as the camera's page's browser puts it in the query (`rawInQuery`; every other byte as `%XX`): the camera reads the XML
    /// exactly, from the same bytes it gets from its own page.
    static func percentEncoded(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if rawInQuery.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
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

    /// `set=<what>` with `<?xml version='1.0'?><root>` + `element` + `</root>`, as the camera's page writes it. A write the camera answers
    /// 532374 ("No Privilege") once it signed Camera Bridge in is a change the account may not make: `CameraAdapterError.notPermitted`
    /// (owner decision, 2026-10-18: no wrong password, nothing latched, the setup's other steps still run).
    func write(_ what: String, element: String, cgi: String = "network") async throws {
        _ = try await call(cgi, op: "set", what: what, data: "<?xml version='1.0'?><root>\(element)</root>")
    }

    /// One call with the session (signing in first when there is none); a 532227 answer (the session is not valid) signs in once more and
    /// asks again. A write answered 532374 throws `CameraAdapterError.notPermitted` ("set mobile"), any other code `IPCamWebCameraError`.
    /// An answer of the camera's without a code is done (code 0, as on the camera's page: its reads never carry one); one that is not the
    /// camera's XML is `invalidResponse`.
    private func call(_ cgi: String, op: String, what: String, data: String?) async throws -> String {
        for attempt in 0..<2 {
            let current = try await validSession()
            var items = [(op, what), ("auth", current)]
            if let data { items.append(("data", data)) }
            items.append(("guid", Self.millis()))
            let answer = try await send("/cgi/\(cgi).cgi", items)
            guard answer.contains("<root") else { throw CameraAdapterError.invalidResponse("\(op) \(what): not the camera's answer") }
            if let code = Self.code(in: answer), code != 0 {
                if code == IPCamWebCameraError.invalidSession, attempt == 0 {
                    if session == current { session = nil }
                    continue
                }
                if code == IPCamWebCameraError.noPrivilege, op == "set" {
                    log.info("The camera's web API does not let this account change \(what) (code \(code): no privilege)")
                    throw CameraAdapterError.notPermitted("\(op) \(what)")
                }
                throw IPCamWebCameraError(code: code)
            }
            return answer
        }
        throw IPCamWebCameraError(code: IPCamWebCameraError.invalidSession)
    }

    /// Signs in now when there is no session yet (the setup asks first, so a refusal is a reason its steps give, not an error in one).
    func signIn() async throws {
        _ = try await validSession()
    }

    private func validSession() async throws -> String {
        if let session { return session }
        if let signingIn { return try await signingIn.value }
        let task = Task { try await self.newSession() }
        signingIn = task
        defer { if signingIn == task { signingIn = nil } }
        return try await task.value
    }

    /// Signs in: only to a camera of the family, never while its logins are paused or after it refused one. The code is read as the
    /// camera's page reads it (`signInCode(in:)`): an answer of the camera's without `<code>` is 0 (most likely how the owner's camera
    /// answered build 0.1.111's sign-in, which that build could not read and stopped the API for). Answered 0, or 532379 (signed in, but the camera calls the password
    /// insecure), with an `authid`: the session; without one, `IPCamWebUnavailable.noSession` (nothing latched). Any other code is a
    /// refusal, as on the camera's page ("Login Failed!"). An answer that is not the camera's XML (no `<root>`), or whose code is not a
    /// number, is unreadable (`invalidResponse`), not a refused password. A refusal or an unreadable answer stops this API only (`refused`).
    private func newSession() async throws -> String {
        guard let credentials else { throw IPCamWebUnavailable.noCredentials }
        guard try await showsItsPage() else { throw CameraAdapterError.unsupported("the camera is not of the IPCamera Web family") }
        if let refusal = latch.refusal(key) { throw refusal }
        if let pause = ONVIFLoginGuard.shared.pause(hosts: loginKeys) { throw pause.error }   // the camera's lock, or Camera Bridge's own pause
        let data = "<?xml version='1.0'?><root><mode>1</mode><encrypt>\(Self.encrypted(username: credentials.username, password: credentials.password))</encrypt></root>"
        let answer = try await send("/cgi/auth.cgi", [("act", "auth"), ("auth", Self.signInAuth), ("data", data), ("guid", Self.millis())])
        guard answer.contains("<root") else {
            refused("answered Camera Bridge's sign-in with something other than its XML")
            throw CameraAdapterError.invalidResponse("the sign-in's answer is not the camera's")
        }
        guard let code = Self.signInCode(in: answer) else {
            refused("answered Camera Bridge's sign-in with a code that is not a number")
            throw CameraAdapterError.invalidResponse("the sign-in's code is not a number")
        }
        let insecure = code == IPCamWebCameraError.insecurePassword
        guard code == 0 || insecure else {
            let noPrivilege = code == IPCamWebCameraError.noPrivilege
            refused("refused Camera Bridge's sign-in (code \(code)\(noPrivilege ? ": no privilege" : ""))", code: code)
            throw noPrivilege ? IPCamWebCameraError(code: code) : CameraAdapterError.unauthorized
        }
        guard let id = Self.text("authid", in: answer), !id.isEmpty else { throw IPCamWebUnavailable.noSession }
        session = id
        if latch.signedIn(key, insecurePassword: insecure) {
            log.warning("The camera signed Camera Bridge in to its web API, but it calls the camera's password insecure and asks for a stronger "
                        + "password (9 to 16 characters with a letter, a digit and a symbol): change it in the camera's web page, then in Camera Bridge")
        }
        log.debug("Signed in to the camera's web API")
        return id
    }

    /// One `GET`. The URL holds the session or the sign-in value: it is never put in an error or the log.
    private func send(_ path: String, _ items: [(String, String)]) async throws -> String {
        if let refusal = latch.refusal(key) { throw refusal }
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
            refused("refused Camera Bridge (HTTP \(response.statusCode))")
            throw CameraAdapterError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else { throw CameraAdapterError.httpStatus(response.statusCode) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Trips the latch for this API only. ONVIF's logins are not paused: the family's ONVIF and RTSP may ask no password at all (the
    /// owner's camera's don't), and pausing them stopped the camera's events and snapshots for 2 minutes at every start, for nothing.
    /// `what` names the camera's answer (its code, or an HTTP status): never the URL, the sign-in value, a session or the answer's text;
    /// `code` is kept with the refusal, so a want of privilege is said as such (`IPCamWebLatch.refusal`).
    private func refused(_ what: String, code: Int? = nil) {
        guard latch.trip(key, credentials: credentials, code: code) else { return }
        log.warning("The camera's web API \(what): Camera Bridge stops asking it until the camera's username or password changes in Camera "
                    + "Bridge, or the camera restarts in the bridge after 30 minutes, so the camera does not lock its account")
    }

    /// The answer's `<code>`, nil when it has none.
    static func code(in answer: String) -> Int? {
        text("code", in: answer).flatMap { Int($0) }
    }

    /// The sign-in answer's code as the camera's page reads it (`land.js`: `hXmlVal({t:'code'})`, `common.js`): 0 when the answer has no
    /// `<code>` or an empty one (`hXmlVal`'s default), else its number; nil when it is not a number (the page then says "Login Failed!").
    static func signInCode(in answer: String) -> Int? {
        guard let text = text("code", in: answer), !text.isEmpty else { return 0 }
        return Int(text)
    }

    /// The trimmed text of the first `name` element of `answer`.
    static func text(_ name: String, in answer: String) -> String? {
        guard let element = IPCWebXML.element(name, in: answer), let open = element.firstIndex(of: ">"),
              let close = element.range(of: "</", options: .backwards), open < close.lowerBound else { return nil }
        return element[element.index(after: open)..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func millis() -> String { String(Int64(Date().timeIntervalSince1970 * 1000)) }
}
