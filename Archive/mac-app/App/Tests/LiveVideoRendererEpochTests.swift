import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import PlatformApple
import Synchronization
import Testing

/// A `VideoOutput` that records what the renderer's task gives it, and can hold the task inside `enqueue` (a layer that is not ready for
/// more frames) so a test can queue frames behind it. Frames are told apart by their presentation time: `id * 3_000` ticks at 90 kHz.
nonisolated final class FakeVideoOutput: VideoOutput {
    struct Entry: Equatable {
        var id: Int
        var doNotDisplay: Bool
        var displayImmediately: Bool
        var isSync: Bool
    }

    private struct State {
        var entries: [Entry] = []
        var flushes: [Bool] = []
        var entered = 0
        var results: [VideoEnqueueResult] = []
        var holding = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var entries: [Entry] { state.withLock { $0.entries } }
    var ids: [Int] { state.withLock { $0.entries.map(\.id) } }
    /// `removingDisplayedImage` of every flush, in order.
    var flushes: [Bool] { state.withLock { $0.flushes } }
    /// Calls of `enqueue` so far (the one the task is held in included).
    var entered: Int { state.withLock { $0.entered } }

    /// The next `enqueue` waits until `release()`.
    func hold() { state.withLock { $0.holding = true } }

    func release() {
        let resumed = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.holding = false
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in resumed { waiter.resume() }
    }

    /// The answers of the next `enqueue` calls (then `.enqueued`).
    func script(_ results: [VideoEnqueueResult]) { state.withLock { $0.results = results } }

    func flush(removingDisplayedImage: Bool) async {
        state.withLock { $0.flushes.append(removingDisplayedImage) }
    }

    func enqueue(_ sample: sending CMSampleBuffer) async throws -> VideoEnqueueResult {
        state.withLock { $0.entered += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = state.withLock { state -> Bool in
                guard state.holding else { return false }
                state.waiters.append(continuation)
                return true
            }
            if !wait { continuation.resume() }
        }
        let entry = Entry(id: Int(CMSampleBufferGetPresentationTimeStamp(sample).value / 3_000),
                          doNotDisplay: Self.attachment(sample, kCMSampleAttachmentKey_DoNotDisplay) == true,
                          displayImmediately: Self.attachment(sample, kCMSampleAttachmentKey_DisplayImmediately) == true,
                          isSync: Self.attachment(sample, kCMSampleAttachmentKey_NotSync) != true)
        return state.withLock { state in
            state.entries.append(entry)
            return state.results.isEmpty ? .enqueued : state.results.removeFirst()
        }
    }

    private static func attachment(_ sample: CMSampleBuffer, _ key: CFString) -> Bool? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false), CFArrayGetCount(attachments) > 0 else { return nil }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self) as NSDictionary
        return dictionary[key as String] as? Bool
    }
}

/// Frames the renderer can turn into sample buffers: a real parameter set (a 320x180 Main profile stream; CoreMedia checks it), a made-up payload
/// (nothing decodes them here). No encoder session: starting a hardware encoder takes most of a second and slows down the tests that run beside it.
nonisolated enum RendererFixtures {
    static func format() async throws -> VideoFormat {
        VideoFormat.h264(sps: Data([0x27, 0x4d, 0x00, 0x28, 0xab, 0x40, 0xa0, 0xcf, 0xcf, 0x35, 0x01, 0x01, 0x01, 0x02]), pps: Data([0x28, 0xee, 0x3c, 0x80]))
            ?? VideoFormat(codec: .h264, width: 320, height: 180, parameterSets: [])
    }

    static func frame(_ id: Int, key: Bool, format: VideoFormat) -> EncodedVideoFrame {
        EncodedVideoFrame(format: format, nalUnits: [Data([key ? 0x65 : 0x41, UInt8(id & 0xFF)])], isKeyframe: key,
                          pts: MediaTime(value: Int64(id) * 3_000, timescale: 90_000), wallClock: Date())
    }
}

