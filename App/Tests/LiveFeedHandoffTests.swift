import BridgeEngine
import Foundation
import MediaCore
import Synchronization
import Testing

/// A sink whose first `show` blocks until the test opens the gate: a picture that is "on its way to the renderer" when the feed stops.
nonisolated final class BlockingLiveSink: LiveVideoSink {
    private let gate = DispatchSemaphore(value: 0)
    private let state = Mutex((blockFirst: true, entered: 0, shown: 0, silences: 0, clears: 0))

    var entered: Int { state.withLock { $0.entered } }
    var shown: Int { state.withLock { $0.shown } }
    var clears: Int { state.withLock { $0.clears } }

    func open() { gate.signal() }

    func show(_ frame: EncodedVideoFrame) {
        let block = state.withLock { state -> Bool in
            state.entered += 1
            defer { state.blockFirst = false }
            return state.blockFirst
        }
        if block { gate.wait() }
        state.withLock { $0.shown += 1 }
    }

    func play(_ frame: EncodedAudioFrame) {}
    func reset() {}
    func silence() { state.withLock { $0.silences += 1 } }
    func clear() { state.withLock { $0.clears += 1 } }
}

/// How the NVR takes a cell's renderer from the live feed and gives it back (`keepsPictureOnStop`, `stopAndWait`).
@MainActor @Suite(.timeLimit(.minutes(1))) struct LiveFeedHandoffTests {
    private let camera = UUID()

    private func feed(_ source: FakeLiveSource, sink: any LiveVideoSink) -> LiveFeed {
        LiveFeed(cameraID: camera, stream: .sub, wantsAudio: false, displayWidth: 640, sink: sink, retryDelay: .milliseconds(30), stallTime: .seconds(5),
                 open: source.opener)
    }

    @Test func aFeedThatKeepsItsPictureOnStopDoesNotClearIt() async {
        let source = FakeLiveSource()
        let sink = FakeLiveSink()
        let feed = feed(source, sink: sink)
        feed.keepsPictureOnStop = true
        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { feed.phase == .live && feed.hasPicture })

        feed.isWanted = false
        #expect(await settles { source.cancelled.value == 1 }, "the lease is released")
        #expect(feed.phase == .stopped)
        #expect(feed.hasPicture, "the picture stays")
        #expect(sink.clears.withLock { $0 } == 0, "nothing removes it from the layer")
        #expect(sink.silences.withLock { $0 } >= 1, "the sound ends")
        #expect(feed.activeStream == nil)

        feed.isWanted = true   // recorded playback gives the renderer back
        #expect(await settles { source.opens.count == 2 })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { feed.phase == .live })
        #expect(sink.resets.withLock { $0 } >= 2, "the new connection resets the renderer, which keeps the picture")
        #expect(feed.hasPicture)
        feed.stop()
    }

    @Test func aFeedWithoutThatFlagStillClearsItsPicture() async {
        let source = FakeLiveSource()
        let sink = FakeLiveSink()
        let feed = feed(source, sink: sink)
        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { feed.hasPicture })
        feed.stop()
        #expect(!feed.hasPicture && sink.clears.withLock { $0 } == 1, "the live view is unchanged")
    }

    @Test func stopAndWaitReturnsOnlyAfterTheLastPictureReachedTheSink() async {
        let source = FakeLiveSource()
        let sink = BlockingLiveSink()
        let feed = feed(source, sink: sink)
        feed.keepsPictureOnStop = true
        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { sink.entered == 1 }, "the reader is inside the sink's show")

        let finished = Mutex(false)
        let waiting = Task { @MainActor in
            await feed.stopAndWait()
            finished.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!finished.withLock { $0 }, "a picture is still on its way to the sink")
        #expect(!feed.isWanted)

        sink.open()
        await waiting.value
        let shownAtReturn = sink.shown
        #expect(shownAtReturn == 1)
        source.send(FakeLiveSource.video(key: false, index: 1))   // too late: nobody reads the stream any more
        source.send(FakeLiveSource.video(key: false, index: 2))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sink.shown == shownAtReturn, "no write after stopAndWait returned")
    }

    @Test func stopAndWaitOnAFeedThatNeverRanReturnsAtOnce() async {
        let source = FakeLiveSource()
        let feed = feed(source, sink: FakeLiveSink())
        await feed.stopAndWait()
        #expect(source.opens.isEmpty && !feed.isWanted)
    }

    @Test func stopAndWaitEndsTheRunAndReleasesTheLease() async {
        let source = FakeLiveSource()
        let feed = feed(source, sink: FakeLiveSink())
        feed.isWanted = true
        #expect(await settles { source.opens.count == 1 })
        source.send(FakeLiveSource.video(key: true))
        #expect(await settles { feed.phase == .live })
        await feed.stopAndWait()
        #expect(source.cancelled.value == 1 && feed.phase == .stopped)
        #expect(source.openCount == 0)
    }
}
