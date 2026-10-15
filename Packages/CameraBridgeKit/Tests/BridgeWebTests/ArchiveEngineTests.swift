import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The Record switch and an ordinary camera edit, through the web routes, on the real engine (not the fake): neither undoes the other.
@Suite(.timeLimit(.minutes(2))) struct NVRRealEngineAPITests {
    @MainActor @Test func theRecordSwitchAndAnEditMadeAtTheSameTimeBothSurvive() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = BridgeEngine(environment: .testing(directory: directory.url))
        let camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
        try await engine.addCamera(camera, password: nil)
        try await engine.updateSettings { $0.nvrFolder = "/Volumes/Recordings" }
        let harness = try Harness()
        let session = try await harness.signIn()
        let app = WebApp(configuration: harness.app.configuration, backend: EngineBackend(engine: engine), system: harness.system, logs: harness.logs)
        func send(_ method: String, _ path: String, _ body: [String: Any]) async -> HTTPResponse {
            await app.handle(harness.request(method, path, json: body, cookie: session.cookie, csrf: session.csrf))
        }
        let id = camera.id.uuidString
        var last = (record: false, sound: false, audio: true)
        for round in 0..<60 {
            let record = round.isMultiple(of: 2), sound = round % 3 == 0, audio = round % 4 != 0
            last = (record, sound, audio)
            async let recordSwitch = send("PATCH", "/api/v1/cameras/\(id)/nvr", ["enabled": record, "recordSound": sound])
            async let edit = send("PATCH", "/api/v1/cameras/\(id)", ["audioEnabled": audio])
            let (first, second) = await (recordSwitch, edit)
            #expect(first.status == 200 && second.status == 200, "round \(round)")
            let stored = try #require(engine.configurations.first)
            #expect(stored.nvrEnabled == record && stored.nvrRecordSound == sound && stored.audioEnabled == audio, "round \(round): both changes are there")
        }
        let reread = try #require(try ConfigurationStore(directory: directory.url).load()?.cameras.first)
        #expect(reread.nvrEnabled == last.record && reread.nvrRecordSound == last.sound && reread.audioEnabled == last.audio, "and they were saved")
        // Record on a camera with no folder chosen is refused by the route, and the engine is never asked.
        try await engine.updateSettings { $0.nvrFolder = nil }
        _ = await send("PATCH", "/api/v1/cameras/\(id)/nvr", ["enabled": false])
        let refused = await send("PATCH", "/api/v1/cameras/\(id)/nvr", ["enabled": true])
        #expect(refused.status == 409)
        #expect(engine.configurations.first?.nvrEnabled == false)
    }
}
