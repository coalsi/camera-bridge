import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import HAPCore

extension BridgeEngine {
    /// Static fake data for SwiftUI previews and the app's `-previewEngine YES` mode; never starts networking.
    ///
    /// A running bridge with five sample cameras that together cover every state the UI renders (live and recording,
    /// an unpaired doorbell, offline with an error, connecting, disabled), a paired sensors bridge, sample logs and
    /// settings. Identifiers, setup codes and configurations are fixed so previews are stable; event and log dates
    /// are relative to the call. Hosts are RFC 5737 documentation addresses (192.0.2.0/24) so nothing can reach a
    /// real device, and the engine runs on the inert environment (every transport/codec call throws). The engine is
    /// never started: callers must not invoke operations on it that would start runtimes (the app skips them in
    /// preview mode).
    public static func preview(scenario: PreviewScenario = .standard) -> BridgeEngine {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CameraBridgePreview", directoryHint: .isDirectory)
        return BridgeEngine(environment: .preview(directory: directory), snapshot: PreviewData.snapshot(now: Date(), scenario: scenario))
    }
}

/// Which sample bridge `BridgeEngine.preview(scenario:)` shows (the app's `-demoScenario` launch argument, for screenshots
/// and UI review of states a healthy bridge never shows). Sample data only.
public enum PreviewScenario: String, Sendable, CaseIterable {
    /// Five cameras covering every camera state (live, recording, offline, connecting, disabled, unpaired doorbell).
    case standard
    /// A bridge without cameras (first run).
    case empty
    /// macOS denied Local Network access.
    case networkDenied = "network-denied"
    /// A damaged configuration was set aside; the bridge started without cameras.
    case damagedConfig = "damaged-config"
    /// The enabled webhook is not listening.
    case webhookError = "webhook-error"
    /// A log full of warnings and errors (Diagnostics page).
    case errors
    /// Eight cameras, seven of them online (the Overview grid and live tiles at full size).
    case fleet
    /// An iPhone on a VPN asked for the Driveway's live view at 10.5.0.2; the stream went to its address on this network.
    case vpn
    /// The same, and the iPhone did not answer: video did not get through.
    case vpnFailed = "vpn-failed"
    /// This Mac is connected to a VPN.
    case macVPN = "mac-vpn"
}

/// Sample content for `BridgeEngine.preview()`.
enum PreviewData {
    struct SampleCamera {
        var configuration: CameraConfiguration
        var status: CameraStatus
    }

    static func snapshot(now: Date, scenario: PreviewScenario = .standard) -> BridgeEngine.Snapshot {
        let cameras = scenario == .empty || scenario == .damagedConfig ? [] : (scenario == .fleet ? fleetCameras(now: now) : sampleCameras(now: now))
        var snapshot = BridgeEngine.Snapshot()
        snapshot.state = .running
        snapshot.cameras = cameras.map(\.status)
        snapshot.configurations = cameras.map(\.configuration)
        // What the sample cameras' sensor options publish (the Sensors Bridge page lists these).
        let published: [UUID: [BridgedSensor]] = [drivewayID: [.occupancy(.person), .occupancy(.vehicle), .light],
                                                  frontDoorID: [.occupancy(.person), .occupancy(.package)]]
        snapshot.sensorsBridge = SensorsBridgeStatus(isPaired: true, setupCode: code("146-83-529").formatted,
                                                     setupURI: SetupPayload.uri(code: code("146-83-529"), setupID: "CBSB", category: .bridge),
                                                     accessoryCount: published.values.map(\.count).reduce(0, +), publishedSensors: published)
        snapshot.localNetworkAccess = scenario == .networkDenied ? .denied : .granted
        snapshot.recentLogs = scenario == .errors ? errorLogs(now: now) : sampleLogs(now: now)
        snapshot.settings = sampleSettings()
        switch scenario {
        case .empty, .damagedConfig:
            snapshot.sensorsBridge = nil
            snapshot.recentLogs = scenario == .empty ? [] : [LogEntry(date: now.addingTimeInterval(-30), level: .error, category: "Engine",
                message: "config.json couldn't be read (the file is damaged); it was set aside and the bridge started without cameras", cameraID: nil)]
            if scenario == .damagedConfig {
                snapshot.configurationRecoveredFrom = URL(fileURLWithPath: "/tmp/config.corrupt-20261002-091500.json")
            }
        case .webhookError:
            snapshot.webhookProblem = "The webhook cannot listen on port 21090 (another app uses the port)."
        case .vpn, .vpnFailed:
            snapshot.networkNotices = [NetworkNotice(kind: .controllerOnVPN, cameraID: drivewayID, cameraName: "Driveway", advertisedAddress: "10.5.0.2",
                                                     peerAddress: "198.51.100.20", usedFallback: true, delivery: scenario == .vpn ? .reached : .failed,
                                                     date: now.addingTimeInterval(-90), firstSeen: now.addingTimeInterval(-600))]
        case .macVPN:
            snapshot.macVPN = MacVPNStatus(interface: "utun4", address: "10.5.0.2", reason: .defaultRoute)
            snapshot.networkNotices = [NetworkNotice(kind: .macOnVPN, interfaceName: "utun4", date: now)]
        default: break
        }
        return snapshot
    }

