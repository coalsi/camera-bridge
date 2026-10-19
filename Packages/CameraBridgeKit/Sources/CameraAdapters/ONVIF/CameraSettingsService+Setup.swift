import BridgeSupport
import Foundation

// "Set up for Camera Bridge" (docs/superpowers/specs/2026-10-16-camera-setup-design.md): the steps that make a camera right for the bridge, each
// read (its current value is also the backup), planned, applied, read back and restorable. This file has the shared types, the time zone
// step and the clean-picture reading; +NTP.swift the time source, +DNS.swift the internet guard's Watch, +Network.swift the camera's cloud
// and UPnP, IPCamWeb/ the video password and the extra services of the IPCamera Web family. The streams step is the HomeKit optimizer's encoder changes (+Encoder.swift), planned
// by the engine.

/// One step of the setup, in the order the steps are applied (the clock first; Restore goes in reverse). A refused step stops the steps
/// after it that would change something (the engine's rule: "Watch its internet" still runs unless the camera stopped answering or refused
/// its login, and a change the account may not make, `CameraSetupOutcome.notPermitted`, stops nothing), so the steps not yet tried on many
/// cameras come after UPnP off and Cloud off: the IPCamera Web family's video password and extra services, then `internetWatch` (the
/// camera's DNS pointed at the bridge, Camera Bridge OS's internet guard, Watch), last.
public enum CameraSetupStepID: String, Sendable, Codable, CaseIterable {
    case timeZone, timeSource, cleanPicture, streams, upnp, cloud, videoPassword, extraServices, internetWatch
}

/// One value a step changes, as a person reads it ("Main stream": "H.265, 20 fps, keyframe every 2.5 s" → "H.264, 20 fps, keyframe every 2 s").
public struct CameraSetupChange: Sendable, Codable, Equatable {
    public var label: String
    public var now: String
    public var after: String

    public init(label: String, now: String, after: String) {
        self.label = label
        self.now = now
        self.after = after
    }
}

/// What reading a step found: something to change, nothing to change, or a camera that cannot do it (with why).
public struct CameraSetupReading: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case willChange
        case alreadyRight
        case notSupported(String)
        /// The setup does not offer the step for this camera (the IPCamera Web family's steps on another camera), with why.
        case notOffered(String)
    }

    public var state: State
    public var changes: [CameraSetupChange]
    /// A sentence about part of the step that is not offered ("Sub stream: not offered, …").
    public var note: String?
    /// "Watch its internet": "Fix its address so the DNS stays", offered as the person's choice (off unless chosen) for a camera whose DNS
    /// only stays with a fixed address; nil where it is not offered.
    public var fixAddress: CameraSetupFixAddress?

    public init(state: State, changes: [CameraSetupChange] = [], note: String? = nil, fixAddress: CameraSetupFixAddress? = nil) {
        self.state = state
        self.changes = changes
        self.note = note
        self.fixAddress = fixAddress
    }

    public static func notSupported(_ reason: String = "not supported by this camera") -> CameraSetupReading { .init(state: .notSupported(reason)) }

    public static func notOffered(_ reason: String = "not offered for this camera") -> CameraSetupReading { .init(state: .notOffered(reason)) }
}

/// What applying or restoring a step did.
public struct CameraSetupOutcome: Sendable, Equatable {
    public var succeeded: Bool
    /// The camera took the change and says it applies after it restarts (ISAPI `statusCode` 7). Camera Bridge restarts it only when the
    /// person presses "Restart the camera now" (`BridgeEngine.restartCamera(id:)`).
    public var needsRestart: Bool
    /// "via ISAPI", or the camera's words when it refused.
    public var detail: String
    /// The camera refused the change to the account Camera Bridge uses (`CameraAdapterError.notPermitted`, or Reolink's `GetAbility` said so
    /// before anything was sent, or the IPCamera Web family answered 532374 "No Privilege" at the write or at the sign-in): it is no wrong
    /// password, and Set up for Camera Bridge goes on with the steps after it. `detail` is then `CameraAdapterError.notPermittedReason`, or
    /// the family's own words for a sign-in refused so (`IPCamWebUnavailable.noPrivilege`, which says to use an administrator account too),
    /// after ONVIF's for "Watch its internet".
    public var notPermitted: Bool
    /// "Watch its internet" with "Fix its address so the DNS stays": the camera took the fixed address (its address as it was, now set by
    /// hand), whether or not the rest of the step was done; the router reservation is then worth making, and Restore puts DHCP back.
    public var addressFixed: Bool
    /// "Fix its address so the DNS stays" was refused before anything about the camera's address was changed: before its first write, or
    /// at it (the camera refused that write). The run then keeps no fixed address to put back. False whenever that is not known for sure.
    public var addressUntouched: Bool

