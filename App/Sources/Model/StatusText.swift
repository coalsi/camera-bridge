import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore

/// Connection health, shown as a coloured dot next to text (colour is never the only signal).
enum Health: Equatable {
    case good, warning, error, inactive
}

/// User-facing status strings. macOS 27 hides menu-item images by default, so the menu bar menu conveys status in text.
enum StatusText {
    // MARK: Menu

    /// "● Driveway — Live · Recording", "○ Garage — Offline — retrying".
    /// With `address` (the camera's IP or host name): "● Driveway · 192.0.2.21 — Live".
    static func menuLine(for camera: CameraStatus, address: String? = nil) -> String {
        let name = address.map { "\(camera.name) · \($0)" } ?? camera.name
        return "\(camera.connection == .online ? "●" : "○") \(name) — \(summary(for: camera))"
    }

    /// The menu line for VoiceOver, without the glyph.
    static func accessibleMenuLine(for camera: CameraStatus, address: String? = nil) -> String {
        [camera.name, address, summary(for: camera)].compactMap { $0 }.joined(separator: ", ")
    }

    /// Short status: "Live · Recording", "Offline — retrying", "Connecting…".
    static func summary(for camera: CameraStatus) -> String {
        switch camera.connection {
        case .online:
            var parts = [String(localized: "Live")]
            if camera.recordingNow {
                parts.append(String(localized: "Recording"))
            } else if camera.motionActive {
                parts.append(String(localized: "Motion"))
            }
            if camera.liveViewers > 0 {
                parts.append(camera.liveViewers == 1 ? String(localized: "1 Viewer") : String(localized: "\(camera.liveViewers) Viewers"))
            }
            if !camera.isPaired {
                parts.append(String(localized: "Not Paired"))
            }
            return parts.joined(separator: " · ")
        case .offline:
            return String(localized: "Offline — retrying")
        case .connecting:
            return String(localized: "Connecting…")
        case .idle:
            return String(localized: "Idle")
        case .disabled:
            return String(localized: "Disabled")
        }
    }

    static func menuHeader(_ state: EngineState) -> String {
        "Camera Bridge — \(engineState(state))"
    }

    /// The status item's symbol: running, stopped/paused, or needs attention (`issue`: `AppModel.bridgeIssue`, the same
    /// issue the manager's banner shows).
    static func menuBarSymbol(state: EngineState, issue: BridgeIssue?) -> String {
        if issue != nil { return "exclamationmark.triangle" }
        switch state {
        case .running, .starting: return "video"
        case .paused, .stopped, .failed: return "video.slash"
        }
    }

    /// What the status item draws: the brand mark while healthy, or a system glyph for attention/paused states
    /// (those read better as alert symbols than as a recolored brand mark).
    enum MenuBarGlyph: Equatable { case brandMark, symbol(String) }

    static func menuBarGlyph(state: EngineState, issue: BridgeIssue?) -> MenuBarGlyph {
        if issue != nil { return .symbol("exclamationmark.triangle") }
        switch state {
        case .running, .starting: return .brandMark
        case .paused, .stopped, .failed: return .symbol("video.slash")
        }
    }

    /// The status item's VoiceOver label, from the same inputs as its symbol: what the warning triangle means (a failed
    /// start reads as the state, "Error — …"), else the bridge state.
    static func menuBarAccessibilityLabel(state: EngineState, issue: BridgeIssue?) -> String {
        switch issue {
        case .startFailed?, nil: "Camera Bridge, \(engineState(state))"
        case let issue?: "Camera Bridge, \(issue.title)"
        }
    }

    // MARK: Trigger Motion

    /// The camera page's Trigger Motion footer: it is a real event in the Home app.
    static let testMotionExplanation = String(localized: "Sends a motion event to the Home app as if the camera saw motion: with recording on, the Home app records a clip, and people who get this camera’s notifications are notified.")

