import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation

// Where recordings are stored (`GET/PATCH /nvr/storage`, `GET /nvr/storage/locations`) and the Record switch (`PATCH /cameras/:id/nvr`).

extension WebApp {
    // MARK: Storage (R1 to R3)

    private struct StorageLimits: Encodable {
        var keepDays: [Int]
        var maxSizeGB: [Int]
    }

    private struct StorageResource: Encodable {
        var location: OrNull<String>
        var label: OrNull<String>
        var state: String
        var message: OrNull<String>
        var recordingCameras: Int
        var keepDays: Int
        var maxSizeGB: Int
        var limits: StorageLimits
        var usedBytes: UInt64
        var freeBytes: UInt64
        var totalBytes: UInt64
        var floorBytes: UInt64
        var roomBytes: UInt64
        var effectiveMaxBytes: UInt64
        var oldest: OrNull<Int64>
        var newest: OrNull<Int64>
        /// The archive drive; null where the system has none.
        var archive: OrNull<ArchiveDriveResource>
    }

    /// `ArchiveDriveStatus` for the page: the state's code, its sentence, the numbers, how far back it goes and what moves now.
    private struct ArchiveDriveResource: Encodable {
        var state: String
        var message: OrNull<String>
        var usedBytes: UInt64
        var freeBytes: UInt64
        var totalBytes: UInt64
        var floorBytes: UInt64
        var oldest: OrNull<Int64>
        var newest: OrNull<Int64>
        var moving: OrNull<MoveResource>
        var waitingFiles: Int
        var waitingBytes: UInt64
        var movedFiles: Int
        var movedBytes: UInt64
    }

    private struct MoveResource: Encodable {
        var cameraID: UUID
        var cameraName: OrNull<String>
        var start: Int64
        var bytes: UInt64
        var doneBytes: UInt64
    }

    private func archiveResource(_ status: ArchiveDriveStatus, cameras: [CameraConfiguration]) -> ArchiveDriveResource {
        let moving = status.moving.map { move in
            MoveResource(cameraID: move.camera, cameraName: OrNull(cameras.first { $0.id == move.camera }?.name), start: Self.milliseconds(move.start),
                         bytes: move.bytes, doneBytes: min(move.doneBytes, move.bytes))
        }
        return ArchiveDriveResource(state: status.state.rawValue, message: OrNull(status.message.map { Redact.string($0) }), usedBytes: status.usedBytes,
                                    freeBytes: status.freeBytes, totalBytes: status.totalBytes, floorBytes: status.floorBytes,
                                    oldest: OrNull(status.oldest.map(Self.milliseconds)), newest: OrNull(status.newest.map(Self.milliseconds)),
                                    moving: OrNull(moving), waitingFiles: status.waitingFiles, waitingBytes: status.waitingBytes,
                                    movedFiles: status.movedFiles, movedBytes: status.movedBytes)
    }

    private func storageResource(_ overview: BridgeOverview) -> StorageResource {
        let settings = overview.settings
        let storage = overview.nvrStorage
        let current = settings.nvrFolder.flatMap { folder in
            configuration.archiveLocations.first { Self.normalizedPath($0.path) == Self.normalizedPath(folder) }
        }
        let pause: ArchivePause? = settings.nvrFolder == nil ? .noFolder : storage?.pause
        return StorageResource(
            location: OrNull(settings.nvrFolder == nil ? nil : (current?.id ?? "other")), label: OrNull(current?.label),
            state: pause?.code ?? "ok", message: OrNull(pause.map { Redact.string($0.readable) }),
            recordingCameras: overview.configurations.filter(\.nvrEnabled).count, keepDays: settings.nvrKeepDays, maxSizeGB: settings.nvrMaxSizeGB,
            limits: StorageLimits(keepDays: [BridgeSettings.nvrKeepDaysRange.lowerBound, BridgeSettings.nvrKeepDaysRange.upperBound],
                                  maxSizeGB: [BridgeSettings.nvrMaxSizeGBRange.lowerBound, BridgeSettings.nvrMaxSizeGBRange.upperBound]),
            usedBytes: storage?.usedBytes ?? 0, freeBytes: storage?.freeBytes ?? 0, totalBytes: storage?.totalBytes ?? 0, floorBytes: storage?.floorBytes ?? 0,
            roomBytes: storage?.roomBytes ?? 0, effectiveMaxBytes: storage?.effectiveMaximumBytes(maxSizeGB: settings.nvrMaxSizeGB) ?? 0,
            oldest: OrNull(storage?.oldest.map(Self.milliseconds)), newest: OrNull(storage?.newest.map(Self.milliseconds)),
            archive: OrNull(storage?.archive.map { archiveResource($0, cameras: overview.configurations) }))
    }

    func nvrStorage() async -> HTTPResponse {
        .json(storageResource(await backend.overview()))
    }

