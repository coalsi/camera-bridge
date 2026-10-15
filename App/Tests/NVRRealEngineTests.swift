import BridgeEngine
import CameraAdapters
import Foundation
import MediaCore
import Synchronization
import Testing

/// What the player's cell does to its sink, in order, with the instants of the recorded frames it shows.
nonisolated final class RecordedSink: ArchiveVideoSink, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case reset
        case clear
        case shown(wall: Date, keyframe: Bool)
        case primed(keyframe: Bool)
    }

    private let log = Mutex<[Event]>([])

    func show(_ frame: EncodedVideoFrame) { show(frame, decodeOnly: false) }

    func show(_ frame: EncodedVideoFrame, decodeOnly: Bool) {
        log.withLock { $0.append(decodeOnly ? .primed(keyframe: frame.isKeyframe) : .shown(wall: frame.wallClock, keyframe: frame.isKeyframe)) }
    }

    func play(_ frame: EncodedAudioFrame) {}
    func reset() { log.withLock { $0.append(.reset) } }
    func silence() {}
    func clear() { log.withLock { $0.append(.clear) } }
    var queued: Int { 0 }
    var restarts: Int { 0 }

    var events: [Event] { log.withLock { $0 } }
    var shownWalls: [Date] { events.compactMap { if case .shown(let wall, _) = $0 { wall } else { nil } } }

    /// After every reset or clear, the next picture handed over (displayable or not) is a keyframe: the decoder never sees a delta frame whose reference it lacks.
    var firstFrameAfterEveryResetIsAKeyframe: Bool {
        var needsKeyframe = true
        for event in events {
            switch event {
            case .reset, .clear: needsKeyframe = true
            case .shown(_, let keyframe), .primed(let keyframe):
                if needsKeyframe && !keyframe { return false }
                needsKeyframe = false
            }
        }
        return true
    }
}

/// A real engine on `BridgeEnvironment.testing` (loopback, in-memory secrets, no Bonjour) with an `ArchivePlatformPolicy` that reports plenty of space on
/// every volume: the engine's default for the Mac measures the real volume, and on a Mac whose startup volume is nearly full (the floor is 10 % of it)
/// every test would pause with `diskFull` before it recorded anything. The free-space rules have their own tests in the package. The demo cameras
/// get HAP ports away from the installed app, Scrypted and Homebridge (22000...28000, as `LiveEngineFixture.withCameras`).
@MainActor
final class NVRFixture {
    static let roomyPolicy = ArchivePlatformPolicy(space: { _ in (total: 2_000_000_000_000, free: 1_000_000_000_000) }, isSystemVolume: { _ in false },
                                                   systemFloor: { _ in 0 }, directoryNaming: .cameraName)

    let directory: URL
    let root: URL
    let scratch = ScratchDefaults()
    let engine: BridgeEngine
    let model: AppModel

    init(cameras: [CameraConfiguration]) async throws {
        let unique = UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appending(path: "T18-data-\(unique)", directoryHint: .isDirectory)
        root = FileManager.default.temporaryDirectory.appending(path: "T18-recordings-\(unique)", directoryHint: .isDirectory)
        for url in [directory, root] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }   // the engine never creates the folder
        let seed = BridgeEngine(environment: .testing(directory: directory))
        var settings = seed.settings
        settings.basePort = UInt16.random(in: 22_000...28_000)
        settings.sensorsBridgePort = 0
        settings.webhookPort = 0
        try await seed.updateSettings(settings)
        for camera in cameras { try await seed.addCamera(camera, password: nil) }
        engine = BridgeEngine(environment: Self.environment(directory))
        scratch.defaults.set(true, forKey: AppModel.onboardingCompletedKey)
        model = AppModel(options: LaunchOptions(), engine: engine, loginItems: InMemoryLoginItemService(), defaults: scratch.defaults, previewLatency: .zero)
    }

    static func environment(_ directory: URL) -> BridgeEnvironment {
        var environment = BridgeEnvironment.testing(directory: directory)
        environment.archivePolicy = roomyPolicy
        return environment
    }

    func tearDown() async {
        await model.prepareToTerminate()
        await engine.stop()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: root)
    }
}

