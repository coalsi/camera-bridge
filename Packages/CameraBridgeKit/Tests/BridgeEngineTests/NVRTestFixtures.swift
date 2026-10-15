import CameraAdapters
import Foundation
import Testing
@testable import BridgeEngine

/// Cameras and JSON the NVR tests share.
enum NVRFixtures {
    static func camera(name: String = "Driveway") -> CameraConfiguration {
        CameraConfiguration(name: name, kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.10"), username: "admin")
    }

    /// `camera` as JSON with `keys` removed and `values` set: the file an older (or newer) build wrote.
    static func json(of camera: CameraConfiguration, removing keys: [String] = [], setting values: [String: Any] = [:]) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(camera)) as? [String: Any])
        for key in keys { object[key] = nil }
        for (key, value) in values { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
