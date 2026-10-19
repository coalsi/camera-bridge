import BridgeSupport
import CameraAdapters
import Foundation

// "Change it by hand" (owner decisions, 2026-10-18): for a step of Set up for Camera Bridge that the camera refused or does not support, and
// for a finding of the Security card the setup can't change (the Internet guard's "not watched" among them): one plain sentence of why
// (from the step's own words where it has some), where to change it by hand (the menus of the camera's family where they are confirmed),
// what to set (the bridge's own address for the DNS and the time), and for Watch, UPnP and the cloud the router's way too. Every word is
// in one table, `CameraManualHelpText`, like `InternetGuardText`. A menu path counts as confirmed only when it was read on the camera's own
// pages or in its maker's documents; anything else is a general instruction, and the help then says "Menu names differ between models"
// (`CameraManualHelp.caveat`). Worked out when a report or a status goes to the web page (BridgeWeb's `EngineBackend`), never saved.
// Pointing the DNS at Camera Bridge by hand (docs/superpowers/specs/2026-10-18-camera-dns-design.md, "What the person sees" 1; the menus
// from the research's §4, .superpowers/sdd/camera-dns-research.md) also links the camera's own page, says what the camera asks now, marks
// the addresses to type for copying, says to keep and reserve the camera's address where its DNS stays only with a fixed one, and warns
// of what lets a camera around the guard.

/// The kinds of camera whose menus the help knows.
public enum CameraFamily: String, Sendable, Codable, CaseIterable {
    /// Hikvision and the cameras it makes for others (Annke).
    case hikvision
    case reolink
    /// TP-Link Tapo (changed in the Tapo app).
    case tapo
    /// The IP camera web API: Jennov and other Anjvision cameras ("IP Camera Web Login").
    case ipcWebAPI
    /// The IPCamera Web family (its page is titled "IPCamera Web").
    case ipcamWeb
    /// Dahua, Amcrest and Lorex.
    case dahua
    case axis
    /// Hanwha Vision (Wisenet).
    case hanwha
    case uniview
    case foscam
    /// TP-Link VIGI.
    case vigi
    /// Xiongmai's XMEye / NetSurveillance cameras.
    case xmeye
    /// A UniFi camera on its own (not adopted by UniFi Protect).
    case unifi
    /// Any other ONVIF camera.
    case onvif

    /// The makers an ONVIF camera names (its manufacturer, any case, anywhere in it; VIGI in its model too, as TP-Link names itself), in
    /// the order they are tried.
    static let makers: [(family: CameraFamily, names: [String])] = [
        (.hikvision, ["hikvision", "annke"]), (.reolink, ["reolink"]), (.dahua, ["dahua", "amcrest", "lorex"]), (.axis, ["axis"]),
        (.hanwha, ["hanwha", "wisenet"]), (.uniview, ["uniview"]), (.foscam, ["foscam"]), (.vigi, ["vigi"]), (.xmeye, ["xiongmai"]),
        (.unifi, ["ubiquiti"]),
    ]

    /// The family of `camera`: its vendor, then the web API its address showed in this run (`webAPI`, CameraAdapters'
    /// `CameraWebAPIFamily.seen(at:)`), then its maker and model (a Tapo, then `makers`), then what an earlier setup kept of one of the two
    /// web API families; else a plain ONVIF camera.
    public static func of(_ camera: CameraConfiguration, webAPI: CameraWebAPIFamily?) -> CameraFamily {
        switch camera.vendor {
        case .hikvision: return .hikvision
        case .reolink: return .reolink
        case .amcrest: return .dahua
        default: break
        }
        switch webAPI {
        case .ipcWebAPI: return .ipcWebAPI
        case .ipcamWeb: return .ipcamWeb
        case nil: break
        }
        if CloudDependentModels.brand(of: camera) == "TP-Link Tapo" { return .tapo }
        let maker = camera.manufacturer.lowercased(), model = camera.model.lowercased()
        for (family, names) in makers where names.contains(where: { maker.contains($0) || (family == .vigi && model.contains($0)) }) { return family }
        // Only the IPCamera Web family has a video password, extra services and the `mobile` cloud; only the IP camera web API keeps the
        // cloud's kind and turns the picture's labels off through its web API.
        let backup = camera.setupBackup
        if backup?.videoPassword != nil || backup?.extraServices != nil || backup?.cloud?.path == "mobile" { return .ipcamWeb }
        if camera.setupState?.steps.contains(where: { ($0.id == .videoPassword || $0.id == .extraServices) && $0.status != .notOffered }) == true {
            return .ipcamWeb
        }
        if camera.cleanPictureBackup?.method == .ipcWebAPI || backup?.cleanPicture?.method == .ipcWebAPI || backup?.cloud?.cloudType != nil { return .ipcWebAPI }
        return .onvif
    }

    /// The camera's DNS set by hand stays only while its address is fixed (the research's §4 "Static first?" yes or probably, §5): the DNS
    /// help says to keep its address as it is and reserve it in the router.
    var dnsNeedsFixedAddress: Bool {
        switch self {
        case .hikvision, .foscam, .vigi, .tapo, .ipcWebAPI, .xmeye, .unifi: true
        case .reolink, .ipcamWeb, .dahua, .axis, .hanwha, .uniview, .onvif: false
        }
    }
}

/// What a person can do by hand where Camera Bridge could not: why, where, what to set, the router's way, and what then.
public struct CameraManualHelp: Sendable, Codable, Equatable {
    /// One place to change it: the app or page, its menu ("Configuration", "Network", "IP Address"; empty for a general instruction), what
    /// to do there, and whether that menu was confirmed on the camera's own pages or in its maker's documents.
    public struct Place: Sendable, Codable, Equatable {
        public var app: String
        public var path: [String]
        public var action: String
        public var confirmed: Bool

