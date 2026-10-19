import CameraAdapters
import Foundation

// The camera security levels (owner decision, 2026-10-17): a pure function of what the camera reported (`RemoteAccessFinding`, from
// `CameraSettingsService.readRemoteAccess()` and the RTSP check), the cameras that work only through their maker's cloud, and the Internet
// guard's evidence (Camera Bridge OS; nil where there is none, so green is the best then). The words say what was confirmed and never
// promise more.

/// How far a camera can be reached from outside the home, worst first: red "Outside access possible", yellow "Needs work", green "Good",
/// gold "Local only".
public enum CameraSecurityLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case red, yellow, green, gold

    private var rank: Int {
        switch self {
        case .red: 0
        case .yellow: 1
        case .green: 2
        case .gold: 3
        }
    }

    public static func < (lhs: CameraSecurityLevel, rhs: CameraSecurityLevel) -> Bool { lhs.rank < rhs.rank }

    /// The level's name (one table, so it can be renamed in one place).
    public var title: String {
        switch self {
        case .red: "Outside access possible"
        case .yellow: "Needs work"
        case .green: "Good"
        case .gold: "Local only"
        }
    }

    /// What the level says, in one sentence.
    var summary: String {
        switch self {
        case .red: "Something on this camera can let it be reached from outside your home."
        case .yellow: "Nothing Camera Bridge read opens this camera to the outside, but something needs work."
        case .green: "Camera Bridge found no cloud turned on, but it can’t confirm everything, so a way out is still possible."
        case .gold: "Every outside feature Camera Bridge knows for this camera is off, its video needs a password, and the \(InternetGuardText.name) saw "
            + "it make no internet lookups in the last 24 hours."
        }
    }
}

/// What a finding is about: a camera feature (`RemoteAccessFeature`) or the Internet guard's evidence.
public enum CameraSecurityFeature: String, Sendable, Codable, CaseIterable {
    case cloud, upnp, ddns, rtmp, unauthenticatedVideo, extraService
    /// What the Internet guard saw of the camera (Camera Bridge OS).
    case internetGuard

    public init(_ feature: RemoteAccessFeature) {
        switch feature {
        case .cloud: self = .cloud
        case .upnp: self = .upnp
        case .ddns: self = .ddns
        case .rtmp: self = .rtmp
        case .unauthenticatedVideo: self = .unauthenticatedVideo
        case .extraService: self = .extraService
        }
    }
}

/// What the Internet guard (Camera Bridge OS: the camera's DNS pointed at the box) saw of one camera, for its level. The guard fills it in;
/// nil where there is no guard (the Mac app), and then green is the best level.
public struct GuardEvidence: Sendable, Codable, Equatable {
    /// The guard watches this camera: it is on the guard's list here (`listed`), the box watches its address, and the camera's DNS, as last
    /// read, asks the bridge's address now (`asksBridge`).
    public var watched: Bool
    /// It is on the guard's list here (its Watch done, or its DNS read pointing at the bridge): the box is asked to watch its address.
    public var listed: Bool
    /// The camera's DNS servers, as last read, are the bridge's address now; false: they are others (a DHCP renewal, a factory reset, the
    /// bridge at a new address); nil: not read.
    public var asksBridge: Bool?
    /// How long the box has watched it without a break; nil when it does not say. Gold needs a full day.
    public var watchedFor: TimeInterval?
    /// Its Watch was taken "after the camera restarts" (ISAPI `statusCode` 7): a camera whose DNS is not the bridge yet waits for that.
    public var waitsForRestart: Bool
    /// The camera's DNS servers, as last read, come from its router (DHCP): the router can change them when it renews the camera's address.
    public var dnsFromRouter: Bool
    /// The camera's lookups of outside names in the last 24 hours (blocked).
    public var outsideLookups24h: Int
    /// The newest names it looked up, newest first.
    public var lastLookupNames: [String]
    /// The guard runs on this bridge now.
    public var available: Bool
    /// Its blocked lookups since the guard's day began.
    public var today: Int
    /// The names it asked for in the last 7 days, most asked first.
    public var names: [GuardReport.Lookup]
    /// Its questions that never leave the home network in the box's last 7 days (`GuardReport.Camera.local`: counted, never named).
    public var localLookups: Int

