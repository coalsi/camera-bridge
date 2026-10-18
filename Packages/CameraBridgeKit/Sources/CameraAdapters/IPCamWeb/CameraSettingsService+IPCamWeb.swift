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
    /// (`IPCamWebClient.showsItsPage()`), signed in unless `signingIn` is false (`ipcamSignInRefusal`). A camera of the family whose API
    /// cannot be asked now (it refuses or refused Camera Bridge's sign-in, or there are no credentials) is `.unavailable` with why. A web
    /// page that does not answer is taken as no such API for this service's life (a setup run, a check): it is not asked again by every
    /// step. Throws `CancellationError` only.
    func ipcamWeb(signingIn: Bool = true) async throws -> IPCamWebAccess {
        guard vendor == .onvif else { return .none }
        let client = ipcamWebClient ?? IPCamWebClient(endpoint: endpoint, credentials: credentials, cameraID: cameraID)
        ipcamWebClient = client
        if await client.unanswered, !IPCamWebLatch.shared.isFamily(IPCamWebLatch.key(endpoint)) { return .none }
        do {
            guard try await client.showsItsPage() else { return .none }
        } catch is IPCamWebNoAnswer {
            return .none
        }
        if let refusal = IPCamWebLatch.shared.refusal(IPCamWebLatch.key(endpoint)) { return .unavailable(refusal) }
        guard credentials != nil else { return .unavailable(IPCamWebUnavailable.noCredentials) }
        if signingIn, let why = try await ipcamSignInRefusal(client) { return .unavailable(why) }
        return .speaks(client)
    }

    /// Signs `client` in (once for its life): nil when it is, or why its API can't be asked now. Asked before a step reads anything, so a
    /// sign-in the camera refuses is every step's reason, as one it refused earlier is (a want of privilege said as such:
    /// `IPCamWebLatch.refusal`), and the setup goes on with the steps that don't need this API (a login refusal would end it, though this
    /// one stops only this API). A sign-in the camera does not answer (a 5xx, a transport failure: no refusal, so the next step tries again)
    /// is this step's reason too, so the step's own call does not sign in again at once; a camera that is silent marks the security check
    /// unanswered (`remoteAccessUnanswered`). Paused logins are left to the step's own call, which meets the pause and sends nothing. A
    /// sign-in refused for want of privilege is `IPCamWebUnavailable.noPrivilege` (`notPermitted`: the steps it stops are changes the account
    /// may not make). Throws `CancellationError` only.
    func ipcamSignInRefusal(_ client: IPCamWebClient) async throws -> IPCamWebUnavailable? {
        do {
            try await client.signIn()
        } catch is CancellationError {
            throw CancellationError()
        } catch let unavailable as IPCamWebUnavailable {
            return unavailable
        } catch {
            if let refusal = IPCamWebLatch.shared.refusal(IPCamWebLatch.key(endpoint)) { return refusal }
            if let paused = error as? CameraAdapterError, paused.isLoginRefusal { return nil }
            if Self.cameraSilent(error) { remoteAccessUnanswered = true }
            return IPCamWebUnavailable(reason: Self.ipcamSignInUnanswered(error))
        }
        return nil
    }

    /// Why this API can't be asked when its sign-in got no answer: "the camera’s web page did not answer Camera Bridge’s sign-in (HTTP 503)".
    static func ipcamSignInUnanswered(_ error: any Error) -> String {
        let words = "the camera’s web page did not answer Camera Bridge’s sign-in"
        if case CameraAdapterError.httpStatus(let status) = error { return "\(words) (HTTP \(status))" }
        return words
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
        do {
            try await client.write("mobile", element: "<mobile on='\(enabled ? 1 : 0)'></mobile>")
        } catch CameraAdapterError.notPermitted {
            return .notPermittedRefusal
        }
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
        switch try await ipcamWeb(signingIn: false) {
        case .none: return (.notOffered(), nil)
        case .unavailable(let why): return (.notSupported(why.reason), nil)
        case .speaks(let speaks): client = speaks
        }
        guard client.hasPassword else { return (.notOffered(Self.ipcamNoPassword), nil) }
        if let why = try await ipcamSignInRefusal(client) { return (.notSupported(why.reason), nil) }
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
        switch try await ipcamWeb(signingIn: false) {
        case .none: return .refused(CameraSetupReading.notOffered().reasonText)
        case .unavailable(let why): return .refused(why)
        case .speaks(let speaks): client = speaks
        }
        guard client.hasPassword else { return .refused(Self.ipcamNoPassword) }
        if let why = try await ipcamSignInRefusal(client) { return .refused(why) }
        for (what, _, _) in Self.ipcamVideoServices {
            guard let element = try await ipcamOption(what, client), let authorized = IPCWebXML.attribute("authorized", of: element), authorized != "1" else { continue }
            guard let taken = try await writeSwitches(["authorized": "1"], of: what, element: element, client: client) else { return .notPermittedRefusal }
            guard taken else { return .refused("the camera kept its video open without a password") }
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
        case .unavailable(let why): return (.notSupported(why.reason), nil)
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
            guard let taken = try await writeSwitches(["on": "0"], of: what, element: element, client: client) else { return .notPermittedRefusal }
            guard taken else { return .refused("the camera kept the \(name) on") }
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
            guard let taken = try await writeSwitches(values, of: what, element: element, client: client) else { return .notPermittedRefusal }
            guard taken else { return .refused("the camera did not take its old settings back") }
        }
        return CameraSetupOutcome(succeeded: true, detail: "via web API")
    }

    /// `element` written back with only `values` changed, then read back: whether the camera took them; nil when the camera answered that
    /// the account may not change it (532374 at the write: `CameraAdapterError.notPermitted`), the step's typed refusal.
    private func writeSwitches(_ values: [String: String], of what: String, element: String, client: IPCamWebClient) async throws -> Bool? {
        guard let edited = IPCWebXML.replacingAttributes(values, in: element) else { return false }
        do {
            try await client.write(what, element: edited)
        } catch CameraAdapterError.notPermitted {
            return nil
        }
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
    /// A camera of the family whose API cannot be asked now, with why (`IPCamWebUnavailable.notPermitted`: the account may not use it).
    case unavailable(IPCamWebUnavailable)
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

// MARK: - DNS (the internet guard's Watch)

/// The family's own network settings for "Watch its internet" (`CameraSettingsService+DNS.swift`), used after ONVIF when ONVIF's `SetDNS`
/// left a server that is not the bridge, or was refused. `GET /cgi/network.cgi?get=eth` answers the interface, `<eth ondhcp ip submask
/// gateway ip6 submask6 gateway6 dhcp_mode dhcp_fixed_time hostname>` with `<dns ondhcp dns1 dns2/>` (the page's preferred and alternative
/// DNS servers; `ondhcp` 1: from DHCP), and `set=eth` takes the interface back whole, its address included: the write is the element exactly
/// as the camera's page writes it (`network.js`), every value as read and only `dns` changed, and an answer the page would write otherwise is
/// refused instead. The camera then restarts its network service (and forgets its session), so it is read back for a while. ONVIF goes first
/// because `SetDNS` touches only the DNS and needs no web sign-in. The answer holds the camera's addresses and host name: it is never logged
/// or kept; only `dns`'s three values are (`CameraDNSBackup.ownAPI`).
extension CameraSettingsService {
    /// The page's `set=eth` attributes in the order it writes them: the interface's, then its `dns` child's.
    static let ipcamEthAttributes = ["ondhcp", "ip", "submask", "gateway", "ip6", "submask6", "gateway6", "dhcp_mode", "dhcp_fixed_time", "hostname"]
    static let ipcamDNSAttributes = ["ondhcp", "dns1", "dns2"]
    /// What the page sends as the camera answered it: an address, a number, a host name.
    private static let ipcamPlainCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

    /// The camera's `get=eth` answer and its `dns` values; nil when the camera has no `eth` option (532229) or no `dns` with those three.
    func ipcamWebDNS(_ client: IPCamWebClient) async throws -> (answer: String, dns: [String: String])? {
        guard let answer = try await client.read("eth"), let dns = Self.ipcamDNS(in: answer) else { return nil }
        return (answer, dns)
    }

    static func ipcamDNS(in answer: String) -> [String: String]? {
        guard let element = IPCWebXML.element("dns", in: answer) else { return nil }
        var values: [String: String] = [:]
        for name in ipcamDNSAttributes {
            guard let value = IPCWebXML.attribute(name, of: element) else { return nil }
            values[name] = value.trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// `set=eth`'s element as the camera's page writes it: the answer's `eth` attributes as the camera gave them, in the page's order, then
    /// `dns` with `dns`'s values. nil when anything else would differ from the answer: an attribute the page does not write, or one it writes
    /// that the answer lacks (each once); a child other than `dns`; a value with a character an address, a number or a host name does not
    /// have (the page encodes the host name and sends the rest as they are, so only such values go back unchanged).
    static func ipcamEthWrite(_ answer: String, dns: [String: String]) -> String? {
        guard let eth = IPCWebXML.element("eth", in: answer).map({ String($0) }),
              let child = IPCWebXML.element("dns", in: answer).map({ String($0) }) else { return nil }
        let attributes = IPCWebXML.attributes(of: eth), childAttributes = IPCWebXML.attributes(of: child)
        guard attributes.count == ipcamEthAttributes.count, Set(attributes.map(\.name)) == Set(ipcamEthAttributes),
              childAttributes.count == ipcamDNSAttributes.count, Set(childAttributes.map(\.name)) == Set(ipcamDNSAttributes),
              Set(dns.keys) == Set(ipcamDNSAttributes), let last = attributes.last,
              let open = eth[eth.index(after: last.value.upperBound)...].firstIndex(of: ">") else { return nil }
        // The interface holds its `dns` and nothing else (or nothing: the answer has `dns` beside it).
        if eth[..<open].last != "/", let close = eth.range(of: "</", options: .backwards), open < close.lowerBound {
            let inner = eth[eth.index(after: open)..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard inner.isEmpty || inner == child else { return nil }
        }
        var values: [String: String] = [:]
        for attribute in attributes { values[attribute.name] = String(eth[attribute.value]) }
        guard values.allSatisfy({ ipcamWritesAsIs($0.value, hostName: $0.key == "hostname") }),
              dns.values.allSatisfy({ ipcamWritesAsIs($0, hostName: false) }) else { return nil }
        let interface = ipcamEthAttributes.map { "\($0)='\(values[$0, default: ""])'" }.joined(separator: " ")
        let servers = ipcamDNSAttributes.map { "\($0)='\(dns[$0, default: ""])'" }.joined(separator: " ")
        return "<eth \(interface) ><dns \(servers) /></eth>"
    }

    /// Letters, digits and `.-_`, and `:` outside the host name (IPv6 addresses).
    private static func ipcamWritesAsIs(_ value: String, hostName: Bool) -> Bool {
        value.unicodeScalars.allSatisfy { ipcamPlainCharacters.contains($0) || (!hostName && $0 == ":") }
    }

    /// Points the family's DNS at the bridge through its page when ONVIF could not: `dns` `ondhcp` 0 with the bridge in both slots, then read
    /// back while the camera restarts its network service, through ONVIF too (the guard's own read). `failed` is ONVIF's outcome: a camera
    /// not of the family keeps it, and when the page cannot be used its words stand with why.
    func setIPCamWebDNS(server: String, onvif: ONVIFClient, failed: CameraSetupOutcome, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome {
        let web: IPCamWebClient
        switch try await ipcamWeb() {
        case .none: return failed
        case .unavailable(let why):
            return CameraSetupOutcome(succeeded: false, detail: "\(failed.detail); the camera’s web API cannot be asked: \(why.reason)", notPermitted: why.notPermitted)
        case .speaks(let client): web = client
        }
        let page = "\(failed.detail); the camera’s web API"
        guard ONVIFClient.isIPv4(server) else { return .refused("\(page) takes an IPv4 address only") }
        let wanted = ["ondhcp": "0", "dns1": server, "dns2": server]
        do {
            guard let read = try await ipcamWebDNS(web) else { return .refused("\(page) shows no DNS servers") }
            if !Self.sameOwnDNS(read.dns, wanted) {
                guard let element = Self.ipcamEthWrite(read.answer, dns: wanted) else {
                    return .refused("\(page) holds network settings it would not get back exactly, so Camera Bridge left them as they are")
                }
                if let refusal = try await writeIPCamEth(element, web) {
                    return CameraSetupOutcome(succeeded: false, detail: "\(page) \(refusal.words)", notPermitted: refusal.notPermitted)
                }
            }
        } catch let error as IPCamWebUnavailable {
            return CameraSetupOutcome(succeeded: false, detail: "\(page) cannot be asked: \(error.reason)", notPermitted: error.notPermitted)
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            return .refused("\(page) cannot be asked: it refused Camera Bridge’s sign-in")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .refused("\(page) did not answer")
        }
        var lastONVIF: CameraDNSReading?
        var lastPage: [String: String]?
        let done: Bool
        do {
            done = try await readBackAfterRestart(readBack) {
                var now: CameraDNSReading?
                if let dns = try await self.onvifDNS(onvif) { now = Self.onvifReading(dns) }
                if let now { lastONVIF = now }
                guard let values = try await self.ipcamWebDNS(web)?.dns else { return false }
                lastPage = values
                return Self.sameOwnDNS(values, wanted) && now?.pointsAt(server) != false
            }
        } catch let error as IPCamWebUnavailable {
            return .refused("the camera was sent the change through its web API, but could not be asked again: \(error.reason)")
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            return .refused("the camera was sent the change through its web API, but refused Camera Bridge’s login before it was read back")
        }
        if done {
            log.info("Set the camera's DNS servers through its IPCamera Web API")
            return CameraSetupOutcome(succeeded: true, detail: "via web API")
        }
        let last = lastONVIF ?? lastPage.map { Self.ownReading($0, dhcpKey: "ondhcp", method: .onvifMinimal) }
        return .refused(Self.keptAfterRestart(last, server: server))
    }

    /// Writes the family's `dns` back as the backup has it through its page, read back while the camera restarts its network service; nil when
    /// the page cannot be used now (not of the family, its API cannot be asked or does not answer, it refuses Camera Bridge's sign-in now, no
    /// `dns`, an interface the page would write otherwise): Restore then goes through ONVIF, whose logins the family's refusal does not pause.
    /// Throws a cancellation only.
    func restoreIPCamWebDNS(_ saved: [String: String], readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome? {
        guard Set(saved.keys) == Set(Self.ipcamDNSAttributes), case .speaks(let web) = try await ipcamWeb() else { return nil }
        let read: (answer: String, dns: [String: String])
        do {
            guard let answer = try await ipcamWebDNS(web) else { return nil }
            read = answer
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.info("The camera's web API cannot be asked now; its DNS servers go back through ONVIF")
            return nil
        }
        if !Self.sameOwnDNS(read.dns, saved) {
            guard let element = Self.ipcamEthWrite(read.answer, dns: saved) else { return nil }
            let done: Bool
            do {
                guard try await writeIPCamEth(element, web) == nil else { return nil }
                done = try await readBackAfterRestart(readBack) {
                    guard let values = try await self.ipcamWebDNS(web)?.dns else { return false }
                    return Self.sameOwnDNS(values, saved)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
            guard done else { return .refused(Self.notTakenBack) }
        }
        log.info("Set the camera's DNS servers through its IPCamera Web API")
        return CameraSetupOutcome(succeeded: true, detail: "via web API")
    }

    /// `set=eth`; the refusal's words when the camera answered one, and whether it was the account's want of privilege (`notPermitted`). No
    /// answer is not a refusal: the camera may restart its network service before it answers, and the read-back tells. A login refusal is
    /// thrown.
    private func writeIPCamEth(_ element: String, _ web: IPCamWebClient) async throws -> (words: String, notPermitted: Bool)? {
        do {
            try await web.write("eth", element: element)
        } catch CameraAdapterError.notPermitted {
            return ("refused the change (\(CameraAdapterError.notPermittedReason))", true)
        } catch let error as IPCamWebCameraError {
            return ("refused the change (\(error))", false)
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            throw error
        } catch let error as IPCamWebUnavailable {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.debug("The camera did not answer the DNS change through its web API (it may be restarting its network)")
        }
        return nil
    }
}
