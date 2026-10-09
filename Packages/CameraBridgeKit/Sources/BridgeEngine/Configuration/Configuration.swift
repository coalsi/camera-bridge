import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore

public enum CameraKind: String, Sendable, Codable, CaseIterable { case camera, doorbell }

public enum MotionSource: String, Sendable, Codable, CaseIterable { case cameraEvents, softMotion, webhook }

/// Which of the camera's streams a live view reads from (`StreamingHandler`, `MediaFit.prefersSubStream`).
/// `.automatic` keeps the existing behaviour (prefer the sub stream for a small or remote request); `.alwaysMain` and
/// `.alwaysSub` override it for every live view of this camera.
public enum LiveStreamMode: String, Sendable, Codable, CaseIterable { case automatic, alwaysMain, alwaysSub }

/// Whether a live view is transcoded to exactly what HomeKit asked for, or the camera's main-stream H.264 is sent
/// untouched when its codec and profile allow it (`MediaFit.live`).
public enum LiveQualityMode: String, Sendable, Codable, CaseIterable { case matchHomeKitRequest, originalQuality }

/// A manual cap on the live transcoder's bit rate, used only while transcoding (`auto` keeps HomeKit's own request).
public enum MaxBitrateOverride: String, Sendable, Codable, CaseIterable {
    case auto, mbps1, mbps2, mbps4, mbps6, mbps8

    /// The override in kbit/s, nil for `.auto` (HomeKit's requested bit rate is kept).
    public var kbps: Int? {
        switch self {
        case .auto: nil
        case .mbps1: 1_000
        case .mbps2: 2_000
        case .mbps4: 4_000
        case .mbps6: 6_000
        case .mbps8: 8_000
        }
    }
}

/// Which stream HKSV recording reads from (`RecordingHandler`). `.automatic` keeps today's behaviour (the main
/// stream); `.sub` needs the camera to have a sub stream, else the main stream is used.
public enum RecordingStreamMode: String, Sendable, Codable, CaseIterable { case automatic, main, sub }

/// Whether a recording is transcoded to exactly the hub's selected configuration, or the camera's main-stream H.264 is
/// passed through when its codec, profile and GOP allow it (`MediaFit.recording`).
public enum RecordingQualityMode: String, Sendable, Codable, CaseIterable { case matchHubRequest, originalWhenPossible }

/// Optional sensors a camera publishes on the sensors bridge (spec §3.4). Decoding fills missing keys with `false`.
public struct SensorOptions: Sendable, Codable, Equatable {
    public var person = false, vehicle = false, animal = false, package = false
    public var dayNight = false, digitalInputs = false, temperature = false, humidity = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case person, vehicle, animal, package, dayNight, digitalInputs, temperature, humidity }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) throws -> Bool { try container.decodeIfPresent(Bool.self, forKey: key) ?? false }
        person = try flag(.person)
        vehicle = try flag(.vehicle)
        animal = try flag(.animal)
        package = try flag(.package)
        dayNight = try flag(.dayNight)
        digitalInputs = try flag(.digitalInputs)
        temperature = try flag(.temperature)
        humidity = try flag(.humidity)
    }
}

