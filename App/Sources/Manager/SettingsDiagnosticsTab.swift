import AppKit
import BridgeEngine
import BridgeSupport
import SwiftUI

/// Settings › Diagnostics: how much CameraBridge logs, the Diagnostics page and its export, and where its data lives.
struct DiagnosticsSettingsTab: View {
    let model: AppModel

    var body: some View {
        SettingsPage {
            SectionCard(title: "Logging", systemImage: "list.bullet.rectangle") {
                SettingRow(title: "Log Level",
                           detail: "Info suits everyday use. Debug records more detail while you chase a problem. Logs never include passwords, tokens or stream URLs with credentials.") {
                    Picker("Log Level", selection: Binding(get: { model.engine.settings.logLevel }, set: { level in
                        Task { await model.updateSettings(String(localized: "Log Level")) { $0.logLevel = level } }
                    })) {
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            Text(LogFilter.levelName(level)).tag(level)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SectionCard(title: "Motion Detection Test", systemImage: "waveform.badge.magnifyingglass") {
                SettingToggleRow(title: "Compare built-in motion detection with camera events (test)",
                                 detail: "Adds light video decoding per camera and doesn’t change recordings or what the Home app sees.",
                                 isOn: Binding(get: { model.motionShadowTest }, set: { on in Task { await model.setMotionShadowTest(on) } }))
                SettingNote("Uses each camera’s small (sub) stream, only for cameras that report motion themselves. The results are in the Diagnostics page and the exported diagnostics.")
            }

            SectionCard(title: "Diagnostics", systemImage: "stethoscope") {
                SettingRow(title: "Diagnostics Page",
                           detail: "Everything Camera Bridge logged, from every camera and part of the app, with filters and search.") {
                    Button("Open Diagnostics") { model.showManager(selecting: .diagnostics) }
                        .buttonStyle(.brand(.secondary))
                }
                SettingDivider()
                SettingRow(title: "Export Diagnostics",
                           detail: "Saves a text file with the recent log and each camera’s status, to send when something doesn’t work. It contains no passwords or setup codes.") {
                    Button("Export Diagnostics…") { model.exportDiagnostics() }
                        .buttonStyle(.brand(.primary))
                }
                if let failure = model.diagnostics.exportFailure {
                    SettingProblem(failure)
                } else if let url = model.diagnostics.lastExport {
                    HStack(spacing: 10) {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.live)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.link)
                            .font(.system(size: 13))
                    }
                }
            }

            SectionCard(title: "Data", systemImage: "folder") {
                SettingRow(title: "Data Folder",
                           detail: "Your cameras’ configuration (config.json) and Camera Bridge’s logs are kept here. Passwords and HomeKit keys are in the Keychain.") {
                    Button("Show in Finder") { model.revealDataFolder() }
                        .buttonStyle(.brand(.secondary))
                }
                SettingCode(text: SettingsText.displayPath(model.dataDirectory), size: 12)
            }
        }
    }
}

#Preview {
    DiagnosticsSettingsTab(model: .preview())
        .frame(width: 740, height: 620)
        .preferredColorScheme(.dark)
}