    /// The box has seen the camera ask it at least once in its last 7 days: a name it blocked, or a question that never leaves the home
    /// network. Without that, a quiet day is no proof (research §5): a camera with a DNS server built in is quiet too, so it is not gold.
    public var lookupSeen: Bool { !names.isEmpty || localLookups > 0 || outsideLookups24h > 0 || today > 0 }

    /// `listed` defaults to `watched`, `asksBridge` to true for a watched camera, `dnsFromRouter` to false, `localLookups` to 0.
    public init(watched: Bool, outsideLookups24h: Int, lastLookupNames: [String], available: Bool, today: Int = 0, names: [GuardReport.Lookup] = [],
                localLookups: Int = 0, listed: Bool? = nil, asksBridge: Bool? = nil, watchedFor: TimeInterval? = nil, waitsForRestart: Bool = false,
                dnsFromRouter: Bool = false) {
        self.watched = watched
        self.listed = listed ?? watched
        self.asksBridge = asksBridge ?? (watched ? true : nil)
        self.watchedFor = watchedFor
        self.waitsForRestart = waitsForRestart
        self.dnsFromRouter = dnsFromRouter
        self.outsideLookups24h = outsideLookups24h
        self.lastLookupNames = lastLookupNames
        self.available = available
        self.today = today
        self.names = names
        self.localLookups = localLookups
    }

    /// Gold needs this long a watch without a lookup.
    public static let quietDay: TimeInterval = 86_400

    /// What a full day's watch says of a camera the box never saw ask anything (`lookupSeen` false).
    public static let noLookupsSeen = "No lookups seen yet; Camera Bridge can’t rule out a built-in DNS server."
}

/// One thing the level rests on: the feature, as the camera reported it, the best level the camera can have with it, a plain sentence,
/// and whether "Set up for Camera Bridge" can change it.
public struct CameraSecurityFinding: Sendable, Codable, Equatable {
    public var feature: CameraSecurityFeature
    public var state: RemoteAccessState
    public var level: CameraSecurityLevel
    public var sentence: String
    public var canChange: Bool
    /// The cloud only: linked to an account (nil: the camera does not say).
    public var linked: Bool?
    /// The service's name ("Hik-Connect", "Meari service (port 10000)").
    public var service: String?
    /// "Change it by hand" where the setup can't change it (CameraManualHelp.swift); filled in for the web page, never by `assess`.
    public var manualHelp: CameraManualHelp?

    public init(feature: CameraSecurityFeature, state: RemoteAccessState, level: CameraSecurityLevel, sentence: String, canChange: Bool,
                linked: Bool? = nil, service: String? = nil, manualHelp: CameraManualHelp? = nil) {
        self.feature = feature
        self.state = state
        self.level = level
        self.sentence = sentence
        self.canChange = canChange
        self.linked = linked
        self.service = service
        self.manualHelp = manualHelp
    }
}

/// A camera's security level with what it rests on and when it was checked (`CameraStatus.security`).
public struct CameraSecurity: Sendable, Codable, Equatable {
    public var level: CameraSecurityLevel
    public var title: String
    public var summary: String
    /// Worst first.
    public var findings: [CameraSecurityFinding]
    public var checkedAt: Date
    /// What the Internet guard saw of the camera; nil where there is no guard (the Mac app).
    public var internetGuard: CameraGuardActivity?

    public init(level: CameraSecurityLevel, title: String, summary: String, findings: [CameraSecurityFinding], checkedAt: Date,
                internetGuard: CameraGuardActivity? = nil) {
        self.level = level
        self.title = title
        self.summary = summary
        self.findings = findings
        self.checkedAt = checkedAt
        self.internetGuard = internetGuard
    }

