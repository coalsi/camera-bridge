import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore

// The JSON the API answers with. Types follow the Mac app's models (`CameraConfiguration`, `CameraStatus`, `DiscoveredCamera`,
// `NetworkNotice`); the words are the Mac app's too (`StatusText`), so the two interfaces say the same things.

/// Names and sentences for engine values, as the Mac app's `StatusText` words them.
enum StatusText {
    static func connectionName(_ state: ConnectionState) -> String {
        switch state {
        case .online: "online"
        case .connecting: "connecting"
        case .idle: "idle"
        case .disabled: "disabled"
        case .offline: "offline"
        }
    }

    static func connectionReason(_ state: ConnectionState) -> String? {
        if case .offline(let reason) = state, !reason.isEmpty { return Redact.string(reason) }
        return nil
    }

    /// "Live", "Connecting…", "Offline — the connection was refused".
    static func connection(_ state: ConnectionState) -> String {
        switch state {
        case .online: "Live"
        case .connecting: "Connecting…"
        case .idle: "Idle"
        case .disabled: "Disabled"
        case .offline(let reason): reason.isEmpty ? "Offline" : "Offline — \(Redact.string(reason))"
        }
    }

    /// Short status: "Live · Recording", "Offline — retrying", "Connecting…".
    static func summary(for camera: CameraStatus) -> String {
        switch camera.connection {
        case .online:
            var parts = ["Live"]
            if camera.recordingNow {
                parts.append("Recording")
            } else if camera.motionActive {
                parts.append("Motion")
            }
            let viewers = camera.liveViewers + camera.appViewers
            if viewers > 0 { parts.append(viewers == 1 ? "1 Viewer" : "\(viewers) Viewers") }
            if !camera.isPaired { parts.append("Not Paired") }
            return parts.joined(separator: " · ")
        case .offline: return "Offline — retrying"
        case .connecting: return "Connecting…"
        case .idle: return "Idle"
        case .disabled: return "Disabled"
        }
    }

    static func engineState(_ state: EngineState) -> String {
        switch state {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .paused: "Paused"
        case .failed(let reason): "Error — \(Redact.string(reason))"
        }
    }

    static func engineStateName(_ state: EngineState) -> String {
        switch state {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .paused: "paused"
        case .failed: "failed"
        }
    }

    static func vendor(_ vendor: CameraVendor) -> String {
        switch vendor {
        case .hikvision: "Hikvision"
        case .reolink: "Reolink"
        case .onvif: "ONVIF"
        case .rtsp: "RTSP"
        case .amcrest: "Amcrest / Dahua"
        case .doorbird: "DoorBird"
        case .unifi: "UniFi Protect"
        case .go2rtc: "Cloud camera"
        case .demo: "Demo"
        }
    }

    static func kind(_ kind: CameraKind) -> String {
        kind == .camera ? "Camera" : "Video Doorbell"
    }

    /// Apple Home setup codes display as `XXX-XX-XXX`; anything that isn't eight digits is shown unchanged.
    static func setupCode(_ raw: String) -> String {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        let separatorsOnly = raw.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "-" || $0 == " " }
        guard digits.count == 8, separatorsOnly else { return raw }
        let chars = Array(digits)
        return "\(String(chars[0..<3]))-\(String(chars[3..<5]))-\(String(chars[5..<8]))"
    }

    static func videoCodec(_ codec: VideoCodec) -> String {
        switch codec {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }

    static func audioCodec(_ codec: AudioCodec) -> String {
        switch codec {
        case .aac: "AAC"
        case .aacELD: "AAC-ELD"
        case .opus: "Opus"
        case .pcmu: "G.711 µ-law"
        case .pcma: "G.711 A-law"
        case .linearPCM: "PCM"
        }
    }

    /// "H.264 1920×1080 · 20 fps · AAC 16 kHz".
    static func stream(_ info: StreamInfo) -> String {
        var parts: [String] = []
        var video: [String] = []
        if let codec = info.videoCodec { video.append(videoCodec(codec)) }
        if let width = info.width, let height = info.height { video.append("\(width)×\(height)") }
        if !video.isEmpty { parts.append(video.joined(separator: " ")) }
        if let fps = info.fps, fps.isFinite, fps > 0 { parts.append("\(trimmed(fps)) fps") }
        if let audio = info.audioCodec {
            var text = audioCodec(audio)
            if let rate = info.audioSampleRate, rate > 0 { text += " \(trimmed(Double(rate) / 1_000)) kHz" }
            parts.append(text)
        }
        return parts.isEmpty ? "Unknown format" : parts.joined(separator: " · ")
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        var result = text
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }

    static func motionSource(_ source: MotionSource) -> String {
        switch source {
        case .cameraEvents: "Camera Events"
        case .softMotion: "Built-in Motion Detection"
        case .webhook: "Webhook"
        }
    }

    static func motionSourceDetail(_ source: MotionSource) -> String {
        switch source {
        case .cameraEvents: "Uses the camera’s own motion detection."
        case .softMotion: "Camera Bridge compares frames from the camera’s sub stream."
        case .webhook: "Another system reports motion to Camera Bridge’s webhook."
        }
    }
}

