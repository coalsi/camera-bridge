import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MediaCore

struct ONVIFDeviceInformation: Sendable, Equatable {
    var manufacturer: String
    var model: String
    var firmwareVersion: String
    var serialNumber: String
    var hardwareID: String
}

struct ONVIFCapabilities: Sendable, Equatable {
    var mediaURL: URL?
    var eventsURL: URL?
    var pullPointSupported: Bool
}

struct ONVIFProfile: Sendable, Equatable {
    var token: String
    var name: String
    var videoEncoding: String?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var audioEncoding: String?
    /// Hz.
    var audioSampleRate: Int?
    /// The profile carries a PTZ configuration (the camera pans, tilts or zooms through it).
    var ptzConfigured = false

    var videoCodec: VideoCodec? {
        switch videoEncoding?.uppercased() {
        case "H264": .h264
        case "H265", "HEVC": .hevc
        default: nil
        }
    }

    var audioCodec: AudioCodec? {
        switch audioEncoding?.uppercased() {
        case "AAC", "MP4A-LATM", "MPEG4-GENERIC": .aac
        case "G711", "PCMU": .pcmu
        case "PCMA": .pcma
        default: nil
        }
    }

    /// width × height (0 when unknown, `Int.max` rather than overflowing).
    var pixelCount: Int {
        let (product, overflow) = (width ?? 0).multipliedReportingOverflow(by: height ?? 0)
        return overflow ? Int.max : max(0, product)
    }

    func streamInfo(url: URL) -> StreamInfo {
        StreamInfo(url: url, videoCodec: videoCodec, width: width, height: height, fps: frameRate, audioCodec: audioCodec,
                   audioSampleRate: audioCodec == nil ? nil : (audioSampleRate ?? (audioCodec == .aac ? nil : 8000)),
                   audioChannels: audioCodec == nil ? nil : 1)
    }
}

/// A PullPoint subscription: the manager address plus WS-Addressing reference parameters to echo in each request.
struct ONVIFSubscription: Sendable, Equatable {
    var address: URL
    var referenceParameters: String
}

/// ONVIF SOAP 1.2 client (device, media and event services). Requests carry a WS-UsernameToken PasswordDigest with the
/// camera's clock offset applied; HTTP Digest/Basic challenges are answered by `AuthenticatingHTTPClient`.
/// XAddrs reported by the camera keep their port and path but take the configured host (cameras behind NAT or with a
/// stale address report internal hosts); with an HTTPS device service, reported `http` addresses become `https` on its
/// port (`serviceURL(_:deviceServiceURL:)`).
/// Keeps CameraBridge from locking a camera out (Hikvision locks logins for 30 min after a handful of wrong
/// passwords, and every further attempt restarts the lock). After a rejected login, ONVIF logins to that host
/// pause for 2 minutes (Camera Bridge's own pause); after the camera locked them, for 30 minutes. Successful-looking
/// requests never touch it, nor does a write refused to an account the camera just signed in (`CameraAdapterError.notPermitted`: the
/// password is right). The pause keeps its cause, so a call that meets it throws the right error (`Pause.error`).
final class ONVIFLoginGuard: @unchecked Sendable {
    /// Why logins to a host are paused.
    enum Cause: Sendable, Equatable {
        /// The camera refused a login: Camera Bridge's own pause, so the next tries don't lock the account.
        case refused
        /// The camera locked its logins after too many wrong passwords.
        case cameraLocked
    }

    struct Pause: Sendable, Equatable {
        var until: Date
        var cause: Cause

        /// What a call that meets the pause throws: `.lockedOut` for the camera's lock, `.loginsPaused` for Camera Bridge's own.
        var error: CameraAdapterError {
            cause == .cameraLocked ? .lockedOut(until: until) : .loginsPaused(until: until)
        }
    }

