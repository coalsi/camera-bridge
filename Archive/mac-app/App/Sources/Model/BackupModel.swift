import AppKit
import BridgeEngine
import BridgeSupport
import Foundation
import Observation
import UniformTypeIdentifiers

/// Settings › Backup: Export Configuration… and Import Configuration…. The file is the person's own (a save and an open
/// panel); nothing is sent anywhere. An import is shown as a plan first (`pending`) and applied only on confirmation.
@MainActor @Observable
final class BackupModel {
    /// What the last export or import did, shown on the page; nil before one ran.
    struct Status: Equatable {
        var text: String
        var isError = false
        /// The exported file, so the page can offer Show in Finder.
        var file: URL?
    }

    /// An import waiting for the person's confirmation.
    struct Pending: Equatable {
        var plan: ConfigurationBackup.ImportPlan
        /// "Backup of 2 October 2026" for the dialog.
        var title: String
    }

    private(set) var status: Status?
    private(set) var pending: Pending?
    private(set) var isImporting = false

    // MARK: Export

    /// Export Configuration…: asks where to save the file and writes it.
    func export(from model: AppModel) {
        guard !model.skipInPreview(String(localized: "Export Configuration")) else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Configuration")
        panel.message = String(localized: "Saves your cameras and settings. It contains no passwords, no webhook token and no HomeKit pairings.")
        panel.allowedContentTypes = [Self.contentType]
        panel.nameFieldStringValue = ConfigurationBackup.fileName()
        panel.canCreateDirectories = true
        panel.begin { [weak self, weak model] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self, let model else { return }
                self.write(model.makeBackup(), to: url)
            }
        }
    }

    func write(_ backup: ConfigurationBackup, to url: URL) {
        do {
            try backup.encoded().write(to: url, options: .atomic)
            let count = backup.cameras.count
            status = Status(text: count == 1 ? String(localized: "Exported 1 camera and the bridge settings.")
                                             : String(localized: "Exported \(count) cameras and the bridge settings."), file: url)
        } catch {
            status = Status(text: String(localized: "The configuration couldn’t be saved (\(error.localizedDescription))."), isError: true)
        }
    }

    // MARK: Import

    /// Import Configuration…: asks for a file, then shows what importing it would do.
    func chooseImport(for model: AppModel) {
        guard !model.skipInPreview(String(localized: "Import Configuration")) else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Configuration")
        panel.message = String(localized: "Choose a Camera Bridge backup. Nothing changes until you confirm.")
        panel.allowedContentTypes = [Self.contentType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self, weak model] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self, let model else { return }
                self.load(url, for: model)
            }
        }
    }

    func load(_ url: URL, for model: AppModel) {
        do {
            // A backup is a few kilobytes: anything large is not one.
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maximumFileBytes else { throw ConfigurationBackup.ReadError.notABackup }
            try prepare(Data(contentsOf: url), for: model)
        } catch {
            status = Status(text: Self.describe(error), isError: true)
            pending = nil
        }
    }

    /// Reads `data` and puts the plan up for confirmation.
    func prepare(_ data: Data, for model: AppModel) throws {
        let reading = try ConfigurationBackup.read(data)
        let plan = reading.backup.plan(existing: model.engine.configurations, unreadableCameras: reading.unreadableCameras)
        let date = reading.backup.exportedAt.formatted(date: .long, time: .omitted)
        pending = Pending(plan: plan, title: String(localized: "Backup of \(date)"))
        status = nil
    }

    func cancelImport() {
        pending = nil
    }

    /// Applies the confirmed plan: adds the cameras (turned off, without passwords) and, with `restoreSettings`, the
    /// backup's bridge settings. `pending` is passed in because dismissing the confirmation clears `self.pending`.
    func confirmImport(_ pending: Pending, for model: AppModel, restoreSettings: Bool) async {
        guard !isImporting else { return }
        self.pending = nil
        isImporting = true
        defer { isImporting = false }
        let outcome = await model.applyImport(pending.plan, restoreSettings: restoreSettings)
        status = Status(text: outcome.summary, isError: outcome.hasFailures)
    }

    static let maximumFileBytes = 5_000_000

    static var contentType: UTType {
        UTType(filenameExtension: ConfigurationBackup.fileExtension, conformingTo: .json) ?? .json
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? ConfigurationBackup.ReadError { return error.errorDescription ?? "" }
        return String(localized: "The file couldn’t be read (\(error.localizedDescription)).")
    }
}

/// What applying an import did.
struct ImportOutcome: Equatable {
    var added: [String] = []
    /// Camera name and why it wasn't added.
    var failed: [(name: String, reason: String)] = []
    var restoredSettings = false
    var settingsFailed = false
    var skippedExisting = 0

    static func == (lhs: ImportOutcome, rhs: ImportOutcome) -> Bool {
        lhs.added == rhs.added && lhs.failed.map(\.name) == rhs.failed.map(\.name) && lhs.restoredSettings == rhs.restoredSettings
            && lhs.settingsFailed == rhs.settingsFailed && lhs.skippedExisting == rhs.skippedExisting
    }

    var hasFailures: Bool { !failed.isEmpty || settingsFailed }

    /// One short paragraph for the Backup page.
    var summary: String {
        var parts: [String] = []
        if !added.isEmpty {
            parts.append(added.count == 1 ? String(localized: "Added 1 camera, turned off until you enter its password.")
                                          : String(localized: "Added \(added.count) cameras, turned off until you enter their passwords."))
        } else if failed.isEmpty {
            parts.append(String(localized: "No cameras were added."))
        }
        if skippedExisting > 0 {
            parts.append(skippedExisting == 1 ? String(localized: "1 camera was already set up.") : String(localized: "\(skippedExisting) cameras were already set up."))
        }
        if !failed.isEmpty {
            let names = failed.map(\.name).formatted(.list(type: .and))
            parts.append(String(localized: "Couldn’t add \(names)."))
        }
        if restoredSettings { parts.append(String(localized: "Settings restored.")) }
        if settingsFailed { parts.append(String(localized: "The settings couldn’t be restored.")) }
        return parts.joined(separator: " ")
    }
}

extension AppModel {
    /// The backup of what is configured now: the engine's settings and cameras (never a password or the token).
    func makeBackup(now: Date = Date()) -> ConfigurationBackup {
        ConfigurationBackup(settings: engine.settings, cameras: engine.configurations, exportedAt: now,
                            appVersion: "\(AppInfo.shortVersion) (\(AppInfo.build))")
    }

    /// Adds the plan's cameras one at a time (a camera that fails doesn't stop the others; the engine's reason is kept)
    /// and applies its settings when asked. A camera added meanwhile is left alone. Preview mode applies nothing.
    func applyImport(_ plan: ConfigurationBackup.ImportPlan, restoreSettings: Bool) async -> ImportOutcome {
        var outcome = ImportOutcome(skippedExisting: plan.alreadySetUp.count)
        guard !skipInPreview(String(localized: "Import Configuration")) else { return outcome }
        for camera in plan.camerasToAdd {
            if configuration(for: camera.id) != nil {
                outcome.skippedExisting += 1
                continue
            }
            do {
                try await engine.addCamera(camera, password: nil)
                outcome.added.append(camera.name)
            } catch {
                outcome.failed.append((camera.name, ErrorText.describe(error)))
            }
        }
        if restoreSettings {
            let settings = plan.settings
            if await updateSettings(String(localized: "Restore Settings"), { settings.applied(to: &$0) }) {
                outcome.restoredSettings = true
            } else {
                outcome.settingsFailed = true
            }
        }
        return outcome
    }
}