/// One camera as persisted in `config.json`. Decoding requires `id`, `name`, `kind`, `vendor` and `endpoint`; every
/// other key that is missing, or holds a value this build cannot read (an enum case from a newer build, a port above
/// 65535, …), takes the `init` default (logged by key name, never by value), so fields added later need no migration.
public struct CameraConfiguration: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: CameraKind
    public var vendor: CameraVendor
    public var endpoint: CameraEndpoint
    public var username: String
    /// No credentials (`ConfigurationStore` strips user info before saving).
    public var mainStreamURL: URL?
    public var subStreamURL: URL?
    public var motionSource: MotionSource
    public var motionSensitivity: Double
    /// How long motion stays on after the last detection, at least 1 s (`EventRouter`; the camera's own delay in
    /// reporting an end counts towards it: 20 s for Hikvision events, 10 s for soft motion).
    public var motionHoldSeconds: Int
    public var sensors: SensorOptions
    public var audioEnabled: Bool
    public var twoWayAudio: Bool
    /// 0 = not allocated yet (`PortAllocator` assigns `BridgeSettings.basePort` + a stable offset and persists it).
    public var hapPort: UInt16
    public var isEnabled: Bool
    public var manufacturer: String
    public var model: String
    public var serialNumber: String
    public var firmware: String
    public var capabilities: CameraCapabilities?
    /// Live view stream and quality controls (docs/CONTRACT_CHANGES.md 2026-10-01).
    public var liveStreamMode: LiveStreamMode
    public var liveQualityMode: LiveQualityMode
    public var liveMaxBitrateOverride: MaxBitrateOverride
    /// Recording stream and quality controls (docs/CONTRACT_CHANGES.md 2026-10-01).
    public var recordingStreamMode: RecordingStreamMode
    public var recordingQualityMode: RecordingQualityMode
    /// The method that last changed this camera's video encoder settings (HomeKit optimization, Camera Settings →
    /// Save); tried first next time. nil: none yet, or the last one failed (docs/CONTRACT_CHANGES.md 2026-10-02).
    public var preferredConfigMethod: CameraConfigMethod?
    /// The "CameraBridge timestamp" drawn on live view and HomeKit Secure Video recordings (docs/CONTRACT_CHANGES.md
    /// 2026-10-02). Off by default; on, both always use the Mac's video encoder (`MediaFit`).
    public var timestampOverlay: TimestampOverlaySettings
    /// Set while CameraBridge has turned the camera's own on-screen date/time off (`BridgeEngine.setCameraClockHidden`):
    /// how, and what it takes to put it back.
    public var hiddenCameraClock: HiddenCameraClock?
    /// How the camera reaches its service, for a camera behind a cloud account or a console (`CameraVendor.go2rtc`,
    /// `.unifi`): the service and plain facts about the camera. Nothing secret; the service's token, key or source address is the
    /// camera's Keychain "password". nil for every other camera.
    public var integration: IntegrationSettings?

    /// Defaults: no stream URLs, camera events for motion (sensitivity 0.5, 20 s hold), no sensors, audio on,
    /// two-way audio off, port 0 (allocated by the engine), enabled, empty device info, capabilities unknown,
    /// automatic live/recording stream selection, quality matched to what HomeKit/the hub asked for, no bit rate override,
    /// timestamp overlay off, the camera's own clock untouched.
    public init(id: UUID = UUID(), name: String, kind: CameraKind, vendor: CameraVendor, endpoint: CameraEndpoint, username: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.vendor = vendor
        self.endpoint = endpoint
        self.username = username
        self.mainStreamURL = nil
        self.subStreamURL = nil
        self.motionSource = .cameraEvents
        self.motionSensitivity = 0.5
        self.motionHoldSeconds = 20
        self.sensors = SensorOptions()
        self.audioEnabled = true
        self.twoWayAudio = false
        self.hapPort = 0
        self.isEnabled = true
        self.manufacturer = ""
        self.model = ""
        self.serialNumber = ""
        self.firmware = ""
        self.capabilities = nil
        self.liveStreamMode = .automatic
        self.liveQualityMode = .matchHomeKitRequest
        self.liveMaxBitrateOverride = .auto
        self.recordingStreamMode = .automatic
        self.recordingQualityMode = .matchHubRequest
        self.preferredConfigMethod = nil
        self.timestampOverlay = TimestampOverlaySettings()
        self.hiddenCameraClock = nil
        self.integration = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, vendor, endpoint, username, mainStreamURL, subStreamURL, motionSource, motionSensitivity, motionHoldSeconds
        case sensors, audioEnabled, twoWayAudio, hapPort, isEnabled, manufacturer, model, serialNumber, firmware, capabilities
        case liveStreamMode, liveQualityMode, liveMaxBitrateOverride, recordingStreamMode, recordingQualityMode
        case preferredConfigMethod, timestampOverlay, hiddenCameraClock, integration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id), name: try container.decode(String.self, forKey: .name),
                  kind: try container.decode(CameraKind.self, forKey: .kind), vendor: try container.decode(CameraVendor.self, forKey: .vendor),
                  endpoint: try container.decode(CameraEndpoint.self, forKey: .endpoint), username: "")
        var unreadable: [String] = []
        func value<T: Decodable>(_ key: CodingKeys, default fallback: T) -> T {
            do {
                return try container.decodeIfPresent(T.self, forKey: key) ?? fallback
            } catch {
                unreadable.append(key.stringValue)
                return fallback
            }
        }
        username = value(.username, default: username)
        mainStreamURL = value(.mainStreamURL, default: nil)
        subStreamURL = value(.subStreamURL, default: nil)
        motionSource = value(.motionSource, default: motionSource)
        motionSensitivity = value(.motionSensitivity, default: motionSensitivity)
        motionHoldSeconds = value(.motionHoldSeconds, default: motionHoldSeconds)
        sensors = value(.sensors, default: sensors)
        audioEnabled = value(.audioEnabled, default: audioEnabled)
        twoWayAudio = value(.twoWayAudio, default: twoWayAudio)
        hapPort = value(.hapPort, default: hapPort)
        isEnabled = value(.isEnabled, default: isEnabled)
        manufacturer = value(.manufacturer, default: manufacturer)
        model = value(.model, default: model)
        serialNumber = value(.serialNumber, default: serialNumber)
        firmware = value(.firmware, default: firmware)
        capabilities = value(.capabilities, default: nil)
        liveStreamMode = value(.liveStreamMode, default: liveStreamMode)
        liveQualityMode = value(.liveQualityMode, default: liveQualityMode)
        liveMaxBitrateOverride = value(.liveMaxBitrateOverride, default: liveMaxBitrateOverride)
        recordingStreamMode = value(.recordingStreamMode, default: recordingStreamMode)
        recordingQualityMode = value(.recordingQualityMode, default: recordingQualityMode)
        preferredConfigMethod = value(.preferredConfigMethod, default: nil)
        timestampOverlay = value(.timestampOverlay, default: timestampOverlay)
        hiddenCameraClock = value(.hiddenCameraClock, default: nil)
        integration = value(.integration, default: nil)
        if !unreadable.isEmpty {
            Log(category: "Engine", cameraID: id).warning("\(name): unreadable \(unreadable.joined(separator: ", ")) in the configuration; defaults are used")
        }
    }

    /// This configuration with user info (`user:password@`) removed from the stream URLs.
    public var withoutStreamCredentials: CameraConfiguration {
        var copy = self
        copy.mainStreamURL = mainStreamURL?.removingUserInfo
        copy.subStreamURL = subStreamURL?.removingUserInfo
        return copy
    }
}

