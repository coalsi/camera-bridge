import BridgeEngine
import CameraAdapters
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) @MainActor struct SetupReportConsentTests {
    private final class RecordingSender: SetupReportSending {
        var bodies: [Data] = []
        func send(_ body: Data) async -> Bool { bodies.append(body); return true }
    }

    private func model(defaults: UserDefaults, sender: RecordingSender, preview: Bool = false) -> AppModel {
        AppModel(options: LaunchOptions(usesPreviewEngine: preview), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(),
                 defaults: defaults, previewLatency: .zero, reportSender: sender)
    }

    private func check(_ id: String, _ status: HomeKitReadinessCheck.Status, _ fix: HomeKitReadinessCheck.FixMethod = .none) -> HomeKitReadinessCheck {
        HomeKitReadinessCheck(id: id, title: id, status: status, explanation: "", fixMethod: fix)
    }

    private var unresolved: HomeKitOptimizationResult {
        HomeKitOptimizationResult(before: HomeKitReadinessReport(checks: []),
                                  after: HomeKitReadinessReport(checks: [check("smartCodec", .warning, .manual(["Turn it off"]))]), canUndo: false)
    }

    private var clean: HomeKitOptimizationResult {
        HomeKitOptimizationResult(before: HomeKitReadinessReport(checks: []), after: HomeKitReadinessReport(checks: [check("codec", .ok)]), canUndo: false)
    }

    @Test func sharingIsOffByDefaultAndRemembered() {
        let scratch = ScratchDefaults()
        let model = model(defaults: scratch.defaults, sender: RecordingSender())
        #expect(!model.sharesSetupReports)
        model.sharesSetupReports = true
        #expect(self.model(defaults: scratch.defaults, sender: RecordingSender()).sharesSetupReports)
    }

    @Test func withSharingOffTheSheetAsksAndNothingIsSentUntilSendIsPressed() async throws {
        let scratch = ScratchDefaults()
        let sender = RecordingSender()
        let model = model(defaults: scratch.defaults, sender: sender)
        let offer = model.offerSetupReport(for: unresolved, cameraID: UUID())
        guard case .ask(let report) = offer else { Issue.record("expected a prompt, got \(offer)"); return }
        #expect(sender.bodies.isEmpty)
        #expect(await model.sendSetupReport(report))
        #expect(sender.bodies == [try report.encoded()], "the exact bytes that were shown are the ones sent")
    }

    @Test func aRunWithNothingLeftToFixOffersNothing() {
        let scratch = ScratchDefaults()
        let sender = RecordingSender()
        let model = model(defaults: scratch.defaults, sender: sender)
        #expect(model.offerSetupReport(for: clean, cameraID: UUID()) == .none)
        #expect(sender.bodies.isEmpty)
    }

    @Test func withSharingOnTheReportGoesWithoutAsking() async {
        let scratch = ScratchDefaults()
        let sender = RecordingSender()
        let model = model(defaults: scratch.defaults, sender: sender)
        model.sharesSetupReports = true
        #expect(model.offerSetupReport(for: unresolved, cameraID: UUID()) == .sentAutomatically)
        for _ in 0..<50 where sender.bodies.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(sender.bodies.count == 1)
    }

    @Test func previewModeNeverSends() async {
        let scratch = ScratchDefaults()
        let sender = RecordingSender()
        let model = model(defaults: scratch.defaults, sender: sender, preview: true)
        model.sharesSetupReports = true
        #expect(model.offerSetupReport(for: unresolved, cameraID: UUID()) == .none)
        #expect(await !model.sendSetupReport(.example))
        #expect(sender.bodies.isEmpty)
    }
}
