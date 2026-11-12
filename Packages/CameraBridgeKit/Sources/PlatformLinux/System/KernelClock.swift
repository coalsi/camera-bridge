#if os(Linux)
import CTimex
import Glibc

/// What the kernel says of the system clock, read with `adjtimex` and no mode bits (it changes nothing and needs no privilege). The NVR's age rule
/// waits for a synchronized clock (`ArchivePlatformPolicy.isClockSynchronized`).
public enum KernelClock {
    /// What one reading found.
    public enum Synchronization: Equatable, Sendable {
        case synchronized
        case unsynchronized
        /// The call failed (a sandbox that refuses it answers `EPERM`): nobody can say.
        case unknown(errno: Int32)
    }

    /// The kernel's word now. chrony with `rtcsync` (Camera Bridge OS) clears `STA_UNSYNC` once it is synchronized; the kernel sets it again
    /// when the clock is set and when its error estimate grows past 16 seconds without an update.
    public static func synchronization() -> Synchronization {
        var info = timex()
        let state = adjtimex(&info)
        if state < 0 { return .unknown(errno: errno) }
        return isSynchronized(state: state, status: info.status) ? .synchronized : .unsynchronized
    }

    /// Synchronized: the clock's state is not `TIME_ERROR` and `STA_UNSYNC` is clear.
    static func isSynchronized(state: Int32, status: Int32) -> Bool {
        state != TIME_ERROR && status & STA_UNSYNC == 0
    }
}
#endif
