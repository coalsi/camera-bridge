#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import PlatformApple
import Testing
import TestSupport
@testable import BridgeEngine

/// Two-way audio's recovery and sharing (plan W3-1 item 3, integration brief §5.4) on `TalkbackBridge` itself: a talkback
/// channel the camera refuses or drops is retried after `retryDelay` (never once per return packet), a camera without
/// one is asked once, a slow open is never doubled by a second talker, and the camera-facing close is bounded.
@Suite struct RuntimeTalkbackBridgeTests {
    static let log = Log(category: "TalkbackTest")

    struct Refused: Error {}
    struct ChannelClosed: Error {}

    /// A camera with one two-way audio channel, like Hikvision's: a sink's `open()` first closes whatever session the
    /// channel has (a stale one blocks the open), then takes it; a sink's `close()` closes the channel whoever holds it.
    /// `failingOpens` / `failingSends` make that many calls throw. Counters are shared by every sink made for it.
    final class OneChannelCamera: Sendable {
        let openDelay: Duration
        let closeDelay: Duration
        let failingOpens: Box<Int>
        let failingSends: Box<Int>
        let sinksMade = Box(0)
        let opens = Box(0)
        let closes = Box(0)
        /// The sink whose session the channel carries.
        let owner = Box<Int?>(nil)
        /// Frames the camera played, by sink.
        let played = Box<[Int: Int]>([:])

        /// Requests follow their caller's cancellation, as Hikvision's HTTP requests do: an open takes the channel when
        /// the camera gets it and fails if cancelled before its answer (leaving the channel taken); a send of a cancelled
        /// caller fails and breaks the sink's upload.
        let followsCancellation: Bool

        init(openDelay: Duration = .zero, closeDelay: Duration = .zero, failingOpens: Int = 0, failingSends: Int = 0,
             followsCancellation: Bool = false) {
            self.openDelay = openDelay
            self.closeDelay = closeDelay
            self.failingOpens = Box(failingOpens)
            self.failingSends = Box(failingSends)
            self.followsCancellation = followsCancellation
        }

        func makeSink() -> any TalkbackSink {
            Sink(camera: self, id: sinksMade.update { $0 += 1; return $0 })
        }

        var framesPlayed: Int { played.value.values.reduce(0, +) }

        static func take(_ box: Box<Int>) -> Bool {
            box.update { count in
                guard count > 0 else { return false }
                count -= 1
                return true
            }
        }

        /// Waits `delay` ignoring cancellation (a request already sent to the camera).
        static func pause(_ delay: Duration) async {
            guard delay > .zero else { return }
            await Task.detached { try? await Task.sleep(for: delay) }.value
        }
    }

    final class Sink: TalkbackSink {
        let inputFormat = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)
        let camera: OneChannelCamera
        let id: Int
        let opened = Box(false)

        init(camera: OneChannelCamera, id: Int) {
            self.camera = camera
            self.id = id
        }

        func open() async throws {
            camera.opens.update { $0 += 1 }
            camera.owner.set(nil)
            if camera.followsCancellation {
                camera.owner.set(id)   // the camera took the session; its answer is on the way
                opened.set(true)
                try await Task.sleep(for: camera.openDelay)
                return
            }
            await OneChannelCamera.pause(camera.openDelay)
            if OneChannelCamera.take(camera.failingOpens) { throw Refused() }
            camera.owner.set(id)
            opened.set(true)
        }

        func send(_ frame: EncodedAudioFrame) async throws {
            if camera.followsCancellation, Task.isCancelled { throw CancellationError() }
            if OneChannelCamera.take(camera.failingSends) { throw ChannelClosed() }
            guard camera.owner.value == id else { throw ChannelClosed() }
            camera.played.update { $0[id, default: 0] += 1 }
        }

