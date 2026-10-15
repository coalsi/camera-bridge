import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// A disk that fills up, disappears or stops answering, and a store that says "not now" (Mac spec 13).
@Suite struct RecorderFaultTests {
    @Test func aFullDiskCutsTheFileBackToItsLastWholeFragmentAndTheRecorderTriesAgainLater() async throws {
        var rig = try RecorderRig()
        let disk = FaultyFileSystem(.init(failWrite: 4))                    // the initialization segment, two fragments, then "no space left on device"
        rig.fileSystem = disk
        defer { rig.root.remove() }
        let log = CameraLogCapture.start(camera: rig.camera.id)
        defer { log.stop() }
        let recorder = rig.recorder(tick: .milliseconds(20))
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<400, gop: 60), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { !rig.target.openedSegments.isEmpty && !rig.target.failures.isEmpty })
        let segment = try #require(rig.target.openedSegments.first)
        #expect(await eventually(timeout: .seconds(10)) { rig.target.closedSegments.contains(segment) })
        // The sidecar describes the two whole fragments, and the mp4 is exactly as long as it says.
        let file = try RecordedFile(rig, segment: segment)
        #expect(file.index.fragments.count == 2 && UInt64(file.mp4.count) == file.index.mp4Size)
        #expect(try file.rescanned() == file.index, "the cut file is a valid file: a scan finds the same two fragments")
        #expect(rig.target.failures == ["NSCocoaErrorDomain 640"], "the store hears the error's domain and code, no text")
        #expect(log.lines.contains { $0.hasPrefix("Recording failed: NSCocoaErrorDomain 640") } && log.lines.allSatisfy { !$0.contains(rig.root.url.path(percentEncoded: false)) })
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .paused(.notWritable("The recordings drive is full.")) })
        // The drive works again: after the retry delay the next keyframe opens a new file.
        rig.uptime.set(rig.uptime.value + 1)
        await rig.feed(RecorderFixtures.videoFrames(400..<700, gop: 60), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { rig.target.openedSegments.count == 2 && recorder.status.state == .recording })
        await recorder.stop()
        let second = try RecordedFile(rig, segment: item(rig.target.openedSegments, 1))
        #expect(try second.videoFrames().first?.isKeyframe == true)
    }

    @Test func aFolderThatIsNotThereIsReportedAndNothingIsCreated() async throws {
        let rig = try RecorderRig()
        let parent = try TemporaryDirectory()
        defer { rig.root.remove(); parent.remove() }
        let missing = parent.url.appending(path: "Volumes/Recordings", directoryHint: .isDirectory)
        rig.target.update { $0.folder = missing }
        let recorder = rig.recorder(tick: .milliseconds(20))
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<200, gop: 60), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .paused(.notWritable("The recordings folder isn’t available.")) })
        #expect(rig.target.failures.count >= 1 && rig.target.openedSegments.isEmpty)
        #expect(parent.contents().isEmpty, "not even the parent of the recordings folder was created")
        await recorder.stop()
    }

    @Test func aDriveThatStopsAnsweringStallsThatRecorderOnly() async throws {
        var rig = try RecorderRig()
        let disk = FaultyFileSystem(.init(blockWrite: 2))                   // the first fragment never returns
        rig.fileSystem = disk
        defer { disk.release(); rig.root.remove() }
        let recorder = rig.recorder(tick: .milliseconds(20))
        await recorder.start()
        // Another consumer of the same hub, which must never notice.
        let other = await rig.hub.subscribe(from: .live)
        let received = Box(0)
        let reader = Task { for await _ in other.samples { received.update { $0 += 1 } } }
        defer { reader.cancel() }
        await rig.feed(RecorderFixtures.videoFrames(0..<200, gop: 60), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { !rig.target.openedSegments.isEmpty })
        let segment = try #require(rig.target.openedSegments.first)
        #expect(await rig.hub.subscriberCount == 2)
        rig.uptime.set(rig.uptime.value + 16)                               // 16 s later the write is still pending
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .paused(.notWritable("The drive isn’t answering.")) })
        #expect(await rig.hub.subscriberCount == 1, "the subscription was dropped")
        #expect(rig.target.closedSegments == [segment], "reported closed without a sidecar")
        if case .closed(_, let index)? = rig.target.events.last { #expect(index == nil) }
        let before = rig.target.openedSegments.count
        await rig.feed(RecorderFixtures.videoFrames(200..<400, gop: 60))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.target.openedSegments.count == before, "no new file while the abandoned write is still blocked")
        #expect(received.value >= 400, "the other subscriber got every frame")
        // The drive answers again: the blocked write ends, the pause lifts, and the recorder replays the newest group into a new file.
        disk.release()
        #expect(await eventually(timeout: .seconds(10)) { await rig.hub.subscriberCount == 2 })
        await rig.feed(RecorderFixtures.videoFrames(400..<500, gop: 60), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .recording || rig.target.openedSegments.count > before })
        await recorder.stop()
    }

    @Test func aBurstOfSixtyMegabytesBehindASlowWriteIsNotAStall() async throws {
        var rig = try RecorderRig()
        let disk = FaultyFileSystem(.init(blockWrite: 2))
        rig.fileSystem = disk
        rig.stallPendingBytes = 256 * 1_048_576
        defer { disk.release(); rig.root.remove() }
        let recorder = rig.recorder(tick: .milliseconds(20))
        await recorder.start()
        // A long group replayed at once: 60 pictures of 1 MB.
        await rig.feed((0..<61).map { RecorderFixtures.video($0, gop: 1_000, size: 1_000_000) }, to: recorder)
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.status.state == .recording, "60 MB pending, 0 s old")
        disk.release()
        await recorder.stop()
        let records = rig.target.records(of: try #require(rig.target.openedSegments.first))
        #expect(records.map { Int($0.samples) }.reduce(0, +) == 61)
    }

    @Test func moreThanTheLimitPendingIsAStall() async throws {
        var rig = try RecorderRig()
        let disk = FaultyFileSystem(.init(blockWrite: 2))
        rig.fileSystem = disk
        rig.stallPendingBytes = 40 * 1_048_576
        defer { disk.release(); rig.root.remove() }
        let recorder = rig.recorder(tick: .milliseconds(20))
        await recorder.start()
        await rig.feed((0..<61).map { RecorderFixtures.video($0, gop: 1_000, size: 1_000_000) })
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .paused(.notWritable("The drive isn’t answering.")) })
        await recorder.stop()
    }
}
