import AppKit
import SwiftUI

/// About Camera Bridge: icon, name, version and build, copyright, the website and legal links, the licence, acknowledgements and the
/// trademark notice. Shown in the About window (app menu, status menu) and on Settings › About.
struct AboutView: View {
    @State private var showingAcknowledgements = false
    @Environment(\.appUpdater) private var updater

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text("Camera Bridge")
                    .font(.title.weight(.semibold))
                Text("Version \(AppInfo.shortVersion) (\(AppInfo.build))")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            Text(AppInfo.copyright)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Free for personal and noncommercial use. Commercial use needs a license.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link("Website", destination: CameraBridgeService.website)
                Link("Documentation", destination: CameraBridgeService.documentation)
                Link("Source Code", destination: CameraBridgeService.sourceCode)
                Link("Support", destination: CameraBridgeService.support)
            }
            .font(.callout)
            HStack(spacing: 14) {
                Link("License", destination: CameraBridgeService.license)
                Link("Privacy Policy", destination: CameraBridgeService.privacyPolicy)
                Link("Terms of Use", destination: CameraBridgeService.terms)
            }
            .font(.callout)
            HStack(spacing: 12) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Button("Acknowledgements…") { showingAcknowledgements = true }
            }
            Text(Acknowledgements.aboutDisclaimer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingAcknowledgements) { AcknowledgementsView() }
    }
}

/// The third-party licences Camera Bridge uses, in full (bundled `Acknowledgements.md`).
struct AcknowledgementsView: View {
    @State private var sections = Acknowledgements.load()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Acknowledgements")
                .font(.headline)
                .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(Acknowledgements.notAffiliated)
                    Text(Acknowledgements.trademarks)
                        .foregroundStyle(.secondary)
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.headline)
                            Text(section.body)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 620, height: 520)
    }
}

/// The About window's scene content.
struct AboutWindowContent: View {
    var body: some View {
        AboutView()
            .frame(width: 420)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    AboutView()
        .frame(width: 420)
}
