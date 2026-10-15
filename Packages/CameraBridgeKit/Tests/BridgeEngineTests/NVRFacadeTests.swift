import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// The engine facade around the NVR fields: the restart rule, validation, `setNVR`, `archive` and `nvrStorage`.
@Suite struct NVRFacadeTests {
    @MainActor @Test func recordAndRecordSoundNeverRestartACamera() {
        let old = NVRFixtures.camera()
        var new = old
        new.nvrEnabled = true
        new.nvrRecordSound = true
        #expect(!BridgeEngine.needsRestart(old, new, paired: false) && !BridgeEngine.needsRestart(old, new, paired: true))
        new.audioEnabled.toggle()
        #expect(BridgeEngine.needsRestart(old, new, paired: false), "the mask hides only the two NVR fields")
    }

    @MainActor static func inertEngine() throws -> (BridgeEngine, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        return (BridgeEngine(environment: .inert(directory: directory.url)), directory)
    }

    @MainActor @Test func validationRejectsOutOfRangeValues() async throws {
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        let changes: [(inout BridgeSettings) -> Void] = [{ $0.nvrKeepDays = 0 }, { $0.nvrKeepDays = 366 }, { $0.nvrMaxSizeGB = 5 },
                                                         { $0.nvrMaxSizeGB = 100_001 }, { $0.nvrFolder = "relative" }, { $0.nvrFolder = "/a/../b" }]
        for change in changes {
            var settings = BridgeSettings()
            change(&settings)
            await #expect(throws: EngineError.self) { try await engine.updateSettings(settings) }
        }
    }

    @MainActor @Test func setNVRChangesOnlyItsFieldsAndUpdateCameraCarriesThemForward() async throws {
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        let camera = NVRFixtures.camera()
        try await engine.addCamera(camera, password: nil)
        try await engine.setNVR(cameraID: camera.id, enabled: true)
        #expect(engine.configurations.first?.nvrEnabled == true && engine.configurations.first?.nvrRecordSound == false)
        try await engine.setNVR(cameraID: camera.id, recordSound: true)
        #expect(engine.configurations.first?.nvrEnabled == true && engine.configurations.first?.nvrRecordSound == true, "nil leaves a field alone")
        try await engine.setNVR(cameraID: camera.id, enabled: false, recordSound: false)
        try await engine.setNVR(cameraID: camera.id, enabled: true)

        // An editor holding a copy from before Record was switched on saves its other changes without undoing Record.
        let stale = CameraConfiguration(id: camera.id, name: "Renamed", kind: .camera, vendor: .hikvision, endpoint: camera.endpoint, username: "admin")
        #expect(!stale.nvrEnabled)
        try await engine.updateCamera(stale, password: nil)
        #expect(engine.configurations.first?.name == "Renamed" && engine.configurations.first?.nvrEnabled == true)

        // The values are saved: a second engine on the same directory reads them.
        let reread = try ConfigurationStore(directory: directory.url).load()
        #expect(reread?.cameras.first?.nvrEnabled == true)

        await #expect(throws: EngineError.unknownCamera) { try await engine.setNVR(cameraID: UUID(), enabled: true) }
    }

    @MainActor @Test func aCameraWithRecordOnShowsItsStatus() async throws {
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        let camera = NVRFixtures.camera()
        try await engine.addCamera(camera, password: nil)
        await engine.refreshStatus()
        #expect(engine.cameras.first?.nvr == CameraArchiveStatus(), "Record off: off")
        try await engine.setNVR(cameraID: camera.id, enabled: true)
        #expect(engine.cameras.first?.nvr.state == .paused(.noFolder), "Record on with no folder chosen")
        try await engine.updateSettings { $0.nvrFolder = "/Volumes/Recordings" }
        await engine.refreshStatus()
        #expect(engine.cameras.first?.nvr.state != .off && engine.cameras.first?.nvr.state != .paused(.noFolder))
        try await engine.setNVR(cameraID: camera.id, enabled: false)
        #expect(engine.cameras.first?.nvr.state == .off)
    }

    @MainActor @Test func theArchiveIsThereButNotReadyBeforeStart() throws {
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        #expect(!engine.archive.isReady && engine.archive.catalogVersion == 0)
        #expect(engine.archive.extent(camera: UUID()) == nil && engine.nvrStorage == nil)
    }

    @MainActor @Test func aPreviewEngineServesTheArchiveItWasGivenAndRecordsNothing() async throws {
        struct Canned: ArchiveReading {
            func activity(camera: UUID, range: Range<Date>, binCount: Int) async -> ArchiveActivity {
                ArchiveActivity(start: range.lowerBound, binDuration: 60, bins: [], typical: nil, isComplete: true)
            }
            func fragment(camera: UUID, containing time: Date) async -> ArchiveFragment? { nil }
            func fragment(camera: UUID, startingAfter time: Date) async -> ArchiveFragment? { nil }
            func fragment(camera: UUID, id: String) async -> ArchiveFragment? { nil }
            func read(_ fragment: ArchiveFragment, _ part: ArchiveReadPart) async throws -> Data { Data() }
            func extent(camera: UUID) -> ArchiveExtent? { ArchiveExtent(oldest: Date(timeIntervalSince1970: 0), newest: Date(timeIntervalSince1970: 60)) }
            var catalogVersion: Int { 7 }
            var isReady: Bool { true }
        }
        var snapshot = BridgeEngine.Snapshot()
        snapshot.archive = Canned()
        snapshot.nvrStorage = ArchiveStorageStatus(usedBytes: 1)
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = BridgeEngine(environment: .inert(directory: directory.url), snapshot: snapshot)
        #expect(engine.archive.isReady && engine.archive.catalogVersion == 7 && engine.nvrStorage?.usedBytes == 1)
        try await engine.setNVR(cameraID: UUID(), enabled: true)   // a preview engine's operations do nothing
    }
}
