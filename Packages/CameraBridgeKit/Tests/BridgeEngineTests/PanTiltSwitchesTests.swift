import BridgeSupport
import CameraAdapters
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// The owner's pan, tilt and zoom switches (`CameraConfiguration.panTiltEnabled`, `.zoomEnabled`), for the fixed cameras that say they pan,
/// tilt and zoom: a configuration saved before they existed reads as the camera's control says, a change never restarts the camera,
/// `CameraStatus.panTilt` and `.zoom` are what the control says less what the owner turned off (`panTiltDetected` and `zoomDetected` keep
/// what it said), and `BridgeEngine.panTilt` refuses a move or a zoom that is turned off before anything reaches the camera.
@Suite(.serialized) struct PanTiltSwitchesTests {
    private func camera() -> CameraConfiguration {
        CameraConfiguration(name: "Patio", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.30"), username: "admin")
    }

    // MARK: Configuration

    @Test func aConfigurationSavedBeforeTheSwitchesExistedTakesTheControlsWord() throws {
        // The keys of a camera saved by an earlier build: nothing about the switches.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Patio","kind":"camera","vendor":"onvif","endpoint":{"host":"192.0.2.30","httpPort":80,"rtspPort":554,"useHTTPS":false},
         "username":"admin","liveQualityMode":"originalQuality","aiDescriptions":true}
        """
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: Data(json.utf8))
        #expect(decoded.panTiltEnabled == nil && decoded.zoomEnabled == nil)
        #expect(decoded.liveQualityMode == .originalQuality && decoded.aiDescriptions, "the rest still reads")
        #expect(camera().panTiltEnabled == nil && camera().zoomEnabled == nil, "a new camera takes its control's word too")
    }

    @Test func theSwitchesAreSavedOnlyOnceSet() throws {
        let untouched = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(camera())) as? [String: Any])
        #expect(!untouched.keys.contains("panTiltEnabled") && !untouched.keys.contains("zoomEnabled"), "absent by default")
        var config = camera()
        config.panTiltEnabled = false
        config.zoomEnabled = true
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(CameraConfiguration.self, from: data) == config)
        let written = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(written["panTiltEnabled"] as? Bool == false && written["zoomEnabled"] as? Bool == true)
    }

    @Test func anUnreadableSwitchTakesTheControlsWordAndTheRestStillLoads() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Patio","kind":"camera","vendor":"onvif","endpoint":{"host":"192.0.2.30","httpPort":80,"rtspPort":554,"useHTTPS":false},
         "username":"admin","panTiltEnabled":"no","zoomEnabled":false,"liveQualityMode":"originalQuality"}
        """
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: Data(json.utf8))
        #expect(decoded.panTiltEnabled == nil)
        #expect(decoded.zoomEnabled == false)
        #expect(decoded.liveQualityMode == .originalQuality)
    }

    // MARK: Restarts

    @MainActor @Test func changingTheSwitchesNeverRestartsTheCamera() {
        let old = camera()
        let changes: [(inout CameraConfiguration) -> Void] = [{ $0.panTiltEnabled = false }, { $0.zoomEnabled = false },
                                                              { $0.panTiltEnabled = true; $0.zoomEnabled = true }]
        for change in changes {
            var new = old
            change(&new)
            #expect(!BridgeEngine.needsRestart(old, new, paired: true) && !BridgeEngine.needsRestart(new, old, paired: false))
        }
        // Another change still restarts, switches or not.
        var other = old
        other.panTiltEnabled = false
        other.endpoint.host = "192.0.2.31"
        #expect(BridgeEngine.needsRestart(old, other, paired: true))
    }
}

#if canImport(Darwin)
extension PanTiltSwitchesTests {
    /// A camera's pan/tilt control: what it says it can do, and what reached it (moves and zoom steps; the stops the runtime sends 1.5 s
    /// after a move are kept apart).
    final class FakePanTilt: PanTiltControl, Sendable {
        let says: PanTiltCapabilities
        let calls = Box<[String]>([])
        let stops = Box(0)

        init(says: PanTiltCapabilities) { self.says = says }

        func capabilities() async throws -> PanTiltCapabilities { says }
        func move(pan: Double, tilt: Double) async throws { calls.update { $0.append("move \(pan) \(tilt)") } }
        func stop() async throws { stops.update { $0 += 1 } }
        func zoom(_ speed: Double) async throws { calls.update { $0.append("zoom \(speed)") } }
    }

    final class PanTiltDriver: CameraDriver, Sendable {
        let vendor: CameraVendor = .demo
        let control: FakePanTilt

        init(_ control: FakePanTilt) { self.control = control }

        func probe() async throws -> CameraProbeResult { throw CameraAdapterError.unsupported("scripted driver") }
        func makeEventSource() -> (any CameraEventSource)? { nil }
        func snapshot() async throws -> Data? { nil }
        func makeTalkbackSink() -> (any TalkbackSink)? { nil }
        func makePanTilt() -> (any PanTiltControl)? { control }
    }

