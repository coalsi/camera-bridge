import BridgeEngine
import Foundation

/// Launch arguments (they arrive through the `UserDefaults` argument domain, e.g. `-previewEngine YES`).
struct LaunchOptions: Equatable {
    static let previewEngineKey = "previewEngine"
    static let openManagerKey = "openManager"
    static let showOnboardingKey = "showOnboarding"
    static let openSettingsKey = "openSettings"
    static let demoScenarioKey = "demoScenario"

    /// `-previewEngine YES`: run the UI on `BridgeEngine.preview()` sample data with no networking and no system changes.
    var usesPreviewEngine = false
    /// `-openManager YES`: open the manager window at launch (screenshots, UI review).
    var opensManagerAtLaunch = false
    /// `-showOnboarding YES`: present onboarding even when it was completed before.
    var showsOnboarding = false
    /// `-openSettings YES`: open the Settings window at launch (screenshots, UI review; `-settingsTab network` picks the tab).
    var opensSettingsAtLaunch = false
    /// `-demoScenario empty|network-denied|damaged-config|webhook-error|errors|fleet|vpn|vpn-failed|mac-vpn` (with `-previewEngine YES`): which sample bridge
    /// the preview engine shows, for screenshots of states a healthy bridge never has. Default: five healthy-to-struggling cameras.
    var previewScenario: PreviewScenario = .standard

    init(usesPreviewEngine: Bool = false, opensManagerAtLaunch: Bool = false, showsOnboarding: Bool = false, opensSettingsAtLaunch: Bool = false) {
        self.usesPreviewEngine = usesPreviewEngine
        self.opensManagerAtLaunch = opensManagerAtLaunch
        self.showsOnboarding = showsOnboarding
        self.opensSettingsAtLaunch = opensSettingsAtLaunch
    }

    init(defaults: UserDefaults) {
        usesPreviewEngine = defaults.bool(forKey: Self.previewEngineKey)
        opensManagerAtLaunch = defaults.bool(forKey: Self.openManagerKey)
        showsOnboarding = defaults.bool(forKey: Self.showOnboardingKey)
        opensSettingsAtLaunch = defaults.bool(forKey: Self.openSettingsKey)
        previewScenario = defaults.string(forKey: Self.demoScenarioKey).flatMap(PreviewScenario.init(rawValue:)) ?? .standard
    }
}