    static let drivewayID = sampleID(1), frontDoorID = sampleID(2), garageID = sampleID(3), sideYardID = sampleID(4), demoID = sampleID(5)

    static func sampleCameras(now: Date) -> [SampleCamera] {
        var driveway = configuration(id: drivewayID, name: "Driveway", kind: .camera, vendor: .hikvision, host: "192.0.2.21", port: 21_100,
                                     main: "rtsp://192.0.2.21:554/ISAPI/Streaming/channels/101",
                                     sub: "rtsp://192.0.2.21:554/ISAPI/Streaming/channels/102",
                                     device: ("Hikvision", "DS-2CD2347G2-LU", "DS-2CD2347G2-LU20230415AAWRJ12345678", "V5.7.15 build 230412"),
                                     capabilities: CameraCapabilities(events: [.motion, .person, .vehicle, .tamper, .dayNight, .digitalInput],
                                                                      twoWayAudio: true, snapshotAPI: true, nightVisionControl: true))
        driveway.sensors.person = true
        driveway.sensors.vehicle = true
        driveway.sensors.dayNight = true
        driveway.twoWayAudio = true
        // Sample data for the Streams page: the CameraBridge timestamp on, the camera's own clock hidden.
        driveway.timestampOverlay = TimestampOverlaySettings(enabled: true, position: .topRight, showCameraName: true, showDate: true, showSeconds: true,
                                                             use24Hour: false, size: .medium)
        driveway.hiddenCameraClock = HiddenCameraClock(method: .hikvisionISAPI, wasShown: true)

        var frontDoor = configuration(id: frontDoorID, name: "Front Door", kind: .doorbell, vendor: .reolink, host: "192.0.2.22", port: 21_101,
                                      main: "rtsp://192.0.2.22:554/h264Preview_01_main", sub: "rtsp://192.0.2.22:554/h264Preview_01_sub",
                                      device: ("Reolink", "Reolink Video Doorbell WiFi", "192168110022", "v3.0.0.2033_23041302"),
                                      capabilities: CameraCapabilities(events: [.motion, .person, .vehicle, .animal, .package, .doorbell, .dayNight],
                                                                       twoWayAudio: true, isDoorbell: true, snapshotAPI: true))
        frontDoor.sensors.person = true
        frontDoor.sensors.package = true
        frontDoor.twoWayAudio = true

        let garage = configuration(id: garageID, name: "Garage", kind: .camera, vendor: .onvif, host: "192.0.2.23", port: 21_102,
                                   main: "rtsp://192.0.2.23:554/stream1", sub: "rtsp://192.0.2.23:554/stream2",
                                   device: ("Amcrest", "IP5M-T1179EW", "AMC0123456789ABCDEF", "V2.800.00AC000.0.R"),
                                   capabilities: CameraCapabilities(events: [.motion, .tamper], snapshotAPI: true))

        var sideYard = configuration(id: sideYardID, name: "Side Yard", kind: .camera, vendor: .rtsp, host: "192.0.2.24", port: 21_103,
                                     main: "rtsp://192.0.2.24:8554/live", sub: nil, device: ("Generic", "RTSP Camera", "", ""),
                                     capabilities: CameraCapabilities())
        sideYard.motionSource = .softMotion
        sideYard.motionSensitivity = 0.6
        sideYard.audioEnabled = false

        var demo = configuration(id: demoID, name: "Demo Camera", kind: .camera, vendor: .demo, host: "localhost", port: 21_104,
                                 main: nil, sub: nil, device: ("CameraBridge", "Demo Camera", "DEMO-0001", "1.0"),
                                 capabilities: CameraCapabilities(events: [.motion]))
        demo.isEnabled = false

        return [
            SampleCamera(configuration: driveway, status: CameraStatus(
                id: drivewayID, name: "Driveway", kind: .camera, vendor: .hikvision, connection: .online, eventChannelConnected: true,
                videoSummary: "H.264 2688×1520 · 20 fps", isPaired: true, setupCode: code("482-17-935").formatted,
                setupURI: uri("482-17-935", "CB1D", .ipCamera), hapPort: 21_100, motionActive: true, recordingEnabled: true,
                recordingNow: true, liveViewers: 1, lastEvent: "Motion", lastEventDate: now.addingTimeInterval(-40),
                recentEvents: events(now, first: 1, [(-2 * 3_600, "Vehicle"), (-25 * 60, "Person"), (-40, "Motion")]))),
            SampleCamera(configuration: frontDoor, status: CameraStatus(
                id: frontDoorID, name: "Front Door", kind: .doorbell, vendor: .reolink, connection: .online, eventChannelConnected: true,
                videoSummary: "H.264 2560×1920 · 15 fps", isPaired: false, setupCode: code("631-58-204").formatted,
                setupURI: uri("631-58-204", "CB2F", .videoDoorbell), hapPort: 21_101, lastEvent: "Doorbell ring",
                lastEventDate: now.addingTimeInterval(-3 * 3_600),
                recentEvents: events(now, first: 4, [(-5 * 3_600, "Package"), (-3 * 3_600 - 5, "Person"), (-3 * 3_600, "Doorbell ring")]))),
            SampleCamera(configuration: garage, status: CameraStatus(
                id: garageID, name: "Garage", kind: .camera, vendor: .onvif, connection: .offline("Connection timed out"),
                videoSummary: "H.264 1920×1080 · 15 fps", isPaired: true, setupCode: code("259-73-610").formatted,
                setupURI: uri("259-73-610", "CB3G", .ipCamera), hapPort: 21_102, recordingEnabled: true, lastEvent: "Motion",
                lastEventDate: now.addingTimeInterval(-26 * 3_600), lastError: "Connection timed out. Retrying in 30 s.")),
            SampleCamera(configuration: sideYard, status: CameraStatus(
                id: sideYardID, name: "Side Yard", kind: .camera, vendor: .rtsp, connection: .connecting, isPaired: true,
                setupCode: code("804-26-157").formatted, setupURI: uri("804-26-157", "CB4K", .ipCamera), hapPort: 21_103,
                recordingEnabled: true)),
            SampleCamera(configuration: demo, status: CameraStatus(
                id: demoID, name: "Demo Camera", kind: .camera, vendor: .demo, connection: .disabled, isPaired: false,
                setupCode: code("370-91-468").formatted, setupURI: uri("370-91-468", "CB5M", .ipCamera))),
        ]
    }

