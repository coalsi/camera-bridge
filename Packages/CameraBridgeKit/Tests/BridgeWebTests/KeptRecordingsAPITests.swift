import BridgeEngine
import Foundation
import Testing
@testable import BridgeWeb

/// `nvr/kept`: keep a stretch, list it with its camera's name, let it go; what cannot be kept is answered with the store's sentence.
@Suite struct KeptRecordingsAPITests {
    @Test func aStretchIsKeptListedAndLetGo() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 4)]
        let made = await rig.session.send("POST", "/api/v1/nvr/kept", json: ["cameraID": rig.cameraID, "from": rig.ms(1_000), "to": rig.ms(5_000), "note": "the parcel"])
        #expect(made.status == 201, "\(made.status) \(made.json)")
        let id = try #require(made.json["id"] as? String)
        #expect(made.json["cameraName"] as? String == "Porch" && made.json["note"] as? String == "the parcel" && made.int("from") == rig.ms(1_000))
        let list = await rig.get("nvr/kept").array("kept")
        #expect(list.count == 1 && list[0]["id"] as? String == id && jsonInt(list[0]["bytes"]) == 1_234)
        #expect(await rig.session.send("DELETE", "/api/v1/nvr/kept/\(id)").status == 204)
        #expect(await rig.get("nvr/kept").array("kept").isEmpty)
        #expect(await rig.session.send("DELETE", "/api/v1/nvr/kept/\(id)").status == 404, "already gone")
    }

    @Test func whatCannotBeKeptIsAnsweredWithASentence() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 4)]
        let backwards = await rig.session.send("POST", "/api/v1/nvr/kept", json: ["cameraID": rig.cameraID, "from": rig.ms(5_000), "to": rig.ms(1_000)])
        #expect(backwards.status == 400)
        let nothing = await rig.session.send("POST", "/api/v1/nvr/kept", json: ["cameraID": rig.cameraID, "from": rig.ms(86_400_000), "to": rig.ms(86_500_000)])
        #expect(nothing.status == 400 && (nothing.json["message"] as? String)?.contains("no recording") == true)
        let stranger = await rig.session.send("POST", "/api/v1/nvr/kept", json: ["cameraID": UUID().uuidString, "from": rig.ms(1_000), "to": rig.ms(5_000)])
        #expect(stranger.status == 404)
        #expect(await rig.session.send("DELETE", "/api/v1/nvr/kept/..%2Fconfig").status == 404, "only an id is an id")
    }
}
