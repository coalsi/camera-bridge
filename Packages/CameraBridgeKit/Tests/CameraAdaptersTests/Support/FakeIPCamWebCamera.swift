#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
@testable import CameraAdapters

/// A loopback camera of the IPCamera Web family (the N801B-RB-IRC-WM701 the owner checked by hand, ONVIF manufacturer "A_ONVIF_CAMERA"): its
/// sign-in page (`GET /`, titled "IPCamera Web") and script (`/js/script/land.js`), served without a login; the sign-in
/// `GET /cgi/auth.cgi?act=auth&auth=123456&data=<xml>&guid=<ms>`, whose `encrypt` must be the RC4 of the MD5 of "username:password" (the
/// value is written here as computed by Python's hashlib and an RC4 written apart from Camera Bridge's, never by the code under test);
/// reads `GET /cgi/network.cgi?get=<what>&auth=<authid>&guid=<ms>` and writes `…?set=<what>&auth=<authid>&data=<xml>&guid=<ms>`, answered
/// `<root>…</root>`, with `<code>532229</code>` for an option it lacks and `531203` for a session it no longer knows. A write stores the
/// element it was sent (what the next read returns). Never a real camera; identifiers and secrets are made up.
final class FakeIPCamWebCamera: Sendable {
    static let username = "admin"
    static let password = "pa55word"
    /// RC4("pwnsd", md5hex("admin:pa55word")) in lowercase hex, computed outside Camera Bridge.
    static let encrypted = "675c8aa16a7497f0969783ab123741ac64b225369591e2430e465d4403c211a3"
    /// The sign-in values of the passwords the camera can be given (`accepted`), computed the same way: "admin:" for an empty one.
    static let encryptedValues = [password: encrypted, "": "6e598af2667295a491c78bf9483445a134b0246c9fc0b1445b4b5b1601c211f0"]
    /// What would identify the camera or its accounts: never logged, kept or shown.
    static let cuid = "TESTCUID000001"
    static let ddnsSecret = "ddns-secret-value"