        func close() async {
            camera.closes.update { $0 += 1 }
            if opened.value { camera.owner.set(nil) }
            await OneChannelCamera.pause(camera.closeDelay)
        }
    }

    static func bridge(_ camera: OneChannelCamera, retryDelay: Duration = .milliseconds(400), closeLimit: Duration = CameraRuntime.stopLimit)
        -> TalkbackBridge {
        TalkbackBridge(makeSink: { camera.makeSink() }, codecs: AppleMediaCodecs(), retryDelay: retryDelay, closeLimit: closeLimit, log: log)
    }

    /// Sends `packets` from `session`, one every `interval` (each session's return audio arrives in order, one at a time).
    static func talk(_ bridge: TalkbackBridge, _ session: UUID, _ packets: some Sequence<EncodedAudioFrame>, every interval: Duration = .milliseconds(20))
        async {
        for packet in packets {
            await bridge.send(packet, from: session)
            try? await Task.sleep(for: interval)
        }
    }

    /// Review finding (W4 round 2): no test covered a refused open (a busy Hikvision channel); a mutant that reopened at
    /// every 20 ms return packet (about 50 open requests a second to the camera) passed every suite.
    @Test(.timeLimit(.minutes(1))) func anOpenTheCameraRefusesIsRetriedOnlyAfterTheDelay() async throws {
        let camera = OneChannelCamera(failingOpens: 1)
        let bridge = Self.bridge(camera)
        let session = UUID()
        let packets = try RuntimeLiveStreamTests.opusSecond()
        await Self.talk(bridge, session, packets.prefix(8))   // about 0.2 s: within the retry delay
        #expect(camera.opens.value == 1, "no second open before the retry delay")
        #expect(await !bridge.isOpen)
        try await Task.sleep(for: .milliseconds(400))
        await Self.talk(bridge, session, packets.dropFirst(8), every: .milliseconds(5))
        #expect(camera.opens.value == 2, "one reopen after the delay")
        #expect(await bridge.isOpen)
        #expect(camera.framesPlayed >= 20)
        await bridge.release(session)
        #expect(camera.closes.value == 1)
        #expect(await !bridge.isOpen)
    }

    /// Review finding (W4 round 2): a channel that fails while sending (the camera dropped it) must be closed once and
    /// reopened after the delay; a mutant that gave up for the camera's lifetime (and left the failed sink open) passed
    /// every suite.
    @Test(.timeLimit(.minutes(1))) func aSinkThatFailsWhileSendingIsClosedAndReopenedAfterTheDelay() async throws {
        let camera = OneChannelCamera(failingSends: 1)
        let bridge = Self.bridge(camera)
        let session = UUID()
        let packets = try RuntimeLiveStreamTests.opusSecond()
        await Self.talk(bridge, session, packets.prefix(8))
        #expect(camera.opens.value == 1)
        #expect(camera.closes.value == 1, "the failed sink is closed")
        #expect(await !bridge.isOpen)
        try await Task.sleep(for: .milliseconds(400))
        await Self.talk(bridge, session, packets.dropFirst(8), every: .milliseconds(5))
        #expect(camera.opens.value == 2 && camera.sinksMade.value == 2, "a new sink after the delay")
        #expect(camera.closes.value == 1)
        #expect(await bridge.isOpen)
        #expect((camera.played.value[2] ?? 0) >= 20, "audio reaches the new sink: \(camera.played.value)")
        await bridge.release(session)
        #expect(camera.closes.value == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aCameraWithoutTalkbackIsAskedOnce() async throws {
        let asked = Box(0)
        let bridge = TalkbackBridge(makeSink: { asked.update { $0 += 1 }; return nil }, codecs: AppleMediaCodecs(), retryDelay: .milliseconds(50),
                                    log: Self.log)
        let session = UUID()
        let packets = try RuntimeLiveStreamTests.opusSecond()
        await Self.talk(bridge, session, packets.prefix(5))
        try await Task.sleep(for: .milliseconds(100))
        await Self.talk(bridge, session, packets.dropFirst(5).prefix(5))
        #expect(asked.value == 1)
        #expect(await !bridge.isOpen)
        #expect(await bridge.framesSent == 0)
    }

    /// Review finding (W4 round 2): while the first talker's open was still in flight (slow cameras and NVRs take over
    /// a second), a second talker passed the hand-over check and opened a second sink; on the camera's single channel
    /// that open ended the first session, and closing the redundant sink then closed the channel the bridge kept.
    @Test(.timeLimit(.minutes(1))) func aSecondTalkerDuringASlowOpenNeverOpensASecondSink() async throws {
        let camera = OneChannelCamera(openDelay: .milliseconds(1_500))
        let bridge = TalkbackBridge(makeSink: { camera.makeSink() }, codecs: AppleMediaCodecs(), log: Self.log)
        let first = UUID(), second = UUID()
        let packets = try RuntimeLiveStreamTests.opusSecond()
        // Packets during the open are dropped (review W4 round 4): both talk past it.
        let firstTalker = Task { await Self.talk(bridge, first, packets + packets) }
        try await Task.sleep(for: .milliseconds(1_100))   // past the 1 s hand-over while the open is in flight
        let secondTalker = Task { await Self.talk(bridge, second, packets + packets) }
        await firstTalker.value
        await secondTalker.value
        #expect(camera.opens.value == 1, "one open reaches the camera (\(camera.opens.value))")
        #expect(await bridge.isOpen)
        #expect(camera.owner.value == 1, "the camera's channel is still open")
        #expect(camera.framesPlayed >= 20, "\(camera.played.value)")
        await bridge.release(first)
        await bridge.release(second)
        #expect(camera.closes.value == 1)

        // The first talker's session ends during the open and a new one starts talking: still one open.
        let slow = OneChannelCamera(openDelay: .milliseconds(800))
        let restarted = TalkbackBridge(makeSink: { slow.makeSink() }, codecs: AppleMediaCodecs(), log: Self.log)
        let ending = UUID(), next = UUID()
        let opening = Task { await restarted.send(packets[0], from: ending) }
        try await Task.sleep(for: .milliseconds(200))
        await restarted.release(ending)
        await Self.talk(restarted, next, packets.prefix(20))
        await opening.value
        await Self.talk(restarted, next, packets.dropFirst(20))
        #expect(slow.opens.value == 1, "\(slow.opens.value) opens")
        #expect(await restarted.isOpen)
        #expect(slow.framesPlayed >= 10)
        await restarted.close()
    }

    /// Review finding (W4 round 2): closing the camera's talkback channel (an HTTP request with a 10 s timeout) was
    /// awaited without a bound by every stop path.
    @Test(.timeLimit(.minutes(1))) func closingTheChannelNeverHoldsUpAStopForLong() async throws {
        let camera = OneChannelCamera(closeDelay: .seconds(5))
        let bridge = Self.bridge(camera, closeLimit: .milliseconds(300))
        let session = UUID()
        let packets = try RuntimeLiveStreamTests.opusSecond()
        await Self.talk(bridge, session, packets.prefix(5))
        #expect(await bridge.isOpen)
        let releasing = ContinuousClock.now
        await bridge.release(session)
        #expect(ContinuousClock.now - releasing < .seconds(1))
        #expect(await !bridge.isOpen)

        await Self.talk(bridge, session, packets.prefix(1))   // an ended session does not reopen
        let other = UUID()
        try await Task.sleep(for: .milliseconds(450))
        await Self.talk(bridge, other, packets.prefix(5))
        #expect(await bridge.isOpen)
        let closing = ContinuousClock.now
        await bridge.close()
        #expect(ContinuousClock.now - closing < .seconds(1))
    }

    /// Review finding (W4 round 3): a live view's stop cancelled its return-audio task, and the cancellation reached the
    /// camera-facing open under way: the camera had taken its single two-way session, the open failed, nothing closed
    /// it, and Hik-Connect and the NVR found the camera busy until it timed the session out. The open runs to its end
    /// and the sink nobody wants is closed.
    @Test(.timeLimit(.minutes(1))) func aViewerLeavingWhileTalkbackOpensStillClosesTheCamerasSession() async throws {
        let camera = OneChannelCamera(openDelay: .milliseconds(400), followsCancellation: true)
        let bridge = Self.bridge(camera)
        let session = UUID()
        let packets = try RuntimeLiveStreamTests.opusSecond()
        let talker = Task { await bridge.send(packets[0], from: session) }
        #expect(await eventually { camera.opens.value == 1 })
        talker.cancel()   // the live view ends while the camera answers the open
        await bridge.release(session)
        await talker.value
        #expect(await eventually(timeout: .seconds(3)) { camera.closes.value == 1 }, "the camera's two-way session is closed")
        #expect(camera.owner.value == nil, "nothing holds the camera's channel")
        #expect(await !bridge.isOpen)
    }

    /// Review finding (W4 round 3): a cancelled sender broke the sink every viewer shares (Hikvision closes its upload
    /// when a send is cancelled), and the bridge then blocked every viewer's talkback for `retryDelay`.
    @Test(.timeLimit(.minutes(1))) func aCancelledSenderLeavesTheSharedSinkToTheOtherViewers() async throws {
        let camera = OneChannelCamera(followsCancellation: true)
        let bridge = Self.bridge(camera, retryDelay: .seconds(5))
        let first = UUID(), second = UUID()
        let packets = try RuntimeLiveStreamTests.opusSecond()
        await Self.talk(bridge, first, packets.prefix(5))
        await bridge.send(packets[5], from: second)   // a second viewer uses talkback too (dropped while the first talks)
        #expect(await bridge.isOpen)
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            await bridge.send(packets[6], from: first)
        }
        cancelled.cancel()
        await cancelled.value
        #expect(await bridge.isOpen, "the shared sink stays open")
        #expect(camera.closes.value == 0)
        await bridge.release(first)
        let played = camera.framesPlayed
        await Self.talk(bridge, second, packets.dropFirst(7).prefix(10))
        #expect(camera.framesPlayed > played, "the other viewer is heard")
        await bridge.close()
    }
}
#endif
