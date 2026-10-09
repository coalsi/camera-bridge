import Foundation

/// Private files for persisted state (HAP `state.json`, the engine's `config.json` and backups): files are 0600 and
/// written atomically (a 0600 temporary file next to the target, then moved into place); every directory created here
/// is 0700, and an existing directory is left as it is (it may be the caller's, e.g. a shared data directory).
public enum PrivateFiles {
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// The temporary file next to the target could not be created (missing directory, permissions, disk full).
        case createFailed(String)

        public var description: String {
            switch self {
            case .createFailed(let name): "could not create \(name)"
            }
        }
    }

    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Creates `directory` and its missing parents, each with mode 0700. An existing directory is never changed.
    public static func prepareDirectory(_ directory: URL) throws {
        var missing: [URL] = []
        var candidate = directory.standardizedFileURL
        while !exists(candidate) {
            missing.append(candidate)
            let parent = candidate.deletingLastPathComponent()
            guard parent.path(percentEncoded: false) != candidate.path(percentEncoded: false) else { break }
            candidate = parent
        }
        guard !missing.isEmpty else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Explicitly, in case the attributes were not applied to every created level (or the umask interfered).
        for created in missing { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: created.path(percentEncoded: false)) }
    }

    /// Writes `data` to `url` atomically with mode 0600 (also when it replaces a file with other permissions).
    public static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path(percentEncoded: false), contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.createFailed(url.lastPathComponent)
        }
        do {
            if exists(url) {
                _ = try manager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: url)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    /// A name in `directory` built by `name(n)` that does not exist yet (n = 0, 1, 2, …).
    public static func unusedURL(in directory: URL, _ name: (Int) -> String) -> URL {
        var attempt = 0
        while true {
            let candidate = directory.appending(path: name(attempt), directoryHint: .notDirectory)
            if !exists(candidate) { return candidate }
            attempt += 1
        }
    }
}