    /// Eight cameras for the `.fleet` scenario: six 16:9 and one 4:3 camera online (some recording, one with motion), one offline.
    static func fleetCameras(now: Date) -> [SampleCamera] {
        let names: [(String, CameraKind, CameraVendor, String, String?)] = [
            ("Driveway", .camera, .hikvision, "H.264 2688×1520 · 20 fps", "Motion"), ("Front Door", .doorbell, .reolink, "H.264 2560×1920 · 15 fps", "Doorbell ring"),
            ("Garage", .camera, .onvif, "H.264 1920×1080 · 15 fps", "Motion"), ("Side Yard", .camera, .hikvision, "H.265 2560×1440 · 20 fps", "Person"),
            ("Back Yard", .camera, .hikvision, "H.264 2688×1520 · 20 fps", "Motion"), ("Patio", .camera, .onvif, "H.264 1920×1080 · 15 fps", nil),
            ("Garden", .camera, .rtsp, "H.264 1920×1080 · 25 fps", nil), ("Workshop", .camera, .onvif, "H.264 1920×1080 · 15 fps", "Motion"),
        ]
        return names.enumerated().map { index, entry in
            let (name, kind, vendor, summary, event) = entry
            let id = sampleID(11 + index)
            let host = "192.0.2.\(41 + index)"
            let config = configuration(id: id, name: name, kind: kind, vendor: vendor, host: host, port: UInt16(21_110 + index),
                                       main: "rtsp://\(host):554/main", sub: "rtsp://\(host):554/sub",
                                       device: (vendor == .hikvision ? "Hikvision" : (vendor == .reolink ? "Reolink" : "Generic"), "Sample \(name)", "", ""),
                                       capabilities: CameraCapabilities(events: [.motion], snapshotAPI: true))
            let offline = name == "Workshop"
            let status = CameraStatus(
                id: id, name: name, kind: kind, vendor: vendor, connection: offline ? .offline("Connection timed out") : .online,
                eventChannelConnected: !offline, videoSummary: summary, isPaired: index % 2 == 0, setupCode: code("482-17-935").formatted,
                setupURI: uri("482-17-935", "CB\(index)F", kind == .doorbell ? .videoDoorbell : .ipCamera), hapPort: UInt16(21_110 + index),
                motionActive: name == "Back Yard", recordingEnabled: index % 3 != 2, recordingNow: name == "Back Yard" || name == "Driveway",
                liveViewers: name == "Driveway" ? 1 : 0, lastEvent: event, lastEventDate: event.map { _ in now.addingTimeInterval(-Double(90 + index * 1_700)) },
                lastError: offline ? "Connection timed out. Retrying in 30 s." : nil)
            return SampleCamera(configuration: config, status: status)
        }
    }

