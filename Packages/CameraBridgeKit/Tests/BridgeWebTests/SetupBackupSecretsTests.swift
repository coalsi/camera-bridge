import BridgeEngine
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// A camera's setup backup reaches the page (`/api/cameras`, its events) with the configuration: the sign-in value of the maker's cloud
/// that the setup turned off (an IP camera web API camera's Authcode) is never in it, even while the engine holds it in memory.
@Suite struct SetupBackupSecretsTests {
    @Test func aCameraResourceNeverCarriesTheCloudsSignIn() throws {
        let authcode = #"Ab&1<2"x"#
        var camera = CameraConfiguration(name: "Yard", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "admin")
        camera.setupBackup = CameraSetupBackup(version: 1, created: Date(timeIntervalSince1970: 0),
                                               cloud: CameraFeatureBackup(path: "getNetworkConfig", enabled: true, cloudType: "10", cloudAuthcode: authcode))
        let text = String(decoding: try JSONEncoder().encode(CameraResource(configuration: camera, status: nil)), as: UTF8.self)
        #expect(text.contains("getNetworkConfig") && text.contains("cloudType"), "the backup itself is there")
        #expect(!text.contains("Ab&1") && !text.contains("Authcode"))
    }
}
