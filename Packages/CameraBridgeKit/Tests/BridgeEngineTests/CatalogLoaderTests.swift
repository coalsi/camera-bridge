import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// Reading a recordings folder into the catalog (Mac spec 4.1, 4.4, 4.5): what is listed, what is left alone, what needs repair.
@Suite struct CatalogLoaderTests {
    static let start: Int64 = 1_760_088_000_000

    @discardableResult
    static func sparse(_ root: URL, camera: UUID, directory: String? = nil, date: String = "2026-10-10", base: String = "13-00-00", startMs: Int64 = start,
                       count: Int = 6, manifest: Bool = true) throws -> (mp4: URL, index: CBIndexFile) {
        try ArchiveFixtureWriter.writeSparse(root: root, camera: camera, directory: directory ?? camera.uuidString, date: date, baseName: base, startMs: startMs,
                                             fragmentCount: count, writesManifest: manifest)
    }

    @Test func listsTheOwnFilesOfEveryCameraDirectoryWithTheirRollups() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let first = UUID(), second = UUID()
        let (_, index) = try Self.sparse(directory.url, camera: first, count: 60)
        try Self.sparse(directory.url, camera: first, date: "2026-10-09", base: "23-59-00", startMs: Self.start - 3_600_000)
        try Self.sparse(directory.url, camera: first, base: "13-00-00-2", startMs: Self.start + 600_000, manifest: false)
        try Self.sparse(directory.url, camera: second, directory: "Porch", base: "08-00-00")
        let scan = CatalogLoader.scan(root: directory.url)
        #expect(scan.files.count == 4 && scan.needsRepair.isEmpty && scan.unreadableDirectories == 0)
        let big = try #require(scan.files.first { $0.segment == "\(first.uuidString)/2026-10-10/13-00-00" })
        #expect(big.camera == first && big.startMs == Self.start && big.endMs == index.endWallMs && big.fragmentCount == 60 && !big.isOpen)
        #expect(big.rollups == index.rollups && big.rollups.count == 3 && big.initLength == 600 && big.mp4Bytes == index.mp4Size)
        #expect(big.sidecarBytes == UInt64(index.encoded().count) && big.fileKey == ArchiveIdentity.fileKey(forSegment: big.segment))
        #expect(scan.files.contains { $0.segment == "Porch/2026-10-10/08-00-00" && $0.camera == second }, "a directory named after the camera maps to the id in camera.json")
        #expect(scan.files.contains { $0.segment.hasSuffix("2026-10-10/13-00-00-2") }, "a file name with a suffix is an own name")
    }

    @Test func leavesForeignThingsAlone() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let camera = UUID()
        let (mp4, index) = try Self.sparse(directory.url, camera: camera)
        let cameraFolder = directory.url.appending(path: camera.uuidString)
        let dateFolder = cameraFolder.appending(path: "2026-10-10")
        // Foreign names beside the real files, and whole directories that are not part of the layout.
        for name in ["notes.txt", "13-00-00.mp4.bak", "13-0-0.mp4", "13-00-00 copy.mp4", ".hidden.mp4", "13-00-00.mov", "25-00-00.mp4"] {
            try Data("x".utf8).write(to: dateFolder.appending(path: name))
        }
        try FileManager.default.createDirectory(at: cameraFolder.appending(path: "backup"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dateFolder, to: cameraFolder.appending(path: "backup/2026-10-10"))
        try FileManager.default.copyItem(at: dateFolder, to: cameraFolder.appending(path: "2026-10-10 old"))
        try FileManager.default.createDirectory(at: directory.url.appending(path: "NoManifest/2026-10-10"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: mp4, to: directory.url.appending(path: "NoManifest/2026-10-10/13-00-00.mp4"))
        try Data("not json".utf8).write(to: directory.url.appending(path: "NoManifest/camera.json"))
        try FileManager.default.createDirectory(at: directory.url.appending(path: "BadId"), withIntermediateDirectories: true)
        try Data(#"{"id":"not-a-uuid","name":"x"}"#.utf8).write(to: directory.url.appending(path: "BadId/camera.json"))
        try Data("stray".utf8).write(to: directory.url.appending(path: "stray.mp4"))
        let scan = CatalogLoader.scan(root: directory.url)
        #expect(scan.files.map(\.segment) == ["\(camera.uuidString)/2026-10-10/13-00-00"] && scan.files[0].fragmentCount == index.fragments.count)
        #expect(scan.needsRepair.isEmpty, "foreign names are not our files, so there is nothing to repair")
    }

    @Test func neverFollowsASymbolicLink() throws {
        let directory = try TemporaryDirectory()
        let outside = try TemporaryDirectory()
        defer { directory.remove(); outside.remove() }
        let camera = UUID()
        let (mp4, _) = try Self.sparse(directory.url, camera: camera)
        let dateFolder = mp4.deletingLastPathComponent()
        // A second recording that is only links: to a real file elsewhere, and its sidecar.
        let realOutside = try Self.sparse(outside.url, camera: camera, base: "14-00-00", startMs: Self.start + 3_600_000)
        try FileManager.default.createSymbolicLink(at: dateFolder.appending(path: "14-00-00.mp4"), withDestinationURL: realOutside.mp4)
        try FileManager.default.createSymbolicLink(at: dateFolder.appending(path: "14-00-00.cbidx"),
                                                   withDestinationURL: realOutside.mp4.deletingPathExtension().appendingPathExtension("cbidx"))
        // A symbolic link to a whole date directory and to a whole camera directory.
        try FileManager.default.createSymbolicLink(at: directory.url.appending(path: camera.uuidString + "/2026-10-11"),
                                                   withDestinationURL: outside.url.appending(path: "\(camera.uuidString)/2026-10-10"))
        try FileManager.default.createSymbolicLink(at: directory.url.appending(path: "Linked"), withDestinationURL: outside.url.appending(path: camera.uuidString))
        // A real mp4 whose sidecar is a link: the index is not trusted and is not rebuilt through the link either.
        let (linkedMP4, _) = try Self.sparse(directory.url, camera: camera, base: "15-00-00", startMs: Self.start + 7_200_000, manifest: false)
        let sidecar = linkedMP4.deletingPathExtension().appendingPathExtension("cbidx")
        let copy = outside.url.appending(path: "copy.cbidx")
        try FileManager.default.moveItem(at: sidecar, to: copy)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: copy)
        let scan = CatalogLoader.scan(root: directory.url)
        #expect(scan.files.map(\.segment) == ["\(camera.uuidString)/2026-10-10/13-00-00"], "only the real file")
        #expect(scan.needsRepair.isEmpty, "a link is never repaired through")
        #expect(CatalogLoader.isSymbolicLink(sidecar) && !CatalogLoader.isSymbolicLink(mp4))
    }

    @Test func aMissingStaleOrUntrustedSidecarNeedsRepair() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let camera = UUID()
        /// Writes a file and its sidecar, `change` edits the sidecar's bytes (nil removes it) or the mp4.
        func make(_ base: String, _ change: (URL, inout Data?) throws -> Void) throws {
            let (mp4, index) = try Self.sparse(directory.url, camera: camera, base: base, manifest: base == "10-00-00")
            let sidecar = mp4.deletingPathExtension().appendingPathExtension("cbidx")
            var data: Data? = index.encoded()
            try change(mp4, &data)
            if let data { try data.write(to: sidecar) } else { try FileManager.default.removeItem(at: sidecar) }
        }
        try make("10-00-00") { _, _ in }
        try make("10-01-00") { _, data in data = nil }
        try make("10-02-00") { mp4, _ in let handle = try FileHandle(forWritingTo: mp4); try handle.truncate(atOffset: handle.seekToEnd() + 10); try handle.close() }   // grew
        try make("10-03-00") { _, data in data = data?.dropLast() }
        try make("10-04-00") { _, data in data?[0] = UInt8(ascii: "X") }
        try make("10-05-00") { _, data in data?[5] = 2 }   // version 2
        try make("10-06-00") { _, data in data = data?.prefix(63) }
        try make("10-07-00") { _, data in data?[8] ^= 0xFF }   // another camera's sidecar
        try make("10-08-00") { _, data in data?.replaceSubrange(52..<56, with: [0x7F, 0xFF, 0xFF, 0xFF]) }   // an impossible record count
        try make("10-09-00") { _, data in data = Data() }
        let scan = CatalogLoader.scan(root: directory.url)
        #expect(scan.files.map(\.segment) == ["\(camera.uuidString)/2026-10-10/10-00-00"])
        #expect(Set(scan.needsRepair.map(\.segment)) == Set(["10-01-00", "10-02-00", "10-03-00", "10-04-00", "10-05-00", "10-06-00", "10-07-00", "10-08-00", "10-09-00"]
            .map { "\(camera.uuidString)/2026-10-10/\($0)" }))
        #expect(scan.needsRepair.allSatisfy { $0.camera == camera && $0.modified > Date(timeIntervalSinceNow: -60) })
    }

    @Test func aFolderThatCannotBeListedIsReportedNotThrown() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
        let scan = CatalogLoader.scan(root: missing)
        #expect(scan.files.isEmpty && scan.unreadableDirectories == 1)
    }

    @Test func scanningCanBeCancelled() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        for position in 0..<3 { try Self.sparse(directory.url, camera: UUID(), base: String(format: "10-%02d-00", position)) }
        #expect(CatalogLoader.scan(root: directory.url, isCancelled: { true }).files.isEmpty)
    }
}
