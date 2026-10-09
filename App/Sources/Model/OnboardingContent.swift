import BridgeEngine
import Foundation

/// First-run copy: what CameraBridge needs, and how to fix Local Network access.
/// Facts: research brief (integration) — hub models, HKSV iCloud+ tiers, Summarize Videos requirements.
enum OnboardingContent {
    struct Prerequisite: Identifiable, Equatable {
        var id: String
        var symbol: String
        var title: String
        var detail: String
    }

    static let prerequisites: [Prerequisite] = [
        Prerequisite(
            id: "hub", symbol: "homepod.and.appletv",
            title: String(localized: "An Apple home hub"),
            detail: String(localized: "Apple TV 4K (2nd generation or later), HomePod (2nd generation) or HomePod mini, updated to the latest software (tvOS 27 or HomePod Software 27). The hub records and analyzes video.")),
        Prerequisite(
            id: "mac", symbol: "macbook",
            title: String(localized: "This Mac, awake and on your network"),
            detail: String(localized: "Camera Bridge runs on macOS 15 or later and needs to stay running on the same network as your cameras. Turn on Keep Mac Awake in Settings if this Mac sleeps.")),
        Prerequisite(
            id: "icloud", symbol: "icloud",
            title: String(localized: "iCloud+ for recording"),
            detail: String(localized: "HomeKit Secure Video recording needs an iCloud+ plan: 50 GB records 1 camera, 200 GB records up to 5, and 2 TB or more records any number. Live view works without a plan.")),
        Prerequisite(
            id: "summaries", symbol: "sparkles",
            title: String(localized: "Summarize Videos (optional)"),
            detail: String(localized: "Video descriptions need an iPhone with Apple Intelligence and a 2 TB or larger iCloud+ plan (1 camera on 2 TB, 2 on 6 TB, 5 on 12 TB). The setting is off by default; turn it on per camera in the Home app.")),
        Prerequisite(
            id: "addAnyway", symbol: "checkmark.shield",
            title: String(localized: "“Add Anyway” in the Home app"),
            detail: String(localized: "When you scan a camera’s code, the Home app says the accessory isn’t certified. That’s expected for Camera Bridge cameras: tap Add Anyway to continue.")),
    ]

    /// The Local Network section's text: the engine's current answer (`access`, which background checks keep up to
    /// date), else what this sheet's last Check Access found.
    static func localNetworkStatus(_ access: LocalNetworkAccess, lastCheck: LocalNetworkCheckOutcome? = nil) -> String {
        switch (access, lastCheck) {
        case (.granted, _): String(localized: "Local Network access is allowed.")
        case (.denied, _): String(localized: "Local Network access was denied, so Camera Bridge can’t reach your cameras or appear in the Home app.")
        case (.unknown, .checked?):
            String(localized: "Nothing on your network answered, so access couldn’t be confirmed. If macOS asked, make sure you clicked Allow; Camera Bridge checks again when you add a camera.")
        case (.unknown, .noNetwork?):
            String(localized: "Camera Bridge couldn’t find your network, so nothing was checked. Connect this Mac to the network your cameras are on, then click Check Access.")
        case (.unknown, nil):
            String(localized: "Camera Bridge needs Local Network access to reach your cameras. Click Check Access; macOS may ask for permission.")
        }
    }

    /// The welcome guide's button: Get Started on the first run (it completes onboarding), Done when the guide is shown
    /// again later (Settings › Welcome Guide).
    static func dismissTitle(hasCompletedOnboarding: Bool) -> String {
        hasCompletedOnboarding ? String(localized: "Done") : String(localized: "Get Started")
    }

    /// Shown while Check Access waits: the first check raises the system's alert and waits for the answer.
    static let localNetworkChecking = String(localized: "Checking… If macOS asks to let Camera Bridge find devices on your local network, click Allow.")

    static let localNetworkFixSteps: [String] = [
        String(localized: "Open System Settings and choose Privacy & Security."),
        String(localized: "Click Local Network."),
        String(localized: "Turn on Camera Bridge, then click Check Again."),
    ]

    /// Privacy & Security in System Settings (there's no documented link to the Local Network list itself).
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
}
