import BridgeSupport
import Foundation

/// The disk operations a recorder needs, behind one seam so tests can make the disk fail or hang (the real one is `DiskFileSystem`). Only the
/// throwing `FileHandle` calls are used: the legacy ones trap on a failed write. Nothing here creates a parent directory, and `createFile` never
/// replaces an existing file.
protocol RecorderFileSystem: Sendable {
    func directoryExists(_ url: URL) -> Bool
    func itemExists(_ url: URL) -> Bool
    /// The names in `directory`, sorted.
    func names(in directory: URL) throws -> [String]
    /// One directory level (mode 0700); its parent must exist.
    func createDirectory(_ url: URL) throws
    /// A new file (mode 0600) opened for writing; throws when the name is taken.
    func createFile(_ url: URL) throws -> any RecorderFileHandle
    /// The file's bytes when it exists and has at most `limit` bytes, else nil.
    func read(_ url: URL, limit: Int) -> Data?
    /// Atomic, mode 0600 (`PrivateFiles.write`).
    func write(_ data: Data, to url: URL) throws
    func remove(_ url: URL) throws
}

protocol RecorderFileHandle: Sendable {
    func write(_ data: Data) throws
    func synchronize() throws
    func truncate(atOffset offset: UInt64) throws
    func close() throws
}

struct DiskFileSystem: RecorderFileSystem {
    /// The path without a trailing slash: a URL made with `directoryHint: .isDirectory` ends in one, and `stat` on "file/" fails with ENOTDIR.
    private func path(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path(url), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func itemExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path(url))) != nil
    }

    func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path(directory)).sorted()
    }

    func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(atPath: path(url), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            if directoryExists(url) { return }                  // someone else made it first (the old and the new recorder of a camera overlap)
            throw error
        }
    }

    func createFile(_ url: URL) throws -> any RecorderFileHandle {
        guard !itemExists(url) else { throw CocoaError(.fileWriteFileExists) }
        guard FileManager.default.createFile(atPath: path(url), contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        return DiskFileHandle(handle: try FileHandle(forWritingTo: url))
    }

    func read(_ url: URL, limit: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path(url)),
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= limit else { return nil }
        return try? Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try PrivateFiles.write(data, to: url)
    }

    func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// A `FileHandle` used from one serial queue only.
private final class DiskFileHandle: RecorderFileHandle, @unchecked Sendable {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func synchronize() throws { try handle.synchronize() }
    func truncate(atOffset offset: UInt64) throws { try handle.truncate(atOffset: offset) }
    func close() throws { try handle.close() }
}
