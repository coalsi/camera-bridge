#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
@testable import CameraAdapters

/// A loopback camera that speaks the IP camera web API the way the JM800S5 family answers it: its web page (`GET /`, no login) titled
/// a sign-in script at /jsCore/rpcLogin.js; every call a POST whose Content-Type must be exactly `application/x-www-form-urlencoded` (anything else
/// reaches its ONVIF server: HTTP 500 and a SOAP fault), the sign-in tokens in the envelope's header, reads answered 200 with XML whose
/// attributes run over several lines, writes 202 with nothing. A write stores the element it was sent as it was sent (what the next read returns), so a test sees exactly what the
/// bridge wrote. Its network settings' `LANConfig` is the one the JM800S5's settings export holds (the same attributes in the same order);
/// a `setNetworkLANConfig` write can restart its network service (`restartAfterLANWrite`: requests dropped unanswered meanwhile). Never a
/// real camera; addresses and values are made up (documentation addresses and MAC).
final class FakeIPCWebCamera: Sendable {
    static let username = "admin"
    static let password = #"p@ss"w\d!"#
    static let firmware = "JM800S5_AF_V100-A_YSSD-RTMP-H5 V3.4.0.3 build 2024-10-23"
    static let features = "+gpio_input+ircut_setting+ledtype_set+ircut_leddelay+ircut_ledmanualswitch+p2p_config+cloud_authcode+"
    /// The cloud's sign-in value, with characters that must be escaped in XML.
    static let authcode = #"Ab&1<2"x"#

    static func capture(ircutMode: Int = 2, brightnessMode: Int = 2, brightness: Int = 100) -> String {
        """
        <Capture Brightness="50"
        Contrast="50"
        Saturation="50"
        IrcutMode="\(ircutMode)"
        IrcutSensitivity="50"
        IrcutOpenLedDelay="5"
        led_brightness_mode="\(brightnessMode)"
        led_brightness_value="\(brightness)"
        led_brightness_alarm="0"
        IrcutNightStartTime="18:00:00"
        IrcutNightEndTime="08:00:00"
        IrcutKeepColor="0"
        led_mode="0"
        light_off_sensitivity="60"
        face_exposure_sensitivity="60"><FishEyeCfg Enable="0" Mode="0"/></Capture>
        """
    }

    static func overlay(enabled: Int = 1) -> String {
        #"<Overlay Enable="\#(enabled)" Transparency="0" RealTransparency="0" time24or12="0" ovlayfps="0" Week="1" Fontsize="0" Style="3" >"#
            + #"<TimeOverlay PosX="1" PosY="1" Format="yyyy-mm-dd hh:mm:ss" PosType="0" />"#
            + #"<TitleOverlay PosX="0" PosY="0" PosType="0" TitleType="0" TitleUtf8="43616d657261" Title="43616d657261" /></Overlay>"#
    }

    /// The camera's hardware address as its `LANConfig` shows it (made up).
    static let hardwareAddress = "02:00:00:00:00:20"

    /// `getNetworkConfig`'s `LANConfig`, attributes over several lines. `ip` is by default the address the fake is reached at (the camera's
    /// own address, as its page shows it).
    static func lan(dhcp: Int = 0, ip: String = "127.0.0.1", dns1: String = "8.8.8.8", dns2: String = "1.1.1.1", netmask: String = "255.255.255.0",
                    gateway: String = "192.0.2.1", mac: String = hardwareAddress) -> String {
        """
        <LANConfig MacAddress="\(mac)"
        DHCP="\(dhcp)"
        dhcpOffTime="255"
        ALLNET="0"
        IPAddress="\(ip)"
        Netmask="\(netmask)"
        Gateway="\(gateway)"
        DNS1="\(dns1)"
        DNS2="\(dns2)"
        hostname="TESTCAM"
        MTU="1460" />
        """
    }

    static func p2p(enabled: Int = 1) -> String {
        #"<P2PConfig Enable="\#(enabled)" Type="10" Authcode="\#(XMLTree.escape(authcode))"/>"#
    }

    struct State: Sendable {
        var capture = FakeIPCWebCamera.capture()
        var overlay = FakeIPCWebCamera.overlay()
        var p2p = FakeIPCWebCamera.p2p()
        /// `getNetworkConfig`'s `LANConfig` (nil: the answer has none).
        var lan: String? = FakeIPCWebCamera.lan()
        var features = FakeIPCWebCamera.features
        var firmware = FakeIPCWebCamera.firmware
        /// `getMediaStreamConfig`'s `StreamAccess` element (nil: the call is answered 404, as on a camera without it).
        var streamAccess: String? = #"<StreamAccess enable_rtsp="1" enable_rtmp="0" rtmp_url=""/>"#
    }

