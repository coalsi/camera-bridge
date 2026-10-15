import Dispatch
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// The repair is wired into the store's start (Mac spec 4.5 and "Changes to the Mac design"): the default `ArchiveStoreTuning.repair` is the
/// scanner's, it runs in the background, `start()` does not wait for it, and recorders (and readers) wait for it, not the other way round.
@Suite struct ArchiveStoreRepairWiringTests {
    static let camera = ArchiveStoreHarness.camera
    static let start: Int64 = 1_760_101_200_000

    @Test func theDefaultRepairIsTheScannersAndNotTheStubOfStepEight() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let result = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, writesIndex: false), root: directory.url)
        let outcome = try ArchiveStoreTuning().repair(result.mp4, result.sidecar, Self.camera)
        guard case .indexed(let index, _, _) = outcome else {
            Issue.record("the default repair answered \(outcome)")
            return
        }
        let written = try Data(contentsOf: result.sidecar)
        #expect(index == result.index && written == result.index.encoded(), "it rebuilt and wrote the index")
    }

    @Test func aSlowRepairDoesNotDelayStartAndRecordersAndReadersWaitForIt() async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = Box(0)
        defer { gate.signal() }
        let harness = try ArchiveStoreHarness(populate: { root in
            try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, startMs: Self.start, writesIndex: false), root: root)
        }, repair: { mp4, sidecar, camera in
            entered.update { $0 += 1 }
            _ = gate.wait(timeout: .now() + 30)   // bounded: a test that fails does not leave the control queue stuck
            return try IndexScanner.repair(mp4: mp4, sidecar: sidecar, camera: camera)
        })
        let started = ContinuousClock.now
        harness.store.start(settings: harness.settings())
        #expect(ContinuousClock.now - started < .seconds(2), "start() returns at once")
        #expect(await eventually(timeout: archiveStorePatience) { entered.value == 1 }, "and the repair is running, in the background")
        #expect(!harness.store.isReady && !harness.store.isSettled && !harness.store.writeState.isReady, "recorders may not open a file yet")
        let meanwhile = await harness.store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 1_000))
        #expect(meanwhile == nil, "and a read answers nothing")
        gate.signal()
        #expect(await eventually(timeout: archiveStorePatience) { harness.store.isSettled })
        #expect(harness.store.isReady && harness.store.writeState.isReady)
        let ids = await harness.ids()
        #expect(ids.count == 6, "the repaired file is in the timeline")
    }

    @Test func aRepairThatFailsLeavesTheFileAloneAndTheStoreStillStartsUp() async throws {
        let harness = try ArchiveStoreHarness(populate: { root in
            try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: Self.camera, cameraDirectory: Self.camera.uuidString, startMs: Self.start, writesIndex: false), root: root)
        }, repair: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })
        let before = try Data(contentsOf: harness.root.url.appending(path: "\(Self.camera.uuidString)/2026-10-10/13-00-00.mp4"))
        #expect(await harness.start())
        #expect(harness.store.isReady, "a drive that refuses the write does not keep the store from starting")
        let ids = await harness.ids()
        #expect(ids.isEmpty, "the file is out of the timeline until it can be repaired")
        let after = try Data(contentsOf: harness.root.url.appending(path: "\(Self.camera.uuidString)/2026-10-10/13-00-00.mp4"))
        #expect(after == before, "and nothing was cut")
    }
}

#if canImport(Darwin)
/// The same through the whole engine: the real `BridgeEngine`, its settings and its archive, with the default store tuning.
@Suite(.serialized) struct ArchiveStoreRepairEngineTests {
    @MainActor @Test(.timeLimit(.minutes(2))) func aTornRecordingAndAPowerCutRecordingWithoutASidecarAreRepairedInTheBackgroundAfterStartReturned() async throws {
        let data = try TemporaryDirectory(), recordings = try TemporaryDirectory()
        defer { data.remove(); recordings.remove() }
        let camera = UUID()
        // What a crash leaves: one recording cut in the middle of its fifth fragment (the size is past the last whole fragment), one that ended on a
        // fragment boundary when the power went; neither has a sidecar, the recorder writes it when the file closes.
        let torn = try ArchiveStoreEngineTests.recentFile(camera: camera, in: recordings.url, secondsAgo: 3_600, writesIndex: false)
        let handle = try FileHandle(forWritingTo: torn.mp4)
        try handle.truncate(atOffset: torn.index.fragments[4].offset + 700)
        try handle.close()
        let powerCut = try ArchiveStoreEngineTests.recentFile(camera: camera, in: recordings.url, secondsAgo: 2_400, writesIndex: false)
        let engine = try await ArchiveStoreEngineTests.engine(directory: data, recordings: recordings.url, policy: ArchiveStoreEngineTests.policy())
        let started = ContinuousClock.now
        await engine.start()
        #expect(ContinuousClock.now - started < .seconds(30), "start() did not wait for the repair")
        #expect(engine.state == .running)
        #expect(await eventually(timeout: archiveStorePatience) { engine.archive.isReady }, "the repair and the catalog load finish in the background")
        var ids: [String] = []
        var cursor = Date(timeIntervalSince1970: 0)
        while let fragment = await engine.archive.fragment(camera: camera, startingAfter: cursor) {
            ids.append(fragment.id)
            cursor = fragment.start
        }
        #expect(ids.count == 4 + 6, "the four whole fragments of the torn recording and the six of the other")
        let lastWhole = torn.index.fragments[3]
        let tornSize = (try? FileManager.default.attributesOfItem(atPath: torn.mp4.path(percentEncoded: false))[.size] as? UInt64) ?? 0
        #expect(tornSize == lastWhole.offset + UInt64(lastWhole.length), "the torn tail was cut")
        let tornIndex = try CBIndexFile.decode(try Data(contentsOf: torn.sidecar), mp4Size: tornSize)
        #expect(tornIndex.fragments == Array(torn.index.fragments.prefix(4)), "and the sidecar lists exactly the whole fragments")
        let powerCutSidecar = try Data(contentsOf: powerCut.sidecar)
        #expect(powerCutSidecar == powerCut.index.encoded(), "the sidecar the recorder would have written")
        await engine.stop()
    }
}
#endif
