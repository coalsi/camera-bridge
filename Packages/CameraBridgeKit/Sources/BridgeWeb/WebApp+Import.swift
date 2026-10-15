import BridgeEngine
import BridgeSupport
import Foundation

// Moving from Camera Bridge for Mac: the Mac app's configuration backup (Settings › Backup, a `.camerabridge-backup` JSON file) read here, shown
// to the person, and its cameras added with the passwords they type (the file never holds passwords). Cameras keep their identity (the same
// id), so importing the same file twice adds nothing twice; each gets a HomeKit port of this box. A camera whose password was given is turned on.

/// The Mac app's backup file as the box reads it (the Mac's `ConfigurationBackup`: kind, version, cameras).
struct MacBackupFile {
    static let kind = "CameraBridgeBackup"
    static let newestVersion = 1

    var cameras: [CameraConfiguration]
    /// Camera entries this version could not read (made by a newer app, for example).
    var unreadable: Int
    var appVersion: String
    var exportedAt: String?

    /// Throws a sentence for a file that isn't a backup, or one made by a newer version.
    static func read(_ object: Any) throws -> MacBackupFile {
        guard let object = object as? [String: Any], object["kind"] as? String == kind,
              let version = (object["version"] as? NSNumber).flatMap({ Int(exactly: $0.doubleValue) }) else {
            throw APIError.badRequest("This file isn’t a Camera Bridge backup. On the Mac: Camera Bridge › Settings › Backup › Export.", field: "file")
        }
        guard version <= newestVersion else {
            throw APIError.badRequest("This backup was made by a newer Camera Bridge. Update this bridge, then try again.", field: "file")
        }
        guard let entries = object["cameras"] as? [Any] else { throw APIError.badRequest("This backup has no cameras.", field: "file") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var cameras: [CameraConfiguration] = []
        var seen = Set<UUID>()
        var unreadable = 0
        for entry in entries.prefix(200) {
            guard JSONSerialization.isValidJSONObject(entry), let json = try? JSONSerialization.data(withJSONObject: entry),
                  let camera = try? decoder.decode(CameraConfiguration.self, from: json) else {
                unreadable += 1
                continue
            }
            if seen.insert(camera.id).inserted { cameras.append(camera) }
        }
        return MacBackupFile(cameras: cameras, unreadable: unreadable, appVersion: object["appVersion"] as? String ?? "", exportedAt: object["exportedAt"] as? String)
    }

    /// A camera as this box adds it: no credentials in its addresses, a port of this box (0: the allocator picks one from the box's range), on
    /// only when its password was given (a camera signing in with nothing may lock its account).
    static func imported(_ camera: CameraConfiguration, hasPassword: Bool) -> CameraConfiguration {
        var imported = camera.withoutStreamCredentials
        imported.hapPort = 0
        imported.isEnabled = hasPassword && camera.isEnabled
        return imported
    }
}

extension WebApp {
    /// `{file: <the backup's JSON>, passwords: {<camera id>: <password>}}`, read with JSONSerialization (the file is the Mac's format, not ours).
    private struct ImportRequest {
        var file: Any?
        var passwords: [String: String]

        init(_ ctx: RequestContext) throws {
            guard let object = (try? JSONSerialization.jsonObject(with: ctx.request.body)) as? [String: Any] else {
                throw APIError.badRequest("Send the backup as JSON.", field: "file")
            }
            file = object["file"]
            passwords = (object["passwords"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        }
    }

    private struct PreviewCamera: Encodable {
        var id: String
        var name: String
        var vendor: String
        var host: String
        var username: String
        var record: Bool
        var enabled: Bool
        /// Already on this bridge (same camera): left as it is.
        var alreadySetUp: Bool
    }

    private struct Preview: Encodable {
        var cameras: [PreviewCamera]
        var unreadable: Int
        var appVersion: String
        var exportedAt: String?
    }

    private func readBackup(_ body: ImportRequest) throws -> MacBackupFile {
        guard let file = body.file else { throw APIError.badRequest("Choose the backup file from the Mac.", field: "file") }
        return try MacBackupFile.read(file)
    }

    func importPreview(_ ctx: RequestContext) async throws -> HTTPResponse {
        let backup = try readBackup(try ImportRequest(ctx))
        let known = Set(await backend.overview().configurations.map(\.id))
        return .json(Preview(cameras: backup.cameras.map {
            PreviewCamera(id: $0.id.uuidString, name: $0.name, vendor: $0.vendor.rawValue, host: $0.endpoint.host, username: $0.username, record: $0.nvrEnabled,
                          enabled: $0.isEnabled, alreadySetUp: known.contains($0.id))
        }, unreadable: backup.unreadable, appVersion: backup.appVersion, exportedAt: backup.exportedAt))
    }

    private struct ImportResult: Encodable {
        struct Failure: Encodable {
            var name: String
            var message: String
        }

        var added: [String]
        /// Added turned off: no password was given.
        var addedOff: [String]
        var alreadySetUp: [String]
        var failed: [Failure]
        /// Record was on for some cameras and this bridge had no place for recordings yet: its own storage was chosen.
        var recordingPlaceChosen: Bool
    }

    func importBackup(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try ImportRequest(ctx)
        let backup = try readBackup(body)
        let passwords = body.passwords
        let overview = await backend.overview()
        let known = Set(overview.configurations.map(\.id))
        var result = ImportResult(added: [], addedOff: [], alreadySetUp: [], failed: [], recordingPlaceChosen: false)
        var recordsAny = false
        for camera in backup.cameras {
            if known.contains(camera.id) { result.alreadySetUp.append(camera.name); continue }
            let password = passwords[camera.id.uuidString].flatMap { $0.isEmpty ? nil : $0 }
            guard password.map({ $0.utf8.count <= 256 }) ?? true else {
                result.failed.append(.init(name: camera.name, message: "The password is too long."))
                continue
            }
            do {
                try await backend.addCamera(MacBackupFile.imported(camera, hasPassword: password != nil), password: password)
                if password != nil { result.added.append(camera.name) } else { result.addedOff.append(camera.name) }
                if camera.nvrEnabled { recordsAny = true }
            } catch {
                result.failed.append(.init(name: camera.name, message: ErrorText.describe(error)))
            }
        }
        // Record was on for cameras on the Mac: they record here too, to this box's storage, unless a place is chosen already.
        if recordsAny, overview.settings.nvrFolder == nil, let place = configuration.archiveLocations.first {
            do {
                try await backend.updateSettings { $0.nvrFolder = place.path }
                result.recordingPlaceChosen = true
            } catch {
                log.warning("importing: the recording place could not be set: \(ErrorText.logDescription(error))")
            }
        }
        log.notice("imported \(result.added.count + result.addedOff.count) camera(s) from a Camera Bridge for Mac backup")
        return .json(result)
    }
}
