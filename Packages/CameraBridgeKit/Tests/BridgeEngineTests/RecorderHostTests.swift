import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// `RecorderHost`: one recorder per camera, started by the coordinator when a runtime starts or Record changes, stopped within seconds.
@Suite struct RecorderHostTests {
    func host(_ rig: RecorderRig, tick: Duration = .milliseconds(20), closeDeadline: Duration = .seconds(3), naming: ArchivePlatformPolicy.DirectoryNaming? = nil) -> RecorderHost {
        var environment = BridgeEnvironment.inert(directory: rig.root.url)
        environment.archivePolicy = naming.map { ArchivePlatformPolicy(space: { _ in nil }, isSystemVolume: { _ in false }, systemFloor: { $0 / 10 }, directoryNaming: $0) }
        return RecorderHost(target: rig.target, environment: environment, signal: rig.signal, tuning: rig.tuning(tick: tick, closeDeadline: closeDeadline))
    }

    @Test func aCameraHasARecorderFromAttachToDetach() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let host = host(rig)
        #expect(host.status(for: rig.camera.id) == nil)
        await host.attach(rig.camera, hub: rig.hub)
        #expect(host.status(for: rig.camera.id)?.state == .waiting("waiting for the camera"))
        #expect(await rig.hub.subscriberCount == 1, "attach returns subscribed")
        await rig.feed(RecorderFixtures.videoFrames(0..<130, gop: 60), to: host.recorder(for: rig.camera.id))
        #expect(await eventually(timeout: .seconds(10)) { host.status(for: rig.camera.id)?.state == .recording })
        await host.detach(rig.camera.id)
        #expect(host.status(for: rig.camera.id) == nil && rig.target.closedSegments.count == 1)
        #expect(await rig.hub.subscriberCount == 0)
        await host.detach(rig.camera.id)                                              // a camera without a recorder is ignored
        let file = try RecordedFile(rig, segment: item(rig.target.openedSegments, 0))
        #expect(try file.videoFrames().count == 130, "detach wrote out the open group")
    }

    @Test func attachingAgainReplacesTheRecorderAndTheOldFileIsClosedFirst() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let host = host(rig)
        await host.attach(rig.camera, hub: rig.hub)
        await rig.feed(RecorderFixtures.videoFrames(0..<130, gop: 60), to: host.recorder(for: rig.camera.id))
        await host.attach(rig.camera, hub: rig.hub)
        #expect(rig.target.closedSegments.count == 1, "the first recorder closed its file before the second subscribed")
        #expect(await rig.hub.subscriberCount == 1)
        await host.detachAll()
    }

    @Test func theSoundSwitchMakesANewRecorderAndTheNewFileHasSound() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: false))
        defer { rig.root.remove() }
        let host = host(rig)
        await host.attach(rig.camera, hub: rig.hub)
        let video = RecorderFixtures.videoFrames(0..<200, gop: 60)
        let sound = RecorderFixtures.audioFrames(seconds: 10)
        await rig.feed(RecorderFixtures.interleaved(Array(video[0..<150]), sound.filter { $0.pts.seconds < 5 }), to: host.recorder(for: rig.camera.id))
        #expect(await eventually(timeout: .seconds(10)) { !rig.target.openedSegments.isEmpty })
        // What the coordinator does for a changed sound switch: detach, then attach with the new camera on the same hub.
        var louder = rig.camera
        louder.nvrRecordSound = true
        await host.detach(louder.id)
        await host.attach(louder, hub: rig.hub)
        // The new recorder replays the hub's newest group first: the 30 frames from the keyframe at frame 120 and the 31 sound frames after it.
        let recorder = try #require(host.recorder(for: louder.id))
        let replay = 30 + sound.filter { $0.pts.seconds >= 4 && $0.pts.seconds < 5 }.count
        #expect(await eventually(timeout: .seconds(10)) { await recorder.samplesHandled == replay })
        await rig.feed(RecorderFixtures.interleaved(Array(video[150..<200]), sound.filter { $0.pts.seconds >= 5 && $0.pts.seconds < 7 }), to: recorder)
        await host.detach(louder.id)
        let segments = rig.target.openedSegments
        #expect(segments.count == 2)
        let before = try RecordedFile(rig, segment: item(segments, 0)), after = try RecordedFile(rig, segment: item(segments, 1))
        #expect(before.info.audio == nil && after.info.audio == RecorderFixtures.aac32k)
        let replayed = try after.videoFrames()
        // The new recorder replayed the hub's newest group (from the keyframe at frame 120): up to one group is stored twice, the later file wins.
        #expect(replayed.first?.isKeyframe == true && replayed.count == 80)
        #expect(after.start < before.start.addingTimeInterval(Double(try before.videoFrames().count) / 30), "the two files overlap by the replayed frames")
    }

    @Test func detachAllClosesEveryFile() async throws {
        let rig = try RecorderRig()
        let other = RecorderFixtures.camera(name: "Porch")
        let otherHub = MediaHub()
        defer { rig.root.remove() }
        let host = host(rig)
        await host.attach(rig.camera, hub: rig.hub)
        await host.attach(other, hub: otherHub)
        await rig.feed(RecorderFixtures.videoFrames(0..<130, gop: 60), to: host.recorder(for: rig.camera.id))
        for frame in RecorderFixtures.videoFrames(0..<130, gop: 60) { await otherHub.ingest(.video(frame)) }
        #expect(await eventually(timeout: .seconds(10)) { rig.target.openedSegments.count == 2 })
        await host.detachAll()
        #expect(rig.target.closedSegments.count == 2 && host.status(for: other.id) == nil && host.status(for: rig.camera.id) == nil)
        #expect(Set(rig.root.contents()) == ["Driveway", "Porch"], "without a platform policy a folder is named after its camera")
    }

    @Test func detachReturnsWithinItsDeadlineWhateverTheDriveDoes() async throws {
        var rig = try RecorderRig()
        let disk = FaultyFileSystem(.init(blockWrite: 2))
        rig.fileSystem = disk
        defer { disk.release(); rig.root.remove() }
        let host = host(rig, closeDeadline: .milliseconds(300))
        await host.attach(rig.camera, hub: rig.hub)
        await rig.feed(RecorderFixtures.videoFrames(0..<200, gop: 60))
        #expect(await eventually(timeout: .seconds(10)) { !rig.target.openedSegments.isEmpty })
        let started = ContinuousClock.now
        await host.detach(rig.camera.id)
        #expect(ContinuousClock.now - started < .seconds(3), "the drive never answered, detach did not wait for it")
        #expect(rig.target.closedSegments.count == 1)
        if case .closed(_, let index)? = rig.target.events.last { #expect(index == nil, "reported closed without a sidecar: repair deals with it at the next start") }
    }

    @Test func theBoxNamesFoldersByCameraIDAndTheMacByName() async throws {
        let box = try RecorderRig()
        defer { box.root.remove() }
        let boxHost = host(box, naming: .cameraID)
        await boxHost.attach(box.camera, hub: box.hub)
        await box.feed(RecorderFixtures.videoFrames(0..<130, gop: 60), to: boxHost.recorder(for: box.camera.id))
        await boxHost.detachAll()
        #expect(box.root.contents() == [box.camera.id.uuidString])
        let mac = try RecorderRig(camera: RecorderFixtures.camera(name: "Front/Door"))
        defer { mac.root.remove() }
        let macHost = host(mac, naming: nil)
        await macHost.attach(mac.camera, hub: mac.hub)
        await mac.feed(RecorderFixtures.videoFrames(0..<130, gop: 60), to: macHost.recorder(for: mac.camera.id))
        await macHost.detachAll()
        #expect(mac.root.contents() == ["Front-Door"], "no policy: the camera's name, sanitized")
    }

    @Test func aChangeOfStatusWakesTheEngine() async throws {
        let rig = try RecorderRig()
        defer { rig.root.remove() }
        let host = host(rig)
        await rig.signal.wait(timeout: .milliseconds(1))
        await host.attach(rig.camera, hub: rig.hub)
        let started = ContinuousClock.now
        await rig.signal.wait(timeout: .seconds(5))
        #expect(ContinuousClock.now - started < .seconds(2), "attach notified the change signal")
        await rig.signal.wait(timeout: .milliseconds(1))
        await rig.feed(RecorderFixtures.videoFrames(0..<130, gop: 60))
        let later = ContinuousClock.now
        await rig.signal.wait(timeout: .seconds(5))
        #expect(ContinuousClock.now - later < .seconds(2), "the state turning to recording notified it")
        await host.detachAll()
    }
}