    /// Why Trigger Motion is off (`AppModel.testMotionBlocker`).
    static func testMotionUnavailable(_ blocker: PairingBlocker) -> String {
        switch blocker {
        case .cameraDisabled: String(localized: "This camera is turned off, so a motion event can’t reach the Home app.")
        case .bridgePaused: String(localized: "The bridge is paused, so a motion event can’t reach the Home app.")
        case .bridgeNotRunning: String(localized: "The bridge isn’t running, so a motion event can’t reach the Home app.")
        case .bridgeStarting: String(localized: "The bridge is starting.")
        case .accessoryNotRunning: String(localized: "This camera’s accessory isn’t running, so a motion event can’t reach the Home app.")
        }
    }

    static func pauseResumeTitle(_ state: EngineState) -> String {
        switch state {
        case .running, .starting: String(localized: "Pause Bridge")
        case .paused: String(localized: "Resume Bridge")
        case .stopped, .failed: String(localized: "Start Bridge")
        }
    }

    // MARK: Engine and connection

    static func engineState(_ state: EngineState) -> String {
        switch state {
        case .stopped: String(localized: "Stopped")
        case .starting: String(localized: "Starting…")
        case .running: String(localized: "Running")
        case .paused: String(localized: "Paused")
        case .failed(let reason): String(localized: "Error — \(Redact.string(reason))")   // shown on screen, like the log
        }
    }

    /// Why the Sensors Bridge page shows no QR code, or nil when the bridge is running and can be paired. The engine
    /// runs the sensors bridge only while a camera exists, and pause or stop close it while `sensorsBridge` keeps its
    /// last status — so only a running engine may offer the code.
    static func sensorsBridgeUnavailable(state: EngineState, bridge: SensorsBridgeStatus?, hasCameras: Bool) -> String? {
        guard hasCameras else {
            return String(localized: "It starts when you add a camera. Until then, Camera Bridge publishes nothing on your network.")
        }
        switch state {
        case .paused: return String(localized: "The bridge is paused. Resume it to use the sensors bridge.")
        case .stopped, .failed: return String(localized: "The bridge isn’t running. Start it to use the sensors bridge.")
        case .starting: return String(localized: "The bridge is starting.")
        case .running: return bridge == nil ? String(localized: "It isn’t running. The log in Settings shows why.") : nil
        }
    }

    static func connection(_ state: ConnectionState) -> String {
        switch state {
        case .online: String(localized: "Live")
        case .connecting: String(localized: "Connecting…")
        case .idle: String(localized: "Idle")
        case .disabled: String(localized: "Disabled")
        case .offline(let reason):
            reason.isEmpty ? String(localized: "Offline") : String(localized: "Offline — \(reason)")
        }
    }

    /// The camera page's Camera Events row. Plain RTSP cameras have no event channel (motion comes from built-in
    /// detection or the webhook), so theirs is never "Not connected", which would read as a fault.
    static func cameraEvents(_ status: CameraStatus) -> String {
        if status.vendor == .rtsp { return String(localized: "None — RTSP cameras send no events") }
        if status.vendor == .go2rtc { return String(localized: "None — cloud cameras send no events here; built-in motion detection is used") }
        return status.eventChannelConnected ? String(localized: "Connected") : String(localized: "Not connected")
    }

    static func health(_ state: ConnectionState) -> Health {
        switch state {
        case .online: .good
        case .connecting: .warning
        case .offline: .error
        case .idle, .disabled: .inactive
        }
    }

    // MARK: Names

    static func kind(_ kind: CameraKind) -> String {
        switch kind {
        case .camera: String(localized: "Camera")
        case .doorbell: String(localized: "Video Doorbell")
        }
    }

    static func vendor(_ vendor: CameraVendor) -> String {
        switch vendor {
        case .hikvision: "Hikvision"
        case .reolink: "Reolink"
        case .onvif: "ONVIF"
        case .rtsp: "RTSP"
        case .amcrest: String(localized: "Amcrest / Dahua")
        case .doorbird: "DoorBird"
        case .unifi: "UniFi Protect"
        case .go2rtc: String(localized: "Cloud camera")
        case .demo: String(localized: "Demo")
        }
    }

