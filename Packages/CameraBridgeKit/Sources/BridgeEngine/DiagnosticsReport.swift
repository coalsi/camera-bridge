import BridgeSupport
import Foundation

/// Where the report runs: the app and the system (filled in by the app, which knows its bundle).
public struct DiagnosticsContext: Sendable, Equatable {
    public var appName: String
    public var appVersion: String
    public var appBuild: String
    public var macOSVersion: String
    /// "Mac15,3"-style model identifier.
    public var macModel: String
    public var architecture: String
    /// Seconds since the Mac booted.
    public var systemUptime: TimeInterval
    /// Seconds since CameraBridge launched.
    public var processUptime: TimeInterval
    public var generated: Date
    public var locale: String

    public init(appName: String = "Camera Bridge", appVersion: String, appBuild: String, macOSVersion: String, macModel: String, architecture: String,
                systemUptime: TimeInterval, processUptime: TimeInterval, generated: Date = Date(), locale: String = Locale.current.identifier) {
        self.appName = appName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.macOSVersion = macOSVersion
        self.macModel = macModel
        self.architecture = architecture
        self.systemUptime = systemUptime
        self.processUptime = processUptime
        self.generated = generated
        self.locale = locale
    }

    /// The running system. `macModel`: the model identifier ("Mac15,3": the app reads `hw.model`, which this portable module
    /// does not); `launched`: when the app started (for the process uptime).
    public static func current(appVersion: String, appBuild: String, macModel: String, launched: Date) -> DiagnosticsContext {
        let info = ProcessInfo.processInfo
        return DiagnosticsContext(appVersion: appVersion, appBuild: appBuild, macOSVersion: info.operatingSystemVersionString,
                                  macModel: macModel, architecture: architectureName(), systemUptime: info.systemUptime,
                                  processUptime: Date().timeIntervalSince(launched))
    }

    private static func architectureName() -> String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

/// The text bundle the owner sends when something does not work: app and system facts, every camera's summary (vendor,
/// model, firmware, stream formats, status, recent errors, live and recording session history with phase timings), the
/// engine settings and the diagnostics log at debug level. Nothing secret goes in: passwords, tokens, URL credentials and
/// RTSP query tokens are redacted (`Redact`) in the log and again over the finished text; the HomeKit setup code, the
/// webhook token and serial numbers are left out altogether. Camera and network addresses on the LAN are included (they
/// say how the cameras are reached).
public enum DiagnosticsReport {
    /// The log lines at the end of the report, newest last.
    public static let defaultMaximumLogLines = 10_000

