import BridgeEngine
import Darwin
import Foundation
import Synchronization

/// Why a clip file could not be written, in the words the person reads (`ClipExportModel` shows `errorDescription` as it is). `description` says
/// the same, so an engine that wraps the error in its own `ClipError.sink(String)` passes the sentence on too.
nonisolated struct ClipFileError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The drive is full (`ENOSPC`, `EDQUOT`).
        case noRoom
        /// The drive's file system cannot hold a file this big (`EFBIG`: a FAT32 stick stops at 4 GB).
        case tooBigForDrive
        /// The folder is gone, read-only or not ours to write in.
        case cannotWrite
        /// Anything else the system reports (a drive that was pulled answers `EIO`); the number is `errno`.
        case failed(code: Int32)
    }

    var reason: Reason

    /// The error for `errno` value `code`.
    static func forErrno(_ code: Int32) -> ClipFileError {
        switch code {
        case ENOSPC, EDQUOT: ClipFileError(reason: .noRoom)
        case EFBIG: ClipFileError(reason: .tooBigForDrive)
        case EACCES, EPERM, EROFS, ENOENT, ENOTDIR: ClipFileError(reason: .cannotWrite)
        default: ClipFileError(reason: .failed(code: code))
        }
    }

    var errorDescription: String? {
        switch reason {
        case .noRoom: String(localized: "There isn't enough room on the destination drive.")
        case .tooBigForDrive: String(localized: "The destination drive can't hold a file this big. Choose a drive formatted as APFS, Mac OS Extended or exFAT.")
        case .cannotWrite: String(localized: "Camera Bridge can't write to that folder.")
        case .failed(let code):
            String(localized: "The clip couldn't be written to the destination (\(String(cString: strerror(code)))).")
        }
    }

    var description: String { errorDescription ?? "" }
}

/// Writes one clip file the careful way: the bytes go to `<name>.part` next to the final name, and only `finish()` (after an `fsync`) renames it to
/// `<name>`, so a file with the final name is always a whole clip. A failed write, `discard()` and a sink that goes away unfinished remove the
/// partial file. One writer at a time (the engine writes a part from one task); the lock only makes `discard()` safe from anywhere.
nonisolated final class FileClipSink: ClipSink {
    /// The system calls that can fail on a bad drive. Tests replace them to fail the way a full or a vanished drive does (set `errno`, return -1).
    struct Operations: Sendable {
        var write: @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> Int
        var sync: @Sendable (_ descriptor: Int32) -> Int32
        var rename: @Sendable (_ from: String, _ to: String) -> Int32

        static let system = Operations(
            write: { Darwin.write($0, $1.baseAddress, $1.count) },
            sync: { Darwin.fsync($0) },
            rename: { Darwin.rename($0, $1) })
    }

    private struct State {
        var descriptor: Int32?
        var bytesWritten: Int64 = 0
        var isFinished = false
        var isDiscarded = false
    }

    /// The file the clip becomes.
    let destination: URL
    /// Where its bytes are until then: `destination` plus `.part`.
    let partialURL: URL
    private let operations: Operations
    private let state: Mutex<State>

    /// Creates `<destination>.part` (an older one left by a crash is overwritten). Throws `ClipFileError` when the folder cannot take it.
    init(destination: URL, operations: Operations = .system) throws {
        self.destination = destination
        partialURL = destination.appendingPathExtension("part")
        self.operations = operations
        let descriptor = Darwin.open(partialURL.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw ClipFileError.forErrno(errno) }
        state = Mutex(State(descriptor: descriptor))
    }

    deinit {
        discard()
    }

    var bytesWritten: Int64 { state.withLock { $0.bytesWritten } }

    func write(_ bytes: Data) async throws {
        try state.withLock { state in
            guard !state.isFinished, !state.isDiscarded, let descriptor = state.descriptor else { throw CancellationError() }
            var offset = 0
            let failure: Int32? = bytes.withUnsafeBytes { buffer in
                while offset < buffer.count {
                    let count = operations.write(descriptor, UnsafeRawBufferPointer(rebasing: buffer[offset...]))
                    if count < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        return code
                    }
                    if count == 0 { return EIO }
                    offset += count
                }
                return nil
            }
            if let failure {
                Self.remove(&state, partialURL: partialURL)
                throw ClipFileError.forErrno(failure)
            }
            state.bytesWritten += Int64(bytes.count)
        }
    }

    /// Makes the clip real: the bytes reach the drive (`fsync`), the file is closed and `.part` is renamed to the final name (replacing a file of
    /// that name, which the Save panel has already asked about). Returns the final location. Throws `ClipFileError` and removes the partial file
    /// when any of it fails.
    @discardableResult
    func finish() throws -> URL {
        try state.withLock { state in
            if state.isFinished { return destination }
            guard !state.isDiscarded, let descriptor = state.descriptor else { throw CancellationError() }
            if operations.sync(descriptor) != 0 {
                let code = errno
                Self.remove(&state, partialURL: partialURL)
                throw ClipFileError.forErrno(code)
            }
            let closed = Darwin.close(descriptor)
            let closeCode = errno
            state.descriptor = nil
            if closed != 0 {
                Self.remove(&state, partialURL: partialURL)
                throw ClipFileError.forErrno(closeCode)
            }
            if operations.rename(partialURL.path(percentEncoded: false), destination.path(percentEncoded: false)) != 0 {
                let code = errno
                Self.remove(&state, partialURL: partialURL)
                throw ClipFileError.forErrno(code)
            }
            state.isFinished = true
            return destination
        }
    }

    /// Gives the clip up: closes the file and removes `.part`. Safe to call again, and after `finish()` (then it does nothing).
    func discard() {
        state.withLock { Self.remove(&$0, partialURL: partialURL) }
    }

    private static func remove(_ state: inout State, partialURL: URL) {
        guard !state.isFinished, !state.isDiscarded else { return }
        state.isDiscarded = true
        if let descriptor = state.descriptor {
            Darwin.close(descriptor)
            state.descriptor = nil
        }
        unlink(partialURL.path(percentEncoded: false))
    }
}
