import AppKit
import BridgeEngine
import SwiftUI

/// The bar between the transport row and the timeline while a clip is being chosen or saved: the range and its size, what to know about it, which
/// cameras, and Cancel and Export Clip; then the progress of the save and, at the end, where the files went.
struct ClipBar: View {
    let panel: NVRPanelModel
    @Environment(\.calendar) private var calendar

    var body: some View {
        if let export = panel.clipExport {
            Group {
                switch export.state {
                case .idle:
                    if panel.isChoosingClip { choosing(export) }
                case .planning:
                    working(label: String(localized: "Choose where to save the clip."), progress: nil, export: export)
                case .exporting(let progress, let label):
                    working(label: label, progress: progress, export: export)
                case .finished(let urls, let notes):
                    finished(urls: urls, notes: notes, export: export)
                case .failed(let sentence):
                    failed(sentence, export: export)
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Choosing

    private func choosing(_ export: ClipExportModel) -> some View {
        let selection = panel.clipSelection
        let preview = panel.clipPreview
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "scissors").foregroundStyle(Brand.accent)
                if let selection {
                    Text(range(selection, preview: preview))
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                    Text(Self.duration(selection.duration))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    if let preview, preview.byteCount > 0 {
                        Text(RecordingSettings.bytes(UInt64(preview.byteCount)))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if panel.clipAvailable.count > 1 { cameraChoice }
                Button("Cancel") { panel.cancelClip() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .help("Stop choosing a clip (Esc)")
                Button { Task { await panel.exportClip() } } label: {
                    Text("Export Clip")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.onRed)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(Brand.red.opacity(canExport ? 1 : 0.4), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canExport)
                .help("Save the clip (Return)")
            }
            Text(hint(selection: selection, preview: preview))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(preview?.notes ?? [], id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Brand.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.accent.opacity(0.45), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Clip"))
    }

    private var canExport: Bool {
        guard let selection = panel.clipSelection, selection.isExportable, let preview = panel.clipPreview else { return false }
        return preview.byteCount > 0
    }

    private func hint(selection: ClipSelection?, preview: ClipPreview?) -> String {
        if let selection, !selection.isExportable { return ClipSentences.underOneSecond }
        guard preview != nil else { return String(localized: "Move the playhead to where the clip should end, then choose Export Clip.") }
        return String(localized: "Move the playhead to change where the clip ends, then choose Export Clip.")
    }

    /// "Oct 12, 2026, 2:02:10 PM to 2:05:42 PM": where the first picture really is, to where the clip ends.
    private func range(_ selection: ClipSelection, preview: ClipPreview?) -> String {
        var shown = selection
        if let preview, preview.byteCount > 0 { shown.start = min(preview.actualStart, selection.range.lowerBound); shown.end = selection.range.upperBound }
        return shown.summary(calendar: calendar)
    }

    private var cameraChoice: some View {
        let chosen = panel.clipCameras.count, total = panel.clipAvailable.count
        return HStack(spacing: 8) {
            Text("\(chosen) of \(total) cameras").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            Button(chosen == total ? "All cameras" : "Select all") { panel.setAllClipCameras() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(chosen == total ? Brand.onRed : .white)
                .padding(.horizontal, 10).frame(height: 28)
                .background(chosen == total ? Brand.red : Color.white.opacity(0.12), in: Capsule())
                .help("Include every camera. Click a picture to include or leave it out.")
        }
    }

    // MARK: Saving and the result

    private func working(label: String, progress: Double?, export: ClipExportModel) -> some View {
        HStack(spacing: 12) {
            if let progress { ProgressView(value: progress).frame(maxWidth: 260) } else { ProgressView().controlSize(.small) }
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 8)
            Button("Cancel") { export.cancel() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .barBackground()
    }

    private func finished(urls: [URL], notes: [String], export: ClipExportModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent)
                Text(urls.count == 1 ? String(localized: "Saved the clip") : String(localized: "Saved \(urls.count) clips"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 8)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.onRed)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Brand.red, in: Capsule())
                Button("Done") { export.dismissResult() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .barBackground()
    }

    private func failed(_ sentence: String, export: ClipExportModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t Save the Clip").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(sentence).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("OK") { export.dismissResult() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 28)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .barBackground()
    }

    /// "1:05" or "1:02:03".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3_600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

private extension View {
    func barBackground() -> some View {
        padding(10)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The part of the track between the clip's start and the playhead, with a flag where it starts.
struct ClipBand: View {
    let panel: NVRPanelModel
    let width: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(panel.session.clock.isPlaying || panel.session.clock.isLive))) { _ in
            if let start = panel.clipStart {
                let from = panel.timeline.viewport.x(for: start, width: width)
                let to = panel.playheadX()
                let (left, right) = (min(max(min(from, to), 0), width), min(max(max(from, to), 0), width))
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Brand.accent.opacity(0.22)).frame(width: max(0, right - left), height: TimelineScrubber.trackHeight)
                        .offset(x: left)
                    if from >= 0, from <= width {
                        Rectangle().fill(Brand.accent).frame(width: 2, height: TimelineScrubber.trackHeight).offset(x: from - 1)
                        Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(Brand.accent).offset(x: from + 2, y: 2)
                    }
                }
                .frame(width: width, height: TimelineScrubber.trackHeight, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .allowsHitTesting(false)
            }
        }
    }
}
