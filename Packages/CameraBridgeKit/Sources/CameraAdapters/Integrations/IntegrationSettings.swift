import Foundation

/// The service behind a camera that is not reached directly (a cloud account, a console, a bridge). Shown in the app and
/// chosen by the Add Camera wizard; the camera's vendor says how Camera Bridge talks to it (`CameraVendor`).
public enum IntegrationService: String, Sendable, Codable, CaseIterable {
    case ring, nest, tuya, wyze, unifiProtect
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
    }

    public var deviceName: String? { details[Key.deviceName] }
}
