import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

// The IP camera web API (docs/integrations/ip-camera-web-api.md): the camera's own web page's API, found on a family of OEM cameras (an
// Anjvision platform sold under many brands, whose sign-in page is titled "IP Camera Web Login"). Camera Bridge uses it next to ONVIF for what
// these cameras' ONVIF reports wrongly: night vision, the IR lights, the on-screen text and the maker's cloud.

/// What the IP camera web API's probe found.
struct IPCWebDevice: Sendable, Equatable {
    static let nightVisionFeature = "ircut_setting"
    static let lightFeature = "ircut_leddelay"
    static let cloudFeature = "p2p_config"

    /// `fsVersion` of `getSystemVersionInfo`: the camera's firmware version.
    var firmware: String
    /// `getSystemControlString`'s feature flags ("+gpio_input+ircut_setting+…").
    var features: Set<String>

    func has(_ feature: String) -> Bool { features.contains(feature) }

    /// The flags of a `getSystemControlString` answer.
    static func features(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == "+" || $0.isWhitespace }).map(String.init))
    }
}

/// Per camera address (scheme, host, web port): whether the bridge stopped using the camera's web API, and whether the address served
/// this family's sign-in script. A refused request (an HTTP error, a SOAP fault, or the camera saying `passwordError` / `passwordLock`) trips
/// it, because the camera locks its account after a few wrong logins and what a wrong password answers is not known. Shared by every
/// client of the address (the camera's night vision and its setup), so a refusal is never repeated, and a camera known to be of the
/// family is not taken for one without the API while it is paused; the camera's next start in the bridge clears both
/// (`ONVIFDriver.makeNightVision`).
final class IPCWebLatch: Sendable {
    static let shared = IPCWebLatch()
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

    /// The address served the family's sign-in script during this run (`IPCWebClient.showsItsPage()`).
    func isFamily(_ key: String) -> Bool { state.withLock { $0.family.contains(key) } }

    func markFamily(_ key: String) { state.withLock { _ = $0.family.insert(key) } }

    func reset(_ key: String) {
        state.withLock { state in
            state.tripped.remove(key)
            state.family.remove(key)
        }
    }
}

/// A camera of the family (its sign-in script is the API's) whose web API cannot be used now: paused after a refusal, not answering, or
/// a username or password it cannot take. The features that need it say so, and never fall back to ONVIF answers these cameras get wrong.
struct IPCWebUnavailable: Error, Equatable, LocalizedError, CustomStringConvertible {
    static let paused = IPCWebUnavailable(reason: "the camera’s web API refused a request, so Camera Bridge paused it until the camera restarts in the bridge")
    static let noAnswer = IPCWebUnavailable(reason: "the camera’s web API did not answer")
    static let credentials = IPCWebUnavailable(reason: "the camera’s username or password has a character its web API cannot take "
                                               + "(such as an emoji or a letter outside the Latin alphabet)")

    let reason: String

    var description: String { reason }
    var errorDescription: String? { reason }
}

/// The camera's web server did not answer its sign-in script (a transport error, a timeout, or a 5xx, as while the camera starts):
/// whether it is of the family is not known yet. Nothing is kept, so the next probe asks again (`IPCWebClient.probe()`).
struct IPCWebNoAnswer: Error, Equatable, CustomStringConvertible {
    var description: String { "the camera’s web server did not answer" }
}