    static func sampleLogs(now: Date) -> [LogEntry] {
        let entries: [(TimeInterval, LogLevel, String, String, UUID?)] = [
            (-600, .notice, "Engine", "Bridge started with 5 cameras", nil),
            (-598, .info, "HAP", "Sensors bridge listening on port 21099", nil),
            (-596, .info, "HAP", "Driveway listening on port 21100", drivewayID),
            (-595, .info, "RTSP", "Driveway connected to rtsp://192.0.2.21:554/ISAPI/Streaming/channels/101 (H.264 2688×1520)", drivewayID),
            (-594, .info, "Camera", "Driveway event channel connected", drivewayID),
            (-590, .info, "RTSP", "Front Door connected to rtsp://192.0.2.22:554/h264Preview_01_main (H.264 2560×1920)", frontDoorID),
            (-585, .warning, "RTSP", "Garage connection timed out; retrying in 30 s", garageID),
            (-560, .debug, "HAP", "Driveway pair-verify completed for controller 2B4F…", drivewayID),
            (-420, .info, "Recording", "Driveway recording configuration selected: 1920×1080 H.264 High 4.0, 2000 kbit/s", drivewayID),
            (-300, .info, "Webhook", "Webhook listening on port 21090", nil),
            (-200, .error, "RTSP", "Garage connection timed out; retrying in 30 s", garageID),
            (-120, .info, "Events", "Front Door person detected", frontDoorID),
            (-60, .info, "Live", "Driveway live stream started (1280×720, 30 fps)", drivewayID),
            (-40, .info, "Events", "Driveway motion detected", drivewayID),
            (-39, .notice, "Recording", "Driveway recording started", drivewayID),
            (-5, .debug, "Engine", "Status refresh: 2 online, 1 offline, 1 connecting, 1 disabled", nil),
        ]
        return entries.map { offset, level, category, message, cameraID in
            LogEntry(date: now.addingTimeInterval(offset), level: level, category: category, message: message, cameraID: cameraID)
        }
    }

