import AppKit
import BridgeEngine
import BridgeSupport
import SwiftUI

/// Recent engine log entries (newest first) with level and text filters. Messages are already redacted at the source.
struct LogView: View {
    let entries: [LogEntry]
    /// Only this camera's entries; nil = everything.
    var cameraID: UUID?
    /// Names of the configured cameras: with every camera's entries shown (`cameraID` nil), each names its camera.
    var cameraNames: [UUID: String] = [:]
    @State private var filter = LogFilter()
    @State private var visible: [LogEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Level", selection: $filter.minimumLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(LogFilter.levelName(level)).tag(level)
                    }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Filter", text: $filter.searchText, prompt: Text("Filter"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(LogFilter.plainText(visible, cameraNames: shownCameraNames), forType: .string)
                }
                .disabled(visible.isEmpty)
                .help("Copy the entries shown")
            }

            ScrollView {
                if visible.isEmpty {
                    Text("No log entries")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(visible) { entry in
                            LogRow(entry: entry, camera: LogFilter.cameraName(of: entry, in: shownCameraNames))
                        }
                    }
                    .padding(8)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            }
        }
        .onChange(of: entries, initial: true) { recompute() }
        .onChange(of: filter) { recompute() }
        .onChange(of: cameraNames) { recompute() }
    }

    /// A camera's own page needs no names: every entry is that camera's.
    private var shownCameraNames: [UUID: String] { cameraID == nil ? cameraNames : [:] }

    private func recompute() {
        var scoped = filter
        scoped.cameraID = cameraID
        visible = scoped.apply(to: entries, cameraNames: shownCameraNames)
    }
}

private struct LogRow: View {
    let entry: LogEntry
    /// The camera the entry belongs to (Settings' log), else nil.
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
                .frame(width: 72, alignment: .leading)
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
    LogView(entries: BridgeEngine.preview().recentLogs)
        .padding()
        .frame(width: 720, height: 360)
}