    public init(succeeded: Bool, needsRestart: Bool = false, detail: String, notPermitted: Bool = false, addressFixed: Bool = false,
                addressUntouched: Bool = false) {
        self.succeeded = succeeded
        self.needsRestart = needsRestart
        self.detail = detail
        self.notPermitted = notPermitted
        self.addressFixed = addressFixed
        self.addressUntouched = addressUntouched
    }

    /// The same refusal, marked `addressUntouched`.
    var untouched: CameraSetupOutcome {
        var copy = self
        copy.addressUntouched = true
        return copy
    }

    static func refused(_ words: String) -> CameraSetupOutcome { .init(succeeded: false, detail: words) }

    /// The camera's refusal of a change, quoted (`CameraAdapterError.refusalWords`): a change the account may not make in those words, with
    /// `notPermitted` set; an IPCamera Web family's API that cannot be asked in its reason, with `notPermitted` set when the account has no
    /// privilege for it (`IPCamWebUnavailable.noPrivilege`).
    static func refused(_ error: any Error) -> CameraSetupOutcome {
        if case CameraAdapterError.notPermitted = error { return notPermittedRefusal }
        if let unavailable = error as? IPCamWebUnavailable {
            return CameraSetupOutcome(succeeded: false, detail: unavailable.reason, notPermitted: unavailable.notPermitted)
        }
        return .refused(CameraAdapterError.refusalWords(error))
    }

    /// A change the account Camera Bridge uses may not make.
    static let notPermittedRefusal = CameraSetupOutcome(succeeded: false, detail: CameraAdapterError.notPermittedReason, notPermitted: true)
}

/// The camera's time zone before the setup changed it.
public struct CameraTimeZoneBackup: Sendable, Codable, Equatable {
    /// `.hikvisionISAPI` (the `timeZone` of `/ISAPI/System/time`), `.onvifMinimal` (ONVIF's POSIX `TZ` and daylight saving) or `.reolinkAPI`
    /// (Reolink's daylight-saving switch: `value` is "1" or "0"; `reolinkTime` the rest).
    public var method: CameraConfigMethod
    public var value: String
    /// ONVIF: its daylight-saving flag.
    public var daylightSavings: Bool?
    /// Reolink: `Time.timeZone` (as "timeZone", in the camera's own sign) and every number of `Dst` ("Dst.enable", "Dst.startMon", …) as the
    /// camera had them, written back by Restore. nil in a backup saved before 2026-10-18, which puts back only the switch.
    public var reolinkTime: [String: Int]?

    public init(method: CameraConfigMethod, value: String, daylightSavings: Bool? = nil, reolinkTime: [String: Int]? = nil) {
        self.method = method
        self.value = value
        self.daylightSavings = daylightSavings
        self.reolinkTime = reolinkTime
    }
}

/// The camera's stream settings before the setup changed them (what the HomeKit optimizer's undo keeps, saved with the configuration).
public struct CameraStreamsBackup: Sendable, Codable, Equatable {
    public var mainEncoder: CameraVideoEncoderSettings?
    public var subEncoder: CameraVideoEncoderSettings?
    public var mainOptions: [CameraVideoEncoderOptions]
    public var subOptions: [CameraVideoEncoderOptions]
    /// Hikvision: the smart codec (H.264+/H.265+) was on, and was turned off.
    public var mainSmartCodec: Bool?
    public var subSmartCodec: Bool?

