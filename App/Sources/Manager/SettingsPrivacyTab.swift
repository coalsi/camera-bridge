import BridgeEngine
import CameraAdapters
import SwiftUI

/// Settings › Privacy: the one thing Camera Bridge can send (an opt-in, anonymous setup report) and the two things it
/// downloads (the public camera profiles feed and the list of app versions Sparkle reads).
struct PrivacySettingsTab: View {
    let model: AppModel
    @State private var showsExample = false

    var body: some View {
        SettingsPage {
            SectionCard(title: "Help Improve Camera Support", systemImage: "wrench.and.screwdriver") {
                SettingToggleRow(title: "Send setup reports automatically",
                                 detail: "When Optimize for HomeKit can’t fix something on a camera, send an anonymous setup report. With this off, Camera Bridge asks first, every time, and shows you the report.",
                                 isOn: Binding(get: { model.sharesSetupReports }, set: { model.sharesSetupReports = $0 }))
                SettingDivider()
                SettingRow(title: "Example Report", detail: "An example with made-up values. The real report has the same fields.") {
                    Button(showsExample ? "Hide Example" : "Show Example") { showsExample.toggle() }
                        .buttonStyle(.brand(.secondary))
                }
                if showsExample {
                    SettingCode(text: SetupReport.example.prettyJSON, size: 11)
                }
                SettingNote("A report contains the camera’s brand, model and firmware version, which ways of changing its settings worked or failed, the HomeKit readiness results, and the Camera Bridge and macOS versions. It never contains IP addresses, camera or home names, passwords, serial numbers, images or video, and it isn’t linked to you or used for tracking.")
                Link("Privacy Policy", destination: CameraBridgeService.privacyPolicy)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.amber)
            }

            SectionCard(title: "Camera Profiles", systemImage: "arrow.triangle.2.circlepath") {
                if let status = model.cameraProfileStatus {
                    SettingRow(verbatimTitle: SettingsText.profileSummary(status), verbatimDetail: SettingsText.profileSource(status)) { EmptyView() }
                    SettingDivider()
                    SettingRow(verbatimTitle: String(localized: "Last Checked"), verbatimDetail: SettingsText.lastChecked(status.lastCheck)) {
                        HStack(spacing: 10) {
                            if model.isCheckingCameraProfiles { ProgressView().controlSize(.small) }
                            Button("Check Now") { Task { await model.checkCameraProfilesNow() } }
                                .buttonStyle(.brand(.secondary))
                                .disabled(model.isCheckingCameraProfiles)
                        }
                    }
                    if let result = model.cameraProfileCheckResult {
                        let outcome = SettingsText.checkResult(result)
                        if outcome.isProblem {
                            SettingProblem(outcome.text)
                        } else {
                            Label(outcome.text, systemImage: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.live)
                        }
                    }
                } else {
                    SettingNote("Camera profiles aren’t available here.")
                }
                SettingNote("Profiles tell Camera Bridge how to set up cameras it knows about. It downloads a public list from the Camera Bridge website at most once a day, and sends nothing about you, your cameras or your network.")
            }

            SectionCard(title: "Updates", systemImage: "arrow.down.circle") {
                SettingNote("Unless you turn it off in Settings › General, Camera Bridge asks the Camera Bridge website for the list of app versions about once a day. The request contains only the app’s name and version, nothing about you, your cameras or your network, and a new version is only installed when you agree.")
            }
        }
        .onAppear { model.refreshCameraProfileStatus() }
    }
}

#Preview {
    PrivacySettingsTab(model: .preview())
        .frame(width: 740, height: 620)
        .preferredColorScheme(.dark)
}
