import Darwin
import Foundation
import Synchronization
import Testing

/// A folder in the system's temporary items, removed with the test. The clip tests write their files in it.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "ClipTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appending(path: name, directoryHint: .notDirectory) }

    /// What the folder holds, by name.
    var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []).sorted()
    }

    func bytes(of name: String) -> Data? { try? Data(contentsOf: file(name)) }
}

/// The system calls a `FileClipSink` made, in order, with the real calls behind them unless a test replaces one.
private nonisolated final class CallLog: Sendable {
    private let entries = Mutex<[String]>([])
    var calls: [String] { entries.withLock { $0 } }
    /// Adds `entry` and returns how many calls there are now.
    @discardableResult
    func add(_ entry: String) -> Int { entries.withLock { $0.append(entry); return $0.count } }
}

@Suite struct FileClipSinkTests {
    private let hello = Data("hello clip".utf8)

    // MARK: The part file and the rename

    @Test func theBytesWaitInAPartFileAndTheClipAppearsOnlyAtFinish() async throws {
        let folder = try TemporaryFolder()
        let sink = try FileClipSink(destination: folder.file("Driveway.mp4"))
        #expect(sink.partialURL.lastPathComponent == "Driveway.mp4.part")
        try await sink.write(hello)
        try await sink.write(hello)
        #expect(folder.names == ["Driveway.mp4.part"], "only the part file while it is written")
        #expect(folder.bytes(of: "Driveway.mp4.part") == hello + hello && sink.bytesWritten == 20)
        let url = try sink.finish()
        #expect(url == folder.file("Driveway.mp4") && sink.destination == url)
        #expect(folder.names == ["Driveway.mp4"], "renamed: no part file is left")
        #expect(folder.bytes(of: "Driveway.mp4") == hello + hello)
    }

    @Test func theBytesReachTheDriveBeforeTheRename() async throws {
        let folder = try TemporaryFolder()
        let log = CallLog()
        var operations = FileClipSink.Operations.system
        let write = operations.write, sync = operations.sync, rename = operations.rename
        operations.write = { log.add("write"); return write($0, $1) }
        operations.sync = { log.add("sync"); return sync($0) }
        operations.rename = { log.add("rename"); return rename($0, $1) }
        let sink = try FileClipSink(destination: folder.file("a.mp4"), operations: operations)
        try await sink.write(hello)
        try sink.finish()
        #expect(log.calls == ["write", "sync", "rename"])
    }

    @Test func finishingTwiceGivesTheSameFileAndDiscardingAfterwardsKeepsIt() async throws {
        let folder = try TemporaryFolder()
        let sink = try FileClipSink(destination: folder.file("a.mp4"))
        try await sink.write(hello)
        let first = try sink.finish()
        #expect(try sink.finish() == first)
        sink.discard()
        #expect(folder.names == ["a.mp4"] && folder.bytes(of: "a.mp4") == hello, "a finished clip is not the sink's to remove")
        await #expect(throws: CancellationError.self) { try await sink.write(hello) }
    }

    @Test func aFileOfTheSameNameIsReplacedAtTheRenameAndAStalePartFileIsOverwritten() async throws {
        let folder = try TemporaryFolder()
        try Data("an older clip the person agreed to replace".utf8).write(to: folder.file("a.mp4"))
        try Data("left behind by a crash, longer than the new clip".utf8).write(to: folder.file("a.mp4.part"))
        let sink = try FileClipSink(destination: folder.file("a.mp4"))
        try await sink.write(Data("new".utf8))
        try sink.finish()
        #expect(folder.names == ["a.mp4"] && folder.bytes(of: "a.mp4") == Data("new".utf8))
    }

    // MARK: Giving up

    @Test func discardingRemovesThePartFileAndWritesStopAfterIt() async throws {
        let folder = try TemporaryFolder()
        let sink = try FileClipSink(destination: folder.file("a.mp4"))
        try await sink.write(hello)
        #expect(folder.names == ["a.mp4.part"])
        sink.discard()
        sink.discard()
        #expect(folder.names.isEmpty)
        await #expect(throws: CancellationError.self) { try await sink.write(hello) }
        #expect(throws: CancellationError.self) { try sink.finish() }
        #expect(folder.names.isEmpty, "nothing came back")
    }

    @Test func aSinkThatIsDroppedUnfinishedTakesItsPartFileWithIt() async throws {
        let folder = try TemporaryFolder()
        do {
            let sink = try FileClipSink(destination: folder.file("a.mp4"))
            try await sink.write(hello)
            #expect(folder.names == ["a.mp4.part"])
        }
        #expect(folder.names.isEmpty, "released without finish(): the partial clip is gone")
    }

    @Test func aSinkThatFinishedKeepsItsClipWhenItIsDropped() async throws {
        let folder = try TemporaryFolder()
        do {
            let sink = try FileClipSink(destination: folder.file("a.mp4"))
            try await sink.write(hello)
            try sink.finish()
        }
        #expect(folder.names == ["a.mp4"])
    }

    // MARK: Failures