    /// The demo camera "Patio" with `control` as its pan/tilt control, running, once its control has answered.
    @MainActor private func running(_ control: FakePanTilt, _ configure: (inout CameraConfiguration) -> Void = { _ in }) async throws
        -> (EngineFixture, UUID) {
        var tuning = EngineTuning.testing
        let driver = PanTiltDriver(control)
        tuning.driverFactory = { _, _, _ in driver }
        let fixture = try await EngineFixture(tuning: tuning)
        var camera = EngineFixture.demoCamera(name: "Patio")
        configure(&camera)
        let id = camera.id
        try await fixture.engine.addCamera(camera, password: nil)
        await fixture.engine.start()
        let says = control.says
        #expect(await fixture.waitFor(.seconds(10)) {
            fixture.status(id).map { $0.panTiltDetected == says.panTilt && $0.zoomDetected == says.zoom } ?? false
        }, "the control answered")
        return (fixture, id)
    }

    /// The camera's status once `holds` says it is what a change made it (the change's own refresh publishes it; a refresh another
    /// operation overtook comes again).
    @MainActor private func statusWhen(_ fixture: EngineFixture, _ id: UUID, _ holds: (CameraStatus) -> Bool) async throws -> CameraStatus {
        #expect(await fixture.waitFor(.seconds(5)) { fixture.status(id).map(holds) ?? false })
        return try #require(fixture.status(id))
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func theOwnerTurnsOffWhatTheControlSaysInPlace() async throws {
        let control = FakePanTilt(says: PanTiltCapabilities(panTilt: true, zoom: true))
        let (fixture, id) = try await running(control)
        let engine = fixture.engine
        let runtime = try #require(engine.runtimes[id])
        let first = try #require(fixture.status(id))
        #expect(first.panTilt && first.zoom, "as the control says")

        // Pan and tilt off: the status says so, zoom stays, and a move (a stop too) is refused before it reaches the camera, as for a
        // camera without the control.
        try await engine.updateCamera(id: id, password: nil) { $0.panTiltEnabled = false }
        let off = try await statusWhen(fixture, id) { !$0.panTilt }
        #expect(off.panTiltDetected, "still what the control says")
        #expect(off.zoom && off.zoomDetected)
        #expect(engine.runtimes[id] === runtime, "applied in place: the camera was not restarted")
        await #expect(throws: EngineError.cameraNotRunning) { try await engine.panTilt(cameraID: id, pan: 1, tilt: 0) }
        await #expect(throws: EngineError.cameraNotRunning) { try await engine.panTilt(cameraID: id, pan: 0, tilt: 0) }
        try await engine.panTilt(cameraID: id, pan: 0, tilt: 0, zoom: 1)
        #expect(control.calls.value == ["zoom 1.0"], "only the zoom reached the camera")

        // Zoom off too: nothing reaches the camera any more.
        try await engine.updateCamera(id: id, password: nil) { $0.zoomEnabled = false }
        let both = try await statusWhen(fixture, id) { !$0.zoom }
        #expect(!both.panTilt && both.panTiltDetected && both.zoomDetected)
        await #expect(throws: EngineError.cameraNotRunning) { try await engine.panTilt(cameraID: id, pan: 0, tilt: 0, zoom: -1) }
        await #expect(throws: EngineError.cameraNotRunning) { try await engine.panTilt(cameraID: id, pan: 0, tilt: 1) }
        #expect(control.calls.value == ["zoom 1.0"])
        #expect(control.stops.value == 0, "not even a stop")

        // Back on, by saying so or by leaving it to the control again: the camera moves and zooms again, still without a restart.
        try await engine.updateCamera(id: id, password: nil) { $0.panTiltEnabled = true; $0.zoomEnabled = nil }
        _ = try await statusWhen(fixture, id) { $0.panTilt && $0.zoom }
        try await engine.panTilt(cameraID: id, pan: 0.5, tilt: 0)
        try await engine.panTilt(cameraID: id, pan: 0, tilt: 0, zoom: -1)
        #expect(control.calls.value == ["zoom 1.0", "move 0.5 0.0", "zoom -1.0"])
        #expect(engine.runtimes[id] === runtime)

        // Saved with the camera: the configuration read back has them.
        let saved = try #require(try ConfigurationStore(directory: fixture.directory.url).load()?.cameras.first(where: { $0.id == id }))
        #expect(saved.panTiltEnabled == true && saved.zoomEnabled == nil)
        await fixture.tearDown()
    }

    /// The switches only take away: on, they never give a camera what its control does not say; off when the camera starts (a saved
    /// configuration), the status never offers it.
    @MainActor @Test(.timeLimit(.minutes(1))) func theSwitchesOnlyTakeAway() async throws {
        let control = FakePanTilt(says: PanTiltCapabilities(panTilt: false, zoom: true))
        let (fixture, id) = try await running(control) { $0.panTiltEnabled = true; $0.zoomEnabled = false }
        let status = try #require(fixture.status(id))
        #expect(!status.panTilt && !status.panTiltDetected, "on is the control's word, and the control says no")
        #expect(!status.zoom && status.zoomDetected, "off from the start")
        await #expect(throws: EngineError.cameraNotRunning) { try await fixture.engine.panTilt(cameraID: id, pan: 1, tilt: 0) }
        await #expect(throws: EngineError.cameraNotRunning) { try await fixture.engine.panTilt(cameraID: id, pan: 0, tilt: 0, zoom: 1) }
        #expect(control.calls.value.isEmpty)
        await fixture.tearDown()
    }
}
#endif