        public init(app: String, path: [String] = [], action: String, confirmed: Bool = false) {
            self.app = app
            self.path = path
            self.action = action
            self.confirmed = confirmed
        }
    }

    /// A value to set ("Preferred DNS server": "192.168.77.28"); `copy`: an address to type in, which the page offers to copy.
    public struct Value: Sendable, Codable, Equatable {
        public var label: String
        public var value: String
        public var copy: Bool

        public init(label: String, value: String, copy: Bool = false) {
            self.label = label
            self.value = value
            self.copy = copy
        }
    }

    /// A link to the camera's own web page ("Open the camera’s web page"): only ever the address and web port Camera Bridge is configured
    /// with (`CameraManualHelpText.webPageURL`), never anything the camera says.
    public struct Link: Sendable, Codable, Equatable {
        public var label: String
        public var url: String

        public init(label: String, url: String) {
            self.label = label
            self.url = url
        }
    }

    /// The camera's address to keep as it is while fixing it: the address, and its mask and gateway where the camera showed them.
    public struct Keep: Sendable, Codable, Equatable {
        public var address: String
        public var mask: String?
        public var gateway: String?

        public init(address: String, mask: String?, gateway: String?) {
            self.address = address
            self.mask = mask
            self.gateway = gateway
        }
    }

    /// The router reservation for the camera's fixed address: the address, and its hardware (MAC) address where the camera showed it.
    public struct Reserve: Sendable, Codable, Equatable {
        public var address: String
        public var mac: String?

        public init(address: String, mac: String?) {
            self.address = address
            self.mac = mac
        }
    }

    /// One plain sentence: why Camera Bridge did not change it.
    public var why: String
    public var places: [Place]
    public var values: [Value]
    /// The router's way (Watch, UPnP, the cloud), one sentence.
    public var router: String?
    /// What else to know: what stops working, the models that lack it.
    public var note: String?
    /// What to do afterwards ("Then press Check again on the camera’s Security card.").
    public var then: String?
    /// `CameraManualHelpText.caveat` whenever a place is not confirmed; nil when every place is.
    public var caveat: String?
    /// The camera's own web page, where a place is that page; nil for a camera without one Camera Bridge knows of (a Tapo, a camera of an
    /// unknown maker).
    public var link: Link?
    /// The DNS help: the DNS servers the camera asks now, as last read ("Right now it asks A and B. Change both to C."); empty when not known,
    /// and in a setup report (its own change row says them).
    public var current: [String]
    /// The DNS help of a camera whose DNS stays only with a fixed address: its address to keep, and to reserve in the router.
    public var keep: Keep?
    public var reserve: Reserve?
    /// The DNS help: short warnings that apply (both slots the bridge, a restart, a recorder's ports).
    public var warnings: [String]

    /// `caveat` follows `places`.
    public init(why: String, places: [Place] = [], values: [Value] = [], router: String? = nil, note: String? = nil, then: String? = nil,
                link: Link? = nil, current: [String] = [], keep: Keep? = nil, reserve: Reserve? = nil, warnings: [String] = []) {
        self.why = why
        self.places = places
        self.values = values
        self.router = router
        self.note = note
        self.then = then
        caveat = places.contains { !$0.confirmed } ? CameraManualHelpText.caveat : nil
        self.link = link
        self.current = current
        self.keep = keep
        self.reserve = reserve
        self.warnings = warnings
    }
}

/// The help's words, one table: for each step of the setup and each camera family, why, where and what.
public enum CameraManualHelpText {
    /// The bridge's addresses and zone the help names, and what the engine knows of the camera for its DNS help.
    public struct Context: Sendable, Equatable {
        /// The bridge's address on the camera's network as its time server (Camera Bridge OS); nil where the bridge serves no time.
        public var timeServer: String?
        /// The bridge's address on the camera's network as its DNS server (the Internet guard); nil where there is no guard or no address there.
        public var guardServer: String?
        /// The bridge's time zone in words ("America/Phoenix (UTC−7:00)").
        public var timeZone: String?
        /// The camera is a doorbell (what turning its cloud off leaves working says so).
        public var doorbell: Bool
        /// The camera's own web page as Camera Bridge is configured to reach it (`webPageURL`); nil: none.
        public var webPage: String?
        /// The camera's IPv4 address as Camera Bridge reaches it (the guard's); nil when it is reached by name.
        public var cameraAddress: String?
        /// The DNS servers the camera asks now, as the engine last read them; empty: not read.
        public var currentDNS: [String]
        /// The camera's address whole as its last reading showed it (CameraAdapters' `CameraDNSReading.addressing`); nil: not shown.
        public var addressing: CameraAddressing?
        /// The camera has IPv6 on, as the engine's last security check read it (CameraAdapters' `CameraSettingsService.readIPv6()`, ONVIF's
        /// `GetNetworkInterfaces`); false: off, or not read.
        public var ipv6On: Bool

        public init(timeServer: String?, guardServer: String?, timeZone: String?, doorbell: Bool = false, webPage: String? = nil,
                    cameraAddress: String? = nil, currentDNS: [String] = [], addressing: CameraAddressing? = nil, ipv6On: Bool = false) {
            self.timeServer = timeServer
            self.guardServer = guardServer
            self.timeZone = timeZone
            self.doorbell = doorbell
            self.webPage = webPage
            self.cameraAddress = cameraAddress
            self.currentDNS = currentDNS
            self.addressing = addressing
            self.ipv6On = ipv6On
        }
    }