    /// Review page: which audio the camera will have in the Home app.
    static func audioSummary(cameraAudio: Bool, twoWayAudio: Bool) -> String {
        switch (cameraAudio, twoWayAudio) {
        case (true, true): String(localized: "Camera audio and two-way audio")
        case (true, false): String(localized: "Camera audio")
        case (false, true): String(localized: "Two-way audio only")
        case (false, false): String(localized: "Off")
        }
    }

    static func motionSource(_ source: MotionSource) -> String {
        switch source {
        case .cameraEvents: String(localized: "Camera Events")
        case .softMotion: String(localized: "Built-in Motion Detection")
        case .webhook: String(localized: "Webhook")
        }
    }

    static func motionSourceDetail(_ source: MotionSource) -> String {
        switch source {
        case .cameraEvents: String(localized: "Uses the camera’s own motion detection.")
        case .softMotion: String(localized: "Camera Bridge compares frames from the camera’s sub stream.")
        case .webhook: String(localized: "Another system reports motion to Camera Bridge’s webhook.")
        }
    }

    // MARK: Setup codes and streams

    /// Apple Home setup codes display as `XXX-XX-XXX`; anything that isn't eight digits is shown unchanged.
    static func setupCode(_ raw: String) -> String {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        let separatorsOnly = raw.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "-" || $0 == " " }
        guard digits.count == 8, separatorsOnly else { return raw }
        let chars = Array(digits)
        return "\(String(chars[0..<3]))-\(String(chars[3..<5]))-\(String(chars[5..<8]))"
    }

    /// "H.264 1920×1080 · 20 fps · AAC 16 kHz".
    static func stream(_ info: StreamInfo) -> String {
        var parts: [String] = []
        var video: [String] = []
        if let codec = info.videoCodec { video.append(videoCodec(codec)) }
        if let width = info.width, let height = info.height { video.append("\(width)×\(height)") }
        if !video.isEmpty { parts.append(video.joined(separator: " ")) }
        if let fps = info.fps, fps > 0 {
            parts.append("\(fps.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))) fps")
        }
        if let audio = info.audioCodec {
            var text = audioCodec(audio)
            if let rate = info.audioSampleRate, rate > 0 {
                text += " \((Double(rate) / 1_000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
            }
            parts.append(text)
        }
        return parts.isEmpty ? String(localized: "Unknown format") : parts.joined(separator: " · ")
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

    /// "Motion · 2 min. ago" at `now`. The camera page passes its timeline's date, so the text moves on by itself (a
    /// string formatted once froze on a quiet camera: nothing else redraws the row).
    static func lastEvent(_ event: String?, at date: Date?, now: Date) -> String? {
        guard let event else { return nil }
        guard let date else { return event }
        return "\(event) · \(now.formatted(Date.AnchoredRelativeFormatStyle(anchor: date, presentation: .named, unitsStyle: .abbreviated)))"
    }

    /// The camera page's Live View tile: everybody watching, in the Home app and in CameraBridge's own window.
    static func viewersValue(_ camera: CameraStatus) -> String {
        let total = camera.liveViewers + camera.appViewers
        return total == 0 ? String(localized: "No viewers") : (total == 1 ? String(localized: "1 viewer") : String(localized: "\(total) viewers"))
    }

    /// "Watching in the Home app", "1 viewer in CameraBridge", "2 in the Home app · 1 in CameraBridge".
    static func viewersDetail(_ camera: CameraStatus) -> String {
        switch (camera.liveViewers, camera.appViewers) {
        case (0, 0): String(localized: "Nobody is watching right now")
        case (_, 0): String(localized: "Watching in the Home app")
        case (0, 1): String(localized: "1 viewer in Camera Bridge")
        case (0, let app): String(localized: "\(app) viewers in Camera Bridge")
        case (let home, let app): String(localized: "\(home) in the Home app · \(app) in Camera Bridge")
        }
    }

    /// "2 hours ago" at `now` (the Recent Events rows).
    static func timeAgo(_ date: Date, now: Date) -> String {
        now.formatted(Date.AnchoredRelativeFormatStyle(anchor: date, presentation: .named))
    }
}