    /// How the camera answers.
    enum Mode: Sendable {
        case normal
        /// Writes are answered 202 and change nothing.
        case ignoreWrites
        /// Every call is answered HTTP 500 with a SOAP fault (what a wrong password might look like).
        case refuseAll
        /// Every call is answered 200 with the text `passwordError`.
        case passwordError
        /// Not this API at all (another camera's web server): no sign-in script, another page at `/`, 404 to the API's calls.
        case notThisAPI
        /// Its sign-in script is the family's, but the API's calls are answered 404.
        case pageOnly
        /// Every call to the API is answered 200 with the text `passwordLock`.
        case passwordLock
        /// Every request, its sign-in script too, is answered HTTP 503 (as while the camera starts).
        case starting
    }

    /// The family's sign-in script (`IPCWebClient.signInScript`), shortened: what the client looks for is in it.
    static let page = """
    function encryptIpcUserName(e){return e}var IPCLogin=new Class({Extends:RPCCall,login:function(e,o,s,n){var e=checkLoginStr(e),\
    o=checkLoginStr(o),e=stringToHex(des("WebLogin",e,1,0)),o=stringToHex(des("WebLogin",o,1,0)),r=0;return sendRequest(e,s,!1,"/ipcLogin"),r}});
    """

    let server: MockHTTPServer
    let state = Box(State())
    let mode = Box(Mode.normal)
    /// Calls in order: the endpoint's name and the envelope's body.
    let calls = Box<[(name: String, body: String)]>([])
    /// Requests whose Content-Type was not exactly the form type, or whose tokens did not match.
    let rejectedRequests = Box(0)
    /// How long `setIRCutManual_DayNight` takes to answer (longer than a client's timeout: the command did not answer).
    let dayNightDelay = Box<Duration?>(nil)
    /// How long its sign-in script takes to load (longer than a client's timeout: the camera did not answer).
    let pageDelay = Box<Duration?>(nil)
    /// After a `setNetworkLANConfig` write, the camera restarts its network service: this many requests are dropped unanswered.
    let restartAfterLANWrite = Box(0)
    /// A `setNetworkLANConfig` write is dropped unanswered (taken all the same): the camera restarted its network before it answered.
    let dropLANWriteAnswer = Box(false)
    /// The requests dropped while the network service restarted.
    let dropped = Box(0)
    private let restarting = Box(0)

