import BridgeSupport
import Foundation
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

// The Sky Watcher's service (Task 7): one detector per sky camera, one flight history, and the feed polled only while a detector runs; then the
// engine's side: the plugin's switch (Ruling S21) and each camera's, the place and the folder, the status the card reads, the aim kept per
// camera and removed with it. Nothing is downloaded: the feed is a fake at a 192.168.77.x address, the place the made-up one.

/// A flight feed that answers every request with `body`, and remembers what it was asked.
final class SkyFakeFeed: SkyHTTP {
    private let asked = Mutex<[URL]>([])
    let body: Data

    init(_ body: String = SkyFixtures.aircraftJSON) {
        self.body = Data(body.utf8)
    }

    func get(_ url: URL, timeout: Duration, maximumBytes: Int) async throws -> (body: Data, status: Int) {
        asked.withLock { $0.append(url) }
        return (body, 200)
    }

    var requests: [URL] { asked.withLock { $0 } }
}

@Suite(.timeLimit(.minutes(2))) struct SkyServiceTests {
    static let feed = "http://192.168.77.20/tar1090/data/aircraft.json"
    static let place = SkyLocation(latitude: 40.0, longitude: -100.0, heightMeters: 0)
    static let settings = SkySettings(location: place, flightFeedURL: feed)

    static func context(_ id: UUID, folder: URL, name: String = "North Sky") -> SkyCameraDetector.Context {
        SkyCameraDetector.Context(cameraID: id, cameraName: name, settings: SkyDetectorSettings(enabled: true, facing: 330, tilt: 15),
                                  observer: SkyFixtures.observer, zone: SkyDetectorRig.zone, pictureWidth: 4256, pictureHeight: 1888,
                                  folder: { folder }, still: { _ in nil })
    }

    @Test func nothingIsFetchedWhileTheDetectorIsOff() async throws {
        let data = try TemporaryDirectory(), recordings = try TemporaryDirectory()
        defer {
            data.remove()
            recordings.remove()
        }
        let http = SkyFakeFeed()
        let service = SkyService(dataDirectory: data.url, http: http, logStore: SkyLogStore(log: .silent), pollInterval: .milliseconds(50))
        // Every camera off: no request at all.
        #expect(await service.update(settings: Self.settings, cameras: [:]).isEmpty)
        try await Task.sleep(for: .milliseconds(500))
        let idle = await service.isPolling
        #expect(http.requests.isEmpty && !idle)
        // One on: the feed is asked, and its aircraft reach the history.
        let id = UUID()
        let detectors = await service.update(settings: Self.settings, cameras: [id: Self.context(id, folder: recordings.url)])
        let running = await service.detector(id)
        #expect(detectors.keys.sorted() == [id] && running === detectors[id])
        #expect(await eventually { http.requests.count >= 3 })
        #expect(Set(http.requests.map(\.absoluteString)) == [Self.feed])
        #expect(await eventually { await service.flights.aircraftCount == 3 }, "the three usable aircraft of the feed")
        #expect(await service.feedProblem == nil)
        // Off again: nothing after it.
        #expect(await service.update(settings: Self.settings, cameras: [:]).isEmpty)
        let after = http.requests.count
        try await Task.sleep(for: .milliseconds(400))
        let polling = await service.isPolling
        #expect(http.requests.count == after && !polling)
        #expect(await service.detector(id) == nil)
    }

    @Test func theFeedFollowsItsAddressAndNoAddressAsksNothing() async throws {
        let data = try TemporaryDirectory(), recordings = try TemporaryDirectory()
        defer {
            data.remove()
            recordings.remove()
        }
        let http = SkyFakeFeed()
        let service = SkyService(dataDirectory: data.url, http: http, logStore: SkyLogStore(log: .silent), pollInterval: .milliseconds(50))
        let id = UUID(), cameras = [id: Self.context(id, folder: recordings.url)]
        // No feed set: the detector runs and nothing is asked.
        await service.update(settings: SkySettings(location: Self.place), cameras: cameras)
        try await Task.sleep(for: .milliseconds(300))
        let watching = await service.detector(id)
        #expect(http.requests.isEmpty && watching != nil)
        // A feed set, then another: only the latest is asked once it is set.
        await service.update(settings: Self.settings, cameras: cameras)
        #expect(await eventually { !http.requests.isEmpty })
        let other = "http://192.168.77.21:8080/data/aircraft.json"
        await service.update(settings: SkySettings(location: Self.place, flightFeedURL: other), cameras: cameras)
        let moved = http.requests.count
        #expect(await eventually { http.requests.count > moved + 2 })
        #expect(http.requests.suffix(from: moved).allSatisfy { $0.absoluteString == other })
        // The same settings again keep the detector (its state) and the poller.
        let detector = await service.detector(id)
        await service.update(settings: SkySettings(location: Self.place, flightFeedURL: other), cameras: cameras)
        let kept = await service.detector(id)
        #expect(kept === detector)
        await service.stop()
        let stopped = http.requests.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(http.requests.count == stopped)
    }

    @Test func theAimIsKeptWhenTheDetectorIsTurnedOffAndRemovedWithTheCamera() async throws {
        let data = try TemporaryDirectory(), recordings = try TemporaryDirectory()
        defer {
            data.remove()
            recordings.remove()
        }
        let service = SkyService(dataDirectory: data.url, http: SkyFakeFeed(), logStore: SkyLogStore(log: .silent))
        let id = UUID()
        await service.update(settings: SkySettings(location: Self.place), cameras: [id: Self.context(id, folder: recordings.url)])
        let folder = SkyService.directory(of: id, in: data.url)
        #expect(folder.path(percentEncoded: false).hasSuffix("/sky/\(id.uuidString)/"))
        #expect(await eventually { PrivateFiles.exists(folder.appending(path: SkyCameraDetector.stateFileName)) }, "the detector's own state, beside the aim")
        // Turned off: the folder stays.
        await service.update(settings: SkySettings(location: Self.place), cameras: [:])
        #expect(PrivateFiles.exists(folder.appending(path: SkyCameraDetector.stateFileName)))
        // The camera removed: it goes.
        await service.remove(id)
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        // What it keeps names no place.
        await service.update(settings: SkySettings(location: Self.place), cameras: [id: Self.context(id, folder: recordings.url)])
        await service.stop()
        let saved = try String(contentsOf: folder.appending(path: SkyCameraDetector.stateFileName), encoding: .utf8)
        #expect(!saved.contains("40.0") && !saved.contains("100.0") && !saved.contains("latitude"), "\(saved)")
    }
}