// MARK: - Camera

struct StreamInfoResource: Encodable {
    var codec: String
    var width: Int
    var height: Int
    var fps: Double?
    var bitrateKbps: Int?

    init(_ info: SourceStreamInfo) {
        codec = info.codec
        width = info.width
        height = info.height
        fps = info.fps.flatMap { $0.isFinite ? $0 : nil }
        bitrateKbps = info.bitrateKbps
    }
}

struct LiveSessionResource: Encodable {
    var usesSubStream: Bool
    var isPassthrough: Bool
    var width: Int?
    var height: Int?
    var fps: Int?
    var bitrateKbps: Int?
    var health: String?
    var endReason: String?

    init(_ session: LiveSessionStatus) {
        usesSubStream = session.usesSubStream
        isPassthrough = session.isPassthrough
        width = session.resolution?.width
        height = session.resolution?.height
        fps = session.resolution?.fps
        bitrateKbps = session.bitrateKbps
        health = session.health.map { Redact.string($0) }
        endReason = session.endReason.map { Redact.string($0) }
    }
}

struct RecordingSessionResource: Encodable {
    var usesSubStream: Bool
    var isPassthrough: Bool?
    var width: Int?
    var height: Int?
    var bitrateKbps: Int?

    init(_ session: RecordingSessionStatus) {
        usesSubStream = session.usesSubStream
        isPassthrough = session.isPassthrough
        width = session.resolution?.width
        height = session.resolution?.height
        bitrateKbps = session.bitrateKbps
    }
}

struct EventResource: Encodable {
    var name: String
    var date: Date
}

/// A camera's live state: what the Mac app's camera page and menu show. The HomeKit setup code is not part of it (`/pairing`).
struct CameraStatusResource: Encodable {
    var connection: String
    var connectionReason: String?
    var summary: String
    var eventChannelConnected: Bool
    var videoSummary: String?
    var paired: Bool
    var hapPort: UInt16?
    var motion: Bool
    var recordingEnabled: Bool
    var recordingNow: Bool
    var liveViewers: Int
    var appViewers: Int
    /// The camera pans and tilts (`POST cameras/:id/pan-tilt`).
    var panTilt: Bool
    /// The camera zooms (`POST cameras/:id/pan-tilt {zoom}`).
    var zoom: Bool
    /// The camera's night vision and lamp (`POST cameras/:id/night-vision`); absent when the bridge can't switch them.
    var nightVision: NightVisionResource?
    var lastEvent: String?
    var lastEventDate: Date?
    var lastError: String?
    var recentEvents: [EventResource]
    var subStreamProblem: String?
    var liveSessions: [LiveSessionResource]
    var recordingSession: RecordingSessionResource?
    var mainStreamInfo: StreamInfoResource?
    var subStreamInfo: StreamInfoResource?
    var eventsNote: String?
    var homeKitNote: String?
    /// The NVR recording of this camera; always present.
    var nvr: NVRStatusResource
    /// A battery camera's charge (absent for a camera without a battery, or before the first reading).
    var battery: BatteryResource?
    /// The camera's security level (absent until its first check; `POST cameras/:id/security/check`).
    var security: CameraSecurityResource?

