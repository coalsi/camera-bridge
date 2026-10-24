import CameraAdapters
import Foundation
import Testing
@testable import BridgeEngine

/// `BridgeSettings.cameraOrder`: the order the person gave the cameras.
@Suite struct CameraOrderSettingsTests {
    @Test func aSettingsFileFromBeforeLoadsUnchangedWithNoOrder() throws {
        let old = #"{"webhookPort":21091,"keepMacAwake":true,"nvrKeepDays":14}"#
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(old.utf8))
        #expect(settings.cameraOrder.isEmpty)
        #expect(settings.webhookPort == 21_091 && settings.keepMacAwake && settings.nvrKeepDays == 14)
    }

    @Test func theOrderRoundTripsAndAnUnreadableOneIsEmptyWithTheOtherKeysKept() throws {
        var settings = BridgeSettings()
        settings.cameraOrder = [UUID(), UUID()]
        #expect(try JSONDecoder().decode(BridgeSettings.self, from: JSONEncoder().encode(settings)) == settings)
        let broken = try JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"webhookPort":21092,"cameraOrder":["not an id",3]}"#.utf8))
        #expect(broken.cameraOrder.isEmpty && broken.webhookPort == 21_092)
    }

    @Test func listedCamerasComeFirstTheRestByNameAndStaleOrRepeatedIdsAreIgnored() {
        let porch = NVRFixtures.camera(name: "Porch"), alley = NVRFixtures.camera(name: "Alley")
        let cam10 = NVRFixtures.camera(name: "Camera 10"), cam2 = NVRFixtures.camera(name: "Camera 2")
        var settings = BridgeSettings()
        let all = [porch, alley, cam10, cam2]
        #expect(settings.orderedIDs(of: all) == [alley.id, cam2.id, cam10.id, porch.id], "no order: by name, numbers by value")
        settings.cameraOrder = [UUID(), porch.id, porch.id, cam10.id]
        #expect(settings.orderedIDs(of: all) == [porch.id, cam10.id, alley.id, cam2.id], "stale ids and repeats ignored, new cameras after by name")
        #expect(settings.orderedIDs(of: []) == [])
    }
}