    public init(mainEncoder: CameraVideoEncoderSettings? = nil, subEncoder: CameraVideoEncoderSettings? = nil, mainOptions: [CameraVideoEncoderOptions] = [],
                subOptions: [CameraVideoEncoderOptions] = [], mainSmartCodec: Bool? = nil, subSmartCodec: Bool? = nil) {
        self.mainEncoder = mainEncoder
        self.subEncoder = subEncoder
        self.mainOptions = mainOptions
        self.subOptions = subOptions
        self.mainSmartCodec = mainSmartCodec
        self.subSmartCodec = subSmartCodec
    }

    public var isEmpty: Bool { mainEncoder == nil && subEncoder == nil && mainSmartCodec == nil && subSmartCodec == nil }
}

/// A camera network feature's switch before the setup turned it off (Hikvision's UPnP, Hik-Connect; the cloud of a camera that speaks the
/// IP camera web API).
public struct CameraFeatureBackup: Sendable, Codable, Equatable {
    /// The ISAPI resource it was read from (the cloud's path varies between firmwares); the web API's read for the web API's cloud.
    public var path: String
    public var enabled: Bool
    /// IP camera web API: the cloud's `Type` and `Authcode` as the camera had them, written back with the switch. The Authcode signs the
    /// camera in to its maker's cloud: it is never encoded (the configuration goes to the page, its events and the Mac's backup file) and
    /// never logged; the engine keeps it in the platform's secret store while the backup holds the cloud, and puts it back here to
    /// restore it.
    public var cloudType: String?
    public var cloudAuthcode: String? = nil

    public init(path: String, enabled: Bool, cloudType: String? = nil, cloudAuthcode: String? = nil) {
        self.path = path
        self.enabled = enabled
        self.cloudType = cloudType
        self.cloudAuthcode = cloudAuthcode
    }

    private enum CodingKeys: String, CodingKey {
        case path, enabled, cloudType
    }
}

/// The switches of a camera's own services before the setup changed them (the IPCamera Web family: `rtsp` and `onvif` `authorized` for the
/// video password, `hik` and `meari` `on` for the extra services): service → attribute → value, as the camera had them. Only switches.
public struct CameraServiceSwitchesBackup: Sendable, Codable, Equatable {
    public var services: [String: [String: String]]

    public init(services: [String: [String: String]]) {
        self.services = services
    }
}

/// Everything the setup changed on a camera, as the camera had it before: one backup, one way back. Only the values the setup changes are
/// kept (no document with a verification code or a password); the one sign-in value, the IP camera web API cloud's Authcode
/// (`CameraFeatureBackup.cloudAuthcode`, which turning that cloud back on needs), is not encoded with it. Saved in the camera's
/// configuration.
public struct CameraSetupBackup: Sendable, Codable, Equatable {
    public var version: Int
    public var created: Date
    public var timeZone: CameraTimeZoneBackup?
    public var timeSource: CameraTimeSourceBackup?
    public var cleanPicture: CleanPictureBackup?
    public var streams: CameraStreamsBackup?
    public var upnp: CameraFeatureBackup?
    public var cloud: CameraFeatureBackup?
    public var videoPassword: CameraServiceSwitchesBackup?
    public var extraServices: CameraServiceSwitchesBackup?
    /// The camera's DNS servers before "Watch its internet" pointed them at the bridge.
    public var internetWatch: CameraDNSBackup?

    public init(version: Int, created: Date, timeZone: CameraTimeZoneBackup? = nil, timeSource: CameraTimeSourceBackup? = nil,
                cleanPicture: CleanPictureBackup? = nil, streams: CameraStreamsBackup? = nil, upnp: CameraFeatureBackup? = nil,
                cloud: CameraFeatureBackup? = nil, videoPassword: CameraServiceSwitchesBackup? = nil, extraServices: CameraServiceSwitchesBackup? = nil,
                internetWatch: CameraDNSBackup? = nil) {
        self.version = version
        self.created = created
        self.timeZone = timeZone
        self.timeSource = timeSource
        self.cleanPicture = cleanPicture
        self.streams = streams
        self.upnp = upnp
        self.cloud = cloud
        self.videoPassword = videoPassword
        self.extraServices = extraServices
        self.internetWatch = internetWatch
    }

