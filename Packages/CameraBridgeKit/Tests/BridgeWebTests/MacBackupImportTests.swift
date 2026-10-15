import BridgeEngine
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// Importing the Mac app's configuration backup on the box (Settings › Move from Camera Bridge for Mac).
@Suite struct MacBackupImportTests {
    static let origin = "http://camera-bridge.local"

    /// A backup exactly as the Mac app writes it (`ConfigurationBackup.encoded()`): sorted keys, ISO 8601 dates.
    static func backup(_ cameras: [CameraConfiguration], extra: [Any] = []) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entries = try cameras.map { try JSONSerialization.jsonObject(with: try encoder.encode($0)) } + extra
        return ["kind": "CameraBridgeBackup", "version": 1, "exportedAt": "2026-10-13T20:00:00Z", "appVersion": "1.1 (9)",
                "settings": ["webhookEnabled": false, "webhookPort": 8080, "keepMacAwake": true, "sensorsBridgePort": 51900, "logLevel": "info", "basePort": 51100],
                "cameras": entries] as [String: Any]
    }

    static func camera(_ name: String, record: Bool = true, port: UInt16 = 51_101) -> CameraConfiguration {
        var camera = CameraConfiguration(name: name, kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.\(name.count)"), username: "admin")
        camera.hapPort = port
        camera.nvrEnabled = record
        camera.isEnabled = true
        return camera
    }

    @Test func thePreviewListsTheCamerasAndWhatIsAlreadyHere() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let backyard = Self.camera("Backyard"), patio = Self.camera("Patio", record: false)
        try await harness.backend.addCamera(patio, password: "x")
        let both = try Self.backup([backyard, patio], extra: [["id": "not a camera"]])
        let preview = await session.send("POST", "/api/v1/import/mac-backup/preview", json: ["file": both])
        #expect(preview.status == 200, "\(preview.json)")
        let cameras = preview.json["cameras"] as? [[String: Any]] ?? []
        #expect(cameras.map { $0["name"] as? String } == ["Backyard", "Patio"])
        #expect(cameras.map { $0["alreadySetUp"] as? Bool } == [false, true] && cameras.first?["record"] as? Bool == true)
        #expect(cameras.first?["host"] as? String == "192.0.2.8" && cameras.first?["username"] as? String == "admin")
        #expect(preview.json["unreadable"] as? Int == 1 && preview.json["appVersion"] as? String == "1.1 (9)")
        #expect(await session.send("POST", "/api/v1/import/mac-backup/preview", json: ["file": ["kind": "Other"]]).status == 400)
        #expect(await session.send("POST", "/api/v1/import/mac-backup/preview", json: ["file": ["kind": "CameraBridgeBackup", "version": 9, "cameras": []]]).status == 400)
        let file = try Self.backup([backyard])
        #expect(await harness.send("POST", "/api/v1/import/mac-backup/preview", json: ["file": file], origin: Self.origin).status == 401, "only a signed-in person imports")
    }

    @Test func importingAddsTheCamerasWithTheirPasswordsOnAndWithoutOff() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let backyard = Self.camera("Backyard"), driveway = Self.camera("Driveway", port: 51_102)
        let file = try Self.backup([backyard, driveway])
        let result = await session.send("POST", "/api/v1/import/mac-backup", json: ["file": file, "passwords": [backyard.id.uuidString: "secret-1"]])
        #expect(result.status == 200, "\(result.json)")
        #expect(result.json["added"] as? [String] == ["Backyard"] && result.json["addedOff"] as? [String] == ["Driveway"])
        let overview = await harness.backend.overview()
        let added = overview.configurations
        #expect(added.map(\.id) == [backyard.id, driveway.id], "the cameras keep their identity")
        let freshPorts = added.allSatisfy { $0.hapPort == 0 }
        #expect(freshPorts, "the Mac's HomeKit ports are not kept: the box gives its own")
        #expect(added.first?.isEnabled == true && added.last?.isEnabled == false, "on with a password, off without")
        let recordsAll = added.allSatisfy { $0.nvrEnabled }
        #expect(recordsAll, "Record stays as it was")
        #expect(result.json["recordingPlaceChosen"] as? Bool == (harness.app.configuration.archiveLocations.isEmpty ? false : true))
        let again = await session.send("POST", "/api/v1/import/mac-backup", json: ["file": file, "passwords": [:] as [String: String]])
        #expect(again.json["alreadySetUp"] as? [String] == ["Backyard", "Driveway"] && (again.json["added"] as? [String])?.isEmpty == true,
                "the same file twice adds nothing twice")
    }
}
