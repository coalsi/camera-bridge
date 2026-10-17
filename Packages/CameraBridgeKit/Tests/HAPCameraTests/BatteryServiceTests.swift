#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import HAPCore
import TestSupport
import Testing
@testable import HAP
@testable import HAPCamera

/// A battery camera's HAP Battery service (`CameraController.setBattery`): BatteryLevel, ChargingState and StatusLowBattery below
/// 20 %, added the first time the camera reports a battery, saved, and published from the start after a restart.
@Suite(.timeLimit(.minutes(1))) struct BatteryServiceTests {
    @Test func noBatteryServiceUntilTheCameraReportsOne() async {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        #expect(harness.service(.battery) == nil)
        #expect(harness.controller.battery == nil && harness.controller.batteryService == nil)
    }

    @Test func batteryServiceShowsLevelChargingAndLowBattery() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        await harness.controller.setBattery(CameraBattery(level: 22, chargingState: .notCharging))
        #expect(harness.services(.battery).count == 1)
        let service = try #require(harness.service(.battery))
        #expect(service === harness.controller.batteryService)
        #expect(try harness.characteristic(.battery, .batteryLevel).value == .uint(22))
        #expect(try harness.characteristic(.battery, .chargingState).value == .uint(0))
        #expect(try harness.characteristic(.battery, .statusLowBattery).value == .uint(0))

        // Low (below 20 %) and charging; still one service.
        await harness.controller.setBattery(CameraBattery(level: 19, chargingState: .charging))
        #expect(harness.services(.battery).count == 1)
        #expect(try harness.characteristic(.battery, .batteryLevel).value == .uint(19))
        #expect(try harness.characteristic(.battery, .chargingState).value == .uint(1))
        #expect(try harness.characteristic(.battery, .statusLowBattery).value == .uint(1))
        #expect(harness.controller.battery == CameraBattery(level: 19, chargingState: .charging))

        await harness.controller.setBattery(CameraBattery(level: 20, chargingState: .notChargeable))
        #expect(try harness.characteristic(.battery, .statusLowBattery).value == .uint(0), "20 % is not low")
        #expect(try harness.characteristic(.battery, .chargingState).value == .uint(2))
        #expect(CameraBattery(level: 140, chargingState: .charging).level == 100 && CameraBattery(level: -3, chargingState: .charging).level == 0)
    }

    /// The service as `/accessories` lists it: type 96 with StatusLowBattery (79), BatteryLevel (68, percent 0–100) and ChargingState (8F,
    /// valid values 0, 1, 2).
    @Test func batteryServiceJSON() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        await harness.controller.setBattery(CameraBattery(level: 64, chargingState: .charging))
        let service = try #require(harness.service(.battery))
        let json = HAPJSONEncoding.service(service, includeValues: true)
        #expect(json["type"]?.stringValue == "96")
        let characteristics = try #require(json["characteristics"]?.arrayValue)
        var byType: [String: HAPJSON] = [:]
        for characteristic in characteristics { byType[characteristic["type"]?.stringValue ?? ""] = characteristic }
        #expect(Set(byType.keys) == ["79", "68", "8F"])
        let level = try #require(byType["68"])
        #expect(level["format"]?.stringValue == "uint8" && level["unit"]?.stringValue == "percentage")
        #expect(level["value"]?.intValue == 64 && level["maxValue"]?.doubleValue == 100 && level["minValue"]?.doubleValue == 0)
        let charging = try #require(byType["8F"])
        #expect(charging["value"]?.intValue == 1)
        #expect(charging["valid-values"]?.arrayValue?.compactMap(\.intValue) == [0, 1, 2])
        let low = try #require(byType["79"])
        #expect(low["value"]?.intValue == 0 && low["valid-values"]?.arrayValue?.compactMap(\.intValue) == [0, 1])
        for characteristic in byType.values {
            #expect(characteristic["perms"]?.arrayValue?.compactMap(\.stringValue).sorted() == ["ev", "pr"])
        }
    }

    /// The first reading adds the service to a running accessory (a structure change: `c#` moves, so Home reads it); the saved reading
    /// publishes it from the start after a restart, with the last values, and `c#` stays.
    @Test func firstReadingBumpsTheConfigurationNumberAndARestartKeepsIt() async throws {
        let store = InMemoryHAPStore()
        let first = await CameraHarness.make(store: store)
        try await first.server.start()
        #expect(try store.loadState()?.configNumber == 1)
        await first.controller.setBattery(CameraBattery(level: 64, chargingState: .charging))
        await first.server.configurationDidChange()
        #expect(try store.loadState()?.configNumber == 2)
        let saved = try #require(await first.server.extra(forKey: CameraController.persistenceKey))
        #expect(try JSONDecoder().decode(PersistedCameraState.self, from: saved).battery == CameraBattery(level: 64, chargingState: .charging))
        await first.server.stop()
        await first.stop()

        // Unpaired, so the rest of the saved camera state is reset; the battery is a fact about the camera and stays.
        let second = await CameraHarness.make(store: store)
        defer { await second.stop() }
        #expect(second.services(.battery).count == 1, "published from the start")
        #expect(try second.characteristic(.battery, .batteryLevel).value == .uint(64))
        #expect(try second.characteristic(.battery, .chargingState).value == .uint(1))
        try await second.server.start()
        #expect(try store.loadState()?.configNumber == 2, "same structure as before the restart")
        await second.controller.setBattery(CameraBattery(level: 63, chargingState: .notCharging))
        await second.server.configurationDidChange()
        #expect(try store.loadState()?.configNumber == 2, "a new reading changes values, not the structure")
        #expect(try second.characteristic(.battery, .batteryLevel).value == .uint(63))
        await second.server.stop()
    }

    @Test func savedStateWithoutABatteryDecodes() throws {
        let old = Data(#"{"version":1,"recordingActive":true,"streamActive":[true,false]}"#.utf8)
        let state = try JSONDecoder().decode(PersistedCameraState.self, from: old)
        #expect(state.battery == nil && state.recordingActive && state.streamActive == [true, false])
        let unreadable = Data(#"{"version":1,"battery":{"level":"x"}}"#.utf8)
        #expect(try JSONDecoder().decode(PersistedCameraState.self, from: unreadable).battery == nil, "an unreadable battery is dropped, not the state")
    }
}
#endif
