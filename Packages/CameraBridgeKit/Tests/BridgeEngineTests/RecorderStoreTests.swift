import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// A store that says "not now": not ready, no folder, paused, or a new folder (Mac spec 4.5, 6, 13).
@Suite struct RecorderStoreTests {
    @Test func aStoreThatPausesRecordingClosesTheFileAndResumesWithAReplayOfTheNewestGroup() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let recorder = rig.recorder(tick: .milliseconds(20))
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<130, gop: 60), to: recorder)
        rig.target.update { $0.pause = .diskFull }
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .paused(.diskFull) && rig.target.closedSegments.count == 1 })
        #expect(await rig.hub.subscriberCount == 0, "a paused recorder holds no subscription")
        await rig.feed(RecorderFixtures.videoFrames(130..<250, gop: 60))                 // nothing records these, except what the hub keeps
        rig.target.update { $0.pause = nil }
        #expect(await eventually(timeout: .seconds(10)) { await rig.hub.subscriberCount == 1 })
        await rig.feed(RecorderFixtures.videoFrames(250..<300, gop: 60), to: recorder)
        await recorder.stop()
        let first = try RecordedFile(rig, segment: item(rig.target.openedSegments, 0)), second = try RecordedFile(rig, segment: item(rig.target.openedSegments, 1))
        let firstFrames = try first.videoFrames().count
        #expect(firstFrames == 130)
        let resumed = try second.videoFrames()
        #expect(resumed.first?.isKeyframe == true && resumed.count == 60 + 0 || resumed.count > 0, "the newest group the hub held, then the live frames")
        #expect(resumed.map(\.nalUnits) == RecorderFixtures.videoFrames(240..<300, gop: 60).map(\.nalUnits))
    }

    @Test func aNewFolderGenerationClosesTheFileAndRecordsToTheNewFolder() async throws {
        let rig = try RecorderRig()
        let second = try TemporaryDirectory()
        defer { rig.root.remove(); second.remove() }
        let recorder = rig.recorder(tick: .milliseconds(20))
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<130, gop: 60), to: recorder)
        rig.target.update {
            $0.folder = second.url
            $0.generation += 1
        }
        #expect(await eventually(timeout: .seconds(10)) { rig.target.closedSegments.count == 1 })
        await rig.feed(RecorderFixtures.videoFrames(130..<250, gop: 60), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { rig.target.openedSegments.count == 2 })
        await recorder.stop()
        let camera = rig.camera.id.uuidString
        #expect(rig.root.contents() == [camera] && second.contents() == [camera], "each folder has its own camera directory")
        let segment = try item(rig.target.openedSegments, 1)
        #expect(FileManager.default.fileExists(atPath: second.url.appending(path: "\(segment).mp4").path(percentEncoded: false)))
    }

    @Test func aStoreThatIsNotReadyOrHasNoFolderKeepsTheRecorderIdle() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        rig.target.update { $0.isReady = false }
        let recorder = rig.recorder(tick: .milliseconds(20))
        await recorder.start()
        #expect(recorder.status.state == .waiting("loading the recordings") && rig.target.openedSegments.isEmpty)
        #expect(await rig.hub.subscriberCount == 0)
        rig.target.update { $0.isReady = true; $0.folder = nil }
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .paused(.noFolder) })
        rig.target.update { $0.folder = rig.root.url }
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .waiting("waiting for the camera") })
        #expect(await eventually(timeout: .seconds(10)) { await rig.hub.subscriberCount == 1 })
        await rig.feed(RecorderFixtures.videoFrames(0..<130, gop: 60), to: recorder)
        #expect(await eventually(timeout: .seconds(10)) { recorder.status.state == .recording })
        await recorder.stop()
    }
}