#if canImport(Darwin)
import PlatformApple

/// The engine's side (macOS, like the other engine tests): a demo camera whose sky pictures are flat (the fake sky decoder).
@Suite(.serialized) struct SkyEngineTests {
    @MainActor private static func rig(plugin: Bool, enabled: Bool, http: SkyFakeFeed, recordings: TemporaryDirectory)
        async throws -> (fixture: EngineFixture, camera: CameraConfiguration) {
        var tuning = EngineTuning.testing
        tuning.skyHTTP = http
        tuning.skyPollInterval = .milliseconds(100)
        let codecs = SkyFakeCodecs(base: AppleMediaCodecs())
        let folder = recordings.url.path(percentEncoded: false)
        let fixture = try await EngineFixture(tuning: tuning, configure: { settings in
            if plugin { settings.plugins["sky"] = PluginState(enabled: true) }
            settings.sky = SkyServiceTests.settings
            settings.nvrFolder = folder
        }, adjust: { $0.codecs = codecs })
        var camera = EngineFixture.demoCamera(name: "Demo Sky")
        camera.skyDetector = SkyDetectorSettings(enabled: enabled, facing: 330, tilt: 15)
        try await fixture.engine.addCamera(camera, password: nil)
        await fixture.engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        return (fixture, camera)
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func theEngineStartsAndStopsItWithTheSwitch() async throws {
        let recordings = try TemporaryDirectory()
        defer { recordings.remove() }
        let http = SkyFakeFeed()
        let (fixture, added) = try await Self.rig(plugin: true, enabled: false, http: http, recordings: recordings)
        var camera = added
        let runtime = try #require(fixture.engine.runtimes[camera.id])
        try await Task.sleep(for: .milliseconds(400))
        let offStream = await runtime.skyStream
        #expect(fixture.status(camera.id)?.sky == nil && offStream == nil && http.requests.isEmpty, "off: nothing runs")

        camera.skyDetector?.enabled = true
        try await fixture.engine.updateCamera(camera, password: nil)
        #expect(await fixture.waitFor(.seconds(30)) { fixture.status(camera.id)?.sky?.running == true }, "the runtime's pictures reach the detector")
        let sky = try #require(fixture.status(camera.id)?.sky)
        #expect(sky.stream == "main" && sky.analysisWidth == 640 && sky.decoding == "software" && sky.problem == nil, "\(sky)")
        #expect(await fixture.waitFor { fixture.status(camera.id)?.sky?.picturesPerSecond.map { abs($0 - 5) < 0.6 } == true })
        #expect(await runtime.skyStream != nil)
        #expect(await fixture.until { !http.requests.isEmpty }, "the feed is asked while it runs")
        // The log answers with the detector's aim and learning.
        let log = try await fixture.engine.skyNightLog(cameraID: camera.id, night: nil, view: .night)
        #expect(log.aim == fixture.status(camera.id)?.sky?.aim && log.learning == SkyLearning(ready: false, planes: 0, satellites: 0))

        camera.skyDetector?.enabled = false
        try await fixture.engine.updateCamera(camera, password: nil)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.sky == nil })
        #expect(await runtime.skyStream == nil, "the runtime's sky is stopped")
        let after = http.requests.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(http.requests.count == after, "and the feed is not asked any more")
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func nothingRunsOrIsFetchedWhileThePluginIsOff() async throws {
        let recordings = try TemporaryDirectory()
        defer { recordings.remove() }
        let http = SkyFakeFeed()
        let (fixture, camera) = try await Self.rig(plugin: false, enabled: true, http: http, recordings: recordings)
        let runtime = try #require(fixture.engine.runtimes[camera.id])
        try await Task.sleep(for: .milliseconds(600))
        let pluginOffStream = await runtime.skyStream
        #expect(fixture.status(camera.id)?.sky == nil && pluginOffStream == nil && http.requests.isEmpty,
                "the camera's switch is on, but the plugin is off: no detector, no poller, no request")
        #expect(fixture.engine.configurations.first?.skyDetector?.enabled == true, "the camera's sky settings are kept")
        let service = try #require(fixture.engine.skyService)
        let noneAtStart = await service.detector(camera.id), pollingAtStart = await service.isPolling
        #expect(fixture.engine.skyDetectors.isEmpty && noneAtStart == nil && !pollingAtStart, "the start is gated on the plugin")

