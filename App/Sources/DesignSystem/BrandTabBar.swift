import SwiftUI

/// Segmented tab strip: a capsule track with a solid amber thumb behind the selected item (black text on it). Each item is
/// a real button: keyboard focusable, with the selected trait for VoiceOver.
struct BrandTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> LocalizedStringKey
    let symbol: (Tab) -> String
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    let selected = tab == selection
                    Button {
                        if reduceMotion { selection = tab } else { withAnimation(.snappy(duration: 0.22)) { selection = tab } }
                    } label: {
                        Label(title(tab), systemImage: symbol(tab))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(selected ? Brand.onAmber : Color(hex: 0xE4E4E8))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background {
                                if selected {
                                    Capsule().fill(Brand.amber).matchedGeometryEffect(id: "thumb", in: thumb)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(4)
        }
        .scrollIndicators(.hidden)
        .background { Capsule().fill(Brand.card) }
        .overlay { Capsule().strokeBorder(Brand.border, lineWidth: 1) }
        .clipShape(Capsule())
        .fixedSize(horizontal: false, vertical: true)
    }
}
