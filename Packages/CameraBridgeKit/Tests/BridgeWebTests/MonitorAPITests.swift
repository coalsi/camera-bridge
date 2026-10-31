import BridgeEngine
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// `GET /api/v1/monitor`: read-only health for Home Assistant or Uptime Kuma, behind a token from Settings sent as a header.
@Suite(.timeLimit(.minutes(1))) struct MonitorAPITests {
    private func monitor(_ harness: Harness, token: String?, query: String = "") async -> Answer {
        await harness.send("GET", "/api/v1/monitor" + query, headers: token.map { [("Authorization", "Bearer \($0)")] } ?? [])
    }

    @Test func itAnswersOnlyWithItsTokenInAHeader() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let off = await monitor(harness, token: "anything")
        #expect(off.status == 403 && off.json["code"] as? String == "monitor_off")
        var settings = await session.get("/api/v1/settings")
        #expect(settings.json["monitorEnabled"] as? Bool == false && settings.json.keys.contains("monitorToken") && settings.json["monitorToken"] is NSNull)
        settings = await session.send("PATCH", "/api/v1/settings", json: ["monitorEnabled": true])
        let token = try #require(settings.json["monitorToken"] as? String)
        #expect(settings.json["monitorEnabled"] as? Bool == true && token.count >= 43)

        #expect(await monitor(harness, token: nil).status == 401)
        let wrong = await monitor(harness, token: token + "x")
        #expect(wrong.status == 401 && wrong.json["code"] as? String == "monitor_token" && wrong.headers["WWW-Authenticate"] == "Bearer")
        #expect(await harness.send("GET", "/api/v1/monitor", cookie: session.cookie).status == 401, "a session alone is not the token")
        let inTheAddress = await monitor(harness, token: token, query: "?token=\(token)")
        #expect(inTheAddress.status == 400, "a token in a URL ends up in logs and histories")
        let right = await monitor(harness, token: token)
        #expect(right.status == 200)
        #expect(Set(right.json.keys) == ["time", "version", "state", "cameras", "recordings", "archive", "update", "signIn"])
        #expect(right.json["state"] as? String == "running" && right.json["version"] as? String == "0.1")

        settings = await session.send("PATCH", "/api/v1/settings", json: ["regenerateMonitorToken": true])
        let fresh = try #require(settings.json["monitorToken"] as? String)
        #expect(fresh != token)
        #expect(await monitor(harness, token: token).status == 401)
        #expect(await monitor(harness, token: fresh).status == 200)
        settings = await session.send("PATCH", "/api/v1/settings", json: ["monitorEnabled": false])
        #expect(settings.json["monitorEnabled"] as? Bool == false)
        #expect(await monitor(harness, token: fresh).status == 403)
    }

    @Test func itTellsEachCameraTheDrivesTheUpdateAndFailedSignIns() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 4)
        archive.files = [file]
        rig.backend.write { state in
            state.nvrStorage = ArchiveStorageStatus(folder: URL(fileURLWithPath: NVRRig.folder), freeBytes: 300_000_000_000, totalBytes: 500_000_000_000,
                                                    floorBytes: 50_000_000_000)
        }
        let token = try #require(await rig.session.send("PATCH", "/api/v1/settings", json: ["monitorEnabled": true]).json["monitorToken"] as? String)
        for _ in 0..<2 { _ = await rig.harness.send("POST", "/api/v1/auth/login", json: ["password": "wrong password"], from: "192.0.2.40") }
        let answer = await monitor(rig.harness, token: token)
        #expect(answer.status == 200)
        let cameras = try #require(answer.json["cameras"] as? [[String: Any]])
        let camera = try #require(cameras.first)
        #expect(Set(camera.keys) == ["id", "name", "enabled", "online", "connection", "recording", "recordingState", "lastSegment"])
        #expect(camera["id"] as? String == rig.cameraID && camera["online"] as? Bool == true && camera["connection"] as? String == "online")
        let newest = try #require(archive.extent(camera: rig.camera.id)?.newest)
        let last = try #require((camera["lastSegment"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
        #expect(abs(last.timeIntervalSince(newest)) < 1, "the end of the newest recorded piece")
        let recordings = try #require(answer.json["recordings"] as? [String: Any])
        #expect(recordings["state"] as? String == "ok" && jsonInt(recordings["freeBytes"]) == 300_000_000_000 && jsonInt(recordings["totalBytes"]) == 500_000_000_000)
        #expect(answer.json["archive"] is NSNull, "no archive drive")
        let update = try #require(answer.json["update"] as? [String: Any])
        #expect(update["current"] as? String == "0.1" && update.keys.contains("latest"))
        let signIn = try #require(answer.json["signIn"] as? [String: Any])
        #expect(jsonInt(signIn["failedLastHour"]) == 2 && jsonInt(signIn["failedLastDay"]) == 2 && jsonInt(signIn["lockedAddresses"]) == 0)
        #expect(signIn["everyoneWaits"] as? Bool == false)
    }
}