    static let shared = ONVIFLoginGuard()
    static let rejectionPause: TimeInterval = 120
    static let lockoutPause: TimeInterval = 30 * 60
    private let lock = NSLock()
    /// Per host, when Camera Bridge's pause after a refusal ends and when the camera's lock does.
    private var paused: [String: (refused: Date?, locked: Date?)] = [:]

    /// The pause of `host` now: it lasts until the later of its two ends. While the camera's lock lasts it is the cause (a refusal never
    /// shortens or recasts it); after that, what is left is Camera Bridge's own.
    func pause(host: String, now: Date = Date()) -> Pause? {
        lock.withLock {
            guard let entry = paused[host] else { return nil }
            let until = max(entry.refused ?? .distantPast, entry.locked ?? .distantPast)
            guard until > now else { return nil }
            return Pause(until: until, cause: (entry.locked ?? .distantPast) > now ? .cameraLocked : .refused)
        }
    }

    /// The longest pause of `hosts` (one account behind several ports), the camera's lock when any of them has one.
    func pause(hosts: [String], now: Date = Date()) -> Pause? {
        let pauses = hosts.compactMap { pause(host: $0, now: now) }
        guard let until = pauses.map(\.until).max() else { return nil }
        return Pause(until: until, cause: pauses.contains { $0.cause == .cameraLocked } ? .cameraLocked : .refused)
    }

    func blockedUntil(host: String, now: Date = Date()) -> Date? {
        pause(host: host, now: now)?.until
    }

    /// The camera refused a login: Camera Bridge pauses logins to `host` for `rejectionPause`.
    func recordRejection(host: String, now: Date = Date()) {
        lock.withLock {
            let until = now.addingTimeInterval(Self.rejectionPause)
            paused[host, default: (nil, nil)].refused = max(paused[host]?.refused ?? until, until)
        }
    }

    /// The camera locked its logins for `duration` (by default 30 minutes, Hikvision's). Returns when the pause ends.
    @discardableResult
    func recordLockout(host: String, now: Date = Date(), for duration: TimeInterval = ONVIFLoginGuard.lockoutPause) -> Date {
        lock.withLock {
            let until = now.addingTimeInterval(duration)
            paused[host, default: (nil, nil)].locked = max(paused[host]?.locked ?? until, until)
            return max(paused[host]?.refused ?? until, paused[host]?.locked ?? until)
        }
    }

    /// Forgets a pause (tests: a mock camera's ephemeral port must not stay blocked for the next test that binds it).
    func clear(host: String) {
        lock.withLock { _ = paused.removeValue(forKey: host) }
    }
}

