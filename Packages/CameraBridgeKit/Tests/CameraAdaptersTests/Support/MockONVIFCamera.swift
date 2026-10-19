#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
@testable import CameraAdapters

/// A loopback ONVIF device (device/media/events services + PullPoint) serving the `Fixtures/onvif` responses.
/// Verifies WS-UsernameToken PasswordDigest on every authenticated call.
final class MockONVIFCamera: Sendable {
    static let username = "admin"
    static let password = "secret"
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0xFF, 0xD9])

    let server: MockHTTPServer
    /// SOAP body element names in arrival order.
    let actions = Box<[String]>([])
    /// Raw SOAP headers of subscription-manager calls (PullMessages/Renew/Unsubscribe).
    let subscriptionHeaders = Box<[String]>([])
    /// WS-Security `Created` values seen.
    let createdStamps = Box<[String]>([])
    /// Fixture names returned by successive PullMessages calls; afterwards `Pull-Empty.xml` after a short wait.
    let pullQueue: Box<[String]>
    let failCreateSubscription = Box(false)
    /// PullMessages answers HTTP 500 while set (the subscription broke; CreatePullPointSubscription still works).
    let failPulls = Box(false)
    /// An empty PullMessages is answered at once while set (a camera that ignores `Timeout`), else after 50 ms.
    let instantEmptyPulls = Box(false)
    /// When set, Renew answers a SOAP fault with this subcode (and `renewFaultReason`).
    let renewFault = Box<String?>(nil)
    let renewFaultReason = Box("renew failed")
    /// Every authenticated call answers `NotAuthorized` while set (the camera's ONVIF user has another password).
    let rejectCredentials = Box(false)
    /// How the device refuses the account Camera Bridge uses a change it signed in for (the Reolink doorbell's ONVIF user and `SetNTP`).
    enum WriteRefusal: Sendable {
        /// A SOAP fault with the `ter:NotAuthorized` subcode, as for a wrong password.
        case notAuthorizedFault
        /// HTTP 401 without a body.
        case http401
    }
    /// The actions (body element names) refused that way, though the login is right; their reads still answer.
    let refusedWrites = Box<[String: WriteRefusal]>([:])
    /// Authenticated calls are answered whatever credentials they carry while set (an ONVIF that asks no password, as the IPCamera Web
    /// family's can).
    let openONVIF = Box(false)
    /// Asked first for every request; an answer it gives is the device's (another API on the same port, such as Reolink's `/api.cgi`).
    let otherAPI = Box<(@Sendable (MockRequest) -> MockResponse?)?>(nil)
    /// Stream addresses `GetStreamUri` answers per profile token, instead of the default Reolink-like paths (a Dahua/Amcrest camera's
    /// differ only in their query: `/cam/realmonitor?channel=1&subtype=0` and `…subtype=1`).
    let streamURIs = Box<[String: String]>([:])
    /// `GetProfiles` lists the main profile ("000") first, as an Amcrest does, instead of the sub profile first.
    let mainProfileFirst = Box(false)
    /// Configuration tokens of successive `SetVideoEncoderConfiguration` calls, in order.
    let setVideoEncoderConfigurationCalls = Box<[String]>([])
    /// Video source tokens of successive `SetImagingSettings` calls, in order.
    let setImagingSettingsCalls = Box<[String]>([])
    let systemRebootCalled = Box(0)
    /// Profile tokens of successive `SetSynchronizationPoint` calls, in order; the call answers a fault while `refuseSynchronizationPoint`.
    let synchronizationPoints = Box<[String]>([])
    let refuseSynchronizationPoint = Box(false)
    /// The on-screen display elements the device holds (token → the element's children): its own date/time and a caption.
    let osds = Box<[(token: String, children: String)]>([
        ("OSD_DateTime", MockONVIFCamera.osdChildren(textType: "DateAndTime", text: nil)),
        ("OSD_Caption", MockONVIFCamera.osdChildren(textType: "Plain", text: "Front door")),
    ])
    /// Media calls on the OSDs, in order: "GetOSDs", "DeleteOSD:<token>", "CreateOSD", "SetOSD:<token>".
    let osdCalls = Box<[String]>([])
    /// How the device answers `DeleteOSD` / `CreateOSD` / `SetOSD`.
    enum OSDMode: Sendable {
        case accept
        /// `DeleteOSD` is refused (the element is built in); `SetOSD` works.
        case refuseDelete
        /// Every change is refused.
        case refuseAll
        /// `DeleteOSD` and `SetOSD` answer success but change nothing.
        case ignoreChanges
        /// `GetOSDs` answers a SOAP fault that is only "Sender" (no subcode, no reason), as a Reolink doorbell does.
        case bareSenderFault
    }
    let osdMode = Box(OSDMode.accept)

    /// The device's clock (`GetSystemDateAndTime` / `SetSystemDateAndTime`) and time servers (`GetNTP` / `SetNTP`), as a camera keeps them.
    struct Clock: Sendable, Equatable {
        var type = "NTP"
        var daylightSavings = true
        var timeZone: String? = "CST6CDT,M3.2.0,M11.1.0"
        var ntpFromDHCP = false
        var ntpServers = ["pool.ntp.org"]
    }
    let clock = Box(Clock())
    /// `SetSystemDateAndTime` and `SetNTP` answer a fault while set (a camera whose ONVIF user may not change the clock).
    let refuseClockChanges = Box(false)
    /// The device has no `GetNTP` (answers `ActionNotSupported`).
    let noNTP = Box(false)
    /// Clock calls in order: "SetSystemDateAndTime", "SetNTP".
    let clockCalls = Box<[String]>([])

    /// The device's DNS servers (`GetDNS` / `SetDNS`), as a camera keeps them; by default as camera A answered: from DHCP, with a search domain.
    struct DNS: Sendable, Equatable {
        var fromDHCP = true
        var searchDomains = ["domain.name"]
        /// What DHCP gave (`DNSFromDHCP`).
        var dhcpServers = ["1.1.1.1", "8.8.8.8"]
        /// The servers set by hand (`DNSManual`), IPv4 or IPv6.
        var manualServers: [String] = []
    }
    let dns = Box(DNS())
    /// How the device keeps the `DNSManual` entries `SetDNS` sends.
    enum DNSSlots: Sendable, Equatable {
        /// As sent: they replace every server set by hand (cameras A and B, a Jennov).
        case asSent
        /// Two slots, as the IPCamera Web family's page has them ("Patio New"): each entry sent fills its slot (an empty one empties it), a
        /// slot not sent keeps its server, and the servers set by hand are not shown while the camera takes them from DHCP.
        case two
        /// `two`, but a request that names one address twice is refused.
        case twoRefusingDuplicates
        /// `two`, but the second slot keeps its server whatever is sent.
        case twoKeepingSecond
    }
    let dnsSlots = Box(DNSSlots.asSent)
    /// `SetDNS` answers a fault while set (a camera whose ONVIF user may not change its network).
    let refuseDNSChanges = Box(false)
    /// `SetDNS` answers success and changes nothing while set.
    let ignoreDNSChanges = Box(false)
    /// The subcodes of the faults successive `SetDNS` requests are answered with, in order ("InvalidArgVal"; "NotAuthorized" is the account
    /// that may not change the DNS once it signed in); once used up, `SetDNS` is answered as `refuseDNSChanges` and the slots say.
    let dnsFaults = Box<[String]>([])
    /// The device has no `GetDNS` (answers `ActionNotSupported`).
    let noDNS = Box(false)
    /// How `GetDNS` shows a slot set by hand that is empty: left out (nil, by default), or as this address ("0.0.0.0", as ISAPI shows one).
    let emptySlotShownAs = Box<String?>(nil)
    /// Raw bodies of successive `SetDNS` requests.
    let setDNSBodies = Box<[String]>([])
    /// A camera that applies `SetDNS` only after its network restarts: while set, the write is answered at once but kept pending, and shown
    /// by `GetDNS` once `GetDNS` has been asked this many times since (a read-back every 2 s: 5 is 10 s). Until then `GetDNS` shows the old
    /// servers. nil (by default): the write applies at once.
    let applyDNSAfterReads = Box<Int?>(nil)
    /// While a write is pending (`applyDNSAfterReads`), `GetDNS` answers HTTP 503 instead of the old servers (the camera is restarting its
    /// network service).
    let silentWhileApplying = Box(false)
    /// A `SetDNS` the camera has answered but not applied yet: the `GetDNS` reads still to pass before it shows, and what it does to the DNS.
    private struct PendingDNS: Sendable {
        var readsLeft: Int
        let apply: @Sendable (inout DNS) -> Void
    }
    private let pendingDNS = Box<PendingDNS?>(nil)
    /// The `GetNetworkDefaultGateway` and `GetNetworkInterfaces` answers: camera A's (addresses changed to made-up ones, its MAC too).
    static let gatewayAnswer = MockONVIFCamera.gatewayAnswer(["192.168.77.1"])
    static let hardwareAddress = "02:00:00:00:00:22"
    static let interfacesAnswer = MockONVIFCamera.interfacesAnswer(IPv4())

    /// The device's network interface `eth0`, its IPv4 settings as `GetNetworkInterfaces` shows them and `SetNetworkInterfaces` sets them: by
    /// default camera A's, on DHCP (the lease shown as `FromDHCP` and `LinkLocal`). Fixed (`dhcp` false), the address is shown as `Manual`.
    struct IPv4: Sendable, Equatable {
        var dhcp = true
        var address = "192.168.77.22"
        var prefixLength = 24
    }
    let ipv4 = Box(IPv4())
    /// The default gateways `GetNetworkDefaultGateway` shows and `SetNetworkDefaultGateway` sets (IPv4 ones; empty: none).
    let gateways = Box(["192.168.77.1"])
    /// `GetNetworkInterfaces` shows no hardware address while set.
    let hidesHardwareAddress = Box(false)
    /// `GetNetworkInterfaces` answers this body instead of `ipv4`'s while set (an interface shown in another shape).
    let interfacesOverride = Box<String?>(nil)
    /// `SetNetworkInterfaces` answers `RebootNeeded` true while set: the change is taken and shown only after the camera restarts, which
    /// never happens here (its old settings stay shown).
    let networkRebootNeeded = Box(false)
    /// `SetNetworkInterfaces` answers success and changes nothing while set.
    let ignoreNetworkChanges = Box(false)
    /// `SetNetworkInterfaces` answers a fault with this subcode while set ("InvalidArgVal": a body it does not take; "ActionNotSupported").
    let networkInterfacesFault = Box<String?>(nil)
    /// `SetNetworkInterfaces` applies the change and answers 200 with a body that is not its answer while set.
    let networkInterfacesUnreadable = Box(false)
    /// A fixed address drops the gateway DHCP gave (`gateways` empty), and DHCP gives it back, while set.
    let dropsGatewayWhenFixed = Box(false)
    /// `SetNetworkDefaultGateway` answers success and changes nothing while set.
    let ignoreGatewayChanges = Box(false)
    /// Raw bodies of successive `SetNetworkInterfaces` and `SetNetworkDefaultGateway` requests.
    let setNetworkInterfacesBodies = Box<[String]>([])
    let setGatewayBodies = Box<[String]>([])

    static func gatewayAnswer(_ ipv4: [String]) -> String {
        "<tds:GetNetworkDefaultGatewayResponse><tds:NetworkGateway>" + ipv4.map { "<tt:IPv4Address>\($0)</tt:IPv4Address>" }.joined()
            + "</tds:NetworkGateway></tds:GetNetworkDefaultGatewayResponse>"
    }

    static func interfacesAnswer(_ ipv4: IPv4, hardwareAddress: String? = MockONVIFCamera.hardwareAddress) -> String {
        let prefixed = "<tt:Address>\(ipv4.address)</tt:Address><tt:PrefixLength>\(ipv4.prefixLength)</tt:PrefixLength>"
        let config = ipv4.dhcp ? "<tt:LinkLocal>\(prefixed)</tt:LinkLocal><tt:FromDHCP>\(prefixed)</tt:FromDHCP><tt:DHCP>true</tt:DHCP>"
            : "<tt:Manual>\(prefixed)</tt:Manual><tt:DHCP>false</tt:DHCP>"
        let mac = hardwareAddress.map { "<tt:HwAddress>\($0)</tt:HwAddress>" } ?? ""
        return "<tds:GetNetworkInterfacesResponse><tds:NetworkInterfaces token=\"eth0\"><tt:Enabled>true</tt:Enabled><tt:Info><tt:Name>eth0</tt:Name>"
            + "\(mac)<tt:MTU>1400</tt:MTU></tt:Info><tt:IPv4><tt:Enabled>true</tt:Enabled><tt:Config>\(config)</tt:Config></tt:IPv4>"
            + "</tds:NetworkInterfaces></tds:GetNetworkInterfacesResponse>"
    }

    /// One `IPAddress` entry (`DNSManual`, `DNSFromDHCP`) in the device's answer.
    private static func addressEntry(_ element: String, _ address: String) -> String {
        let type = ONVIFClient.isIPv4(address) ? "IPv4" : "IPv6"
        return "<tt:\(element)><tt:Type>\(type)</tt:Type><tt:\(type)Address>\(address)</tt:\(type)Address></tt:\(element)>"
    }

    /// An `OSD` element's children: a text element of `textType` (Plain, Date, Time, DateAndTime).
    static func osdChildren(textType: String, text: String?) -> String {
        let plain = text.map { "<tt:PlainText>\($0)</tt:PlainText>" } ?? ""
        let formats = textType == "Plain" ? "" : "<tt:DateFormat>yyyy-MM-dd</tt:DateFormat><tt:TimeFormat>HH:mm:ss</tt:TimeFormat>"
        return "<tt:VideoSourceConfigurationToken>vsc_main</tt:VideoSourceConfigurationToken><tt:Type>Text</tt:Type>"
            + "<tt:Position><tt:Type>UpperLeft</tt:Type></tt:Position><tt:TextString><tt:Type>\(textType)</tt:Type>\(formats)\(plain)</tt:TextString>"
    }
    /// How `SetVideoEncoderConfiguration` is answered.
    enum SetEncoderMode: Sendable {
        /// Accepts and keeps the values (later `GetProfiles` / `GetVideoEncoderConfigurations` show them).
        case accept
        case rejectAll
        /// Rejects a request that doesn't carry the camera's own `UseCount` element (CameraBridge's sparse full request).
        case rejectSparseRequest
        /// Rejects `ForcePersistence` true.
        case rejectForcePersistenceTrue
        /// Answers success but keeps the old values.
        case acceptWithoutStoring
    }
    let setEncoderMode = Box(SetEncoderMode.accept)
    /// Raw bodies of successive `SetVideoEncoderConfiguration` requests.
    let setEncoderBodies = Box<[String]>([])
    /// Encoder values (element name → text) set through `SetVideoEncoderConfiguration`, by configuration token.
    let encoderValues = Box<[String: [String: String]]>([:])

    /// `xml` with the stored encoder values written into the matching `VideoEncoderConfiguration` / `Configurations` elements.
    private func withEncoderValues(_ xml: String) -> String {
        var result = xml
        for (token, values) in encoderValues.value {
            for (open, close) in [("<tt:VideoEncoderConfiguration token=\"\(token)\"", "</tt:VideoEncoderConfiguration>"),
                                  ("<trt:Configurations token=\"\(token)\"", "</trt:Configurations>")] {
                guard let start = result.range(of: open), let end = result.range(of: close, range: start.upperBound..<result.endIndex) else { continue }
                var segment = String(result[start.lowerBound..<end.upperBound])
                for (tag, value) in values {
                    guard let first = segment.range(of: "<tt:\(tag)>"), let last = segment.range(of: "</tt:\(tag)>", range: first.upperBound..<segment.endIndex) else { continue }
                    segment.replaceSubrange(first.upperBound..<last.lowerBound, with: value)
                }
                result.replaceSubrange(start.lowerBound..<end.upperBound, with: segment)
            }
        }
        return result
    }

    var baseURL: URL { server.baseURL }
    var deviceServiceURL: URL { server.baseURL.appending(path: "onvif/device_service") }
    var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port), onvifPort: Int(server.port)) }

    /// The `GetProfiles` answer with the profile "000" moved in front of the others.
    static func mainFirst(_ xml: String) -> String {
        let marker = "<trt:Profiles "
        var parts = xml.components(separatedBy: marker)
        guard parts.count > 2 else { return xml }
        let head = parts.removeFirst()
        // Each part is one profile up to the next; the last one also carries the rest of the document.
        guard let lastClose = parts[parts.count - 1].range(of: "</trt:Profiles>", options: .backwards) else { return xml }
        let tail = String(parts[parts.count - 1][lastClose.upperBound...])
        parts[parts.count - 1] = String(parts[parts.count - 1][..<lastClose.upperBound])
        guard let index = parts.firstIndex(where: { $0.hasPrefix("token=\"000\"") }) else { return xml }
        let main = parts.remove(at: index)
        return head + ([main] + parts).map { marker + $0 }.joined() + tail
    }

    private init(server: MockHTTPServer, pullQueue: Box<[String]>) {
        self.server = server
        self.pullQueue = pullQueue
    }

    static func start(clockOffset: TimeInterval = 0, pulls: [String] = []) async throws -> MockONVIFCamera {
        let holder = Box<MockONVIFCamera?>(nil)
        let queue = Box(pulls)
        let server = try await MockHTTPServer.start { request in
            guard let camera = holder.value else { return .status(503) }
            return await camera.handle(request, clockOffset: clockOffset)
        }
        let camera = MockONVIFCamera(server: server, pullQueue: queue)
        holder.set(camera)
        // A fake of the IP camera web API family that a test before ran at the same loopback port is forgotten: an ONVIF camera's DNS, clean
        // picture and cloud ask that API's sign-in script first, and this camera has none.
        IPCWebLatch.shared.reset(IPCWebLatch.key(camera.endpoint))
        return camera
    }

    func stop() { server.stop() }

    func template(_ name: String) -> String {
        (try? fixtureText("onvif/\(name)"))?.replacingOccurrences(of: "{{BASE}}", with: server.baseURL.absoluteString) ?? ""
    }

    private func fault(_ subcode: String, _ reason: String) -> MockResponse {
        .soap("""
        <?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:ter="http://www.onvif.org/ver10/error">\
        <s:Body><s:Fault><s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>ter:\(subcode)</s:Value></s:Subcode></s:Code>\
        <s:Reason><s:Text xml:lang="en">\(reason)</s:Text></s:Reason></s:Fault></s:Body></s:Envelope>
        """, status: 400)
    }

    private func envelope(_ body: String) -> MockResponse {
        .soap("""
        <?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" \
        xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" \
        xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:timg="http://www.onvif.org/ver20/imaging/wsdl"><s:Body>\(body)</s:Body></s:Envelope>
        """)
    }

    private func authorized(_ envelope: XMLTree) -> Bool {
        guard let token = envelope.child("Header")?.child("Security")?.child("UsernameToken"),
              token.string("Username") == Self.username, let password = token.string("Password"),
              let nonceText = token.string("Nonce"), let nonce = Data(base64Encoded: nonceText), let created = token.string("Created") else {
            return false
        }
        createdStamps.update { $0.append(created) }
        return password == ONVIFSOAP.passwordDigest(nonce: nonce, created: created, password: Self.password)
    }

    private func handle(_ request: MockRequest, clockOffset: TimeInterval) async -> MockResponse {
        if let other = otherAPI.value, let answer = other(request) { return answer }
        if request.method == "GET", request.path == "/cgi-bin/api.cgi" {
            guard isDigestAuthorization(request.head.headers["Authorization"]) else { return .digestChallenge() }
            return .full(status: 200, headers: [("Content-Type", "image/jpeg")], body: Self.jpeg)
        }
        guard request.method == "POST", let envelope = try? XMLTree.parse(request.body),
              let action = envelope.child("Body")?.children.first?.name else { return .status(400) }
        actions.update { $0.append(action) }
        if action == "GetSystemDateAndTime" {
            let date = Date().addingTimeInterval(clockOffset)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let state = self.clock.value
            let zone = state.timeZone.map { "<tt:TimeZone><tt:TZ>\($0)</tt:TZ></tt:TimeZone>" } ?? ""
            return self.envelope("""
            <tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:DateTimeType>\(state.type)</tt:DateTimeType>\
            <tt:DaylightSavings>\(state.daylightSavings)</tt:DaylightSavings>\(zone)<tt:UTCDateTime>\
            <tt:Time><tt:Hour>\(c.hour!)</tt:Hour><tt:Minute>\(c.minute!)</tt:Minute><tt:Second>\(c.second!)</tt:Second></tt:Time>\
            <tt:Date><tt:Year>\(c.year!)</tt:Year><tt:Month>\(c.month!)</tt:Month><tt:Day>\(c.day!)</tt:Day></tt:Date></tt:UTCDateTime>\
            </tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>
            """)
        }
        guard !rejectCredentials.value, openONVIF.value || authorized(envelope) else { return fault("NotAuthorized", "Sender not Authorized") }
        switch refusedWrites.value[action] {
        case .notAuthorizedFault: return fault("NotAuthorized", "Sender not Authorized")
        case .http401: return .status(401)
        case nil: break
        }
        switch action {
        case "GetDeviceInformation": return .soap(template("GetDeviceInformationResponse.xml"))
        case "GetCapabilities": return .soap(template("GetCapabilitiesResponse.xml"))
        case "GetServices": return .soap(template("GetServicesResponse.xml"))
        case "GetProfiles":
            let profiles = withEncoderValues(template("GetProfilesResponse.xml"))
            return .soap(mainProfileFirst.value ? Self.mainFirst(profiles) : profiles)
        case "GetStreamUri":
            let token = envelope.firstDescendant("ProfileToken")?.text ?? ""
            let uri = streamURIs.value[token]
                ?? (token == "000" ? "rtsp://admin:secret@10.0.0.99:554/Preview_01_main" : "rtsp://127.0.0.1:554/Preview_01_sub")
            let escaped = uri.replacingOccurrences(of: "&", with: "&amp;")
            return .soap(template("GetStreamUriResponse.xml").replacingOccurrences(of: "{{URI}}", with: escaped))
        case "GetSnapshotUri": return .soap(template("GetSnapshotUriResponse.xml"))
        case "GetEventProperties": return .soap(template("GetEventPropertiesResponse.xml"))
        case "GetVideoSources": return .soap(template("GetVideoSourcesResponse.xml"))
        case "GetVideoEncoderConfigurations": return .soap(withEncoderValues(template("GetVideoEncoderConfigurationsResponse.xml")))
        case "GetVideoEncoderConfigurationOptions": return .soap(template("GetVideoEncoderConfigurationOptionsResponse.xml"))
        case "SetVideoEncoderConfiguration":
            let configuration = envelope.firstDescendant("Configuration")
            let token = configuration?.attribute("token") ?? ""
            setVideoEncoderConfigurationCalls.update { $0.append(token) }
            setEncoderBodies.update { $0.append(request.bodyText) }
            let rejected = fault("InvalidArgVal", "the parameter value is illegal")
            switch setEncoderMode.value {
            case .rejectAll: return rejected
            case .rejectSparseRequest where configuration?.child("UseCount") == nil: return rejected
            case .rejectForcePersistenceTrue where envelope.firstDescendant("ForcePersistence")?.text == "true": return rejected
            case .acceptWithoutStoring: return self.envelope("<trt:SetVideoEncoderConfigurationResponse/>")
            default: break
            }
            var stored: [String: String] = [:]
            for (tag, path) in [("Encoding", ["Encoding"]), ("Width", ["Resolution", "Width"]), ("Height", ["Resolution", "Height"]),
                                ("FrameRateLimit", ["RateControl", "FrameRateLimit"]), ("BitrateLimit", ["RateControl", "BitrateLimit"]),
                                ("GovLength", ["H264", "GovLength"]), ("H264Profile", ["H264", "H264Profile"])] {
                if let value = configuration?.element(path: path)?.text { stored[tag] = value }
            }
            encoderValues.update { $0[token, default: [:]].merge(stored) { _, new in new } }
            return self.envelope("<trt:SetVideoEncoderConfigurationResponse/>")
        case "GetOSDs":
            osdCalls.update { $0.append("GetOSDs") }
            if osdMode.value == .bareSenderFault {
                return .soap("""
                <?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault>\
                <s:Code><s:Value>s:Sender</s:Value></s:Code></s:Fault></s:Body></s:Envelope>
                """, status: 400)
            }
            let elements = osds.value.map { "<trt:OSDs token=\"\($0.token)\">\($0.children)</trt:OSDs>" }.joined()
            return self.envelope("<trt:GetOSDsResponse xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\">\(elements)</trt:GetOSDsResponse>")
        case "DeleteOSD":
            let token = envelope.firstDescendant("OSDToken")?.text ?? ""
            osdCalls.update { $0.append("DeleteOSD:\(token)") }
            switch osdMode.value {
            case .refuseDelete, .refuseAll: return fault("InvalidArgVal", "the OSD can not be deleted")
            case .ignoreChanges: break
            case .accept, .bareSenderFault: osds.update { $0.removeAll { $0.token == token } }
            }
            return self.envelope("<trt:DeleteOSDResponse xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\"/>")
        case "CreateOSD":
            osdCalls.update { $0.append("CreateOSD") }
            if osdMode.value == .refuseAll { return fault("InvalidArgVal", "the OSD can not be created") }
            let children = envelope.firstDescendant("OSD")?.children.map { $0.serialized() }.joined() ?? ""
            let token = "OSD_created_\(osds.value.count)"
            if osdMode.value != .ignoreChanges { osds.update { $0.append((token, children)) } }
            return self.envelope("<trt:CreateOSDResponse xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\"><trt:OSDToken>\(token)</trt:OSDToken></trt:CreateOSDResponse>")
        case "SetOSD":
            let node = envelope.firstDescendant("OSD")
            let token = node?.attribute("token") ?? ""
            osdCalls.update { $0.append("SetOSD:\(token)") }
            if osdMode.value == .refuseAll { return fault("InvalidArgVal", "the OSD can not be changed") }
            let children = node?.children.map { $0.serialized() }.joined() ?? ""
            if osdMode.value != .ignoreChanges { osds.update { list in if let index = list.firstIndex(where: { $0.token == token }) { list[index].children = children } } }
            return self.envelope("<trt:SetOSDResponse xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\"/>")
        case "SetSystemDateAndTime":
            clockCalls.update { $0.append("SetSystemDateAndTime") }
            if refuseClockChanges.value { return fault("InvalidArgVal", "the time settings can not be changed") }
            let type = envelope.firstDescendant("DateTimeType")?.text ?? "NTP"
            let dst = envelope.firstDescendant("DaylightSavings")?.text == "true"
            let zone = envelope.firstDescendant("TimeZone")?.child("TZ")?.text
            clock.update { state in
                state.type = type
                state.daylightSavings = dst
                if let zone { state.timeZone = zone }
            }
            return self.envelope("<tds:SetSystemDateAndTimeResponse/>")
        case "GetNTP":
            if noNTP.value { return fault("ActionNotSupported", "GetNTP is not supported") }
            let state = clock.value
            let manual = state.ntpServers.map { server in
                ONVIFClient.isIPv4(server) ? "<tt:NTPManual><tt:Type>IPv4</tt:Type><tt:IPv4Address>\(server)</tt:IPv4Address></tt:NTPManual>"
                    : "<tt:NTPManual><tt:Type>DNS</tt:Type><tt:DNSname>\(server)</tt:DNSname></tt:NTPManual>"
            }.joined()
            return self.envelope("<tds:GetNTPResponse><tds:NTPInformation><tt:FromDHCP>\(state.ntpFromDHCP)</tt:FromDHCP>\(manual)</tds:NTPInformation></tds:GetNTPResponse>")
        case "SetNTP":
            clockCalls.update { $0.append("SetNTP") }
            if refuseClockChanges.value { return fault("InvalidArgVal", "the time servers can not be changed") }
            let fromDHCP = envelope.firstDescendant("FromDHCP")?.text == "true"
            let servers = (envelope.firstDescendant("SetNTP")?.children("NTPManual") ?? []).compactMap { entry in
                entry.string("IPv4Address") ?? entry.string("IPv6Address") ?? entry.string("DNSname")
            }
            clock.update { state in
                state.ntpFromDHCP = fromDHCP
                state.ntpServers = servers
            }
            return self.envelope("<tds:SetNTPResponse/>")
        case "GetDNS":
            if noDNS.value { return fault("ActionNotSupported", "GetDNS is not supported") }
            let restarting = pendingDNS.update { pending -> Bool in
                guard let waiting = pending else { return false }
                guard waiting.readsLeft == 0 else { pending?.readsLeft -= 1; return true }
                dns.update(waiting.apply)
                pending = nil
                return false
            }
            if restarting && silentWhileApplying.value { return .status(503) }
            let state = dns.value
            let search = state.searchDomains.map { "<tt:SearchDomain>\($0)</tt:SearchDomain>" }.joined()
            let fromDHCP = state.fromDHCP ? state.dhcpServers.map { Self.addressEntry("DNSFromDHCP", $0) }.joined() : ""
            let slots = emptySlotShownAs.value.map { zero in state.manualServers.map { $0.isEmpty ? zero : $0 } } ?? state.manualServers.filter { !$0.isEmpty }
            let shown = dnsSlots.value != .asSent && state.fromDHCP ? [] : slots
            let manual = shown.map { Self.addressEntry("DNSManual", $0) }.joined()
            return self.envelope("<tds:GetDNSResponse><tds:DNSInformation><tt:FromDHCP>\(state.fromDHCP)</tt:FromDHCP>\(search)\(fromDHCP)\(manual)"
                + "</tds:DNSInformation></tds:GetDNSResponse>")
        case "SetDNS":
            setDNSBodies.update { $0.append(request.bodyText) }
            if let subcode = dnsFaults.update({ $0.isEmpty ? nil : $0.removeFirst() }) { return fault(subcode, "the DNS settings can not be changed") }
            if refuseDNSChanges.value { return fault("InvalidArgVal", "the DNS settings can not be changed") }
            if ignoreDNSChanges.value { return self.envelope("<tds:SetDNSResponse/>") }
            let set = envelope.firstDescendant("SetDNS")
            let fromDHCP = set?.child("FromDHCP")?.text == "true"
            let search = (set?.children("SearchDomain") ?? []).map(\.text)
            // IPv6 addresses kept in lower case, as cameras echo them.
            let servers = (set?.children("DNSManual") ?? []).compactMap { $0.string("IPv4Address") ?? $0.string("IPv6Address")?.lowercased() }
            let slots = dnsSlots.value
            let named = servers.filter { !$0.isEmpty }
            if slots == .twoRefusingDuplicates, Set(named).count < named.count { return fault("InvalidArgVal", "a DNS server is named twice") }
            let apply: @Sendable (inout DNS) -> Void = { state in
                state.fromDHCP = fromDHCP
                state.searchDomains = search
                guard slots != .asSent else { state.manualServers = servers; return }
                var kept = Array((state.manualServers + ["", ""]).prefix(2))
                for (index, server) in servers.prefix(2).enumerated() where !(slots == .twoKeepingSecond && index == 1) { kept[index] = server }
                state.manualServers = kept
            }
            if let reads = applyDNSAfterReads.value {
                pendingDNS.set(PendingDNS(readsLeft: reads, apply: apply))
            } else {
                dns.update(apply)
            }
            return self.envelope("<tds:SetDNSResponse/>")
        case "GetNetworkDefaultGateway": return self.envelope(Self.gatewayAnswer(gateways.value))
        case "GetNetworkInterfaces":
            return self.envelope(interfacesOverride.value ?? Self.interfacesAnswer(ipv4.value, hardwareAddress: hidesHardwareAddress.value ? nil : Self.hardwareAddress))
        case "SetNetworkInterfaces":
            setNetworkInterfacesBodies.update { $0.append(request.bodyText) }
            if let subcode = networkInterfacesFault.value { return fault(subcode, "the network interface settings can not be changed") }
            let set = envelope.firstDescendant("SetNetworkInterfaces")
            guard set?.string("InterfaceToken") == "eth0", let config = set?.child("NetworkInterface")?.child("IPv4"),
                  let dhcp = config.child("DHCP").flatMap({ ONVIFNotification.parseBool($0.text) }) else {
                return fault("InvalidArgVal", "the network interface settings are not valid")
            }
            let manual = config.child("Manual")
            let reboot = networkRebootNeeded.value
            if !reboot, !ignoreNetworkChanges.value {
                if dropsGatewayWhenFixed.value { gateways.set(dhcp ? ["192.168.77.1"] : []) }
                ipv4.update { state in
                    state.dhcp = dhcp
                    if !dhcp, let address = manual?.string("Address"), let prefix = manual?.string("PrefixLength").flatMap({ Int($0) }) {
                        state.address = address
                        state.prefixLength = prefix
                    }
                }
            }
            if networkInterfacesUnreadable.value { return self.envelope("<tds:Unexpected/>") }
            return self.envelope("<tds:SetNetworkInterfacesResponse><tds:RebootNeeded>\(reboot)</tds:RebootNeeded></tds:SetNetworkInterfacesResponse>")
        case "SetNetworkDefaultGateway":
            setGatewayBodies.update { $0.append(request.bodyText) }
            if ignoreGatewayChanges.value { return self.envelope("<tds:SetNetworkDefaultGatewayResponse/>") }
            gateways.set((envelope.firstDescendant("SetNetworkDefaultGateway")?.children("IPv4Address") ?? []).map(\.text))
            return self.envelope("<tds:SetNetworkDefaultGatewayResponse/>")
        case "GetImagingSettings": return .soap(template("GetImagingSettingsResponse.xml"))
        case "GetOptions": return .soap(template("GetImagingOptionsResponse.xml"))
        case "SetImagingSettings":
            setImagingSettingsCalls.update { $0.append(envelope.firstDescendant("VideoSourceToken")?.text ?? "") }
            return self.envelope("<timg:SetImagingSettingsResponse/>")
        case "SetSynchronizationPoint":
            synchronizationPoints.update { $0.append(envelope.firstDescendant("ProfileToken")?.text ?? "") }
            if refuseSynchronizationPoint.value { return fault("ActionNotSupported", "SetSynchronizationPoint is not supported") }
            return self.envelope("<trt:SetSynchronizationPointResponse xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\"/>")
        case "SystemReboot":
            systemRebootCalled.update { $0 += 1 }
            return self.envelope("<tds:SystemRebootResponse><tds:Message>Rebooting</tds:Message></tds:SystemRebootResponse>")
        case "CreatePullPointSubscription":
            if failCreateSubscription.value { return fault("ActionNotSupported", "create pull-point subscription failed") }
            return .soap(template("CreatePullPointSubscriptionResponse.xml"))
        case "PullMessages", "Renew", "Unsubscribe":
            let header = envelope.child("Header")
            subscriptionHeaders.update { $0.append(header.map { h in h.children.map { $0.serialized() }.joined() } ?? "") }
            switch action {
            case "PullMessages":
                if failPulls.value { return .status(500) }
                let next = pullQueue.update { queue -> String? in queue.isEmpty ? nil : queue.removeFirst() }
                if let next { return .soap(template(next)) }
                if !instantEmptyPulls.value { try? await Task.sleep(for: .milliseconds(50)) }
                return .soap(template("Pull-Empty.xml"))
            case "Renew":
                if let subcode = renewFault.value { return fault(subcode, renewFaultReason.value) }
                return self.envelope("<wsnt:RenewResponse><wsnt:TerminationTime>2026-09-30T15:07:52Z</wsnt:TerminationTime></wsnt:RenewResponse>")
            default:
                return self.envelope("<wsnt:UnsubscribeResponse/>")
            }
        default:
            return fault("ActionNotSupported", "unsupported \(action)")
        }
    }
}

#endif
