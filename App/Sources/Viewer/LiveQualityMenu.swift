import BridgeEngine
import SwiftUI

extension LiveQuality {
    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .main: "High Quality (Main Stream)"
        case .sub: "Low Bandwidth (Sub Stream)"
        }
    }

    var shortTitle: LocalizedStringKey {
        switch self {
        case .automatic: "Auto"
        case .main: "High"
        case .sub: "Low"
        }
    }
}

/// The small quality menu on a live picture: which of the camera's streams it reads (a glass capsule with the choice and
/// a chevron).
struct LiveQualityMenu: View {
    @Binding var quality: LiveQuality

    var body: some View {
        Menu {
            Picker("Stream", selection: $quality) {
                ForEach(LiveQuality.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "dial.medium")
                Text(quality.shortTitle)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glass(in: Capsule(), interactive: true)
        .fixedSize()
        .help("Choose which stream to watch")
        .accessibilityLabel(Text("Stream Quality"))
    }
}
