import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// Camera folder names, the manifest, and the file names inside the date folders (Mac spec 4.1, T00 B.7).
@Suite struct ArchiveCameraDirectoryTests {
    func directory(_ naming: ArchivePlatformPolicy.DirectoryNaming, id: UUID = UUID(), name: String = "Driveway") -> ArchiveCameraDirectory {
        ArchiveCameraDirectory(naming: naming, cameraID: id, cameraName: name, fileSystem: DiskFileSystem())
    }

    // MARK: Sanitizer

    @Test func theSanitizerKeepsOrdinaryNamesAndFixesTheRest() {
        let cases: [(String, String)] = [
            ("Driveway", "Driveway"), ("Front Door (2)", "Front Door (2)"), ("Garten Süd", "Garten Süd"), ("カメラ１", "カメラ１"),
            ("..", "Camera"), (".", "Camera"), ("", "Camera"), ("   ", "Camera"), ("...", "Camera"),
            ("a/b", "a-b"), ("a\\b", "a-b"), ("a:b", "a-b"), ("/", "-"), ("a/../b", "a-..-b"),
            (".hidden", "hidden"), ("..hidden", "hidden"), ("name. ", "name"), ("name...", "name"), ("  padded  ", "padded"),
            ("a\u{0}b", "a-b"), ("a\nb", "a-b"), ("a\tb", "a-b"), ("a\u{7F}b", "a-b"), ("\u{1}x", "-x"),
        ]
        for (input, expected) in cases { #expect(ArchiveCameraDirectory.sanitize(input) == expected, "\(input.debugDescription)") }
    }

    @Test func theSanitizerCutsAtSixtyUnicodeScalars() {
        let sixty = String(repeating: "é", count: 60), sixtyOne = String(repeating: "é", count: 61)
        #expect(ArchiveCameraDirectory.sanitize(sixty) == sixty)
        #expect(ArchiveCameraDirectory.sanitize(sixtyOne) == sixty)
        let japanese = String(repeating: "日", count: 100)
        #expect(ArchiveCameraDirectory.sanitize(japanese).unicodeScalars.count == 60)
        // A cut that leaves a trailing dot or space is trimmed again.
        let edge = String(repeating: "a", count: 59) + ". tail"
        #expect(ArchiveCameraDirectory.sanitize(edge) == String(repeating: "a", count: 59))
        // An emoji sequence is never made longer than 60 scalars (it may be cut inside; the result is still a valid name).
        let family = String(repeating: "👨‍👩‍👧", count: 20)                       // 5 scalars each
        let cut = ArchiveCameraDirectory.sanitize(family)
        #expect(cut.unicodeScalars.count == 60 && !cut.isEmpty)
    }

    // MARK: Camera directories

    @Test func aNewCameraGetsItsSanitizedNameAndAManifest() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let id = UUID()
        let name = try directory(.cameraName, id: id, name: "Front/Door").resolve(root: root.url)
        #expect(name == "Front-Door" && root.contents() == ["Front-Door"])
        let manifest = try Data(contentsOf: root.url.appending(path: "Front-Door/camera.json"))
        #expect(String(decoding: manifest, as: UTF8.self) == #"{"id":"\#(id.uuidString)","name":"Front\/Door"}"#)
        #expect(try posixPermissions(of: root.url.appending(path: "Front-Door")) == 0o700)
        #expect(try posixPermissions(of: root.url.appending(path: "Front-Door/camera.json")) == 0o600)
    }

