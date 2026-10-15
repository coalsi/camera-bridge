import BridgeEngine
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// The backend seams the NVR routes use (`archive`, `inspectArchiveFolder`, `setNVR`, `BridgeOverview.nvrStorage`) on the fake and on the engine.
@Suite struct BridgeBackendNVRTests {
    @Test func theFakeBackendRecordsNVRChangesAndAnswersTheFolderCheck() async throws {
        let backend = FakeBackend()
        let camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
        try await backend.addCamera(camera, password: nil)
        try await backend.setNVR(cameraID: camera.id, enabled: true, recordSound: nil)
        #expect(await backend.overview().configurations.first?.nvrEnabled == true)
        await #expect(throws: EngineError.unknownCamera) { try await backend.setNVR(cameraID: UUID(), enabled: true, recordSound: nil) }
        #expect(try await backend.inspectArchiveFolder("/var/lib/camera-bridge/recordings").totalBytes == 500_000_000_000)
        #expect(backend.archive == nil)
        backend.write { $0.nvrStorage = ArchiveStorageStatus(usedBytes: 5) }
        #expect(await backend.overview().nvrStorage?.usedBytes == 5)
    }

    @MainActor @Test func theEngineBackendForwardsToTheEngine() async throws {
        let engine = BridgeEngine.preview(scenario: .empty)
        let backend = EngineBackend(engine: engine)
        #expect(backend.archive != nil && backend.archive?.isReady == false)
        await #expect(throws: ArchiveFolderError.invalidPath) { _ = try await backend.inspectArchiveFolder("relative") }
        try await backend.setNVR(cameraID: UUID(), enabled: true, recordSound: false)   // a preview engine's operations do nothing
        #expect(await backend.overview().nvrStorage == nil)
    }
}

@Suite struct WebConfigurationNVRTests {
    @Test func theArchiveLimitsHaveTheirDefaults() {
        let configuration = WebConfiguration(dataDirectory: URL(filePath: "/tmp/x"))
        #expect(configuration.archiveLocations.isEmpty)
        #expect(configuration.maximumArchiveReads == 24 && configuration.maximumArchiveReadsPerAddress == 16)
        #expect(configuration.maximumSegmentBytes == 16 * 1_048_576 && configuration.maximumSegmentBytes == ArchiveConstants.fragmentMaximumBytes)
        let location = ArchiveLocation(id: "builtin", label: "This box’s storage", path: "/var/lib/camera-bridge/recordings")
        #expect(location == ArchiveLocation(id: "builtin", label: "This box’s storage", path: "/var/lib/camera-bridge/recordings"))
    }
}