    public static let caveat = "Menu names differ between models and firmware versions, so look for the closest match."
    static let then = "Then press Check again on the camera’s Security card."

    static let webPage = "The camera’s web page"
    static let reolinkApp = "The Reolink app"
    static let reolinkClient = "The Reolink Client (on a computer)"
    static let tapoApp = "The Tapo app"
    /// The button that opens the camera's own web page.
    static let openWebPage = "Open the camera’s web page"

    static let accountWhy = "The account Camera Bridge signs in with may not change this setting: change it by hand, or sign Camera Bridge in with an "
        + "administrator account."
    static let tapoCloud = "Tapo cameras have no switch for TP-Link’s cloud that Camera Bridge knows of."
    /// Words of a refusal for want of rights (the camera's "No Privilege", or Camera Bridge's own sentence for a write the account may not make).
    static let accountWords = ["administrator", "may not change", "not permitted", "no privilege", "permission"]

    // The DNS help's warnings (research §5).
    /// A second server that is not the bridge, or an empty one, is a way around the guard.
    static let bothSlots = "Put Camera Bridge in both slots: with a public server, or none, as the second one, the camera can look names up without it."
    static let restartWarning = "If the camera asks to restart after you save, let it: it may keep its old DNS servers until then."
    static let recorderWarning = "If the camera is plugged into a recorder’s own ports, the recorder runs its network: set its DNS on the recorder instead."
    /// For a camera whose DNS stays only with a fixed address, when nothing is known of its address (the page then has no reservation line).
    static let reserveWarning = "Reserve the camera’s address in your router too, so nothing else takes it."
    static let tapoWarning = "Check every number before you save: a wrong fixed address on a Tapo can need a factory reset."
    /// A camera with IPv6 on can take DNS servers from the router's advertisements or DHCPv6, beside the IPv4 ones set by hand (research §5).
    static let ipv6Warning = "IPv6 is on: the camera may get DNS servers from your router over IPv6 too. Turn IPv6 off on the camera."

    // MARK: Steps

    /// The help for step `id` that ended `status` (only `notSupported` and `refused` have any) with `detail`, on a camera of `family`;
    /// `changes` are the step's planned values (the streams' "after"). nil for the DNS and the time without the bridge's address. The camera's
    /// own page is linked where a place is that page, for a maker Camera Bridge knows (`link`); the DNS help has its own parts (`dnsParts`).
    public static func step(_ id: CameraSetupStepID, status: CameraSetupStepStatus, detail: String?, family: CameraFamily, context: Context,
                            changes: [CameraSetupChange] = []) -> CameraManualHelp? {
        guard status == .notSupported || status == .refused else { return nil }
        let values: [CameraManualHelp.Value]
        switch id {
        case .timeSource:
            guard let server = context.timeServer else { return nil }
            values = [.init(label: "Time from", value: "NTP (a time server)"), .init(label: "NTP server", value: server, copy: true),
                      .init(label: "Port", value: "123")]
        case .internetWatch:
            guard let server = context.guardServer else { return nil }
            values = [.init(label: "DNS", value: "set by hand, not automatic"), .init(label: "Preferred DNS server", value: server, copy: true),
                      .init(label: "Alternate DNS server", value: server, copy: true)]
        default:
            values = Self.values(id, family: family, context: context, changes: changes)
        }
        let (places, note) = entry(id, family: family, doorbell: context.doorbell)
        var help = CameraManualHelp(why: why(id, status: status, detail: detail, family: family), places: places, values: values,
                                    router: router(id, server: context.guardServer, alone: places.isEmpty), note: note,
                                    then: id == .internetWatch ? then : nil, link: link(places, family: family, context: context))
        if id == .internetWatch { dnsParts(&help, family: family, context: context) }
        return help
    }

    /// The camera's own page (ruling D1: its configured address and web port only), where a place of the help is that page; none for a
    /// maker Camera Bridge does not know (its web port may be another service's, so the link could lead nowhere).
    static func link(_ places: [CameraManualHelp.Place], family: CameraFamily, context: Context) -> CameraManualHelp.Link? {
        guard family != .onvif, let page = context.webPage, places.contains(where: { $0.app == webPage }) else { return nil }
        return .init(label: openWebPage, url: page)
    }

    /// The DNS help's own parts: what the camera asks now, its address to keep and reserve where its DNS stays only with a fixed address
    /// (from its reading when that is of the address Camera Bridge reaches it at, else that address alone; nothing guessed), and the warnings
    /// that apply (IPv6 only when the camera was read with it on).
    static func dnsParts(_ help: inout CameraManualHelp, family: CameraFamily, context: Context) {
        help.current = context.currentDNS
        var warnings = [bothSlots]
        if context.ipv6On { warnings.append(ipv6Warning) }
        if family == .tapo { warnings.append(tapoWarning) }
        if family.dnsNeedsFixedAddress {
            let known = context.addressing.flatMap { context.cameraAddress == nil || $0.address == context.cameraAddress ? $0 : nil }
            if let address = known?.address ?? context.cameraAddress {
                help.keep = .init(address: address, mask: known?.subnetMask, gateway: known?.gateway)
                help.reserve = .init(address: address, mac: known?.hardwareAddress)
            } else {
                warnings.append(reserveWarning)
            }
        }
        if family != .foscam { warnings.append(restartWarning) }   // a Foscam restarts on its own (its note says so)
        if family != .tapo { warnings.append(recorderWarning) }
        help.warnings = warnings
    }

