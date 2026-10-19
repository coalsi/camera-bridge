import BridgeEngine
import CameraAdapters
import SwiftUI

/// "HomeKit Readiness" card on the camera detail page (Overview tab): a score/summary and an expandable checklist, with
/// "Optimize for HomeKit…" opening `HomeKitOptimizeSheet` (presented by the camera page, which owns `readiness` so the
/// hero button and the score tile share it).
struct HomeKitReadinessSection: View {
    let readiness: ReadinessState
    /// Whether the checklist is open: the dashboard's "View Checklist" opens it.
    @Binding var isChecklistExpanded: Bool

    var body: some View {
        Section {
            if readiness.isLoading {
                HStack { ProgressView(); Text("Checking HomeKit readiness…").foregroundStyle(.secondary) }
            } else if let loadError = readiness.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if let report = readiness.report {
                ReadinessSummaryRow(report: report)
                DisclosureGroup("Checklist", isExpanded: $isChecklistExpanded) {
                    ForEach(report.checks, id: \.id) { check in
                        ReadinessCheckRow(check: check)
                    }
                }
                Button(readiness.canOptimize ? "Optimize for HomeKit…" : "How to Fix…") { readiness.showingOptimizeSheet = true }
                    .disabled(!readiness.canAct)
                if !readiness.canAct {
                    Text(report.checks.contains { $0.status != .ok }
                         ? "Nothing here can be changed automatically. Follow the steps in the checklist on the camera's web page."
                         : "Already optimized. Nothing to change.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("HomeKit Readiness")
        } footer: {
            Text("How well this camera's video and audio settings fit HomeKit Secure Video's requirements.")
        }
    }
}

private struct ReadinessSummaryRow: View {
    let report: HomeKitReadinessReport

    var body: some View {
        HStack(spacing: 12) {
            ScoreRing(score: report.score)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(report.score)% ready")
                    .font(.headline)
                Text(report.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct ReadinessCheckRow: View {
    let check: HomeKitReadinessCheck

    private var icon: (name: String, color: Color) {
        switch check.status {
        case .ok: ("checkmark.circle.fill", .green)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        case .problem: ("xmark.octagon.fill", .red)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon.name)
                    .foregroundStyle(icon.color)
                Text(check.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                fixBadge
            }
            Text(check.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let recommended = check.recommendedValue {
                Text("Recommended: \(recommended)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if case .manual(let steps) = check.fixMethod, !steps.isEmpty {
                DisclosureGroup("How to fix this on the camera") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)")
                                .font(.caption)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var fixBadge: some View {
        switch check.fixMethod {
        case .automatic:
            Text("Fixable automatically")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.blue.opacity(0.15), in: Capsule())
                .foregroundStyle(.blue)
        case .manual:
            Text("Manual fix")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }
}

/// "Optimize for HomeKit…": confirms exactly what will change, applies it (Applying → Reconnecting → Testing),
/// then shows the before/after checklist with Undo.
struct HomeKitOptimizeSheet: View {
    let model: AppModel
    let cameraID: UUID
    let name: String
    let report: HomeKitReadinessReport
    var endpoint: CameraEndpoint? = nil
    /// Re-checks the camera (e.g. after fixing something on its web page); the parent passes the new report back in.
    var reload: (() async -> Void)? = nil
    @State private var isRechecking = false
    @Environment(\.dismiss) private var dismiss

    /// The camera's own web page, opened in the browser while this sheet stays open so manual fixes can be made
    /// side by side. Never carries credentials.
    private var webPageURL: URL? {
        endpoint.flatMap { URL(string: "\($0.useHTTPS ? "https" : "http")://\($0.host):\($0.httpPort)/") }
    }

    private var manualChecks: [HomeKitReadinessCheck] {
        report.checks.filter { if case .manual = $0.fixMethod { $0.status != .ok } else { false } }
    }

    private enum Phase: Equatable {
        case confirming
        case applying
        case reconnecting
        case testing
        case done(HomeKitOptimizationResult)
        case failed(String)
    }

    @State private var phase: Phase = .confirming
    @State private var isUndoing = false
    /// Whether to offer a setup report for this run (`AppModel.offerSetupReport`).
    @State private var reportOffer: AppModel.SetupReportOffer = .none
    @State private var reportWasSent = false

    private var automaticFixes: [HomeKitReadinessCheck] {
        report.checks.filter { if case .automatic = $0.fixMethod { true } else { false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Optimize “\(name)” for HomeKit")
                .font(.headline)
            Group {
                switch phase {
                case .confirming: ConfirmationList(checks: automaticFixes, manualChecks: manualChecks)
                case .applying: ProgressRow(text: "Applying settings to the camera…")
                case .reconnecting: ProgressRow(text: "Reconnecting the camera’s stream…")
                case .testing: ProgressRow(text: "Testing the new settings…")
                case .done(let result):
                    VStack(alignment: .leading, spacing: 12) {
                        ResultsList(result: result)
                        if case .ask(let report) = reportOffer {
                            Divider()
                            SetupReportPrompt(report: report, send: { Task { await sendReport(report) } }, decline: { reportOffer = .none })
                        } else if reportWasSent {
                            Label("Setup report sent. Thank you.", systemImage: "paperplane")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 260)
            HStack {
                if let webPageURL {
                    Button("Open Camera Web Page", systemImage: "safari") { NSWorkspace.shared.open(webPageURL) }
                        .help("Opens the camera's settings in your browser. This window stays open.")
                }
                if case .confirming = phase, let reload {
                    Button {
                        Task { isRechecking = true; await reload(); isRechecking = false }
                    } label: {
                        if isRechecking { ProgressView().controlSize(.small) } else { Label("Check Again", systemImage: "arrow.clockwise") }
                    }
                    .disabled(isRechecking)
                    .help("Re-reads the camera's settings after you change something on its web page.")
                }
                if case .done(let result) = phase, result.canUndo {
                    Button("Undo") { Task { await undo() } }
                        .disabled(isUndoing)
                }
                Spacer()
                Button(isFinalPhase ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRunning)
                if case .confirming = phase {
                    Button("Optimize") { Task { await optimize() } }
                        .buttonStyle(.brand(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(automaticFixes.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var isRunning: Bool {
        switch phase {
        case .applying, .reconnecting, .testing: true
        default: false
        }
    }

    private var isFinalPhase: Bool {
        switch phase {
        case .done, .failed: true
        default: false
        }
    }

    private func optimize() async {
        phase = .applying
        // The engine does the whole apply → restart → re-measure sequence in one call; these phases are a best-effort
        // narration of what it's doing, not separately awaited steps.
        Task { try? await Task.sleep(for: .seconds(1)); if case .applying = phase { phase = .reconnecting } }
        Task { try? await Task.sleep(for: .seconds(3)); if case .reconnecting = phase { phase = .testing } }
        do {
            let result = try await model.optimizeForHomeKit(cameraID: cameraID)
            phase = .done(result)
            reportOffer = model.offerSetupReport(for: result, cameraID: cameraID)
        } catch {
            phase = .failed(ErrorText.describe(error))
        }
    }

    /// Send was pressed on the prompt: posts the report that was shown. A failure only ends up in the log.
    private func sendReport(_ report: SetupReport) async {
        reportOffer = .none
        reportWasSent = await model.sendSetupReport(report)
    }

    private func undo() async {
        isUndoing = true
        do {
            try await model.undoHomeKitOptimization(cameraID: cameraID)
            dismiss()
        } catch {
            phase = .failed(ErrorText.describe(error))
        }
        isUndoing = false
    }
}

private struct ConfirmationList: View {
    let checks: [HomeKitReadinessCheck]
    var manualChecks: [HomeKitReadinessCheck] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Camera Bridge will change:")
                    .font(.subheadline.weight(.medium))
                ForEach(checks, id: \.id) { check in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title).font(.subheadline)
                            if let recommended = check.recommendedValue {
                                Text("→ \(recommended)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if checks.isEmpty {
                    Text("Nothing can be changed automatically right now.").font(.subheadline).foregroundStyle(.secondary)
                }
                if !manualChecks.isEmpty {
                    Text("Change on the camera yourself:")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 6)
                    ForEach(manualChecks, id: \.id) { check in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(check.title, systemImage: "wrench.and.screwdriver").font(.subheadline)
                            if case .manual(let steps) = check.fixMethod {
                                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                    Text("\(index + 1). \(step)").font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                Text("The camera's stream reconnects briefly while this applies. If the resolution or codec changes, you may need to turn HomeKit Secure Video recording off and on again for this camera in the Home app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProgressRow: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ResultsList: View {
    let result: HomeKitOptimizationResult

    /// A readiness check ID in words.
    static func title(_ checkID: String) -> String {
        switch checkID {
        case "codec": "Video format"
        case "keyframeInterval": "Keyframe interval"
        case "bFrames": "B-frames"
        case "frameRate": "Frame rate"
        case "bitrate": "Bit rate"
        case "subStream": "Sub stream"
        case "smartCodec": "Smart codec"
        default: checkID
        }
    }

    static func appliedText(_ checkID: String, method: CameraConfigMethod?) -> String {
        guard let method else { return title(checkID) }
        return "\(title(checkID)) (via \(method.displayName))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(result.before.score)% → \(result.after.score)%")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Spacer()
                }
                // One line per fix: what changed and which way the camera accepted it ("via ISAPI").
                ForEach(result.appliedFixes, id: \.self) { fix in
                    Label(Self.appliedText(fix, method: result.fixMethods[fix]), systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Failures list every method that was tried and why it failed.
                ForEach(result.failedFixes, id: \.checkID) { failure in
                    Label("\(Self.title(failure.checkID)): \(failure.reason)", systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if result.mayNeedRecordingReEnabled {
                    Label("You may need to turn HomeKit Secure Video recording off and on again for this camera in the Home app.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                ForEach(result.after.checks, id: \.id) { check in
                    ReadinessCheckRow(check: check)
                }
            }
        }
    }
}
