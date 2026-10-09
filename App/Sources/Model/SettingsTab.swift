import SwiftUI

/// The Settings window's tabs, in toolbar order. The last one used is remembered (`storageKey`, an `@AppStorage`).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, homeKit, network, webhook, privacy, diagnostics, backup, about

    static let storageKey = "settingsTab"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .homeKit: "HomeKit"
        case .network: "Network"
        case .webhook: "Webhook"
        case .privacy: "Privacy"
        case .diagnostics: "Diagnostics"
        case .backup: "Backup"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .homeKit: "house"
        case .network: "network"
        case .webhook: "link"
        case .privacy: "hand.raised"
        case .diagnostics: "stethoscope"
        case .backup: "externaldrive"
        case .about: "info.circle"
        }
    }
}
