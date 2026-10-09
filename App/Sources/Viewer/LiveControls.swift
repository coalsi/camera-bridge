import SwiftUI

/// "LIVE" on a glass capsule over a picture: a red dot and the word (never colour alone).
struct LiveChip: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Brand.recording)
                .frame(width: 7, height: 7)
            Text("LIVE")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glass(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Live"))
    }
}

/// A round glass button for controls laid over a picture (play, pause, mute, expand, snapshot).
struct LiveIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    var size: CGFloat = 36
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(in: Circle(), interactive: true, tint: isProminent ? Brand.amber.opacity(0.55) : nil)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

/// A dimming layer with a glass label over a picture that is not live: offline, connecting, reconnecting, turned off.
struct LiveOverlayView: View {
    let overlay: LiveOverlay
    var compact = false

    var body: some View {
        if let title = overlay.title {
            ZStack {
                Color.black.opacity(0.5)
                Label(title, systemImage: overlay.symbol)
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glass(in: Capsule())
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
        }
    }
}