    init(_ status: CameraStatus) {
        connection = StatusText.connectionName(status.connection)
        connectionReason = StatusText.connectionReason(status.connection)
        summary = StatusText.summary(for: status)
        eventChannelConnected = status.eventChannelConnected
        videoSummary = status.videoSummary
        paired = status.isPaired
        hapPort = status.hapPort
        motion = status.motionActive
        recordingEnabled = status.recordingEnabled
        recordingNow = status.recordingNow
        liveViewers = status.liveViewers
        appViewers = status.appViewers
        panTilt = status.panTilt
        zoom = status.zoom
        nightVision = status.nightVision.map {
            NightVisionResource(modes: $0.modes.map(\.rawValue), mode: $0.mode?.rawValue, light: $0.light, lightOn: $0.lightOn)
        }
        lastEvent = status.lastEvent
        lastEventDate = status.lastEventDate
        lastError = status.lastError.map { Redact.string($0) }
        recentEvents = status.recentEvents.map { EventResource(name: $0.name, date: $0.date) }
        subStreamProblem = status.subStreamProblem.map { Redact.string($0) }
        liveSessions = status.liveSessions.map(LiveSessionResource.init)
        recordingSession = status.recordingSession.map(RecordingSessionResource.init)
        mainStreamInfo = status.mainStreamInfo.map(StreamInfoResource.init)
        subStreamInfo = status.subStreamInfo.map(StreamInfoResource.init)
        eventsNote = status.eventsNote
        homeKitNote = status.homeKitNote
        nvr = NVRStatusResource(status.nvr)
        battery = status.battery.map(BatteryResource.init)
        security = status.security.map(CameraSecurityResource.init)
    }
}

/// `CameraStatus.security`: `level` red, yellow, green or gold, its `title` and `summary`, when it was checked, and the `findings` worst first,
/// each `{feature, state, level, sentence, canChange, linked, service, manualHelp}` (`feature`: cloud, upnp, ddns, rtmp, unauthenticatedVideo,
/// extraService, internetGuard; `state`: on, off, absent, unknown; `linked` and `service` null when the camera does not say; `manualHelp`,
/// "Change it by hand" (`CameraManualHelp`), null where there is none), and `guard`,
/// what the internet guard saw (`{watched, today, last24h, names: [{name, count, first, last}]}`, the 10 most asked names of the last 7 days,
/// `first` and `last` null when the box does not say; null on a bridge without the guard). Every key is always there.
struct CameraSecurityResource: Encodable {
    struct Finding: Encodable {
        var feature: String
        var state: String
        var level: String
        var sentence: String
        var canChange: Bool
        var linked: OrNull<Bool>
        var service: OrNull<String>
        var manualHelp: OrNull<CameraManualHelp>
    }

    struct Guard: Encodable, Sendable {
        struct Name: Encodable, Sendable {
            var name: String
            var count: Int
            var first: OrNull<Date>
            var last: OrNull<Date>
        }

        var watched: Bool
        var today: Int
        var last24h: Int
        var last7d: Int
        var names: [Name]
    }

    var level: String
    var title: String
    var summary: String
    var checkedAt: Date
    var findings: [Finding]
    var `guard`: OrNull<Guard>

    init(_ security: CameraSecurity) {
        level = security.level.rawValue
        title = security.title
        summary = security.summary
        checkedAt = security.checkedAt
        findings = security.findings.map {
            Finding(feature: $0.feature.rawValue, state: $0.state.rawValue, level: $0.level.rawValue, sentence: Redact.string($0.sentence),
                    canChange: $0.canChange, linked: OrNull($0.linked), service: OrNull($0.service), manualHelp: OrNull($0.manualHelp))
        }
        `guard` = OrNull(security.internetGuard.map { activity in
            Guard(watched: activity.watched, today: activity.today, last24h: activity.last24h, last7d: activity.last7d,
                  names: activity.names.map { Guard.Name(name: $0.name, count: $0.count, first: OrNull($0.first), last: OrNull($0.last)) })
        })
    }
}

