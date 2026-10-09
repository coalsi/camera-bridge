import BridgeEngine
import Foundation
import MediaCore
import Synchronization
import Testing

/// A thread-safe counter.
nonisolated final class SyncCount: Sendable {
    private let state = Mutex(0)
    func add() { state.withLock { $0 += 1 } }
    var value: Int { state.withLock { $0 } }
}

/// Records what a feed sends to its renderer.
nonisolated final class FakeLiveSink: LiveVideoSink {
    let keyframes = Mutex(0)
    let deltas = Mutex(0)
    let audio = Mutex(0)
    let resets = Mutex(0)
    let silences = Mutex(0)
    let clears = Mutex(0)

    func show(_ frame: EncodedVideoFrame) {
        if frame.isKeyframe { keyframes.withLock { $0 += 1 } } else { deltas.withLock { $0 += 1 } }
    }

    func play(_ frame: EncodedAudioFrame) { audio.withLock { $0 += 1 } }
    func reset() { resets.withLock { $0 += 1 } }
    func silence() { silences.withLock { $0 += 1 } }
    func clear() { clears.withLock { $0 += 1 } }
}

/// The engine's live video, played by the test: records the opens, the cancellations, and feeds the samples it is told to.
@MainActor
final class FakeLiveSource {
    struct Open: Equatable {
        var camera: UUID
        var stream: LiveVideoStream
        var audio: Bool
        var width: Int?
    }

    private(set) var opens: [Open] = []
    /// Opens that did not fail.
    private(set) var successes = 0
    /// Subscriptions cancelled (a lease released).
    let cancelled = SyncCount()
    /// Opens fail with this while it is set (a camera that is not running).
    var failure: (any Error)?
    private var continuations: [AsyncStream<MediaSample>.Continuation] = []

    var opener: LiveVideoOpener {
        { [self] camera, stream, audio, width in
            opens.append(Open(camera: camera, stream: stream, audio: audio, width: width))
            if let failure { throw failure }
            successes += 1
            let (samples, continuation) = AsyncStream.makeStream(of: MediaSample.self)
            continuations.append(continuation)
            let cancelled = cancelled
            continuation.onTermination = { _ in cancelled.add() }
            return LiveVideoSubscription(samples: samples, stream: stream == .automatic ? .main : stream, cancel: { continuation.finish() })
        }
    }

    /// Subscriptions that are open now.
    var openCount: Int { successes - cancelled.value }

    func send(_ sample: MediaSample, to index: Int? = nil) {
        guard let continuation = index.map({ continuations[$0] }) ?? continuations.last else { return }
        continuation.yield(sample)
    }

    func end(_ index: Int? = nil) {
        (index.map { continuations[$0] } ?? continuations.last)?.finish()
    }

    static let format = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [Data([0x67, 1]), Data([0x68, 2])])

    static func video(key: Bool, index: Int = 0) -> MediaSample {
        .video(EncodedVideoFrame(format: format, nalUnits: [Data([key ? 0x65 : 0x41, UInt8(index & 0xFF)])], isKeyframe: key,
                                 pts: MediaTime(value: Int64(index) * 3_000, timescale: 90_000), wallClock: Date()))
    }

    static func audio(_ index: Int = 0) -> MediaSample {
        .audio(EncodedAudioFrame(format: .aacLC(sampleRate: 16_000, channels: 1), data: Data([1, 2]), pts: MediaTime(value: Int64(index) * 1_024, timescale: 16_000),
                                 sampleCount: 1_024, wallClock: Date()))
    }
}

/// Polls `condition` on the main actor.
@MainActor
func settles(timeout: Duration = .seconds(5), every interval: Duration = .milliseconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return condition()
}

