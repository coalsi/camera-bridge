import BridgeSupport
import Foundation
import Synchronization

/// Checks that a folder can hold recordings: it is a directory, a probe file can be created and deleted in it, and its volume has at least the
/// floor free that recording pauses at there (the host policy's, else the Mac's rule), so a folder the recorder would pause on at once is refused
/// with a sentence instead of being accepted. It runs on a single-flight probe queue that is not the store's control queue, and throws
/// `ArchiveFolderError` (readable sentences).
public enum ArchiveFolderCheck {
    /// `policy` supplies the space numbers and the floor (nil: Foundation's volume attributes and the Mac's rule, the startup volume being the
    /// volume of `dataDirectory`, else of the home folder).
    public static func inspect(_ url: URL, policy: ArchivePlatformPolicy? = nil, dataDirectory: URL? = nil) async throws -> ArchiveFolderReport {
        try await inspect(url, policy: policy, dataDirectory: dataDirectory, queue: .shared, deadline: .seconds(8))
    }

    /// The same on `queue`, giving up with `.notAnswering` after `deadline` (the probe thread may stay blocked in a hung drive; nothing else
    /// queues behind it: a probe whose caller gave up before it started is skipped).
    static func inspect(_ url: URL, policy: ArchivePlatformPolicy?, dataDirectory: URL?, queue: ArchiveProbeQueue, deadline: Duration) async throws -> ArchiveFolderReport {
        guard url.isFileURL, BridgeSettings.isValidNVRFolder(ArchiveVolume.path(of: url)) else { throw ArchiveFolderError.invalidPath }
        let startup = dataDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        do {
            return try await queue.run(deadline: deadline) { try check(url, policy: policy, startup: startup) }
        } catch is DeadlineExceeded {
            throw ArchiveFolderError.notAnswering
        }
    }

    /// Blocking: on the probe queue only.
    private static func check(_ url: URL, policy: ArchivePlatformPolicy?, startup: URL) throws -> ArchiveFolderReport {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ArchiveVolume.path(of: url), isDirectory: &isDirectory) else { throw ArchiveFolderError.notFound }
        guard isDirectory.boolValue else { throw ArchiveFolderError.notAFolder }
        guard ArchiveVolume.writeProblem(in: url) == nil else { throw ArchiveFolderError.cannotWrite }
        guard let space = ArchiveVolume.space(of: url, policy: policy) else { throw ArchiveFolderError.notAnswering }
        let floor = max(ArchiveConstants.minimumFolderFreeBytes, ArchiveVolume.floor(for: url, total: space.total, policy: policy, dataDirectory: startup))
        guard space.free >= floor else { throw ArchiveFolderError.belowFloor(freeBytes: space.free, floorBytes: floor) }
        return ArchiveFolderReport(freeBytes: space.free, totalBytes: space.total, floorBytes: floor)
    }
}

/// A flag a caller sets when it stops waiting for queued work.
private final class AbandonedFlag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

/// One serial queue for the calls that can hang on a bad drive (stat, free space, a probe file): at most one thread is ever blocked, whatever the
/// callers do, and work whose caller has given up is skipped instead of piling up behind a hung call. Never the store's control queue: a hung
/// probe must not stop file rollover or retention for the drive's other users.
final class ArchiveProbeQueue: Sendable {
    static let shared = ArchiveProbeQueue()

    private let queue = DispatchQueue(label: "CameraBridge.NVR.probe", qos: .utility)

    init() {}

    /// Runs `work` and waits for it as long as it takes.
    func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Runs `work` unless `deadline` passes first, then throws `DeadlineExceeded` (and skips `work` if it has not started).
    func run<Value: Sendable>(deadline: Duration, _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let abandoned = AbandonedFlag()
        do {
            return try await withDeadline(deadline) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                    self.queue.async {
                        if abandoned.isSet {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(with: Result { try work() })
                        }
                    }
                }
            }
        } catch let error as DeadlineExceeded {
            abandoned.set()
            throw error
        }
    }
}

/// What the archive asks a volume (blocking calls: on the probe queue only).
enum ArchiveVolume {
    /// The folder's path without a trailing slash.
    static func path(of url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Total and free bytes of the volume `url` is on: the host policy's, else Foundation's volume attributes. Free is the space "for important
    /// usage" where Foundation has it (APFS counts purgeable space, which the system gives back when it is needed, and Finder shows that number),
    /// else the plain available capacity.
    static func space(of url: URL, policy: ArchivePlatformPolicy?) -> (total: UInt64, free: UInt64)? {
        if let policy { return policy.space(url) }
        #if os(macOS)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        #else
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]   // Foundation on Linux has no "important usage" number
        #endif
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity, total > 0 else { return nil }
        #if os(macOS)
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        #else
        let important: Int64 = 0
        #endif
        let free = max(important, Int64(values.volumeAvailableCapacity ?? 0))
        guard free >= 0 else { return nil }
        return (UInt64(total), UInt64(free))
    }

    /// The free space below which recording pauses on the volume `url` is on: the policy's, else the Mac's rule (the volume of the data
    /// directory is the startup volume).
    static func floor(for url: URL, total: UInt64, policy: ArchivePlatformPolicy?, dataDirectory: URL) -> UInt64 {
        if let policy { return policy.floorBytes(for: url, total: total) }
        return sameVolume(url, dataDirectory) ? ArchivePlatformPolicy.macStartupFloor(total: total) : ArchiveConstants.otherVolumeFloorBytes
    }

    /// Whether both URLs are on one volume: by the file system number (`st_dev`) where Foundation reports it, else by the volume's URL.
    static func sameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        if let left = volumeNumber(lhs), let right = volumeNumber(rhs) { return left == right }
        guard let left = (try? lhs.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              let right = (try? rhs.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return false }
        return left.standardizedFileURL.path(percentEncoded: false) == right.standardizedFileURL.path(percentEncoded: false)
    }

    private static func volumeNumber(_ url: URL) -> UInt64? {
        ((try? FileManager.default.attributesOfFileSystem(forPath: path(of: url)))?[.systemNumber] as? NSNumber)?.uint64Value
    }

    /// Creates and deletes a small file in `folder`; the sentence for the person when that fails, else nil.
    static func writeProblem(in folder: URL) -> String? {
        let probe = folder.appending(path: ".camerabridge-probe-\(UUID().uuidString)", directoryHint: .notDirectory)
        let path = probe.path(percentEncoded: false)
        guard FileManager.default.createFile(atPath: path, contents: Data("probe".utf8), attributes: [.posixPermissions: 0o600]) else {
            return ArchiveFolderError.cannotWrite.errorDescription
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            return ArchiveFolderError.cannotWrite.errorDescription
        }
        return nil
    }
}