    /// The level from what the camera reported (several readings of one feature are one: open if any saw it on, else confirmed if any
    /// confirmed it), `cloudModel` (a camera that works only through its maker's cloud: `CloudDependentModels`) and the guard's evidence.
    /// A camera without a reading of its cloud has it unknown; video nothing checked is unknown too.
    /// - red: the cloud on and linked or of unknown link, UPnP, DDNS or RTMP on, or a cloud-dependent model.
    /// - yellow: the cloud on but not linked, or unknown; video (or another service) without a password; watched and still looking up
    ///   internet names.
    /// - green: nothing of those, but something can't be confirmed (an unknown, another service, no guard, not watched, watched for less
    ///   than a day, or no lookup ever seen from it).
    /// - gold: everything confirmed off or absent, the video locked, and watched for a full day with no internet lookups, by a box that has seen
    ///   the camera ask it something in its last 7 days (`GuardEvidence.lookupSeen`: silence alone is no proof).
    public static func assess(_ readings: [RemoteAccessFinding], cloudModel: String? = nil, internetGuard: GuardEvidence?, checkedAt: Date) -> CameraSecurity {
        var readings = merged(readings)
        if let cloudModel {
            readings.removeAll { $0.feature == .cloud && $0.state == .unknown }
            readings.insert(RemoteAccessFinding(feature: .cloud, state: .on, linked: true, service: cloudModel), at: 0)
        }
        if !readings.contains(where: { $0.feature == .cloud }) { readings.insert(.cloudUnknown, at: 0) }
        if !readings.contains(where: { $0.feature == .unauthenticatedVideo }) {
            readings.append(RemoteAccessFinding(feature: .unauthenticatedVideo, state: .unknown))
        }
        var findings = readings.map { finding($0, model: $0.feature == .cloud && $0.service == cloudModel ? cloudModel : nil) }
        findings.append(guardFinding(internetGuard))
        let order = CameraSecurityFeature.allCases
        findings = findings.enumerated().sorted { a, b in
            if a.element.level != b.element.level { return a.element.level < b.element.level }
            let left = order.firstIndex(of: a.element.feature) ?? 0, right = order.firstIndex(of: b.element.feature) ?? 0
            return left != right ? left < right : a.offset < b.offset
        }.map(\.element)
        let level = findings.map(\.level).min() ?? .green
        let activity = internetGuard.map { evidence in
            CameraGuardActivity(watched: evidence.watched, today: evidence.today, last24h: evidence.outsideLookups24h,
                                names: Array(evidence.names.prefix(CameraGuardActivity.maximumNames)))
        }
        return CameraSecurity(level: level, title: level.title, summary: level.summary, findings: findings, checkedAt: checkedAt, internetGuard: activity)
    }

    /// One reading per feature and service: on if any reading saw it on, else off or absent if any confirmed it, else unknown.
    static func merged(_ readings: [RemoteAccessFinding]) -> [RemoteAccessFinding] {
        var keys: [String] = []
        var groups: [String: [RemoteAccessFinding]] = [:]
        for reading in readings {
            let key = "\(reading.feature.rawValue)|\(reading.service ?? "")"
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(reading)
        }
        return keys.compactMap { key in
            guard let group = groups[key], var one = group.first else { return nil }
            let states = group.map(\.state)
            one.state = states.contains(.on) ? .on : states.contains(.off) ? .off : states.contains(.absent) ? .absent : .unknown
            let links = group.filter { $0.state == one.state }.map(\.linked)
            one.linked = links.contains(true) ? true : one.state == .on && links.contains(nil) ? nil : links.compactMap { $0 }.first
            one.canChange = group.contains(where: \.canChange)
            return one
        }
    }

    /// The best level a reading leaves the camera, and its sentence.
    static func finding(_ reading: RemoteAccessFinding, model: String?) -> CameraSecurityFinding {
        let (level, sentence) = judged(reading, model: model)
        return CameraSecurityFinding(feature: CameraSecurityFeature(reading.feature), state: reading.state, level: level, sentence: sentence,
                                     canChange: reading.canChange, linked: reading.linked, service: reading.service)
    }

