import BridgeSupport
import Foundation

/// "Set up for Camera Bridge" and the security check on an ONVIF camera of the IPCamera Web family (`CameraSettingsService.ipcamWeb()`):
/// Cloud off (the `mobile` option, the cloud of the maker's VisionEye app), Video password (`rtsp` and `onvif` `authorized` 1: the bridge
/// already sends the camera's credentials when its RTSP asks for them, so the step is offered only when Camera Bridge has a password for the
/// camera) and Extra services off (`hik` and `meari` `on` 0). Each write sends the element as the camera answered it with only the switch
/// changed (the cloud: as the camera's page writes it), and is read back. The `mobile` and `ddns` answers also hold the camera's cloud id
/// and its DDNS account: only the switches are looked at, nothing of an answer is logged or kept.
extension CameraSettingsService {
    static let ipcamCloudLabel = "The maker’s cloud (VisionEye app)"
    /// The services the video password locks: option, change row's label, how it is now.
    static let ipcamVideoServices = [("rtsp", "Video stream (RTSP)", "plays without a password"), ("onvif", "ONVIF", "answers without a password")]
    /// The extra services: option and name.
    static let ipcamExtraServices = [("hik", "Hikvision protocol"), ("meari", "Meari service")]
    static let ipcamNoPassword = "Camera Bridge has no password saved for this camera, so its video can’t be locked with one"

