import CoreGraphics
import SwiftUI

/// An Apple Home setup QR code for an `X-HM://` setup URI, drawn black on white (in dark mode too) with a four-module
/// quiet zone (part of the image) and nearest-neighbour scaling so the modules stay sharp at any size.
struct QRCodeView: View {
    let uri: String
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))   // corners are quiet zone
            } else {
                Image(systemName: "qrcode")
                    .font(.largeTitle)
                    .foregroundStyle(.black.opacity(0.25))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: uri) { image = QRCodeGenerator.image(for: uri) }
        .accessibilityElement()
        .accessibilityLabel(Text("Apple Home setup code"))
        .accessibilityAddTraits(.isImage)
    }
}

/// A setup code in `XXX-XX-XXX` form, large and selectable.
struct SetupCodeText: View {
    let code: String

    var body: some View {
        Text(StatusText.setupCode(code))
            .font(.system(.title2, design: .monospaced).weight(.semibold))
            .textSelection(.enabled)
            .accessibilityLabel(Text("Setup code \(StatusText.setupCode(code))"))
    }
}

/// Coloured status dot. Always paired with text, so it's hidden from VoiceOver.
struct HealthDot: View {
    let health: Health

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch health {
        case .good: .green
        case .warning: .orange
        case .error: .red
        case .inactive: .gray
        }
    }
}

#Preview("QR code") {
    HStack(spacing: 24) {
        QRCodeView(uri: "X-HM://0081YCYEP3QXO")
            .frame(width: 180)
        VStack(alignment: .leading, spacing: 8) {
            SetupCodeText(code: "48217935")
            HStack { HealthDot(health: .good); Text("Live") }
            HStack { HealthDot(health: .error); Text("Offline") }
        }
    }
    .padding()
}
