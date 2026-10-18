#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
@testable import CameraAdapters

/// A loopback camera of the IPCamera Web family (the N801B-RB-IRC-WM701 the owner checked by hand, ONVIF manufacturer "A_ONVIF_CAMERA"): its
/// sign-in page (`GET /`, titled "IPCamera Web") and script (`/js/script/land.js`), served without a login; the sign-in
/// `GET /cgi/auth.cgi?act=auth&auth=123456&data=<xml>&guid=<ms>`, whose `encrypt` must be the RC4 of the UPPERCASE MD5 hex of
/// "username:password" (the camera's `md5-min.js` uppercases; the value is written here as computed by Python's hashlib and an RC4 written
/// apart from Camera Bridge's, and OpenSSL's `rc4-40`, never by the code under test); reads `GET /cgi/network.cgi?get=<what>&auth=<authid>&guid=<ms>`
/// and writes `…?set=<what>&auth=<authid>&data=<xml>&guid=<ms>`, answered `<root>…</root>`, with `<code>532229</code>` for an option it
/// lacks and `532227` for a session it does not know (the codes of the camera's own page); its reads never carry a `<code>`, and its sign-in
/// and writes can leave it out too (`Mode.signInWithoutCode`, `writesWithoutCode`: the page reads a missing code as 0). A write stores the
/// element it was sent (what the next read returns). Never a real camera; identifiers and secrets are made up.
final class FakeIPCamWebCamera: Sendable {
    static let username = "admin"
    static let password = "pa55word"
    /// RC4("pwnsd", "8C7796AA1C0C8A48B36C8C1C445B2040": the MD5 of "admin:pa55word" in UPPERCASE hex) in lowercase hex, computed outside
    /// Camera Bridge.
    static let encrypted = "677c8aa16a74b7d096b7838b121741ac44b2251695b1e2630e465d6403c211a3"
    /// The sign-in values of the passwords the camera can be given (`accepted`), computed the same way: "admin:" for an empty one.
    static let encryptedValues = [password: encrypted, "": "6e798ad26672b5a491c78bf9681445a134b0246c9fc091647b4b5b1601c211d0"]
    /// What this fake answers a sign-in value it does not take. Made up: what a real camera of the family answers for a wrong password is
    /// not known (its page says "Login Failed!" for every code but 0 and 532379).
    static let wrongPasswordCode = 531201
    /// What would identify the camera or its accounts: never logged, kept or shown.
    static let cuid = "TESTCUID000001"
    static let ddnsSecret = "ddns-secret-value"

    static let page = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>IPCamera Web</title>\
    <script type="text/javascript" src="../js/script/land.js"></script></head><body></body></html>
    """
    /// Shaped like the page's `login_onClickLogin`: `md5` is `md5-min.js`'s (uppercase hex), and `AjaxSubmitEx` appends `&auth=123456`,
    /// `&data=` + the XML as it is, and `&guid=`.
    static let script = """
    function login_onClickLogin(){var d="<?xml version='1.0'?><root><mode>1</mode><encrypt>"+RC4Hex(md5($('#user').val()+':'+$('#password').val()),true)+\
    "</encrypt></root>";AjaxSubmitEx({url:'/cgi/auth.cgi?act=auth',data:d,async:false,auth:false,authid:false,cb:login_answer})}
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
    /// A `get=eth` answer with the attributes the camera's page reads, in another order than the page writes them (documentation addresses,
    /// a made-up host name): not among `options` unless a test adds it.
    static let eth = #"<eth ondhcp="1" ip="192.168.77.22" submask="255.255.255.0" gateway="192.168.77.1" dhcp_mode="0" dhcp_fixed_time="0" "#
        + #"hostname="TESTCAM" ip6="" submask6="" gateway6=""><dns ondhcp="1" dns1="1.1.1.1" dns2="8.8.8.8"/></eth>"#

    enum Mode: Sendable, Equatable {
        case normal
        /// Writes are answered OK and change nothing.
        case ignoreWrites
        /// Another camera's web server: another page at `/`, 404 for everything else.
        case notThisFamily
        /// Every request answers HTTP 503 (as while the camera starts).
        case starting
        /// The sign-in is answered 200 with a web page, not the camera's XML (as a server in front of the camera could).
        case signInAnsweredWithAPage
        /// The sign-in the fake takes is answered without `<code>`: `<root><authid>SESSION</authid><level>0</level></root>`. Most likely how
        /// the owner's camera ("Patio New", N801B) answered build 0.1.111's sign-in; the camera's page reads a missing code as 0
        /// (`hXmlVal`'s default): signed in.
        case signInWithoutCode
        /// The sign-in is answered HTTP 503 (the camera's web server is up, its API is not); the page and its script still answer.
        case signInUnanswered
    }

