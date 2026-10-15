import BridgeEngine
import SwiftUI

/// What a picture says when it is not simply showing video ("No recording", "The recordings drive isn't connected", …): a dimming layer and a glass
/// capsule with the words, and the actions that help. After 300 ms of loading, never before (a picture that arrives at once needs no word).
struct NVRStateOverlay: View {
    let state: NVRTileState
    var compact = false
    var tryAgain: (() -> Void)?
    var goLive: (() -> Void)?
    var jump: (() -> Void)?
    @State private var showsLoading = false
    @Environment(\.calendar) private var calendar

    var body: some View {
        if let title = state.title, state != .loading || showsLoading {
            ZStack {
                Color.black.opacity(state == .loading ? 0.25 : 0.5)
                VStack(spacing: compact ? 6 : 10) {
                    Label(title, systemImage: state.symbol)
                        .font(.system(size: compact ? 12 : 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glass(in: Capsule())
                    if let detail = state.detail(timeZone: calendar.timeZone, locale: calendar.locale ?? .current), !compact {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                    }
                    if !compact { actions }
                }
                .padding(12)
            }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
        } else if state == .loading {
            Color.clear.task {
                try? await Task.sleep(for: .milliseconds(300))
                showsLoading = true
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if state == .unreadable, let tryAgain { overlayButton("Try Again", action: tryAgain) }
            if let jump, case .noRecording(_, let next?) = state, next.timeIntervalSinceNow < 0 { overlayButton("Jump to Next Recording", action: jump) }
            if let goLive, state != .loading { overlayButton("Go Live", action: goLive) }
        }
    }

    private func overlayButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(in: Capsule(), interactive: true)
    }
}

/// "REC" on a red dot over a picture (never colour alone): Record is on and recording; amber, with the reason, while it waits or is paused.
struct RecChip: View {
    let state: ArchiveRecordingState
    var compact = false

    var body: some View {
        if state != .off {
            let tint: Color = state == .recording ? Brand.recording : Brand.warning
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text("REC").font(.system(size: compact ? 10 : 11, weight: .bold)).tracking(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .glass(in: Capsule())
            .help(Self.help(state))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.help(state)))
        }
    }

    static func help(_ state: ArchiveRecordingState) -> String {
        switch state {
        case .off: String(localized: "Not recording")
        case .recording: String(localized: "Recording")
        case .waiting(let reason): String(localized: "Record is on: \(reason)")
        case .paused(let pause): String(localized: "Recording is paused: \(pause.readable)")
        }
    }
}

/// The Record switch of one camera: on or off with the camera's REC chip beside it, showing the new value at once while the change is on its way.
struct RecordSwitch: View {
    let model: AppModel
    let cameraID: UUID
    let status: CameraStatus?

    var body: some View {
        let isOn = model.isRecording(cameraID)
        HStack(spacing: 8) {
            if let status { RecChip(state: status.nvr.state) }
            Toggle(isOn: Binding(get: { isOn }, set: { on in Task { await model.setNVRRecording(on, camera: cameraID) } })) {
                Text("Record")
            }
            .toggleStyle(.switch)
            .tint(Brand.recording)
            .disabled(model.isRecordChangePending(cameraID))
            .help(isOn ? "Stop recording this camera" : "Record this camera’s main stream")
        }
    }
}

/// The small round Record button on an Overview tile: a red dot while Record is on (amber, with the reason in its help, while it waits or is paused),
/// an empty circle while it is off. The first time it asks where to store recordings.
struct NVRRecordButton: View {
    let model: AppModel
    let status: CameraStatus
    var size: CGFloat = 30

    var body: some View {
        let isOn = model.isRecording(status.id)
        let state = status.nvr.state
        let tint: Color = state == .recording ? Brand.recording : Brand.warning
        Button {
            Task { await model.setNVRRecording(!isOn, camera: status.id) }
        } label: {
            Image(systemName: isOn ? "circle.fill" : "circle")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(isOn ? tint : .white)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(in: Circle(), interactive: true)
        .disabled(model.isRecordChangePending(status.id))
        .help(isOn ? RecChip.help(state) : String(localized: "Record this camera"))
        .accessibilityLabel(Text("Record"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .accessibilityAddTraits(.isToggle)
    }
}
