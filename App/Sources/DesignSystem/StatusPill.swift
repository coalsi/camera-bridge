import BridgeEngine
import SwiftUI

/// What a camera is doing, in one word: the pill in the sidebar and the camera hero.
enum CameraPillState: Equatable, Hashable {
    case live, recording, motion, connecting, offline, idle, disabled

    init(_ status: CameraStatus) {
        switch status.connection {
        case .online: self = status.recordingNow ? .recording : (status.motionActive ? .motion : .live)
        case .connecting: self = .connecting
        case .offline: self = .offline
        case .idle: self = .idle
        case .disabled: self = .disabled
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .live: "Live"
        case .recording: "Recording"
        case .motion: "Motion"
        case .connecting: "Connecting"
        case .offline: "Offline"
        case .idle: "Idle"
        case .disabled: "Disabled"
        }
    }

    var plainTitle: String {
        switch self {
        case .live: String(localized: "Live")
        case .recording: String(localized: "Recording")
        case .motion: String(localized: "Motion")
        case .connecting: String(localized: "Connecting")
        case .offline: String(localized: "Offline")
        case .idle: String(localized: "Idle")
        case .disabled: String(localized: "Disabled")
        }
    }

    var symbol: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .recording: "record.circle.fill"
        case .motion: "figure.walk.motion"
        case .connecting: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .idle, .disabled: "pause.circle"
        }
    }

    var tint: Color {
        switch self {
        case .live: Brand.live
        case .recording: Brand.recording
        case .motion, .connecting: Brand.warning
        case .offline: Brand.recording
        case .idle, .disabled: Brand.neutral
        }
    }
}

/// A glyph and a word on one line, a little closer together than the system's label.
private struct PillLabelStyle: LabelStyle {
    let spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

/// Colored capsule with a glyph and a word, always on one line. `onImage` puts it on a snapshot (dark glass, white
/// text); `compact` trims the padding for narrow places (the sidebar, next to a viewer pill).
struct StatusPill: View {
    let state: CameraPillState
    var onImage = false
    var compact = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .labelStyle(PillLabelStyle(spacing: compact ? 3 : 5))
            .font(.system(size: compact ? 11 : 11.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(onImage ? .white : state.tint)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, 4)
            .background {
                if onImage {
                    Capsule().fill(reduceTransparency ? AnyShapeStyle(Color.black.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial))
                    Capsule().fill(state.tint.opacity(0.35))
                } else {
                    Capsule().fill(state.tint.opacity(0.16))
                }
            }
            .overlay { Capsule().strokeBorder(state.tint.opacity(onImage ? 0.8 : 0.35), lineWidth: 1) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(state.plainTitle))
    }
}

/// How many people are watching a camera live right now: an eye and a count, styled like `StatusPill`.
struct ViewerPill: View {
    let count: Int
    var compact = false

    var body: some View {
        Label("\(count)", systemImage: "eye.fill")
            .labelStyle(PillLabelStyle(spacing: compact ? 3 : 5))
            .font(.system(size: compact ? 11 : 11.5, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Brand.amber)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, 4)
            .background { Capsule().fill(Brand.amber.opacity(0.16)) }
            .overlay { Capsule().strokeBorder(Brand.amber.opacity(0.35), lineWidth: 1) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(count == 1 ? String(localized: "1 viewer") : String(localized: "\(count) viewers")))
    }
}

#Preview("Status pills") {
    VStack(alignment: .leading, spacing: 10) {
        ForEach([CameraPillState.live, .recording, .motion, .connecting, .offline, .disabled], id: \.self) { StatusPill(state: $0) }
        HStack(spacing: 6) { StatusPill(state: .live); ViewerPill(count: 2) }
    }
    .padding(30)
    .background(BrandCanvas())
    .preferredColorScheme(.dark)
}
