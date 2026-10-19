import BridgeSupport
import Foundation
import HAPCamera
@testable import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// The pictures an AI description is made from (AI descriptions plan, Task 4, and its review): gathered when the event starts as encoded data
/// (up to two keyframes from before it out of the live ring, the event picture's source, up to two keyframes after it), and made later, one
/// set at a time, each a JPEG at most 768 px wide at quality 0.7, off the cooperative pool. Home's own snapshots are never touched.
@Suite(.timeLimit(.minutes(1))) struct EventPicturesTests {
    static let log = Log(category: "EventPicturesTest")

    /// Codecs whose pictures say what they are: a decoded frame keeps its presentation time (in these tests its seconds from the event), and its
    /// JPEG reads "<seconds> s, <maxWidth> wide, quality <quality>"; the camera's own JPEG reads "camera", "camera, <maxWidth> wide" once Home
    /// resized it, and "camera, <maxWidth> wide, quality <quality>" once resized for a description.
    final class PictureCodecs: MediaCodecs {
        /// Frames decoded, by every decoder made.
        let decodes = Box(0)
        /// For each JPEG encode or resize: whether it ran inside a Swift task (on the cooperative pool) rather than on a thread of its own.
        let encodedInTask = Box<[Bool]>([])
        /// The decode at which the decoding task cancels itself (cancellation tests).
        let cancelAtDecode = Box<Int?>(nil)

        struct Picture: DecodedVideoFrame {
            var width = 1920
            var height = 1080
            var pts: MediaTime
            func grayThumbnail(maxWidth: Int) -> GrayImage? { nil }
        }

        final class Decoder: VideoDecoding {
            let owner: PictureCodecs
            init(owner: PictureCodecs) { self.owner = owner }
            func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
                let count = owner.decodes.update { count -> Int in
                    count += 1
                    return count
                }
                if count == owner.cancelAtDecode.value { withUnsafeCurrentTask { $0?.cancel() } }
                return Picture(pts: frame.pts)
            }
            func invalidate() {}
        }

        static func jpeg(_ text: String) -> Data { Data([0xFF, 0xD8]) + Data(text.utf8) }

        private func noteEncode() { encodedInTask.update { $0.append(withUnsafeCurrentTask { $0 != nil }) } }
        private static func width(_ maxWidth: Int?) -> String { maxWidth.map(String.init) ?? "any" }

        func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { Decoder(owner: self) }
        func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { throw MediaCodecError.unsupported("test") }
        func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { throw MediaCodecError.unsupported("test") }
        func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding { throw MediaCodecError.unsupported("test") }
        func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
            noteEncode()
            return Self.jpeg("\(frame.pts.seconds) s, \(Self.width(maxWidth)) wide, quality \(quality)")
        }
        func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data {
            noteEncode()
            return jpeg + Data(", \(Self.width(maxWidth)) wide".utf8)
        }
        func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
            noteEncode()
            return jpeg + Data(", \(Self.width(maxWidth)) wide, quality \(quality)".utf8)
        }
        func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] { [] }
        func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration,
                                 audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource { fatalError("unused") }
    }

    /// What the camera's snapshot API does.
    enum CameraAPI {
        case none
        case answers(after: Duration)
        case fails
    }

    /// A camera's main stream as its hub sees it: frames sent at once, each with its time on the bridge's clock (seconds from the event, which
    /// is when the camera was made: the camera's JPEG is stamped on the bridge's real clock) and stamped with the camera's clock, `clockBehind`
    /// seconds slow.
    final class Camera: Sendable {
        let event = Date()
        let hub: MediaHub
        let codecs = PictureCodecs()
        let apiCalls = Box(0)
        let offline = Box(false)
        /// The bridge's clock as the hub reads it: the moment the frame being sent arrives.
        private let wall: Box<Date>
        private let clockBehind: Double

        init(clockBehind: Double = 0) {
            self.clockBehind = clockBehind
            let wall = Box(event)
            self.wall = wall
            hub = MediaHub(now: { .now }, wallNow: { wall.value })
        }

        private func deliver(_ frame: (seconds: Double, keyframe: Bool, bytes: Int, pts: MediaTime)) async {
            let now = event.addingTimeInterval(frame.seconds)
            wall.set(now)
            await hub.ingest(.video(EncodedVideoFrame(format: VideoFormat(codec: .h264, width: 1920, height: 1080, parameterSets: []),
                                                      nalUnits: [Data([frame.keyframe ? 0x65 : 0x41]) + Data(count: max(0, frame.bytes - 1))],
                                                      isKeyframe: frame.keyframe, pts: frame.pts, wallClock: now.addingTimeInterval(-clockBehind))))
        }

        /// Keyframes only.
        func send(_ seconds: Double...) async {
            for second in seconds { await deliver((second, true, 2, MediaTime.seconds(second))) }
        }

        /// A keyframe at `start` and `frames` − 1 frames after it, `fps` a second, each `bytes` long, presentation time = their index.
        func sendGOP(from start: Double, frames: Int, fps: Double, bytes: Int) async {
            for index in 0..<frames { await deliver((start + Double(index) / fps, index == 0, bytes, MediaTime.seconds(Double(index)))) }
        }

        /// Home's snapshot provider for this camera (the codecs' own pool, everything inline as for Home).
        func provider(_ api: CameraAPI) -> SnapshotProvider {
            let calls = apiCalls, offline = offline
            var fetch: SnapshotProvider.CameraSnapshot?
            switch api {
            case .none: fetch = nil
            case .answers(let delay):
                fetch = { @Sendable in
                    calls.update { $0 += 1 }
                    try await Task.sleep(for: delay)
                    return PictureCodecs.jpeg("camera")
                }
            case .fails:
                fetch = { @Sendable in
                    calls.update { $0 += 1 }
                    throw TransportError.timedOut
                }
            }
            return SnapshotProvider(cameraSnapshot: fetch, codecs: codecs, hub: hub, log: EventPicturesTests.log, isOffline: { offline.value })
        }

        func gather(_ provider: SnapshotProvider, afterWait: Duration = .seconds(1)) async -> EventFrames {
            await EventPictures(hub: hub, snapshots: provider, afterWait: afterWait).gather(at: event)
        }

        /// The pool the runtime makes for the pictures: its JPEG work off the cooperative pool.
        func decoders() -> SnapshotDecoderPool {
            SnapshotDecoderPool(codecs: codecs, idleLifetime: EventPictures.decoderIdleLifetime, blockingWork: SnapshotDecoderPool.offCooperativePool)
        }

        /// "<label>: <what the fake JPEG says>" of each picture.
        func pictures(_ frames: EventFrames) async -> [String] {
            await frames.pictures(decoders: decoders(), log: EventPicturesTests.log).map(EventPicturesTests.describe)
        }
    }

    static func describe(_ picture: LabeledPicture) -> String {
        "\(picture.label): \(text(picture.jpeg))"
    }

    static func text(_ jpeg: Data) -> String { String(decoding: jpeg.dropFirst(2), as: UTF8.self) }

    @Test func picturesAroundAnEventAreLabelledInTimeOrder() async {
        let camera = Camera()
        await camera.send(-5, -4, -3, -2, -1, 0)
        let provider = camera.provider(.answers(after: .zero))
        let gathering = Task { await camera.gather(provider, afterWait: .seconds(5)) }
        // The ones after the event arrive while it waits for them.
        #expect(await eventually { await camera.hub.subscriberCount == 1 })
        await camera.send(1, 2, 3, 4, 5)
        let frames = await gathering.value
        #expect(await camera.hub.subscriberCount == 0, "the wait for the keyframes after the event ended with them")
        #expect(camera.codecs.decodes.value == 0 && camera.codecs.encodedInTask.value.isEmpty, "gathering decodes and encodes nothing")
        #expect(await camera.pictures(frames) == [
            "4 s before: -4.0 s, 768 wide, quality 0.7",
            "2 s before: -2.0 s, 768 wide, quality 0.7",
            "At the event: camera, 768 wide, quality 0.7",
            "2 s after: 2.0 s, 768 wide, quality 0.7",
            "4 s after: 4.0 s, 768 wide, quality 0.7",
        ])
        #expect(camera.codecs.encodedInTask.value == [false, false, false, false, false], "every JPEG was made off the cooperative pool")
    }

    /// A camera that streams on demand has nothing in its ring when the event starts: the event picture is the first keyframe of the woken
    /// stream, and the ones after it come as they arrive.
    @Test func anEmptyRingGivesOnlyEventAndAfterPictures() async {
        let camera = Camera()
        let started = ContinuousClock.now
        let gathering = Task { await camera.gather(camera.provider(.none), afterWait: .seconds(5)) }
        #expect(await eventually { await camera.hub.subscriberCount == 1 })
        await camera.send(0.5, 2.5, 4.5)
        let frames = await gathering.value
        #expect(ContinuousClock.now - started < .seconds(4), "the wait ended at the keyframe 4 s after the event, not at its limit")
        #expect(await camera.pictures(frames) == [
            "At the event: 0.5 s, 768 wide, quality 0.7",
            "2 s after: 2.5 s, 768 wide, quality 0.7",
            "4 s after: 4.5 s, 768 wide, quality 0.7",
        ])
    }

    @Test func aCameraThatStopsSendingStillAnswersWithinSixSeconds() async {
        let camera = Camera()
        let provider = camera.provider(.none)
        #expect(EventPictures(hub: camera.hub, snapshots: provider).afterWait == .seconds(6))
        await camera.send(0)
        let started = ContinuousClock.now
        let frames = await camera.gather(provider, afterWait: .seconds(1))
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .seconds(1) && elapsed < .seconds(2), "\(elapsed)")
        #expect(await camera.hub.subscriberCount == 0)
        #expect(await camera.pictures(frames) == ["At the event: 0.0 s, 768 wide, quality 0.7"])
    }

    /// A keyframe is used once: with a keyframe every 3 s, the one 3 s before the event is as near 4 s before as 2 s before, and is the "2 s
    /// before" picture alone (the moment nearer the event wins a tie); so with the one 3 s after it.
    @Test func eachKeyframeIsUsedOnceForTheMomentItIsNearer() async {
        let camera = Camera()
        await camera.send(-6, -3, 0, 3, 6)
        #expect(await camera.pictures(await camera.gather(camera.provider(.answers(after: .zero)))) == [
            "2 s before: -3.0 s, 768 wide, quality 0.7",
            "At the event: camera, 768 wide, quality 0.7",
            "2 s after: 3.0 s, 768 wide, quality 0.7",
        ])
    }

    /// A keyframe more than 1.5 s from 4 s or 2 s before or after the event is no picture of that moment.
    @Test func keyframesFarFromTheirMomentsAreLeftOut() async {
        let camera = Camera()
        await camera.send(-11.9, -0.05, 0.2, 6)
        #expect(await camera.pictures(await camera.gather(camera.provider(.answers(after: .zero)))) == ["At the event: camera, 768 wide, quality 0.7"])
    }

    /// An RTSP camera's frames carry its own clock: one running 3 s slow still gets the pictures of 4 s and 2 s before and after the event on
    /// the bridge's clock (the frames' wall clock plus the hub's measured offset, as the recordings place them).
    @Test func aCameraClockRunningSlowIsCorrectedByTheHubsOffset() async {
        let camera = Camera(clockBehind: 3)
        await camera.send(-6, -4, -2, 0, 2, 4)
        #expect(await camera.pictures(await camera.gather(camera.provider(.answers(after: .zero)))) == [
            "4 s before: -4.0 s, 768 wide, quality 0.7",
            "2 s before: -2.0 s, 768 wide, quality 0.7",
            "At the event: camera, 768 wide, quality 0.7",
            "2 s after: 2.0 s, 768 wide, quality 0.7",
            "4 s after: 4.0 s, 768 wide, quality 0.7",
        ])
    }

    /// Home asks for an event snapshot at the moment the event's pictures are gathered: one fetch from the camera serves both, Home's picture
    /// is what it would have been and comes as soon as the camera answers, and without a snapshot API only Home's snapshot decodes anything.
    @Test func homesEventSnapshotAtTheSameMomentIsNeitherChangedNorDelayed() async throws {
        let camera = Camera()
        await camera.send(0)
        let provider = camera.provider(.answers(after: .milliseconds(300)))
        let started = ContinuousClock.now
        let gathering = Task { await camera.gather(provider, afterWait: .seconds(1)) }
        let home = try await provider.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .event))
        let homeTook = ContinuousClock.now - started
        #expect(Self.text(home) == "camera, 1280 wide")
        #expect(homeTook < .seconds(1.5), "Home waited \(homeTook)")
        let frames = await gathering.value
        #expect(camera.apiCalls.value == 1, "one fetch for both")
        guard case .cameraJPEG(let jpeg, _) = frames.event else { Issue.record("no camera JPEG"); return }
        #expect(Self.text(jpeg) == "camera", "the camera's JPEG as it sent it")

        let streamOnly = Camera()
        await streamOnly.sendGOP(from: -0.5, frames: 10, fps: 20, bytes: 100)
        let decoding = streamOnly.provider(.none)
        let both = Task { await streamOnly.gather(decoding, afterWait: .milliseconds(500)) }
        let picture = try await decoding.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        _ = await both.value
        #expect(Self.text(picture) == "9.0 s, 640 wide, quality 0.8", "Home's picture of the newest frame")
        #expect(streamOnly.codecs.decodes.value == 10, "Home's decoder alone decoded, and only Home's snapshot")
    }

    /// The event picture's wait is the AI's own: a fetch it starts runs with Home's own limit for an event snapshot (3 s), so Home, joining it,
    /// still gets the camera's picture when the camera answers after the AI stopped waiting, and the camera's API is not counted as failing.
    @Test func theAIsShortWaitNeverShortensHomesFetch() async throws {
        let camera = Camera()
        await camera.send(0)
        let provider = camera.provider(.answers(after: .milliseconds(1_500)))
        // The event began 2 s before the gather: the AI waits at most 1 s more for the camera's picture.
        let gathering = Task { await EventPictures(hub: camera.hub, snapshots: provider, afterWait: .milliseconds(300)).gather(at: Date().addingTimeInterval(-2)) }
        #expect(await eventually { camera.apiCalls.value == 1 })
        let home = try await provider.snapshot(SnapshotRequest(width: 1280, height: 720, reason: .event))
        #expect(Self.text(home) == "camera, 1280 wide", "Home joined the fetch and had the camera's picture within its own 3 s")
        let frames = await gathering.value
        if case .cameraJPEG = frames.event { Issue.record("the camera's picture came after the AI's wait ended") }
        _ = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        #expect(camera.apiCalls.value == 2, "the camera's API is asked again: it was not counted as failing")
    }

    /// A fetch already running when the event began asked the camera for a picture of before the event: it is no picture "At the event" (half
    /// a second of leeway), and no second fetch is started beside it.
    @Test func aFetchThatBeganBeforeTheEventIsNotItsPicture() async throws {
        // (A late wake from the sleep only makes the fetch earlier still: 100 ms leaves 400 ms of the leeway.)
        for (lead, isEventPicture) in [(Duration.milliseconds(800), false), (.milliseconds(100), true)] {
            let camera = Camera()
            let provider = camera.provider(.answers(after: .milliseconds(1_200)))
            let home = Task { try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .periodic)) }
            #expect(await eventually(every: .milliseconds(1)) { camera.apiCalls.value == 1 })
            try await Task.sleep(for: lead)
            let frames = await EventPictures(hub: camera.hub, snapshots: provider, afterWait: .milliseconds(200)).gather(at: Date())
            if case .cameraJPEG = frames.event {
                #expect(isEventPicture, "a fetch begun \(lead) before the event is not its picture")
            } else {
                #expect(!isEventPicture, "a fetch begun \(lead) before the event is within the leeway")
            }
            #expect(camera.apiCalls.value == 1, "one fetch at a time")
            _ = try await home.value
        }
    }

    /// Gathering never reads or writes Home's caches: Home's next periodic snapshot still comes from its 10 s cache, and Home's next event
    /// snapshot still reuses the picture it decoded.
    @Test func homesCachesAreUntouched() async throws {
        let camera = Camera()
        let provider = camera.provider(.answers(after: .zero))
        let first = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .periodic))
        #expect(camera.apiCalls.value == 1)
        _ = await camera.gather(provider, afterWait: .milliseconds(200))
        #expect(camera.apiCalls.value == 2, "the event picture is the camera's picture of now")
        #expect(try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .periodic)) == first)
        #expect(camera.apiCalls.value == 2, "Home's cached picture is still its own")

        let streamOnly = Camera()
        await streamOnly.send(0)
        let decoding = streamOnly.provider(.none)
        let picture = try await decoding.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event))
        #expect(streamOnly.codecs.decodes.value == 1)
        _ = await streamOnly.gather(decoding, afterWait: .milliseconds(200))
        #expect(try await decoding.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event)) == picture)
        #expect(streamOnly.codecs.decodes.value == 1, "the same keyframe is not decoded again: Home's keyframe cache is as it was")
    }

    /// The last picture Home has (up to 5 minutes old) stands in for Home's snapshots of a camera that cannot answer, but never for the event
    /// picture: with the camera offline or failing and nothing fresh in the ring, an event has no picture "At the event".
    @Test func aStalePictureIsNeverTheEventPicture() async throws {
        let camera = Camera()
        let provider = camera.provider(.answers(after: .zero))
        let cached = try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .periodic))
        await camera.send(-30)   // the camera stopped sending half a minute ago
        camera.offline.set(true)
        #expect(try await provider.snapshot(SnapshotRequest(width: 640, height: 360, reason: .event)) == cached, "Home gets the last picture")
        #expect(await camera.pictures(await camera.gather(provider, afterWait: .milliseconds(200))).isEmpty)

        let failing = Camera()
        await failing.send(-30)
        #expect(await failing.pictures(await failing.gather(failing.provider(.fails), afterWait: .milliseconds(200))).isEmpty)
        #expect(failing.apiCalls.value == 1)
    }

    /// Without a camera JPEG the event picture is decoded from the newest GOP up to the frame nearest the event, at most 150 frames and 8 MiB
    /// (in a longer GOP, the last frame kept); one that cannot get within 3 s of the event that way is no event picture.
    @Test func theEventPictureFromALongGOPIsCappedNearTheEvent() async throws {
        let near = Camera()
        await near.sendGOP(from: -4, frames: 135, fps: 30, bytes: 1_000)   // the frame at the event is the 121st
        let nearFrames = await near.gather(near.provider(.none), afterWait: .milliseconds(200))
        guard case .stream(let nearest) = nearFrames.event else { Issue.record("no event frames"); return }
        #expect(nearest.count == 121 && nearest[0].isKeyframe)
        #expect(await near.pictures(nearFrames).filter { $0.hasPrefix(EventPictures.atTheEvent) } == ["At the event: 120.0 s, 768 wide, quality 0.7"])

        let manyFrames = Camera()
        await manyFrames.sendGOP(from: -6, frames: 200, fps: 30, bytes: 1_000)
        let capped = await manyFrames.gather(manyFrames.provider(.none), afterWait: .milliseconds(200))
        guard case .stream(let kept) = capped.event else { Issue.record("no event frames"); return }
        #expect(kept.count == 150, "150 frames at most, the picture 1 s before the event")
        #expect(await manyFrames.pictures(capped) == ["At the event: 149.0 s, 768 wide, quality 0.7"])

        let bigFrames = Camera()
        await bigFrames.sendGOP(from: -3, frames: 100, fps: 30, bytes: 100_000)
        guard case .stream(let bounded) = await bigFrames.gather(bigFrames.provider(.none), afterWait: .milliseconds(200)).event else {
            Issue.record("no event frames")
            return
        }
        #expect(bounded.count == 83 && bounded.reduce(0) { $0 + $1.nalUnits[0].count } <= 8 << 20, "8 MiB at most")

        let tooLong = Camera()
        await tooLong.sendGOP(from: -10, frames: 320, fps: 30, bytes: 1_000)
        #expect(await tooLong.gather(tooLong.provider(.none), afterWait: .milliseconds(200)).event == nil, "150 frames end 5 s before the event")
    }

    @Test func aCancelledGatherEndsAtOnce() async {
        let camera = Camera()
        let gathering = Task { await camera.gather(camera.provider(.answers(after: .seconds(20))), afterWait: .seconds(30)) }
        #expect(await eventually { await camera.hub.subscriberCount == 1 && camera.apiCalls.value == 1 })
        let cancelled = ContinuousClock.now
        gathering.cancel()
        let frames = await gathering.value
        #expect(ContinuousClock.now - cancelled < .seconds(2), "neither the camera's answer nor the keyframes after the event were waited for")
        #expect(frames.event == nil && frames.after.isEmpty)
        #expect(await camera.hub.subscriberCount == 0)
    }

    @Test func aCancelledDecodeMakesNoMorePictures() async {
        let camera = Camera()
        await camera.send(-4, -2, 0, 2, 4)
        let frames = await camera.gather(camera.provider(.none))
        #expect(frames.before.count == 2 && frames.after.count == 2)
        camera.codecs.cancelAtDecode.set(1)   // the decoding is cancelled while it decodes its first picture
        let pictures = await Task { await camera.pictures(frames) }.value
        #expect(pictures.isEmpty)
        #expect(camera.codecs.decodes.value == 1, "nothing more was decoded")
        #expect(camera.codecs.encodedInTask.value.isEmpty, "nor encoded")
    }

    /// A keyframe decoded between two pictures of one GOP moves the decoder off that GOP: the next picture of it starts again at its keyframe
    /// instead of going on from frames decoded against another picture.
    @Test func aKeyframeBetweenTwoPicturesOfAGOPMakesTheNextStartAtItsKeyframe() async throws {
        let camera = Camera()
        await camera.sendGOP(from: 0, frames: 3, fps: 10, bytes: 10)
        let gop = await camera.hub.newestGOP()
        await camera.send(1)
        let other = try #require(await camera.hub.lastKeyframe)
        let decoders = camera.decoders()
        _ = try await decoders.jpeg(fromGOP: gop, maxWidth: 768, maxHeight: nil, until: .now + .seconds(5))
        #expect(camera.codecs.decodes.value == 3)
        _ = try await decoders.jpeg(fromKeyframe: other, maxWidth: 768, maxHeight: nil)
        _ = try await decoders.jpeg(fromGOP: gop, maxWidth: 768, maxHeight: nil, until: .now + .seconds(5))
        #expect(camera.codecs.decodes.value == 7, "the GOP was decoded again from its keyframe (3 + 1 + 3)")
    }
}
