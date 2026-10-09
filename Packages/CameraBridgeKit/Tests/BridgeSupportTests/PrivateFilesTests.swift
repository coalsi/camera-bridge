import Foundation
import Testing
@testable import BridgeSupport

/// The one atomic 0600 writer shared by the HAP store and the engine's configuration (W4 review: the two copies had
/// diverged on directory permissions).
@Suite struct PrivateFilesTests {
    private func mode(_ url: URL) throws -> Int {
        try #require((FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "PrivateFilesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path(percentEncoded: false))
        return root
    }

    @Test func createdDirectoriesArePrivateAndExistingOnesAreLeftAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "hap/camera", directoryHint: .isDirectory)
        try PrivateFiles.prepareDirectory(nested)
        #expect(try mode(root) == 0o755, "an existing directory is never changed")
        #expect(try mode(root.appending(path: "hap", directoryHint: .isDirectory)) == 0o700, "every level created is 0700")
        #expect(try mode(nested) == 0o700)

        // Loosened afterwards (by someone else): left as it is, like every existing directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: nested.path(percentEncoded: false))
        try PrivateFiles.prepareDirectory(nested)
        #expect(try mode(nested) == 0o750)
    }

    @Test func writesAreAtomicAndPrivate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "state.json", directoryHint: .notDirectory)
        try PrivateFiles.write(Data("one".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("one".utf8))
        #expect(try mode(file) == 0o600)

        // Replacing a file someone made readable restores 0600.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false))
        try PrivateFiles.write(Data("two".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("two".utf8))
        #expect(try mode(file) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)) == ["state.json"], "no temporary files left")
        #expect(PrivateFiles.exists(file))

        let missing = root.appending(path: "absent/state.json", directoryHint: .notDirectory)
        #expect(throws: PrivateFiles.Failure.createFailed("state.json")) { try PrivateFiles.write(Data(), to: missing) }
    }

    @Test func unusedURLSkipsExistingNames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFiles.write(Data(), to: root.appending(path: "backup-0.json"))
        try PrivateFiles.write(Data(), to: root.appending(path: "backup-1.json"))
        #expect(PrivateFiles.unusedURL(in: root) { "backup-\($0).json" }.lastPathComponent == "backup-2.json")
    }
}