/// `CameraStatus.battery`: `level` 0–100, `charging`, `source` `solar`, `cable` or null (not charging, or the camera doesn't say). Every key
/// is always there.
struct BatteryResource: Encodable {
    var level: Int
    var charging: Bool
    var source: OrNull<String>

    init(_ battery: BatteryStatus) {
        level = battery.level
        charging = battery.charging
        source = OrNull(battery.source?.rawValue)
    }
}

/// `CameraStatus.nvr` as the page reads it: `state` is off, waiting, recording or paused; `detail` the sentence under it; `pause` why recording
/// is paused (`ArchivePause.code`); `notes` the lines that last ("sound could not be recorded", "keyframe every N s: scrubbing is slow"). Every key
/// is always there.
struct NVRStatusResource: Encodable {
    struct Note: Encodable {
        var id: String
        var text: String
    }

    var state: String
    var detail: OrNull<String>
    var pause: OrNull<String>
    var notes: [Note]

    init(_ status: CameraArchiveStatus) {
        switch status.state {
        case .off: (state, pause) = ("off", OrNull(nil))
        case .waiting: (state, pause) = ("waiting", OrNull(nil))
        case .recording: (state, pause) = ("recording", OrNull(nil))
        case .paused(let reason): (state, pause) = ("paused", OrNull(reason.code))
        }
        detail = OrNull(status.detail.map { Redact.string($0) })
        notes = status.notes.map { Note(id: $0.id.rawValue, text: Redact.string($0.text)) }
    }
}

/// One camera: its configuration (`CameraConfiguration`, as saved, without any password; with the engine-owned `setupState`, `setupBackup`
/// and `dnsWatch`) with its `status`, display names, `internetWatched`: the Internet guard watches it (`BridgeEngine.internetWatchDone`:
/// its DNS points at the bridge as the newest of the setup's result and the guard's readings says), and `restartOffered`: "Restart the
/// camera now" is offered, the camera waits for a restart to apply a change it took (`BridgeEngine.offersCameraRestart`), both always there.
struct CameraResource: Encodable {
    var configuration: CameraConfiguration
    var status: CameraStatusResource?

    private enum ExtraKeys: String, CodingKey {
        case status, vendorName, kindName, motionSourceName, address, typeID, internetWatched, restartOffered
    }

    func encode(to encoder: any Encoder) throws {
        try configuration.encode(to: encoder)
        var container = encoder.container(keyedBy: ExtraKeys.self)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(StatusText.vendor(configuration.vendor), forKey: .vendorName)
        try container.encode(StatusText.kind(configuration.kind), forKey: .kindName)
        try container.encode(StatusText.motionSource(configuration.motionSource), forKey: .motionSourceName)
        try container.encode(Self.address(of: configuration), forKey: .address)
        try container.encode(BridgeEngine.internetWatchDone(configuration), forKey: .internetWatched)
        try container.encode(BridgeEngine.offersCameraRestart(configuration), forKey: .restartOffered)
    }

    /// Where the camera is: its host, or for a camera behind a service the service's name.
    static func address(of configuration: CameraConfiguration) -> String {
        switch configuration.vendor {
        case .demo: return "Test pattern"
        case .go2rtc: return configuration.integration?.service.displayName ?? "Cloud camera"
        case .unifi: return configuration.endpoint.host
        default: return configuration.endpoint.host
        }
    }
}

// MARK: - Bridge

struct NoticeResource: Encodable {
    var id: String
    var kind: String
    var severity: String
    var title: String
    var detail: String
    var cameraID: UUID?
    var cameraName: String?
    var date: Date
    /// What the notice's button does: "choose-folder" (the storage chooser), "open-settings" (Settings > Recording) or "open-camera" (the page
    /// of the notice's `cameraID`); nil for a notice with no button. Always encoded, as null when nil (a page that does not know the field
    /// ignores it).
    var action: String?
    /// Where the notification page files it: "security", "recording", "cameras" or "system" (by `kind`).
    var category: String {
        switch kind {
        case "internetGuard": "security"
        case "nvrStorage": "recording"
        case "liveViewNotReceived": "cameras"
        default: "system"
        }
    }

