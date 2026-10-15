import BridgeSupport
import Dispatch
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// Collects what the store logs (the log sink of the tests).
final class ArchiveStoreLogCollector: LogSink {
    private let entries = Box<[LogEntry]>([])

    func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }

    /// What the NVR category said.
    var messages: [String] { entries.value.filter { $0.category == "NVR" }.map(\.message) }
}

/// No absolute path, no camera address and no credential in what the store logs (addendum L9, "Information hygiene"), whatever goes wrong.
@Suite(.serialized) struct ArchiveStoreLogTests {
    @Test func theLogNamesNoFolderWhateverGoesWrong() async throws {
        let collector = ArchiveStoreLogCollector()
        let token = LogHub.addSink(collector)
        defer { LogHub.removeSink(token) }
        let camera = ArchiveStoreHarness.camera
        var old: ArchiveStoreRetentionTests.Written?
        var damaged: ArchiveFixtureResult?
        let gate = DispatchSemaphore(value: 0)
        let harness = try ArchiveStoreHarness(spaceGate: gate, probeStallAfter: .milliseconds(300), logs: true) { root in
            old = try ArchiveStoreRetentionTests.sparse(root, camera: camera, hoursAgo: 24 * 30, manifest: true)
            damaged = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString, baseName: "13-00-00"), root: root)
        }
        harness.failRemoval.set([old!.segment + ".mp4"])
        harness.store.start(settings: harness.settings())
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.writeState.pause == .notWritable("The drive isn’t answering.") })   // a drive that hangs
        for _ in 0..<20 { gate.signal() }
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.isSettled })
        await harness.store.runRetention(harness.run)                       // a file that cannot be deleted
        var bytes = try Data(contentsOf: damaged!.mp4)
        bytes.replaceSubrange(Int(damaged!.index.fragments[2].offset) + 4..<Int(damaged!.index.fragments[2].offset) + 8, with: Data("junk".utf8))
        try bytes.write(to: damaged!.mp4)
        let fragment = try #require(await harness.store.fragment(camera: camera, containing: ArchiveTime.date(ms: 1_760_101_200_000 + 6_000)))
        _ = try? await harness.store.read(fragment, .fragment)              // a fragment that is not where the index says
        harness.store.recorderFailed(camera: camera, "write failed at https://admin:hunter2@192.0.2.10/stream?token=abc123")   // a message with secrets in it
        try await Task.sleep(for: .milliseconds(300))
        await harness.store.stop()
        let messages = collector.messages
        #expect(messages.count >= 4, "the store did say things: \(messages)")
        for message in messages {
            #expect(!message.contains(harness.root.url.path(percentEncoded: false)) && !message.contains(harness.dataDirectory.url.path(percentEncoded: false)), "a path in: \(message)")
            #expect(!message.contains("/var/") && !message.contains("/private/") && !message.contains("hunter2") && !message.contains("abc123"), "\(message)")
        }
    }
}