    /// The camera's IPCamera Web API, when it is an ONVIF camera whose web page (loaded without credentials) is the family's
    /// (`IPCamWebClient.showsItsPage()`). A camera of the family whose API cannot be asked now (it refused Camera Bridge's sign-in, or there
    /// are no credentials) is `.unavailable` with why. A web page that does not answer is taken as no such API for this service's life (a
    /// setup run, a check): it is not asked again by every step. Throws `CancellationError` only.
    func ipcamWeb() async throws -> IPCamWebAccess {
        guard vendor == .onvif else { return .none }
        let client = ipcamWebClient ?? IPCamWebClient(endpoint: endpoint, credentials: credentials, cameraID: cameraID)
        ipcamWebClient = client
        if await client.unanswered, !IPCamWebLatch.shared.isFamily(IPCamWebLatch.key(endpoint)) { return .none }
        do {
            guard try await client.showsItsPage() else { return .none }
        } catch is IPCamWebNoAnswer {
            return .none
        }
        if IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(endpoint)) { return .unavailable(IPCamWebUnavailable.paused.reason) }
        guard credentials != nil else { return .unavailable(IPCamWebUnavailable.noCredentials.reason) }
        return .speaks(client)
    }

    /// The option's element as the camera answered it; nil when the camera has no such option (532229).
    func ipcamOption(_ what: String, _ client: IPCamWebClient) async throws -> String? {
        guard let answer = try await client.read(what) else { return nil }
        guard let element = IPCWebXML.element(what, in: answer) else { throw CameraAdapterError.invalidResponse("\(what): not in the answer") }
        return String(element)
    }

    // MARK: The maker's cloud

    func readIPCamWebCloud(_ client: IPCamWebClient) async throws -> (CameraSetupReading, CameraFeatureBackup?) {
        guard let mobile = try await ipcamOption("mobile", client), let on = IPCWebXML.attribute("on", of: mobile) else { return (.notSupported(), nil) }
        let backup = CameraFeatureBackup(path: "mobile", enabled: on != "0")
        guard on != "0" else { return (CameraSetupReading(state: .alreadyRight), backup) }
        return (CameraSetupReading(state: .willChange, changes: [.init(label: Self.ipcamCloudLabel, now: "on", after: "off")]), backup)
    }

    /// `set=mobile` with `<mobile on='0|1'></mobile>`, as the camera's page writes it, then read back.
    func setIPCamWebCloud(enabled: Bool, client: IPCamWebClient) async throws -> CameraSetupOutcome {
        guard let mobile = try await ipcamOption("mobile", client), let on = IPCWebXML.attribute("on", of: mobile) else {
            return .refused("the camera no longer shows this setting")
        }
        if (on != "0") == enabled { return CameraSetupOutcome(succeeded: true, detail: "already \(enabled ? "on" : "off")") }
        try await client.write("mobile", element: "<mobile on='\(enabled ? 1 : 0)'></mobile>")
        guard let after = try await ipcamOption("mobile", client), let now = IPCWebXML.attribute("on", of: after), (now != "0") == enabled else {
            return .refused("the camera kept it \(enabled ? "off" : "on")")
        }
        log.info("Turned the maker's cloud \(enabled ? "on" : "off") through the camera's IPCamera Web API")
        return CameraSetupOutcome(succeeded: true, detail: "via web API")
    }

    /// The family's cameras have no UPnP (the option is answered "no option"); one that has it shows a switch Camera Bridge has no way to change.
    func readIPCamWebUPnP(_ client: IPCamWebClient) async throws -> (CameraSetupReading, CameraFeatureBackup?) {
        guard let upnp = try await ipcamOption("upnp", client) else { return (.notSupported(), nil) }
        if IPCWebXML.attribute("on", of: upnp) == "0" { return (CameraSetupReading(state: .alreadyRight), nil) }
        return (.notSupported(CameraNetworkFeature.upnp.cannotChange), nil)
    }

    // MARK: Video password

    /// Whether the camera's RTSP and ONVIF ask for its password; the backup holds their `authorized` as they are. Not offered on other
    /// cameras, nor without a password saved for the camera.
    public func readVideoPassword() async throws -> (CameraSetupReading, CameraServiceSwitchesBackup?) {
        let client: IPCamWebClient
        switch try await ipcamWeb() {
        case .none: return (.notOffered(), nil)
        case .unavailable(let why): return (.notSupported(why), nil)
        case .speaks(let speaks): client = speaks
        }
        guard client.hasPassword else { return (.notOffered(Self.ipcamNoPassword), nil) }
        var services: [String: [String: String]] = [:]
        var changes: [CameraSetupChange] = []
        for (what, label, now) in Self.ipcamVideoServices {
            guard let element = try await ipcamOption(what, client), let authorized = IPCWebXML.attribute("authorized", of: element) else { continue }
            services[what] = ["authorized": authorized]
            if authorized != "1" { changes.append(.init(label: label, now: now, after: "needs the camera’s password")) }
        }
        guard !services.isEmpty else { return (.notSupported(), nil) }
        let backup = CameraServiceSwitchesBackup(services: services)
        return (changes.isEmpty ? CameraSetupReading(state: .alreadyRight) : CameraSetupReading(state: .willChange, changes: changes), backup)
    }

    /// `authorized` 1 on the camera's RTSP and ONVIF, each read back.
    public func requireVideoPassword() async throws -> CameraSetupOutcome {
        let client: IPCamWebClient
        switch try await ipcamWeb() {
        case .none: return .refused(CameraSetupReading.notOffered().reasonText)
        case .unavailable(let why): return .refused(why)
        case .speaks(let speaks): client = speaks
        }
        guard client.hasPassword else { return .refused(Self.ipcamNoPassword) }
        for (what, _, _) in Self.ipcamVideoServices {
            guard let element = try await ipcamOption(what, client), let authorized = IPCWebXML.attribute("authorized", of: element), authorized != "1" else { continue }
            guard try await writeSwitches(["authorized": "1"], of: what, element: element, client: client) else {
                return .refused("the camera kept its video open without a password")
            }
        }
        log.info("The camera's video now needs its password (through its IPCamera Web API)")
        return CameraSetupOutcome(succeeded: true, detail: "via web API")
    }

    // MARK: Extra services

    /// Which of the camera's other services are on (a Hikvision-compatible protocol, the Meari service); the backup holds their switches.
    public func readExtraServices() async throws -> (CameraSetupReading, CameraServiceSwitchesBackup?) {
        let client: IPCamWebClient
        switch try await ipcamWeb() {
        case .none: return (.notOffered(), nil)
        case .unavailable(let why): return (.notSupported(why), nil)
        case .speaks(let speaks): client = speaks
        }
        var services: [String: [String: String]] = [:]
        var changes: [CameraSetupChange] = []
        for (what, name) in Self.ipcamExtraServices {
            guard let element = try await ipcamOption(what, client), let on = IPCWebXML.attribute("on", of: element) else { continue }
            services[what] = ["on": on]
            if on != "0" { changes.append(.init(label: Self.serviceName(name, element), now: "on", after: "off")) }
        }
        guard !services.isEmpty else { return (.notSupported(), nil) }
        let backup = CameraServiceSwitchesBackup(services: services)
        return (changes.isEmpty ? CameraSetupReading(state: .alreadyRight) : CameraSetupReading(state: .willChange, changes: changes), backup)
    }

    /// `on` 0 on every extra service that is on, each read back.
    public func turnOffExtraServices() async throws -> CameraSetupOutcome {
        let client: IPCamWebClient
        switch try await ipcamWeb() {
        case .none: return .refused(CameraSetupReading.notOffered().reasonText)
        case .unavailable(let why): return .refused(why)
        case .speaks(let speaks): client = speaks
        }
        for (what, name) in Self.ipcamExtraServices {
            guard let element = try await ipcamOption(what, client), let on = IPCWebXML.attribute("on", of: element), on != "0" else { continue }
            guard try await writeSwitches(["on": "0"], of: what, element: element, client: client) else { return .refused("the camera kept the \(name) on") }
        }
        log.info("Turned the camera's extra services off through its IPCamera Web API")
        return CameraSetupOutcome(succeeded: true, detail: "via web API")
    }

    /// Writes back the switches the video password or the extra services step saved, each read back.
    public func restoreServiceSwitches(_ backup: CameraServiceSwitchesBackup) async throws -> CameraSetupOutcome {
        let client: IPCamWebClient
        switch try await ipcamWeb() {
        case .none: return .refused("the camera no longer shows these settings")
        case .unavailable(let why): return .refused(why)
        case .speaks(let speaks): client = speaks
        }
        for (what, values) in backup.services.sorted(by: { $0.key < $1.key }) {
            guard let element = try await ipcamOption(what, client) else { return .refused("the camera no longer shows these settings") }
            guard values.contains(where: { IPCWebXML.attribute($0.key, of: element) != $0.value }) else { continue }
            guard try await writeSwitches(values, of: what, element: element, client: client) else {
                return .refused("the camera did not take its old settings back")
            }
        }
        return CameraSetupOutcome(succeeded: true, detail: "via web API")
    }

    /// `element` written back with only `values` changed, then read back: whether the camera took them.
    private func writeSwitches(_ values: [String: String], of what: String, element: String, client: IPCamWebClient) async throws -> Bool {
        guard let edited = IPCWebXML.replacingAttributes(values, in: element) else { return false }
        try await client.write(what, element: edited)
        guard let after = try await ipcamOption(what, client) else { return false }
        return values.allSatisfy { IPCWebXML.attribute($0.key, of: after) == $0.value }
    }

    /// "Meari service (port 10000)".
    static func serviceName(_ name: String, _ element: String) -> String {
        IPCWebXML.attribute("port", of: element).map { "\(name) (port \($0))" } ?? name
    }

    // MARK: The security check

    /// What the camera's API shows about its ways out. An option the camera answers "no option" is absent; one that cannot be read is
    /// unknown (after a refused sign-in nothing more is sent, so everything left is unknown).
    func ipcamWebRemoteAccess(_ client: IPCamWebClient) async throws -> [RemoteAccessFinding] {
        var stopped = false
        /// The options, read one after the other: the element, `.some(nil)` for an option the camera lacks, nil for one not read.
        var options: [String: String?] = [:]
        for what in ["mobile", "cloud", "p2p", "platform", "upnp", "ddns", "rtmp"] + Self.ipcamExtraServices.map(\.0) + Self.ipcamVideoServices.map(\.0) {
            if let element = try await attempt(&stopped, { try await ipcamOption(what, client) }) { options[what] = element }
        }
        func state(_ what: String, _ attribute: String = "on") -> RemoteAccessState {
            guard let read = options[what] else { return .unknown }
            guard let element = read else { return .absent }
            switch IPCWebXML.attribute(attribute, of: element) {
            case "1": return .on
            case "0": return .off
            default: return .unknown
            }
        }
        var findings: [RemoteAccessFinding] = []
        for (what, service, changeable) in [("mobile", "VisionEye cloud", true), ("cloud", "cloud service", false), ("p2p", "P2P service", false),
                                            ("platform", "platform service", false)] {
            let read = state(what)
            findings.append(RemoteAccessFinding(feature: .cloud, state: read, service: service, canChange: changeable && (read == .on || read == .off)))
        }
        for (what, feature) in [("upnp", RemoteAccessFeature.upnp), ("ddns", .ddns), ("rtmp", .rtmp)] {
            findings.append(RemoteAccessFinding(feature: feature, state: state(what)))
        }
        for (what, name) in Self.ipcamExtraServices {
            let read = state(what)
            let service = (options[what] ?? nil).map { Self.serviceName(name, $0) } ?? name
            findings.append(RemoteAccessFinding(feature: .extraService, state: read, service: service, canChange: read == .on || read == .off))
            // On and asking no password (`authorized` 0): anyone at home can connect to it, whatever RTSP and ONVIF ask.
            if read == .on, state(what, "authorized") == .off {
                findings.append(RemoteAccessFinding(feature: .unauthenticatedVideo, state: .on, service: service, canChange: true))
            }
        }
        // The video: open when either service answers without the password (`authorized` 0, which `state` reads as off: the password is not
        // asked for), closed when every service it has asks for it.
        let present = Self.ipcamVideoServices.map { state($0.0, "authorized") }.filter { $0 != .absent }
        let open: RemoteAccessState = present.contains(.off) ? .on : present.isEmpty ? .absent : present.allSatisfy({ $0 == .on }) ? .off : .unknown
        findings.append(RemoteAccessFinding(feature: .unauthenticatedVideo, state: open, canChange: client.hasPassword && (open == .on || open == .off)))
        return findings
    }
}

/// What `CameraSettingsService.ipcamWeb()` found.
enum IPCamWebAccess: Sendable {
    /// Not an ONVIF camera of the family: its steps are not offered, its readings come from elsewhere.
    case none
    case speaks(IPCamWebClient)
    /// A camera of the family whose API cannot be asked now, with why.
    case unavailable(String)
}

extension CameraSetupReading {
    /// The reason of a step that is not supported or not offered ("" otherwise).
    var reasonText: String {
        switch state {
        case .notSupported(let why), .notOffered(let why): why
        case .willChange, .alreadyRight: ""
        }
    }
}