    /// What the notice says, as the key the notification log tells one happening from another by: another title or camera is a new thing,
    /// other figures in the text (the free gigabytes) are not.
    var key: String { "\(id)|\(title)|\(cameraID?.uuidString ?? "")" }

    private enum CodingKeys: String, CodingKey { case id, kind, severity, title, detail, cameraID, cameraName, date, action, category, key }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(severity, forKey: .severity)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encodeIfPresent(cameraID, forKey: .cameraID)
        try container.encodeIfPresent(cameraName, forKey: .cameraName)
        try container.encode(date, forKey: .date)
        try container.encode(action, forKey: .action)
        try container.encode(category, forKey: .category)
        try container.encode(key, forKey: .key)
    }

    /// Everything that is a notification now: the network notices (below), at most one storage notice, first, and what the internet guard
    /// found, last. This is what the status answer, the event stream's snapshot, its change detection and the notification log all use.
    static func resources(for overview: BridgeOverview, now: Date = Date()) -> [NoticeResource] {
        var notices = resources(for: overview.networkNotices, now: now)
        if let storage = storageNotice(for: overview, now: now) { notices.insert(storage, at: 0) }
        notices += overview.internetGuardAlerts.map(internetGuardNotice)
        return notices
    }

    /// "Patio New tried to reach the internet": information, with a button to the camera's page at its Security card (`action` "open-camera");
    /// a warning for a camera the guard can no longer watch.
    static func internetGuardNotice(_ alert: InternetGuardAlert) -> NoticeResource {
        NoticeResource(id: alert.id, kind: "internetGuard", severity: alert.isWarning ? "warning" : "info", title: alert.title, detail: alert.detail,
                       cameraID: alert.cameraID, cameraName: alert.cameraName, date: alert.date, action: "open-camera")
    }

    /// "Recording Can't Continue" when recording is paused (or no folder is chosen), else "Recording Storage Almost Full" when less than
    /// `ArchiveConstants.lowSpaceMarginBytes` is left above the floor; nil when no camera records or all is well. The low-space figure is whole
    /// decimal gigabytes (rounded down), so the notice's text, which the event stream compares, changes at most once per gigabyte.
    static func storageNotice(for overview: BridgeOverview, now: Date) -> NoticeResource? {
        guard overview.configurations.contains(where: \.nvrEnabled) else { return nil }
        let pause: ArchivePause? = overview.settings.nvrFolder == nil ? .noFolder : overview.nvrStorage?.pause
        if let pause {
            return NoticeResource(id: "nvr-storage", kind: "nvrStorage", severity: "warning", title: "Recording Can’t Continue",
                                  detail: Redact.string(pause.readable), cameraID: nil, cameraName: nil, date: now,
                                  action: pause == .noFolder ? "choose-folder" : "open-settings")
        }
        guard let storage = overview.nvrStorage, storage.totalBytes > 0, storage.spareBytes < ArchiveConstants.lowSpaceMarginBytes else { return nil }
        return NoticeResource(id: "nvr-storage", kind: "nvrStorage", severity: "warning", title: "Recording Storage Almost Full",
                              detail: "About \(storage.spareBytes / ArchiveConstants.gigabyte) GB are left before recording pauses.", cameraID: nil, cameraName: nil,
                              date: now, action: "open-settings")
    }

    /// The notices that apply and have something to say (the Mac app's `NetworkNoticeMessage`, in this bridge's words).
    static func resources(for notices: [NetworkNotice], now: Date = Date()) -> [NoticeResource] {
        notices.filter { $0.isActive(at: now) }.compactMap { make(for: $0) }.sorted {
            $0.severity != $1.severity ? $0.severity == "warning" : $0.date > $1.date
        }
    }

    private static func make(for notice: NetworkNotice) -> NoticeResource? {
        let who = notice.cameraName.map { "An iPhone or iPad watching \($0)" } ?? "An iPhone or iPad watching a camera"
        switch notice.kind {
        case .macOnVPN:
            return nil
        case .localNetworkDenied:
            return nil
        case .liveViewNotReceived:
            if notice.delivery == .reached { return nil }
            return NoticeResource(
                id: notice.id, kind: notice.kind.rawValue, severity: "warning", title: "Live View Did Not Reach a Device",
                detail: "\(who) answered Camera Bridge but never received the video, so Camera Bridge ended that live view for Home to try again, sending a different way each time. If it keeps happening, make sure the device is on the same network as this bridge (not a guest network), turn off any VPN on the device, and check your router for “client isolation” or “AP isolation”.",
                cameraID: notice.cameraID, cameraName: notice.cameraName, date: notice.date)
        case .dualHomedSubnet:
            let interfaces = notice.interfaceName ?? "two network connections"
            let subnet = notice.detail.map { " (\($0))" } ?? ""
            return NoticeResource(
                id: notice.id, kind: notice.kind.rawValue, severity: "info", title: "This Bridge Is on Your Network Twice",
                detail: "\(interfaces) are connected to the same network\(subnet), usually Ethernet and Wi-Fi at once. Camera Bridge sends live video from the address the Home device connected to, but unplugging one of them is more reliable.",
                cameraID: nil, cameraName: nil, date: notice.date)
        case .controllerOnVPN:
            if !notice.usedFallback, notice.delivery == .reached { return nil }
            let failed = notice.delivery == .failed
            let advertised = notice.advertisedAddress ?? "an address outside this network"
            var detail: String
            if failed {
                detail = "Live view to a device on a VPN failed — turn off the VPN on that device. "
                if notice.usedFallback, let peer = notice.peerAddress {
                    detail += "\(who) asked for video at \(advertised); Camera Bridge sent it to \(peer) instead, but nothing came back."
                } else {
                    detail += "\(who) asked for video at \(advertised), which isn’t on this network, and nothing came back."
                }
            } else if notice.usedFallback, let peer = notice.peerAddress {
                detail = "\(who) seems to be on a VPN (asked for video at \(advertised)). Camera Bridge sent it to \(peer) instead. If live view still doesn’t load, turn off the VPN on that device or allow local network access in the VPN app."
            } else {
                detail = "\(who) seems to be on a VPN (asked for video at \(advertised), which isn’t on this network). If live view doesn’t load, turn off the VPN on that device or allow local network access in the VPN app."
            }
            return NoticeResource(
                id: notice.id, kind: notice.kind.rawValue, severity: failed ? "warning" : "info",
                title: failed ? "Live View to a Device on a VPN Failed" : "A Device Watching Live View Is on a VPN", detail: detail,
                cameraID: notice.cameraID, cameraName: notice.cameraName, date: notice.date)
        }
    }
}

