import BridgeEngine
import Foundation
import Testing
@testable import BridgeWeb

/// The internet guard is part of Camera Bridge OS: a system without it (a Mac, a conformer written before it existed) has no report and
/// refuses a list, with a sentence.
@Suite struct InternetGuardSystemTests {
    @Test func aDevelopmentSystemHasNoGuard() async throws {
        let system = UnavailableSystemControl()
        #expect(await system.guardReport() == .unavailable)
        await #expect(throws: SystemError("The internet guard is part of Camera Bridge OS.")) {
            try await system.setGuardedCameras([GuardedCamera(address: "192.168.77.21", level: .watch)])
        }
    }

    @Test func aSystemWrittenBeforeTheGuardGetsTheSameDefaults() async throws {
        let system = FakeSystem()
        #expect(await system.guardReport() == .unavailable)
        await #expect(throws: SystemError.self) { try await system.setGuardedCameras([]) }
    }
}