    /// Whether this backup holds the step's original value.
    public func holds(_ step: CameraSetupStepID) -> Bool {
        switch step {
        case .timeZone: timeZone != nil
        case .timeSource: timeSource != nil
        case .internetWatch: internetWatch != nil
        case .cleanPicture: cleanPicture != nil
        case .streams: streams.map { !$0.isEmpty } ?? false
        case .videoPassword: videoPassword != nil
        case .extraServices: extraServices != nil
        case .upnp: upnp != nil
        case .cloud: cloud != nil
        }
    }

    /// The backup without the step's value (after it was restored).
    public func clearing(_ step: CameraSetupStepID) -> CameraSetupBackup {
        var copy = self
        switch step {
        case .timeZone: copy.timeZone = nil
        case .timeSource: copy.timeSource = nil
        case .internetWatch: copy.internetWatch = nil
        case .cleanPicture: copy.cleanPicture = nil
        case .streams: copy.streams = nil
        case .videoPassword: copy.videoPassword = nil
        case .extraServices: copy.extraServices = nil
        case .upnp: copy.upnp = nil
        case .cloud: copy.cloud = nil
        }
        return copy
    }

    public var isEmpty: Bool { CameraSetupStepID.allCases.allSatisfy { !holds($0) } }
}

// MARK: - Time zone

extension CameraSettingsService {
    /// The camera's time zone against `posix` (the bridge's, as a POSIX TZ string): Hikvision through ISAPI's `/ISAPI/System/time` (ONVIF
    /// when ISAPI has no clock document), Reolink through its own API (`Time.timeZone` and the `Dst` rule, `ReolinkTimeZone`: Reolink refuses
    /// ONVIF's clock to its ONVIF user), other cameras ONVIF. `zoneName` names the bridge's zone for a person. The backup is the camera's
    /// value now.
    public func readTimeZone(posix: String, zoneName: String) async throws -> (CameraSetupReading, CameraTimeZoneBackup?) {
        let target = "\(zoneName) (\(CameraSetupText.zone(posix)))"
        if vendor == .hikvision, let document = try await isapi().document(HikvisionISAPI.timePath),
           let current = HikvisionISAPI.elementText("timeZone", in: document), let wanted = HikvisionTimeZone.isapi(fromPosix: posix) {
            let backup = CameraTimeZoneBackup(method: .hikvisionISAPI, value: current)
            if HikvisionTimeZone.same(current, wanted) { return (CameraSetupReading(state: .alreadyRight), backup) }
            return (CameraSetupReading(state: .willChange, changes: [.init(label: "Time zone", now: CameraSetupText.zone(current), after: target)]), backup)
        }
        if vendor == .reolink { return try await readReolinkTimeZone(posix: posix, zoneName: zoneName, target: target) }
        guard let client = await client() else { return (.notSupported("the camera has no ONVIF device service"), nil) }
        let settings = try await client.dateTimeSettings()
        guard let current = settings.timeZone else { return (.notSupported("the camera reports no time zone"), nil) }
        let backup = CameraTimeZoneBackup(method: .onvifMinimal, value: current, daylightSavings: settings.daylightSavings)
        if current == posix || HikvisionTimeZone.same(current, posix) { return (CameraSetupReading(state: .alreadyRight), backup) }
        return (CameraSetupReading(state: .willChange, changes: [.init(label: "Time zone", now: CameraSetupText.zone(current), after: target)]), backup)
    }

    /// Puts the camera's clock in `posix`, then reads it back.
    public func applyTimeZone(posix: String) async throws -> CameraSetupOutcome {
        if vendor == .hikvision, let document = try await isapi().document(HikvisionISAPI.timePath),
           HikvisionISAPI.elementText("timeZone", in: document) != nil, let wanted = HikvisionTimeZone.isapi(fromPosix: posix) {
            return try await writeISAPITimeZone(wanted, document: document)
        }
        if vendor == .reolink { return try await applyReolinkTimeZone(posix: posix) }
        if let refusal = try await cameraTimeZoneRefusal(posix: posix) { return refusal }
        guard let client = await client(), let now = try? await client.dateTimeSettings().timeZone else {
            return CameraSetupOutcome(succeeded: true, detail: "via ONVIF")
        }
        return now == posix || HikvisionTimeZone.same(now, posix) ? CameraSetupOutcome(succeeded: true, detail: "via ONVIF")
            : .refused("the camera kept its time zone (\(CameraSetupText.zone(now)))")
    }

