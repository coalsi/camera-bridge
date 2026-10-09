import AppKit
import BridgeEngine
import SwiftUI

/// First-run sheet: what CameraBridge needs, and a Local Network access check with a guided fix when it's denied (the
/// sheet scrolls to it then). Fix… for a denial opens `LocalNetworkAccessSheet` instead.
struct OnboardingView: View {
    let model: AppModel
    /// What this sheet's last Check Access found.
    @State private var lastCheck: LocalNetworkCheckOutcome?
    @State private var isChecking = false
    /// The ID of the Local Network section, scrolled into view while access is denied.
    private static let localNetworkSection = "localNetwork"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .padding(28)
                }
                // Denied: the fix steps, Open Settings and Check Again sit below the prerequisites, out of sight.
                .onAppear { if model.engine.localNetworkAccess == .denied { proxy.scrollTo(Self.localNetworkSection, anchor: .bottom) } }
                .onChange(of: model.engine.localNetworkAccess) { _, access in
                    if access == .denied { withAnimation { proxy.scrollTo(Self.localNetworkSection, anchor: .bottom) } }
                }
            }
            HStack(spacing: 16) {
                Text(Acknowledgements.notAffiliated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(OnboardingContent.dismissTitle(hasCompletedOnboarding: model.hasCompletedOnboarding)) {
                    Task { await model.completeOnboarding() }
                }
                .buttonStyle(.brand(.primary, large: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.black.opacity(0.25))
        }
        .frame(width: 640, height: 700)
        .background { BrandCanvas() }
        .preferredColorScheme(.dark)   // the brand look is dark
        .tint(Brand.amber)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                Image("BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Camera Bridge")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .accessibilityAddTraits(.isHeader)
                    Text("Bring your network cameras into the Apple Home app, with HomeKit Secure Video recording, doorbell rings and extra sensors.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 4)

            Text("Before You Start")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(OnboardingContent.prerequisites) { item in
                    PrerequisiteRow(symbol: item.symbol, title: item.title, detail: item.detail)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .brandSurface(radius: 16)
                }
            }

            // The engine's answer is live: a background check that finds access allowed updates it here.
            LocalNetworkCheck(access: model.engine.localNetworkAccess, lastCheck: lastCheck, isChecking: isChecking) {
                Task {
                    isChecking = true
                    lastCheck = await model.checkLocalNetworkAccess()
                    isChecking = false
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .brandSurface(radius: 18)
            .id(Self.localNetworkSection)
        }
    }
}

/// Fix… for denied Local Network access (the banner, the menu bar): the check with its fix steps, Open Privacy &
/// Security Settings… and Check Again, in view at once. The access shown is the engine's live answer, so the sheet
/// says when the background checks find access allowed.
struct LocalNetworkAccessSheet: View {
    let model: AppModel
    @State private var lastCheck: LocalNetworkCheckOutcome?
    @State private var isChecking = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LocalNetworkCheck(access: model.engine.localNetworkAccess, lastCheck: lastCheck, isChecking: isChecking) {
                Task {
                    isChecking = true
                    lastCheck = await model.checkLocalNetworkAccess()
                    isChecking = false
                }
            }
            .padding(24)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.brand(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Color.black.opacity(0.25))
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background { BrandCanvas() }
        .preferredColorScheme(.dark)
        .tint(Brand.amber)
    }
}

private struct PrerequisiteRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Brand.amber)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LocalNetworkCheck: View {
    let access: LocalNetworkAccess
    let lastCheck: LocalNetworkCheckOutcome?
    let isChecking: Bool
    let check: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Local Network Access", systemImage: "network")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if access != .unknown {
                    Image(systemName: access == .granted ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(access == .granted ? .green : .red)
                        .accessibilityHidden(true)
                }
                Text(OnboardingContent.localNetworkStatus(access, lastCheck: lastCheck))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if access == .denied {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(OnboardingContent.localNetworkFixSteps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                    }
                }
                .foregroundStyle(.secondary)
                if let url = OnboardingContent.privacySettingsURL {
                    Button("Open Privacy & Security Settings…") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.brand(.secondary))
                }
            }
            HStack(spacing: 8) {
                Button(access == .denied ? "Check Again" : "Check Access", action: check)
                    .buttonStyle(.brand(.secondary))
                    .disabled(isChecking)
                if isChecking {
                    ProgressView().controlSize(.small)
                }
            }
            if isChecking {
                Text(OnboardingContent.localNetworkChecking)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("Onboarding") {
    OnboardingView(model: .preview(showsOnboarding: true))
}

#Preview("Local Network") {
    LocalNetworkAccessSheet(model: .preview())
}