/// A camera's live picture in the app (`LiveFeed`): the lease follows the wish, keyframes lead, reconnects, mute.
@MainActor @Suite(.timeLimit(.minutes(1))) struct LiveFeedTests {
    private let camera = UUID()

    private func feed(_ source: FakeLiveSource, sink: FakeLiveSink = FakeLiveSink(), stream: LiveVideoStream = .sub, audio: Bool = false,
                      retry: Duration = .milliseconds(30), stall: Duration = .seconds(5)) -> LiveFeed {
        LiveFeed(cameraID: camera, stream: stream, wantsAudio: audio, displayWidth: 640, sink: sink, retryDelay: retry, stallTime: stall, open: source.opener)
    }

    @Test func aFeedHoldsNoStreamUntilItIsWantedAndLetsGoWhenItStops() async {
        let source = FakeLiveSource()
        let sink = FakeLiveSink()
        let feed = feed(source, sink: sink)
        #expect(feed.phase == .stopped && source.opens.isEmpty)

        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        #expect(source.opens.first == FakeLiveSource.Open(camera: camera, stream: .sub, audio: false, width: 640))
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { feed.phase == .live && feed.hasPicture })
        #expect(feed.activeStream == .sub && feed.pictureSize == CGSize(width: 640, height: 360))

        feed.stop()
        #expect(await settles { source.cancelled.value == 1 }, "the lease is released")
        #expect(feed.phase == .stopped && !feed.hasPicture && sink.clears.withLock { $0 } >= 1)
    }

    @Test func framesGoToTheRendererInOrderStartingWithTheKeyframe() async {
        let source = FakeLiveSource()
        let sink = FakeLiveSink()
        let feed = feed(source, sink: sink)
        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        source.send(FakeLiveSource.video(key: true))
        for index in 1...5 { source.send(FakeLiveSource.video(key: false, index: index)) }
        #expect(await settles { sink.keyframes.withLock { $0 } == 1 && sink.deltas.withLock { $0 } == 5 })
        feed.stop()
    }

    @Test func aSuspendedFeedHoldsNothingAndResumesWhenTheWindowCanBeSeenAgain() async {
        let source = FakeLiveSource()
        let feed = feed(source)
        feed.isSuspended = true   // the window is hidden
        feed.isWanted = true
        try? await Task.sleep(for: .milliseconds(100))
        #expect(source.opens.isEmpty, "nothing is leased while the window cannot be seen")

        feed.isSuspended = false
        #expect(await settles { source.opens.count == 1 })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { feed.phase == .live })

        feed.isSuspended = true
        #expect(await settles { source.cancelled.value == 1 })
        #expect(feed.isWanted && feed.phase == .stopped, "the wish stays: playback resumes with the window")
        feed.isSuspended = false
        #expect(await settles { source.opens.count == 2 })
        feed.stop()
    }

    @Test func aCameraThatIsNotRunningIsTriedAgainAndShownUnavailable() async {
        let source = FakeLiveSource()
        source.failure = EngineError.cameraNotRunning
        let feed = feed(source)
        feed.isWanted = true
        #expect(await settles { feed.phase == .unavailable })
        #expect(await settles { source.opens.count >= 3 }, "tried again at the retry delay")
        source.failure = nil
        #expect(await settles { source.openCount == 1 })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { feed.phase == .live })
        feed.stop()
        #expect(await settles { source.openCount == 0 })
    }

    @Test func aStreamThatEndsReconnectsAndShowsTheKeyframeAgain() async {
        let source = FakeLiveSource()
        let sink = FakeLiveSink()
        let feed = feed(source, sink: sink)
        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { feed.phase == .live })
        source.end()   // the runtime stopped, the camera went away
        #expect(await settles { source.opens.count == 2 })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { sink.keyframes.withLock { $0 } == 2 && feed.phase == .live })
        #expect(sink.resets.withLock { $0 } >= 2, "the renderer starts over at every connection")
        feed.stop()
    }

    @Test func aFeedThatReceivesNothingForTheStallTimeSaysItIsReconnecting() async {
        let source = FakeLiveSource()
        let feed = feed(source, stall: .milliseconds(400))
        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { feed.phase == .live })
        #expect(await settles(timeout: .seconds(5)) { feed.phase == .stalled })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { feed.phase == .live })
        feed.stop()
    }

    @Test func aStreamThatStaysSilentIsOpenedAgainSoTheEngineCanPickAnotherOne() async {
        let source = FakeLiveSource()
        let feed = feed(source, stall: .milliseconds(300))
        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { feed.phase == .live })
        #expect(await settles(timeout: .seconds(5)) { source.opens.count == 2 }, "silent for twice the stall time: asked for again")
        #expect(await settles { source.openCount == 1 }, "the silent stream's lease was released")
        var live = false
        for _ in 0..<40 where !live {   // the new connection shows its picture (a busy machine may need a few tries)
            source.send(FakeLiveSource.video(key: true))
            live = await settles(timeout: .milliseconds(150)) { feed.phase == .live }
        }
        #expect(live)
        feed.stop()
    }

    @Test func soundIsOffUntilTheViewerTurnsItOn() async {
        let source = FakeLiveSource()
        let sink = FakeLiveSink()
        let feed = feed(source, sink: sink, stream: .main, audio: true)
        #expect(feed.isMuted, "muted by default")
        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        #expect(source.opens.first?.audio == true, "the camera's audio is read for a viewer that has a mute button")
        source.send(FakeLiveSource.video(key: true))
        source.send(FakeLiveSource.audio())
        source.send(FakeLiveSource.video(key: false, index: 1))
        #expect(await settles { sink.deltas.withLock { $0 } == 1 })
        #expect(sink.audio.withLock { $0 } == 0)

        feed.isMuted = false
        source.send(FakeLiveSource.audio(1))
        source.send(FakeLiveSource.video(key: false, index: 2))
        #expect(await settles { sink.deltas.withLock { $0 } == 2 })
        #expect(sink.audio.withLock { $0 } == 1)
        feed.isMuted = true
        #expect(sink.silences.withLock { $0 } >= 1)
        feed.stop()
    }

    @Test func aTileDoesNotAskForAudio() async {
        let source = FakeLiveSource()
        let feed = feed(source, audio: false)
        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        #expect(source.opens.first?.audio == false)
        feed.stop()
    }

    @Test func changingTheQualityReconnectsOnTheOtherStream() async {
        let source = FakeLiveSource()
        let feed = feed(source, stream: .main)
        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        feed.stream = .sub
        #expect(await settles { source.opens.count == 2 })
        #expect(source.opens.map(\.stream) == [.main, .sub])
        #expect(await settles { source.openCount == 1 }, "the first lease was released")
        feed.stop()
        #expect(await settles { source.openCount == 0 })
    }
}