    /// Writes back the time zone the camera had.
    public func restoreTimeZone(_ backup: CameraTimeZoneBackup) async throws -> CameraSetupOutcome {
        switch backup.method {
        case .hikvisionISAPI:
            guard let document = try await isapi().document(HikvisionISAPI.timePath) else { return .refused("the camera no longer shows its clock settings") }
            return try await writeISAPITimeZone(backup.value, document: document)
        case .reolinkAPI:
            return try await restoreReolinkTimeZone(backup)
        case .onvifMinimal, .onvifFull:
            guard let client = await client() else { return .refused("the camera has no ONVIF device service") }
            var settings = try await client.dateTimeSettings()
            settings.timeZone = backup.value
            settings.daylightSavings = backup.daylightSavings ?? settings.daylightSavings
            do { try await client.setDateTime(settings) } catch let error as CameraAdapterError where !error.isLoginRefusal {
                return .refused(error)
            }
            return try await client.dateTimeSettings().timeZone == backup.value ? CameraSetupOutcome(succeeded: true, detail: "via ONVIF")
                : .refused("the camera did not take its old time zone back")
        case .ipcWebAPI:
            return .refused("the time zone was not saved through the web API")
        case .dahuaCGI:
            return .refused("the time zone was not saved through Dahua’s API")
        }
    }

    private func writeISAPITimeZone(_ value: String, document: String) async throws -> CameraSetupOutcome {
        guard let edited = HikvisionISAPI.settingElement("timeZone", to: value, in: document) else { return .refused("no time zone in the clock settings") }
        let answer: ISAPIWriteAnswer
        do {
            answer = try await isapi().write(HikvisionISAPI.timePath, document: Self.withoutLocalTime(edited))
        } catch let refusal as ISAPIRefusal {
            return .refused(refusal.words)
        } catch CameraAdapterError.notPermitted {
            return .notPermittedRefusal
        }
        guard let after = try await isapi().document(HikvisionISAPI.timePath), let now = HikvisionISAPI.elementText("timeZone", in: after) else {
            return CameraSetupOutcome(succeeded: true, needsRestart: answer == .rebootRequired, detail: "via ISAPI")
        }
        guard HikvisionTimeZone.same(now, value) || answer == .rebootRequired else { return .refused("the camera kept its time zone (\(CameraSetupText.zone(now)))") }
        return CameraSetupOutcome(succeeded: true, needsRestart: answer == .rebootRequired, detail: "via ISAPI")
    }
}

// MARK: - Clean picture (reading)

extension CameraSettingsService {
    /// Which labels the camera draws itself now (for the preview; `cleanPicture()` turns them off and keeps the backup). An ONVIF camera
    /// that speaks the IP camera web API is read there only (its ONVIF on-screen display answers cannot be trusted), and is not possible
    /// now when that API cannot be asked.
    public func readCleanPicture() async throws -> CameraSetupReading {
        switch try await ipcWeb() {
        case .speaks(let client, _): return try await readIPCWebCleanPicture(client)
        case .unavailable(let why): return .notSupported(why)
        case .none: break
        }
        var shown: [String] = []
        var supported = false
        if vendor == .hikvision {
            let path = HikvisionISAPI.overlaysPath(inputChannel: HikvisionISAPI.inputChannel(streamingChannelID: hikvisionChannel(isSub: false)))
            if let document = try await isapi().document(path), let tree = try? XMLTree.parse(Data(document.utf8)) {
                supported = true
                shown = Self.shownOverlays(tree)
            }
        } else if vendor == .reolink {
            if let osd = try? await reolink().command("GetOsd", param: .object(["channel": .number(Double(reolinkChannel))]))["Osd"]?.object {
                supported = true
                if osd["osdTime"]?.object?["enable"]?.int == 1 { shown.append("date and time") }
                if osd["osdChannel"]?.object?["enable"]?.int == 1 { shown.append("camera name") }
                if osd["watermark"]?.int == 1 { shown.append("logo") }
            }
        }
        if !supported, let client = await client(), let osds = try? await client.osds() {
            let texts = osds.filter { $0.type.caseInsensitiveCompare("Text") == .orderedSame }
            supported = !texts.isEmpty
            shown = texts.compactMap { osd in
                if osd.showsClock { return "date and time" }
                let plain = (try? XMLTree.parse(Data("<r xmlns:tt=\"http://www.onvif.org/ver10/schema\">\(osd.children)</r>".utf8)))?
                    .firstDescendant("PlainText")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return plain.isEmpty ? nil : "text “\(plain)”"
            }
        }
        guard supported else { return .notSupported() }
        if shown.isEmpty { return CameraSetupReading(state: .alreadyRight) }
        let unique = shown.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return CameraSetupReading(state: .willChange, changes: [.init(label: "The camera’s own labels", now: CameraSetupText.list(unique), after: "off (the bridge draws its own)")])
    }