    static let page = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>IPCamera Web</title>\
    <script type="text/javascript" src="../js/script/land.js"></script></head><body></body></html>
    """
    static let script = """
    function login(){var e=hex_md5(user+":"+pwd);var d="<?xml version='1.0'?><root><mode>1</mode><encrypt>"+rc4("pwnsd",e)+"</encrypt></root>";\
    ajax("cgi/auth.cgi?act=auth&auth=123456&data="+encodeURIComponent(d)+"&guid="+new Date().getTime())}
    """

    /// The options as the owner's camera answered them (identifiers made up). A missing key is an option the camera lacks.
    static let options: [String: String] = [
        "mobile": #"<mobile on="1" sendalarm="1" cuid="\#(cuid)"/>"#,
        "ddns": #"<ddns on="0" type="0" account="test-account" port="80" name="" pwd="\#(ddnsSecret)" times="3600"/>"#,
        "rtmp": #"<rtmp on="0"><url mainurl="" suburl=""/></rtmp>"#,
        "meari": #"<meari on="1" authorized="0" port="10000"/>"#,
        "hik": #"<hik on="1" authorized="0" port="8000" dataport="8200"/>"#,
        "onvif": #"<onvif on="1" enabletalk="1" synctime="1" syncparam="1" enablemeta="1" authorized="0" companyname="A_ONVIF_CAMERA" hostname="" location="" wlanip="0.0.0.0" compatiblemode="0"/>"#,
        "rtsp": #"<rtsp port="554" rtspsport="322" authorized="0" mtu="1400" videoflag="video" audioflag="audio" audiobackflag="audioback"/>"#,
        "wifiap": #"<wifiap on="1"/>"#,
    ]
    /// The `<version>` line some answers start with.
    static let versions: [String: String] = ["ddns": "0", "rtmp": "1", "onvif": "4", "rtsp": "1"]

    enum Mode: Sendable, Equatable {
        case normal
        /// Writes are answered OK and change nothing.
        case ignoreWrites
        /// Another camera's web server: another page at `/`, 404 for everything else.
        case notThisFamily
        /// Every request answers HTTP 503 (as while the camera starts).
        case starting
    }

    let server: MockHTTPServer
    /// The camera's password (one of `encryptedValues`).
    let accepted = Box(FakeIPCamWebCamera.password)
    let options = Box(FakeIPCamWebCamera.options)
    let mode = Box(Mode.normal)
    /// The sign-in answer's code (0, 531355 "signed in", or a refusal).
    let signInCode = Box(0)
    /// The next reads answer `531203` (the session expired) this many times.
    let expireSessions = Box(0)
    /// Sessions handed out, in order (`SESSION-1`, …); only the newest is known.
    let sessions = Box<[String]>([])
    /// Every call of the API in order: `get`/`set`, what, the decoded `data` (empty for a read).
    let calls = Box<[(op: String, what: String, data: String)]>([])
    /// Sign-ins whose `encrypt` was not the expected value, or whose XML was not the page's.
    let rejectedSignIns = Box(0)

    var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port), onvifPort: Int(server.port)) }
    var credentials: HTTPCredentials { HTTPCredentials(username: Self.username, password: Self.password) }

    private init(server: MockHTTPServer) {
        self.server = server
    }

    /// Starts the camera and clears its address's `IPCamWebLatch` and login pause (a test before may have used the same loopback port).
    static func start() async throws -> FakeIPCamWebCamera {
        let holder = Box<FakeIPCamWebCamera?>(nil)
        let server = try await MockHTTPServer.start { request in
            guard let camera = holder.value else { return .status(503) }
            return camera.handle(request)
        }
        let camera = FakeIPCamWebCamera(server: server)
        holder.set(camera)
        IPCamWebLatch.shared.reset(IPCamWebLatch.key(camera.endpoint))
        for key in IPCamWebClient.loginKeys(camera.endpoint) { ONVIFLoginGuard.shared.clear(host: key) }
        return camera
    }

    func stop() { server.stop() }

    var signIns: [MockRequest] { server.requests.filter { $0.path == "/cgi/auth.cgi" } }
    var apiRequests: [MockRequest] { server.requests.filter { $0.path.hasPrefix("/cgi/") } }
    func writes(_ what: String) -> [String] { calls.value.filter { $0.op == "set" && $0.what == what }.map(\.data) }
    func reads(_ what: String) -> Int { calls.value.filter { $0.op == "get" && $0.what == what }.count }

    static func answer(_ body: String) -> MockResponse {
        .full(status: 200, headers: [("Content-Type", "text/xml")], body: Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><root>\(body)</root>".utf8))
    }

    static func error(_ code: Int, _ words: String) -> MockResponse { answer("<code>\(code)</code><error>\(words)</error>") }

    private func handle(_ request: MockRequest) -> MockResponse {
        if mode.value == .starting { return .status(503) }
        if mode.value == .notThisFamily {
            guard request.path == "/" else { return .status(404) }
            return .full(status: 200, headers: [("Content-Type", "text/html")], body: Data("<html><head><title>Network Camera</title></head></html>".utf8))
        }
        guard request.method == "GET", request.head.headers["Authorization"] == nil else { return .status(400) }
        switch request.path {
        case "/": return .full(status: 200, headers: [("Content-Type", "text/html")], body: Data(Self.page.utf8))
        case "/js/script/land.js": return .full(status: 200, headers: [("Content-Type", "application/javascript")], body: Data(Self.script.utf8))
        case "/cgi/auth.cgi": return signIn(request)
        case "/cgi/network.cgi": return network(request)
        default: return .status(404)
        }
    }

    private func signIn(_ request: MockRequest) -> MockResponse {
        let expected = "<?xml version='1.0'?><root><mode>1</mode><encrypt>\(Self.encryptedValues[accepted.value] ?? "-")</encrypt></root>"
        guard request.query("act") == "auth", request.query("auth") == "123456", request.query("guid").flatMap({ Int64($0) }) != nil,
              request.query("data") == expected else {
            rejectedSignIns.update { $0 += 1 }
            return Self.error(531201, "user or password error")
        }
        guard signInCode.value == 0 || signInCode.value == 531355 else { return Self.error(signInCode.value, "user or password error") }
        let session = "SESSION-\(sessions.value.count + 1)"
        sessions.update { $0.append(session) }
        return Self.answer("<code>\(signInCode.value)</code><authid>\(session)</authid><level>0</level>")
    }

    private func network(_ request: MockRequest) -> MockResponse {
        guard request.query("guid").flatMap({ Int64($0) }) != nil else { return Self.error(531000, "bad request") }
        let (op, what) = request.query("get").map { ("get", $0) } ?? request.query("set").map { ("set", $0) } ?? ("", "")
        calls.update { $0.append((op, what, request.query("data") ?? "")) }
        guard let auth = request.query("auth"), auth == sessions.value.last else { return Self.error(531203, "session timeout") }
        if expireSessions.value > 0 {
            expireSessions.update { $0 -= 1 }
            sessions.update { $0.append("SESSION-EXPIRED") }   // the session the bridge has is gone
            return Self.error(531203, "session timeout")
        }
        switch op {
        case "get":
            guard let element = options.value[what] else { return Self.error(532229, "no option") }
            return Self.answer((Self.versions[what].map { #"<version version="\#($0)"/>"# } ?? "") + element)
        case "set":
            guard options.value[what] != nil else { return Self.error(532229, "no option") }
            let data = request.query("data") ?? ""
            guard data.hasPrefix("<?xml version='1.0'?><root>"), data.hasSuffix("</root>"), let element = IPCWebXML.element(what, in: data) else {
                return Self.error(531000, "bad data")
            }
            if mode.value != .ignoreWrites { options.update { $0[what] = Self.merged(String(element), into: $0[what] ?? "") } }
            return Self.answer("<code>0</code>")
        default:
            return Self.error(531000, "bad request")
        }
    }

    /// The camera keeps the attributes a write names (the page sends `<mobile on='0'></mobile>` with only the switch) and the rest as they were.
    static func merged(_ written: String, into stored: String) -> String {
        let values = Dictionary(IPCWebXML.attributes(of: written).map { ($0.name, String(written[$0.value])) }, uniquingKeysWith: { $1 })
        let known = Set(IPCWebXML.attributes(of: stored).map(\.name))
        return IPCWebXML.replacingAttributes(values.filter { known.contains($0.key) }, in: stored) ?? stored
    }
}
#endif