/// A client of one camera's IP camera web API. Every call is `POST http://<host>:<web port>/<name>` with the `Content-Type` exactly
/// `application/x-www-form-urlencoded` (anything else reaches the camera's ONVIF server, which answers a fault) and a SOAP-like envelope
/// carrying the sign-in tokens (`IPCWebToken`); no cookie or session. Reads answer 200 with XML, writes 202 with nothing. A non-2xx
/// status, a SOAP fault or the camera's `passwordError` / `passwordLock` fails the call and trips the address's `IPCWebLatch`; after
/// that no request is sent. The tokens are the password in a form anyone can turn back (the key is in the camera's own page), so they
/// go only to a camera whose sign-in script, loaded without them, is this family's (`showsItsPage()`), and never while the camera's logins are
/// paused (`ONVIFLoginGuard`, shared with ONVIF: the same account); a login refusal pauses them in turn. One HTTP client for the
/// client's life; 10 s per request, like the ONVIF client. Texts are carried as ISO-8859-1, so what is read and written back keeps its
/// bytes.
actor IPCWebClient {
    static let contentType = "application/x-www-form-urlencoded"
    /// The family's sign-in script, served without a login. The sign-in page itself (`/`) is drawn by scripts: its HTML has an empty
    /// title, so the script is what tells the family apart.
    static let signInScript = "/jsCore/rpcLogin.js"
    /// What the sign-in script holds: the token scheme (`IPCWebToken`'s key) and the sign-in call.
    static let signInMarkers = ["des(\"WebLogin\"", "/ipcLogin"]

    let endpoint: CameraEndpoint
    /// The username's and password's tokens; nil when either has a character the API cannot take (above U+00FF).
    private let tokens: (user: String, password: String)?
    private let hasCredentials: Bool
    private let http: AuthenticatingHTTPClient
    private let latch: IPCWebLatch
    private let key: String
    /// `ONVIFLoginGuard`'s keys for this camera ("host:port" of the web port and of the ONVIF port): one account behind both.
    private let loginKeys: [String]
    private let log: Log
    /// The probe's answer once the camera gave one (the inner nil: it does not speak the API).
    private var probed: IPCWebDevice??

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, cameraID: UUID? = nil, timeout: Duration = .seconds(10),
         latch: IPCWebLatch = .shared) {
        self.endpoint = endpoint
        if let user = IPCWebToken.make(credentials?.username ?? ""), let password = IPCWebToken.make(credentials?.password ?? "") {
            tokens = (user, password)
        } else {
            tokens = nil
        }
        hasCredentials = credentials != nil
        http = AuthenticatingHTTPClient(credentials: nil, timeout: timeout)
        self.latch = latch
        key = IPCWebLatch.key(endpoint)
        loginKeys = Self.loginKeys(endpoint)
        log = Log(category: "ipc-web", cameraID: cameraID)
    }

    static func loginKeys(_ endpoint: CameraEndpoint) -> [String] {
        let web = "\(endpoint.host):\(endpoint.httpPort)", onvif = "\(endpoint.host):\(endpoint.onvifPort ?? endpoint.httpPort)"
        return web == onvif ? [web] : [web, onvif]
    }

    /// The request body: the envelope with the tokens (a literal tab before each) around `body`.
    static func envelope(user: String, password: String, body: String) -> String {
        "<?xml version=\"1.0\"?><soap:Envelope xmlns:soap=\"http://www.w3.org/2001/12/soap-envelope\"><soap:Header>\t<userid>\(user)</userid>"
            + "\t<passwd>\(password)</passwd></soap:Header><soap:Body>\(body)</soap:Body></soap:Envelope>"
    }

    /// The address served the family's sign-in script during this run (`IPCWebLatch.isFamily`).
    nonisolated var isFamily: Bool { latch.isFamily(key) }

    /// `probe()`, with a web server that did not answer taken as no web API (the setup's steps then go through ONVIF, as for any other
    /// camera); nothing is kept, so the next call asks again.
    func device() async throws -> IPCWebDevice? {
        do {
            return try await probe()
        } catch is IPCWebNoAnswer {
            return nil
        }
    }

    /// Whether the camera speaks the API, and what it offers: its sign-in script first (`showsItsPage()`, no credentials), then
    /// `getSystemVersionInfo` (its `SystemVersionInfo`) and `getSystemControlString`. Kept once answered; nil when it does not speak it
    /// (another web server, or a camera of the family that does not answer the API). Throws `IPCWebNoAnswer` when the web server did not
    /// answer its sign-in script (asked again next time); for a camera of the family that cannot be asked now, `IPCWebUnavailable` (paused
    /// after a refusal, no answer: asked again next time; or credentials that cannot be sent), and the camera's login refusal
    /// (`CameraAdapterError.unauthorized` / `.lockedOut`) and `CancellationError` as they are.
    func probe() async throws -> IPCWebDevice? {
        if let probed { return probed }
        guard try await showsItsPage() else {
            probed = .some(nil)
            return nil
        }
        guard tokens != nil else {
            // Not taken for a camera without the API either: its ONVIF answers would be used, and they are wrong.
            log.debug("The camera's page is the IP camera web API's, but the username or password has characters it cannot take: not asked")
            throw IPCWebUnavailable.credentials
        }
        guard !latch.isTripped(key) else { throw IPCWebUnavailable.paused }
        do {
            let info = try await call("getSystemVersionInfo", body: "")
            guard let root = IPCWebXML.element("SystemVersionInfo", in: info) else {
                log.debug("The camera's page is the IP camera web API's, but the camera does not answer it: Camera Bridge uses ONVIF")
                probed = .some(nil)
                return nil
            }
            let firmware = IPCWebXML.element("VersionInfo", in: String(root)).flatMap { IPCWebXML.attribute("fsVersion", of: $0) } ?? ""
            let device = IPCWebDevice(firmware: firmware, features: IPCWebDevice.features(try await call("getSystemControlString", body: "")))
            log.info("The camera speaks the IP camera web API (\(Redact.cameraText(firmware)))")
            probed = .some(device)
            return device
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw latch.isTripped(key) ? IPCWebUnavailable.paused : IPCWebUnavailable.noAnswer
        }
    }

    /// Whether the camera's web server is this family's: its sign-in script (`GET signInScript`, no credentials sent) holds
    /// `signInMarkers`. Remembered for the address (`IPCWebLatch.isFamily`), so later clients of the camera do not load it again. A 2xx
    /// without them, or a 4xx (404: another web server), is not the family's. No answer (a transport error, a timeout, or a 5xx while the
    /// camera starts) throws `IPCWebNoAnswer`: not known yet.
    func showsItsPage() async throws -> Bool {
        if latch.isFamily(key) { return true }
        guard let url = endpoint.httpURL(path: Self.signInScript) else { return false }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.data(for: CameraHTTP.request(url))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            log.debug("The camera's web sign-in script did not load: asked again next time")
            throw IPCWebNoAnswer()
        }
        guard response.statusCode < 500 else {
            log.debug("The camera's web server answered HTTP \(response.statusCode) for its sign-in script: asked again next time")
            throw IPCWebNoAnswer()
        }
        guard (200..<300).contains(response.statusCode), Self.isFamilyPage(data) else {
            log.debug("The camera's web server is not the IP camera web API's: Camera Bridge uses ONVIF")
            return false
        }
        latch.markFamily(key)
        return true
    }

    /// The sign-in script holds every one of `signInMarkers`, in its first 64 KiB.
    static func isFamilyPage(_ data: Data) -> Bool {
        let text = String(data: data.prefix(64 << 10), encoding: .isoLatin1) ?? ""
        return signInMarkers.allSatisfy { text.contains($0) }
    }

    /// A read: the whole answer as the camera wrote it. Throws when it has no `root` element (nothing is tripped for that).
    func read(_ name: String, root: String) async throws -> String {
        let text = try await call(name, body: "")
        guard IPCWebXML.element(root, in: text) != nil else { throw CameraAdapterError.invalidResponse("\(name): no \(root)") }
        return text
    }

    /// A write (the camera answers 202 with nothing).
    func write(_ name: String, body: String) async throws {
        _ = try await call(name, body: body)
    }

    /// One request. The answer and the request are never put in an error or the log (they hold the tokens, and some answers hold
    /// the camera's other passwords).
    private func call(_ name: String, body: String) async throws -> String {
        guard let tokens else { throw CameraAdapterError.unsupported("the credentials have characters the camera's web API cannot take") }
        guard !latch.isTripped(key) else {
            throw CameraAdapterError.unsupported("Camera Bridge stopped using the camera's web API after it refused a request")
        }
        // Paused logins (a rejected or locked login, through this API or ONVIF) are not tried: every attempt can extend the lock.
        if hasCredentials, let until = loginKeys.compactMap({ ONVIFLoginGuard.shared.blockedUntil(host: $0) }).max() {
            throw CameraAdapterError.lockedOut(until: until)
        }
        guard let url = endpoint.httpURL(path: "/" + name) else { throw CameraAdapterError.invalidResponse("invalid camera address") }
        let text = Self.envelope(user: tokens.user, password: tokens.password, body: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = text.data(using: .isoLatin1) ?? Data(text.utf8)
        request.setValue(Self.contentType, forHTTPHeaderField: "Content-Type")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            throw CameraHTTP.sanitized(error)
        }
        let answer = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        let lowered = answer.lowercased()
        if lowered.contains("passwordlock") {
            refused("the camera locked its account")
            let until = loginKeys.map { ONVIFLoginGuard.shared.recordLockout(host: $0) }.max() ?? Date()
            throw CameraAdapterError.lockedOut(until: until)
        }
        if lowered.contains("passworderror") || response.statusCode == 401 || response.statusCode == 403 {
            refused("the camera refused the login")
            if hasCredentials { for key in loginKeys { ONVIFLoginGuard.shared.recordRejection(host: key) } }
            throw CameraAdapterError.unauthorized
        }
        // Any other refusal only pauses this API (`IPCWebLatch`): whether it was the login is not known, and pausing every login
        // (ONVIF's events and keyframes too) for a refused write would cost more than it saves.
        guard (200..<300).contains(response.statusCode) else {
            refused("HTTP \(response.statusCode)")
            throw CameraAdapterError.httpStatus(response.statusCode)
        }
        if answer.range(of: #"<([A-Za-z0-9_.\-]+:)?Fault[\s/>]"#, options: .regularExpression) != nil {
            refused("a SOAP fault")
            throw CameraAdapterError.soapFault("\(name) refused")
        }
        return answer
    }

    private func refused(_ why: String) {
        guard latch.trip(key) else { return }
        log.warning("The camera's web API refused a request (\(why)): Camera Bridge stops using it until the camera restarts in the bridge, "
                    + "so the camera does not lock its account")
    }
}
