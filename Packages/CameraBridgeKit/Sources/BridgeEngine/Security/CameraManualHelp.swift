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

/// The kinds of camera whose menus the help knows.
public enum CameraFamily: String, Sendable, Codable, CaseIterable {
    case hikvision, reolink
    /// TP-Link Tapo (changed in the Tapo app).
    case tapo
    /// The IP camera web API: Jennov and other Anjvision cameras ("IP Camera Web Login").
    case ipcWebAPI
    /// The IPCamera Web family (its page is titled "IPCamera Web").
    case ipcamWeb
    /// Dahua and Amcrest.
    case dahua
    /// Any other ONVIF camera.
    case onvif

    /// The family of `camera`: its vendor, then the web API its address showed in this run (`webAPI`, CameraAdapters'
    /// `CameraWebAPIFamily.seen(at:)`), then its maker and model (a Tapo, a Hikvision, Reolink, Dahua or Amcrest added as ONVIF), then what
    /// an earlier setup kept of one of the two web API families; else a plain ONVIF camera.
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
        let maker = Set(camera.manufacturer.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if maker.contains("hikvision") { return .hikvision }
        if maker.contains("reolink") { return .reolink }
        if !maker.isDisjoint(with: ["dahua", "amcrest", "lorex"]) { return .dahua }
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

    /// A value to set ("Preferred DNS server": "192.168.77.28").
    public struct Value: Sendable, Codable, Equatable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
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

    /// `caveat` follows `places`.
    public init(why: String, places: [Place] = [], values: [Value] = [], router: String? = nil, note: String? = nil, then: String? = nil) {
        self.why = why
        self.places = places
        self.values = values
        self.router = router
        self.note = note
        self.then = then
        caveat = places.contains { !$0.confirmed } ? CameraManualHelpText.caveat : nil
    }
}

/// The help's words, one table: for each step of the setup and each camera family, why, where and what.
public enum CameraManualHelpText {
    /// The bridge's addresses and zone the help names.
    public struct Context: Sendable, Equatable {
        /// The bridge's address on the camera's network as its time server (Camera Bridge OS); nil where the bridge serves no time.
        public var timeServer: String?
        /// The bridge's address on the camera's network as its DNS server (the Internet guard); nil where there is no guard or no address there.
        public var guardServer: String?
        /// The bridge's time zone in words ("America/Phoenix (UTC−7:00)").
        public var timeZone: String?
        /// The camera is a doorbell (what turning its cloud off leaves working says so).
        public var doorbell: Bool

        public init(timeServer: String?, guardServer: String?, timeZone: String?, doorbell: Bool = false) {
            self.timeServer = timeServer
            self.guardServer = guardServer
            self.timeZone = timeZone
            self.doorbell = doorbell
        }
    }

    public static let caveat = "Menu names differ between models and firmware versions, so look for the closest match."
    static let then = "Then press Check again on the camera’s Security card."

    static let webPage = "The camera’s web page"
    static let reolinkApp = "The Reolink app"
    static let reolinkClient = "The Reolink Client (on a computer)"
    static let tapoApp = "The Tapo app"

    static let accountWhy = "The account Camera Bridge signs in with may not change this setting: change it by hand, or sign Camera Bridge in with an "
        + "administrator account."
    static let tapoCloud = "Tapo cameras have no switch for TP-Link’s cloud that Camera Bridge knows of."
    /// Words of a refusal for want of rights (the camera's "No Privilege", or Camera Bridge's own sentence for a write the account may not make).
    static let accountWords = ["administrator", "may not change", "not permitted", "no privilege", "permission"]

    // MARK: Steps

