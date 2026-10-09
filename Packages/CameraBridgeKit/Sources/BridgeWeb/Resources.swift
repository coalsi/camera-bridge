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
    }
}

/// One camera: its configuration (`CameraConfiguration`, as saved, without any password) with its `status` and display names.
struct CameraResource: Encodable {
    var configuration: CameraConfiguration
    var status: CameraStatusResource?

    private enum ExtraKeys: String, CodingKey {
        case status, vendorName, kindName, motionSourceName, address, typeID
    }

    func encode(to encoder: any Encoder) throws {
        try configuration.encode(to: encoder)
        var container = encoder.container(keyedBy: ExtraKeys.self)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(StatusText.vendor(configuration.vendor), forKey: .vendorName)
        try container.encode(StatusText.kind(configuration.kind), forKey: .kindName)
        try container.encode(StatusText.motionSource(configuration.motionSource), forKey: .motionSourceName)
        try container.encode(Self.address(of: configuration), forKey: .address)
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

    init(settings: BridgeSettings, bridgeName: String, webhookProblem: String?) {
        self.bridgeName = bridgeName
        basePort = settings.basePort
        sensorsBridgePort = settings.sensorsBridgePort
        webhookEnabled = settings.webhookEnabled
        webhookPort = settings.webhookPort
        webhookToken = settings.webhookToken
        self.webhookProblem = webhookProblem
        logLevel = Self.levelName(settings.logLevel)
        motionShadowTest = settings.motionShadowTest
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

    init(_ camera: DiscoveredCamera, configurations: [CameraConfiguration]) {
        host = camera.host
        name = camera.name
        hardware = camera.hardware
        onvifPort = camera.xAddrs.first { $0.scheme?.lowercased() == "http" }?.port
        alreadyAdded = configurations.contains { $0.vendor != .demo && $0.endpoint.host.caseInsensitiveCompare(camera.host) == .orderedSame }
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
