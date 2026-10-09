import BridgeSupport
import Foundation
import Synchronization

/// The engine's power policy (plan W3-1 item 7, spec §7) over `PlatformServices.power`: a background activity while
/// the bridge runs (no App Nap; idle sleep still allowed; ended on pause and stop), and the "Keep Mac Awake" assertion while the bridge runs with
/// `BridgeSettings.keepMacAwake` on. The app's toggle reaches it through `BridgeEngine.updateSettings`. Calls go to the
/// platform only when the wanted state changes.
final class PowerController: Sendable {
    static let activityReason = "Camera Bridge is bridging cameras to Apple Home"
    static let keepAwakeReason = "Camera Bridge Keep Mac Awake"

    private let power: any PowerManaging
    /// The keep-awake state last sent to the platform (nil before the first call).
    private let keepingAwake = Mutex<Bool?>(nil)

    init(power: any PowerManaging) {
        self.power = power
    }

    /// The bridge started: background activity, keep-awake as configured.
    func bridgeStarted(keepAwake: Bool) {
        power.beginBackgroundActivity(reason: Self.activityReason)
        setKeepAwake(keepAwake)
    }

    /// The bridge stopped or paused: nothing keeps the Mac awake any more, and the app may nap.
    func bridgeStopped() {
        power.endBackgroundActivity()
        guard keepingAwake.withLock({ $0 }) == true else { return }
        setKeepAwake(false)
    }

    func setKeepAwake(_ awake: Bool) {
        let changed = keepingAwake.withLock { current -> Bool in
            guard current != awake else { return false }
            current = awake
            return true
        }
        guard changed else { return }
        power.setKeepSystemAwake(awake, reason: Self.keepAwakeReason)
        Log(category: "Engine").info(awake ? "Keeping the Mac awake" : "No longer keeping the Mac awake")
    }
}
