#if os(macOS)
import BridgeEngine
import BridgeSupport
import BridgeWeb
import Foundation
import Testing
import TestSupport
@testable import BridgeDaemon

/// The whole daemon on this Mac (the real engine, the web interface on a loopback port, a throwaway data directory) and the NVR's folder:
/// where it is, who may write it, what is offered to the web interface, and that nothing about it can hold up the start.
@Suite(.serialized, .timeLimit(.minutes(2))) struct DaemonRecordingsTests {
    @MainActor
    private func makeDaemon(directory: TemporaryDirectory, extra: [String] = []) throws -> Daemon {
        var options = try DaemonOptions.parse(arguments: ["--dev", "--data-dir", directory.url.path] + extra)
        options.port = 0
        options.hapBasePort = UInt16.random(in: 31_000...37_000)
        options.sensorsBridgePort = 0
        options.staticDirectory = nil
        return Daemon(options: options, environment: [:])
    }

    private func status(port: UInt16) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/status")!)
        request.timeoutInterval = 20
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (response as! HTTPURLResponse).statusCode
    }

    private func mode(of url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.posixPermissions] as? NSNumber)?.intValue
    }

    @Test @MainActor func theDefaultFolderIsMadeAndOffered() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        defer { directory.remove() }
        let daemon = try makeDaemon(directory: directory)
        let port = try await daemon.start()
        let recordings = directory.url.appending(path: "recordings", directoryHint: .isDirectory)
        #expect(mode(of: recordings) == 0o700)
        #expect(daemon.archiveLocations == RecordingsFolder.locations(recordings: recordings))
        #expect(daemon.archiveLocations.map(\.id) == ["builtin"])
        #expect(try await status(port: port) == 200)
        await daemon.stop()
    }

    @Test @MainActor func theEngineGetsThePolicyThatNamesFoldersByCameraID() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        defer { directory.remove() }
        let environment = try Daemon.makeEnvironment(directory: directory.url, options: DaemonOptions())
        let policy = try #require(environment.archivePolicy)
        #expect(policy.directoryNaming == .cameraID)
        #expect(policy.isSystemVolume(directory.url.appending(path: "recordings", directoryHint: .isDirectory)))
        #expect(policy.systemFloor(100_000_000_000) == 8 * 1_073_741_824)
    }

    @Test @MainActor func theDemoKeyframeIntervalOfTheCommandLineReachesTheEngineEnvironment() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        defer { directory.remove() }
        #expect(try Daemon.makeEnvironment(directory: directory.url, options: DaemonOptions()).demoKeyframeSeconds == nil)
        let options = try DaemonOptions.parse(arguments: ["--dev", "--demo-keyframe-seconds", "12"])
        #expect(try Daemon.makeEnvironment(directory: directory.url, options: options).demoKeyframeSeconds == 12)
    }

    @Test @MainActor func aFolderGivenOnTheCommandLineIsUsedInsteadAndOffered() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        let drive = try TemporaryDirectory(prefix: "cb-drive")   // another place than the data directory
        defer { directory.remove(); drive.remove() }
        let elsewhere = drive.file("recordings")
        let daemon = try makeDaemon(directory: directory, extra: ["--recordings-dir", elsewhere.path])
        _ = try await daemon.start()
        #expect(mode(of: elsewhere) == 0o700)
        #expect(!FileManager.default.fileExists(atPath: directory.file("recordings").path), "the default folder is not made as well")
        #expect(daemon.archiveLocations.map(\.path) == [RecordingsFolder.normalizedPath(elsewhere)])
        await daemon.stop()
    }

    @Test @MainActor func aDriveThatIsNotThereDoesNotStopTheDaemonAndIsNotInvented() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        let drive = try TemporaryDirectory(prefix: "cb-drive")
        defer { directory.remove(); drive.remove() }
        let missing = drive.file("not-mounted/recordings")
        let daemon = try makeDaemon(directory: directory, extra: ["--recordings-dir", missing.path])
        let port = try await daemon.start()
        #expect(!FileManager.default.fileExists(atPath: drive.file("not-mounted").path), "no parent was created")
        #expect(daemon.archiveLocations.count == 1, "still offered: the web interface shows why it cannot be used")
        #expect(try await status(port: port) == 200)
        await daemon.stop()
    }

    @Test @MainActor func startingDoesNotWaitForTheArchive() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        defer { directory.remove() }
        // A big, messy archive from an earlier run: thousands of foreign files, a camera folder, and a recording that was torn by a power cut.
        let camera = directory.url.appending(path: "recordings/\(UUID().uuidString)/2026-10-09", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: camera, withIntermediateDirectories: true)
        for index in 0..<3_000 { FileManager.default.createFile(atPath: camera.appending(path: "foreign-\(index).txt").path, contents: Data()) }
        try Data(repeating: 0, count: 4_096).write(to: camera.appending(path: "10-00-00.mp4"))
        let daemon = try makeDaemon(directory: directory)
        let began = ContinuousClock.now
        let port = try await daemon.start()
        let elapsed = ContinuousClock.now - began
        #expect(elapsed < .seconds(20), "start() took \(elapsed): the archive loads in the background")
        #expect(try await status(port: port) == 200)
        await daemon.stop()
    }

    @Test @MainActor func thePreviewOffersNoArchiveAndMakesNoFolder() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        defer { directory.remove() }
        let daemon = try makeDaemon(directory: directory, extra: ["--preview"])
        _ = try await daemon.start()
        #expect(daemon.backend?.archive == nil)
        #expect(daemon.archiveLocations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.file("recordings").path))
        await daemon.stop()
        // A real run has an archive object (not ready until the store has loaded).
        let real = try TemporaryDirectory(prefix: "cb-daemon")
        defer { real.remove() }
        let running = try makeDaemon(directory: real)
        _ = try await running.start()
        #expect(running.backend?.archive != nil)
        await running.stop()
    }
}
#endif
