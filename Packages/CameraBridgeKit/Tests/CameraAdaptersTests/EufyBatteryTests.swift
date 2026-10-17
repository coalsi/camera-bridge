import Foundation
import Testing
@testable import CameraAdapters

/// A eufy camera's battery from the `eufy-bridge` helper's `GET /devices` (`battery`, `charging`, `chargingSource`).
@Suite struct EufyBatteryTests {
    private func device(_ json: String) throws -> EufyBridge.DeviceBattery {
        try JSONDecoder().decode(EufyBridge.DeviceBattery.self, from: Data(json.utf8))
    }

    @Test func helperDevicesMapToBatteryStatus() throws {
        // The owner's SoloCam S220 as the helper lists it.
        let s220 = try device(#"{"serial":"T8134X","name":"Porch","model":"T8134","type":63,"online":true,"livestream":true,"battery":22,"charging":false,"chargingSource":null}"#)
        #expect(EufyBridge.batteryStatus(s220) == BatteryStatus(level: 22, charging: false))
        let solar = try device(#"{"serial":"T8134X","battery":64,"charging":true,"chargingSource":"solar"}"#)
        #expect(EufyBridge.batteryStatus(solar) == BatteryStatus(level: 64, charging: true, source: .solar))
        let cable = try device(#"{"serial":"T8134X","battery":64,"charging":true,"chargingSource":"cable"}"#)
        #expect(EufyBridge.batteryStatus(cable)?.source == .cable)
        // An older helper (no chargingSource) or an unknown source: charging, from where unknown.
        let older = try device(#"{"serial":"T8134X","battery":64,"charging":true}"#)
        #expect(EufyBridge.batteryStatus(older) == BatteryStatus(level: 64, charging: true, source: nil))
        let unknown = try device(#"{"serial":"T8134X","battery":64,"charging":true,"chargingSource":"wind"}"#)
        #expect(EufyBridge.batteryStatus(unknown)?.source == nil)
        // A wired camera (no battery), or a level out of range: none.
        #expect(EufyBridge.batteryStatus(try device(#"{"serial":"T8400X","charging":false}"#)) == nil)
        #expect(EufyBridge.batteryStatus(try device(#"{"serial":"T8134X","battery":101}"#)) == nil)
        // Charging unknown: not charging.
        #expect(EufyBridge.batteryStatus(try device(#"{"serial":"T8134X","battery":80}"#)) == BatteryStatus(level: 80, charging: false))
    }

    @Test func noBatteryWhileThePluginIsOff() async {
        let bridge = EufyBridge()
        #expect(await bridge.battery(serial: "T8134X") == nil)
    }
}