actor ONVIFClient {
    static let mediaNamespace = "http://www.onvif.org/ver10/media/wsdl"
    static let eventsNamespace = "http://www.onvif.org/ver10/events/wsdl"

    let deviceServiceURL: URL
    private let credentials: HTTPCredentials?
    private let http: AuthenticatingHTTPClient
    private let longPollHTTP: AuthenticatingHTTPClient
    private var clockOffset: TimeInterval = 0
    /// "NTP" or "Manual", as the camera reported in its last `GetSystemDateAndTime` (readable without a login).
    private(set) var dateTimeType: String?
    private var cachedCapabilities: ONVIFCapabilities?
    private var cachedServices: [String: URL]?
    /// The camera refused this client's own login, and no login has worked since. A call that then meets Camera Bridge's pause reports
    /// that refusal (`.unauthorized`) rather than the pause it caused: an event channel whose first call was refused meets the pause on
    /// its next one (the subscription, after `eventsServiceURL` swallowed the refusal), and it is that channel the camera refused.
    private var refusedLogin = false
    /// When a call the camera answers only to the right password last succeeded on this client (`provesLogin`), since its last refused
    /// login. A write the camera refuses (`NotAuthorized`, HTTP 401) within `loginProofWindow` of it is one this account may not make
    /// (`.notPermitted`), not a wrong password: the Reolink doorbell's ONVIF account reads `GetNTP` and `GetDNS` but is refused `SetNTP`.
    private var loginProvenAt: Date?
    /// How long a call that signed in proves the login for a write refused after it (`.notPermitted`): a setup run reads right before it
    /// writes, while a driver's long-lived client whose password changed on the camera since takes the refusal for a refused login again.
    static let loginProofWindow: TimeInterval = 300
    private let now: @Sendable () -> Date
    private let log: Log

    /// `cameraID`: the camera the client serves (its log lines are tagged with it). `now`: the clock a login's proof is timed by (tests).
    init(deviceServiceURL: URL, credentials: HTTPCredentials?, timeout: Duration = .seconds(10), longPollTimeout: Duration = .seconds(80),
         cameraID: UUID? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.deviceServiceURL = deviceServiceURL
        self.credentials = credentials
        self.http = AuthenticatingHTTPClient(credentials: credentials, timeout: timeout)
        self.longPollHTTP = AuthenticatingHTTPClient(credentials: credentials, timeout: longPollTimeout)
        self.now = now
        self.log = Log(category: "onvif", cameraID: cameraID)
    }

    /// The operation an ONVIF action names when it changes something on the camera (a setting, the picture, the camera's position): "SetNTP",
    /// "SetDNS", "SetSystemDateAndTime", "SetVideoEncoderConfiguration", "CreateOSD", "DeleteOSD", "SetImagingSettings", "ContinuousMove",
    /// "Stop", "SendAuxiliaryCommand", "SystemReboot"; nil for a read and for the event service's messages (subscribe, pull, renew).
    static func writeName(action: String?) -> String? {
        guard let name = operation(action), !name.hasSuffix("Request") else { return nil }
        let writes = ["Set", "Create", "Delete", "Remove", "Add", "Goto", "Send"].contains { name.hasPrefix($0) }
            || name.hasSuffix("Move") || ["Stop", "SystemReboot"].contains(name)
        return writes ? name : nil
    }

    /// ONVIF's calls a device answers before authentication (the Core specification's PRE_AUTH access class): their answer says nothing
    /// about the password the request carried.
    static let preAuthenticationCalls: Set<String> = ["GetSystemDateAndTime", "GetCapabilities", "GetServices", "GetServiceCapabilities",
                                                       "GetWsdlUrl", "GetHostname", "GetEndpointReference"]

    /// Whether the camera answering `action` proves the login: an authenticated call it answers only to the right password. Not ONVIF's
    /// calls before authentication (`preAuthenticationCalls`), which a camera may answer to anyone, nor the event service's messages.
    static func provesLogin(action: String?) -> Bool {
        guard let name = operation(action) else { return false }
        return !preAuthenticationCalls.contains(name) && !name.hasSuffix("Request")
    }

    /// The operation an action URI names: its last path component ("SetNTP" of ".../device/wsdl/SetNTP").
    private static func operation(_ action: String?) -> String? {
        guard let name = action?.split(separator: "/").last, !name.isEmpty else { return nil }
        return String(name)
    }

    /// `http(s)://host:(onvifPort ?? httpPort)/onvif/device_service`.
    static func deviceServiceURL(for endpoint: CameraEndpoint) -> URL? {
        endpoint.httpURL(path: "/onvif/device_service", port: endpoint.onvifPort ?? endpoint.httpPort)
    }

    // MARK: Transport

    /// POSTs a SOAP request and returns the response envelope. SOAP faults throw (`NotAuthorized` → `.unauthorized`, or `.notPermitted` for
    /// a write this account may not make: `refusal(host:action:)`).
    func call(_ url: URL, body: String, action: String? = nil, header: String = "", authenticated: Bool = true,
              longPoll: Bool = false) async throws -> XMLTree {
        var security: String?
        let host = "\(url.host(percentEncoded: false) ?? ""):\(url.port ?? 80)"
        if authenticated, credentials != nil, let pause = ONVIFLoginGuard.shared.pause(host: host) {
            throw refusedLogin && pause.cause == .refused ? CameraAdapterError.unauthorized : pause.error
        }
        if authenticated, let credentials {
            security = ONVIFSOAP.securityHeader(username: credentials.username, password: credentials.password,
                                                created: Date().addingTimeInterval(clockOffset), nonce: ONVIFSOAP.randomNonce())
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = ONVIFSOAP.envelope(body: body, header: header, security: security)
        var contentType = "application/soap+xml; charset=utf-8"
        if let action { contentType += "; action=\"\(action)\"" }
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await (longPoll ? longPollHTTP : http).data(for: request)
        } catch {
            throw CameraHTTP.sanitized(error)
        }
        let envelope = try? XMLTree.parse(data)
        if authenticated, credentials != nil {
            // Hikvision answers a locked device with HTTP 400 and a plain-text/HTML "device is locked" message.
            let text = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
            if text.contains("locked") && (text.contains("password") || text.contains("try it after")) {
                let until = ONVIFLoginGuard.shared.recordLockout(host: host)
                log.warning("ONVIF \(host): the camera locked logins after too many wrong passwords; not trying again for 30 min")
                throw CameraAdapterError.lockedOut(until: until)
            }
        }
        if let envelope, let fault = ONVIFSOAP.fault(in: envelope) {
            if fault.isNotAuthorized {
                guard authenticated else { throw CameraAdapterError.unauthorized }
                throw refusal(host: host, action: action)
            }
            throw CameraAdapterError.soapFault(fault.summary)
        }
        if response.statusCode == 401 {
            guard authenticated else { throw CameraAdapterError.unauthorized }
            throw refusal(host: host, action: action)
        }
        guard (200..<300).contains(response.statusCode) else { throw CameraAdapterError.httpStatus(response.statusCode) }
        guard let envelope, envelope.child("Body") != nil else { throw CameraAdapterError.invalidResponse("not a SOAP envelope") }
        if authenticated, credentials != nil {
            refusedLogin = false
            if Self.provesLogin(action: action) { loginProvenAt = now() }
        }
        return envelope
    }

    /// What an authenticated call the camera refused (`NotAuthorized`, HTTP 401) throws. A write refused while this client's login is proven
    /// (a call that signed in, `loginProvenAt`, within `loginProofWindow`) is one this account may not make: `.notPermitted`, and nothing
    /// pauses, since the password is right. Anything else, a first call included, is a refused login: logins to `host` pause
    /// (`ONVIFLoginGuard`) and the proof is gone.
    private func refusal(host: String, action: String?) -> CameraAdapterError {
        if credentials != nil, let name = Self.writeName(action: action), let proven = loginProvenAt,
           now().timeIntervalSince(proven) < Self.loginProofWindow {
            log.info("ONVIF \(host): the camera refused \(name) to the account Camera Bridge uses, which it signed in and read with: the account "
                     + "may not change this (not a wrong password, so logins are not paused)")
            return .notPermitted(name)
        }
        refused(host)
        return .unauthorized
    }

    /// The camera refused this client's login: logins to `host` pause (`ONVIFLoginGuard`).
    private func refused(_ host: String) {
        refusedLogin = true
        loginProvenAt = nil
        ONVIFLoginGuard.shared.recordRejection(host: host)
    }

    func responseBody(_ envelope: XMLTree, _ name: String) throws -> XMLTree {
        guard let body = envelope.child("Body")?.child(name) ?? envelope.firstDescendant(name) else {
            throw CameraAdapterError.invalidResponse("missing \(name)")
        }
        return body
    }

    private func xAddr(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else { return nil }
        let resolved = Self.serviceURL(url, deviceServiceURL: deviceServiceURL)
        if url.scheme?.lowercased() == "http", resolved.scheme == "https" {
            log.debug("camera reported an http:// address; using HTTPS like the device service")
        }
        return resolved
    }

    /// A camera-reported XAddr, subscription address or media URI as this client uses it: the configured host replaces
    /// the reported one (cameras behind NAT or with a stale address report internal hosts), keeping scheme, port, path
    /// and query — except that when the device service is HTTPS ("Use HTTPS"), an `http` URL becomes `https` on the
    /// device service's port. Cameras report `http://<ip>/onvif/…` even with HTTPS on; following them would send the
    /// media, event, PullPoint and snapshot requests (WS-Security digests, HTTP Digest/Basic answers, images) in
    /// cleartext, or fail on a camera with HTTP turned off.
    static func serviceURL(_ reported: URL, deviceServiceURL: URL) -> URL {
        guard let host = deviceServiceURL.host(percentEncoded: false) else { return reported }
        let url = reported.replacingHost(with: host)
        guard deviceServiceURL.scheme?.lowercased() == "https", url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        components.port = deviceServiceURL.port   // nil: HTTPS's default port, as the device service
        return components.url ?? url
    }

    // MARK: Device service

    /// `GetSystemDateAndTime` (unauthenticated). Records the camera clock offset used for WS-Security `Created`.
    @discardableResult
    func systemDateAndTime() async throws -> Date? {
        let envelope = try await call(deviceServiceURL, body: "<tds:GetSystemDateAndTime/>",
                                      action: "http://www.onvif.org/ver10/device/wsdl/GetSystemDateAndTime", authenticated: false)
        let body = try responseBody(envelope, "GetSystemDateAndTimeResponse")
        dateTimeType = body.firstDescendant("DateTimeType")?.text.trimmingCharacters(in: .whitespaces)
        guard let date = Self.parseSystemDate(body) else { return nil }
        let offset = date.timeIntervalSinceNow
        guard offset.isFinite else { return nil }
        clockOffset = abs(offset) > 5 ? offset : 0
        if clockOffset != 0 {
            log.info("ONVIF \(deviceServiceURL.host(percentEncoded: false) ?? "camera"): camera clock differs by \(Int(clockOffset)) s; "
                     + "adjusting WS-Security timestamps")
        }
        return date
    }

    /// The `UTCDateTime` of a `GetSystemDateAndTimeResponse`; nil when missing or out of range (years 1970…2999).
    static func parseSystemDate(_ response: XMLTree) -> Date? {
        guard let utc = response.firstDescendant("UTCDateTime") else { return nil }
        func component(_ path: String..., in range: ClosedRange<Int>) -> Int? {
            guard let text = utc.element(path: path)?.text, let value = Int(text.trimmingCharacters(in: .whitespaces)), range.contains(value) else {
                return nil
            }
            return value
        }
        guard let year = component("Date", "Year", in: 1970...2999), let month = component("Date", "Month", in: 1...12),
              let day = component("Date", "Day", in: 1...31), let hour = component("Time", "Hour", in: 0...23),
              let minute = component("Time", "Minute", in: 0...59), let second = component("Time", "Second", in: 0...60) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }

    func deviceInformation() async throws -> ONVIFDeviceInformation {
        let envelope = try await call(deviceServiceURL, body: "<tds:GetDeviceInformation/>",
                                      action: "http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation")
        let r = try responseBody(envelope, "GetDeviceInformationResponse")
        return ONVIFDeviceInformation(manufacturer: r.string("Manufacturer") ?? "", model: r.string("Model") ?? "",
                                      firmwareVersion: r.string("FirmwareVersion") ?? "", serialNumber: r.string("SerialNumber") ?? "",
                                      hardwareID: r.string("HardwareId") ?? "")
    }

    func capabilities() async throws -> ONVIFCapabilities {
        if let cachedCapabilities { return cachedCapabilities }
        let envelope = try await call(deviceServiceURL, body: "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>",
                                      action: "http://www.onvif.org/ver10/device/wsdl/GetCapabilities")
        let caps = try responseBody(envelope, "GetCapabilitiesResponse").child("Capabilities")
        let events = caps?.child("Events")
        let result = ONVIFCapabilities(mediaURL: xAddr(caps?.element("Media", "XAddr")?.text), eventsURL: xAddr(events?.string("XAddr")),
                                       pullPointSupported: events?.string("WSPullPointSupport").flatMap(ONVIFNotification.parseBool) ?? (events != nil))
        cachedCapabilities = result
        return result
    }

    /// Namespace → XAddr from `GetServices`.
    func services() async throws -> [String: URL] {
        if let cachedServices { return cachedServices }
        let envelope = try await call(deviceServiceURL, body: "<tds:GetServices><tds:IncludeCapability>false</tds:IncludeCapability></tds:GetServices>",
                                      action: "http://www.onvif.org/ver10/device/wsdl/GetServices")
        var result: [String: URL] = [:]
        for service in try responseBody(envelope, "GetServicesResponse").children("Service") {
            if let namespace = service.string("Namespace"), let url = xAddr(service.string("XAddr")) { result[namespace] = url }
        }
        cachedServices = result
        return result
    }

    func mediaServiceURL() async -> URL {
        if let url = try? await capabilities().mediaURL { return url }
        if let url = try? await services()[Self.mediaNamespace] { return url }
        return deviceServiceURL
    }

    func eventsServiceURL() async -> URL {
        if let url = try? await capabilities().eventsURL { return url }
        if let url = try? await services()[Self.eventsNamespace] { return url }
        return deviceServiceURL
    }

    // MARK: Media service

    func profiles() async throws -> [ONVIFProfile] {
        let envelope = try await call(await mediaServiceURL(), body: "<trt:GetProfiles/>", action: "http://www.onvif.org/ver10/media/wsdl/GetProfiles")
        _ = try responseBody(envelope, "GetProfilesResponse")
        return Self.parseProfiles(envelope)
    }

    /// Media profiles of a `GetProfilesResponse` envelope. Camera-reported numbers are sanitized (`CameraNumbers`).
    static func parseProfiles(_ envelope: XMLTree) -> [ONVIFProfile] {
        guard let response = envelope.child("Body")?.child("GetProfilesResponse") ?? envelope.firstDescendant("GetProfilesResponse") else {
            return []
        }
        return response.children("Profiles").compactMap { profile in
            guard let token = profile.attribute("token") else { return nil }
            let video = profile.child("VideoEncoderConfiguration")
            let audio = profile.child("AudioEncoderConfiguration")
            return ONVIFProfile(token: token, name: profile.string("Name") ?? token, videoEncoding: video?.string("Encoding"),
                                width: CameraNumbers.dimension(video?.string("Resolution", "Width")),
                                height: CameraNumbers.dimension(video?.string("Resolution", "Height")),
                                frameRate: CameraNumbers.frameRate(video?.string("RateControl", "FrameRateLimit").flatMap(Double.init)),
                                audioEncoding: audio?.string("Encoding"), audioSampleRate: CameraNumbers.sampleRate(audio?.string("SampleRate")),
                                ptzConfigured: profile.child("PTZConfiguration") != nil)
        }
    }

    /// RTSP stream URI (RTP-Unicast over RTSP), without credentials, host set to the configured camera host.
    func streamURI(profileToken: String) async throws -> URL {
        let body = "<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol>"
            + "</tt:Transport></trt:StreamSetup><trt:ProfileToken>\(XMLTree.escape(profileToken))</trt:ProfileToken></trt:GetStreamUri>"
        let envelope = try await call(await mediaServiceURL(), body: body, action: "http://www.onvif.org/ver10/media/wsdl/GetStreamUri")
        guard let uri = xAddr(try responseBody(envelope, "GetStreamUriResponse").element("MediaUri", "Uri")?.text) else {
            throw CameraAdapterError.invalidResponse("missing stream URI")
        }
        return uri.removingUserInfo
    }

    /// Asks the profile's encoder for a keyframe (`SetSynchronizationPoint`): one call, answered with an empty response.
    func setSynchronizationPoint(profileToken: String) async throws {
        let body = "<trt:SetSynchronizationPoint><trt:ProfileToken>\(XMLTree.escape(profileToken))</trt:ProfileToken></trt:SetSynchronizationPoint>"
        _ = try await call(await mediaServiceURL(), body: body, action: "http://www.onvif.org/ver10/media/wsdl/SetSynchronizationPoint")
    }

    func snapshotURI(profileToken: String) async throws -> URL {
        let body = "<trt:GetSnapshotUri><trt:ProfileToken>\(XMLTree.escape(profileToken))</trt:ProfileToken></trt:GetSnapshotUri>"
        let envelope = try await call(await mediaServiceURL(), body: body, action: "http://www.onvif.org/ver10/media/wsdl/GetSnapshotUri")
        guard let uri = xAddr(try responseBody(envelope, "GetSnapshotUriResponse").element("MediaUri", "Uri")?.text) else {
            throw CameraAdapterError.invalidResponse("missing snapshot URI")
        }
        return uri.removingUserInfo
    }

    /// Fetches a JPEG from a snapshot URI with the same credentials (HTTP Digest/Basic).
    func fetchSnapshot(_ url: URL) async throws -> Data {
        let (data, _) = try await CameraHTTP.send(http, CameraHTTP.request(url))
        return data
    }

    // MARK: Event service

    func eventTopics() async throws -> Set<String> {
        let envelope = try await call(await eventsServiceURL(), body: "<tev:GetEventProperties/>",
                                      action: "http://www.onvif.org/ver10/events/wsdl/EventPortType/GetEventPropertiesRequest")
        return ONVIFEventMapper.topics(inEventProperties: envelope)
    }

    func createPullPointSubscription(initialTerminationTime: String) async throws -> ONVIFSubscription {
        let eventsURL = await eventsServiceURL()
        let body = "<tev:CreatePullPointSubscription><tev:InitialTerminationTime>\(XMLTree.escape(initialTerminationTime))"
            + "</tev:InitialTerminationTime></tev:CreatePullPointSubscription>"
        let envelope = try await call(eventsURL, body: body,
                                      action: "http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest")
        let reference = try responseBody(envelope, "CreatePullPointSubscriptionResponse").child("SubscriptionReference")
        guard let address = xAddr(reference?.string("Address")) else { throw CameraAdapterError.invalidResponse("missing subscription address") }
        let parameters = reference?.child("ReferenceParameters")?.children.map { $0.serialized() }.joined() ?? ""
        return ONVIFSubscription(address: address, referenceParameters: parameters)
    }

    private func addressingHeader(_ subscription: ONVIFSubscription, action: String) -> String {
        "<wsa:Action>\(XMLTree.escape(action))</wsa:Action><wsa:To>\(XMLTree.escape(subscription.address.absoluteString))</wsa:To>"
            + subscription.referenceParameters
    }

    func pullMessages(_ subscription: ONVIFSubscription, timeout: String, messageLimit: Int) async throws -> [ONVIFNotification] {
        let action = "http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest"
        let body = "<tev:PullMessages><tev:Timeout>\(XMLTree.escape(timeout))</tev:Timeout><tev:MessageLimit>\(messageLimit)</tev:MessageLimit>"
            + "</tev:PullMessages>"
        let envelope = try await call(subscription.address, body: body, action: action,
                                      header: addressingHeader(subscription, action: action), longPoll: true)
        _ = try responseBody(envelope, "PullMessagesResponse")
        return ONVIFNotification.parse(pullMessagesResponse: envelope)
    }

    func renew(_ subscription: ONVIFSubscription, terminationTime: String) async throws {
        let action = "http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/RenewRequest"
        let body = "<wsnt:Renew><wsnt:TerminationTime>\(XMLTree.escape(terminationTime))</wsnt:TerminationTime></wsnt:Renew>"
        _ = try await call(subscription.address, body: body, action: action, header: addressingHeader(subscription, action: action))
    }

    func unsubscribe(_ subscription: ONVIFSubscription) async throws {
        let action = "http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/UnsubscribeRequest"
        _ = try await call(subscription.address, body: "<wsnt:Unsubscribe/>", action: action,
                           header: addressingHeader(subscription, action: action))
    }
}
