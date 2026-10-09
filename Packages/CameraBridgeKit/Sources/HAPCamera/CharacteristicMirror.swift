import Foundation
import HAP

extension Characteristic {
    /// Stores the value `current()` computes, again until it no longer changes: concurrent callers that computed their
    /// value from older state cannot leave a stale value behind (each re-checks after storing). `current` is evaluated
    /// outside any characteristic lock, so observers never run inside the caller's locks.
    func mirror(_ current: () -> HAPValue) {
        var value = current()
        for _ in 0..<8 {
            update(value)
            let latest = current()
            if latest == value { return }
            value = latest
        }
        update(value)
    }
}
