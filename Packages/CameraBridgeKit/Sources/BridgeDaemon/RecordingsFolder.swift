import BridgeEngine
import BridgeSupport
import BridgeWeb
import Dispatch
import Foundation

/// The NVR's folder as the daemon handles it: making it, and the location list the web interface offers (`WebConfiguration.archiveLocations`).
/// The engine's recorder never creates the folder or a parent of it (a drive that is not connected must not fill the system disk); this is
/// the one place that makes the root, and only in the cases below.
enum RecordingsFolder {
    /// An absolute path without `.` or `..` components and without a trailing slash: what `BridgeSettings.nvrFolder` holds and the location
    /// list shows. The browser compares nothing; the web routes find the stored folder in the list by this exact string.
    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Whether `child` is `parent` or below it, after standardizing both (a `..` in the path is judged by where it really leads).
    static func isInside(_ child: URL, of parent: URL) -> Bool {
        let child = normalizedPath(child), parent = normalizedPath(parent)
        return child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
    }

    /// Makes the recordings folder when it is missing. Returns nil when the folder is there (or was made), else a short sentence for the log
    /// that names no path. It never throws and never creates more than it should:
    ///
    /// - A folder that exists is left as it is, whatever its mode or owner (a symlink to a drive included).
    /// - Inside the data directory (the default) the missing levels are made 0700, like the data directory itself (`PrivateFiles.prepareDirectory`).
    /// - Anywhere else only the folder itself is made, and only when its parent exists: an unplugged `/mnt/usb` must not be re-invented on the
    ///   system disk, which recordings would then fill.
    static func prepare(_ recordings: URL, dataDirectory: URL) -> String? {
        let manager = FileManager.default
        let path = normalizedPath(recordings)
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? nil : "the recordings path is not a folder"
        }
        do {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            if isInside(folder, of: dataDirectory) {
                try PrivateFiles.prepareDirectory(folder)
            } else {
                var parentIsDirectory: ObjCBool = false
                guard manager.fileExists(atPath: normalizedPath(folder.deletingLastPathComponent()), isDirectory: &parentIsDirectory),
                      parentIsDirectory.boolValue else {
                    return "the folder that should hold the recordings is missing (a drive that is not connected?), so nothing was created"
                }
                try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            return "the recordings folder could not be created (error \((error as NSError).code))"
        }
        return nil
    }

    /// `prepare`, but it never waits longer than `deadline`: a folder on a drive that does not answer must not hold up the start (the daemon
    /// says `READY=1` only after `start()`, and the unit gives it 120 s). The disk calls run on a Dispatch queue, not on the cooperative pool,
    /// and a blocked one is left to finish on its own. `work` is `prepare` unless a test replaces it.
    static func prepare(_ recordings: URL, dataDirectory: URL, within deadline: Duration, work: (@Sendable () -> String?)? = nil) async -> String? {
        let work = work ?? { prepare(recordings, dataDirectory: dataDirectory) }
        do {
            return try await withDeadline(deadline, followsCancellation: false) {
                await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
                }
            }
        } catch {
            return "the folder did not answer in time, so recording waits for it"
        }
    }

    /// The places the web interface offers for recordings: the one built-in folder. Empty when its path is not one the engine could store.
    /// The box calls it "This box’s storage"; the Mac development daemon "Development folder".
    static func locations(recordings: URL) -> [ArchiveLocation] {
        let path = normalizedPath(recordings)
        guard BridgeSettings.isValidNVRFolder(path) else { return [] }
        #if os(Linux)
        let label = "This box’s storage"
        #else
        let label = "Development folder"
        #endif
        return [ArchiveLocation(id: "builtin", label: label, path: path)]
    }
}
