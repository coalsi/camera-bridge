import Foundation

/// Private files for persisted state (HAP `state.json`, the engine's `config.json` and backups): files are 0600 and
/// written atomically and durably (a 0600 temporary file next to the target, synced, then moved into place, and the folder
/// synced); every directory created here is 0700, and an existing directory is left as it is (it may be the caller's, e.g. a
/// shared data directory).
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

    /// Writes `data` to `url` atomically and durably, with mode 0600 (also when it replaces a file with other permissions): a 0600
    /// temporary file next to it is written and synced to the disk, then moved into place, and the folder is synced. A power cut right
    /// after a save leaves the old file or the new one, never an empty one (on ext4 a rename can reach the journal before the data it
    /// names does).
    ///
    /// With `keepingPrevious`, the file `url` held until now is kept as `<name>.bak` first (`previousURL(of:)`), unless it is empty: a
    /// loader whose file cannot be read falls back to it. Keeping it is best effort; the save goes on when it fails.
    public static func write(_ data: Data, to url: URL, keepingPrevious: Bool = false) throws {
        if keepingPrevious, let previous = try? Data(contentsOf: url), !previous.isEmpty {
            try? place(previous, at: previousURL(of: url))
        }
        try place(data, at: url)
    }

    /// `<name>.bak` next to `url`: the version `write(_:to:keepingPrevious:)` replaced last.
    public static func previousURL(of url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).bak", directoryHint: .notDirectory)
    }

    private static func place(_ data: Data, at url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.createFailed(url.lastPathComponent)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()   // the bytes are on the disk before a name points at them
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
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
        synchronizeFolder(directory)
    }

    /// Asks the folder's entries (the new name) to reach the disk; best effort: not every platform syncs a folder.
    private static func synchronizeFolder(_ directory: URL) {
        guard let handle = try? FileHandle(forReadingFrom: directory) else { return }
        try? handle.synchronize()
        try? handle.close()
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
