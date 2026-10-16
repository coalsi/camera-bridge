import BridgeSupport
import Foundation

// "Set up for Camera Bridge" (docs/superpowers/specs/2026-10-16-camera-setup-design.md): the steps that make a camera right for the bridge, each
// read (its current value is also the backup), planned, applied, read back and restorable. This file has the shared types, the time zone
// step and the clean-picture reading; +NTP.swift the time source, +Network.swift the camera's cloud and UPnP. The streams step is the
// HomeKit optimizer's encoder changes (+Encoder.swift), planned by the engine.

/// One step of the setup, in the order the steps are applied (the clock first, the cloud last).
public enum CameraSetupStepID: String, Sendable, Codable, CaseIterable {
    case timeZone, timeSource, cleanPicture, streams, upnp, cloud
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
    }

    public var state: State
    public var changes: [CameraSetupChange]
    /// A sentence about part of the step that is not offered ("Sub stream: not offered, …").
    public var note: String?

    public init(state: State, changes: [CameraSetupChange] = [], note: String? = nil) {
        self.state = state
        self.changes = changes
        self.note = note
    }

    public static func notSupported(_ reason: String = "not supported by this camera") -> CameraSetupReading { .init(state: .notSupported(reason)) }
}

/// What applying or restoring a step did.
public struct CameraSetupOutcome: Sendable, Equatable {
    public var succeeded: Bool
    /// The camera took the change and says it applies after it restarts (ISAPI `statusCode` 7). Camera Bridge never restarts it.
    public var needsRestart: Bool
    /// "via ISAPI", or the camera's words when it refused.
    public var detail: String

    public init(succeeded: Bool, needsRestart: Bool = false, detail: String) {
        self.succeeded = succeeded
        self.needsRestart = needsRestart
        self.detail = detail
    }

    static func refused(_ words: String) -> CameraSetupOutcome { .init(succeeded: false, detail: words) }
}

/// The camera's time zone before the setup changed it.
public struct CameraTimeZoneBackup: Sendable, Codable, Equatable {
    /// `.hikvisionISAPI` (the `timeZone` of `/ISAPI/System/time`), `.onvifMinimal` (ONVIF's POSIX `TZ` and daylight saving) or `.reolinkAPI`
    /// (Reolink's daylight-saving switch: `value` is "1" or "0").
    public var method: CameraConfigMethod
    public var value: String
    /// ONVIF: its daylight-saving flag.
    public var daylightSavings: Bool?