    private struct LocationResource: Encodable {
        var id: String
        var label: String
        var path: String
        var current: Bool
        var writable: Bool
        var freeBytes: OrNull<UInt64>
        var totalBytes: OrNull<UInt64>
        var roomBytes: OrNull<UInt64>
        var problem: OrNull<String>
        var warning: OrNull<String>
    }

    /// `GET /nvr/storage/locations`. Probes the disk (single flight, 8 s deadline, reused for 10 s), so the page asks only when the chooser opens.
    func nvrLocations() async -> HTTPResponse {
        struct Locations: Encodable { var locations: [LocationResource] }
        let overview = await backend.overview()
        let stored = overview.settings.nvrFolder.map(Self.normalizedPath)
        var rows: [LocationResource] = []
        for location in configuration.archiveLocations {
            let isCurrent = stored == Self.normalizedPath(location.path)
            var row = LocationResource(id: location.id, label: location.label, path: location.path, current: isCurrent, writable: false, freeBytes: OrNull(nil),
                                       totalBytes: OrNull(nil), roomBytes: OrNull(nil), problem: OrNull(nil), warning: OrNull(nil))
            switch await archiveState.folders.inspect(location.path, using: backend, reusing: true) {
            case .usable(let report):
                let room = isCurrent ? overview.nvrStorage?.roomBytes : nil
                row.writable = true
                row.freeBytes = OrNull(report.freeBytes)
                row.totalBytes = OrNull(report.totalBytes)
                row.roomBytes = OrNull(room)
                let basis = room ?? report.freeBytes
                if basis < 100 * ArchiveConstants.gigabyte { row.warning = OrNull("Small drive: room for about \(basis / ArchiveConstants.gigabyte) GB") }
            case .rejected(let sentence):
                row.problem = OrNull(sentence)
            case .unresponsive:
                row.problem = OrNull(ArchiveFolderError.notAnswering.errorDescription)
            }
            rows.append(row)
        }
        return .json(Locations(locations: rows))
    }

    private struct StoragePatch: Decodable {
        var location: String?
        /// The two limits are read as numbers and checked as whole numbers in `wholeLimit`: decoding 1.5, or a number too large for an integer, straight into an
        /// `Int` makes Foundation report unreadable JSON with an empty coding path, so the answer said the JSON was broken and named no `field` (T00 R3 gives
        /// every 400 `invalid` of a limit its field). A string or a boolean still fails here with its key ("has the wrong kind of value").
        var keepDays: Double?
        var maxSizeGB: Double?
        var confirm: Bool?
    }

    /// A limit from the body: nil when it is absent, else a whole number inside `range`. A fraction, a number outside the integers or outside the range is
    /// 400 `invalid` with `field`, never "isn't valid JSON": the body was well-formed.
    private static func wholeLimit(_ value: Double?, in range: ClosedRange<Int>, field: String, sentence: String) throws -> Int? {
        guard let value else { return nil }
        guard let whole = Int(exactly: value), range.contains(whole) else { throw APIError.badRequest(sentence, field: field) }
        return whole
    }

    /// What the new limits would delete, from the storage snapshot (approximate on purpose): the larger of the bytes over the size limit and the
    /// share of the archive older than the age limit (spread evenly over the time between the oldest and the newest recording). With an archive drive
    /// that is connected, what is over the size limit moves there instead of being deleted, and the age limit covers what is on both drives.
    static func bytesTheLimitsWouldDelete(_ storage: ArchiveStorageStatus, keepDays: Int, maxSizeGB: Int, now: Date) -> (deletes: Bool, bytes: Double) {
        let archive = storage.archive
        let moves = archive?.state == .connected
        let used = Double(storage.usedBytes) + Double(archive?.usedBytes ?? 0)
        let sizeExcess = moves ? 0 : max(0, Double(storage.usedBytes) - Double(maxSizeGB) * Double(ArchiveConstants.gigabyte))
        var ageDeletes = false
        var ageExcess = 0.0
        let oldestKept = [storage.oldest, archive?.oldest].compactMap { $0 }.min()
        let newestKept = [storage.newest, archive?.newest].compactMap { $0 }.max()
        if let oldest = oldestKept {
            let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
            ageDeletes = oldest < cutoff
            let span = newestKept.map { $0.timeIntervalSince(oldest) } ?? 0
            let share = span > 0 ? min(max(cutoff.timeIntervalSince(oldest) / span, 0), 1) : (ageDeletes ? 1 : 0)
            ageExcess = used * share
        }
        return (sizeExcess > 0 || ageDeletes, max(sizeExcess, ageExcess))
    }

