#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import PlatformApple
import TestSupport
import Testing
@testable import BridgeEngine

/// Review finding (W4 App): the camera page's log shows only entries tagged with the camera, but HAP, HAPCamera, HDS
/// and RTSP logged without a camera ID — pairing, "Recording turned on", the hub's recording selection, recording
/// stream opens and closes, HDS connections and RTSP connection changes never reached it, and with two cameras the
/// Settings log couldn't tell whose lines they were.
@Suite(.serialized) struct RuntimeCameraLogTests {
    @MainActor static func tagged(_ engine: BridgeEngine, _ cameraID: UUID, _ category: String, _ prefix: String) -> Bool {
        engine.recentLogs.contains { $0.cameraID == cameraID && $0.category == category && $0.message.hasPrefix(prefix) }
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func accessoryRecordingAndDataStreamLinesNameTheirCamera() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Logbook Porch")   // a name no other test uses (the log hub is process-wide)
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online && fixture.status(camera.id)?.hapPort != nil })
        let status = try #require(fixture.status(camera.id))
        let controller = try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
        let ids = try await controller.cameraIDs()
        let recordingIDs = try #require(ids.recording)
        let supported = try await controller.supportedRecordingConfiguration(recordingIDs)
        try await controller.selectRecordingConfiguration(recordingIDs, try .preferred(camera: supported.camera, video: supported.video,
                                                                                      audio: supported.audio))
        try await controller.enableRecording(ids, audio: false)
        let dataStream = try await controller.openDataStream(try #require(ids.setupDataStreamTransport))
        let open = try await dataStream.openRecording(streamID: 1)
        #expect(open.isAccepted)
        try await dataStream.closeRecording(streamID: 1)

        let id = camera.id
        #expect(await fixture.waitFor { Self.tagged(engine, id, "hap", "Logbook Porch paired with controller") }, "HAP (AccessoryServer)")
        #expect(await fixture.waitFor { Self.tagged(engine, id, "camera", "Recording turned on") }, "HAPCamera (CameraController)")
        #expect(await fixture.waitFor { Self.tagged(engine, id, "camera", "The hub selected recording") })
        #expect(await fixture.waitFor { Self.tagged(engine, id, "camera", "Recording stream 1 opened") }, "HAPCamera (RecordingStream)")
        #expect(await fixture.waitFor { Self.tagged(engine, id, "camera", "Recording stream 1 ended") })
        #expect(await fixture.waitFor { Self.tagged(engine, id, "HDS", "HDS listener started") }, "HDS (DataStreamServer)")
        #expect(await fixture.waitFor { Self.tagged(engine, id, "HDS", "HDS connection") })
        // The accessory's lines (they name it) are all tagged. Other layers' lines name no camera, and tests running
        // alongside log untagged ones of their own into the same hub, so those are checked by their tags above.
        let untagged = engine.recentLogs.filter { $0.cameraID == nil && $0.category == "hap" && $0.message.contains("Logbook Porch") }
        #expect(untagged.isEmpty, "\(untagged.map(\.message))")
        await dataStream.close()
        await controller.close()
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func rtspLinesNameTheirCamera() async throws {
        let server = RTSPTestServer(source: syntheticSource(width: 320, height: 180, fps: 15, gop: .seconds(1), audio: nil),
                                    transport: AppleNetworkTransport())
        try await server.start()
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let camera = RuntimeCameraLifecycleTests.rtspCamera("Gate", server: server)
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(await fixture.waitFor { Self.tagged(engine, camera.id, "rtsp", "Connected to rtsp://") }, "RTSP (RTSPClient)")
        #expect(await fixture.waitFor { Self.tagged(engine, camera.id, "rtsp", "Playing rtsp://") })
        await fixture.tearDown()
        await server.stop()
    }

    /// Review finding (W4 round 4): the driver a runtime builds logged without the camera's ID (`CameraDrivers.make` took
    /// none), so the camera page never showed why its event channel dropped, nor its camera API and two-way audio
    /// lines. The runtime hands the driver its camera's ID.
    @MainActor @Test(.timeLimit(.minutes(2))) func driverLinesNameTheirCamera() async throws {
        let listener = try await AppleNetworkTransport().listen(port: 0, loopbackOnly: true)
        let port = Int(listener.port)
        listener.close()   // nothing answers there: the ONVIF event channel fails
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let camera = CameraConfiguration(name: "Logbook Gate", kind: .camera, vendor: .onvif,
                                         endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: port, rtspPort: port, onvifPort: port),
                                         username: "admin")
        try await engine.addCamera(camera, password: "secret")
        await engine.start()
        #expect(await fixture.waitFor(.seconds(20)) { Self.tagged(engine, camera.id, "events", "ONVIF 127.0.0.1: event channel failed") },
                "the event source's failure is on the camera's log")
        await fixture.tearDown()
    }

    /// The configuration of every RTSP session the runtime opens carries the camera's ID (its log lines are tagged).
    @Test func streamSourcesTagTheirSessionsWithTheCamera() {
        let id = UUID()
        let configuration = StreamSources.rtspConfiguration(url: URL(string: "rtsp://192.0.2.10/stream1")!, credentials: nil, cameraID: id)
        #expect(configuration.cameraID == id)
    }
}
#endif
