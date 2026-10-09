import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import Testing
@testable import BridgeEngine

@Suite struct DiagnosticsReportTests {
    private static let context = DiagnosticsContext(appVersion: "1.0", appBuild: "7", macOSVersion: "Version 27.0 (Build 26A425)", macModel: "Mac15,3",
                                                    architecture: "arm64", systemUptime: 90_000, processUptime: 4_000,
                                                    generated: Date(timeIntervalSince1970: 1_790_000_000), locale: "en_US")

    private func fixture() -> (configuration: CameraConfiguration, status: CameraStatus, logs: [LogEntry], sessions: [SessionRecord], settings: BridgeSettings) {
        var configuration = CameraConfiguration(name: "Patio", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.44", onvifPort: 2020),
                                                username: "admin")
        configuration.manufacturer = "TP-Link"
        configuration.model = "Tapo C225"
        configuration.firmware = "1.3.4"
        configuration.serialNumber = "SERIAL-SECRET-123"
        configuration.mainStreamURL = URL(string: "rtsp://admin:hunter2@192.0.2.44:554/stream1?token=abc123")
        var status = CameraStatus(id: configuration.id, name: "Patio", kind: .camera, vendor: .onvif, connection: .online, eventChannelConnected: false,
                                  isPaired: true, setupCode: "123-45-678", setupURI: "X-HM://0023ISGSSABCD", lastError: "login failed password=hunter2",
                                  mainStreamInfo: SourceStreamInfo(codec: "h264", width: 2688, height: 1520, fps: 15))
        status.eventsNote = "Camera events unreliable; using built-in motion detection"
        status.liveSessions = [LiveSessionStatus(usesSubStream: false, isPassthrough: false, resolution: VideoResolution(1280, 720, 30), bitrateKbps: 299)]
        let logs = [
            LogEntry(date: Date(timeIntervalSince1970: 1_789_999_990), level: .debug, category: "LiveStream", message: "live stream trace: first video packet sent 412 ms after start",
                     cameraID: configuration.id),
            LogEntry(date: Date(timeIntervalSince1970: 1_789_999_995), level: .warning, category: "events",
                     message: "ONVIF 192.0.2.44: event channel failed: closed token=abc123", cameraID: configuration.id),
            LogEntry(date: Date(timeIntervalSince1970: 1_789_999_999), level: .info, category: "Engine", message: "Bridge running"),
        ]
        var session = SessionRecord(id: UUID(), kind: "live", cameraID: configuration.id, started: Date(timeIntervalSince1970: 1_789_999_980),
                                    summary: "transcoded 2688×1520 → 1280×720@30 299 kbit/s")
        session.phases = [.init(name: "prepare", offset: 0), .init(name: "first video packet", offset: 0.412), .init(name: "first RTCP received", offset: 0.9)]
        session.endReason = "controllerTimeout: no RTCP from the controller"
        session.duration = 30.01
        var settings = BridgeSettings()
        settings.webhookEnabled = true
        settings.webhookToken = "WEBHOOKTOKEN0123456789"
        return (configuration, status, logs, [session], settings)
    }

    @Test func theReportHasEverySectionAndNoSecrets() {
        let f = fixture()
        let text = DiagnosticsReport.render(context: Self.context, state: .running, localNetwork: .granted, settings: f.settings, cameras: [f.status],
                                            configurations: [f.configuration], sessions: f.sessions, logEntries: f.logs)
        for needle in ["Camera Bridge 1.0 (build 7)", "macOS: Version 27.0", "Mac: Mac15,3 (arm64)", "Mac uptime: 1 d 1 h 0 min", "State: running",
                       "## Camera: Patio", "Device: TP-Link Tapo C225, firmware: 1.3.4", "192.0.2.44", "onvif 2020", "h264 2688×1520 @ 15.0 fps",
                       "Camera events unreliable; using built-in motion detection", "transcoded, 1280×720@30, up to 299 kbit/s",
                       "first video packet +412 ms", "ended (controllerTimeout: no RTCP from the controller) +30010 ms", "## Log (3 of 3 entries",
                       "live stream trace: first video packet sent 412 ms after start"] {
            #expect(text.contains(needle), "missing: \(needle)")
        }
        for secret in ["hunter2", "abc123", "123-45-678", "X-HM://", "WEBHOOKTOKEN0123456789", "SERIAL-SECRET-123"] {
            #expect(!text.contains(secret), "leaked: \(secret)")
        }
        #expect(text.contains("token hidden"))
    }

    @Test func theLogIsLimitedToTheNewestLines() {
        let f = fixture()
        let many = (0..<50).map { LogEntry(level: .debug, category: "Test", message: "line \($0)") }
        let text = DiagnosticsReport.render(context: Self.context, state: .running, localNetwork: .unknown, settings: f.settings, cameras: [],
                                            configurations: [], sessions: [], logEntries: many, maximumLogLines: 10)
        #expect(text.contains("## Log (10 of 50 entries"))
        #expect(text.contains("line 49") && text.contains("line 40") && !text.contains("line 39"))
    }

    @Test func aCameraWithoutStatusStillGetsASection() {
        let f = fixture()
        let text = DiagnosticsReport.render(context: Self.context, state: .stopped, localNetwork: .unknown, settings: f.settings, cameras: [],
                                            configurations: [f.configuration], sessions: [], logEntries: [])
        #expect(text.contains("## Camera: Patio") && text.contains("Status: not available") && text.contains("- none"))
    }
}
