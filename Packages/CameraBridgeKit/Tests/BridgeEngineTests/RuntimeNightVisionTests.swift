import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine
@testable import HAP

#if canImport(Darwin)
import PlatformApple

/// A camera's night vision through the runtime: what the camera says (its mode and its lamp) in `CameraStatus.nightVision`, and Apple
/// Home's Night Vision once the camera can go to auto and off: shown as the camera is, a Home write turns the camera to auto (on) or off,
/// and a change from the bridge's page reaches Home.
@Suite(.serialized) struct RuntimeNightVisionTests {
    final class FakeNightVision: NightVisionControl, @unchecked Sendable {
        let modes: [NightVisionMode]
        let mode = Box<NightVisionMode?>(.auto)
        let light = Box<Bool?>(true)
        let modesSet = Box<[NightVisionMode]>([])
        let refuse = Box(false)
        /// The camera does not say what its night vision offers (yet).
        let silent = Box(false)

        init(modes: [NightVisionMode] = [.auto, .on, .off]) { self.modes = modes }

        func capabilities() async throws -> NightVisionCapabilities {
            if silent.value { throw CameraAdapterError.httpStatus(503) }
            return NightVisionCapabilities(modes: modes, light: true)
        }
        func currentMode() async throws -> NightVisionMode? { mode.value }
        func currentLight() async throws -> Bool? { light.value }
        func setMode(_ mode: NightVisionMode) async throws {
            if refuse.value { throw CameraAdapterError.unsupported("the camera accepted the change but kept its old setting") }
            modesSet.update { $0.append(mode) }
            self.mode.set(mode)
        }
        func setLight(_ on: Bool) async throws { light.set(on) }
    }

    final class NightVisionDriver: CameraDriver, @unchecked Sendable {
        let vendor: CameraVendor = .demo
        let control: FakeNightVision
        init(_ control: FakeNightVision) { self.control = control }
        func probe() async throws -> CameraProbeResult { throw CameraAdapterError.unsupported("scripted driver") }
        func makeEventSource() -> (any CameraEventSource)? { nil }
        func snapshot() async throws -> Data? { nil }
        func makeTalkbackSink() -> (any TalkbackSink)? { nil }
        func makeNightVision() -> (any NightVisionControl)? { control }
    }

    /// A controller's session for a write as the server performs it.
    final class Session: HAPSessionHandle {
        let id = UUID()
        let controllerID = UUID().uuidString
        let isAdmin = false
        let sharedSecret = Data(repeating: 7, count: 32)
        let localAddress = "127.0.0.1"
        let remoteAddress = "127.0.0.1"
        let isIPv6 = false
        func onClose(_ handler: @escaping @Sendable () -> Void) {}
    }