    public init(method: CameraConfigMethod, value: String, daylightSavings: Bool? = nil) {
        self.method = method
        self.value = value
        self.daylightSavings = daylightSavings
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

/// A camera network feature's switch before the setup turned it off (Hikvision's UPnP, Hik-Connect).
public struct CameraFeatureBackup: Sendable, Codable, Equatable {
    /// The ISAPI resource it was read from (the cloud's path varies between firmwares).
    public var path: String
    public var enabled: Bool

    public init(path: String, enabled: Bool) {
        self.path = path
        self.enabled = enabled
    }
}

/// Everything the setup changed on a camera, as the camera had it before: one backup, one way back. Nothing secret is kept (no document
/// with a verification code or a password; only the values the setup changes). Saved in the camera's configuration.
public struct CameraSetupBackup: Sendable, Codable, Equatable {
    public var version: Int
    public var created: Date
    public var timeZone: CameraTimeZoneBackup?
    public var timeSource: CameraTimeSourceBackup?
    public var cleanPicture: CleanPictureBackup?
    public var streams: CameraStreamsBackup?
    public var upnp: CameraFeatureBackup?
    public var cloud: CameraFeatureBackup?

    public init(version: Int, created: Date, timeZone: CameraTimeZoneBackup? = nil, timeSource: CameraTimeSourceBackup? = nil,
                cleanPicture: CleanPictureBackup? = nil, streams: CameraStreamsBackup? = nil, upnp: CameraFeatureBackup? = nil,
                cloud: CameraFeatureBackup? = nil) {
        self.version = version
        self.created = created
        self.timeZone = timeZone
        self.timeSource = timeSource
        self.cleanPicture = cleanPicture
        self.streams = streams
        self.upnp = upnp
        self.cloud = cloud
    }

    /// Whether this backup holds the step's original value.
    public func holds(_ step: CameraSetupStepID) -> Bool {
        switch step {
        case .timeZone: timeZone != nil
        case .timeSource: timeSource != nil
        case .cleanPicture: cleanPicture != nil
        case .streams: streams.map { !$0.isEmpty } ?? false
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
        case .cleanPicture: copy.cleanPicture = nil
        case .streams: copy.streams = nil
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
    /// when ISAPI has no clock document), Reolink its daylight-saving switch (its own API: Reolink refuses ONVIF's clock to its ONVIF
    /// user), other cameras ONVIF. `zoneName` names the bridge's zone for a person. The backup is the camera's value now.
    public func readTimeZone(posix: String, zoneName: String) async throws -> (CameraSetupReading, CameraTimeZoneBackup?) {
        let target = "\(zoneName) (\(CameraSetupText.zone(posix)))"
        if vendor == .hikvision, let document = try await isapi().document(HikvisionISAPI.timePath),
           let current = HikvisionISAPI.elementText("timeZone", in: document), let wanted = HikvisionTimeZone.isapi(fromPosix: posix) {
            let backup = CameraTimeZoneBackup(method: .hikvisionISAPI, value: current)
            if HikvisionTimeZone.same(current, wanted) { return (CameraSetupReading(state: .alreadyRight), backup) }
            return (CameraSetupReading(state: .willChange, changes: [.init(label: "Time zone", now: CameraSetupText.zone(current), after: target)]), backup)
        }
        if vendor == .reolink {
            let api = ReolinkAPI(endpoint: endpoint, credentials: credentials, channel: reolinkChannel, cameraID: cameraID)
            defer { Task { await api.logout() } }
            guard let enable = try await api.command("GetTime")["Dst"]?.object?["enable"]?.int else {
                return (.notSupported("the camera reports no daylight saving"), nil)
            }
            let wanted = PosixTimeZone.hasDaylightSaving(posix)
            let backup = CameraTimeZoneBackup(method: .reolinkAPI, value: enable != 0 ? "1" : "0")
            if (enable != 0) == wanted { return (CameraSetupReading(state: .alreadyRight), backup) }
            let words = { (on: Bool) in on ? "daylight saving on" : "daylight saving off" }
            return (CameraSetupReading(state: .willChange, changes: [.init(label: "Time zone", now: words(enable != 0), after: "\(words(wanted)), as \(zoneName)")]), backup)
        }
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
        if let failure = try await setCameraTimeZone(posix: posix) { return .refused(failure) }
        guard vendor != .reolink else { return CameraSetupOutcome(succeeded: true, detail: "via Reolink API") }
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
            if let failure = try await setReolinkDaylightSaving(backup.value == "1") { return .refused(failure) }
            return CameraSetupOutcome(succeeded: true, detail: "via Reolink API")
        case .onvifMinimal, .onvifFull:
            guard let client = await client() else { return .refused("the camera has no ONVIF device service") }
            var settings = try await client.dateTimeSettings()
            settings.timeZone = backup.value
            settings.daylightSavings = backup.daylightSavings ?? settings.daylightSavings
            do { try await client.setDateTime(settings) } catch let error as CameraAdapterError where !error.isLoginRefusal {
                return .refused(Redact.string(String(describing: error)))
            }
            return try await client.dateTimeSettings().timeZone == backup.value ? CameraSetupOutcome(succeeded: true, detail: "via ONVIF")
                : .refused("the camera did not take its old time zone back")
        }
    }

    private func writeISAPITimeZone(_ value: String, document: String) async throws -> CameraSetupOutcome {
        guard let edited = HikvisionISAPI.settingElement("timeZone", to: value, in: document) else { return .refused("no time zone in the clock settings") }
        let answer: ISAPIWriteAnswer
        do { answer = try await isapi().write(HikvisionISAPI.timePath, document: Self.withoutLocalTime(edited)) } catch let refusal as ISAPIRefusal { return .refused(refusal.words) }
        guard let after = try await isapi().document(HikvisionISAPI.timePath), let now = HikvisionISAPI.elementText("timeZone", in: after) else {
            return CameraSetupOutcome(succeeded: true, needsRestart: answer == .rebootRequired, detail: "via ISAPI")
        }
        guard HikvisionTimeZone.same(now, value) || answer == .rebootRequired else { return .refused("the camera kept its time zone (\(CameraSetupText.zone(now)))") }
        return CameraSetupOutcome(succeeded: true, needsRestart: answer == .rebootRequired, detail: "via ISAPI")
    }
}

// MARK: - Clean picture (reading)

extension CameraSettingsService {
    /// Which labels the camera draws itself now (for the preview; `cleanPicture()` turns them off and keeps the backup).
    public func readCleanPicture() async throws -> CameraSetupReading {
        var shown: [String] = []
        var supported = false
        if vendor == .hikvision {
            let path = HikvisionISAPI.overlaysPath(inputChannel: HikvisionISAPI.inputChannel(streamingChannelID: hikvisionChannel(isSub: false)))
            if let document = try await isapi().document(path), let tree = try? XMLTree.parse(Data(document.utf8)) {
                supported = true
                shown = Self.shownOverlays(tree)
            }
        } else if vendor == .reolink {
            let api = ReolinkAPI(endpoint: endpoint, credentials: credentials, channel: reolinkChannel, cameraID: cameraID)
            defer { Task { await api.logout() } }
            if let osd = try? await api.command("GetOsd", param: .object(["channel": .number(Double(reolinkChannel))]))["Osd"]?.object {
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
