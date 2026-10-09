import AppKit
import BridgeEngine
import BridgeSupport
import Foundation
import Observation
import UniformTypeIdentifiers

/// The Diagnostics page's data: the central log's entries (`DiagnosticsCenter`, every subsystem at debug level, redacted),
/// reloaded while the page is visible, and the text bundle Export Diagnostics… saves.
@MainActor @Observable
final class DiagnosticsModel {
    /// Rows shown at most (the newest matching ones); the whole log is still exported.
    static let displayLimit = 2_000

    private(set) var entries: [LogEntry] = []
    var filter = DiagnosticsFilter()
    /// Why the last export failed, nil otherwise.
    private(set) var exportFailure: String?
    /// The saved bundle's location after an export, nil otherwise.
    private(set) var lastExport: URL?

    @ObservationIgnored private var loadedTotal = -1
    @ObservationIgnored private let log: () -> DiagnosticsLog?
    @ObservationIgnored private let fallbackEntries: () -> [LogEntry]

    /// `log`: where the entries come from (the installed `DiagnosticsLog`); without one (previews, tests) `fallbackEntries`.
    init(log: @escaping () -> DiagnosticsLog? = { DiagnosticsCenter.shared.log }, fallbackEntries: @escaping () -> [LogEntry] = { [] }) {
        self.log = log
        self.fallbackEntries = fallbackEntries
    }

    /// Reloads the entries when the log changed since the last call.
    func refresh() {
        guard let log = log() else {
            let fallback = fallbackEntries()
            if fallback != entries { entries = fallback }
            return
        }
        let total = log.totalRecorded
        guard total != loadedTotal else { return }
        loadedTotal = total
        entries = log.entries()
    }

    func visibleEntries(cameraNames: [UUID: String]) -> [LogEntry] {
        filter.apply(to: entries, cameraNames: cameraNames, limit: Self.displayLimit)
    }

    func matchCount(cameraNames: [UUID: String]) -> Int {
        filter.apply(to: entries, cameraNames: cameraNames).count
    }

    var subsystems: [String] { DiagnosticsFilter.subsystems(in: entries) }

    /// "CameraBridge-Diagnostics-20261001-203312.txt"
    static func exportFileName(_ date: Date = Date()) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "CameraBridge-Diagnostics-%04d%02d%02d-%02d%02d%02d.txt", components.year ?? 0, components.month ?? 0, components.day ?? 0,
                      components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
    }

    /// The system and app facts for the report.
    static func context(launched: Date) -> DiagnosticsContext {
        let info = Bundle.main.infoDictionary ?? [:]
        return DiagnosticsContext.current(appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                                          appBuild: info["CFBundleVersion"] as? String ?? "unknown", macModel: macModelIdentifier() ?? "unknown",
                                          launched: launched)
    }

    /// "Mac15,3" (`hw.model`).
    static func macModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Asks where to save the bundle (the person chooses; nothing is sent anywhere) and writes `text` there.
    func export(text: @escaping @MainActor () -> String) {
        exportFailure = nil
        lastExport = nil
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Diagnostics")
        panel.message = String(localized: "Saves a text file with Camera Bridge’s recent log and each camera’s status. It contains no passwords or setup codes.")
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = Self.exportFileName()
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.write(text(), to: url) }
        }
    }

    func write(_ text: String, to url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastExport = url
            exportFailure = nil
        } catch {
            lastExport = nil
            exportFailure = String(localized: "The diagnostics couldn’t be saved (\(error.localizedDescription)).")
        }
    }
}