    @MainActor private func running(_ control: FakeNightVision) async throws -> (EngineFixture, RTSPTestServer, CameraRuntime, UUID) {
        var tuning = EngineTuning.testing
        let driver = NightVisionDriver(control)
        tuning.driverFactory = { _, _, _ in driver }
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil), transport: AppleNetworkTransport())
        try await server.start()
        let fixture = try await EngineFixture(tuning: tuning)
        let camera = RuntimeCameraLifecycleTests.rtspCamera("Yard", server: server)
        try await fixture.engine.addCamera(camera, password: nil)
        await fixture.engine.start()
        let runtime = try #require(fixture.engine.runtimes[camera.id])
        return (fixture, server, runtime, camera.id)
    }

    private static func homeNightVision(_ runtime: CameraRuntime) async -> HAPValue? {
        await runtime.controller?.operatingModeService?.existingCharacteristic(.nightVision)?.value
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func homeFollowsTheCameraAndTheCameraFollowsHome() async throws {
        let control = FakeNightVision()
        control.light.set(false)
        let (fixture, server, runtime, id) = try await running(control)

        #expect(await fixture.waitFor(.seconds(10)) {
            fixture.status(id)?.nightVision == NightVisionState(modes: [.auto, .on, .off], mode: .auto, light: true, lightOn: false)
        }, "the lamp as the camera has it")
        #expect(await fixture.until(.seconds(10)) { await Self.homeNightVision(runtime) == .bool(true) }, "auto: Night Vision on")
        #expect(await runtime.controller?.offersNightVision == true)

        // Home turns it off: the camera's day picture, IR off.
        let characteristic = try #require(await runtime.controller?.operatingModeService?.existingCharacteristic(.nightVision))
        _ = try await characteristic.handleWrite(.bool(false), context: HAPRequestContext(session: Session()))
        #expect(await fixture.waitFor(.seconds(5)) { control.modesSet.value == [.off] })
        #expect(await fixture.waitFor(.seconds(5)) { fixture.status(id)?.nightVision?.mode == .off })

        // Home turns it on: the camera's own choice.
        _ = try await characteristic.handleWrite(.bool(true), context: HAPRequestContext(session: Session()))
        #expect(await fixture.waitFor(.seconds(5)) { control.modesSet.value == [.off, .auto] })

        // The bridge's page sets night vision on (IR on): Home shows Night Vision on, and its write of on changes nothing.
        try await fixture.engine.setNightVision(cameraID: id, mode: .on, light: true)
        #expect(control.modesSet.value == [.off, .auto, .on])
        #expect(await fixture.waitFor(.seconds(5)) { fixture.status(id)?.nightVision?.mode == .on })
        #expect(await Self.homeNightVision(runtime) == .bool(true))
        await runtime.homeKitNightVision(true)
        #expect(control.modesSet.value == [.off, .auto, .on], "already in night vision")
        try await fixture.engine.setNightVision(cameraID: id, mode: .off, light: nil)
        #expect(await Self.homeNightVision(runtime) == .bool(false), "the page's off reaches Home")
        #expect(await fixture.waitFor(.seconds(5)) { fixture.status(id)?.nightVision?.lightOn == true })

        // A change the camera refuses puts Home back to what the camera does.
        control.refuse.set(true)
        _ = try await characteristic.handleWrite(.bool(true), context: HAPRequestContext(session: Session()))
        #expect(await fixture.until(.seconds(5)) { await Self.homeNightVision(runtime) == .bool(false) })
        #expect(await runtime.nightVisionReading.mode == .off)

        // A refused change that left the camera in a mode it cannot say: the page shows none, not the one asked for or the old one.
        control.mode.set(nil)
        await #expect(throws: CameraAdapterError.self) { try await fixture.engine.setNightVision(cameraID: id, mode: .auto, light: nil) }
        #expect(await runtime.nightVisionReading.mode == nil)
        #expect(await fixture.waitFor(.seconds(5)) { fixture.status(id)?.nightVision?.mode == nil })

        await fixture.tearDown()
        await server.stop()
    }

    /// The camera refuses Home's write and then cannot say its mode (its web API paused, its logins paused): Home goes back to what it
    /// showed before the write, not the value the camera refused.
    @MainActor @Test(.timeLimit(.minutes(1))) func aRefusedHomeWriteWhoseModeCannotBeReadPutsHomeBack() async throws {
        let control = FakeNightVision()
        control.mode.set(.off)
        let (fixture, server, runtime, _) = try await running(control)
        #expect(await fixture.until(.seconds(10)) { await Self.homeNightVision(runtime) == .bool(false) }, "off: Night Vision off")

        control.refuse.set(true)
        control.mode.set(nil)
        let characteristic = try #require(await runtime.controller?.operatingModeService?.existingCharacteristic(.nightVision))
        _ = try await characteristic.handleWrite(.bool(true), context: HAPRequestContext(session: Session()))
        #expect(await fixture.until(.seconds(5)) { await runtime.nightVisionReading.mode == nil }, "the page shows no mode")
        #expect(await fixture.until(.seconds(5)) { await Self.homeNightVision(runtime) == .bool(false) }, "Home shows off again, not the refused on")

        await fixture.tearDown()
        await server.stop()
    }

    /// A Home write the runtime cannot follow (the camera has not said what its night vision offers yet, while Home shows Night Vision
    /// from the accessory's saved state): Home goes back, the write is not dropped with Home showing a change that never happened.
    @MainActor @Test(.timeLimit(.minutes(1))) func aHomeWriteTheRuntimeCannotFollowIsPutBack() async throws {
        let control = FakeNightVision()
        control.silent.set(true)
        let (fixture, server, runtime, id) = try await running(control)
        #expect(await fixture.until(.seconds(10)) { await runtime.controller != nil })
        await runtime.controller?.setNightVision(true)   // as the saved state brings it back after a restart
        let characteristic = try #require(await runtime.controller?.operatingModeService?.existingCharacteristic(.nightVision))

        _ = try await characteristic.handleWrite(.bool(false), context: HAPRequestContext(session: Session()))
        #expect(await fixture.until(.seconds(5)) { await Self.homeNightVision(runtime) == .bool(true) }, "put back")
        #expect(control.modesSet.value.isEmpty && fixture.status(id)?.nightVision == nil)

        await fixture.tearDown()
        await server.stop()
    }

    /// After a restart Home shows Night Vision from the accessory's saved state before the camera has said anything. A Home write of the
    /// value Home already shows (a scene) that the runtime cannot follow yet leaves Home as it was, not turned to the opposite and saved.
    @MainActor @Test(.timeLimit(.minutes(1))) func aHomeWriteOfTheSavedValueTheRuntimeCannotFollowLeavesHomeAsItWas() async throws {
        let control = FakeNightVision()
        let (fixture, server, runtime, id) = try await running(control)
        #expect(await fixture.until(.seconds(10)) { await Self.homeNightVision(runtime) == .bool(true) }, "auto: Night Vision on, saved")

        await fixture.engine.stop()
        control.silent.set(true)
        await fixture.engine.start()
        let restarted = try #require(fixture.engine.runtimes[id])
        #expect(await fixture.until(.seconds(10)) { await Self.homeNightVision(restarted) == .bool(true) }, "from the saved state")
        #expect(fixture.status(id)?.nightVision == nil, "the camera has not said what its night vision offers")

        await restarted.homeKitNightVision(true)
        #expect(await Self.homeNightVision(restarted) == .bool(true), "Home still shows Night Vision on")
        #expect(await restarted.controller?.operatingState.nightVision == true, "and keeps it")
        #expect(control.modesSet.value.isEmpty)

        await fixture.tearDown()
        await server.stop()
    }

    /// The camera says what its night vision offers but not its mode, so Home shows Night Vision as the accessory had it. A Home write of
    /// that value the camera refuses, with its mode still unreadable, leaves Home as it was.
    @MainActor @Test(.timeLimit(.minutes(1))) func aRefusedHomeWriteOfTheShownValueWithNoModeEverReadLeavesHomeAsItWas() async throws {
        let control = FakeNightVision()
        control.mode.set(nil)
        control.refuse.set(true)
        let (fixture, server, runtime, id) = try await running(control)
        #expect(await fixture.waitFor(.seconds(10)) { fixture.status(id)?.nightVision?.modes == [.auto, .on, .off] })
        #expect(await fixture.until(.seconds(5)) { await Self.homeNightVision(runtime) == .bool(true) }, "the accessory's own value")
        #expect(await runtime.nightVisionReading.mode == nil)

        await runtime.homeKitNightVision(true)
        #expect(await Self.homeNightVision(runtime) == .bool(true), "Home still shows Night Vision on")
        #expect(await runtime.controller?.operatingState.nightVision == true)

        await fixture.tearDown()
        await server.stop()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func aCameraThatCannotTurnItOffGetsNoNightVisionInHome() async throws {
        let control = FakeNightVision(modes: [.auto])
        let (fixture, server, runtime, id) = try await running(control)
        #expect(await fixture.waitFor(.seconds(10)) { fixture.status(id)?.nightVision?.modes == [.auto] })
        #expect(await fixture.until(.seconds(5)) { await runtime.controller != nil })
        #expect(await runtime.controller?.offersNightVision == false)
        #expect(await Self.homeNightVision(runtime) == nil)
        #expect(!CameraRuntime.offersHomeKitNightVision(NightVisionCapabilities(modes: [.on, .off], light: false)))
        #expect(CameraRuntime.offersHomeKitNightVision(NightVisionCapabilities(modes: [.auto, .off], light: false)))
        await fixture.tearDown()
        await server.stop()
    }
}
#endif