    /// The overlays a Hikvision overlays document has switched on, in plain words.
    static func shownOverlays(_ tree: XMLTree) -> [String] {
        var shown: [String] = []
        func on(_ node: XMLTree?) -> Bool { node?.string("enabled").flatMap(ONVIFNotification.parseBool) == true }
        if on(tree.firstDescendant("DateTimeOverlay")) { shown.append("date and time") }
        if on(tree.firstDescendant("channelNameOverlay")) { shown.append("camera name") }
        if tree.descendants("TextOverlay").contains(where: on) { shown.append("text lines") }
        // Anything else switched on (a logo, a frame-rate or coordinates overlay).
        let known: Set<String> = ["DateTimeOverlay", "channelNameOverlay", "TextOverlay"]
        func others(_ node: XMLTree) -> Bool {
            node.children.contains { child in
                (!known.contains(child.name) && child.child("enabled") != nil && on(child)) || (!known.contains(child.name) && others(child))
            }
        }
        if others(tree) { shown.append("other labels") }
        return shown
    }
}

/// The setup's words for values ("UTC−7:00 with daylight saving", "H.264, 1920×1080, 20 fps, keyframe every 2 s").
public enum CameraSetupText {
    /// A POSIX or Hikvision time zone text as an offset from UTC (POSIX counts west as positive).
    public static func zone(_ text: String) -> String {
        guard let parsed = HikvisionTimeZone.parse(text) else { return text }
        let east = -parsed.standardSeconds
        let hours = abs(east) / 3600, minutes = abs(east) / 60 % 60
        let offset = east == 0 ? "UTC" : "UTC\(east < 0 ? "−" : "+")\(hours)" + (minutes == 0 ? "" : String(format: ":%02d", minutes))
        return parsed.dst == nil ? offset : "\(offset) with daylight saving"
    }

    /// "a", "a and b", "a, b and c".
    public static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return "none"
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// An encoder's settings in a person's words.
    public static func encoder(_ settings: CameraVideoEncoderSettings) -> String {
        var parts = [EncoderValues.normalizedCodec(settings.encoding) == "H265" ? "H.265" : EncoderValues.normalizedCodec(settings.encoding) == "H264" ? "H.264" : settings.encoding]
        if let size = settings.resolution { parts.append("\(size.width)×\(size.height)") }
        if let fps = settings.frameRate, fps > 0 { parts.append("\(fps.rounded() == fps ? String(Int(fps)) : String(format: "%.1f", fps)) fps") }
        if let bitrate = settings.bitrate, bitrate > 0 { parts.append(bitrate >= 1000 ? String(format: "%.1f Mbit/s", Double(bitrate) / 1000) : "\(bitrate) kbit/s") }
        if let gov = settings.iFrameInterval, gov > 0 {
            if let fps = settings.frameRate, fps > 0 {
                let seconds = Double(gov) / fps
                parts.append("keyframe every \(seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)) s")
            } else {
                parts.append("keyframe every \(gov) pictures")
            }
        }
        return parts.joined(separator: ", ")
    }
}
