import Foundation

/// The service behind a camera that is not reached directly (a cloud account, a console, a bridge). Shown in the app and
/// chosen by the Add Camera wizard; the camera's vendor says how Camera Bridge talks to it (`CameraVendor`).
public enum IntegrationService: String, Sendable, Codable, CaseIterable {
    case ring, nest, tuya, wyze, unifiProtect, eufy
    /// Any other source go2rtc understands (`Go2RTCSource.allowedSchemes`).
    case other

    /// The brand as people know it ("Ring"), for the camera's manufacturer field and the app's text.
    public var displayName: String {
        switch self {
        case .ring: "Ring"
        case .nest: "Google Nest"
        case .tuya: "Tuya / Smart Life"
        case .wyze: "Wyze"
        case .unifiProtect: "UniFi Protect"
        case .eufy: "eufy"
        case .other: "go2rtc source"
        }
    }
}

/// What is saved in `config.json` about how a camera reaches its service. Nothing secret: a token, an API key or a
/// stream address with a key in it lives in the Keychain (the camera's stored "password") and nowhere else.
public struct IntegrationSettings: Sendable, Codable, Equatable {
    public var service: IntegrationService
    /// Plain facts the app shows or the driver needs and that identify nothing secret: the Protect camera's ID, the name the
    /// service gave the camera. Keys and values are short; they are never credentials.
    public var details: [String: String]

    public init(service: IntegrationService, details: [String: String] = [:]) {
        self.service = service
        self.details = details
    }

    /// Keys used in `details`.
    public enum Key {
        /// The camera's name at the service (Ring "Front Door").
        public static let deviceName = "deviceName"
        /// UniFi Protect: the camera's ID in the console.
        public static let protectCameraID = "protectCameraID"
        /// UniFi Protect: which of the console's streams to use (`high`, `medium`, `low`).
        public static let protectQuality = "protectQuality"
        /// Wyze: the camera's MAC address as the Wyze account lists it ("D03F27A1B2C3"), which ties the camera to the Wyze plugin.
        public static let wyzeMAC = "wyzeMAC"
        /// Wyze: the camera's product model ("HL_CAM4").
        public static let wyzeModel = "wyzeModel"
        /// Wyze: how the camera is reached, `rtsp` (its own RTSP) or `local` (the local Wyze connection through go2rtc).
        public static let wyzeWay = "wyzeWay"
        /// eufy: the camera's serial number as the Eufy account lists it ("T8134…"), which ties the camera to the Eufy plugin.
        public static let eufySerial = "eufySerial"
        /// eufy: the camera's model code ("T8134").
        public static let eufyModel = "eufyModel"
    }

    public var deviceName: String? { details[Key.deviceName] }
}
