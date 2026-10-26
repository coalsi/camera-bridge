import BridgeEngine
import Foundation
import Testing
@testable import BridgeDaemon

/// `--recordings-dir` and `CAMERABRIDGE_RECORDINGS_DIR` (the NVR's folder), parsed like every other daemon option.
@Suite struct RecordingsOptionsTests {
    private let dataDirectory = URL(fileURLWithPath: "/var/lib/camera-bridge", isDirectory: true)

    @Test func withoutAnythingTheFolderIsRecordingsInsideTheDataDirectory() throws {
        let options = try DaemonOptions.parse(arguments: [])
        #expect(options.recordingsDirectory == nil)
        #expect(options.effectiveRecordingsDirectory(dataDirectory: dataDirectory).path == "/var/lib/camera-bridge/recordings")
        // Development mode and the other flags leave it alone.
        let development = try DaemonOptions.parse(arguments: ["--dev", "--port", "8123"])
        #expect(development.recordingsDirectory == nil)
    }

    @Test func theArchiveDrivesFolderIsTheOptionElseArchiveInsideTheDataDirectoryOnCameraBridgeOS() throws {
        let none = try DaemonOptions.parse(arguments: [])
        #expect(none.effectiveArchiveDirectory(dataDirectory: dataDirectory, systemAvailable: true)?.path == "/var/lib/camera-bridge/archive")
        #expect(none.effectiveArchiveDirectory(dataDirectory: dataDirectory, systemAvailable: false) == nil, "no Camera Bridge OS underneath: no archive drive")
        let flagged = try DaemonOptions.parse(arguments: ["--archive-dir", "/Volumes/Archive/cb"])
        #expect(flagged.effectiveArchiveDirectory(dataDirectory: dataDirectory, systemAvailable: false)?.path == "/Volumes/Archive/cb")
        let variable = try DaemonOptions.parse(arguments: [], environment: ["CAMERABRIDGE_ARCHIVE_DIR": "/srv/archive"])
        #expect(variable.archiveDirectory?.path == "/srv/archive")
        #expect(try DaemonOptions.parse(arguments: ["--preview"]).effectiveArchiveDirectory(dataDirectory: dataDirectory, systemAvailable: true) == nil)
        #expect(throws: DaemonOptions.UsageError.self) { try DaemonOptions.parse(arguments: ["--archive-dir", "archive"]) }
    }

    @Test func theFlagIsParsedInBothSpellings() throws {
        let spaced = try DaemonOptions.parse(arguments: ["--recordings-dir", "/srv/cb-recordings"])
        #expect(spaced.recordingsDirectory?.path == "/srv/cb-recordings")
        #expect(spaced.effectiveRecordingsDirectory(dataDirectory: dataDirectory).path == "/srv/cb-recordings")
        let inline = try DaemonOptions.parse(arguments: ["--recordings-dir=/srv/other"])
        #expect(inline.recordingsDirectory?.path == "/srv/other")
    }

    @Test func theVariableIsReadAndTheFlagWins() throws {
        let environment = ["CAMERABRIDGE_RECORDINGS_DIR": "/srv/from-variable"]
        #expect(try DaemonOptions.parse(arguments: [], environment: environment).recordingsDirectory?.path == "/srv/from-variable")
        let flagged = try DaemonOptions.parse(arguments: ["--recordings-dir", "/srv/from-flag"], environment: environment)
        #expect(flagged.recordingsDirectory?.path == "/srv/from-flag")
        // An empty variable counts as not set, like every other one; this setting has no older spelling.
        #expect(try DaemonOptions.parse(arguments: [], environment: ["CAMERABRIDGE_RECORDINGS_DIR": ""]).recordingsDirectory == nil)
        #expect(try DaemonOptions.parse(arguments: [], environment: ["CAMERA_BRIDGE_RECORDINGS_DIR": "/srv/old"]).recordingsDirectory == nil)
    }

    @Test(arguments: [
        ["--recordings-dir", "recordings"],
        ["--recordings-dir", "./recordings"],
        ["--recordings-dir", "/srv/../etc"],
        ["--recordings-dir", "/srv/line\nbreak"],
        ["--recordings-dir", "/srv/nul\u{0}byte"],
        ["--recordings-dir", "/" + String(repeating: "a", count: 1_100)],
        ["--recordings-dir"],
    ])
    func aFolderTheEngineCouldNotStoreIsRefused(arguments: [String]) {
        #expect(throws: DaemonOptions.UsageError.self) { try DaemonOptions.parse(arguments: arguments) }
    }

    @Test func aBadVariableNamesItselfAndNotItsValue() {
        do {
            _ = try DaemonOptions.parse(arguments: [], environment: ["CAMERABRIDGE_RECORDINGS_DIR": "relative/path"])
            Issue.record("a relative path must be refused")
        } catch let error as DaemonOptions.UsageError {
            #expect(error.message.contains("CAMERABRIDGE_RECORDINGS_DIR"))
            #expect(!error.message.contains("relative/path"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func theUsageTextDocumentsTheFlagAndTheVariable() {
        #expect(DaemonOptions.usage.contains("--recordings-dir"))
        #expect(DaemonOptions.usage.contains("CAMERABRIDGE_RECORDINGS_DIR"))
    }
}
