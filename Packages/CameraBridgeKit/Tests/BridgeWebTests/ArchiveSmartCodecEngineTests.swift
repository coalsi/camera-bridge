#if canImport(Darwin)
import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The smart-codec path on the real engine: a demo camera that keys every 12 s, recorded by the real recorder into the real store, read through
/// the real routes. Needs T01 and T02 (against the placeholder store nothing is ever ready).
@Suite(.timeLimit(.minutes(4))) struct NVRSmartCodecEngineTests {
    private let gigabyte: UInt64 = 1_000_000_000

    @MainActor @Test func aTwelveSecondKeyframeIntervalGivesTheNoteATypicalGOPOfTwelveAndAPlanThatStartsAtTheKeyFragment() async throws {
        let directory = try TemporaryDirectory()
        let recordings = try TemporaryDirectory()
        defer { directory.remove(); recordings.remove() }
        var environment = BridgeEnvironment.testing(directory: directory.url)
        environment.demoKeyframeSeconds = 12
        let roomy = gigabyte * 1_000
        environment.archivePolicy = ArchivePlatformPolicy(space: { _ in (total: roomy, free: roomy * 9 / 10) }, isSystemVolume: { _ in false },
                                                          systemFloor: { $0 / 20 }, directoryNaming: .cameraID)
        let engine = BridgeEngine(environment: environment)
        await engine.start()
        try await engine.updateSettings { $0.nvrFolder = recordings.url.path(percentEncoded: false) }
        let camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
        try await engine.addCamera(camera, password: nil)
        try await engine.setNVR(cameraID: camera.id, enabled: true, recordSound: false)

        let harness = try Harness()
        let session = try await harness.signIn()
        let app = WebApp(configuration: harness.app.configuration, backend: EngineBackend(engine: engine), system: harness.system, logs: harness.logs)
        func get(_ path: String) async -> Answer {
            let response = await app.handle(harness.request("GET", "/api/v1/\(path)", cookie: session.cookie))
            return Answer(status: response.status, headers: response.headers, body: response.bodyData ?? Data())
        }
        let id = camera.id.uuidString

        // About a minute of video: keys at 0, 12, 24, 36 and 48 s give the median interval and the recorder's note.
        var extent: [String: Any]?
        var notes: [[String: Any]] = []
        let deadline = ContinuousClock.now + .seconds(150)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(3))
            extent = (await get("nvr/cameras").json["cameras"] as? [[String: Any]])?.first
            notes = ((await get("cameras/\(id)").object("status")["nvr"] as? [String: Any])?["notes"] as? [[String: Any]]) ?? []
            if extent?["typicalGOP"] is Double, !notes.isEmpty, let newest = jsonInt(extent?["newest"]), let oldest = jsonInt(extent?["oldest"]), newest - oldest >= 50_000 { break }
        }
        let found = try #require(extent, "the camera has no recording after \(150) s")
        let gop = try #require(found["typicalGOP"] as? Double, "typicalGOP is null")
        #expect((10.5...13.5).contains(gop), "typicalGOP is \(gop) for a stream that keys every 12 s")
        #expect(notes.contains { $0["id"] as? String == "keyframe" && ($0["text"] as? String)?.hasPrefix("keyframe every 12 s") == true }, "notes: \(notes)")

        // A time 8 s into the first GOP: the plan starts at the key fragment and lists the continuation fragments after it.
        let oldest = try #require(jsonInt(found["oldest"]))
        let plan = await get("nvr/cameras/\(id)/fragments?at=\(oldest + 8_000)&ahead=0")
        #expect(plan.status == 200 && plan.json["found"] as? Bool == true, "\(plan.text.prefix(200))")
        let parts = plan.array("parts")
        let target = Int(plan.int("targetIndex") ?? -1)
        #expect(parts.count >= 3 && target >= 2 && target < parts.count, "a time 8 s after a key lies in the third fragment or later (2.5 s fragments): \(parts.count) parts, target \(target)")
        #expect(parts.first?["key"] as? Bool == true && parts.dropFirst().allSatisfy { $0["key"] as? Bool == false }, "one key fragment, then continuation fragments")
        let keyframe = await get("nvr/cameras/\(id)/keyframe?at=\(oldest + 8_000)")
        #expect(keyframe.status == 200 && keyframe.body.count > 0 && keyframe.body.count <= 16 * 1_048_576)
        #expect(keyframe.headers["X-CB-Part"]?.contains("\"id\":\"\(parts.first?["id"] as? String ?? "?")\"") == true, "the key picture is the plan's first part")
        await engine.stop()
    }
}
#endif
