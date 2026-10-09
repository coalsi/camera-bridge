import SwiftUI

/// One Settings tab: cards on the brand canvas, scrolling when they don't fit.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.canvas)
    }
}

/// A row inside a `SectionCard`: a title with an optional explanation on the left, the control on the right.
struct SettingRow<Trailing: View>: View {
    let title: Text
    let detail: Text?
    @ViewBuilder var trailing: Trailing

    init(title: LocalizedStringKey, detail: LocalizedStringKey? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(title)
        self.detail = detail.map { Text($0) }
        self.trailing = trailing()
    }

    /// For text that isn't a localized key (a camera's name, an address, a port).
    init(verbatimTitle: String, verbatimDetail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(verbatim: verbatimTitle)
        self.detail = verbatimDetail.map { Text(verbatim: $0) }
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(.system(size: 14, weight: .medium))
                if let detail {
                    detail
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

/// A switch row: the title and its explanation on the left, the switch at the trailing edge.
struct SettingToggleRow: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle(isOn: $isOn) { Text(title) }
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Brand.amber)
        }
    }
}

/// The hairline between rows of one card.
struct SettingDivider: View {
    var body: some View {
        Rectangle()
            .fill(Brand.border)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// Small print under a card's rows.
struct SettingNote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A problem inside a card: an amber triangle and a sentence, with an optional action.
struct SettingProblem<Action: View>: View {
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Brand.warning)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action
        }
    }
}

extension SettingProblem where Action == EmptyView {
    init(_ text: String) {
        self.init(text: text) { EmptyView() }
    }
}

/// A port: a number field and Apply, with why a number can't be used. `current` is the saved port; Apply is on while the
/// text is a different, usable port.
struct PortEditor: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    let current: UInt16
    let validate: (String) -> WebhookSettings.PortValidation
    let apply: (UInt16) -> Void
    @State private var text = ""

    var body: some View {
        let validation = validate(text)
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title: title, detail: detail) {
                HStack(spacing: 8) {
                    TextField("Port", text: $text)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 84)
                        .onSubmit { commit(validation) }
                    Button("Apply") { commit(validation) }
                        .buttonStyle(.brand(.secondary))
                        .disabled(!canApply(validation))
                }
            }
            if case .invalid(let reason) = validation {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.warning)
            }
        }
        .onChange(of: current, initial: true) { _, port in text = String(port) }
    }

    private func canApply(_ validation: WebhookSettings.PortValidation) -> Bool {
        if case .valid(let port) = validation { port != current } else { false }
    }

    private func commit(_ validation: WebhookSettings.PortValidation) {
        guard canApply(validation), case .valid(let port) = validation else { return }
        apply(port)
    }
}

/// A banner at the bottom of Settings for `AppModel.notice` (preview mode skipping a change): the manager window shows
/// it too, but Settings may be the only window open.
struct SettingsNotice: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "info.circle")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Brand.card, in: Capsule())
                .overlay { Capsule().strokeBorder(Brand.border, lineWidth: 1) }
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// Monospaced, selectable text in an inset box: a token, a command, an example.
struct SettingCode: View {
    let text: String
    var size: CGFloat = 12.5

    var body: some View {
        Text(text)
            .font(.system(size: size, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Brand.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.border, lineWidth: 1) }
    }
}
