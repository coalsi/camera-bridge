import AppKit
import Observation
import SwiftUI
import Sparkle

/// Automatic updates with Sparkle 2 (MIT). Camera Bridge is distributed as a notarized DMG outside the App Store, so it
/// updates itself: Sparkle reads the appcast at `SUFeedURL` (https://www.camera-bridge.app/appcast.xml, Info.plist), checks the
/// EdDSA signature of the download against `SUPublicEDKey` and replaces the app.
///
/// The updater only exists when there is a public key to verify with (`Tools/sparkle-generate-keys.sh` writes it into
/// `project.yml`) and in non-Debug builds; otherwise `isAvailable` is false, Check for Updates… is disabled and `unavailableReason`
/// says why. Sparkle itself is linked from the app target only: the logic-test bundle never sees it.
@MainActor @Observable
final class AppUpdater {
    /// The updater of a build without one (Debug builds, no public key yet, `#Preview`s).
    static let unavailable = AppUpdater(controller: nil, reason: String(localized: "Updates are off in this build."))

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// Whether Check for Updates… can run now (not while a check is under way).
    private(set) var canCheckForUpdates = false
    /// Settings › General › Updates: check in the background about once a day.
    var automaticallyChecksForUpdates: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    /// Why there is no updater, in a sentence (nil when there is one).
    let unavailableReason: String?

    var isAvailable: Bool { controller != nil }

    /// The updater of the running app: live in a Release build that carries a public key.
    convenience init() {
        #if DEBUG
        self.init(controller: nil, reason: String(localized: "Updates are off in Debug builds."))
        #else
        if Self.publicKey == nil {
            self.init(controller: nil, reason: String(localized: "This build has no update signing key, so it cannot update itself."))
        } else {
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            self.init(controller: controller, reason: nil)
        }
        #endif
    }

    private init(controller: SPUStandardUpdaterController?, reason: String?) {
        self.controller = controller
        unavailableReason = reason
        automaticallyChecksForUpdates = controller?.updater.automaticallyChecksForUpdates ?? false
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let can = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
    }

    /// The EdDSA public key in Info.plist, or nil while it is empty (an unsigned local build).
    static var publicKey: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    /// Check for Updates…: Sparkle's own window says what it found. The app is activated first: a menu bar only app is not
    /// frontmost, and Sparkle's window would open behind other apps.
    func checkForUpdates() {
        guard let controller, canCheckForUpdates else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

extension EnvironmentValues {
    /// The app's updater (`AppUpdater.unavailable` in previews).
    @Entry var appUpdater: AppUpdater = .unavailable
}

/// "Check for Updates…" for the app menu.
struct CheckForUpdatesButton: View {
    let updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
