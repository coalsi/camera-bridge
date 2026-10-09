#if os(macOS)
import BridgeSupport
import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import Synchronization

/// `PowerManaging` for macOS: a `ProcessInfo` activity (`.userInitiatedAllowingIdleSystemSleep`: no App Nap, no
/// automatic termination, idle sleep still allowed) and an optional `PreventUserIdleSystemSleep` IOPM assertion.
/// Both are held at most once and released on deinit.
public final class ApplePowerManager: PowerManaging {
    private struct State {
        var activity: (any NSObjectProtocol)?
        var assertion: IOPMAssertionID?
    }

    private let state = Mutex(State())
    private let log = Log(category: "power")

    public init() {}

    deinit {
        endBackgroundActivity()
        setKeepSystemAwake(false, reason: "")
    }

    /// Idempotent: a second call keeps the first activity (and its reason).
    public func beginBackgroundActivity(reason: String) {
        state.withLock { state in
            guard state.activity == nil else { return }
            state.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: reason)
        }
    }

    public func endBackgroundActivity() {
        state.withLock { state in
            guard let activity = state.activity else { return }
            ProcessInfo.processInfo.endActivity(activity)
            state.activity = nil
        }
    }

    /// Idempotent: while awake, further `true` calls keep the existing assertion (and its reason).
    public func setKeepSystemAwake(_ awake: Bool, reason: String) {
        let failure: IOReturn? = state.withLock { state in
            if awake {
                guard state.assertion == nil else { return nil }
                var id: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                         IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
                guard result == kIOReturnSuccess else { return result }
                state.assertion = id
            } else if let id = state.assertion {
                IOPMAssertionRelease(id)
                state.assertion = nil
            }
            return nil
        }
        if let failure { log.warning("Could not prevent idle sleep (IOReturn \(failure))") }
    }

    /// An internal battery is one of the Mac's power sources (a laptop). A desktop has none (a UPS is not an internal battery).
    public var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    public var isBackgroundActivityActive: Bool { state.withLock { $0.activity != nil } }
    public var isKeepingSystemAwake: Bool { state.withLock { $0.assertion != nil } }
}
#endif
