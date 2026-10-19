import AppKit
import BridgeEngine
import BridgeSupport
import SwiftUI

/// Diagnostics: every subsystem's log across all cameras (debug level, redacted), filters for level, camera and subsystem,
/// a search, and Export Diagnostics… — the text file the owner sends when something does not work.
struct DiagnosticsView: View {
    let model: AppModel
    @State private var visible: [LogEntry] = []
    @State private var matches = 0

    private var diagnostics: DiagnosticsModel { model.diagnostics }
    private var cameraNames: [UUID: String] {
        Dictionary(model.engine.configurations.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        @Bindable var diagnostics = model.diagnostics
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.motionShadowTest { MotionShadowSection(cameras: model.engine.cameras) }
            filters(diagnostics: diagnostics)
            logList
            footer
        }
        .padding(20)
        .navigationTitle("Diagnostics")
        .task {
            while !Task.isCancelled {
                model.diagnostics.refresh()
                recompute()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: model.diagnostics.filter) { recompute() }
        .onChange(of: model.engine.configurations) { recompute() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Diagnostics").font(.title2.weight(.semibold))
                Text("Everything Camera Bridge logged, from every camera and part of the app. Passwords, tokens and setup codes are never in it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Export Diagnostics…") { model.exportDiagnostics() }
                .buttonStyle(.brand(.primary))
                .help("Save the log, each camera’s status and its recent live view sessions as a text file to send")
        }
    }

    private func filters(diagnostics: DiagnosticsModel) -> some View {
        @Bindable var diagnostics = diagnostics
        return HStack(spacing: 8) {
            Picker("Level", selection: $diagnostics.filter.minimumLevel) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(LogFilter.levelName(level)).tag(level)
                }
            }
            .fixedSize()
            Picker("Camera", selection: $diagnostics.filter.camera) {
                Text("All Cameras").tag(DiagnosticsCameraScope.all)
                Text("App and Engine").tag(DiagnosticsCameraScope.engine)
                ForEach(model.engine.configurations) { camera in
                    Text(camera.name).tag(DiagnosticsCameraScope.camera(camera.id))
                }
            }
            .fixedSize()
            Picker("Subsystem", selection: $diagnostics.filter.subsystem) {
                Text("All Subsystems").tag(String?.none)
                ForEach(diagnostics.subsystems, id: \.self) { subsystem in
                    Text(subsystem).tag(String?.some(subsystem))
                }
            }
            .fixedSize()
            TextField("Search", text: $diagnostics.filter.searchText, prompt: Text("Search"))
                .textFieldStyle(.roundedBorder)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(LogFilter.plainText(visible, cameraNames: cameraNames), forType: .string)
            }
            .disabled(visible.isEmpty)
            .help("Copy the entries shown")
        }
    }

    private var logList: some View {
        ScrollView {
            if visible.isEmpty {
                Text("No log entries match")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(visible) { entry in
                        DiagnosticsRow(entry: entry, camera: LogFilter.cameraName(of: entry, in: cameraNames))
                    }
                }
                .padding(8)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5))
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Text(matches > visible.count ? "Showing the newest \(visible.count) of \(matches) entries" : "\(matches) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let failure = model.diagnostics.exportFailure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            } else if let url = model.diagnostics.lastExport {
                Button("Saved — Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func recompute() {
        visible = model.diagnostics.visibleEntries(cameraNames: cameraNames)
        matches = visible.count < DiagnosticsModel.displayLimit ? visible.count : model.diagnostics.matchCount(cameraNames: cameraNames)
    }
}

/// The motion shadow test's results: what built-in motion detection and each camera's own events saw, per camera.
private struct MotionShadowSection: View {
    let cameras: [CameraStatus]
    @State private var span = MotionShadowTable.Span.last24Hours

    private var rows: [MotionShadowTable.Row] { MotionShadowTable.rows(cameras, span: span) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Built-in Motion Detection vs. Camera Events (Test)").font(.headline)
                Spacer()
                Picker("Span", selection: $span) {
                    ForEach(MotionShadowTable.Span.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if rows.isEmpty {
                Text("No camera is being compared yet. The test covers cameras that report motion themselves.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        Text("Camera").gridColumnAlignment(.leading)
                        Text("Both")
                        Text("Camera Only")
                        Text("Built-in Only")
                        Text("Median Delay")
                        Text("Sensitivity")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.name).gridColumnAlignment(.leading).lineLimit(1)
                            if let reason = row.pauseReason {
                                Text(reason)
                                    .foregroundStyle(.secondary)
                                    .gridCellColumns(4)
                                    .gridColumnAlignment(.leading)
                            } else {
                                Text(row.both, format: .number).monospacedDigit()
                                Text(row.cameraOnly, format: .number).monospacedDigit()
                                Text(row.builtInOnly, format: .number).monospacedDigit()
                                Text(row.medianDelay).monospacedDigit()
                            }
                            Text(row.sensitivity).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                Text("“Both”: the camera and built-in detection saw the motion. “Camera only”: built-in detection missed it. “Built-in only”: an extra trigger. The delay is how much later (or earlier) built-in detection noticed it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5))
        }
    }
}

private struct DiagnosticsRow: View {
    let entry: LogEntry
    let camera: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(LogFilter.levelName(entry.level))
                .fontWeight(.semibold)
                .foregroundStyle(levelStyle)
                .frame(width: 56, alignment: .leading)
            Text(entry.category)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
                .lineLimit(1)
            Group {
                if let camera {
                    Text("\(Text(camera).fontWeight(.semibold)): \(entry.message)")
                } else {
                    Text(entry.message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }

    private var levelStyle: Color {
        switch entry.level {
        case .debug: .secondary
        case .info: .primary
        case .notice: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

#Preview {
    DiagnosticsView(model: .preview())
        .frame(width: 900, height: 560)
}
