import BridgeEngine
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The `ArchivePlatformPolicy` of the daemon: what the NVR needs to know about the machine and Foundation cannot tell portably. It is built
/// here because Glibc and Darwin may be imported only in this module (`PortabilityTests`); the engine receives it as
/// `BridgeEnvironment.archivePolicy` and never calls statvfs itself.
///
/// - `space`: statvfs on the folder, or on its nearest existing parent while the folder is not made yet. `free` is `f_bavail` (what a
///   non-root writer may use), `total` is `f_blocks`, both in `f_frsize` units.
/// - `isSystemVolume`: the folder is on the same device (`st_dev`) as the data directory. On the box that is the data partition, which also holds
///   the settings, the HomeKit keys, the journal and the update staging area, so it keeps `linuxSystemFloor` free. What cannot be measured counts
///   as the system volume, because its floor is the higher and so the safe one.
/// - `directoryNaming`: `.cameraID`. Camera folders are named by UUID and `camera.json` carries the name.
/// - `isSameVolume`: both folders have the same `st_dev` (the archive drive must not be on the recordings drive); what cannot be measured counts as the
///   same, the safe answer.
/// - `lowerThreadPriority`: the archive mover's thread at the lowest priority (`lowerThisThread`).
enum DaemonArchivePolicy {
    /// `deviceOf` and `spaceOf` are the two things that touch the machine; tests replace them.
    static func make(dataDirectory: URL,
                     deviceOf: @escaping @Sendable (URL) -> UInt64? = { DaemonArchivePolicy.deviceNumber(of: $0) },
                     spaceOf: @escaping @Sendable (URL) -> (total: UInt64, free: UInt64)? = { DaemonArchivePolicy.volumeSpace(of: $0) }) -> ArchivePlatformPolicy {
        let dataDevice = deviceOf(dataDirectory)
        var policy = ArchivePlatformPolicy(
            space: spaceOf,
            isSystemVolume: { url in
                guard let dataDevice, let device = deviceOf(url) else { return true }
                return device == dataDevice
            },
            systemFloor: { ArchivePlatformPolicy.linuxSystemFloor(total: $0) },
            directoryNaming: .cameraID)
        policy.isSameVolume = { lhs, rhs in
            guard let left = deviceOf(lhs), let right = deviceOf(rhs) else { return true }
            return left == right
        }
        policy.lowerThreadPriority = { DaemonArchivePolicy.lowerThisThread() }
        return policy
    }

    /// The calling thread at the least CPU and disk priority: `nice` 19 (on Linux the nice value is per thread: `setpriority` with id 0 is the
    /// calling thread) and the idle I/O class (`ioprio_set`, which glibc does not wrap and Swift cannot call through `syscall`, so util-linux's
    /// `ionice -c 3 -p <thread id>` sets it, for this thread alone). Best effort: where either fails the thread still runs, at background quality of
    /// service (and at `nice` 19 the kernel already gives it the lowest best-effort disk priority).
    static func lowerThisThread() {
        #if os(Linux)
        _ = setpriority(__priority_which_t(PRIO_PROCESS.rawValue), 0, 19)
        guard let thread = currentThreadID(), let ionice = ["/usr/bin/ionice", "/bin/ionice"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ionice)
        process.arguments = ["-c", "3", "-p", String(thread)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
        #endif
    }

    /// The kernel's id of the calling thread, from `/proc/thread-self` (a link to `<pid>/task/<tid>`); nil where there is none.
    static func currentThreadID() -> Int? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/thread-self") else { return nil }
        return threadID(fromThreadSelf: target)
    }

    /// "1234/task/1240" → 1240.
    static func threadID(fromThreadSelf target: String) -> Int? {
        let parts = target.split(separator: "/")
        guard parts.count == 3, parts[1] == "task", let thread = Int(parts[2]), thread > 0 else { return nil }
        return thread
    }

    /// Total and free bytes from statvfs numbers. nil when they cannot be right: no fragment size, no blocks, or a product that overflows.
    /// Free never exceeds total.
    static func space(blocks: UInt64, available: UInt64, fragmentSize: UInt64) -> (total: UInt64, free: UInt64)? {
        guard fragmentSize > 0, blocks > 0 else { return nil }
        let (total, totalOverflow) = blocks.multipliedReportingOverflow(by: fragmentSize)
        let (free, freeOverflow) = available.multipliedReportingOverflow(by: fragmentSize)
        guard !totalOverflow, !freeOverflow else { return nil }
        return (total, min(free, total))
    }

    /// statvfs of `url`, or of its nearest existing parent. nil when the call fails.
    static func volumeSpace(of url: URL) -> (total: UInt64, free: UInt64)? {
        var info = statvfs()
        guard statvfs(nearestExistingAncestor(of: url).path(percentEncoded: false), &info) == 0 else { return nil }
        let fragment = info.f_frsize != 0 ? UInt64(info.f_frsize) : UInt64(info.f_bsize)
        return space(blocks: UInt64(info.f_blocks), available: UInt64(info.f_bavail), fragmentSize: fragment)
    }

    /// `st_dev` of `url`, or of its nearest existing parent. nil when the call fails.
    static func deviceNumber(of url: URL) -> UInt64? {
        var info = stat()
        guard stat(nearestExistingAncestor(of: url).path(percentEncoded: false), &info) == 0 else { return nil }
        return UInt64(truncatingIfNeeded: info.st_dev)
    }

    /// `url` if it exists, else the closest parent that does (at most as many steps as the path has components; "/" always exists).
    static func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url.standardizedFileURL
        let manager = FileManager.default
        while !manager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == candidate.path(percentEncoded: false) { break }
            candidate = parent
        }
        return candidate
    }
}