/// What `LiveVideoRenderer` guarantees a producer that is not the live feed: stale frames never reach the layer, decode-only frames are
/// marked, and the backlog and the renderer's own restarts can be read.
@Suite(.serialized, .timeLimit(.minutes(1))) nonisolated struct LiveVideoRendererEpochTests {

    @Test func aKeyframeQueuedBeforeAResetNeverReachesTheOutput() async throws {
        let format = try await RendererFixtures.format()
        let output = FakeVideoOutput()
        output.hold()
        let renderer = LiveVideoRenderer(output: output)
        renderer.show(RendererFixtures.frame(0, key: true, format: format))   // the task takes it and waits inside enqueue
        await eventually { output.entered == 1 }
        renderer.show(RendererFixtures.frame(1, key: true, format: format))   // queued behind it ...
        renderer.show(RendererFixtures.frame(2, key: false, format: format))
        renderer.reset()                                                      // ... and made stale by the reset
        renderer.show(RendererFixtures.frame(3, key: true, format: format))   // the new picture
        output.release()
        await eventually { output.ids.contains(3) }
        #expect(output.ids == [0, 3], "frames 1 and 2 were queued before the reset")
        #expect(output.flushes == [false], "the picture stays: the flush does not remove the displayed image")
        #expect(renderer.restarts == 0 && renderer.queued == 0)
    }

    @Test func aClearAlsoDropsTheFramesQueuedBeforeIt() async throws {
        let format = try await RendererFixtures.format()
        let output = FakeVideoOutput()
        output.hold()
        let renderer = LiveVideoRenderer(output: output)
        renderer.show(RendererFixtures.frame(0, key: true, format: format))
        await eventually { output.entered == 1 }
        renderer.show(RendererFixtures.frame(1, key: true, format: format))
        renderer.clear()
        renderer.show(RendererFixtures.frame(2, key: true, format: format))
        output.release()
        await eventually { output.ids.contains(2) }
        #expect(output.ids == [0, 2])
        #expect(output.flushes == [true], "a clear removes the displayed image")
    }

    @Test func queuedCountsTheFramesTheTaskHasNotTakenYet() async throws {
        let format = try await RendererFixtures.format()
        let output = FakeVideoOutput()
        output.hold()
        let renderer = LiveVideoRenderer(output: output)
        #expect(renderer.queued == 0)
        renderer.show(RendererFixtures.frame(0, key: true, format: format))
        await eventually { output.entered == 1 }
        #expect(renderer.queued == 0, "the frame in the task's hands is not queued any more")
        for id in 1...5 { renderer.show(RendererFixtures.frame(id, key: false, format: format)) }
        #expect(renderer.queued == 5)
        output.release()
        await eventually { output.ids.count == 6 }
        await eventually { renderer.queued == 0 }
        #expect(renderer.queued == 0 && output.ids == [0, 1, 2, 3, 4, 5])
    }

    @Test func decodeOnlyFramesAreMarkedDoNotDisplayAndTheRestAreShownAtOnce() async throws {
        let format = try await RendererFixtures.format()
        let output = FakeVideoOutput()
        let renderer = LiveVideoRenderer(output: output)
        renderer.show(RendererFixtures.frame(0, key: true, format: format), decodeOnly: true)    // a lead-in: keyframe, then deltas
        renderer.show(RendererFixtures.frame(1, key: false, format: format), decodeOnly: true)
        renderer.show(RendererFixtures.frame(2, key: false, format: format))                     // the picture the person asked for
        await eventually { output.ids.count == 3 }
        #expect(output.entries == [
            .init(id: 0, doNotDisplay: true, displayImmediately: false, isSync: true),
            .init(id: 1, doNotDisplay: true, displayImmediately: false, isSync: false),
            .init(id: 2, doNotDisplay: false, displayImmediately: true, isSync: false),
        ])
    }

    @Test func aDecodeOnlyKeyframePassesTheKeyframeGate() async throws {
        let format = try await RendererFixtures.format()
        let output = FakeVideoOutput()
        let renderer = LiveVideoRenderer(output: output)
        renderer.show(RendererFixtures.frame(1, key: false, format: format), decodeOnly: true)   // no keyframe yet: dropped
        renderer.show(RendererFixtures.frame(2, key: true, format: format), decodeOnly: true)
        renderer.show(RendererFixtures.frame(3, key: false, format: format))
        await eventually { output.ids.count == 2 }
        #expect(output.ids == [2, 3])
    }

    @Test func restartsCountsOnlyWhatTheRendererDidByItself() async throws {
        let format = try await RendererFixtures.format()
        let output = FakeVideoOutput()
        output.script([.restart, .failed(CocoaError(.coderInvalidValue))])
        let renderer = LiveVideoRenderer(output: output)
        renderer.show(RendererFixtures.frame(0, key: true, format: format))   // the decoder says restart
        await eventually { renderer.restarts == 1 }
        renderer.show(RendererFixtures.frame(1, key: false, format: format))   // no keyframe since the restart: dropped
        renderer.show(RendererFixtures.frame(2, key: true, format: format))    // the layer fails this one
        await eventually { renderer.restarts == 2 }
        #expect(output.ids == [0, 2])
        renderer.reset()
        renderer.clear()
        renderer.show(RendererFixtures.frame(3, key: true, format: format))
        await eventually { output.ids.contains(3) }
        #expect(renderer.restarts == 2, "reset() and clear() were asked for; they are not restarts")
    }

    @Test func aFullQueueLosesTheOldestFramesAndRestartsAtTheNextKeyframe() async throws {
        let format = try await RendererFixtures.format()
        let output = FakeVideoOutput()
        output.hold()
        let renderer = LiveVideoRenderer(output: output)
        renderer.show(RendererFixtures.frame(0, key: true, format: format))
        await eventually { output.entered == 1 }
        for id in 1...310 { renderer.show(RendererFixtures.frame(id, key: false, format: format)) }
        #expect(renderer.queued == LiveVideoRenderer.maximumPending, "ten of the 310 frames were lost; the count follows the queue")
        output.release()
        await eventually { renderer.queued == 0 && renderer.restarts == 1 }
        #expect(renderer.restarts == 1)
        #expect(output.ids == [0], "the survivors were deltas after lost frames: none is shown without a keyframe")
        renderer.show(RendererFixtures.frame(400, key: true, format: format))
        await eventually { output.ids.contains(400) }
        #expect(output.ids == [0, 400])
    }
}
