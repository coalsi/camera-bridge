import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import HAPCamera
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

#if canImport(Darwin)
import PlatformApple

/// A battery camera's charge (`CameraDriver.batteryStatus`): asked at the start and every `batteryPollInterval`, kept when an answer is
/// missing, shown in `CameraStatus.battery` and the accessory's HAP Battery service. A driver without a battery is asked a few more
/// times at the start, then no more.
@Suite(.serialized) struct RuntimeBatteryTests {
    @MainActor @Test(.timeLimit(.minutes(1))) func batteryIsPolledShownAndKept() async throws {
        var tuning = EngineTuning.testing
        tuning.batteryPollInterval = .milliseconds(300)
        let driver = ScriptedEventDriver()
        driver.battery.set(BatteryStatus(level: 22, charging: false))
        tuning.driverFactory = { _, _, _ in driver }
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await server.start()
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let camera = RuntimeCameraLifecycleTests.rtspCamera("Solo", server: server)
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        let runtime = try #require(engine.runtimes[camera.id])

        #expect(await fixture.waitFor(.seconds(10)) { fixture.status(camera.id)?.battery == BatteryStatus(level: 22, charging: false) })
        #expect(await fixture.until(.seconds(10)) { await runtime.controller?.batteryService != nil }, "the accessory has a Battery service")
        let service = try #require(await runtime.controller?.batteryService)
        #expect(service.existingCharacteristic(.batteryLevel)?.value == .uint(22))
        #expect(service.existingCharacteristic(.chargingState)?.value == .uint(0))
        #expect(service.existingCharacteristic(.statusLowBattery)?.value == .uint(0))

        // Charging from the sun and below 20 %: the next poll shows it.
        driver.battery.set(BatteryStatus(level: 18, charging: true, source: .solar))
        #expect(await fixture.waitFor(.seconds(5)) { fixture.status(camera.id)?.battery?.source == .solar })
        #expect(fixture.status(camera.id)?.battery?.level == 18 && fixture.status(camera.id)?.battery?.charging == true)
        #expect(service.existingCharacteristic(.batteryLevel)?.value == .uint(18))
        #expect(service.existingCharacteristic(.chargingState)?.value == .uint(1))
        #expect(service.existingCharacteristic(.statusLowBattery)?.value == .uint(1))

        // No answer (the cloud didn't say): the last reading stays, and polling goes on.
        driver.battery.set(nil)
        let calls = driver.batteryCalls.value
        #expect(await fixture.waitFor(.seconds(5)) { driver.batteryCalls.value >= calls + 2 })
        #expect(fixture.status(camera.id)?.battery == BatteryStatus(level: 18, charging: true, source: .solar))
        #expect(await runtime.batteryReading?.level == 18)

        await fixture.tearDown()
        await server.stop()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func aCameraWithoutABatteryIsAskedOnlyAtTheStart() async throws {
        var tuning = EngineTuning.testing
        tuning.batteryPollInterval = .milliseconds(200)
        let driver = ScriptedEventDriver()
        tuning.driverFactory = { _, _, _ in driver }
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await server.start()
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let camera = RuntimeCameraLifecycleTests.rtspCamera("Wired", server: server)
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        let runtime = try #require(engine.runtimes[camera.id])
        #expect(await fixture.waitFor(.seconds(10)) { fixture.status(camera.id)?.connection == .online })
        // The start and four quick retries (1/20 … 2/5 of the interval), then nothing.
        #expect(await fixture.waitFor(.seconds(5)) { driver.batteryCalls.value == 5 })
        try await Task.sleep(for: .seconds(1))
        #expect(driver.batteryCalls.value == 5)
        #expect(fixture.status(camera.id)?.battery == nil)
        #expect(await runtime.controller?.batteryService == nil)

        await fixture.tearDown()
        await server.stop()
    }

    @Test func batteryStatusClampsAndDropsTheSourceWhileNotCharging() {
        #expect(BatteryStatus(level: 140, charging: false).level == 100)
        #expect(BatteryStatus(level: -1, charging: false).level == 0)
        #expect(BatteryStatus(level: 50, charging: false, source: .solar).source == nil)
        #expect(BatteryStatus(level: 19, charging: true).isLow && !BatteryStatus(level: 20, charging: true).isLow)
        #expect(CameraRuntime.homeKitBattery(BatteryStatus(level: 30, charging: true, source: .cable)) == CameraBattery(level: 30, chargingState: .charging))
        #expect(CameraRuntime.homeKitBattery(BatteryStatus(level: 30, charging: false)).chargingState == .notCharging)
    }
}
#endif
