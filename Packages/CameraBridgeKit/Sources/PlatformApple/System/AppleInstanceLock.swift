#if os(macOS)
import BridgeSupport
import Foundation
import Synchronization

/// `InstanceLocking` with an exclusive `flock` on `instance.lock` in the data directory: one copy of CameraBridge per
/// configuration. The kernel drops the lock when the process ends, however it ends, so a crash never leaves a stale one.
/// A copy with its own data directory (a Debug build under another bundle ID has its own container) has its own lock and
/// is not affected.
public final class AppleInstanceLock: InstanceLocking {
    static let fileName = "instance.lock"

    private let descriptor = Mutex<Int32?>(nil)

    public init() {}

    deinit {
        release()
    }

    public func acquire(directory: URL) -> String? {
        descriptor.withLock { descriptor in
            if descriptor != nil { return nil }
            do {
                try PrivateFiles.prepareDirectory(directory)
            } catch {
                return nil   // no lock without a directory: the bridge's own start reports what is wrong with it
            }
            let path = directory.appending(path: Self.fileName, directoryHint: .notDirectory).path(percentEncoded: false)
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return nil }   // cannot lock: do not stop the bridge over it
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let busy = errno == EWOULDBLOCK
                close(fd)
                return busy ? "Camera Bridge is already running with this configuration. Quit the other copy first: two copies would advertise "
                    + "the same cameras to Apple Home and fight over their ports." : nil
            }
            descriptor = fd
            return nil
        }
    }

    public func release() {
        descriptor.withLock { descriptor in
            guard let fd = descriptor else { return }
            flock(fd, LOCK_UN)
            close(fd)
            descriptor = nil
        }
    }
}
#endif