/// Bridge-wide settings the page edits (`BridgeSettings` plus the name the web interface keeps).
struct SettingsResource: Encodable {
    var bridgeName: String
    var basePort: UInt16
    var sensorsBridgePort: UInt16
    var webhookEnabled: Bool
    var webhookPort: UInt16
    var webhookToken: String
    var webhookProblem: String?
    var logLevel: String
    var motionShadowTest: Bool
    var timeZone: String?
    /// The cameras' ids in the order the person chose, stale ids left out (`BridgeSettings.cameraOrder`).
    var cameraOrder: [UUID]
    /// The AI description settings, with whether a key is saved and its last four characters (never the key).
    var ai: AISettingsResource

    init(settings: BridgeSettings, cameras: [CameraConfiguration] = [], bridgeName: String, webhookProblem: String?, aiKey: (saved: Bool, hint: String?), aiStatus: AIStatus) {
        self.bridgeName = bridgeName
        basePort = settings.basePort
        sensorsBridgePort = settings.sensorsBridgePort
        webhookEnabled = settings.webhookEnabled
        webhookPort = settings.webhookPort
        webhookToken = settings.webhookToken
        self.webhookProblem = webhookProblem
        logLevel = Self.levelName(settings.logLevel)
        motionShadowTest = settings.motionShadowTest
        timeZone = settings.timeZone
        let known = Set(cameras.map(\.id))
        cameraOrder = settings.cameraOrder.filter { known.contains($0) }
        ai = AISettingsResource(settings.ai, key: aiKey, status: aiStatus)
    }

