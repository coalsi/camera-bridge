import AppKit
import BridgeEngine
import SwiftUI

/// Settings › Backup: Export Configuration… and Import Configuration…. A backup holds the cameras and the bridge settings;
/// passwords stay in the Keychain (enter them again after an import), and so do the HomeKit pairings.
struct BackupSettingsTab: View {
    let model: AppModel

    var body: some View {
        let backup = model.backup
        SettingsPage {
            SectionCard(title: "Export", systemImage: "square.and.arrow.up") {
                SettingRow(title: "Export Configuration",
                           detail: "Saves your cameras and the bridge settings as a file. It contains no passwords, no webhook token and no HomeKit pairings.") {
                    Button("Export Configuration…") { model.backup.export(from: model) }
                        .buttonStyle(.brand(.primary))
                }
                SettingNote("Each camera’s name, address, user name, stream addresses and options, and the ports, log level and keep-awake choice.")
            }

            SectionCard(title: "Import", systemImage: "square.and.arrow.down") {
                SettingRow(title: "Import Configuration",
                           detail: "Adds the cameras from a backup that this Mac doesn’t have yet. Cameras already set up are left as they are.") {
                    Button("Import Configuration…") { model.backup.chooseImport(for: model) }
                        .buttonStyle(.brand(.secondary))
                        .disabled(backup.isImporting)
                }
                SettingNote("Passwords stay in the Keychain, so imported cameras are turned off until you enter each password on the camera’s page, under Advanced › Connection, and turn it on. Add them to the Home app again if they aren’t there.")
            }

            if let status = backup.status {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(status.isError ? Brand.warning : Brand.live)
                        .accessibilityHidden(true)
                    Text(status.text)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let file = status.file {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                            .buttonStyle(.link)
                            .font(.system(size: 13))
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .confirmationDialog(backup.pending?.title ?? "", isPresented: Binding(get: { backup.pending != nil }, set: { if !$0 { backup.cancelImport() } }),
                            titleVisibility: .visible, presenting: backup.pending) { pending in
            if pending.plan.isEmpty {
                Button("Restore Settings") {
                    Task { await model.backup.confirmImport(pending, for: model, restoreSettings: true) }
                }
            } else {
                Button("Import Cameras and Settings") {
                    Task { await model.backup.confirmImport(pending, for: model, restoreSettings: true) }
                }
                Button("Import Cameras Only") {
                    Task { await model.backup.confirmImport(pending, for: model, restoreSettings: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(Self.message(for: pending.plan))
        }
    }

    /// What the confirmation says will happen.
    static func message(for plan: ConfigurationBackup.ImportPlan) -> String {
        var parts: [String] = []
        let count = plan.camerasToAdd.count
        if count > 0 {
            let names = plan.camerasToAdd.map(\.name).formatted(.list(type: .and))
            parts.append(count == 1 ? String(localized: "1 camera will be added, turned off until you enter its password: \(names).")
                                    : String(localized: "\(count) cameras will be added, turned off until you enter their passwords: \(names)."))
        } else {
            parts.append(String(localized: "Every camera in this backup is already set up."))
        }
        if !plan.alreadySetUp.isEmpty, count > 0 {
            parts.append(plan.alreadySetUp.count == 1 ? String(localized: "1 camera is already set up and stays as it is.")
                                                      : String(localized: "\(plan.alreadySetUp.count) cameras are already set up and stay as they are."))
        }
        if plan.unreadableCameras > 0 {
            parts.append(plan.unreadableCameras == 1 ? String(localized: "1 camera in the file couldn’t be read and is skipped.")
                                                     : String(localized: "\(plan.unreadableCameras) cameras in the file couldn’t be read and are skipped."))
        }
        return parts.joined(separator: " ")
    }
}

#Preview {
    BackupSettingsTab(model: .preview())
        .frame(width: 740, height: 620)
        .preferredColorScheme(.dark)
}
