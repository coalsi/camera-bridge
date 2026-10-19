import BridgeEngine
import CameraAdapters
import Foundation
import Testing

/// Settings › Backup › Move to Camera Bridge OS › Stop This Mac's Bridge: every camera stops recording and is turned off, its settings kept.
@MainActor @Suite(.timeLimit(.minutes(1))) struct HandOverTests {
    @Test func stoppingThisMacsBridgeTurnsEveryCameraOffAndStopsRecording() async throws {
        var porch = LiveEngineFixture.disabledCamera("Porch")
        porch.isEnabled = true
        porch.nvrEnabled = true
        var gate = LiveEngineFixture.disabledCamera("Gate")
        gate.nvrEnabled = true
        let idle = LiveEngineFixture.disabledCamera("Idle")
        let fixture = try await LiveEngineFixture.withCameras([porch, gate, idle], onboardingCompleted: true)
        let model = fixture.model
        try await fixture.engine.updateSettings(fixture.engine.settings)   // loads the configuration
        #expect(fixture.engine.configurations.count == 3)
        let stopped = await model.handOverToAnotherBridge()
        #expect(stopped == 2, "Porch (on and recording) and Gate (recording); Idle was neither")
        let after = fixture.engine.configurations
        #expect(after.allSatisfy { !$0.isEnabled && !$0.nvrEnabled })
        #expect(after.map(\.name) == ["Porch", "Gate", "Idle"] && after.first?.endpoint.host == "192.0.2.40", "settings stay")
        #expect(model.message == nil, "no failure was shown")
    }

    @Test func thePreviewChangesNothing() async {
        let scratch = ScratchDefaults()
        let model = AppModel(options: LaunchOptions(usesPreviewEngine: true), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(),
                             defaults: scratch.defaults, previewLatency: .zero)
        #expect(await model.handOverToAnotherBridge() == 0)
    }
}