    @Test func aRenamedCameraKeepsItsDirectoryAndAnotherCameraWithTheSameNameGetsANumber() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let first = UUID(), second = UUID(), third = UUID()
        #expect(try directory(.cameraName, id: first, name: "Garage").resolve(root: root.url) == "Garage")
        #expect(try directory(.cameraName, id: first, name: "Garage").resolve(root: root.url) == "Garage", "the same camera again")
        #expect(try directory(.cameraName, id: second, name: "Garage").resolve(root: root.url) == "Garage (2)", "same name, another camera")
        #expect(try directory(.cameraName, id: third, name: "Garage").resolve(root: root.url) == "Garage (3)")
        // The first camera is renamed: its directory stays, and its manifest follows.
        #expect(try directory(.cameraName, id: first, name: "Workshop").resolve(root: root.url) == "Garage")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.url.appending(path: "Garage/camera.json"))) as? [String: String]
        #expect(manifest?["name"] == "Workshop" && manifest?["id"] == first.uuidString)
        // The old name is now free for the second camera? No: it keeps "Garage (2)" and the folder named "Garage" belongs to the first.
        #expect(try directory(.cameraName, id: second, name: "Garage").resolve(root: root.url) == "Garage (2)")
        #expect(root.contents() == ["Garage", "Garage (2)", "Garage (3)"])
    }

    @Test func aFolderThatIsNotOursIsNeverUsedUnlessItIsEmpty() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        try FileManager.default.createDirectory(at: root.url.appending(path: "Porch"), withIntermediateDirectories: false)
        try Data("hello".utf8).write(to: root.url.appending(path: "Porch/notes.txt"))
        try FileManager.default.createDirectory(at: root.url.appending(path: "Porch (2)"), withIntermediateDirectories: false)
        let id = UUID()
        #expect(try directory(.cameraName, id: id, name: "Porch").resolve(root: root.url) == "Porch (2)", "an empty folder is adopted, a folder with other files is skipped")
        #expect(FileManager.default.fileExists(atPath: root.url.appending(path: "Porch (2)/camera.json").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: root.url.appending(path: "Porch/camera.json").path(percentEncoded: false)))
        // A file named like the camera is not a folder either.
        #expect(FileManager.default.createFile(atPath: root.url.appending(path: "Yard").path(percentEncoded: false), contents: Data("x".utf8)))
        #expect(try directory(.cameraName, id: UUID(), name: "Yard").resolve(root: root.url) == "Yard (2)")
    }

    @Test func theBoxNamesTheDirectoryAfterTheCameraID() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let id = UUID()
        #expect(try directory(.cameraID, id: id, name: "Kitchen").resolve(root: root.url) == id.uuidString)
        #expect(id.uuidString == id.uuidString.uppercased())
        #expect(try directory(.cameraID, id: id, name: "Pantry").resolve(root: root.url) == id.uuidString, "a rename changes the manifest only")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.url.appending(path: "\(id.uuidString)/camera.json"))) as? [String: String]
        #expect(manifest == ["id": id.uuidString, "name": "Pantry"])
        #expect(root.contents() == [id.uuidString])
    }

    @Test func theRecordingsFolderIsNeverCreated() throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let missing = parent.url.appending(path: "Volumes/Recordings")
        for naming in [ArchivePlatformPolicy.DirectoryNaming.cameraID, .cameraName] {
            #expect(throws: RecorderFailure.folderMissing) { _ = try directory(naming).resolve(root: missing) }
            #expect(throws: RecorderFailure.folderMissing) { _ = try directory(naming).resolve(root: parent.url.appending(path: "not-here")) }
        }
        #expect(parent.contents().isEmpty, "nothing was created, not even a parent")
        let file = parent.url.appending(path: "a-file")
        try Data().write(to: file)
        #expect(throws: RecorderFailure.folderMissing) { _ = try directory(.cameraID).resolve(root: file) }
    }

    // MARK: Files

    @Test func dateAndFileNamesAreLocalTime() throws {
        let instant = Date(timeIntervalSince1970: 1_791_590_405)                  // 2026-10-10 00:00:05 UTC
        let utc = TimeZone(identifier: "UTC")!, losAngeles = TimeZone(identifier: "America/Los_Angeles")!, auckland = TimeZone(identifier: "Pacific/Auckland")!
        #expect(ArchiveCameraDirectory.dateDirectoryName(instant, timeZone: utc) == "2026-10-10")
        #expect(ArchiveCameraDirectory.fileBaseName(instant, timeZone: utc) == "00-00-05")
        #expect(ArchiveCameraDirectory.dateDirectoryName(instant, timeZone: losAngeles) == "2026-10-09")
        #expect(ArchiveCameraDirectory.fileBaseName(instant, timeZone: losAngeles) == "17-00-05")
        #expect(ArchiveCameraDirectory.dateDirectoryName(instant, timeZone: auckland) == "2026-10-10")
        #expect(ArchiveCameraDirectory.fileBaseName(instant, timeZone: auckland) == "13-00-05")
        for name in ["00-00-05", "17-00-05"] { #expect(ArchiveLayout.isOwnFileBaseName(name)) }
    }

    @Test func aFileNeverReplacesAnotherAndTheSecondInOneSecondGetsASuffix() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let camera = directory(.cameraID)
        let name = try camera.resolve(root: root.url)
        let anchor = Date(timeIntervalSince1970: 1_791_590_405)
        let utc = TimeZone(identifier: "UTC")!
        let first = try camera.createFile(root: root.url, directory: name, anchor: anchor, timeZone: utc)
        try first.handle.write(Data("first".utf8))
        let second = try camera.createFile(root: root.url, directory: name, anchor: anchor, timeZone: utc)
        let third = try camera.createFile(root: root.url, directory: name, anchor: anchor, timeZone: utc)
        #expect(first.segment == "\(name)/2026-10-10/00-00-05" && second.segment.hasSuffix("/00-00-05-2") && third.segment.hasSuffix("/00-00-05-3"))
        for segment in [first.segment, second.segment, third.segment] { #expect(ArchiveLayout.parseSegment(segment) != nil) }
        #expect(try Data(contentsOf: first.mp4) == Data("first".utf8), "the first file was not touched")
        // An orphaned sidecar blocks its name too: a new mp4 must not meet a stale index.
        try Data("stale".utf8).write(to: root.url.appending(path: "\(name)/2026-10-10/00-00-06.cbidx"))
        let later = try camera.createFile(root: root.url, directory: name, anchor: anchor.addingTimeInterval(1), timeZone: utc)
        #expect(later.segment.hasSuffix("/00-00-06-2"))
        try [first, second, third, later].forEach { try $0.handle.close() }
        #expect(try posixPermissions(of: first.mp4) == 0o600)
    }

    @Test func aDayThatRepeatsAnHourGetsTheSuffixToo() throws {
        // 2026-11-01 01:30 happens twice in Los Angeles (PDT, then PST): the same local name an hour apart.
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let camera = directory(.cameraID)
        let name = try camera.resolve(root: root.url)
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let firstPass = Date(timeIntervalSince1970: 1_793_521_800)                // 2026-11-01 08:30 UTC = 01:30 PDT
        let secondPass = firstPass.addingTimeInterval(3_600)                      // 09:30 UTC = 01:30 PST
        #expect(ArchiveCameraDirectory.fileBaseName(firstPass, timeZone: zone) == ArchiveCameraDirectory.fileBaseName(secondPass, timeZone: zone))
        let a = try camera.createFile(root: root.url, directory: name, anchor: firstPass, timeZone: zone)
        let b = try camera.createFile(root: root.url, directory: name, anchor: secondPass, timeZone: zone)
        #expect(a.segment.hasSuffix("/01-30-00") && b.segment.hasSuffix("/01-30-00-2"))
        try a.handle.close()
        try b.handle.close()
    }
}