    /// `http://<host>[:<port>]/` (https where Camera Bridge reaches the camera so), the port left out when it is the scheme's own: the
    /// camera's configured address and web port, nothing else. nil for a host that is not a plain name or address (no path, user, query or
    /// anything but ASCII letters, digits, dots, hyphens and an IPv6 address's colons) or a port out of range.
    static func webPageURL(_ endpoint: CameraEndpoint) -> String? {
        var host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, host.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || ".-:".unicodeScalars.contains($0)) }),
              (1...65_535).contains(endpoint.httpPort) else { return nil }
        let scheme = endpoint.useHTTPS ? "https" : "http"
        let port = endpoint.httpPort == (endpoint.useHTTPS ? 443 : 80) ? "" : ":\(endpoint.httpPort)"
        let url = "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)\(port)/"
        guard let parts = URLComponents(string: url), parts.host?.isEmpty == false, parts.user == nil, parts.password == nil, parts.path == "/",
              parts.query == nil, parts.fragment == nil else { return nil }
        return url
    }

    /// `report` with each step's help (none on a step that was done, is right, or was not tried). Its Watch step says what the camera asks
    /// now in its own change row, so its help does not (`current`), and the address it read just now (an offer to fix it, or the one it
    /// fixed) is the one to keep.
    public static func withHelp(_ report: CameraSetupReport, family: CameraFamily, context: Context) -> CameraSetupReport {
        var helped = report
        var reported = context
        reported.currentDNS = []
        for index in helped.steps.indices {
            let step = helped.steps[index]
            var stepContext = reported
            if let addressing = step.fixAddress?.addressing ?? step.fixedAddress { stepContext.addressing = addressing }
            helped.steps[index].manualHelp = Self.step(step.id, status: step.status, detail: step.detail, family: family, context: stepContext,
                                                       changes: step.changes)
        }
        return helped
    }

    /// One sentence of why, from the step's own words where it has some.
    static func why(_ id: CameraSetupStepID, status: CameraSetupStepStatus, detail: String?, family: CameraFamily) -> String {
        if let said = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
            let lower = said.lowercased().replacingOccurrences(of: "'", with: "’")
            if accountWords.contains(where: lower.contains) { return accountWhy }
            if lower.contains("refused the login") { return "The camera refused Camera Bridge’s login when it tried to change this." }
            if lower.contains("locked its logins") || lower.contains("logs in again") || lower.contains("logins paused") {
                return "The camera’s logins were paused, so Camera Bridge didn’t try."
            }
            if lower.contains("did not answer") || lower.contains("didn’t answer") || lower.contains("stopped answering") {
                return "The camera didn’t answer when Camera Bridge tried."
            }
            if lower.contains("can’t change this camera’s") {
                return family == .tapo && id == .cloud ? tapoCloud : "Camera Bridge has no way to change this setting on this camera yet."
            }
            if lower != "not supported by this camera" && lower != "not offered for this camera" {
                let clause = said.hasSuffix(".") ? String(said.dropLast()) : said
                return status == .refused ? "The camera didn’t take the change: \(clause)." : "Camera Bridge can’t change this on this camera: \(clause)."
            }
        }
        if family == .tapo && id == .cloud { return tapoCloud }
        if family == .ipcamWeb && id == .upnp && status == .notSupported { return "This camera has no UPnP setting of its own." }
        return status == .refused ? "The camera didn’t take the change." : "This camera doesn’t let Camera Bridge change this setting."
    }

    /// What to set, for the steps whose values are not the bridge's addresses.
    static func values(_ id: CameraSetupStepID, family: CameraFamily, context: Context, changes: [CameraSetupChange]) -> [CameraManualHelp.Value] {
        switch id {
        case .timeZone:
            return context.timeZone.map { [.init(label: "Time zone", value: $0)] } ?? []
        case .cleanPicture:
            return [.init(label: "The camera’s own date, time and name on the picture", value: "off (the bridge draws its own)")]
        case .streams:
            guard changes.isEmpty else { return changes.map { .init(label: $0.label, value: $0.after) } }
            return [.init(label: "Main stream", value: "H.264, 15 to 25 fps, a keyframe every 2 seconds, 2 to 6 Mbit/s"),
                    .init(label: "Sub stream", value: "H.264, the same frame rate and keyframe interval, 360 to 720 lines high"),
                    .init(label: "Smart codec (H.264+ or H.265+)", value: "off")]
        case .upnp:
            return [.init(label: "UPnP", value: "off")]
        case .cloud:
            switch family {
            case .hikvision: return [.init(label: "Hik-Connect", value: "off")]
            case .reolink: return [.init(label: "UID (P2P)", value: "off")]
            case .ipcamWeb: return [.init(label: "Enable Mobile Monitoring", value: "off")]
            case .ipcWebAPI: return [.init(label: "Cloud (Enable)", value: "off")]
            case .tapo: return []
            case .dahua, .axis, .hanwha, .uniview, .foscam, .vigi, .xmeye, .unifi, .onvif: return [.init(label: "The maker’s cloud (P2P)", value: "off")]
            }
        case .videoPassword:
            return [.init(label: family == .ipcamWeb ? "Identity Authentication (RTSP and Onvif)" : "A password for its video (RTSP and ONVIF)", value: "on")]
        case .extraServices:
            return family == .ipcamWeb ? [.init(label: "HIK", value: "off"), .init(label: "MEARI", value: "off")]
                : [.init(label: "Services of other makers’ apps", value: "off")]
        case .timeSource, .internetWatch:
            return []
        }
    }

    /// The router's way: for Watch (its DNS from the router, or no internet at all), UPnP and the cloud; `alone` when the camera has no
    /// place of its own to change it (the router is then the way, not another one).
    static func router(_ id: CameraSetupStepID, server: String?, alone: Bool = false) -> String? {
        switch id {
        case .internetWatch:
            guard let server else { return nil }
            return "Or have your router hand this camera \(server) as its DNS server, with a DHCP reservation: OpenWrt, pfSense, OPNsense, MikroTik, "
                + "ASUS and Pi-hole can do that for one device; UniFi, Synology and Firewalla only for a whole network (such as a separate one for the "
                + "cameras); eero, Google/Nest Wifi, Deco and Orbi can’t, so change it on the camera. The router’s way works only while the camera "
                + "takes its DNS from DHCP (automatic), and only from the camera’s next DHCP renewal or restart. Or block the camera’s internet in your "
                + "router (see Keep this camera local). A DNS server from the router counts too, but it can change when the router renews the camera’s "
                + "address."
        case .upnp:
            return alone ? "Turn UPnP off on your router: then nothing at home can open ports to the internet."
                : "Turn UPnP off on your router too: then nothing at home can open ports to the internet."
        case .cloud:
            return alone ? "Block the camera’s internet in your router (see Keep this camera local)."
                : "Or block the camera’s internet in your router (see Keep this camera local)."
        default:
            return nil
        }
    }

    // MARK: Where

    typealias Place = CameraManualHelp.Place

    static func web(_ path: [String], _ action: String, confirmed: Bool = true) -> Place {
        Place(app: webPage, path: path, action: action, confirmed: confirmed)
    }

    static let dnsAction = "Set the DNS by hand (not automatic) and enter the DNS servers below."

    /// Where to change step `id` on a camera of `family`, and what else to know. Confirmed: the IPCamera Web family's own page (its
    /// language file and menu), the IP camera web API's page (its language file and menu script), TP-Link's FAQs 688 and 4372 (the Tapo
    /// app's network settings), Reolink's support articles (UPnP, UID), and for the DNS the makers' documents in the research's §4
    /// (Hikvision's manual 5.7.20, AXIS OS help, Hanwha's KB, Uniview's manual V3.00, Foscam FAQ 243, VIGI FAQ 4741). Best guesses carry the
    /// caveat: Reolink's DNS switch (its network pages are confirmed), Amcrest's and Lorex's cameras (Dahua's menu is confirmed, and the family
    /// is one), XMEye's and a standalone UniFi camera's menus. Everything else is a general instruction (`generalAction`), with the caveat:
    /// Hikvision's, Dahua's and Amcrest's other menus are only in other people's guides, the other makers' are not known, and the IP camera
    /// web API's OSD tab was not confirmed.
    static func entry(_ id: CameraSetupStepID, family: CameraFamily, doorbell: Bool = false) -> (places: [Place], note: String?) {
        switch (family, id) {
        // The IPCamera Web family: Configuration and its pages, in the page's own words.
        case (.ipcamWeb, .timeZone):
            return ([web(["Configuration", "Network", "Date & Time"], "Choose the Timezone below, and set Use DST as your time zone has it.")], nil)
        case (.ipcamWeb, .timeSource):
            return ([web(["Configuration", "Network", "Date & Time"], "Turn on Use NTP, then enter the NTP IP and the Port below.")], nil)
        case (.ipcamWeb, .cleanPicture):
            return ([web(["Configuration", "Media Setup", "OSD"], "Turn off Enable Title and Enable Time.")], nil)
        case (.ipcamWeb, .streams):
            return ([web(["Configuration", "Media Setup", "Video Setup"], "Set the Main Stream and the Sub Stream as below.")], nil)
        case (.ipcamWeb, .upnp):
            return ([], nil)   // the family has no UPnP setting of its own: the router's way
        case (.ipcamWeb, .cloud):
            return ([web(["Configuration", "Services Security", "P2P"], "Turn off Enable Mobile Monitoring.")],
                    "The maker’s VisionEye app then no longer reaches the camera away from home.")
        case (.ipcamWeb, .videoPassword):
            return ([web(["Configuration", "Services Security", "RTSP"], "Turn on Identity Authentication."),
                     web(["Configuration", "Services Security", "Onvif"], "Turn on Identity Authentication.")], nil)
        case (.ipcamWeb, .extraServices):
            return ([web(["Configuration", "Services Security", "HIK"], "Turn Enable off."), web(["Configuration", "Services Security", "MEARI"], "Turn Enable off.")], nil)
        case (.ipcamWeb, .internetWatch):
            return ([web(["Configuration", "Network", "IP Address"],
                         "Under DNS, choose Static DNS Server, then enter the Preferred DNS Server and the Alternative DNS Server below.")], nil)

        // The IP camera web API (Jennov): its page's menus.
        case (.ipcWebAPI, .timeZone):
            return ([web(["System", "Date & Time"], "Choose the Time Zone below.")], nil)
        case (.ipcWebAPI, .timeSource):
            return ([web(["System", "Date & Time"], "Set Update Method to NTP and enter the NTP Server below.")], nil)
        case (.ipcWebAPI, .streams):
            return ([web(["Camera", "Video"], "Set the main stream and the sub stream as below.")], nil)
        case (.ipcWebAPI, .upnp):
            return ([Place(app: webPage, action: "Find UPnP in the camera’s network settings and set its Enable off.")], nil)
        case (.ipcWebAPI, .cloud):
            return ([Place(app: webPage, action: "Find the camera’s cloud settings (Enable, Cloud Type, Authorization Code) and set Enable off.")],
                    "The maker’s phone app then no longer reaches the camera away from home.")
        case (.ipcWebAPI, .internetWatch):
            return ([web(["Network", "Basic"], "Set Mode to Static and keep the camera’s IP address, subnet mask and gateway as they are, then enter "
                         + "the Preferred DNS Server and the Alternate DNS Server below.")],
                    "The DNS fields can’t be changed while Mode is DHCP.")

        // Tapo: the Tapo app's network settings (TP-Link FAQs 688 and 4372); nothing else is confirmed.
        case (.tapo, .internetWatch):
            return ([Place(app: tapoApp, path: ["(your camera)", "Device Settings", "Advanced Settings", "Network Settings", "Static IP"],
                           action: "Choose Static IP, keep the camera’s IP address, subnet mask and gateway as they are, and enter the DNS servers below.",
                           confirmed: true)],
                    "Battery Tapo models, and the C100, C200, TC60 and TC70 at hardware versions 1 and 2, don’t have this setting.")
        case (.tapo, .cloud), (.tapo, .upnp):
            return ([], nil)
        case (.tapo, _):
            return ([Place(app: tapoApp, action: tapoAction(id))], nil)

        // Reolink: its support articles for UPnP and UID; where the network screens are is known (the app's, the web page's), not their DNS
        // switch (the Client's is from a search snippet of an article now gone).
        case (.reolink, .upnp):
            return ([Place(app: webPage, path: ["Settings (the gear)", "Network", "Advanced", "UPnP"], action: "Turn UPnP off.", confirmed: true),
                     Place(app: reolinkClient, path: ["Camera Settings", "Network", "Advanced", "Enable UPNP"], action: "Turn it off.", confirmed: true)],
                    "The Reolink phone app has no UPnP setting.")
        case (.reolink, .cloud):
            return ([Place(app: reolinkClient, path: ["Camera Settings", "Network", "Advanced", "UID"], action: "Turn UID off.", confirmed: true)],
                    "With UID off, the Reolink app no longer reaches the camera away from home." + (doorbell ? " Doorbell rings still come through Apple Home." : "")
                        + " The Reolink phone app has no switch for it, and battery cameras have none.")
        case (.reolink, .internetWatch):
            return ([Place(app: reolinkApp, path: ["Settings", "(your camera)", "Network Information"], action: dnsAction),
                     Place(app: reolinkClient, path: ["Device Settings", "Network", "Network Information", "Network Settings"],
                           action: "Choose Static DNS instead of Auto DNS and enter the DNS servers below."),
                     web(["Settings (the gear)", "Network Settings", "Set Up"],
                         dnsAction + " On newer firmware it is under Device Settings › Network › Set up.", confirmed: false)],
                    "Battery cameras have no DNS setting.")
        case (.reolink, _):
            return ([Place(app: "The Reolink Client or the camera’s web page", action: generalAction(id))], nil)

        // The DNS of the other makers (research §4). Hikvision and its OEMs: probably kept only with DHCP off.
        case (.hikvision, .internetWatch):
            return ([web(["Configuration", "Network", "Basic Settings", "TCP/IP"],
                         "Untick DHCP, keep the IPv4 address, subnet mask and default gateway as they are, and enter the Preferred DNS Server and the "
                             + "Alternate DNS Server below.")], nil)
        // Dahua's own manual; the DNS fields can be changed on DHCP. Amcrest's and Lorex's cameras: a best guess.
        case (.dahua, .internetWatch):
            return ([web(["Setup", "Network", "TCP/IP"],
                         "Leave Mode as it is (the DNS can be changed on DHCP too) and enter the Preferred DNS and the Alternate DNS below.",
                         confirmed: false)], nil)
        case (.axis, .internetWatch):
            return ([web(["System", "Network"],
                         "Under DNS, turn off Assign DNS automatically and add the DNS servers below. Leave Assign IPv4 automatically as it is.")], nil)
        case (.hanwha, .internetWatch):
            return ([web(["Setup", "Basic", "IP & Port"], "Untick DNS setting by DHCP, enter the DNS servers below as DNS 1 and DNS 2, and press Apply.")],
                     nil)
        // Uniview's DNS page is confirmed, not its fields' names, nor whether it needs a fixed address.
        case (.uniview, .internetWatch):
            return ([web(["Setup", "Network", "DNS"], "Enter the DNS servers below as its preferred and alternate DNS servers.")],
                    "If it won’t take them, set its address to static first under Setup › Network › Network, keeping the same address, mask and gateway, "
                        + "and reserve it in your router.")
        case (.foscam, .internetWatch):
            return ([web(["Settings", "Network", "IP Configuration"],
                         "Untick Obtain IP From DHCP, keep the IP address, subnet mask and gateway as they are, and enter the DNS servers below, starting "
                             + "with the Primary DNS Server."),
                     Place(app: "Foscam’s Equipment Search Tool (on a computer)", path: ["(your camera, right-click)", "Network Configuration"],
                           action: "Untick Obtain IP From DHCP, keep the address as it is and enter the DNS servers below.", confirmed: true)],
                    "The camera restarts when you save.")
        case (.vigi, .internetWatch):
            return ([web(["Settings", "Network Settings", "Connect"],
                         "Set IPv4 Mode to Static, keep the IP address, subnet mask and gateway as they are, and enter the Preferred DNS and the "
                             + "Alternative DNS below.")],
                    "VIGI VMS and the VIGI Config Tool can change it too.")
        // XMEye: a best guess, on the recorder or in its desktop app (the camera's own page's labels are not known).
        case (.xmeye, .internetWatch):
            return ([Place(app: "The recorder’s menu, or the CMS or VMS app on a computer", path: ["Setting", "System", "Network"],
                           action: "Untick DHCP Enable, keep the IP address, subnet mask and gateway as they are, and enter the Primary DNS and the "
                               + "Secondary DNS below.")], nil)
        // A UniFi camera on its own: a best guess.
        case (.unifi, .internetWatch):
            return ([web(["Network"], "Choose Static, keep the IP address, subnet mask and gateway as they are, and enter the DNS servers below.",
                         confirmed: false)],
                    "Sign in with ubnt and the camera’s recovery code.")

        // Any other step of these makers, and other ONVIF cameras: no menu of theirs is confirmed.
        default:
            return ([Place(app: webPage, action: generalAction(id))], nil)
        }
    }

    /// The general instruction for a step, on the camera's own page or app.
    static func generalAction(_ id: CameraSetupStepID) -> String {
        switch id {
        case .timeZone: "Open the camera’s date and time settings and choose the time zone below."
        case .timeSource: "Open the camera’s date and time settings, choose NTP (time from a server) and enter the server and port below."
        case .cleanPicture: "Open the camera’s on-screen display (OSD) settings and turn off the date, the time and the camera’s name on the picture."
        case .streams: "Open the camera’s video (encoding) settings and set the main and the sub stream as below."
        case .upnp: "Open the camera’s network settings and turn UPnP off."
        case .cloud: "Open the camera’s network or cloud settings and turn its cloud (P2P) off."
        case .videoPassword: "Open the camera’s RTSP and ONVIF settings and turn on their password (authentication)."
        case .extraServices: "Turn off the services for other makers’ apps that the camera offers (such as a Hikvision or Meari protocol)."
        case .internetWatch: "Open the camera’s network settings, set the DNS by hand (not automatic) and enter the DNS servers below."
        }
    }

    /// The Tapo app's general instruction (no menu of it is confirmed but the network settings').
    static func tapoAction(_ id: CameraSetupStepID) -> String {
        switch id {
        case .timeZone: "In the camera’s Device Settings, find its date and time and choose the time zone below."
        case .timeSource: "Camera Bridge knows of no time server setting in the Tapo app; look in the camera’s Device Settings for its date and time."
        case .cleanPicture: "In the camera’s settings, find the date, time and logo shown on the picture and turn them off."
        case .streams: "In the camera’s settings, find its video quality and choose the one closest to the values below."
        default: generalAction(id)
        }
    }

    // MARK: The Security card

    /// What the Internet guard knows of the camera's DNS, for its finding's help: the camera is on the guard's list, its DNS as last read
    /// asks the bridge (nil: not read, or it could not be), its Watch waits for the camera's restart, and the box's report is evidence
    /// (`GuardEvidence.available`).
    public struct GuardDNS: Sendable, Equatable {
        public var listed: Bool
        public var asksBridge: Bool?
        public var waitsForRestart: Bool
        public var available: Bool

        public init(listed: Bool, asksBridge: Bool?, waitsForRestart: Bool = false, available: Bool = true) {
            self.listed = listed
            self.asksBridge = asksBridge
            self.waitsForRestart = waitsForRestart
            self.available = available
        }

        /// The DNS is why the guard does not watch the camera, so pointing it at Camera Bridge by hand helps: it asks other servers and is not
        /// waiting for a restart to take the bridge, or its DNS could not be read. Not while it already asks the bridge (the box has not
        /// started watching it yet), nor while a listed camera's box isn't running (the cause is the box).
        public var wantsHelp: Bool {
            if listed && !available { return false }
            switch asksBridge {
            case true?: return false
            case false?: return !waitsForRestart
            case nil: return true
            }
        }
    }

    /// `security` with the help of each finding the setup can't change: UPnP or the cloud on (or not readable), the video or an extra service
    /// without a password, and the Internet guard's finding while it does not watch the camera (`CameraSecurity.internetGuard`) because of
    /// the camera's DNS (`guardDNS`, `GuardDNS.wantsHelp`; nil: not known, the finding alone decides), where the bridge has an address on the
    /// camera's network.
    public static func withHelp(_ security: CameraSecurity, family: CameraFamily, context: Context, guardDNS: GuardDNS? = nil) -> CameraSecurity {
        var helped = security
        let watched = security.internetGuard?.watched
        for index in helped.findings.indices {
            helped.findings[index].manualHelp = finding(helped.findings[index], watched: watched, guardDNS: guardDNS, family: family, context: context)
        }
        return helped
    }

    static func finding(_ finding: CameraSecurityFinding, watched: Bool?, guardDNS: GuardDNS? = nil, family: CameraFamily,
                        context: Context) -> CameraManualHelp? {
        let id: CameraSetupStepID
        switch finding.feature {
        case .internetGuard:
            guard watched == false, guardDNS?.wantsHelp != false, let server = context.guardServer,
                  var help = step(.internetWatch, status: .notSupported, detail: nil, family: family, context: context) else { return nil }
            help.why = "The \(InternetGuardText.name) sees a camera’s lookups only while its DNS asks Camera Bridge (\(server)) and nothing else."
            return help
        case .upnp, .cloud:
            guard !finding.canChange, finding.state == .on || finding.state == .unknown else { return nil }
            id = finding.feature == .upnp ? .upnp : .cloud
        case .unauthenticatedVideo, .extraService:
            guard !finding.canChange, finding.state == .on else { return nil }
            id = finding.feature == .unauthenticatedVideo ? .videoPassword : .extraServices
        case .ddns, .rtmp:
            return nil
        }
        guard var help = step(id, status: .notSupported, detail: nil, family: family, context: context) else { return nil }
        if family == .tapo && id == .cloud {
            help.why = tapoCloud
        } else if finding.state == .unknown {
            help.why = "Camera Bridge can’t read this setting on this camera, so check it by hand."
        } else if id == .videoPassword {
            help.why = "Camera Bridge can’t give this camera’s video a password, so turn it on by hand."
        } else {
            help.why = "Camera Bridge can’t turn this off on this camera, so turn it off by hand."
        }
        return help
    }
}