    var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port), onvifPort: Int(server.port)) }
    var credentials: HTTPCredentials { HTTPCredentials(username: Self.username, password: Self.password) }

    private init(server: MockHTTPServer) {
        self.server = server
    }

    /// Starts the camera and clears its address's `IPCWebLatch` and login pause (a test before may have used the same loopback port).
    static func start() async throws -> FakeIPCWebCamera {
        let holder = Box<FakeIPCWebCamera?>(nil)
        let server = try await MockHTTPServer.start { request in
            guard let camera = holder.value else { return .status(503) }
            return await camera.handle(request)
        }
        let camera = FakeIPCWebCamera(server: server)
        holder.set(camera)
        IPCWebLatch.shared.reset(IPCWebLatch.key(camera.endpoint))
        camera.clearLoginPause()
        return camera
    }

    /// Forgets `ONVIFLoginGuard`'s pause of this address (tests that end with a refused login).
    func clearLoginPause() {
        for key in IPCWebClient.loginKeys(endpoint) { ONVIFLoginGuard.shared.clear(host: key) }
    }

    /// The loads of its sign-in script.
    var pageLoads: Int { server.requests.filter { $0.method == "GET" && $0.path == IPCWebClient.signInScript }.count }

    /// The API's calls that reached it (its web page not counted).
    var apiRequests: [MockRequest] { server.requests.filter { $0.method == "POST" } }

    func stop() { server.stop() }

    func calls(_ name: String) -> [String] { calls.value.filter { $0.name == name }.map(\.body) }

    static let soapFault = """
    <?xml version="1.0" encoding="UTF-8"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"><SOAP-ENV:Body>\
    <SOAP-ENV:Fault><SOAP-ENV:Code><SOAP-ENV:Value>SOAP-ENV:Sender</SOAP-ENV:Value></SOAP-ENV:Code></SOAP-ENV:Fault></SOAP-ENV:Body></SOAP-ENV:Envelope>
    """

    private func handle(_ request: MockRequest) async -> MockResponse {
        if mode.value == .starting { return .status(503) }
        let inRestart = restarting.update { count -> Bool in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
        if inRestart {
            dropped.update { $0 += 1 }
            return .drop
        }
        if request.method == "GET", request.path == IPCWebClient.signInScript {
            guard request.head.headers["Content-Type"] == nil, !request.bodyText.contains("passwd") else { return .status(400) }
            if let delay = pageDelay.value { try? await Task.sleep(for: delay) }
            guard mode.value != .notThisAPI else { return .status(404) }
            return .full(status: 200, headers: [("Content-Type", "application/javascript")], body: Data(Self.page.utf8))
        }
        if request.method == "GET", request.path == "/" {
            // The real sign-in page: drawn by scripts, its HTML title empty.
            let page = mode.value == .notThisAPI ? "<html><head><title>Network Camera</title></head></html>"
                : "<!DOCTYPE html><html><head><title></title><script src=\"jsCore/rpcLogin.js?version=2.400\"></script></head></html>"
            return .full(status: 200, headers: [("Content-Type", "text/html")], body: Data(page.utf8))
        }
        let name = String(request.path.dropFirst())
        guard request.method == "POST", request.head.headers["Content-Type"] == IPCWebClient.contentType else {
            rejectedRequests.update { $0 += 1 }
            return .xml(Self.soapFault, status: 500)
        }
        let text = request.bodyText
        guard let header = IPCWebXML.element("soap:Header", in: text),
              IPCWebXML.element("userid", in: String(header)).map(Self.inner) == IPCWebToken.make(Self.username),
              IPCWebXML.element("passwd", in: String(header)).map(Self.inner) == IPCWebToken.make(Self.password) else {
            rejectedRequests.update { $0 += 1 }
            return .xml(Self.soapFault, status: 500)
        }
        let body = IPCWebXML.element("soap:Body", in: text).map(Self.inner) ?? ""
        calls.update { $0.append((name, body)) }
        switch mode.value {
        case .refuseAll: return .xml(Self.soapFault, status: 500)
        case .passwordError: return .full(status: 200, headers: [("Content-Type", "text/plain")], body: Data("passwordError".utf8))
        case .passwordLock: return .full(status: 200, headers: [("Content-Type", "text/plain")], body: Data("passwordLock".utf8))
        case .notThisAPI, .pageOnly: return .status(404)
        case .starting: return .status(503)
        case .normal, .ignoreWrites: break
        }
        let current = state.value
        let ignore = mode.value == .ignoreWrites
        switch name {
        case "getSystemVersionInfo":
            return .xml("""
            <?xml version="1.0" encoding="UTF-8"?><SystemVersionInfo><VersionInfo kernelVersion="Linux 4.9.37"
            fsVersion="\(current.firmware)"/><SerialNumber serialNumber="TEST0000000000"/></SystemVersionInfo>
            """)
        case "getSystemControlString":
            return .full(status: 200, headers: [("Content-Type", "text/plain")], body: Data(current.features.utf8))
        case "getMediaVideoConfig":
            return .xml("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Video>\(current.capture)<Encode><MainStream Codec="H264" Width="2304" Height="1296"/></Encode><JpegConfig Quality="80"/>\
            \(current.overlay)<Mask Enable="0"/></Video>
            """)
        case "setMediaVideoCaptureConfig":
            if !ignore, let capture = IPCWebXML.element("Capture", in: body) { state.update { $0.capture = String(capture) } }
            return .status(202)
        case "setIRCutManual_DayNight":
            if let delay = dayNightDelay.value { try? await Task.sleep(for: delay) }
            return .status(202)
        case "setMediaVideoOverlayConfig":
            if !ignore, let overlay = IPCWebXML.element("Overlay", in: body) { state.update { $0.overlay = String(overlay) } }
            return .status(202)
        case "getNetworkConfig":
            return .xml("""
            <?xml version="1.0" encoding="UTF-8"?><NetworkConfig>\(current.lan ?? "")\
            <WIFIConfig Enable="0" SSID="test" Password="wifi-secret-value"/><UPNPConfig Enable="0"/>\(current.p2p)\
            <EmailConfig Password="mail-secret-value"/></NetworkConfig>
            """)
        case "setNetworkLANConfig":
            if !ignore, let lan = IPCWebXML.element("LANConfig", in: body) { state.update { $0.lan = String(lan) } }
            restarting.set(restartAfterLANWrite.value)
            return dropLANWriteAnswer.value ? .drop : .status(202)
        case "setNetworkP2PConfig":
            if !ignore, let p2p = IPCWebXML.element("P2PConfig", in: body) { state.update { $0.p2p = String(p2p) } }
            return .status(202)
        case "getMediaStreamConfig":
            guard let access = current.streamAccess else { return .status(404) }
            return .xml("<?xml version=\"1.0\"?><MediaStreamConfig>\(access)</MediaStreamConfig>")
        case "getNetworkStatus":
            let on = IPCWebXML.attribute("Enable", of: current.p2p) == "1"
            return .xml("<?xml version=\"1.0\"?><NetworkStatus><CLOUD Enable=\"\(on ? 1 : 0)\" Type=\"10\" LoginStatus=\"\(on ? 1 : 0)\" ID=\"TEST\"/></NetworkStatus>")
        default:
            return .status(404)
        }
    }

    /// The text between an element's start and end tags.
    static func inner(_ element: Substring) -> String {
        guard let open = element.firstIndex(of: ">"), let close = element.range(of: "</", options: .backwards) else { return "" }
        return String(element[element.index(after: open)..<close.lowerBound])
    }
}
#endif
