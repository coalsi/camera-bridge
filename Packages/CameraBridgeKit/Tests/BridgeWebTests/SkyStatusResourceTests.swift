import BridgeEngine
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The Sky Watcher's status on a camera's resource (`status.sky`, Task 7): absent while it is off for the camera, else every key the card reads,
/// an unknown value null.
@Suite(.timeLimit(.minutes(2))) struct SkyStatusResourceTests {
    @Test func theCameraStatusCarriesTheSkyWhenItIsOn() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        let added = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": "192.168.77.30", "username": "viewer", "password": "pw",
                                                                         "name": "North Sky"])
        let id = try #require(UUID(uuidString: added.json["id"] as? String ?? ""), "\(added.text)")
        let path = "/api/v1/cameras/\(id.uuidString)"
        // Off: no key.
        let off = try #require((await session.get(path)).json["status"] as? [String: Any])
        #expect(!off.keys.contains("sky"), "\(off.keys.sorted())")

        // Watching: the stream, how fast, where it is decoded, the aim by lens, the learning, no problem.
        let aim = SkyAimStatus(quality: .good, planes: 23, stars: 0, residualPixels: 14.2, updated: Date(timeIntervalSince1970: 1_792_915_920), lenses: [
            SkyLensAimStatus(quality: .good, planes: 12, stars: 0, residualPixels: 13.1), SkyLensAimStatus(quality: .good, planes: 11, stars: 0, residualPixels: nil),
        ], note: nil)
        var status = CameraStatus(id: id, name: "North Sky", kind: .camera, vendor: .hikvision, connection: .online)
        status.sky = SkyCameraStatus(running: true, stream: "main", analysisWidth: 1920, picturesPerSecond: 5, decoding: "software", aim: aim,
                                     learning: SkyLearning(ready: false, planes: 12, satellites: 0), problem: nil, profile: nil)
        backend.write { $0.statusOverrides[id] = status }
        let sky = try #require(((await session.get(path)).json["status"] as? [String: Any])?["sky"] as? [String: Any])
        #expect(Set(sky.keys) == ["running", "stream", "analysisWidth", "picturesPerSecond", "decoding", "aim", "learning", "problem", "profile"], "\(sky.keys.sorted())")
        #expect(sky["running"] as? Bool == true && sky["stream"] as? String == "main" && sky["analysisWidth"] as? Int == 1920)
        #expect(sky["picturesPerSecond"] as? Double == 5 && sky["decoding"] as? String == "software" && sky["problem"] is NSNull && sky["profile"] is NSNull)
        let shown = try #require(sky["aim"] as? [String: Any])
        #expect(shown["quality"] as? String == "good" && shown["planes"] as? Int == 23 && shown["stars"] as? Int == 0 && shown["residualPixels"] as? Double == 14.2)
        #expect(shown["updated"] as? Int64 == 1_792_915_920_000 && shown["note"] is NSNull)
        let lenses = try #require(shown["lenses"] as? [[String: Any]])
        #expect(lenses.count == 2 && lenses[0]["planes"] as? Int == 12 && lenses[1]["residualPixels"] is NSNull)
        let learning = try #require(sky["learning"] as? [String: Any])
        #expect(learning["ready"] as? Bool == false && learning["planes"] as? Int == 12 && learning["satellites"] as? Int == 0)
        #expect(learning["planesNeeded"] as? Int == 30 && learning["satellitesNeeded"] as? Int == 10)

        // Wanted but unable to run: not running, the reason as a sentence, nothing about a stream.
        status.sky = SkyCameraStatus(running: false, stream: nil, analysisWidth: nil, picturesPerSecond: nil, decoding: nil, aim: SkyAimStatus(
            quality: .rough, planes: 0, stars: 0, residualPixels: nil, updated: nil), learning: SkyLearning(ready: false, planes: 0, satellites: 0),
                                     problem: "Set where the box is first.", profile: nil)
        backend.write { $0.statusOverrides[id] = status }
        let stopped = try #require(((await session.get("/api/v1/cameras")).array("cameras").first?["status"] as? [String: Any])?["sky"] as? [String: Any])
        #expect(stopped["running"] as? Bool == false && stopped["problem"] as? String == "Set where the box is first.")
        #expect(stopped["stream"] is NSNull && stopped["analysisWidth"] is NSNull && stopped["picturesPerSecond"] is NSNull && stopped["decoding"] is NSNull)
        let rough = try #require(stopped["aim"] as? [String: Any])
        #expect(rough["quality"] as? String == "rough" && rough["residualPixels"] is NSNull && rough["updated"] is NSNull && (rough["lenses"] as? [Any])?.isEmpty == true)
    }
}
