import AppKit
import BridgeEngine
import SwiftUI

/// Settings › Recording: where recordings are kept, how much, for how long. Used and free are the engine's numbers (`engine.nvrStorage`), already
/// kept fresh, so the page only reads them. Lowering a limit that would delete recordings asks first (deleting is irreversible).
struct RecordingSettingsTab: View {
    let model: AppModel
    var showGeneral: () -> Void = {}
    @State private var pendingKeepDays: Int?
    @State private var pendingMaxSize: Int?
    @Environment(\.locale) private var locale

    var body: some View {
        let settings = model.engine.settings
        let storage = model.nvrStorage
        SettingsPage {
            SectionCard(title: "Recordings", systemImage: "recordingtape") {
                folderRow(settings: settings)
                if let storage {
                    SettingDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        if let usage = RecordingSettings.usageLine(storage: storage, maxSizeGB: settings.nvrMaxSizeGB, locale: locale) { Text(usage) }
                        if let drive = RecordingSettings.driveLine(storage: storage, locale: locale) { Text(drive).foregroundStyle(.secondary) }
                        if let oldest = storage.oldest, let newest = storage.newest {
                            Text("Recordings from \(oldest.formatted(date: .abbreviated, time: .shortened)) to \(newest.formatted(date: .abbreviated, time: .shortened)).")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let pause = storage.pause, model.engine.cameras.contains(where: { $0.nvr.state != .off }) {
                        SettingProblem(pause.readable)
                    }
                }
                SettingNote("Recordings already saved stay in the old folder and will not appear in the timeline when you choose another one.")
            }

            SectionCard(title: "Keep", systemImage: "calendar") {
                SettingRow(title: "Keep for", detail: "Older recordings are deleted.") {
                    Picker("Keep for", selection: keepDaysBinding(settings)) {
                        ForEach(RecordingSettings.choices(RecordingSettings.keepDaysChoices, including: settings.nvrKeepDays), id: \.self) { days in
                            Text(RecordingSettings.keepLabel(days)).tag(days)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingDivider()
                SettingRow(title: "Maximum size", detail: "The oldest recordings go first, across all cameras.") {
                    Picker("Maximum size", selection: maxSizeBinding(settings)) {
                        ForEach(RecordingSettings.choices(RecordingSettings.maxSizeChoices, including: settings.nvrMaxSizeGB), id: \.self) { size in
                            Text(RecordingSettings.sizeLabel(size)).tag(size)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let holds = RecordingSettings.holdsLine(storage: storage, cameras: model.engine.cameras, maxSizeGB: settings.nvrMaxSizeGB, locale: locale) {
                    SettingNote(LocalizedStringKey(holds))
                }
                if let room = RecordingSettings.roomWarning(storage: storage, maxSizeGB: settings.nvrMaxSizeGB, locale: locale) {
                    SettingProblem(room)
                }
            }

            if RecordingSettings.suggestsKeepAwake(anyCameraRecording: model.engine.cameras.contains { $0.nvr.state != .off }, keepsAwake: model.keepMacAwake) {
                SectionCard(title: "While the Mac Sleeps", systemImage: "moon.zzz") {
                    SettingRow(title: "Recording stops while the Mac sleeps",
                               detail: "Keep Mac Awake stops it from going to sleep when it is idle, so cameras keep recording. Closing a laptop’s lid still puts it to sleep.") {
                        Button("Open Keep Mac Awake") { showGeneral() }.buttonStyle(.brand(.secondary))
                    }
                }
            }
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { pendingKeepDays != nil || pendingMaxSize != nil }, set: { if !$0 { clearPending() } }),
                            titleVisibility: .visible) {
            Button("Delete and Apply", role: .destructive) { applyPending() }
            Button("Cancel", role: .cancel) { clearPending() }
        } message: {
            Text(deletionWarning(settings: settings, storage: storage) ?? "")
        }
    }

    // MARK: Folder

    private func folderRow(settings: BridgeSettings) -> some View {
        let folder = settings.nvrFolder
        return SettingRow(verbatimTitle: folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "No folder chosen"),
                          verbatimDetail: folder ?? String(localized: "Choose where Camera Bridge keeps recordings. An external drive works; so does a folder on this Mac.")) {
            HStack(spacing: 8) {
                if let folder {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }.buttonStyle(.brand(.secondary))
                }
                Button("Choose…") { Task { await model.chooseNVRFolder() } }.buttonStyle(.brand(.primary))
            }
        }
    }

    // MARK: Limits

    /// A choice that would delete recordings waits for a yes; any other applies at once.
    private func keepDaysBinding(_ settings: BridgeSettings) -> Binding<Int> {
        Binding(get: { pendingKeepDays ?? settings.nvrKeepDays }, set: { days in
            guard days != settings.nvrKeepDays else { return }
            if RecordingSettings.deletionWarning(keepDays: days, maxSizeGB: settings.nvrMaxSizeGB, storage: model.nvrStorage, now: .now) != nil {
                pendingKeepDays = days
            } else {
                Task { await model.updateSettings(String(localized: "Keep Recordings For")) { $0.nvrKeepDays = days } }
            }
        })
    }

    private func maxSizeBinding(_ settings: BridgeSettings) -> Binding<Int> {
        Binding(get: { pendingMaxSize ?? settings.nvrMaxSizeGB }, set: { size in
            guard size != settings.nvrMaxSizeGB else { return }
            if RecordingSettings.deletionWarning(keepDays: settings.nvrKeepDays, maxSizeGB: size, storage: model.nvrStorage, now: .now) != nil {
                pendingMaxSize = size
            } else {
                Task { await model.updateSettings(String(localized: "Maximum Recordings Size")) { $0.nvrMaxSizeGB = size } }
            }
        })
    }

    private var deletionTitle: LocalizedStringKey { "Delete the Oldest Recordings?" }

    private func deletionWarning(settings: BridgeSettings, storage: ArchiveStorageStatus?) -> String? {
        RecordingSettings.deletionWarning(keepDays: pendingKeepDays ?? settings.nvrKeepDays, maxSizeGB: pendingMaxSize ?? settings.nvrMaxSizeGB, storage: storage,
                                          now: .now, locale: locale)
    }

    private func applyPending() {
        let days = pendingKeepDays, size = pendingMaxSize
        clearPending()
        Task { await model.updateSettings(String(localized: "Recordings Limits")) { settings in
            if let days { settings.nvrKeepDays = days }
            if let size { settings.nvrMaxSizeGB = size }
        } }
    }

    private func clearPending() {
        pendingKeepDays = nil
        pendingMaxSize = nil
    }
}

#Preview {
    RecordingSettingsTab(model: .preview())
}