/// Bridge-wide settings as persisted in `config.json`. Decoding fills missing or unreadable keys with the `init`
/// defaults (a missing webhook token gets a fresh random one); unreadable keys are logged by name.
public struct BridgeSettings: Sendable, Codable, Equatable {
    public var webhookEnabled: Bool
    public var webhookPort: UInt16
    public var webhookToken: String
    public var keepMacAwake: Bool
    public var sensorsBridgePort: UInt16
    public var logLevel: LogLevel
    public var basePort: UInt16
    /// The motion shadow test: built-in motion detection runs next to the camera events of every camera that uses them and
    /// the two are compared (`CameraStatus.motionShadow`). It never changes what reaches HomeKit. Off by default.
    public var motionShadowTest: Bool

    /// Webhook off (port 21090, random 32-hex-digit token), keep-awake off, sensors bridge on 21099,
    /// log level info, camera HAP ports from 21100, motion shadow test off.
    public init() {
        webhookEnabled = false
        webhookPort = 21_090
        var generator = SystemRandomNumberGenerator()
        webhookToken = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        keepMacAwake = false
        sensorsBridgePort = 21_099
        logLevel = .info
        basePort = 21_100
        motionShadowTest = false
    }

    private enum CodingKeys: String, CodingKey { case webhookEnabled, webhookPort, webhookToken, keepMacAwake, sensorsBridgePort, logLevel, basePort, motionShadowTest }

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var unreadable: [String] = []
        func value<T: Decodable>(_ key: CodingKeys, default fallback: T) -> T {
            do {
                return try container.decodeIfPresent(T.self, forKey: key) ?? fallback
            } catch {
                unreadable.append(key.stringValue)
                return fallback
            }
        }
        webhookEnabled = value(.webhookEnabled, default: webhookEnabled)
        webhookPort = value(.webhookPort, default: webhookPort)
        webhookToken = value(.webhookToken, default: webhookToken)
        keepMacAwake = value(.keepMacAwake, default: keepMacAwake)
        sensorsBridgePort = value(.sensorsBridgePort, default: sensorsBridgePort)
        logLevel = value(.logLevel, default: logLevel)
        basePort = value(.basePort, default: basePort)
        motionShadowTest = value(.motionShadowTest, default: motionShadowTest)
        if !unreadable.isEmpty {
            Log(category: "Engine").warning("Unreadable settings \(unreadable.joined(separator: ", ")) in the configuration; defaults are used")
        }
    }
}
