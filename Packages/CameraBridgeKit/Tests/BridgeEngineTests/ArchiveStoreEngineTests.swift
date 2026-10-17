#if canImport(Darwin)
import BridgeSupport
import Dispatch
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// The store behind the engine (task T00's hooks, T02's store): start-up never waits for the archive, the status reaches `nvrStorage`, ids survive
/// `stop()` and `start()`.
@Suite(.serialized) struct ArchiveStoreEngineTests {
    @MainActor
    static func engine(directory: TemporaryDirectory, recordings: URL?, policy: ArchivePlatformPolicy?) async throws -> BridgeEngine {
        var environment = BridgeEnvironment.testing(directory: directory.url)
        environment.archivePolicy = policy
        let engine = BridgeEngine(environment: environment, tuning: .testing)
        var settings = engine.settings
        settings.basePort = UInt16.random(in: 22_000...28_000)
        settings.sensorsBridgePort = 0
        settings.webhookPort = 0
        settings.nvrFolder = recordings?.path(percentEncoded: false)
        try await engine.updateSettings(settings)
        return engine
    }

    /// A file that started an hour ago (the engine's janitor keeps a week), or `secondsAgo`; `writesIndex: false` leaves it without a sidecar.
    @discardableResult
    static func recentFile(camera: UUID, in root: URL, secondsAgo: Double = 3_600, writesIndex: Bool = true) throws -> ArchiveFixtureResult {
        let startMs = Int64((Date().timeIntervalSince1970 - secondsAgo) * 1_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: ArchiveTime.date(ms: startMs))
        return try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString, date: String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!),
                                                          baseName: String(format: "%02d-%02d-%02d", parts.hour!, parts.minute!, parts.second!), startMs: startMs,
                                                          writesIndex: writesIndex), root: root)
    }

    static func policy(free: UInt64 = 400_000_000_000, gate: DispatchSemaphore? = nil) -> ArchivePlatformPolicy {
        ArchivePlatformPolicy(space: { _ in
            gate?.wait()
            return (total: 500_000_000_000, free: free)
        }, isSystemVolume: { _ in false }, systemFloor: { $0 / 10 }, directoryNaming: .cameraID)
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func aDriveThatStallsForAMinuteDoesNotDelayStartOrStop() async throws {
        let data = try TemporaryDirectory(), recordings = try TemporaryDirectory()
        defer { data.remove(); recordings.remove() }
        let gate = DispatchSemaphore(value: 0)
        let engine = try await Self.engine(directory: data, recordings: recordings.url, policy: Self.policy(gate: gate))
        var camera = EngineFixture.demoCamera(name: "Garage")
        camera.nvrEnabled = true
        try await engine.addCamera(camera, password: nil)
        let started = ContinuousClock.now
        await engine.start()
        #expect(ContinuousClock.now - started < .seconds(30), "start() did not wait for the archive (the daemon waits for it before it says READY)")
        #expect(engine.state == .running && !engine.archive.isReady)
        #expect(await eventually(timeout: archiveStorePatience) { engine.nvrStorage?.pause == .notWritable("The drive isn’t answering.") }, "and the drive is reported as not answering")
        let stopped = ContinuousClock.now
        await engine.stop()
        #expect(ContinuousClock.now - stopped < .seconds(10), "stop() does not wait for the stuck call either")
        gate.signal()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func theStorageNumbersReachTheEngineAndTheArchiveLoads() async throws {
        let data = try TemporaryDirectory(), recordings = try TemporaryDirectory()
        defer { data.remove(); recordings.remove() }
        let camera = UUID()
        try Self.recentFile(camera: camera, in: recordings.url)
        let engine = try await Self.engine(directory: data, recordings: recordings.url, policy: Self.policy())
        #expect(engine.nvrStorage == nil && !engine.archive.isReady)
        await engine.start()
        #expect(await eventually(timeout: archiveStorePatience) { engine.archive.isReady && engine.nvrStorage?.totalBytes == 500_000_000_000 && engine.nvrStorage?.oldest != nil })
        let storage = try #require(engine.nvrStorage)
        #expect(storage.pause == nil && storage.freeBytes == 400_000_000_000 && storage.floorBytes == ArchiveConstants.otherVolumeFloorBytes && storage.folder != nil)
        #expect(storage.oldest != nil && engine.archive.extent(camera: camera) != nil)
        // The ids of the fragments are the same after the engine was stopped and started.
        func ids() async -> [String] {
            var ids: [String] = []
            var cursor = Date(timeIntervalSince1970: 0)
            while let fragment = await engine.archive.fragment(camera: camera, startingAfter: cursor) {
                ids.append(fragment.id)
                cursor = fragment.start
            }
            return ids
        }
        let before = await ids()
        #expect(before.count == 6)
        await engine.stop()
        await engine.start()
        #expect(await eventually(timeout: archiveStorePatience) { engine.archive.isReady })
        let after = await ids()
        #expect(after == before)
        await engine.stop()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func aLowDriveShowsUpInTheStatusOfACameraThatRecords() async throws {
        let data = try TemporaryDirectory(), recordings = try TemporaryDirectory()
        defer { data.remove(); recordings.remove() }
        let engine = try await Self.engine(directory: data, recordings: recordings.url, policy: Self.policy(free: 1_000_000_000))   // below the 2 GiB floor of a volume that is not the system's
        await engine.start()
        #expect(await eventually(timeout: archiveStorePatience) { engine.nvrStorage?.pause == .diskFull })
        #expect(engine.nvrStorage?.roomBytes == 0, "nothing used and nothing spare")
        await engine.stop()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func changingTheFolderThroughTheSettingsReloadsTheArchive() async throws {
        let data = try TemporaryDirectory(), first = try TemporaryDirectory(), second = try TemporaryDirectory()
        defer { data.remove(); first.remove(); second.remove() }
        let cameraA = UUID(), cameraB = UUID()
        try Self.recentFile(camera: cameraA, in: first.url)
        try Self.recentFile(camera: cameraB, in: second.url)
        let engine = try await Self.engine(directory: data, recordings: first.url, policy: Self.policy())
        await engine.start()
        #expect(await eventually(timeout: archiveStorePatience) { engine.archive.extent(camera: cameraA) != nil })
        try await engine.updateSettings { $0.nvrFolder = second.url.path(percentEncoded: false) }
        #expect(await eventually(timeout: archiveStorePatience) { engine.archive.extent(camera: cameraB) != nil && engine.archive.extent(camera: cameraA) == nil })
        try await engine.updateSettings { $0.nvrFolder = nil }
        #expect(await eventually(timeout: archiveStorePatience) { engine.nvrStorage?.pause == .noFolder })
        await engine.stop()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func aCamerasEventsReachTheArchiveAndAreThereAfterARestart() async throws {
        let data = try TemporaryDirectory(), recordings = try TemporaryDirectory()
        defer { data.remove(); recordings.remove() }
        let engine = try await Self.engine(directory: data, recordings: recordings.url, policy: Self.policy())
        let camera = EngineFixture.demoCamera(name: "Porch")   // Record off: its events are kept all the same
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await eventually(timeout: archiveStorePatience) { engine.archive.isReady })
        let before = Date()
        await engine.triggerTestMotion(cameraID: camera.id)
        let range = before.addingTimeInterval(-60)..<Date().addingTimeInterval(60)
        var page = ArchiveEventPage(events: [], isTruncated: false)
        #expect(await eventually(timeout: archiveStorePatience) {
            page = (try? await engine.archive.events(cameras: [camera.id], range: range, limit: 10)) ?? page
            return !page.events.isEmpty
        })
        let event = try #require(page.events.first)
        #expect(event.kind == "Motion" && event.camera == camera.id && !event.hadVideo && !event.recorded)
        await engine.stop()
        await engine.start()
        #expect(await eventually(timeout: archiveStorePatience) { engine.archive.isReady })
        let again = try await engine.archive.events(cameras: [camera.id], range: range, limit: 10)
        #expect(again.events.first?.id == event.id, "kept on the drive")
        await engine.stop()
    }
}
#endif