    static func levelName(_ level: LogLevel) -> String {
        DiagnosticsLog.levelName(level).lowercased()
    }

    static func level(named name: String) -> LogLevel? {
        LogLevel.allCases.first { levelName($0) == name.lowercased() }
    }
}

struct DiscoveredResource: Encodable {
    var host: String
    var name: String?
    var hardware: String?
    var onvifPort: Int?
    var alreadyAdded: Bool
    /// SADP found it on none of the box's networks: the page shows this card instead of a choice (`NotSetUpText.otherNetwork`).
    var otherNetwork: WebApp.OtherNetworkResource?
    /// SADP says it has no admin password yet (and it is on the home network): the page shows the not-set-up card.
    var notSetUp: WebApp.NotSetUpResource?

    init(_ camera: DiscoveredCamera, configurations: [CameraConfiguration]) {
        host = camera.host
        name = camera.name
        hardware = camera.hardware
        onvifPort = camera.xAddrs.first { $0.scheme?.lowercased() == "http" }?.port
        alreadyAdded = configurations.contains { $0.vendor != .demo && $0.endpoint.host.caseInsensitiveCompare(camera.host) == .orderedSame }
        if camera.onAnotherNetwork == true {
            otherNetwork = NotSetUpText.otherNetwork(address: camera.host)
        } else if camera.activated == false, !alreadyAdded {
            notSetUp = NotSetUpText.resource(NotSetUp(maker: "Hikvision", vendor: .hikvision),
                                             endpoint: CameraEndpoint(host: camera.host, httpPort: camera.httpPort ?? 80))
        }
    }
}

struct LogLineResource: Encodable {
    var id: UUID
    var date: Date
    var level: String
    var category: String
    var message: String
    var cameraID: UUID?

    init(_ entry: LogEntry) {
        id = entry.id
        date = entry.date
        level = SettingsResource.levelName(entry.level)
        category = entry.category
        message = Redact.string(entry.message)
        cameraID = entry.cameraID
    }
}

struct PairingResource: Encodable {
    var accessoryName: String
    var paired: Bool
    var setupCode: String?
    var setupURI: String?
    var qrSVG: String?
    /// Why no code is offered (the Home app could not find the accessory), nil when it is.
    var blocker: String?
    var blockerMessage: String?
    /// What fixes it from the same page: "resume" or "start".
    var blockerAction: String?
}

/// Why a camera's QR code and setup code aren't offered, and the fix (the Mac app's `PairingBlocker`).
enum PairingBlocker: String {
    case cameraDisabled, bridgePaused, bridgeNotRunning, bridgeStarting, accessoryNotRunning

    static func current(state: EngineState, isEnabled: Bool, hapPort: UInt16?) -> PairingBlocker? {
        guard isEnabled else { return .cameraDisabled }
        switch state {
        case .paused: return .bridgePaused
        case .stopped, .failed: return .bridgeNotRunning
        case .starting: return .bridgeStarting
        case .running: return hapPort == nil ? .accessoryNotRunning : nil
        }
    }

    var message: String {
        switch self {
        case .cameraDisabled: "This camera is turned off, so the Home app can’t find it. Turn it on to add it."
        case .bridgePaused: "The bridge is paused, so the Home app can’t find this accessory. Resume the bridge to add it."
        case .bridgeNotRunning: "The bridge isn’t running, so the Home app can’t find this accessory. Start the bridge to add it."
        case .bridgeStarting: "The bridge is starting. The code appears once this accessory is published."
        case .accessoryNotRunning: "This camera’s accessory isn’t running, so the Home app can’t find it. The camera’s status and log show why."
        }
    }

    var action: String? {
        switch self {
        case .bridgePaused: "resume"
        case .bridgeNotRunning: "start"
        default: nil
        }
    }
}

struct NightVisionResource: Encodable {
    var modes: [String]
    var mode: String?
    var light: Bool
    var lightOn: Bool?
}