// MARK: - The engine

extension BridgeEngine {
    /// The web API family each camera's address showed in this run, kept while the bridge runs: the clients forget it when the camera
    /// starts again, and the help should not change while they ask again.
    @MainActor private static var seenWebAPIs: [UUID: CameraWebAPIFamily] = [:]

    /// The family whose menus the help names for `camera`.
    public func cameraFamily(_ camera: CameraConfiguration) -> CameraFamily {
        if let seen = CameraWebAPIFamily.seen(at: camera.endpoint) { Self.seenWebAPIs[camera.id] = seen }
        return CameraFamily.of(camera, webAPI: Self.seenWebAPIs[camera.id])
    }

    /// The bridge's addresses on the camera's network (its time where the bridge serves time, its DNS where it has the Internet guard), its
    /// time zone in words (`zone`, `manualHelpZone`: read once for many cameras), and for the DNS help the camera's own page (its configured
    /// address and web port), its address as Camera Bridge reaches it, the DNS servers and the address its last reading showed, and whether
    /// its last security check found IPv6 on.
    func manualHelpContext(_ camera: CameraConfiguration, interfaces: [InterfaceAddress], zone: String?) -> CameraManualHelpText.Context {
        let timeServer = environment.servesTime ? Self.timeServerAddress(cameraHost: camera.endpoint.host, interfaces: interfaces) : nil
        let cameraAddress = guardCameraAddress(camera)
        let guardServer = offersInternetGuard ? cameraAddress.flatMap { Self.bridgeAddress(onNetworkOf: $0, interfaces: interfaces) } : nil
        let record = securityChecks.records[camera.id]
        let reading: CameraDNSReading? = if case .read(let reading)? = record?.dns { reading } else { nil }
        return CameraManualHelpText.Context(timeServer: timeServer, guardServer: guardServer, timeZone: zone, doorbell: camera.kind == .doorbell,
                                            webPage: CameraManualHelpText.webPageURL(camera.endpoint), cameraAddress: cameraAddress,
                                            currentDNS: reading?.servers ?? [], addressing: reading?.addressing, ipv6On: record?.ipv6On == true)
    }