    private static func judged(_ reading: RemoteAccessFinding, model: String?) -> (CameraSecurityLevel, String) {
        let state = reading.state
        switch reading.feature {
        case .cloud:
            if let model { return (.red, "\(model) cameras work through \(model)’s cloud, so they can be reached from outside your home.") }
            let name = reading.service ?? "the maker’s cloud"
            switch state {
            case .on where reading.linked == true:
                return (.red, "\(capitalized(name)) is on and linked to an account, so the camera can be reached from outside your home.")
            case .on where reading.linked == false:
                return (.yellow, "\(capitalized(name)) is on but not linked to an account.")
            case .on:
                return (.red, "\(capitalized(name)) is on, and Camera Bridge can’t tell whether it is linked to an account. If it is, the camera can be "
                        + "reached from outside your home.")
            case .off: return (.gold, "\(capitalized(name)) is off.")
            case .absent: return (.gold, reading.service.map { "The camera has no \($0)." } ?? "The camera has no cloud setting.")
            case .unknown: return (.yellow, "Camera Bridge can’t read whether \(name) is on.")
            }
        case .upnp:
            return outside(state, name: "UPnP", on: "UPnP is on, so the camera can open ports on your router to the internet.")
        case .ddns:
            return outside(state, name: "dynamic DNS", on: "Dynamic DNS is on, so the camera keeps a name on the internet that leads to your home.")
        case .rtmp:
            return outside(state, name: "RTMP push", on: "RTMP push is on, so the camera can send its video to a server on the internet.")
        case .unauthenticatedVideo:
            if let service = reading.service, state == .on { return (.yellow, "Its \(service) answers without a password on your home network.") }
            switch state {
            case .on: return (.yellow, "Its video plays without a password on your home network.")
            case .off: return (.gold, "Its video needs a password.")
            case .absent, .unknown: return (.green, "Camera Bridge couldn’t check whether its video needs a password.")
            }
        case .extraService:
            let name = reading.service ?? "another service"
            switch state {
            case .on: return (.green, "\(capitalized(name)) is on, and Camera Bridge can’t tell whether it reaches the internet.")
            case .off: return (.gold, "\(capitalized(name)) is off.")
            case .absent: return (.gold, "The camera has no \(name).")
            case .unknown: return (.green, "Camera Bridge can’t read whether \(name) is on.")
            }
        }
    }

    /// UPnP, DDNS and RTMP: on is red; unknown leaves green at best.
    private static func outside(_ state: RemoteAccessState, name: String, on: String) -> (CameraSecurityLevel, String) {
        switch state {
        case .on: (.red, on)
        case .off: (.gold, "\(capitalized(name)) is off.")
        case .absent: (.gold, "The camera has no \(name).")
        case .unknown: (.green, "Camera Bridge can’t read whether \(name) is on.")
        }
    }

    /// A watch on DNS servers the camera's router gives (DHCP) can end when the router renews the camera's address.
    static let dnsFromRouterNote = "Its DNS servers come from your router, which can change them when it renews the camera’s address."

