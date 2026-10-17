#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import HAPCore
import TestSupport
import Testing
@testable import HAP
@testable import HAPCamera

/// Night Vision offered once the camera says it can switch it (`CameraController.setNightVision`): added to the operating mode service at
/// run time like the Battery service, back from the start after a restart, and a controller's writes reported on `nightVisionWrites` (the
/// camera follows those; the camera's own changes are not reported there).
@Suite(.timeLimit(.minutes(1))) struct NightVisionOfferTests {
    @Test func theCameraAddsNightVisionAndHomeWritesReachIt() async throws {
        let store = try CameraHarness.pairedStore()
        let harness = await CameraHarness.make(store: store)
        defer { await harness.stop() }
        #expect(!harness.controller.offersNightVision)
        #expect(harness.service(.cameraOperatingMode)?.existingCharacteristic(.nightVision) == nil)
        #expect(harness.controller.operatingState.nightVision == nil)

        let writes = Box<[Bool]>([])
        let stream = harness.controller.nightVisionWrites
        let reader = Task { for await value in stream { writes.update { $0.append(value) } } }
        defer { reader.cancel() }

        await harness.controller.setNightVision(false)
        #expect(harness.controller.offersNightVision)
        let characteristic = try harness.characteristic(.cameraOperatingMode, .nightVision)
        #expect(characteristic.value == .bool(false))
        #expect(harness.controller.operatingState.nightVision == false)
        #expect(harness.controller.operatingModeService === harness.service(.cameraOperatingMode))

        try await characteristic.write(.bool(true), as: FakeHAPSession(isAdmin: false))
        #expect(await eventually { writes.value == [true] }, "a controller's write is reported")
        #expect(harness.controller.operatingState.nightVision == true)
        try await characteristic.write(.bool(true), as: FakeHAPSession(isAdmin: false))
        #expect(await eventually { writes.value == [true, true] }, "every write, also one that changes nothing")

        await harness.controller.setNightVision(false)
        await harness.controller.setNightVision(nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(writes.value == [true, true], "the camera's own changes are not Home's writes")
        #expect(characteristic.value == .bool(false), "nil keeps the value")

        let persisted = try #require(await harness.server.extra(forKey: CameraController.persistenceKey))
        #expect(try JSONDecoder().decode(PersistedCameraState.self, from: persisted).nightVision == false)
    }

    @Test func nightVisionOfferedOnceIsThereFromTheStartAfterARestart() async throws {
        let store = try CameraHarness.pairedStore()
        let first = await CameraHarness.make(store: store)
        await first.controller.setNightVision(false)
        await first.stop()

        let second = await CameraHarness.make(store: store)
        defer { await second.stop() }
        #expect(second.controller.offersNightVision)
        #expect(try second.characteristic(.cameraOperatingMode, .nightVision).value == .bool(false))
        #expect(second.controller.operatingState.nightVision == false)
        let writes = Box<[Bool]>([])
        let stream = second.controller.nightVisionWrites
        let reader = Task { for await value in stream { writes.update { $0.append(value) } } }
        defer { reader.cancel() }
        try await second.characteristic(.cameraOperatingMode, .nightVision).write(.bool(true), as: FakeHAPSession(isAdmin: false))
        #expect(await eventually { writes.value == [true] }, "the restored characteristic is wired too")
    }

    @Test func anAccessoryWithoutTheOperatingModeServiceIsLeftAlone() async throws {
        let harness = await CameraHarness.make(recordingOptions: nil)
        defer { await harness.stop() }
        await harness.controller.setNightVision(true)
        #expect(!harness.controller.offersNightVision && harness.service(.cameraOperatingMode) == nil)
        #expect(harness.controller.operatingModeService == nil)
    }

    @Test func aConfiguredNightVisionIsNotAddedTwice() async throws {
        let harness = await CameraHarness.make(nightVision: true)
        defer { await harness.stop() }
        #expect(harness.controller.offersNightVision)
        let count = try #require(harness.service(.cameraOperatingMode)).characteristics.count
        await harness.controller.setNightVision(false)
        #expect(try #require(harness.service(.cameraOperatingMode)).characteristics.count == count)
        #expect(try harness.characteristic(.cameraOperatingMode, .nightVision).value == .bool(false))
    }
}
#endif