    public static func render(context: DiagnosticsContext, state: EngineState, localNetwork: LocalNetworkAccess, settings: BridgeSettings,
                              cameras: [CameraStatus], configurations: [CameraConfiguration], sessions: [SessionRecord], logEntries: [LogEntry],
                              networkNotices: [NetworkNotice] = [], macVPN: MacVPNStatus? = nil,
                              maximumLogLines: Int = defaultMaximumLogLines) -> String {
        var out: [String] = []
        let names = Dictionary(configurations.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        out.append("Camera Bridge diagnostics")
        out.append(String(repeating: "=", count: 24))
        out.append("Generated: \(DiagnosticsLog.timestamp(context.generated))")
        out.append("This report holds no passwords, tokens or HomeKit setup codes. It does show the cameras' LAN addresses and log lines.")
        out.append("")
        out.append("## App and system")
        out.append("App: \(context.appName) \(context.appVersion) (build \(context.appBuild))")
        out.append("macOS: \(context.macOSVersion)")
        out.append("Mac: \(context.macModel) (\(context.architecture))")
        out.append("Locale: \(context.locale)")
        out.append("Mac uptime: \(duration(context.systemUptime))")
        out.append("App uptime: \(duration(context.processUptime))")
        out.append("")
        out.append("## Engine")
        out.append("State: \(describe(state))")
        out.append("Local Network access: \(localNetwork)")
        out.append("Settings: webhook \(settings.webhookEnabled ? "on, port \(settings.webhookPort), token hidden" : "off"), "
                   + "keep Mac awake \(settings.keepMacAwake ? "on" : "off"), Sensors Bridge port \(settings.sensorsBridgePort), "
                   + "log level \(DiagnosticsLog.levelName(settings.logLevel).lowercased()), base port \(settings.basePort), "
                   + "motion shadow test \(settings.motionShadowTest ? "on" : "off")")
        out.append("Cameras: \(configurations.count)")
        out.append("")
        out.append(contentsOf: networkSection(notices: networkNotices, macVPN: macVPN, generated: context.generated))

        let cameraSessions = Dictionary(grouping: sessions.filter { $0.cameraID != nil }, by: { $0.cameraID! })
        let statuses = Dictionary(cameras.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for configuration in configurations {
            out.append(contentsOf: cameraSection(configuration, status: statuses[configuration.id], sessions: cameraSessions[configuration.id] ?? [],
                                                 logEntries: logEntries))
        }
        let engineWide = sessions.filter { $0.cameraID == nil }
        if !engineWide.isEmpty {
            out.append("## Sessions without a camera")
            out.append(contentsOf: engineWide.suffix(20).map { "- \(Redact.string($0.oneLine))" })
            out.append("")
        }

        let lines = logEntries.suffix(max(0, maximumLogLines)).map { DiagnosticsLog.line(for: $0, cameraNames: names) }
        out.append("## Log (\(lines.count) of \(logEntries.count) entries, debug level, oldest first)")
        out.append(contentsOf: lines)
        out.append("")
        return Redact.string(out.joined(separator: "\n"))
    }

    /// "## Network": whether this Mac is on a VPN and which Apple Home devices asked for live video at an address that is on
    /// none of this Mac's networks (a VPN on the device), with what CameraBridge did and whether video then got through; then the
    /// other findings: a device that answered but received no video, a send macOS or a firewall blocks, a network held twice.
    private static func networkSection(notices: [NetworkNotice], macVPN: MacVPNStatus?, generated: Date) -> [String] {
        var out = ["## Network"]
        if let macVPN {
            out.append("This Mac: connected to a VPN (\(macVPN.interface)\(macVPN.address.map { ", \($0)" } ?? ""), \(describe(macVPN.reason)))")
        } else {
            out.append("This Mac: no VPN found")
        }
        let controllers = notices.filter { $0.kind == .controllerOnVPN }
        if controllers.isEmpty {
            out.append("Apple Home devices: none seen asking for video at an address outside this network in the last hour")
        }
        for notice in controllers {
            let seen = Int(max(0, generated.timeIntervalSince(notice.date)) / 60)
            var line = "- Device at \(notice.peerAddress ?? "an unknown address") asked for video at \(notice.advertisedAddress ?? "?")"
            if let name = notice.cameraName { line += " for \(name)" }
            line += notice.usedFallback ? "; sent to \(notice.peerAddress ?? "its HAP address") instead" : "; sent to the advertised address (no usable HAP address)"
            switch notice.delivery {
            case .pending: line += "; not verified yet"
            case .reached: line += "; the device answered (video got through)"
            case .failed: line += "; the device did not answer (video did not get through)"
            }
            out.append(line + "; last seen \(seen) min ago")
        }
        let findings = notices.filter { [.liveViewNotReceived, .localNetworkDenied, .dualHomedSubnet].contains($0.kind) }
        if findings.isEmpty {
            out.append("Live video findings: none (no device that received nothing, no send blocked, no network held twice)")
        }
        for notice in findings {
            let first = Int(max(0, generated.timeIntervalSince(notice.firstSeen)) / 60)
            let last = Int(max(0, generated.timeIntervalSince(notice.date)) / 60)
            var line: String
            switch notice.kind {
            case .liveViewNotReceived:
                line = "- Live video did not reach the device at \(notice.peerAddress ?? notice.advertisedAddress ?? "an unknown address")"
                if let name = notice.cameraName { line += " (watching \(name))" }
                line += ": it answered but its reports show it received none; the stream was ended so Home tries again, sending another way"
                line += notice.delivery == .reached ? "; a later live view received video (settled)" : "; no live view has received video since"
            case .localNetworkDenied:
                line = "- Sending live video failed for good" + (notice.detail.map { " (\($0))" } ?? "")
                line += ": the Local Network permission is off or a firewall or VPN app blocks Camera Bridge"
            case .dualHomedSubnet:
                line = "- This Mac is on one network twice (\(notice.interfaceName ?? "two interfaces")" + (notice.detail.map { ", \($0)" } ?? "") + ")"
                line += ": live video is sent from the address the device connected to; using only one connection is more reliable"
            case .controllerOnVPN, .macOnVPN:
                continue
            }
            out.append(line + "; first seen \(first) min ago, last seen \(last) min ago")
        }
        out.append("")
        return out
    }

    private static func describe(_ reason: MacVPNStatus.Reason) -> String {
        switch reason {
        case .defaultRoute: "carries the default route"
        case .nordLynxAddress: "NordLynx-style address"
        case .tunnelInterface: "tunnel interface with an address"
        }
    }

    private static func cameraSection(_ configuration: CameraConfiguration, status: CameraStatus?, sessions: [SessionRecord], logEntries: [LogEntry]) -> [String] {
        var out: [String] = []
        out.append("## Camera: \(configuration.name) (\(configuration.id.uuidString.prefix(8)))")
        out.append("Kind: \(configuration.kind.rawValue), vendor: \(configuration.vendor.rawValue), enabled: \(configuration.isEnabled ? "yes" : "no")")
        let device = [configuration.manufacturer, configuration.model].filter { !$0.isEmpty }.joined(separator: " ")
        out.append("Device: \(device.isEmpty ? "unknown" : device), firmware: \(configuration.firmware.isEmpty ? "unknown" : configuration.firmware)")
        let endpoint = configuration.endpoint
        out.append("Endpoint: \(endpoint.host) http \(endpoint.httpPort), rtsp \(endpoint.rtspPort)"
                   + (endpoint.onvifPort.map { ", onvif \($0)" } ?? "") + (endpoint.useHTTPS ? ", https" : "")
                   + ", username \(configuration.username.isEmpty ? "none" : "set")")
        if let url = configuration.mainStreamURL { out.append("Main stream URL: \(Redact.url(url))") }
        if let url = configuration.subStreamURL { out.append("Sub stream URL: \(Redact.url(url))") }
        out.append("Motion: \(configuration.motionSource.rawValue), sensitivity \(configuration.motionSensitivity), hold \(configuration.motionHoldSeconds) s")
        out.append("Live view: stream \(configuration.liveStreamMode.rawValue), quality \(configuration.liveQualityMode.rawValue), "
                   + "bit rate cap \(configuration.liveMaxBitrateOverride.rawValue); recording: stream \(configuration.recordingStreamMode.rawValue), "
                   + "quality \(configuration.recordingQualityMode.rawValue)")
        out.append("Audio: \(configuration.audioEnabled ? "on" : "off"), two-way \(configuration.twoWayAudio ? "on" : "off"), HAP port \(configuration.hapPort)")
        if let status {
            out.append("Status: \(describe(status.connection)); event channel \(status.eventChannelConnected ? "connected" : "not connected")"
                       + "; \(status.isPaired ? "paired with Home" : "not paired")")
            if let note = status.eventsNote { out.append("Events: \(note)") }
            if let note = status.homeKitNote { out.append("Apple Home: \(note)") }
            if let shadow = status.motionShadow { out.append(contentsOf: motionShadowLines(shadow)) }
            if let problem = status.subStreamProblem { out.append("Sub stream problem: \(problem)") }
            if let error = status.lastError { out.append("Last error: \(error)") }
            if let last = status.lastEvent { out.append("Last event: \(last)" + (status.lastEventDate.map { " at \(DiagnosticsLog.timestamp($0))" } ?? "")) }
            out.append("Streams: main \(describe(status.mainStreamInfo)); sub \(describe(status.subStreamInfo)); summary \(status.videoSummary ?? "none yet")")
            out.append("Now: \(status.liveViewers) live viewer(s), recording \(status.recordingEnabled ? (status.recordingNow ? "running" : "enabled") : "off"), "
                       + "motion \(status.motionActive ? "active" : "idle")")
            for (index, live) in status.liveSessions.enumerated() {
                out.append("Live session \(index + 1): \(live.usesSubStream ? "sub" : "main") stream, \(live.isPassthrough ? "passthrough" : "transcoded")"
                           + (live.resolution.map { ", \($0.width)×\($0.height)@\($0.fps)" } ?? "") + (live.bitrateKbps.map { ", up to \($0) kbit/s" } ?? "")
                           + (live.health.map { ", health: \($0)" } ?? "") + (live.endReason.map { ", ended by Camera Bridge: \($0)" } ?? ""))
            }
            if let recording = status.recordingSession {
                out.append("Recording session: \(recording.usesSubStream ? "sub" : "main") stream"
                           + (recording.resolution.map { ", \($0.width)×\($0.height)@\($0.fps)" } ?? ""))
            }
        } else {
            out.append("Status: not available")
        }
        let problems = logEntries.filter { $0.cameraID == configuration.id && $0.level >= .warning }.suffix(15)
        out.append("Recent warnings and errors (\(problems.count)):")
        out.append(contentsOf: problems.isEmpty ? ["- none"] : problems.map { "- \(DiagnosticsLog.line(for: $0))" })
        let recent = sessions.suffix(20)
        out.append("Live and recording sessions (newest last, \(recent.count) of \(sessions.count)):")
        out.append(contentsOf: recent.isEmpty ? ["- none"] : recent.map { "- \(DiagnosticsLog.timestamp($0.started)) \($0.oneLine)" })
        out.append("")
        return out
    }

    /// The motion shadow test's numbers for one camera (built-in motion detection compared with the camera's own events; it
    /// never changes what reaches HomeKit). The delay is the built-in detector's start minus the camera's.
    private static func motionShadowLines(_ shadow: MotionShadowStatus) -> [String] {
        var state = "comparing"
        if case .paused(let reason) = shadow.state { state = "paused (\(reason))" }
        return ["Motion shadow test: \(state), sensitivity \(String(format: "%.2f", shadow.sensitivity)), since \(DiagnosticsLog.timestamp(shadow.enabledSince))"
                    + (shadow.eventInProgress ? ", an event is being compared now" : ""),
                "  Last 24 h: \(MotionShadowTest.describe(shadow.last24Hours))",
                "  Since enabled: \(MotionShadowTest.describe(shadow.sinceEnabled))"]
    }

    private static func describe(_ state: EngineState) -> String {
        switch state {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .paused: "paused"
        case .failed(let reason): "failed (\(reason))"
        }
    }

    private static func describe(_ state: ConnectionState) -> String {
        switch state {
        case .idle: "idle"
        case .connecting: "connecting"
        case .online: "online"
        case .offline(let reason): "offline (\(reason))"
        case .disabled: "disabled"
        }
    }

    private static func describe(_ info: SourceStreamInfo?) -> String {
        guard let info else { return "unknown" }
        return "\(info.codec) \(info.width)×\(info.height)" + (info.fps.map { String(format: " @ %.1f fps", $0) } ?? "")
            + (info.bitrateKbps.map { " \($0) kbit/s" } ?? "")
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let (days, hours, minutes) = (total / 86_400, total % 86_400 / 3_600, total % 3_600 / 60)
        return (days > 0 ? "\(days) d " : "") + "\(hours) h \(minutes) min"
    }
}

extension BridgeEngine {
    /// The diagnostics bundle's text: this engine's state, cameras and settings, the sessions the `DiagnosticsCenter` kept and
    /// the `DiagnosticsLog` (else the engine's own recent log) — see `DiagnosticsReport`.
    public func diagnosticsReport(context: DiagnosticsContext, maximumLogLines: Int = DiagnosticsReport.defaultMaximumLogLines) -> String {
        let center = DiagnosticsCenter.shared
        let entries = center.log?.entries() ?? recentLogs
        return DiagnosticsReport.render(context: context, state: state, localNetwork: localNetworkAccess, settings: settings, cameras: cameras,
                                        configurations: configurations, sessions: center.sessions(), logEntries: entries,
                                        networkNotices: recentNetworkNotices, macVPN: macVPN, maximumLogLines: maximumLogLines)
    }
}