    /// What the guard saw: without it, while it does not watch the camera, or before a full day of watching, green is the best; watched and
    /// still looking up internet names, yellow; watched for a day without a lookup, gold, but only once the box has seen the camera ask it
    /// something (`GuardEvidence.lookupSeen`, any name, local ones included): else green, `GuardEvidence.noLookupsSeen`. A camera not on the
    /// guard's list gets the "doesn't watch" sentence whatever the box's state (a box watching no camera has its DNS off). A watch on DNS the
    /// router gives says so (`dnsFromRouterNote`).
    static func guardFinding(_ evidence: GuardEvidence?) -> CameraSecurityFinding {
        func make(_ state: RemoteAccessState, _ level: CameraSecurityLevel, _ sentence: String) -> CameraSecurityFinding {
            CameraSecurityFinding(feature: .internetGuard, state: state, level: level, sentence: sentence, canChange: false)
        }
        let name = InternetGuardText.name
        guard let evidence else {
            return make(.absent, .green, "This bridge can’t watch the camera’s internet traffic, so Camera Bridge can’t confirm that nothing gets out.")
        }
        guard evidence.listed else {
            return make(.off, .green, "The \(name) doesn’t watch this camera, so Camera Bridge can’t confirm that nothing gets out.")
        }
        guard evidence.available else {
            return make(.unknown, .green, "The \(name) isn’t running, so Camera Bridge can’t confirm that nothing gets out.")
        }
        let note = evidence.watched && evidence.dnsFromRouter ? " " + dnsFromRouterNote : ""
        if evidence.outsideLookups24h > 0 {
            let count = evidence.outsideLookups24h
            let names = evidence.lastLookupNames.prefix(3)
            return make(.on, .yellow, "The \(name) blocked \(count == 1 ? "1 lookup of an internet name" : "\(count) lookups of internet names") in the last "
                        + "24 hours" + (names.isEmpty ? "" : " (\(names.joined(separator: ", ")))") + ", but the camera may have another way out." + note)
        }
        switch evidence.asksBridge {
        case false? where evidence.waitsForRestart:
            return make(.off, .green, "The camera takes Camera Bridge as its DNS server when it restarts. Until then the \(name) can’t see its lookups.")
        case false?:
            return make(.off, .green, "The camera no longer asks Camera Bridge for its lookups, so the \(name) can’t see them. Run Set up for Camera Bridge "
                        + "again to watch it.")
        case nil:
            return make(.unknown, .green, "Camera Bridge couldn’t read which DNS servers the camera asks, so it can’t confirm that the \(name) sees its lookups.")
        case true?:
            break
        }
        guard evidence.watched else { return make(.unknown, .green, "The \(name) hasn’t started watching this camera yet.") }
        guard let watchedFor = evidence.watchedFor, watchedFor >= GuardEvidence.quietDay else {
            let hours = Int((evidence.watchedFor ?? 0) / 3600)
            let time = hours < 1 ? "less than an hour" : hours == 1 ? "1 hour" : "\(hours) hours"
            return make(.on, .green, "The \(name) has watched it for \(time) and seen no internet lookups yet. It takes a full day to confirm." + note)
        }
        guard evidence.lookupSeen else { return make(.on, .green, GuardEvidence.noLookupsSeen + note) }
        return make(.on, .gold, "The \(name) has watched it for the last 24 hours and saw it make no internet lookups." + note)
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

/// The cameras that work only through their maker's cloud (owner decision, 2026-10-17): they are red whatever their settings say.
public enum CloudDependentModels {
    /// The brand of such a camera: Wyze through the Wyze plugin, eufy through the eufy plugin, Ring, Google Nest and Tuya (Smart Life)
    /// through their integrations (Ring and Nest also by their maker), and TP-Link Tapo, Blink, Arlo and SimpliSafe by their maker or model. A TP-Link camera that is not of
    /// its local VIGI line is a Tapo (Tapo firmware's ONVIF device information names the maker "tp-link" and the model alone, "C200"). nil
    /// for any other camera.
    public static func brand(integration: IntegrationService?, manufacturer: String, model: String) -> String? {
        switch integration {
        case .wyze: return "Wyze"
        case .eufy: return "eufy"
        case .ring: return "Ring"
        case .nest: return "Google Nest"
        case .tuya: return "Tuya (Smart Life)"
        case .unifiProtect, .other, nil: break
        }
        let maker = words(manufacturer), both = maker.union(words(model))
        if both.contains("tapo") { return "TP-Link Tapo" }
        if maker.contains("tplink") || (maker.contains("tp") && maker.contains("link")), !words(model).contains("vigi") { return "TP-Link Tapo" }
        if maker.contains("ring") { return "Ring" }
        if both.contains("nest") { return "Google Nest" }
        if both.contains("blink") { return "Blink" }
        if both.contains("arlo") { return "Arlo" }
        if both.contains("simplisafe") { return "SimpliSafe" }
        return nil
    }

    static func brand(of camera: CameraConfiguration) -> String? {
        brand(integration: camera.integration?.service, manufacturer: camera.manufacturer, model: camera.model)
    }

    /// The text's words, lowercased (letters and digits; anything else separates them).
    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}