    /// The bridge's time zone in words ("America/Phoenix (UTC−7:00)"; its zone file is read).
    private var manualHelpZone: String? {
        let identifier = settings.timeZone ?? TimeZone.current.identifier
        return PosixTimeZone.string(for: identifier).map { "\(identifier) (\(CameraSetupText.zone($0)))" }
    }

    private var manualHelpInterfaces: [InterfaceAddress] { tuning.interfaceAddresses?() ?? StreamAddress.interfaceAddresses() }

    /// The cameras the help is for: those the setup works with, reached directly.
    private func getsManualHelp(_ cameraID: UUID) -> CameraConfiguration? {
        configurations.first { $0.id == cameraID && $0.integration == nil && Self.cameraSetupVendors.contains($0.vendor) }
    }

    /// `report` with "Change it by hand" on each step the camera refused or does not support (`CameraSetupStep.manualHelp`).
    public func withManualHelp(_ report: CameraSetupReport, cameraID: UUID) -> CameraSetupReport {
        guard let camera = getsManualHelp(cameraID) else { return report }
        return CameraManualHelpText.withHelp(report, family: cameraFamily(camera),
                                             context: manualHelpContext(camera, interfaces: manualHelpInterfaces, zone: manualHelpZone))
    }

    /// `security` with "Change it by hand" on each finding the setup can't change (`CameraSecurityFinding.manualHelp`).
    public func withManualHelp(_ security: CameraSecurity, cameraID: UUID) -> CameraSecurity {
        guard let camera = getsManualHelp(cameraID) else { return security }
        return CameraManualHelpText.withHelp(security, family: cameraFamily(camera),
                                             context: manualHelpContext(camera, interfaces: manualHelpInterfaces, zone: manualHelpZone),
                                             guardDNS: manualHelpGuardDNS(camera))
    }