    func patchNVRStorage(_ ctx: RequestContext) async throws -> HTTPResponse {
        let patch = try decode(StoragePatch.self, from: ctx)
        guard patch.location != nil || patch.keepDays != nil || patch.maxSizeGB != nil else {
            throw APIError.badRequest("Choose a location, how long to keep recordings, or a maximum size.", field: "location")
        }
        // 1. The limits are in range (the engine's `validate` stays the authority).
        let days = BridgeSettings.nvrKeepDaysRange, size = BridgeSettings.nvrMaxSizeGBRange
        let keepDays = try Self.wholeLimit(patch.keepDays, in: days, field: "keepDays",
                                           sentence: "Keep recordings for \(days.lowerBound) to \(days.upperBound) days.")
        let maxSizeGB = try Self.wholeLimit(patch.maxSizeGB, in: size, field: "maxSizeGB",
                                            sentence: "Keep at most \(size.lowerBound) to \(size.upperBound) GB of recordings.")
        let overview = await backend.overview()
        // 2. A location is one of the bridge's own ids, never a path from the network.
        var chosen: ArchiveLocation?
        if let id = patch.location {
            guard let found = configuration.archiveLocations.first(where: { $0.id == id }) else {
                throw APIError(status: 422, code: "folder_rejected", message: "Choose one of the listed locations.")
            }
            chosen = found
        }
        // 3. A different folder must be able to hold recordings.
        let changesFolder = chosen.map { Self.normalizedPath($0.path) != overview.settings.nvrFolder.map(Self.normalizedPath) } ?? false
        if let chosen, changesFolder {
            switch await archiveState.folders.inspect(chosen.path, using: backend, reusing: false) {
            case .usable: break
            case .rejected(let sentence): throw APIError(status: 422, code: "folder_rejected", message: sentence)
            case .unresponsive: throw Self.archiveAPIError(ArchiveError.timedOut)
            }
        }
        // 4. Limits that would delete recordings are confirmed on the server.
        let stored = overview.settings
        let newDays = keepDays ?? stored.nvrKeepDays, newSize = maxSizeGB ?? stored.nvrMaxSizeGB
        if newDays < stored.nvrKeepDays || newSize < stored.nvrMaxSizeGB, patch.confirm != true, let storage = overview.nvrStorage {
            let outcome = Self.bytesTheLimitsWouldDelete(storage, keepDays: newDays, maxSizeGB: newSize, now: Date())
            if outcome.deletes {
                let gigabytes = max(1, Int((outcome.bytes / Double(ArchiveConstants.gigabyte)).rounded()))
                throw APIError(status: 409, code: "confirm_required", message: "This will delete about \(gigabytes) GB of the oldest recordings. Send confirm to continue.",
                               field: "confirm")
            }
        }
        // 5. One change, under the engine's operations lock.
        let folder = changesFolder ? chosen?.path : nil   // the same folder is not set again: the engine would reload its catalog
        do {
            try await backend.updateSettings { settings in
                if let folder { settings.nvrFolder = folder }
                if let keepDays { settings.nvrKeepDays = keepDays }
                if let maxSizeGB { settings.nvrMaxSizeGB = maxSizeGB }
            }
        } catch {
            throw APIError(status: 422, code: "settings_failed", message: ErrorText.describe(error))
        }
        if let folder { await waitForStorageSnapshot(of: folder) }
        return .json(storageResource(await backend.overview()))
    }

    /// After a folder change the store measures the new folder and the engine copies the store's status a moment later (about 0.4 s). The
    /// answer to the PATCH is the storage as it is after the change, so it waits for a snapshot of that folder: every 100 ms, 2 s at most. A
    /// drive that does not answer in time gets the answer as it stands (the page's next poll shows the numbers).
    private func waitForStorageSnapshot(of folder: String) async {
        let wanted = Self.normalizedPath(folder)
        for _ in 0..<20 {
            if let status = await backend.overview().nvrStorage, status.pause != .noFolder,
               status.folder.map({ Self.normalizedPath($0.path(percentEncoded: false)) }) == wanted { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: The Record switch (R4)

    private struct CameraFlagsPatch: Decodable {
        var enabled: Bool?
        var recordSound: Bool?
    }

    /// `PATCH /cameras/:id/nvr`: only `setNVR` changes these two fields (in place, under the engine's lock); `patchCamera` never carries them.
    func patchCameraNVR(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        let patch = try decode(CameraFlagsPatch.self, from: ctx)
        guard patch.enabled != nil || patch.recordSound != nil else {
            throw APIError.badRequest("Send “enabled”, “recordSound” or both.", field: "enabled")
        }
        let overview = await backend.overview()
        guard let camera = overview.configurations.first(where: { $0.id == id }) else { throw APIError.notFound("There is no camera with this identifier.") }
        if patch.enabled == true, !camera.nvrEnabled, overview.settings.nvrFolder == nil {
            throw APIError.conflict("folder_required", "Choose where to store recordings first.")
        }
        do {
            try await backend.setNVR(cameraID: id, enabled: patch.enabled, recordSound: patch.recordSound)
        } catch EngineError.unknownCamera {
            throw APIError.notFound("This camera was removed.")
        } catch {
            log.warning("changing Record for \(camera.name) failed: \(ErrorText.logDescription(error))")
            throw APIError(status: 422, code: "update_failed", message: ErrorText.describe(error))
        }
        guard let updated = await backend.overview().cameraResource(id: id) else { throw APIError.notFound("This camera was removed.") }
        return .json(updated)
    }
}