/// The app and the engine together, for real: the demo camera records through `AppModel`, the archive reads it back, the player plays it, a
/// vanished folder is reported and recovers, a relaunch finds the footage. Each test runs a real engine on `BridgeEnvironment.testing` (loopback, in-memory
/// secrets, no Bonjour) with the demo camera, which encodes 1080p30 H.264 with a keyframe every 2 s, so a test takes tens of seconds.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4))) struct NVRRealEngineTests {
    private func demoCamera() -> CameraConfiguration {
        CameraConfiguration(name: "Soak 1", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
    }

    private func files(under root: URL, extension ext: String) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == ext }
    }

    private func recordedSeconds(_ engine: BridgeEngine, _ id: UUID) -> TimeInterval {
        engine.archive.extent(camera: id).map { $0.newest.timeIntervalSince($0.oldest) } ?? 0
    }

    /// Record on with the folder chosen through the app's picker, until `seconds` of footage exist.
    private func startRecording(_ fixture: NVRFixture, camera: CameraConfiguration, seconds: TimeInterval) async -> Bool {
        let root = fixture.root
        fixture.model.nvrFolderPicker = { root }
        await fixture.engine.start()
        await fixture.model.setNVRRecording(true, camera: camera.id)
        let recording = await settles(timeout: .seconds(40), every: .milliseconds(100)) { fixture.engine.cameras.first { $0.id == camera.id }?.nvr.state == .recording }
        guard recording else { return false }
        return await settles(timeout: .seconds(60), every: .milliseconds(100)) { recordedSeconds(fixture.engine, camera.id) >= seconds }
    }

    @Test func recordingFromTheAppWritesFilesAndAReadableArchive() async throws {
        let camera = demoCamera()
        let fixture = try await NVRFixture(cameras: [camera])
        let root = fixture.root
        #expect(await startRecording(fixture, camera: camera, seconds: 8))
        let engine = fixture.engine
        #expect(engine.settings.nvrFolder == root.path, "the first Record asked for the folder and saved it")
        #expect(engine.configurations.first?.nvrEnabled == true)
        #expect(files(under: root, extension: "mp4").count >= 1)

        // The archive answers for a time inside the footage, and its bytes are what the index says.
        let extent = try #require(engine.archive.extent(camera: camera.id))
        let middle = extent.oldest.addingTimeInterval(extent.newest.timeIntervalSince(extent.oldest) / 2)
        let fragment = try #require(await engine.archive.fragment(camera: camera.id, containing: middle))
        #expect(fragment.start <= middle && middle < fragment.end)
        let key = try #require(await engine.archive.fragment(camera: camera.id, containing: fragment.gopStart))
        #expect(key.hasKeyframe && key.backToKey == 0)
        let keyBytes = try await engine.archive.read(key, .keyframe)
        #expect(keyBytes.count > 1_000, "one keyframe of a 1080p picture")
        let bytes = try await engine.archive.read(fragment, .fragment)
        #expect(bytes.count == fragment.byteLength)

        // Record off closes the file: the sidecar appears, and it says how big the mp4 is.
        await fixture.model.setNVRRecording(false, camera: camera.id)
        #expect(await settles(timeout: .seconds(10), every: .milliseconds(100)) { !files(under: root, extension: "cbidx").isEmpty })
        let sidecar = try #require(files(under: root, extension: "cbidx").first)
        let index = try Data(contentsOf: sidecar)
        #expect(Array(index.prefix(4)) == Array("CBNX".utf8))
        let mp4 = sidecar.deletingPathExtension().appendingPathExtension("mp4")
        let size = (try FileManager.default.attributesOfItem(atPath: mp4.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let recorded = index[40..<48].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }   // mp4Size, big-endian
        #expect(recorded == size && size > 0)
        let manifest = root.appending(path: "Soak 1/camera.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: String])
        #expect(json["id"] == camera.id.uuidString && json["name"] == "Soak 1")
        await fixture.tearDown()
    }

    @Test func thePlayerShowsWhatTheEngineRecorded() async throws {
        let camera = demoCamera()
        let fixture = try await NVRFixture(cameras: [camera])
        #expect(await startRecording(fixture, camera: camera, seconds: 14))
        await fixture.model.setNVRRecording(false, camera: camera.id)
        let engine = fixture.engine
        let extent = try #require(engine.archive.extent(camera: camera.id))
        let target = extent.oldest.addingTimeInterval(3.2)   // inside the footage and far from now: releasing there plays, it does not go live

        let sink = RecordedSink()
        let session = NVRSession(archive: engine.archive, clock: PlaybackClock(), makeSink: { sink }, now: { ProcessInfo.processInfo.systemUptime },
                                 sleep: { until in
                                     let delay = until - ProcessInfo.processInfo.systemUptime
                                     if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                                 })
        session.setCameras([camera.id])
        session.beginScrub()
        session.scrub(to: target)
        // The exact still: the last frame at or before the target, within one frame (1/30 s) of it.
        let exact = await settles(timeout: .seconds(10), every: .milliseconds(20)) {
            sink.shownWalls.contains { target.timeIntervalSince($0) >= -0.001 && target.timeIntervalSince($0) <= 1.0 / 30 + 0.012 }
        }
        #expect(exact, "no frame within one frame interval of the target: \(sink.shownWalls.suffix(5).map { target.timeIntervalSince($0) })")
        #expect(sink.firstFrameAfterEveryResetIsAKeyframe)
        #expect(sink.events.contains(.reset), "a jump into another GOP resets the sink")

        // Release: it plays at one picture per frame, in order.
        let before = sink.shownWalls.count
        session.endScrub()
        try await Task.sleep(for: .seconds(2.5))
        let played = Array(sink.shownWalls.dropFirst(before))
        #expect((50...80).contains(played.count), "30 pictures a second for about 2.4 s: \(played.count)")
        #expect(zip(played, played.dropFirst()).allSatisfy { $0 < $1 }, "pictures arrive in recorded order")
        #expect(sink.firstFrameAfterEveryResetIsAKeyframe)
        session.pause()
        session.setCameras([])
        await fixture.tearDown()
    }

    @Test func aRelaunchOnTheSameFolderFindsTheFootageAgain() async throws {
        let camera = demoCamera()
        let fixture = try await NVRFixture(cameras: [camera])
        let root = fixture.root
        #expect(await startRecording(fixture, camera: camera, seconds: 8))
        let before = try #require(fixture.engine.archive.extent(camera: camera.id))
        await fixture.engine.stop()   // closes the file within 3 s and the store with it

        let second = BridgeEngine(environment: NVRFixture.environment(fixture.directory))
        await second.start()
        #expect(await settles(timeout: .seconds(40), every: .milliseconds(100)) { second.archive.isReady }, "the catalog loads in the background after the engine is running")
        let after = try #require(second.archive.extent(camera: camera.id))
        #expect(abs(after.oldest.timeIntervalSince(before.oldest)) < 0.002, "the same oldest footage")
        #expect(after.newest >= before.newest.addingTimeInterval(-0.002), "the footage is all still there")
        #expect(second.configurations.first?.nvrEnabled == true && second.settings.nvrFolder == root.path, "Record and the folder survive the relaunch")
        await second.stop()
        await fixture.tearDown()
    }

    @Test func aFolderThatVanishesIsReportedAndRecordingComesBackWhenItReturns() async throws {
        let camera = demoCamera()
        let fixture = try await NVRFixture(cameras: [camera])
        let root = fixture.root
        let gone = root.deletingLastPathComponent().appending(path: "T18-gone-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: gone) }
        #expect(await startRecording(fixture, camera: camera, seconds: 6))
        let model = fixture.model, engine = fixture.engine
        let newestBefore = try #require(engine.archive.extent(camera: camera.id)).newest

        try FileManager.default.moveItem(at: root, to: gone)   // a drive that was pulled
        #expect(await settles(timeout: .seconds(20), every: .milliseconds(100)) { engine.cameras.first?.nvr.state == .paused(.folderMissing) },
                "state: \(String(describing: engine.cameras.first?.nvr.state))")
        #expect(model.bridgeIssue == .nvrStorage(.folderMissing), "the manager shows the banner and the menu bar the warning")
        #expect(engine.nvrStorage?.pause == .folderMissing)

        try FileManager.default.moveItem(at: gone, to: root)   // plugged in again
        #expect(await settles(timeout: .seconds(40), every: .milliseconds(100)) { engine.cameras.first?.nvr.state == .recording }, "recording resumes by itself")
        #expect(model.bridgeIssue == nil)
        #expect(await settles(timeout: .seconds(20), every: .milliseconds(100)) { (engine.archive.extent(camera: camera.id)?.newest ?? .distantPast) > newestBefore.addingTimeInterval(3) },
                "new footage after the gap")
        await fixture.tearDown()
    }

    @Test func theLimitsAreSavedAndWrongOnesAreRefused() async throws {
        let fixture = try await NVRFixture(cameras: [])
        let model = fixture.model
        #expect(await model.updateSettings { $0.nvrKeepDays = 3; $0.nvrMaxSizeGB = 100 })
        #expect(fixture.engine.settings.nvrKeepDays == 3 && fixture.engine.settings.nvrMaxSizeGB == 100)
        let saved = BridgeEngine(environment: NVRFixture.environment(fixture.directory)).settings
        #expect(saved.nvrKeepDays == 3 && saved.nvrMaxSizeGB == 100, "in config.json")
        #expect(await model.updateSettings { $0.nvrKeepDays = 0 } == false, "the engine refuses zero days")
        #expect(model.message != nil)
        #expect(await model.updateSettings { $0.nvrMaxSizeGB = 5 } == false)
        #expect(await model.updateSettings { $0.nvrFolder = "relative/path" } == false, "a folder must be a full path")
        #expect(fixture.engine.settings.nvrKeepDays == 3 && fixture.engine.settings.nvrMaxSizeGB == 100 && fixture.engine.settings.nvrFolder == nil)
        await fixture.tearDown()
    }
}
