import SwiftUI

/// Liquid Glass where the system has it (macOS 26 and later), a translucent material before that, so the app runs on macOS 15.
extension View {
    /// `glassEffect(.regular, in:)`, or `glassEffect(.regular.interactive(), in:)` with `interactive`; `tint` colours the glass.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            switch (interactive, tint) {
            case (false, nil): glassEffect(.regular, in: shape)
            case (true, nil): glassEffect(.regular.interactive(), in: shape)
            case (false, let tint?): glassEffect(.regular.tint(tint), in: shape)
            case (true, let tint?): glassEffect(.regular.tint(tint).interactive(), in: shape)
            }
        } else {
            background(.regularMaterial, in: shape)
                .overlay { shape.stroke(.white.opacity(0.12), lineWidth: 0.5) }
                .background { if let tint { shape.fill(tint.opacity(0.5)) } }
        }
    }

    /// `buttonStyle(.glass)`, or a bordered button before macOS 26.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }
}