    let server: MockHTTPServer
    /// The camera's password (one of `encryptedValues`).
    let accepted = Box(FakeIPCamWebCamera.password)
    let options = Box(FakeIPCamWebCamera.options)
    let mode = Box(Mode.normal)
    /// The code of the sign-in answer to the right value: 0, 532379 (signed in, but the camera calls the password insecure), or a refusal.
    let signInCode = Box(0)
    /// The sign-in's answer to the right value holds a session (`<authid>`); false: it has none.
    let signInGivesSession = Box(true)
    /// The writes it takes are answered `<root></root>`, without `<code>` (its reads never carry one).
    let writesWithoutCode = Box(false)
    /// The next reads answer `532227` (the session is not valid) this many times.
    let expireSessions = Box(0)
    /// Every write is answered with this code instead (532374: the account has no privilege).
    let writeCode = Box<Int?>(nil)
    /// Sessions handed out, in order (`SESSION-1`, …); only the newest is known.
    let sessions = Box<[String]>([])
    /// Every call of the API in order: `get`/`set`, what, the decoded `data` (empty for a read).
    let calls = Box<[(op: String, what: String, data: String)]>([])
    /// Sign-ins whose `encrypt` was not the expected value, or whose XML was not the page's.
    let rejectedSignIns = Box(0)
    /// After an `eth` write it takes, the camera restarts its network service: this many requests answer HTTP 503, and its sessions are gone.
    let restartAfterEthWrite = Box(0)
    private let restarting = Box(0)
    /// Told the `dns` attributes of every `eth` write the camera takes (a test keeps the camera's ONVIF answer in step with them).
    let ethWritten = Box<(@Sendable ([String: String]) -> Void)?>(nil)

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
        let inRestart = restarting.update { count -> Bool in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
        if inRestart { return .status(503) }
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
        if mode.value == .signInAnsweredWithAPage {
            return .full(status: 200, headers: [("Content-Type", "text/html")], body: Data("<html><body>Please wait</body></html>".utf8))
        }
        if mode.value == .signInUnanswered { return .status(503) }
        guard request.query("act") == "auth", request.query("auth") == "123456", request.query("guid").flatMap({ Int64($0) }) != nil,
              request.query("data") == expected else {
            rejectedSignIns.update { $0 += 1 }
            return Self.error(Self.wrongPasswordCode, "user or password error")
        }
        guard signInCode.value == 0 || signInCode.value == 532379 else { return Self.error(signInCode.value, "user or password error") }
        let code = mode.value == .signInWithoutCode ? "" : "<code>\(signInCode.value)</code>"
        guard signInGivesSession.value else { return Self.answer(code + "<level>0</level>") }
        let session = "SESSION-\(sessions.value.count + 1)"
        sessions.update { $0.append(session) }
        return Self.answer(code + "<authid>\(session)</authid><level>0</level>")
    }

    private func network(_ request: MockRequest) -> MockResponse {
        guard request.query("guid").flatMap({ Int64($0) }) != nil else { return Self.error(531000, "bad request") }
        let (op, what) = request.query("get").map { ("get", $0) } ?? request.query("set").map { ("set", $0) } ?? ("", "")
        calls.update { $0.append((op, what, request.query("data") ?? "")) }
        guard let auth = request.query("auth"), auth == sessions.value.last else { return Self.error(532227, "auth failed") }
        if expireSessions.value > 0 {
            expireSessions.update { $0 -= 1 }
            sessions.update { $0.append("SESSION-EXPIRED") }   // the session the bridge has is gone
            return Self.error(532227, "auth failed")
        }
        switch op {
        case "get":
            guard let element = options.value[what] else { return Self.error(532229, "no option") }
            return Self.answer((Self.versions[what].map { #"<version version="\#($0)"/>"# } ?? "") + element)
        case "set":
            guard options.value[what] != nil else { return Self.error(532229, "no option") }
            if let code = writeCode.value { return Self.error(code, "no privilege") }
            let data = request.query("data") ?? ""
            guard data.hasPrefix("<?xml version='1.0'?><root>"), data.hasSuffix("</root>"), let element = IPCWebXML.element(what, in: data) else {
                return Self.error(531000, "bad data")
            }
            let done = Self.answer(writesWithoutCode.value ? "" : "<code>0</code>")
            guard mode.value != .ignoreWrites else { return done }
            guard what == "eth" else {
                options.update { $0[what] = Self.merged(String(element), into: $0[what] ?? "") }
                return done
            }
            // The interface is taken whole, its `dns` child with it (the page writes both), and the network service restarts.
            guard let dns = IPCWebXML.element("dns", in: String(element)).map({ String($0) }) else { return Self.error(531000, "bad data") }
            options.update { $0["eth"] = String(element) }
            ethWritten.value?(Dictionary(IPCWebXML.attributes(of: dns).map { ($0.name, String(dns[$0.value])) }, uniquingKeysWith: { $1 }))
            restarting.set(restartAfterEthWrite.value)
            if restartAfterEthWrite.value > 0 { sessions.update { $0.append("SESSION-FORGOTTEN") } }
            return done
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
