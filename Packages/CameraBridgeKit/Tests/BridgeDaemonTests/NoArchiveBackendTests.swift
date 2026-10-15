import BridgeEngine
import BridgeWeb
import Foundation
import Testing
@testable import BridgeDaemon

/// `--preview` serves the engine's sample data and records nothing, so its backend offers no archive (the NVR routes then say so).
@Suite struct NoArchiveBackendTests {
    @MainActor @Test func theWrapperHidesTheArchiveAndForwardsTheRest() async throws {
        let real = EngineBackend(engine: BridgeEngine.preview(scenario: .standard))
        #expect(real.archive != nil, "the engine always has an archive object")
        let hidden = NoArchiveBackend(wrapping: real)
        #expect(hidden.archive == nil)
        #expect(await hidden.overview().cameras.count == real.overview().cameras.count)
        await #expect(throws: ArchiveFolderError.invalidPath) { _ = try await hidden.inspectArchiveFolder("relative") }
        try await hidden.setNVR(cameraID: UUID(), enabled: true, recordSound: false)   // a preview engine's operations do nothing
    }
}
