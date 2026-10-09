import AppKit
import BridgeEngine
import CameraAdapters
import MediaCore
import SwiftUI

/// Streams tab: the "CameraBridge Timestamp". Draws the Mac's clock (NTP-synced) on live view and HomeKit Secure Video
/// recordings, so every camera shows the same time whatever its own clock says. The preview below the switch is drawn by
/// the very renderer the video encoder uses on the camera's current picture, so it is what the video will carry.
struct TimestampOverlaySection: View {
    let model: AppModel
    let cameraID: UUID
    /// The engine's configuration: `hiddenCameraClock` lives there, not in the draft.
    let configuration: CameraConfiguration
    @Binding var draft: CameraConfiguration

    @State private var changingClock = false
    /// What the last request to hide or show the camera's own clock said (until the camera page is left).
    @State private var clockResult: ClockResult?

    private struct ClockResult: Equatable {
        var text: String
        var isProblem: Bool
    }

    var body: some View {
        Section {
            Toggle(isOn: $draft.timestampOverlay.enabled) {
                Text("Show Camera Bridge Timestamp")
                Text("Draws the Mac’s clock on live view and recordings, so every camera shows the same time. Uses the Mac’s video encoder; a little more CPU.")
            }
            if configuration.hasCameraInterface {
                Toggle(isOn: hidesCameraClock) {
                    Text("Hide the Camera’s Own Clock")
                    clockStatus
                }
                .disabled(changingClock)
            }
            if draft.timestampOverlay.enabled {
                TimestampPreviewRow(cameraID: cameraID, settings: draft.timestampOverlay, cameraName: draft.name)
                LabeledContent("Position") {
                    OverlayPositionPicker(selection: $draft.timestampOverlay.position)
                }
                Picker("Size", selection: $draft.timestampOverlay.size) {
                    ForEach(OverlaySize.allCases, id: \.self) { size in
                        Text(Self.title(size)).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Show Date", isOn: $draft.timestampOverlay.showDate)
                Toggle("Show Seconds", isOn: $draft.timestampOverlay.showSeconds)
                Toggle("24-Hour Time", isOn: $draft.timestampOverlay.use24Hour)
                Toggle("Show Camera Name", isOn: $draft.timestampOverlay.showCameraName)
            }
        } header: {
            Text("Camera Bridge Timestamp")
        } footer: {
            Text("The timestamp is drawn at the size the Home app asks for, in the Mac’s language and region. Snapshots in the Home app’s grid stay as the camera sends them.")
        }
    }

    // MARK: The camera's own clock

    private var hidesCameraClock: Binding<Bool> {
        Binding(get: { configuration.hiddenCameraClock != nil }, set: { hide in changeClock(hide: hide) })
    }

    @ViewBuilder private var clockStatus: some View {
        if changingClock {
            Text("Changing the camera’s settings…")
        } else if let clockResult {
            Text(clockResult.text)
                .foregroundStyle(clockResult.isProblem ? Brand.warning : Color.secondary)
        } else if let hidden = configuration.hiddenCameraClock {
            Text(TimestampOverlayModel.hiddenDescription(hidden))
        } else {
            Text(TimestampOverlayModel.hideExplanation)
        }
    }

    private func changeClock(hide: Bool) {
        guard !changingClock else { return }
        changingClock = true
        clockResult = nil
        Task {
            let change = await model.setCameraClockHidden(cameraID: cameraID, hidden: hide)
            changingClock = false
            guard let change else { return }
            clockResult = ClockResult(text: TimestampOverlayModel.describe(change, hiding: hide), isProblem: !change.succeeded)
        }
    }

    static func title(_ size: OverlaySize) -> String {
        switch size {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        }
    }

    static func title(_ position: OverlayPosition) -> String {
        switch position {
        case .topLeft: String(localized: "Top Left")
        case .topRight: String(localized: "Top Right")
        case .bottomLeft: String(localized: "Bottom Left")
        case .bottomRight: String(localized: "Bottom Right")
        }
    }
}

/// Which corner the timestamp sits in: a small screen with a pill in each corner, the chosen one amber.
struct OverlayPositionPicker: View {
    @Binding var selection: OverlayPosition

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.canvas)
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.border, lineWidth: 1)
            VStack {
                HStack {
                    corner(.topLeft)
                    Spacer(minLength: 0)
                    corner(.topRight)
                }
                Spacer(minLength: 0)
                HStack {
                    corner(.bottomLeft)
                    Spacer(minLength: 0)
                    corner(.bottomRight)
                }
            }
            .padding(7)
        }
        .frame(width: 148, height: 84)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Position"))
    }

    private func corner(_ position: OverlayPosition) -> some View {
        let isSelected = selection == position
        return Button {
            selection = position
        } label: {
            Capsule()
                .fill(isSelected ? Brand.amber : Brand.control)
                .frame(width: 42, height: 16)
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .help(TimestampOverlaySection.title(position))
        .accessibilityLabel(Text(TimestampOverlaySection.title(position)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The camera's current picture with the timestamp on it, redrawn when a setting changes, a new snapshot arrives and
/// every second (the time moves).
private struct TimestampPreviewRow: View {
    let cameraID: UUID
    let settings: TimestampOverlaySettings
    let cameraName: String
    @State private var rendered: NSImage?

    /// What a drawn preview depends on, apart from the time.
    private struct Key: Equatable {
        var settings: TimestampOverlaySettings
        var cameraName: String
        var snapshotTime: Date?
    }

    var body: some View {
        let store = SnapshotStore.shared
        let key = Key(settings: settings, cameraName: cameraName, snapshotTime: store.updatedAt[cameraID])
        let snapshot = store.image(for: cameraID)
        ZStack {
            Brand.canvas
            if let rendered {
                Image(nsImage: rendered)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 280)
                    .accessibilityLabel(Text("Preview of the timestamp on the camera’s picture"))
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the camera’s picture…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 40)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.border, lineWidth: 1) }
        .task(id: key) { await keepDrawn(snapshot: snapshot, key: key) }
    }

    /// Draws now and again at each whole second, until the view goes away or something it depends on changes.
    private func keepDrawn(snapshot: NSImage?, key: Key) async {
        guard let picture = snapshot?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            rendered = nil
            return
        }
        while !Task.isCancelled {
            let now = Date.now
            let drawn = await Task.detached(priority: .userInitiated) {
                TimestampOverlayModel.preview(snapshot: picture, settings: key.settings, cameraName: key.cameraName, at: now)
            }.value
            guard !Task.isCancelled else { return }
            rendered = drawn.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            try? await Task.sleep(for: .seconds(TimestampOverlayModel.secondsUntilNextSecond(from: .now)))
        }
    }
}
