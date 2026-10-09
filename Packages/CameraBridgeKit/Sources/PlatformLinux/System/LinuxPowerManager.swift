#if os(Linux)
import BridgeSupport
import Foundation

/// `PowerManaging` for Linux: nothing to hold. The box is a small server that never sleeps (no App Nap, no idle suspend), so
/// the activity and keep-awake calls do nothing. `hasBattery` looks for a battery under `/sys/class/power_supply`, so a laptop
/// running the OS image is still recognized.
public final class LinuxPowerManager: PowerManaging {
    private let powerSupplyDirectory: URL

    /// `powerSupplyDirectory` replaces `/sys/class/power_supply` (tests).
    public init(powerSupplyDirectory: URL = URL(filePath: "/sys/class/power_supply", directoryHint: .isDirectory)) {
        self.powerSupplyDirectory = powerSupplyDirectory
    }

    public func beginBackgroundActivity(reason: String) {}
    public func endBackgroundActivity() {}
    public func setKeepSystemAwake(_ awake: Bool, reason: String) {}

    public var hasBattery: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: powerSupplyDirectory.path(percentEncoded: false))) ?? []
        return names.contains { name in
            let type = try? String(contentsOf: powerSupplyDirectory.appending(path: name).appending(path: "type"), encoding: .utf8)
            return type?.trimmingCharacters(in: .whitespacesAndNewlines) == "Battery"
        }
    }
}
#endif
