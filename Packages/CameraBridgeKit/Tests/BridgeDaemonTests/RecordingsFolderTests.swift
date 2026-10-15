import BridgeEngine
import BridgeWeb
import Foundation
import Testing
import TestSupport
@testable import BridgeDaemon

/// Making the recordings folder, and the location list the web interface offers for it.
@Suite struct RecordingsFolderTests {
    private func mode(of url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.posixPermissions] as? NSNumber)?.intValue
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    // MARK: Making the folder

    @Test func theDefaultFolderInsideTheDataDirectoryIsMadePrivate() throws {
        let data = try TemporaryDirectory(prefix: "cb-recordings")
        defer { data.remove() }
        let recordings = data.url.appending(path: "recordings", directoryHint: .isDirectory)
        #expect(RecordingsFolder.prepare(recordings, dataDirectory: data.url) == nil)
        #expect(mode(of: recordings) == 0o700)
        #expect(RecordingsFolder.prepare(recordings, dataDirectory: data.url) == nil, "again: nothing to do")
    }

    @Test func aFolderThatIsThereIsLeftAsItIs() throws {
        let data = try TemporaryDirectory(prefix: "cb-recordings")
        defer { data.remove() }
        let recordings = data.url.appending(path: "recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o750])
        #expect(RecordingsFolder.prepare(recordings, dataDirectory: data.url) == nil)
        #expect(mode(of: recordings) == 0o750)
    }

    @Test func missingLevelsInsideTheDataDirectoryAreMadeLikeTheDataDirectory() throws {
        let data = try TemporaryDirectory(prefix: "cb-recordings")
        defer { data.remove() }
        let recordings = data.url.appending(path: "media/recordings", directoryHint: .isDirectory)
        #expect(RecordingsFolder.prepare(recordings, dataDirectory: data.url) == nil)
        #expect(mode(of: recordings) == 0o700 && mode(of: recordings.deletingLastPathComponent()) == 0o700)
    }

    @Test func aFolderElsewhereIsMadeOnlyWhenItsParentIsThere() throws {
        let root = try TemporaryDirectory(prefix: "cb-recordings")
        defer { root.remove() }
        let data = root.file("data"), drive = root.file("drive")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: false)
        let recordings = drive.appending(path: "recordings", directoryHint: .isDirectory)
        #expect(RecordingsFolder.prepare(recordings, dataDirectory: data) == nil)
        #expect(mode(of: recordings) == 0o700)
    }

    @Test func aDriveThatIsNotThereIsNotInventedOnTheSystemDisk() throws {
        let root = try TemporaryDirectory(prefix: "cb-recordings")
        defer { root.remove() }
        let data = root.file("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
        let recordings = root.file("not-mounted").appending(path: "recordings", directoryHint: .isDirectory)
        let problem = RecordingsFolder.prepare(recordings, dataDirectory: data)
        #expect(problem != nil)
        #expect(!exists(root.file("not-mounted")), "no parent was created")
        // A path that only looks like it is inside the data directory is judged by where it really is.
        let sneaky = data.appending(path: "../not-mounted-either/recordings", directoryHint: .isDirectory)
        #expect(RecordingsFolder.prepare(sneaky, dataDirectory: data) != nil)
        #expect(!exists(root.file("not-mounted-either")))
    }

    @Test func aFileInTheWayIsReportedAndKept() throws {
        let data = try TemporaryDirectory(prefix: "cb-recordings")
        defer { data.remove() }
        let path = data.file("recordings")
        try Data("not a folder".utf8).write(to: path)
        #expect(RecordingsFolder.prepare(URL(fileURLWithPath: path.path, isDirectory: true), dataDirectory: data.url) != nil)
        #expect(try String(contentsOf: path, encoding: .utf8) == "not a folder")
    }

    @Test func theProblemSentenceNamesNoPath() throws {
        let root = try TemporaryDirectory(prefix: "cb-recordings")
        defer { root.remove() }
        let problem = try #require(RecordingsFolder.prepare(root.file("gone").appending(path: "recordings", directoryHint: .isDirectory), dataDirectory: root.file("data")))
        #expect(!problem.contains(root.url.lastPathComponent) && !problem.contains("/"))
    }

    @Test func aFolderThatDoesNotAnswerDoesNotHoldUpTheStart() async {
        let began = ContinuousClock.now
        let problem = await RecordingsFolder.prepare(URL(fileURLWithPath: "/nowhere", isDirectory: true), dataDirectory: URL(fileURLWithPath: "/data", isDirectory: true),
                                                     within: .milliseconds(300)) {
            Thread.sleep(forTimeInterval: 3)   // a drive that hangs: the call blocks and does not return
            return nil
        }
        let elapsed = ContinuousClock.now - began
        #expect(problem != nil, "the daemon is told the folder did not answer")
        #expect(elapsed < .seconds(2), "prepare gave up after \(elapsed)")
    }

    @Test func aFolderThatAnswersIsPreparedAsUsualWithinTheDeadline() async throws {
        let data = try TemporaryDirectory(prefix: "cb-recordings")
        defer { data.remove() }
        let recordings = data.url.appending(path: "recordings", directoryHint: .isDirectory)
        #expect(await RecordingsFolder.prepare(recordings, dataDirectory: data.url, within: .seconds(5)) == nil)
        #expect(mode(of: recordings) == 0o700)
    }

    // MARK: The location list

    @Test func theLocationListHasTheBuiltInFolderWithACleanPath() {
        #if os(Linux)
        let label = "This box’s storage"
        #else
        let label = "Development folder"
        #endif
        let plain = RecordingsFolder.locations(recordings: URL(fileURLWithPath: "/var/lib/camera-bridge/recordings", isDirectory: true))
        #expect(plain == [ArchiveLocation(id: "builtin", label: label, path: "/var/lib/camera-bridge/recordings")])
        let messy = RecordingsFolder.locations(recordings: URL(fileURLWithPath: "/var/lib/./camera-bridge/x/../recordings/", isDirectory: true))
        #expect(messy.map(\.path) == ["/var/lib/camera-bridge/recordings"], "no dot components and no trailing slash")
    }

    @Test func aPathTheEngineCouldNotStoreIsNotOffered() {
        let long = URL(fileURLWithPath: "/" + String(repeating: "a", count: 1_100), isDirectory: true)
        #expect(RecordingsFolder.locations(recordings: long).isEmpty)
        #expect(BridgeSettings.isValidNVRFolder("/var/lib/camera-bridge/recordings"))
    }
}