    /// Warnings and errors a struggling bridge logs (Diagnostics page review).
    static func errorLogs(now: Date) -> [LogEntry] {
        let entries: [(TimeInterval, LogLevel, String, String, UUID?)] = [
            (-900, .notice, "Engine", "Bridge started with 5 cameras", nil),
            (-880, .info, "RTSP", "Driveway connected to rtsp://192.0.2.21:554/ISAPI/Streaming/channels/101 (H.264 2688×1520)", drivewayID),
            (-860, .warning, "RTSP", "Garage connection timed out; retrying in 30 s", garageID),
            (-830, .warning, "Camera", "Garage snapshot failed again (httpStatus(503)); next try in 1800 s", garageID),
            (-800, .error, "ONVIF", "Garage ONVIF login was refused (HTTP 401); Camera Bridge won't try again for 10 minutes", garageID),
            (-780, .warning, "Camera", "Garage: the camera locked logins after too many wrong passwords; holding off until 12:45 PM", garageID),
            (-700, .error, "RTSP", "Side Yard stream ended: the camera has no video stream at this address", sideYardID),
            (-690, .warning, "RTSP", "Side Yard reconnecting in 60 s (attempt 4)", sideYardID),
            (-600, .info, "HAP", "Driveway listening on port 21100", drivewayID),
            (-560, .warning, "Recording", "Driveway recording fragment late: 1.8 s behind (the network is slow)", drivewayID),
            (-520, .error, "Recording", "Garage recording stream 1 ended: the hub closed it (reason 3)", garageID),
            (-480, .warning, "Webhook", "Webhook request rejected: missing or wrong bearer token (192.0.2.77)", nil),
            (-400, .error, "Webhook", "The webhook cannot listen on port 21090 (another app uses the port)", nil),
            (-360, .warning, "Camera", "Front Door event channel dropped; reconnecting", frontDoorID),
            (-300, .error, "Live", "Garage live stream failed: the camera didn't send a keyframe in 10 s", garageID),
            (-240, .warning, "Camera", "Driveway time differs from this Mac by 94 s; the camera's clock isn't synced", drivewayID),
            (-120, .info, "Events", "Front Door person detected", frontDoorID),
            (-60, .error, "Network", "Local Network access check found no answer from 192.0.2.21", nil),
            (-40, .info, "Events", "Driveway motion detected", drivewayID),
            (-5, .debug, "Engine", "Status refresh: 2 online, 1 offline, 1 connecting, 1 disabled", nil),
        ]
        return entries.map { offset, level, category, message, cameraID in
            LogEntry(date: now.addingTimeInterval(offset), level: level, category: category, message: message, cameraID: cameraID)
        }
    }

    static func sampleSettings() -> BridgeSettings {
        var settings = BridgeSettings()
        settings.webhookEnabled = true
        settings.webhookToken = "5f1c0d9e7a3b42c68e0f1a2b3c4d5e6f"   // sample value, not a secret
        settings.keepMacAwake = false
        settings.logLevel = .info
        return settings
    }

    private static func configuration(id: UUID, name: String, kind: CameraKind, vendor: CameraVendor, host: String, port: UInt16,
                                      main: String?, sub: String?, device: (String, String, String, String),
                                      capabilities: CameraCapabilities) -> CameraConfiguration {
        var config = CameraConfiguration(id: id, name: name, kind: kind, vendor: vendor, endpoint: CameraEndpoint(host: host),
                                         username: vendor == .demo ? "" : "admin")
        config.mainStreamURL = main.flatMap(URL.init(string:))
        config.subStreamURL = sub.flatMap(URL.init(string:))
        config.hapPort = port
        (config.manufacturer, config.model, config.serialNumber, config.firmware) = device
        config.capabilities = capabilities
        config.motionSource = capabilities.events.contains(.motion) ? .cameraEvents : .softMotion
        return config
    }

    /// Sample event history, oldest first (offsets in seconds from `now`).
    private static func events(_ now: Date, first: Int, _ entries: [(TimeInterval, String)]) -> [CameraEventRecord] {
        entries.enumerated().map { index, entry in
            CameraEventRecord(id: UUID(uuidString: String(format: "CB0E0000-0000-4000-8000-%012d", first + index)) ?? UUID(), name: entry.1,
                              date: now.addingTimeInterval(entry.0))
        }
    }

    private static func sampleID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "CB000000-0000-4000-8000-%012d", n)) ?? UUID()
    }

    private static func code(_ text: String) -> SetupCode {
        SetupCode(text) ?? SetupCode.random()   // literals above are valid, non-trivial codes
    }

    private static func uri(_ code: String, _ setupID: String, _ category: AccessoryCategory) -> String {
        SetupPayload.uri(code: Self.code(code), setupID: setupID, category: category)
    }
}
