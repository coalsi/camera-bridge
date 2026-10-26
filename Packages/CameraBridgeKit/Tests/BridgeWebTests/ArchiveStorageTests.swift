import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// `GET/PATCH /nvr/storage`, `GET /nvr/storage/locations` and `PATCH /cameras/:id/nvr` (contract C.5 R1 to R4).
@Suite(.timeLimit(.minutes(1))) struct NVRStorageAPITests {
    private let gigabyte: UInt64 = 1_000_000_000

    private func storage(used: UInt64 = 120, free: UInt64 = 300, total: UInt64 = 500, floor: UInt64 = 25, pause: ArchivePause? = nil, oldest: Date? = nil,
                         newest: Date? = nil) -> ArchiveStorageStatus {
        ArchiveStorageStatus(folder: URL(filePath: NVRRig.folder), pause: pause, usedBytes: used * gigabyte, freeBytes: free * gigabyte, totalBytes: total * gigabyte,
                             floorBytes: floor * gigabyte, oldest: oldest, newest: newest)
    }

    // MARK: R1

    @Test func beforeAFolderIsChosenEveryKeyIsThereAndTheStateIsNoFolder() async throws {
        let rig = try await NVRRig.make(folder: nil)
        let answer = await rig.get("nvr/storage")
        #expect(answer.status == 200)
        #expect(Set(answer.json.keys) == ["location", "label", "state", "message", "recordingCameras", "keepDays", "maxSizeGB", "limits", "usedBytes", "freeBytes",
                                          "totalBytes", "floorBytes", "roomBytes", "effectiveMaxBytes", "oldest", "newest", "archive"])
        #expect(answer.json["archive"] is NSNull, "no archive drive where the system has none")
        #expect(answer.json["location"] is NSNull && answer.json["label"] is NSNull && answer.json["oldest"] is NSNull && answer.json["newest"] is NSNull)
        #expect(answer.json["state"] as? String == "noFolder")
        #expect(answer.json["message"] as? String == "Choose where to store recordings.")
        #expect(answer.int("keepDays") == 7 && answer.int("maxSizeGB") == 500 && answer.int("recordingCameras") == 0)
        #expect(answer.object("limits")["keepDays"] as? [Int] == [1, 365] && answer.object("limits")["maxSizeGB"] as? [Int] == [10, 100_000])
        for key in ["usedBytes", "freeBytes", "totalBytes", "floorBytes", "roomBytes", "effectiveMaxBytes"] { #expect(answer.int(key) == 0, "\(key)") }
    }

    @Test func theNumbersComeFromTheEnginesStorageStatus() async throws {
        let rig = try await NVRRig.make()
        let oldest = Date(timeIntervalSince1970: Double(NVRRig.base) / 1000), newest = oldest.addingTimeInterval(86_400)
        rig.backend.write {
            $0.nvrStorage = storage(oldest: oldest, newest: newest)
            $0.configurations[0].nvrEnabled = true
        }
        let answer = await rig.get("nvr/storage")
        #expect(answer.json["location"] as? String == "builtin" && answer.json["label"] as? String == "This box’s storage")
        #expect(answer.json["state"] as? String == "ok" && answer.json["message"] is NSNull)
        #expect(answer.int("recordingCameras") == 1)
        #expect(answer.int("usedBytes") == 120_000_000_000 && answer.int("freeBytes") == 300_000_000_000 && answer.int("totalBytes") == 500_000_000_000)
        #expect(answer.int("floorBytes") == 25_000_000_000)
        #expect(answer.int("roomBytes") == 395_000_000_000, "used + (free - floor)")
        #expect(answer.int("effectiveMaxBytes") == 450_000_000_000, "min(500 GB, total - 2 x floor)")
        #expect(answer.int("oldest") == NVRRig.base && answer.int("newest") == NVRRig.base + 86_400_000)
    }

    @Test func theArchiveDriveIsInTheAnswerWithWhatMovesNow() async throws {
        let rig = try await NVRRig.make()
        let oldest = Date(timeIntervalSince1970: Double(NVRRig.base) / 1000)
        let camera = rig.camera
        rig.backend.write {
            var status = storage()
            status.archive = ArchiveDriveStatus(state: .connected, usedBytes: 900 * gigabyte, freeBytes: 2_700 * gigabyte, totalBytes: 4_000 * gigabyte,
                                                floorBytes: 2_147_483_648, oldest: oldest, newest: oldest.addingTimeInterval(3_600),
                                                moving: ArchiveDriveStatus.Move(camera: camera.id, start: oldest.addingTimeInterval(7_200), bytes: 450_000_000, doneBytes: 900_000_000),
                                                waitingFiles: 3, waitingBytes: 1_350_000_000, movedFiles: 12, movedBytes: 5_400_000_000)
            $0.nvrStorage = status
        }
        let answer = await rig.get("nvr/storage")
        let archive = answer.object("archive")
        #expect(Set(archive.keys) == ["state", "message", "usedBytes", "freeBytes", "totalBytes", "floorBytes", "oldest", "newest", "moving", "waitingFiles",
                                      "waitingBytes", "movedFiles", "movedBytes"])
        #expect(archive["state"] as? String == "connected" && archive["message"] is NSNull)
        #expect((archive["usedBytes"] as? NSNumber)?.int64Value == 900_000_000_000 && (archive["oldest"] as? NSNumber)?.int64Value == NVRRig.base)
        let moving = try #require(archive["moving"] as? [String: Any])
        #expect(moving["cameraID"] as? String == camera.id.uuidString && moving["cameraName"] as? String == camera.name)
        #expect((moving["start"] as? NSNumber)?.int64Value == NVRRig.base + 7_200_000)
        #expect((moving["doneBytes"] as? NSNumber)?.int64Value == 450_000_000, "never more than the file")
        #expect(archive["waitingFiles"] as? Int == 3 && archive["movedFiles"] as? Int == 12)
        rig.backend.write {
            var status = storage()
            status.archive = ArchiveDriveStatus(state: .notConnected, message: "The archive drive isn’t connected. Its recordings play again when it is plugged back in.")
            $0.nvrStorage = status
        }
        let away = await rig.get("nvr/storage").object("archive")
        #expect(away["state"] as? String == "notConnected" && away["message"] as? String == "The archive drive isn’t connected. Its recordings play again when it is plugged back in.")
        #expect(away["moving"] is NSNull && away["oldest"] is NSNull)
    }

    @Test func aLowerSizeLimitThatOnlyMovesToTheArchiveDeletesNothing() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        var status = storage(used: 400, oldest: now.addingTimeInterval(-3 * 86_400), newest: now)
        #expect(WebApp.bytesTheLimitsWouldDelete(status, keepDays: 7, maxSizeGB: 100, now: now).deletes, "without an archive the excess is deleted")
        status.archive = ArchiveDriveStatus(state: .connected, usedBytes: 1_000 * gigabyte, oldest: now.addingTimeInterval(-6 * 86_400), newest: now.addingTimeInterval(-3 * 86_400))
        let moved = WebApp.bytesTheLimitsWouldDelete(status, keepDays: 7, maxSizeGB: 100, now: now)
        #expect(!moved.deletes && moved.bytes == 0, "with a connected archive it moves")
        let aged = WebApp.bytesTheLimitsWouldDelete(status, keepDays: 3, maxSizeGB: 100, now: now)
        #expect(aged.deletes && aged.bytes > 0, "a shorter keep time deletes on both drives")
        status.archive?.state = .notConnected
        #expect(WebApp.bytesTheLimitsWouldDelete(status, keepDays: 7, maxSizeGB: 100, now: now).deletes, "an archive that is away takes nothing")
    }

    @Test func aPausedRecorderAndAFolderThatIsNotInTheListAreNamed() async throws {
        let rig = try await NVRRig.make()
        rig.backend.write { $0.nvrStorage = storage(pause: .diskFull) }
        let paused = await rig.get("nvr/storage")
        #expect(paused.json["state"] as? String == "diskFull")
        #expect(paused.json["message"] as? String == "There isn’t enough free space on the recordings drive.")
        rig.backend.write {
            $0.settings.nvrFolder = "/mnt/elsewhere"
            $0.nvrStorage = storage(pause: .notWritable("The drive isn’t answering."))
        }
        let other = await rig.get("nvr/storage")
        #expect(other.json["location"] as? String == "other" && other.json["label"] is NSNull)
        #expect(other.json["state"] as? String == "notWritable" && other.json["message"] as? String == "The drive isn’t answering.")
    }

    @Test func aTrailingSlashDoesNotMakeTheFolderStrange() async throws {
        let rig = try await NVRRig.make(folder: NVRRig.folder + "/")
        #expect(await rig.get("nvr/storage").json["location"] as? String == "builtin")
        let again = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["location": "builtin", "keepDays": 14])
        #expect(again.status == 200 && again.json["location"] as? String == "builtin")
        #expect(rig.backend.read { $0.settings.nvrFolder == NVRRig.folder + "/" && $0.calls.isEmpty }, "the same folder is neither checked nor set again, so the engine does not reload it")
    }

    // MARK: R2

    @Test func theLocationsAreCheckedOnceAndTheAnswerIsReused() async throws {
        let rig = try await NVRRig.make()
        rig.backend.write { $0.nvrStorage = storage(used: 5, free: 40, total: 64, floor: 8) }
        let first = await rig.get("nvr/storage/locations")
        let second = await rig.get("nvr/storage/locations")
        #expect(first.status == 200 && second.status == 200)
        let rows = first.array("locations")
        try #require(rows.count == 1)
        #expect(Set(rows[0].keys) == ["id", "label", "path", "current", "writable", "freeBytes", "totalBytes", "roomBytes", "problem", "warning"])
        #expect(rows[0]["id"] as? String == "builtin" && rows[0]["path"] as? String == NVRRig.folder && rows[0]["current"] as? Bool == true)
        #expect(rows[0]["writable"] as? Bool == true && rows[0]["problem"] is NSNull)
        #expect(jsonInt(rows[0]["freeBytes"]) == 200_000_000_000, "the folder check's numbers (the fake backend's default report)")
        #expect(jsonInt(rows[0]["roomBytes"]) == 37_000_000_000, "the current location: used + (free - floor) from the engine")
        #expect(rows[0]["warning"] as? String == "Small drive: room for about 37 GB")
        #expect(second.array("locations").count == 1)
        #expect(rig.backend.read { $0.calls.filter { $0 == "inspect:\(NVRRig.folder)" }.count } == 1, "single flight, reused for 10 s")
    }

    @Test func aLocationThatCannotBeUsedSaysWhy() async throws {
        let rig = try await NVRRig.make(folder: nil)
        rig.backend.write { $0.folderReport = .failure(ArchiveFolderError.cannotWrite) }
        let row = try #require(await rig.get("nvr/storage/locations").array("locations").first)
        #expect(row["current"] as? Bool == false && row["writable"] as? Bool == false)
        #expect(row["problem"] as? String == "Camera Bridge can’t write to that folder.")
        #expect(row["freeBytes"] is NSNull && row["totalBytes"] is NSNull && row["roomBytes"] is NSNull && row["warning"] is NSNull)
        let slow = try await NVRRig.make(folder: nil)
        slow.backend.write { $0.folderReport = .failure(DeadlineExceeded(limit: .seconds(8))) }
        let timedOut = try #require(await slow.get("nvr/storage/locations").array("locations").first)
        #expect(timedOut["problem"] as? String == "The drive isn’t answering.")
    }

    @Test func aBridgeWithNoLocationOffersNone() async throws {
        let rig = try await NVRRig.make(locations: [])
        let answer = await rig.get("nvr/storage/locations")
        #expect(answer.status == 200 && answer.array("locations").isEmpty)
        #expect(rig.backend.read { $0.calls.isEmpty })
    }

    // MARK: R3

    @Test func aChangeNeedsAtLeastOneField() async throws {
        let rig = try await NVRRig.make()
        for body in [[String: Any](), ["confirm": true], ["unknown": 1]] as [[String: Any]] {
            let answer = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: body)
            #expect(answer.status == 400 && answer.json["error"] as? String == "invalid", "\(body)")
        }
    }

    @Test func limitsOutsideTheRangesAreRefusedWithTheirField() async throws {
        let rig = try await NVRRig.make()
        let cases: [([String: Any], String)] = [(["keepDays": 0], "keepDays"), (["keepDays": 366], "keepDays"), (["keepDays": -1], "keepDays"), (["keepDays": "7"], "keepDays"), (["maxSizeGB": 9], "maxSizeGB"), (["maxSizeGB": 100_001], "maxSizeGB"), (["maxSizeGB": true], "maxSizeGB")]
        for (body, field) in cases {
            let answer = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: body)
            #expect(answer.status == 400 && answer.json["field"] as? String == field, "\(body) -> \(answer.text)")
        }
        let fractional = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["keepDays": 7.5])
        #expect(fractional.status == 400 && fractional.json["error"] as? String == "invalid", "a fraction is not a number of days")
        #expect(rig.backend.read { $0.settings.nvrKeepDays == 7 && $0.settings.nvrMaxSizeGB == 500 })
        #expect((await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["keepDays": 365, "maxSizeGB": 100_000])).status == 200)
        #expect((await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["keepDays": 1, "maxSizeGB": 10, "confirm": true])).status == 200)
    }

    /// T00 R3 step 1: a well-formed body whose limit is out of type or range is a 400 `invalid` that names the field. A number that is not a whole number
    /// (1.5, or one too large for an integer) once came back as "The request isn't valid JSON." with no `field`, because decoding it straight into an
    /// `Int` makes Foundation report unreadable JSON with no key.
    @Test func aLimitThatIsNotAWholeNumberIsRefusedWithItsFieldAndNotAsBrokenJSON() async throws {
        let rig = try await NVRRig.make()
        let cases: [(String, String, String)] = [
            (#"{"keepDays":1.5}"#, "keepDays", "a fraction of a day"), (#"{"keepDays":7.5}"#, "keepDays", "a fraction of a day"),
            (#"{"maxSizeGB":1.5}"#, "maxSizeGB", "a fraction of a gigabyte"), (#"{"maxSizeGB":12.5}"#, "maxSizeGB", "a fraction of a gigabyte"),
            (#"{"keepDays":1e30}"#, "keepDays", "more days than an integer holds"), (#"{"maxSizeGB":99999999999999999999}"#, "maxSizeGB", "more gigabytes than an integer holds"),
            (#"{"keepDays":-0.5}"#, "keepDays", "a negative fraction"),
            (#"{"keepDays":7,"maxSizeGB":1.5}"#, "maxSizeGB", "a good limit beside a fraction"), (#"{"keepDays":1.5,"maxSizeGB":500}"#, "keepDays", "a fraction beside a good limit"),
            (#"{"location":"builtin","keepDays":1.5}"#, "keepDays", "a fraction beside a good location"),
        ]
        func patch(_ body: String) async -> Answer {   // the text exactly as written: JSONSerialization would not write 1e30 or a 20-digit number the same way
            await rig.harness.send("PATCH", "/api/v1/nvr/storage", rawBody: Data(body.utf8), cookie: rig.session.cookie, csrf: rig.session.csrf)
        }
        for (body, field, label) in cases {
            let answer = await patch(body)
            #expect(answer.status == 400 && answer.json["error"] as? String == "invalid" && answer.json["field"] as? String == field, "\(label) \(body) -> \(answer.text)")
            #expect(!answer.text.contains("valid JSON"), "\(label): the body is well-formed JSON, so the answer must not say it is not -> \(answer.text)")
        }
        // Nothing was changed by any of them, and a value that is whole still works (7.0 is the whole number 7).
        #expect(rig.backend.read { $0.settings.nvrKeepDays == 7 && $0.settings.nvrMaxSizeGB == 500 && $0.settings.nvrFolder == NVRRig.folder })
        #expect((await patch(#"{"keepDays":9,"maxSizeGB":600}"#)).status == 200)
        #expect(rig.backend.read { $0.settings.nvrKeepDays == 9 && $0.settings.nvrMaxSizeGB == 600 })
    }

    @Test func aLocationMustBeOneOfTheListedIdsAndNeverAPath() async throws {
        let rig = try await NVRRig.make(folder: nil)
        for location in ["nope", "builtin ", "BUILTIN", "builtin\u{0}", "/etc", "../recordings", String(repeating: "b", count: 1_025), ""] {
            let answer = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["location": location])
            #expect(answer.status == 422 && answer.json["error"] as? String == "folder_rejected", "\(location.prefix(12))")
            #expect(answer.json["message"] as? String == "Choose one of the listed locations.")
            #expect(!answer.text.contains("nope") && !answer.text.contains("/etc"), "the answer never repeats what was sent")
        }
        #expect(rig.backend.read { $0.settings.nvrFolder == nil && $0.calls.isEmpty }, "nothing was checked or saved")
        let withPath = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["location": "builtin", "path": "/etc"])
        #expect(withPath.status == 200 && withPath.json["location"] as? String == "builtin", "a path in the body is ignored")
        #expect(rig.backend.read { $0.settings.nvrFolder == NVRRig.folder && $0.calls == ["inspect:\(NVRRig.folder)"] })
    }

    @Test func aFolderThatCannotHoldRecordingsIsRefusedWithTheEnginesSentence() async throws {
        let rig = try await NVRRig.make(folder: nil)
        rig.backend.write { $0.folderReport = .failure(ArchiveFolderError.belowFloor(freeBytes: 800_000_000, floorBytes: 2_147_483_648)) }
        let refused = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["location": "builtin", "keepDays": 3])
        #expect(refused.status == 422 && refused.json["error"] as? String == "folder_rejected")
        #expect(refused.json["message"] as? String == "That drive needs 2.1 GB free to record, and has 0.8 GB.")
        #expect(rig.backend.read { $0.settings.nvrFolder == nil && $0.settings.nvrKeepDays == 7 }, "nothing was saved")
        rig.backend.write { $0.folderReport = .failure(DeadlineExceeded(limit: .seconds(8))) }
        let slow = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["location": "builtin"])
        #expect(slow.status == 504 && slow.json["error"] as? String == "drive_slow" && slow.headers["Retry-After"] == "2")
        rig.backend.write { $0.folderReport = .success(ArchiveFolderReport(freeBytes: 200 * gigabyte, totalBytes: 500 * gigabyte)) }
        #expect((await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["location": "builtin"])).status == 200, "a refusal is not remembered")
    }

    @Test func theFolderIsNotCheckedAgainWhenItDoesNotChange() async throws {
        let rig = try await NVRRig.make()
        let answer = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["location": "builtin", "keepDays": 14])
        #expect(answer.status == 200 && answer.int("keepDays") == 14)
        #expect(rig.backend.read { $0.calls.isEmpty })
    }

    @Test func oneRequestIsOneChangeOfTheSettings() async throws {
        let rig = try await NVRRig.make(folder: nil)
        let counting = CountingBackend(rig.backend)
        let app = WebApp(configuration: rig.harness.app.configuration, backend: counting, system: rig.harness.system, logs: rig.harness.logs)
        func patch(_ body: [String: Any]) async -> Int {
            await app.handle(rig.harness.request("PATCH", "/api/v1/nvr/storage", json: body, cookie: rig.session.cookie, csrf: rig.session.csrf)).status
        }
        #expect(await patch(["location": "builtin", "keepDays": 14, "maxSizeGB": 800]) == 200)
        #expect(counting.settingsChanges.withLock { $0 } == 1)
        let settings = rig.backend.read { $0.settings }
        #expect(settings.nvrFolder == NVRRig.folder && settings.nvrKeepDays == 14 && settings.nvrMaxSizeGB == 800)
        let outOfRange = await patch(["keepDays": 0]), unknown = await patch(["location": "nope"])
        #expect(outOfRange == 400 && unknown == 422)
        #expect(counting.settingsChanges.withLock { $0 } == 1, "a refused request changes nothing")
    }

    @Test func theEnginesRefusalOfTheSettingsIsShownAndNothingIsHalfSaved() async throws {
        let rig = try await NVRRig.make(folder: nil)
        rig.backend.write { $0.settings.webhookEnabled = true; $0.settings.webhookToken = "short" }   // the fake refuses any change while this holds
        let answer = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["location": "builtin", "keepDays": 3])
        #expect(answer.status == 422 && answer.json["error"] as? String == "settings_failed")
        #expect(rig.backend.read { $0.settings.nvrFolder == nil && $0.settings.nvrKeepDays == 7 })
    }

    // MARK: confirm_required

    @Test func theBytesTheLimitsWouldDeleteAreTheLargerOfTheSizeAndTheAgeExcess() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func status(used: UInt64, oldestDaysAgo: Double?, newestDaysAgo: Double = 0) -> ArchiveStorageStatus {
            ArchiveStorageStatus(usedBytes: used * gigabyte, oldest: oldestDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }, newest: now.addingTimeInterval(-newestDaysAgo * 86_400))
        }
        func bytes(_ storage: ArchiveStorageStatus, days: Int, size: Int) -> (deletes: Bool, gigabytes: Double) {
            let result = WebApp.bytesTheLimitsWouldDelete(storage, keepDays: days, maxSizeGB: size, now: now)
            return (result.deletes, result.bytes / 1e9)
        }
        // 300 GB over 10 days, keep 7 days: 3 of the 10 days are too old, 90 GB.
        var result = bytes(status(used: 300, oldestDaysAgo: 10), days: 7, size: 500)
        #expect(result.deletes && abs(result.gigabytes - 90) < 0.001)
        // The size limit alone: 300 GB with a 200 GB limit, and nothing older than 14 days.
        result = bytes(status(used: 300, oldestDaysAgo: 10), days: 14, size: 200)
        #expect(result.deletes && abs(result.gigabytes - 100) < 0.001)
        // Both: the larger one counts (keep 1 day deletes 90% = 270 GB, the size limit 100 GB).
        result = bytes(status(used: 300, oldestDaysAgo: 10), days: 1, size: 200)
        #expect(result.deletes && abs(result.gigabytes - 270) < 0.001)
        // Everything is older than the limit.
        result = bytes(status(used: 40, oldestDaysAgo: 30, newestDaysAgo: 30), days: 7, size: 500)
        #expect(result.deletes && abs(result.gigabytes - 40) < 0.001)
        // Nothing to delete.
        result = bytes(status(used: 40, oldestDaysAgo: 2), days: 7, size: 500)
        #expect(!result.deletes && result.gigabytes == 0)
        result = bytes(status(used: 40, oldestDaysAgo: nil), days: 1, size: 500)
        #expect(!result.deletes)
    }

    @Test func limitsThatWouldDeleteRecordingsNeedTheServersConfirmation() async throws {
        let rig = try await NVRRig.make()
        let now = Date()
        rig.backend.write { $0.nvrStorage = storage(used: 300, oldest: now.addingTimeInterval(-10 * 86_400), newest: now); $0.settings.nvrKeepDays = 14 }
        let asked = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["keepDays": 7])
        #expect(asked.status == 409 && asked.json["error"] as? String == "confirm_required" && asked.json["field"] as? String == "confirm")
        #expect(asked.json["message"] as? String == "This will delete about 90 GB of the oldest recordings. Send confirm to continue.")
        #expect(rig.backend.read { $0.settings.nvrKeepDays } == 14, "nothing changed")
        let notTrue = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["keepDays": 7, "confirm": false])
        #expect(notTrue.status == 409)
        let confirmed = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["keepDays": 7, "confirm": true])
        #expect(confirmed.status == 200 && confirmed.int("keepDays") == 7)
        #expect(rig.backend.read { $0.settings.nvrKeepDays } == 7)
    }

    @Test func aSizeLimitUnderWhatIsUsedAsksWithTheExcess() async throws {
        let rig = try await NVRRig.make()
        let now = Date()
        rig.backend.write { $0.nvrStorage = storage(used: 300, oldest: now.addingTimeInterval(-10 * 86_400), newest: now); $0.settings.nvrKeepDays = 14 }
        let asked = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["maxSizeGB": 200])
        #expect(asked.status == 409 && (asked.json["message"] as? String)?.contains("about 100 GB") == true)
        let both = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["maxSizeGB": 200, "keepDays": 1])
        #expect((both.json["message"] as? String)?.contains("about 270 GB") == true)
    }

    @Test func limitsThatDeleteNothingOrLoosenAreNotAsked() async throws {
        let rig = try await NVRRig.make()
        let now = Date()
        rig.backend.write { $0.nvrStorage = storage(used: 40, oldest: now.addingTimeInterval(-2 * 86_400), newest: now) }
        #expect((await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["keepDays": 3, "maxSizeGB": 100])).status == 200, "stricter, but nothing to delete")
        rig.backend.write { $0.nvrStorage = storage(used: 300, oldest: now.addingTimeInterval(-10 * 86_400), newest: now) }
        #expect((await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["keepDays": 30, "maxSizeGB": 1000])).status == 200, "looser limits")
        rig.backend.write { $0.nvrStorage = nil }
        #expect((await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["keepDays": 1])).status == 200, "no measurement yet")
    }

    // MARK: R4

    @Test func turningRecordOnWithNoFolderAsksForOneAndChangesNothing() async throws {
        let rig = try await NVRRig.make(folder: nil)
        let answer = await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr", json: ["enabled": true])
        #expect(answer.status == 409 && answer.json["error"] as? String == "folder_required")
        #expect(answer.json["message"] as? String == "Choose where to store recordings first.")
        #expect(rig.backend.read { $0.configurations[0].nvrEnabled == false && !$0.calls.contains("setNVR") })
        #expect((await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr", json: ["enabled": false])).status == 200, "turning it off needs no folder")
        #expect((await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr", json: ["recordSound": true])).status == 200, "nor does the sound switch")
    }

    @Test func recordAndRecordSoundAreSwitchedThroughSetNVROnly() async throws {
        let rig = try await NVRRig.make()
        let on = await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr", json: ["enabled": true])
        #expect(on.status == 200 && on.json["nvrEnabled"] as? Bool == true && on.json["nvrRecordSound"] as? Bool == false)
        #expect(on.json["id"] as? String == rig.cameraID)
        let sound = await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr", json: ["recordSound": true])
        #expect(sound.json["nvrEnabled"] as? Bool == true && sound.json["nvrRecordSound"] as? Bool == true, "audioEnabled is not a condition of the switch")
        let both = await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr", json: ["enabled": false, "recordSound": false])
        #expect(both.json["nvrEnabled"] as? Bool == false && both.json["nvrRecordSound"] as? Bool == false)
        #expect(rig.backend.read { $0.calls } == ["setNVR", "setNVR", "setNVR"], "never updateCamera")
    }

    @Test func theGeneralCameraPatchLeavesTheTwoSwitchesAlone() async throws {
        let rig = try await NVRRig.make()
        _ = await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr", json: ["enabled": true, "recordSound": true])
        let patched = await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)", json: ["audioEnabled": false, "nvrEnabled": false, "nvrRecordSound": false])
        #expect(patched.status == 200)
        #expect(patched.json["nvrEnabled"] as? Bool == true && patched.json["nvrRecordSound"] as? Bool == true, "PATCH /cameras/:id does not carry the two fields")
        #expect(patched.json["audioEnabled"] as? Bool == false)
    }

    @Test func aRequestThatSaysNothingOrTheWrongThingIsRefused() async throws {
        let rig = try await NVRRig.make()
        for body in [[String: Any](), ["other": true]] as [[String: Any]] {
            let answer = await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr", json: body)
            #expect(answer.status == 400 && answer.json["error"] as? String == "invalid", "\(body)")
        }
        let wrong = await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr", json: ["enabled": "yes"])
        #expect(wrong.status == 400 && wrong.json["field"] as? String == "enabled")
        #expect((await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr")).status == 400, "no body")
        #expect(rig.backend.read { !$0.calls.contains("setNVR") })
    }

    @Test func anUnknownCameraIsNotFoundAndAFailureIsExplained() async throws {
        let rig = try await NVRRig.make()
        #expect((await rig.session.send("PATCH", "/api/v1/cameras/\(UUID().uuidString)/nvr", json: ["enabled": true])).status == 404)
        #expect((await rig.session.send("PATCH", "/api/v1/cameras/not-an-id/nvr", json: ["enabled": true])).status == 404)
        rig.backend.write { $0.nvrError = EngineError.configurationUnavailable("disk") }
        let failed = await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr", json: ["enabled": true])
        #expect(failed.status == 422 && failed.json["error"] as? String == "update_failed")
        rig.backend.write { $0.nvrError = EngineError.unknownCamera }
        #expect((await rig.session.send("PATCH", "/api/v1/cameras/\(rig.cameraID)/nvr", json: ["enabled": true])).status == 404, "removed while asking")
    }

    @Test func theCameraAnswerCarriesTheRecordingStatusWithEveryKey() async throws {
        let rig = try await NVRRig.make()
        let plain = try #require(await rig.get("cameras/\(rig.cameraID)").object("status")["nvr"] as? [String: Any])
        #expect(Set(plain.keys) == ["state", "detail", "pause", "notes"])
        #expect(plain["state"] as? String == "off" && plain["detail"] is NSNull && plain["pause"] is NSNull && (plain["notes"] as? [Any])?.isEmpty == true)
        let camera = rig.camera
        rig.backend.write {
            $0.statusOverrides[camera.id] = CameraStatus(id: camera.id, name: camera.name, kind: camera.kind, vendor: camera.vendor, connection: .online,
                                                         nvr: CameraArchiveStatus(state: .paused(.folderMissing),
                                                                                  notes: [ArchiveNote(id: .keyframe, text: "keyframe every 12 s: scrubbing is slow")]))
        }
        let paused = try #require(await rig.get("cameras/\(rig.cameraID)").object("status")["nvr"] as? [String: Any])
        #expect(paused["state"] as? String == "paused" && paused["pause"] as? String == "folderMissing")
        #expect(paused["detail"] as? String == "The recordings folder isn’t available. Reconnect the drive or choose another folder.")
        let notes = try #require(paused["notes"] as? [[String: String]])
        #expect(notes == [["id": "keyframe", "text": "keyframe every 12 s: scrubbing is slow"]])
        rig.backend.write {
            $0.statusOverrides[camera.id] = CameraStatus(id: camera.id, name: camera.name, kind: camera.kind, vendor: camera.vendor, connection: .online,
                                                         nvr: CameraArchiveStatus(state: .waiting("waiting for the camera")))
        }
        let waiting = try #require(await rig.get("cameras/\(rig.cameraID)").object("status")["nvr"] as? [String: Any])
        #expect(waiting["state"] as? String == "waiting" && waiting["detail"] as? String == "waiting for the camera" && waiting["pause"] is NSNull)
    }

    // MARK: the answer to a folder change

    @Test func theAnswerToAFirstFolderChoiceWaitsForTheStorageOfThatFolder() async throws {
        // The engine's status follows a settings change a moment later (the store measures the folder, the engine copies the store's status every
        // 250 ms). A PATCH that answered at once said "noFolder" with every byte count 0, and T14's first phase aborted on it.
        let rig = try await NVRRig.make(folder: nil)
        rig.backend.write { $0.nvrStorage = ArchiveStorageStatus(pause: .noFolder) }
        let follower = Task {
            try? await Task.sleep(for: .milliseconds(350))
            rig.backend.write { $0.nvrStorage = storage() }
        }
        let started = ContinuousClock.now
        let answer = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["location": "builtin"])
        await follower.value
        #expect(answer.status == 200 && answer.json["location"] as? String == "builtin")
        #expect(answer.json["state"] as? String == "ok", "\(answer.text)")
        #expect(answer.int("freeBytes") == Int64(300 * gigabyte) && answer.int("totalBytes") == Int64(500 * gigabyte) && answer.int("floorBytes") == Int64(25 * gigabyte))
        #expect(answer.int("effectiveMaxBytes") == Int64(450 * gigabyte), "min(500 GB, 500 GB - 2 x 25 GB)")
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aSnapshotThatNeverFollowsDelaysTheAnswerByTwoSecondsAtMost() async throws {
        let rig = try await NVRRig.make(folder: nil)
        rig.backend.write { $0.nvrStorage = ArchiveStorageStatus(pause: .noFolder) }
        let started = ContinuousClock.now
        let answer = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["location": "builtin"])
        let elapsed = ContinuousClock.now - started
        #expect(answer.status == 200 && answer.json["location"] as? String == "builtin")
        #expect(elapsed >= .seconds(1.8) && elapsed < .seconds(4), "\(elapsed)")
    }

    @Test func aChangeOfLimitsAloneAnswersAtOnce() async throws {
        let rig = try await NVRRig.make()
        rig.backend.write { $0.nvrStorage = storage() }
        let started = ContinuousClock.now
        let answer = await rig.session.send("PATCH", "/api/v1/nvr/storage", json: ["keepDays": 30])
        #expect(answer.status == 200 && answer.int("keepDays") == 30 && ContinuousClock.now - started < .milliseconds(500))
    }
}