    /// The help for step `id` that ended `status` (only `notSupported` and `refused` have any) with `detail`, on a camera of `family`;
    /// `changes` are the step's planned values (the streams' "after"). nil for the DNS and the time without the bridge's address.
    public static func step(_ id: CameraSetupStepID, status: CameraSetupStepStatus, detail: String?, family: CameraFamily, context: Context,
                            changes: [CameraSetupChange] = []) -> CameraManualHelp? {
        guard status == .notSupported || status == .refused else { return nil }
        let values: [CameraManualHelp.Value]
        switch id {
        case .timeSource:
            guard let server = context.timeServer else { return nil }
            values = [.init(label: "Time from", value: "NTP (a time server)"), .init(label: "NTP server", value: server), .init(label: "Port", value: "123")]
        case .internetWatch:
            guard let server = context.guardServer else { return nil }
            values = [.init(label: "DNS", value: "set by hand, not automatic"), .init(label: "Preferred DNS server", value: server),
                      .init(label: "Alternate DNS server", value: server)]
        default:
            values = Self.values(id, family: family, context: context, changes: changes)
        }
        let (places, note) = entry(id, family: family, doorbell: context.doorbell)
        return CameraManualHelp(why: why(id, status: status, detail: detail, family: family), places: places, values: values,
                                router: router(id, server: context.guardServer, alone: places.isEmpty), note: note,
                                then: id == .internetWatch ? then : nil)
    }

    /// `report` with each step's help (none on a step that was done, is right, or was not tried).
    public static func withHelp(_ report: CameraSetupReport, family: CameraFamily, context: Context) -> CameraSetupReport {
        var helped = report
        for index in helped.steps.indices {
            let step = helped.steps[index]
            helped.steps[index].manualHelp = Self.step(step.id, status: step.status, detail: step.detail, family: family, context: context, changes: step.changes)
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
            case .dahua, .onvif: return [.init(label: "The maker’s cloud (P2P)", value: "off")]
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
            return "Or give the camera a fixed address (a DHCP reservation) and have your router hand that camera \(server) as its DNS server, or "
                + "block the camera’s internet there (see Keep this camera local). A DNS server from the router counts too, but it can change when "
                + "the router renews the camera’s address."
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
    /// language file and menu), the IP camera web API's page (its language file and menu script), TP-Link's FAQ 4372 (the Tapo app's
    /// network settings) and Reolink's support articles (UPnP, UID). Everything else is a general instruction (`generalAction`), with the
    /// caveat: Hikvision's, Dahua's and Amcrest's menus are only in other people's guides, and the IP camera web API's OSD tab was not
    /// confirmed.
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
                    "The DNS fields can’t be changed while Mode is DHCP. Reserve the camera’s address in your router too, so nothing else takes it.")

        // Tapo: the Tapo app's network settings (TP-Link FAQ 4372); nothing else is confirmed.
        case (.tapo, .internetWatch):
            return ([Place(app: tapoApp, path: ["(your camera)", "Device Settings", "Advanced Settings", "Network Settings", "Static IP"],
                           action: "Choose Static IP, keep the camera’s IP address, subnet mask and gateway as they are, and enter the DNS servers below.",
                           confirmed: true)],
                    "Keep the same address, and reserve that address in your router so it never changes. Some older and battery Tapo models don’t "
                        + "have this setting.")
        case (.tapo, .cloud), (.tapo, .upnp):
            return ([], nil)
        case (.tapo, _):
            return ([Place(app: tapoApp, action: tapoAction(id))], nil)

        // Reolink: its support articles for UPnP and UID; where the network screens are is known, not their DNS fields.
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
                     Place(app: reolinkClient, path: ["Device Settings", "Network", "Network Information"], action: dnsAction),
                     Place(app: webPage, path: ["Settings (the gear)", "Network Settings", "Set Up"], action: dnsAction)], nil)
        case (.reolink, _):
            return ([Place(app: "The Reolink Client or the camera’s web page", action: generalAction(id))], nil)

        // Hikvision, Dahua, Amcrest and other ONVIF cameras: no menu of theirs is confirmed.
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

    /// The bridge's addresses on the camera's network (its time where the bridge serves time, its DNS where it has the Internet guard) and its
    /// time zone in words (`zone`, `manualHelpZone`: read once for many cameras).
    func manualHelpContext(_ camera: CameraConfiguration, interfaces: [InterfaceAddress], zone: String?) -> CameraManualHelpText.Context {
        let timeServer = environment.servesTime ? Self.timeServerAddress(cameraHost: camera.endpoint.host, interfaces: interfaces) : nil
        let guardServer = offersInternetGuard ? guardCameraAddress(camera).flatMap { Self.bridgeAddress(onNetworkOf: $0, interfaces: interfaces) } : nil
        return CameraManualHelpText.Context(timeServer: timeServer, guardServer: guardServer, timeZone: zone, doorbell: camera.kind == .doorbell)
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
