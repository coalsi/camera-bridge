import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import Synchronization
import Testing
import TestSupport
@testable import BridgeWeb

/// A camera the tests hand frames to by hand: every subscription is a stream they feed, and they see which ones ended.
private final class FakeLiveCamera: Sendable {
    private struct Subscription {
        var feed: AsyncStream<MediaSample>.Continuation
        var cancelled = false
    }

    private let subscriptions = Mutex<[Subscription]>([])

    var opened: Int { subscriptions.withLock { $0.count } }
    var cancelled: Int { subscriptions.withLock { $0.count(where: \.cancelled) } }

    func subscribe(reading stream: LiveVideoStream = .sub) -> LiveVideoSubscription {
        let (samples, feed) = AsyncStream<MediaSample>.makeStream()
        let index = subscriptions.withLock { list in
            list.append(Subscription(feed: feed))
            return list.count - 1
        }
        return LiveVideoSubscription(samples: samples, stream: stream) { [self] in
            subscriptions.withLock { $0[index].cancelled = true }
            feed.finish()
        }
    }

    /// Gives the newest subscription these samples.
    func send(_ samples: [MediaSample]) {
        subscriptions.withLock { list in
            for sample in samples { list.last?.feed.yield(sample) }
        }
    }

    /// The newest subscription ends, as when the camera restarts.
    func endNewest() {
        subscriptions.withLock { $0.last?.feed.finish() }
    }
}

/// Frames of one camera's timeline: 30 per second, a key frame every `keyEvery`.
private struct Frames {
    static let format = VideoFormat.h264(sps: hex("6764001eacb201405ff2e022000003000200000300781e2c5c90"), pps: hex("68ebc3cb22c0"))!
    static let wallClock = Date(timeIntervalSince1970: 1_800_000_000)

    var keyEvery: Int64 = 30
    var next: Int64 = 0

    static func hex(_ text: String) -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    static func video(_ index: Int64, key: Bool) -> EncodedVideoFrame {
        EncodedVideoFrame(format: format, nalUnits: [Data([key ? 0x65 : 0x41, 0x88, 0x84, 0x00, 0x33, UInt8(index & 0xFF)])], isKeyframe: key,
                          pts: MediaTime(value: index * 3000, timescale: 90_000), wallClock: wallClock)
    }

    /// The sound that plays with video frame `index`.
    static func sound(_ index: Int64) -> EncodedAudioFrame {
        EncodedAudioFrame(format: .aacLC(sampleRate: 16_000, channels: 1), data: Data([0x21, 0x10, 0x04, UInt8(index & 0xFF)]),
                          pts: MediaTime(value: index * 16_000 / 30, timescale: 16_000), sampleCount: 1024, wallClock: wallClock)
    }

    /// The next `count` frames.
    mutating func take(_ count: Int64) -> [MediaSample] {
        defer { next += count }
        return (next..<(next + count)).map { .video(Self.video($0, key: $0 % keyEvery == 0)) }
    }
}

/// `GET live` shares its camera loop with the HLS packager: what it sends stays what it was, byte for byte.
@Suite(.timeLimit(.minutes(1))) struct LiveLoopBytesTests {
    private func collected(backlogged: @escaping @Sendable () -> Bool = { false }, _ act: @Sendable (FakeLiveCamera, Box<[Data]>) async -> Void) async {
        let backend = FakeBackend()
        let camera = FakeLiveCamera()
        backend.write { $0.liveAnswer = { _, _, _ in camera.subscribe() } }
        let sent = Box<[Data]>([])
        let pump = Task {
            await WebApp.pumpLiveCamera(id: UUID(), index: 3, stream: .sub, width: nil, backend: backend, send: { data in sent.update { $0.append(data) } },
                                        backlogged: backlogged)
        }
        await act(camera, sent)
        pump.cancel()
        await pump.value
    }

    @Test func aSubscriptionIsSentAsMetaInitAndFramesThenSaysItIsReconnecting() async throws {
        var remuxer = LiveMP4Remuxer()
        var frames = Frames(keyEvery: 5)
        var expected: [Data] = []
        let samples = frames.take(12)
        for case .video(let frame) in samples {
            for part in try remuxer.push(frame) {
                switch part {
                case .initialization(let data, let mime, let width, let height):
                    expected.append(WebApp.liveFrame(.meta, camera: 3, payload: WebApp.liveJSON(["mime": mime, "width": width, "height": height, "stream": "sub"])))
                    expected.append(WebApp.liveFrame(.initialization, camera: 3, payload: data))
                case .media(let data, let keyframe, _):
                    expected.append(WebApp.liveFrame(keyframe ? .keyframe : .delta, camera: 3, payload: data))
                }
            }
        }
        expected.append(WebApp.liveFrame(.status, camera: 3, payload: WebApp.liveJSON(["state": "waiting", "message": "Reconnecting to the camera…"])))
        await collected { [expected] camera, sent in
            #expect(await eventually { camera.opened == 1 })
            camera.send(samples)
            camera.endNewest()
            #expect(await eventually { sent.value.count == expected.count })
            #expect(sent.value == expected)
        }
    }

    @Test func aCameraThatCannotBeReadIsSaidToBeUnavailable() async {
        let backend = FakeBackend()
        let sent = Box<[Data]>([])
        let pump = Task {
            await WebApp.pumpLiveCamera(id: UUID(), index: 1, stream: .main, width: 640, backend: backend, send: { data in sent.update { $0.append(data) } },
                                        backlogged: { false })
        }
        #expect(await eventually { !sent.value.isEmpty })
        pump.cancel()
        await pump.value
        let message = EngineError.cameraNotRunning.description
        #expect(sent.value == [WebApp.liveFrame(.status, camera: 1, payload: WebApp.liveJSON(["state": "unavailable", "message": message]))])
    }

    @Test func aBacklogSkipsToTheNextKeyFrameWithANewInit() async {
        let looks = Box(0)
        let backlogged: @Sendable () -> Bool = {
            looks.update { $0 += 1 }
            return looks.value == 4
        }
        await collected(backlogged: backlogged) { camera, sent in
            #expect(await eventually { camera.opened == 1 })
            var frames = Frames(keyEvery: 5)
            camera.send(frames.take(8))
            #expect(await eventually { sent.value.count == 8 })
            #expect(sent.value.map { $0[0] } == [1, 2, 4, 3, 1, 2, 4, 3], "meta, init, key, delta; the skip; meta, init, key, delta")
        }
    }
}