    /// `statuses` with the help on each checked camera's findings (the bridge's interfaces and its zone are read once: the page's events ask
    /// for this twice a second).
    public func withManualHelp(_ statuses: [CameraStatus]) -> [CameraStatus] {
        guard statuses.contains(where: { $0.security != nil }) else { return statuses }
        let interfaces = manualHelpInterfaces, zone = manualHelpZone
        return statuses.map { status in
            guard let security = status.security, let camera = getsManualHelp(status.id) else { return status }
            var helped = status
            helped.security = CameraManualHelpText.withHelp(security, family: cameraFamily(camera),
                                                            context: manualHelpContext(camera, interfaces: interfaces, zone: zone),
                                                            guardDNS: manualHelpGuardDNS(camera))
            return helped
        }
    }

    /// What the Internet guard knows of the camera's DNS (its list, its last reading, a Watch waiting for the camera's restart, the box's
    /// report), as its evidence has it (`internetGuardEvidence`); nil on a bridge without the guard.
    func manualHelpGuardDNS(_ camera: CameraConfiguration) -> CameraManualHelpText.GuardDNS? {
        guard offersInternetGuard else { return nil }
        let dns = securityChecks.records[camera.id]?.dns ?? .notAsked
        let record = camera.setupState?.steps.last { $0.id == .internetWatch }
        let available = internetGuard.fresh && internetGuard.report.map { $0.available && $0.running != false } == true
        return .init(listed: Self.internetWatchDone(camera) && guardCameraAddress(camera) != nil, asksBridge: asksBridge(camera, dns),
                     waitsForRestart: record?.status == .done && record?.needsRestart == true, available: available)
    }
}
