#if os(macOS)
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
        xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"><s:Body>\(body)</s:Body></s:Envelope>
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
            return self.envelope("""
            <tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:DateTimeType>NTP</tt:DateTimeType><tt:UTCDateTime>\
            <tt:Time><tt:Hour>\(c.hour!)</tt:Hour><tt:Minute>\(c.minute!)</tt:Minute><tt:Second>\(c.second!)</tt:Second></tt:Time>\
            <tt:Date><tt:Year>\(c.year!)</tt:Year><tt:Month>\(c.month!)</tt:Month><tt:Day>\(c.day!)</tt:Day></tt:Date></tt:UTCDateTime>\
            </tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>
            """)
        }
        guard !rejectCredentials.value, authorized(envelope) else { return fault("NotAuthorized", "Sender not Authorized") }
        switch action {
        case "GetDeviceInformation": return .soap(template("GetDeviceInformationResponse.xml"))
        case "GetCapabilities": return .soap(template("GetCapabilitiesResponse.xml"))
        case "GetServices": return .soap(template("GetServicesResponse.xml"))
        case "GetProfiles": return .soap(withEncoderValues(template("GetProfilesResponse.xml")))
        case "GetStreamUri":
            let token = envelope.firstDescendant("ProfileToken")?.text ?? ""
            let uri = token == "000" ? "rtsp://admin:secret@10.0.0.99:554/Preview_01_main" : "rtsp://127.0.0.1:554/Preview_01_sub"
            return .soap(template("GetStreamUriResponse.xml").replacingOccurrences(of: "{{URI}}", with: uri))
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
