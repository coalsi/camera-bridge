import BridgeEngine
import BridgeSupport
import Foundation
import Testing

@Suite struct DiagnosticsFilterTests {
    private let patio = UUID()
    private let garage = UUID()

    private var entries: [LogEntry] {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        return [
            LogEntry(date: base, level: .debug, category: "LiveStream", message: "live stream trace: first video packet sent 412 ms after start", cameraID: patio),
            LogEntry(date: base + 1, level: .info, category: "events", message: "ONVIF 192.0.2.44: event channel closed by the camera", cameraID: patio),
            LogEntry(date: base + 2, level: .warning, category: "Engine", message: "Webhook port busy"),
            LogEntry(date: base + 3, level: .error, category: "LiveStream", message: "video send failed", cameraID: garage),
            LogEntry(date: base + 4, level: .debug, category: "HAP", message: "pair-verify done", cameraID: garage),
        ]
    }

    @Test func filtersByLevelCameraSubsystemAndSearch() {
        #expect(DiagnosticsFilter().apply(to: entries).count == 5)
        #expect(DiagnosticsFilter(minimumLevel: .warning).apply(to: entries).map(\.message) == ["video send failed", "Webhook port busy"])
        #expect(DiagnosticsFilter(camera: .camera(patio)).apply(to: entries).count == 2)
        #expect(DiagnosticsFilter(camera: .engine).apply(to: entries).map(\.category) == ["Engine"])
        #expect(DiagnosticsFilter(subsystem: "LiveStream").apply(to: entries).count == 2)
        #expect(DiagnosticsFilter(subsystem: "LiveStream", searchText: "first video").apply(to: entries).count == 1)
        #expect(DiagnosticsFilter(searchText: "  PRIVATE ").apply(to: entries).isEmpty)
        #expect(DiagnosticsFilter(camera: .camera(garage), subsystem: "HAP").apply(to: entries).map(\.message) == ["pair-verify done"])
    }

    @Test func searchAlsoMatchesTheCamerasName() {
        let names = [patio: "Patio", garage: "Garage"]
        #expect(DiagnosticsFilter(searchText: "garage").apply(to: entries, cameraNames: names).count == 2)
        #expect(DiagnosticsFilter(searchText: "garage").apply(to: entries).isEmpty, "without names the camera is not searchable")
    }

    @Test func resultsAreNewestFirstAndLimited() {
        let result = DiagnosticsFilter().apply(to: entries, limit: 2)
        #expect(result.map(\.message) == ["pair-verify done", "video send failed"])
    }

    @Test func subsystemsAreListedOnceAndSorted() {
        #expect(DiagnosticsFilter.subsystems(in: entries) == ["Engine", "events", "HAP", "LiveStream"])
    }
}

@MainActor @Suite struct DiagnosticsModelTests {
    @Test func theModelReloadsWhenTheLogChangedAndFiltersTheRows() {
        let log = DiagnosticsLog(directory: nil, memoryCapacity: 50)
        let model = DiagnosticsModel(log: { log })
        model.refresh()
        #expect(model.entries.isEmpty)
        log.record(LogEntry(level: .info, category: "Engine", message: "Bridge running"))
        log.record(LogEntry(level: .debug, category: "LiveStream", message: "live stream trace: first video packet"))
        model.refresh()
        #expect(model.entries.count == 2 && model.subsystems == ["Engine", "LiveStream"])
        model.filter.minimumLevel = .info
        #expect(model.visibleEntries(cameraNames: [:]).map(\.message) == ["Bridge running"])
        model.filter = DiagnosticsFilter(searchText: "first video")
        #expect(model.visibleEntries(cameraNames: [:]).count == 1 && model.matchCount(cameraNames: [:]) == 1)
    }

    @Test func withoutAnInstalledLogTheEnginesRecentLogIsShown() {
        let fallback = [LogEntry(level: .info, category: "Engine", message: "from the engine")]
        let model = DiagnosticsModel(log: { nil }, fallbackEntries: { fallback })
        model.refresh()
        #expect(model.entries == fallback)
    }

    @Test func exportWritesTheTextAndReportsFailures() throws {
        let model = DiagnosticsModel(log: { nil })
        let url = FileManager.default.temporaryDirectory.appending(path: "diagnostics-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        model.write("Camera Bridge diagnostics\nline", to: url)
        #expect(model.lastExport == url && model.exportFailure == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Camera Bridge diagnostics\nline")
        model.write("x", to: URL(fileURLWithPath: "/nonexistent-directory/diagnostics.txt"))
        #expect(model.exportFailure != nil && model.lastExport == nil)
        #expect(DiagnosticsModel.exportFileName(Date(timeIntervalSince1970: 1_790_000_000)).hasPrefix("CameraBridge-Diagnostics-2026"))
        #expect(DiagnosticsModel.exportFileName().hasSuffix(".txt"))
    }
}