        // The plugin's switch (Task 8b's `PATCH plugins/sky`) goes through `updateSettings`: off to on starts the cameras set to watch the sky.
        try await fixture.engine.updateSettings { $0.plugins["sky"] = PluginState(enabled: true) }
        let started = await service.detector(camera.id), pollingOn = await service.isPolling
        #expect(fixture.engine.skyDetectors.keys.sorted() == [camera.id] && started != nil && started === fixture.engine.skyDetectors[camera.id] && pollingOn)
        #expect(await fixture.waitFor(.seconds(30)) { fixture.status(camera.id)?.sky?.running == true })
        #expect(await fixture.until { !http.requests.isEmpty })

        // On to off: every detector and the poller stop.
        try await fixture.engine.updateSettings { $0.plugins["sky"] = PluginState(enabled: false) }
        let stopped = await service.detector(camera.id), pollingOff = await service.isPolling
        #expect(fixture.engine.skyDetectors.isEmpty && stopped == nil && !pollingOff)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.sky == nil })
        #expect(await runtime.skyStream == nil)
        let after = http.requests.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(http.requests.count == after)

        // And on again, after a restart of the bridge: the start is the plugin's too.
        try await fixture.engine.updateSettings { $0.plugins["sky"] = PluginState(enabled: true) }
        await fixture.engine.pause()
        let pollingPaused = await service.isPolling
        #expect(fixture.engine.skyDetectors.isEmpty && !pollingPaused, "a paused bridge runs no detector")
        await fixture.engine.resume()
        #expect(await fixture.waitFor(.seconds(30)) { fixture.status(camera.id)?.sky?.running == true })
        #expect(fixture.engine.skyDetectors.keys.sorted() == [camera.id])
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func aClearedPlaceOrFolderStopsTheDetectorAndSaysWhy() async throws {
        let recordings = try TemporaryDirectory()
        defer { recordings.remove() }
        let http = SkyFakeFeed()
        let (fixture, camera) = try await Self.rig(plugin: true, enabled: true, http: http, recordings: recordings)
        let runtime = try #require(fixture.engine.runtimes[camera.id])
        #expect(await fixture.waitFor(.seconds(30)) { fixture.status(camera.id)?.sky?.running == true })

        try await fixture.engine.updateSettings { $0.sky.location = nil }
        #expect(await fixture.waitFor { fixture.status(camera.id)?.sky?.problem == "Set where the box is first." })
        let clearedStream = await runtime.skyStream
        #expect(fixture.status(camera.id)?.sky?.running == false && clearedStream == nil)
        let after = http.requests.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(http.requests.count == after, "a detector that cannot run asks for nothing")

        try await fixture.engine.updateSettings { settings in
            settings.sky.location = SkyServiceTests.place
            settings.nvrFolder = nil
        }
        #expect(await fixture.waitFor { fixture.status(camera.id)?.sky?.problem == "Choose a recordings folder first: the sky log is kept with the recordings." })

        try await fixture.engine.updateSettings { $0.nvrFolder = recordings.url.path(percentEncoded: false) }
        #expect(await fixture.waitFor(.seconds(30)) { fixture.status(camera.id)?.sky?.running == true && fixture.status(camera.id)?.sky?.problem == nil })
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func aRemovedCameraTakesItsAimWithIt() async throws {
        let recordings = try TemporaryDirectory()
        defer { recordings.remove() }
        let (fixture, camera) = try await Self.rig(plugin: true, enabled: true, http: SkyFakeFeed(), recordings: recordings)
        let folder = SkyService.directory(of: camera.id, in: fixture.directory.url)
        #expect(await fixture.until(.seconds(15)) { PrivateFiles.exists(folder.appending(path: SkyCameraDetector.stateFileName)) })
        await fixture.engine.removeCamera(id: camera.id)
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        await fixture.tearDown()
    }
}
#endif