/// A camera's live video as HLS: one packager per (camera, stream, audio), shared by tickets, that holds one live slot and the subscription and
/// lets both go when nobody is watching any more.
@Suite(.timeLimit(.minutes(1))) struct HLSLiveTests {
    /// The clocks the tests move: the time of day, and the time that passed. Time passing moves both; somebody setting the clock moves only the first.
    private final class Clock: Sendable {
        private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        private let passed = Mutex(ContinuousClock.now)
        var now: Date { time.withLock { $0 } }
        var uptime: ContinuousClock.Instant { passed.withLock { $0 } }

        func advance(_ seconds: Int) {
            step(seconds)
            passed.withLock { $0 = $0.advanced(by: .seconds(seconds)) }
        }

        /// The time of day is set `seconds` forward, or back if negative.
        func step(_ seconds: Int) { time.withLock { $0 = $0.addingTimeInterval(TimeInterval(seconds)) } }
    }

    private struct Bridge {
        var harness: Harness
        var owner: Harness.Session
        var tv: Harness.PairedTV
        var porch: CameraConfiguration
        var camera: FakeLiveCamera
        var clock: Clock

        var app: WebApp { harness.app }

        func key(stream: LiveVideoStream = .sub, audio: Bool = false) -> HLSLivePackager.Key {
            HLSLivePackager.Key(camera: porch.id, stream: stream, audio: audio)
        }

        func packager(_ key: HLSLivePackager.Key? = nil) async -> HLSLivePackager? {
            await app.hlsPackagers.running(key ?? self.key())
        }

        func addCamera(_ name: String, audio: Bool = true) async throws -> CameraConfiguration {
            var camera = CameraConfiguration(name: name, kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.21"), username: "")
            camera.audioEnabled = audio
            try await harness.backend.addCamera(camera, password: nil)
            return camera
        }
    }

    private func makeBridge(liveSlots: Int = 16, firstPlaylistWait: Duration? = nil) async throws -> Bridge {
        let backend = FakeBackend()
        let porch = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "")
        try await backend.addCamera(porch, password: nil)
        let camera = FakeLiveCamera()
        backend.write { $0.liveAnswer = { _, stream, _ in camera.subscribe(reading: stream == .main ? .main : .sub) } }
        let clock = Clock()
        let harness = try Harness(backend: backend) { configuration in
            configuration.now = { clock.now }
            configuration.uptime = { clock.uptime }
            configuration.maximumLiveStreams = liveSlots
            if let firstPlaylistWait { configuration.hlsFirstPlaylistWait = firstPlaylistWait }
        }
        let owner = try await harness.signIn()
        return Bridge(harness: harness, owner: owner, tv: try await harness.pairAppleTV(owner: owner), porch: porch, camera: camera, clock: clock)
    }

    private func mint(_ bridge: Bridge, key: String? = nil, camera: UUID? = nil, stream: String = "sub", audio: Bool = false) async -> Answer {
        let body: [String: Any] = ["camera": (camera ?? bridge.porch.id).uuidString, "kind": "live", "stream": stream, "audio": audio]
        return await bridge.harness.send("POST", "/api/v1/hls/tickets", json: body, headers: [("Authorization", "Bearer \(key ?? bridge.tv.key)")])
    }

    private func ticket(in answer: Answer) throws -> String {
        let url = try #require(answer.json["url"] as? String, "a url: \(answer.text)")
        let parts = url.split(separator: "/").map(String.init)
        return try #require(parts.count == 5 ? parts[3] : nil, "/api/v1/hls/<ticket>/index.m3u8: \(url)")
    }

    private func fetch(_ bridge: Bridge, _ ticket: String, _ file: String = "index.m3u8") async -> Answer {
        await bridge.harness.send("GET", "/api/v1/hls/\(ticket)/\(file)")
    }

    private func slotIsFree(_ bridge: Bridge) -> Bool {
        guard bridge.app.takeLiveSlot() else { return false }
        bridge.app.releaseLiveSlot()
        return true
    }

    /// The segments a media playlist lists, in order.
    private func segments(in playlist: String) -> [String] {
        playlist.split(separator: "\n").map(String.init).filter { $0.hasPrefix("seg-") }
    }

    // MARK: Sharing and slots

    @Test func twoTicketsShareOnePackager() async throws {
        let bridge = try await makeBridge(liveSlots: 1)
        let other = try await bridge.harness.pairAppleTV(owner: bridge.owner, name: "Bedroom", from: "192.0.2.41")
        let first = try ticket(in: await mint(bridge))
        let second = try ticket(in: await mint(bridge, key: other.key))
        #expect(first != second)
        #expect(await eventually { bridge.camera.opened == 1 })
        var frames = Frames()
        bridge.camera.send(frames.take(182))
        let mine = await fetch(bridge, first, "media.m3u8")
        let theirs = await fetch(bridge, second, "media.m3u8")
        #expect(mine.status == 200 && mine.body == theirs.body)
        #expect(bridge.camera.opened == 1 && bridge.harness.backend.read { $0.liveCalls.count } == 1, "one subscription")
        #expect(!bridge.app.takeLiveSlot(), "one slot, which is the only one here")
        #expect((await mint(bridge, stream: "main")).status == 429, "another stream of the camera is another packager")
        #expect((await mint(bridge, audio: true)).status == 429, "and so is the same stream with sound")
    }

    @Test func noSlotMeansTooManyStreams() async throws {
        let bridge = try await makeBridge(liveSlots: 1)
        let garage = try await bridge.addCamera("Garage")
        #expect((await mint(bridge)).status == 200)
        let refused = await mint(bridge, camera: garage.id)
        #expect(refused.status == 429)
        #expect(refused.json["code"] as? String == "too_many_streams")
        #expect(refused.headers["Retry-After"] == "5")
        #expect(await bridge.app.hlsTickets.count(viewer: bridge.tv.id) == 1, "a refused ticket is not held")
        #expect(bridge.camera.opened <= 1)
        let recording = try ArchiveFixture.file(camera: garage.id, segment: "\(garage.id.uuidString)/2026-09-14/13-24-05", startMs: Double(NVRRig.base), fragments: 4)
        bridge.harness.backend.write { $0.archive = FakeArchiveReading([recording]) }
        let recorded: [String: Any] = ["camera": garage.id.uuidString, "kind": "recorded", "from": NVRRig.base, "to": NVRRig.base + 4_000]
        let answer = await bridge.harness.send("POST", "/api/v1/hls/tickets", json: recorded, headers: [("Authorization", "Bearer \(bridge.tv.key)")])
        #expect(answer.status == 200, "a recorded ticket needs no live slot")
    }

    @Test func aPackagerTakesItsSlotFromThePoolOfTheLiveRoutes() async throws {
        let bridge = try await makeBridge(liveSlots: 1)
        #expect((await mint(bridge)).status == 200)
        #expect(await bridge.owner.get("/api/v1/live?cameras=\(bridge.porch.id.uuidString)").status == 429)
    }

    // MARK: Stopping

    @Test func stopsThirtySecondsAfterTheLastRequestAndGivesItsSlotBack() async throws {
        let bridge = try await makeBridge(liveSlots: 1)
        let ticket = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 1 })
        let packager = try #require(await bridge.packager())
        var frames = Frames()
        bridge.camera.send(frames.take(182))
        #expect((await fetch(bridge, ticket, "media.m3u8")).status == 200)

        bridge.clock.advance(29)
        await packager.stopIfIdle()
        #expect(await bridge.packager() != nil, "29 s without a request: it goes on")
        #expect((await fetch(bridge, ticket, "seg-0.m4s")).status == 200, "and a request starts the 30 s again")
        bridge.clock.advance(29)
        await packager.stopIfIdle()
        #expect(await bridge.packager() != nil)
        #expect(!slotIsFree(bridge))

        bridge.clock.advance(1)
        #expect(await eventually { bridge.camera.cancelled == 1 }, "its own watch stops it, and the subscription ends, so an on-demand sub stream can stop")
        #expect(await eventually { slotIsFree(bridge) })
        #expect(await bridge.packager() == nil)
        #expect((await fetch(bridge, ticket, "media.m3u8")).status == 404, "the ticket has no video behind it any more")
        #expect((await fetch(bridge, ticket, "seg-1.m4s")).status == 404)

        #expect((await mint(bridge)).status == 200, "a new ticket starts a new packager")
        #expect(await eventually { bridge.camera.opened == 2 })
    }

    @Test func aCameraWithLongKeyIntervalsIsGivenTwoTargetDurationsOfIdleTime() async throws {
        #expect(HLSLivePackager.idleLimit(targetDuration: nil) == .seconds(30))
        #expect(HLSLivePackager.idleLimit(targetDuration: 6) == .seconds(30))
        #expect(HLSLivePackager.idleLimit(targetDuration: 15) == .seconds(30))
        #expect(HLSLivePackager.idleLimit(targetDuration: 23) == .seconds(46))

        let bridge = try await makeBridge()
        _ = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 1 })
        let packager = try #require(await bridge.packager())
        var frames = Frames(keyEvery: 450)   // a key frame every 15 s: the target is 23 s
        bridge.camera.send(frames.take(460))
        #expect(await eventually { await packager.targetDuration == 23 })
        bridge.clock.advance(40)
        await packager.stopIfIdle()
        #expect(await bridge.packager() != nil, "40 s is past 30 s, but a player reloads once in 23 s")
        bridge.clock.advance(6)
        await packager.stopIfIdle()
        #expect(await bridge.packager() == nil, "46 s is two targets")
    }

    @Test func aMintCountsAsARequest() async throws {
        let bridge = try await makeBridge()
        _ = try ticket(in: await mint(bridge))
        let packager = try #require(await bridge.packager())
        bridge.clock.advance(29)
        #expect((await mint(bridge)).status == 200)
        bridge.clock.advance(29)
        await packager.stopIfIdle()
        #expect(await bridge.packager() === packager)
    }

    /// The step's length would otherwise be how long the slot and an on-demand sub stream stay held after the last player left.
    @Test func aBackwardClockStepDoesNotKeepThePackager() async throws {
        let bridge = try await makeBridge(liveSlots: 1)
        _ = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 1 })
        let packager = try #require(await bridge.packager())
        bridge.clock.step(-3_600)
        bridge.clock.advance(30)
        await packager.stopIfIdle()
        #expect(await bridge.packager() == nil, "30 s passed, whatever the time of day says")
        #expect(await eventually { bridge.camera.cancelled == 1 })
        #expect(slotIsFree(bridge))
    }

    @Test func aForwardClockStepDoesNotStopThePackagerEarly() async throws {
        let bridge = try await makeBridge()
        _ = try ticket(in: await mint(bridge))
        let packager = try #require(await bridge.packager())
        bridge.clock.step(3_600)
        await packager.stopIfIdle()
        #expect(await bridge.packager() != nil, "an hour on the wall, but no time passed")
    }

    @Test func aRequestStillWaitingKeepsThePackager() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticket(in: await mint(bridge))
        let packager = try #require(await bridge.packager())
        let first = Task { await fetch(bridge, ticket) }
        #expect(await eventually { await packager.waitingRequests == 1 })
        bridge.clock.advance(60)
        await packager.stopIfIdle()
        #expect(await bridge.packager() != nil, "the last request has not been answered yet")
        await packager.stop()
        #expect((await first.value).status != 200)
    }

    /// A newer packager numbers from 0 again, so an old ticket reaching it would see the same names with other bytes, which a player may not.
    @Test func aTicketFromAnEarlierPackagerGets404() async throws {
        let bridge = try await makeBridge()
        let old = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 1 })
        var frames = Frames()
        bridge.camera.send(frames.take(182))
        #expect((await fetch(bridge, old, "media.m3u8")).status == 200)
        await (try #require(await bridge.packager())).stop()

        let new = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 2 })
        let packager = try #require(await bridge.packager())
        var restarted = Frames()
        bridge.camera.send(restarted.take(182))
        let current = await fetch(bridge, new, "media.m3u8")
        #expect(current.status == 200 && current.text.contains("#EXT-X-MEDIA-SEQUENCE:0\n"), "\(current.text)")

        for file in ["index.m3u8", "media.m3u8", "init-0.mp4", "seg-0.m4s"] {
            let answer = await fetch(bridge, old, file)
            #expect(answer.status == 404 && answer.body.isEmpty, "\(file)")
            #expect(answer.headers["Cache-Control"] == "no-store")
        }

        bridge.clock.advance(29)
        #expect((await fetch(bridge, old, "media.m3u8")).status == 404)
        bridge.clock.advance(1)
        await packager.stopIfIdle()
        #expect(await bridge.packager() == nil, "an old player's polling keeps nothing running")
    }

    @Test func aStopOnAnyPathGivesTheSlotBackOnce() async throws {
        let bridge = try await makeBridge(liveSlots: 2)
        _ = try ticket(in: await mint(bridge))
        #expect(bridge.app.takeLiveSlot(), "the second slot, held by something else")
        let packager = try #require(await bridge.packager())
        await packager.stop()
        await packager.stop()
        await packager.stopIfIdle()
        bridge.clock.advance(60)
        await packager.stopIfIdle()
        await bridge.app.hlsPackagers.stopAll()
        #expect(bridge.app.takeLiveSlot(), "its slot came back")
        #expect(!bridge.app.takeLiveSlot(), "the other one is still held: the slot came back only once")
    }

    @Test func stoppingTheWebInterfaceStopsThePackagers() async throws {
        let bridge = try await makeBridge(liveSlots: 1)
        _ = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 1 })
        bridge.app.stopEvents()
        #expect(await eventually { bridge.camera.cancelled == 1 })
        #expect(await eventually { slotIsFree(bridge) })
    }

    @Test func aPackagerThatStoppedJustNowIsReplaced() async throws {
        let bridge = try await makeBridge()
        let key = bridge.key()
        let packagers = HLSLivePackagers()
        let made = Box<[HLSLivePackager]>([])
        @Sendable func start(_ onStop: @escaping @Sendable (HLSLivePackager) async -> Void) -> HLSLivePackager? {
            // A stop that has not reached the list yet: it is the moment a mint can find one.
            let packager = HLSLivePackager(key: key, backend: bridge.harness.backend, uptime: { bridge.clock.uptime }, slot: ReleaseOnce {}, onStop: { _ in })
            made.update { $0.append(packager) }
            return packager
        }
        let first = try #require(await packagers.packager(for: key, viewer: "a", start: start))
        await first.stop()
        let second = try #require(await packagers.packager(for: key, viewer: "b", start: start))
        #expect(first !== second && made.value.count == 2)
        #expect(await packagers.running(key) === second)
        await second.stop()
    }

    @Test func removingTheViewerStopsAPackagerNobodyElseUses() async throws {
        let bridge = try await makeBridge(liveSlots: 1)
        let other = try await bridge.harness.pairAppleTV(owner: bridge.owner, name: "Bedroom", from: "192.0.2.41")
        let mine = try ticket(in: await mint(bridge))
        let theirs = try ticket(in: await mint(bridge, key: other.key))
        #expect(await eventually { bridge.camera.opened == 1 })
        var frames = Frames()
        bridge.camera.send(frames.take(182))
        #expect((await fetch(bridge, mine, "media.m3u8")).status == 200)

        #expect(await bridge.owner.send("DELETE", "/api/v1/viewers/\(bridge.tv.id)").status == 204)
        #expect((await fetch(bridge, mine, "media.m3u8")).status == 404)
        #expect(await bridge.packager() != nil, "the other TV still uses it")
        #expect(bridge.camera.cancelled == 0)
        #expect((await fetch(bridge, theirs, "media.m3u8")).status == 200)

        #expect(await bridge.owner.send("DELETE", "/api/v1/viewers/\(other.id)").status == 204)
        #expect((await fetch(bridge, theirs, "media.m3u8")).status == 404)
        #expect(await bridge.packager() == nil, "nobody is left: no 30 s to wait")
        #expect(await eventually { bridge.camera.cancelled == 1 })
        #expect(slotIsFree(bridge))
    }

    @Test func aBrowserSignedOutStopsAPackagerNobodyElseUses() async throws {
        let bridge = try await makeBridge(liveSlots: 1)
        let body: [String: Any] = ["camera": bridge.porch.id.uuidString, "kind": "live"]
        let ticket = try ticket(in: await bridge.owner.send("POST", "/api/v1/hls/tickets", json: body))
        #expect(await bridge.packager() != nil)
        #expect(await bridge.owner.send("POST", "/api/v1/auth/logout").status == 204)
        #expect((await fetch(bridge, ticket, "media.m3u8")).status == 404)
        #expect(await bridge.packager() == nil)
        #expect(slotIsFree(bridge))
    }

    // MARK: The first playlist

    @Test func firstPlaylistWaitsForThreeSegments() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 1 })
        let packager = try #require(await bridge.packager())
        let done = Box(false)
        let asked = ContinuousClock.now
        let first = Task {
            let answer = await fetch(bridge, ticket)
            done.set(true)
            return answer
        }
        var frames = Frames()
        bridge.camera.send(frames.take(122))
        #expect(await eventually { await packager.segment(1) != nil }, "two finished segments")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!done.value, "two are not enough")
        bridge.camera.send(frames.take(60))
        let answer = await first.value
        #expect(answer.status == 200)
        #expect(ContinuousClock.now - asked < .seconds(15), "as soon as the third is out, not when the wait is over")
        #expect(answer.text.hasPrefix("#EXTM3U\n") && answer.text.contains("BANDWIDTH=") && answer.text.contains("CODECS=\"avc1.64001e\""))
        #expect(answer.text.contains("RESOLUTION=") && answer.text.hasSuffix("media.m3u8\n"))
        let media = await fetch(bridge, ticket, "media.m3u8")
        #expect(media.status == 200)
        #expect(segments(in: media.text) == ["seg-0.m4s", "seg-1.m4s", "seg-2.m4s"])
        #expect(media.text.contains("#EXT-X-TARGETDURATION:6\n") && media.text.contains("#EXT-X-MAP:URI=\"init-0.mp4\"\n"))
    }

    /// AVPlayer gives each playlist 20 s of its own (past them the item fails with -12884), and 15 s + 15 s for the two plays, so a camera with long key
    /// intervals spends the master's wait on its three segments and the media playlist's on the rest. The master can be written from one.
    @Test func aMasterOutOfTimeAnswersFromOneSegment() async throws {
        let bridge = try await makeBridge(firstPlaylistWait: .milliseconds(100))
        let ticket = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 1 })
        let packager = try #require(await bridge.packager())
        var frames = Frames()
        bridge.camera.send(frames.take(62))
        #expect(await eventually { await packager.segment(0) != nil }, "one finished segment")
        let asked = ContinuousClock.now
        let index = await fetch(bridge, ticket)
        #expect(ContinuousClock.now - asked >= .milliseconds(100), "it gave the segments its whole wait")
        #expect(index.status == 200)
        #expect(index.text.contains("BANDWIDTH=") && index.text.contains("CODECS=\"avc1.64001e\""), "\(index.text)")
        #expect((await fetch(bridge, ticket, "media.m3u8")).status == 503, "a media playlist does not start a player on one")
    }

    /// Under AVPlayer's own 20 s, or the player has given up by the time the 503 comes.
    @Test func firstPlaylistAnswers503After18Seconds() async throws {
        let directory = URL(fileURLWithPath: "/nonexistent")
        #expect(WebConfiguration(dataDirectory: directory).hlsFirstPlaylistWait == .seconds(18))
        let bridge = try await makeBridge(firstPlaylistWait: .milliseconds(20))
        let ticket = try ticket(in: await mint(bridge))
        var frames = Frames()
        #expect(await eventually { bridge.camera.opened == 1 })
        for file in ["index.m3u8", "media.m3u8"] {
            let answer = await fetch(bridge, ticket, file)
            #expect(answer.status == 503, "\(file)")
            #expect(answer.headers["Retry-After"] == "5")
            #expect(answer.headers["Cache-Control"] == "no-store")
        }
        #expect((await mint(bridge)).status == 200, "and the packager goes on")
        bridge.camera.send(frames.take(182))
        #expect(await eventually { await fetch(bridge, ticket, "media.m3u8").status == 200 })
    }

    @Test func theIdleTimeCountsFromTheAnswerNotTheQuestion() async throws {
        let bridge = try await makeBridge(firstPlaylistWait: .milliseconds(300))
        let ticket = try ticket(in: await mint(bridge))
        let packager = try #require(await bridge.packager())
        let answered = Task { await fetch(bridge, ticket) }
        #expect(await eventually { await packager.waitingRequests == 1 })
        bridge.clock.advance(29)   // the first playlist is still waiting
        #expect((await answered.value).status == 503)
        bridge.clock.advance(29)
        await packager.stopIfIdle()
        #expect(await bridge.packager() != nil)
    }

    @Test func aWaitingPlaylistEndsWhenThePackagerStops() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticket(in: await mint(bridge))
        let packager = try #require(await bridge.packager())
        let first = Task { await fetch(bridge, ticket) }
        try await Task.sleep(for: .milliseconds(50))
        await packager.stop()
        #expect((await first.value).status != 200)
    }

    @Test func aWaitingPlaylistEndsWhenItsRequestIsCancelled() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticket(in: await mint(bridge))
        let asked = ContinuousClock.now
        let first = Task { await fetch(bridge, ticket) }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        #expect((await first.value).status == 503)
        #expect(ContinuousClock.now - asked < .seconds(15), "a server that stops does not wait out the 18 s")
    }

    // MARK: Files

    @Test func filesCarryTheirTypeAndAreNotStored() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 1 })
        var frames = Frames()
        bridge.camera.send(frames.take(182))
        let index = await fetch(bridge, ticket)
        let media = await fetch(bridge, ticket, "media.m3u8")
        let start = await fetch(bridge, ticket, "init-0.mp4")
        let segment = await fetch(bridge, ticket, "seg-1.m4s")
        for answer in [index, media] { #expect(answer.headers["Content-Type"] == "application/vnd.apple.mpegurl") }
        #expect(start.headers["Content-Type"] == "video/mp4")
        #expect(segment.headers["Content-Type"] == "video/iso.segment")
        for answer in [index, media, start, segment] {
            #expect(answer.status == 200 && !answer.body.isEmpty)
            #expect(answer.headers["Cache-Control"] == "no-store")
        }
        #expect(String(decoding: start.body.dropFirst(4).prefix(4), as: UTF8.self) == "ftyp")
        #expect(String(decoding: segment.body.dropFirst(4).prefix(4), as: UTF8.self) == "moof")
    }

    @Test func aFileIsFoundByTheTicketAlone() async throws {
        let bridge = try await makeBridge()
        let garage = try await bridge.addCamera("Garage")
        let garageCamera = FakeLiveCamera()
        let porchCamera = bridge.camera
        bridge.harness.backend.write { $0.liveAnswer = { id, _, _ in (id == garage.id ? garageCamera : porchCamera).subscribe() } }
        let porch = try ticket(in: await mint(bridge))
        let other = try ticket(in: await mint(bridge, camera: garage.id, stream: "main"))
        let packagers = bridge.app.hlsPackagers
        #expect(await packagers.running(HLSLivePackager.Key(camera: garage.id, stream: .main, audio: false)) != nil)
        #expect(await packagers.running(HLSLivePackager.Key(camera: garage.id, stream: .sub, audio: false)) == nil)
        #expect(await eventually { porchCamera.opened == 1 && garageCamera.opened == 1 })
        var frames = Frames()
        garageCamera.send(frames.take(182))
        #expect((await fetch(bridge, other, "media.m3u8")).status == 200)
        #expect((await fetch(bridge, other, "seg-0.m4s")).status == 200)
        #expect((await fetch(bridge, porch, "seg-0.m4s")).status == 404, "the Porch has given no picture")
    }

    @Test func aNumberThatSlidOutIs404() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 1 })
        var frames = Frames()
        bridge.camera.send(frames.take(60 * 8 + 2))
        #expect(await eventually { segments(in: await fetch(bridge, ticket, "media.m3u8").text).first == "seg-2.m4s" })
        #expect((await fetch(bridge, ticket, "seg-0.m4s")).status == 404)
        #expect((await fetch(bridge, ticket, "seg-1.m4s")).status == 404)
        #expect((await fetch(bridge, ticket, "seg-2.m4s")).status == 200)
        #expect((await fetch(bridge, ticket, "seg-7.m4s")).status == 200)
        #expect((await fetch(bridge, ticket, "seg-8.m4s")).status == 404, "not cut yet")
        #expect((await fetch(bridge, ticket, "init-1.mp4")).status == 404)
    }

    @Test func fileNamesAreParsedStrictly() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 1 })
        var frames = Frames()
        bridge.camera.send(frames.take(182))
        #expect((await fetch(bridge, ticket, "media.m3u8")).status == 200)
        for name in ["seg-1.m4s", "init-0.mp4"] { #expect((await fetch(bridge, ticket, name)).status == 200, "\(name)") }
        let bad = ["seg-.m4s", "seg-+1.m4s", "seg--1.m4s", "seg-01.m4s", "seg-1.mp4", "seg-1.m4s.bak", "seg-1", "xseg-1.m4s", "SEG-1.m4s", "seg-1.M4S", "seg-1x.m4s",
                   "seg-99999999999999999999999.m4s", "init-0.m4s", "init-.mp4", "init-00.mp4", "init.mp4", "index", "master.m3u8", "..", "%2e%2e",
                   "seg-%31.m4s", "seg-\u{0661}.m4s"]
        for name in bad {
            let path = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            let answer = await fetch(bridge, ticket, path)
            #expect(answer.status == 404 && answer.body.isEmpty, "\(name)")
        }
        let parsed = ["index.m3u8", "media.m3u8", "init-3.mp4", "seg-12.m4s"].compactMap(HLSFile.init(name:))
        #expect(parsed == [.master, .media, .initSegment(3), .segment(12)])
        #expect(HLSFile(name: "seg-\u{0661}.m4s") == nil && HLSFile(name: "seg-1\u{0301}.m4s") == nil)
    }

    // MARK: Restarts

    @Test func aRestartedSubscriptionAddsADiscontinuity() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticket(in: await mint(bridge))
        #expect(await eventually { bridge.camera.opened == 1 })
        var frames = Frames()
        bridge.camera.send(frames.take(182))
        #expect(segments(in: await fetch(bridge, ticket, "media.m3u8").text) == ["seg-0.m4s", "seg-1.m4s", "seg-2.m4s"])

        bridge.camera.endNewest()
        #expect(await eventually { bridge.camera.opened == 2 }, "the camera restarted: the packager subscribes again")
        var restarted = Frames()   // its timing starts again too
        bridge.camera.send(restarted.take(122))
        #expect(await eventually { await fetch(bridge, ticket, "media.m3u8").text.contains("seg-4.m4s") })
        let media = await fetch(bridge, ticket, "media.m3u8")
        #expect(segments(in: media.text) == ["seg-0.m4s", "seg-1.m4s", "seg-2.m4s", "seg-3.m4s", "seg-4.m4s"], "no number twice: \(media.text)")
        #expect(media.text.contains("seg-2.m4s\n#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init-1.mp4\"\n"), "\(media.text)")
        #expect((await fetch(bridge, ticket, "init-1.mp4")).status == 200)
        #expect((await fetch(bridge, ticket, "init-0.mp4")).status == 200, "still needed by the first three segments")
    }

    /// The loop's own skip (`backlogged`) and what the subscription drops for a slow reader (a jump to a later key frame) both lose frames. Neither
    /// loses the playlist: what is published stays, and the numbers go on.
    @Test func backlogDropsThePacketsNotThePlaylist() async throws {
        let bridge = try await makeBridge()
        let packager = HLSLivePackager(key: bridge.key(), backend: bridge.harness.backend, uptime: { bridge.clock.uptime }, slot: ReleaseOnce {}, onStop: { _ in })
        let backlog = Box(false)
        let looks = Box(0)
        let (id, backend) = (bridge.porch.id, bridge.harness.backend)
        let pump = Task {
            await WebApp.pumpLiveCamera(id: id, stream: .sub, width: nil, audio: false, backend: backend, backlogged: {
                looks.update { $0 += 1 }
                return backlog.value
            }, sink: { await packager.take($0) })
        }
        #expect(await eventually { bridge.camera.opened == 1 })
        var frames = Frames()
        bridge.camera.send(frames.take(182))
        let before = try #require(await packager.playlist(waitingUpTo: .seconds(10)))
        #expect(segments(in: before) == ["seg-0.m4s", "seg-1.m4s", "seg-2.m4s"])

        backlog.set(true)
        let seen = looks.value
        bridge.camera.send(frames.take(90))   // key frames at 210, 240 and 270: looked at, and gone
        #expect(await eventually { looks.value >= seen + 4 })
        #expect(await packager.playlist(waitingUpTo: .zero) == before, "still there, and nothing was cut from the frames that went")

        backlog.set(false)
        bridge.camera.send(frames.take(150))
        #expect(await eventually { await packager.segment(4) != nil })
        let after = try #require(await packager.playlist(waitingUpTo: .zero))
        #expect(segments(in: after).prefix(5) == ["seg-0.m4s", "seg-1.m4s", "seg-2.m4s", "seg-3.m4s", "seg-4.m4s"])
        #expect(after.contains("seg-2.m4s\n#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init-1.mp4\"\n"), "the skip is a new start: \(after)")

        // What the subscription's own queue drops for a slow reader: the next thing read is a later key frame.
        frames.next = (frames.next / 30 + 100) * 30
        bridge.camera.send(frames.take(122))
        #expect(await eventually { await packager.segment(6) != nil })
        let jumped = try #require(await packager.playlist(waitingUpTo: .zero))
        #expect(segments(in: jumped).contains("seg-6.m4s"))
        pump.cancel()
        await packager.stop()
    }

    // MARK: Sound

    @Test func audioFalseHasNoAudioTrack() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticket(in: await mint(bridge, audio: false))
        #expect(await eventually { bridge.camera.opened == 1 })
        #expect(bridge.harness.backend.read { $0.liveCalls.last?.audio } == false)
        var frames = Frames()
        for sample in frames.take(182) {
            bridge.camera.send([sample, .audio(Frames.sound(frames.next))])
        }
        let index = await fetch(bridge, ticket)
        #expect(index.status == 200)
        #expect(index.text.contains("CODECS=\"avc1.64001e\""), "\(index.text)")
        let media = await fetch(bridge, ticket, "media.m3u8")
        #expect(!media.text.contains("#EXT-X-DISCONTINUITY\n"), "\(media.text)")
        #expect(media.text.contains("init-0.mp4"))
    }

    /// Live begins without its sound and starts again with it at the next key frame. Nothing was out yet, so the player only ever sees the second start.
    @Test func soundThatStartsLateReplacesAnInitNobodySaw() async throws {
        let bridge = try await makeBridge()
        let ticket = try ticket(in: await mint(bridge, audio: true))
        #expect(await eventually { bridge.camera.opened == 1 })
        #expect(bridge.harness.backend.read { $0.liveCalls.last?.audio } == true)
        var frames = Frames()
        bridge.camera.send(frames.take(10))
        for start in stride(from: Int64(10), to: 212, by: 2) {
            bridge.camera.send([.audio(Frames.sound(start))] + frames.take(2))
        }
        let index = await fetch(bridge, ticket)
        #expect(index.status == 200)
        #expect(index.text.contains(",mp4a.40.2\""), "\(index.text)")
        let media = await fetch(bridge, ticket, "media.m3u8")
        #expect(media.status == 200)
        #expect(!media.text.contains("#EXT-X-DISCONTINUITY\n"), "\(media.text)")
        #expect(media.text.contains("#EXT-X-MAP:URI=\"init-0.mp4\"\n") && !media.text.contains("init-1.mp4"), "\(media.text)")
    }

    /// The "Camera audio" switch is the owner's word on whether a camera is heard, whatever a ticket asks for.
    @Test func aCameraWithItsSoundOffIsNotHeardWhateverTheTicketAsks() async throws {
        let bridge = try await makeBridge(liveSlots: 1)
        let quiet = try await bridge.addCamera("Garage", audio: false)
        let asked = try ticket(in: await mint(bridge, camera: quiet.id, audio: true))
        #expect(await eventually { bridge.camera.opened == 1 })
        #expect(bridge.harness.backend.read { $0.liveCalls.last?.audio } == false)
        let held = await bridge.app.hlsTickets.touch(asked, now: bridge.clock.now)
        #expect(held?.kind == .live(stream: .sub, audio: false))
        #expect((await mint(bridge, camera: quiet.id, audio: false)).status == 200, "the same packager as a ticket without sound")
    }
}