    @Test func aFailedWriteRemovesThePartFileAndSaysWhatHappened() async throws {
        let folder = try TemporaryFolder()
        var operations = FileClipSink.Operations.system
        operations.write = { _, _ in errno = EIO; return -1 }   // a drive pulled in the middle of a clip
        let sink = try FileClipSink(destination: folder.file("a.mp4"), operations: operations)
        let error = await #expect(throws: ClipFileError.self) { try await sink.write(hello) }
        #expect(error?.reason == .failed(code: EIO))
        #expect(error?.errorDescription == "The clip couldn't be written to the destination (Input/output error).")
        #expect(folder.names.isEmpty, "the part file is gone as soon as a write fails")
        #expect(sink.bytesWritten == 0)
        await #expect(throws: CancellationError.self) { try await sink.write(hello) }
    }

    @Test func aFullDriveSaysSoInOneSentenceEverywhereTheErrorIsPrinted() async throws {
        let folder = try TemporaryFolder()
        var operations = FileClipSink.Operations.system
        operations.write = { _, _ in errno = ENOSPC; return -1 }
        let sink = try FileClipSink(destination: folder.file("a.mp4"), operations: operations)
        let error = try #require(await #expect(throws: ClipFileError.self) { try await sink.write(hello) })
        let sentence = "There isn't enough room on the destination drive."
        #expect(error.reason == .noRoom && error.errorDescription == sentence && error.localizedDescription == sentence)
        #expect(error.description == sentence && "\(error)" == sentence && String(describing: error) == sentence, "an engine that wraps it as text keeps the sentence")
        #expect(folder.names.isEmpty)
    }

    @Test func theOtherWaysADriveRefusesHaveTheirOwnSentences() {
        #expect(ClipFileError.forErrno(EDQUOT).reason == .noRoom, "a quota is a full drive")
        #expect(ClipFileError.forErrno(EFBIG).errorDescription == "The destination drive can't hold a file this big. Choose a drive formatted as APFS, Mac OS Extended or exFAT.")
        for code in [EACCES, EPERM, EROFS, ENOENT, ENOTDIR] {
            #expect(ClipFileError.forErrno(code).errorDescription == "Camera Bridge can't write to that folder.", "errno \(code)")
        }
        #expect(ClipFileError.forErrno(ETIMEDOUT).errorDescription == "The clip couldn't be written to the destination (Operation timed out).")
    }

    @Test func aShortWriteAndAnInterruptionAreNotFailures() async throws {
        let folder = try TemporaryFolder()
        let log = CallLog()
        var operations = FileClipSink.Operations.system
        let write = operations.write
        operations.write = { descriptor, bytes in
            switch log.add("write") {
            case 1: return write(descriptor, UnsafeRawBufferPointer(rebasing: bytes[..<4]))   // only the first four bytes
            case 2: errno = EINTR; return -1                                                  // interrupted before the next
            default: return write(descriptor, bytes)
            }
        }
        let sink = try FileClipSink(destination: folder.file("a.mp4"), operations: operations)
        try await sink.write(hello)
        try sink.finish()
        #expect(folder.bytes(of: "a.mp4") == hello, "all ten bytes, in order, once")
        #expect(log.calls.count == 3)
    }

    @Test func aWriteThatMakesNoProgressIsAFailureNotALoop() async throws {
        let folder = try TemporaryFolder()
        var operations = FileClipSink.Operations.system
        operations.write = { _, _ in 0 }
        let sink = try FileClipSink(destination: folder.file("a.mp4"), operations: operations)
        let error = await #expect(throws: ClipFileError.self) { try await sink.write(hello) }
        #expect(error?.reason == .failed(code: EIO))
        #expect(folder.names.isEmpty)
    }

    @Test func aFailedSyncRemovesThePartFileAndNothingIsRenamed() async throws {
        let folder = try TemporaryFolder()
        let log = CallLog()
        var operations = FileClipSink.Operations.system
        let rename = operations.rename
        operations.sync = { _ in errno = EIO; return -1 }
        operations.rename = { log.add("rename"); return rename($0, $1) }
        let sink = try FileClipSink(destination: folder.file("a.mp4"), operations: operations)
        try await sink.write(hello)
        let error = #expect(throws: ClipFileError.self) { try sink.finish() }
        #expect(error?.reason == .failed(code: EIO))
        #expect(log.calls.isEmpty && folder.names.isEmpty, "no clip that might be incomplete has the final name")
    }

    @Test func aFailedRenameRemovesThePartFile() async throws {
        let folder = try TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.file("a.mp4"), withIntermediateDirectories: false)   // a folder has the clip's name
        let sink = try FileClipSink(destination: folder.file("a.mp4"))
        try await sink.write(hello)
        let error = #expect(throws: ClipFileError.self) { try sink.finish() }
        #expect(error?.reason == .failed(code: EISDIR))
        #expect(folder.names == ["a.mp4"], "the folder is untouched and the part file is gone")
        #expect((try? folder.file("a.mp4").resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
    }

    @Test func aFolderThatIsNotThereCannotTakeTheClip() throws {
        let folder = try TemporaryFolder()
        let missing = folder.file("gone").appending(path: "a.mp4", directoryHint: .notDirectory)
        let error = #expect(throws: ClipFileError.self) { try FileClipSink(destination: missing) }
        #expect(error?.reason == .cannotWrite && error?.errorDescription == "Camera Bridge can't write to that folder.")
        #expect(folder.names.isEmpty)
    }
}
