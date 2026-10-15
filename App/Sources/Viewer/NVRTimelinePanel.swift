import BridgeEngine
import SwiftUI

/// The transport row and the timeline under a picture or a grid: play/pause, the time, Go Live, the five zoom presets and, for one camera, the Record
/// switch; below them the scrubber. The camera page's viewer and the NVR page use the same panel.
struct NVRTimelinePanel<Trailing: View>: View {
    let panel: NVRPanelModel
    @ViewBuilder var trailing: Trailing
    @Environment(\.calendar) private var calendar

    var body: some View {
        let session = panel.session
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LiveIconButton(systemImage: session.clock.isPlaying ? "pause.fill" : "play.fill", label: session.clock.isPlaying ? "Pause" : "Play", size: 34) {
                    session.togglePlay()
                }
                .disabled(!panel.hasRecordings && session.clock.isLive)
                PlayheadReadout(session: session)
                Button {
                    panel.goLive()
                } label: {
                    Label("Go Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glass(in: Capsule(), interactive: true, tint: session.clock.isLive ? nil : Brand.recording.opacity(0.45))
                .disabled(session.clock.isLive)
                .help("Show the camera live (L)")
                if panel.clipExport != nil { SaveClipButton(panel: panel) }
                Spacer(minLength: 12)
                PresetPicker(panel: panel)
                trailing
            }
            ClipBar(panel: panel)
            TimelineScrubber(panel: panel)
            Notes(panel: panel)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(Brand.sidebar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

extension NVRTimelinePanel where Trailing == EmptyView {
    init(panel: NVRPanelModel) {
        self.init(panel: panel) { EmptyView() }
    }
}

/// The time at the playhead: "Live", or the date and time; redrawn four times a second.
private struct PlayheadReadout: View {
    let session: NVRSession
    @Environment(\.calendar) private var calendar

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 150, alignment: .leading)
        }
    }

    private var text: String {
        session.clock.isLive ? String(localized: "Live") : session.position.formatted(date: .abbreviated, time: .standard, in: calendar)
    }
}

/// 10 min, 1 h, 6 h, 24 h and All: labelled buttons, the one in use filled.
private struct PresetPicker: View {
    let panel: NVRPanelModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ZoomPreset.allCases, id: \.self) { preset in
                Button {
                    panel.select(preset)
                } label: {
                    Text(preset.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(panel.preset == preset ? Brand.onAmber : .white)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(panel.preset == preset ? Brand.amber : Color.white.opacity(0.10), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Show \(preset.title)"))
                .accessibilityAddTraits(panel.preset == preset ? .isSelected : [])
            }
        }
    }
}

/// A line under the track: nothing recorded, or a long group of pictures.
private struct Notes: View {
    let panel: NVRPanelModel

    var body: some View {
        if panel.isCoarse, let gop = panel.typicalGOP {
            Label("Keyframes every \(Int(gop.rounded())) s: scrubbing is coarse. A 2 s interval scrubs best.", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

/// Save Clip (C): the clip starts at the playhead; the end is wherever the playhead goes next.
private struct SaveClipButton: View {
    let panel: NVRPanelModel

    var body: some View {
        let reason = panel.saveClipUnavailableReason
        Button {
            panel.beginClip()
        } label: {
            Label("Save Clip", systemImage: "scissors")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(panel.isChoosingClip ? Brand.onAmber : .white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(panel.isChoosingClip ? Brand.amber : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(in: Capsule(), interactive: true)
        .disabled(reason != nil)
        .help(reason ?? (panel.isChoosingClip ? String(localized: "Start the clip here instead (C)") : String(localized: "Start a clip at the playhead (C)")))
    }
}
