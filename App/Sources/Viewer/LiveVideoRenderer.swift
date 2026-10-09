import AVFoundation
import AppKit
import BridgeSupport
import CoreMedia
import CoreVideo
import MediaCore
import PlatformApple
import Synchronization

/// Draws a camera's encoded video with `AVSampleBufferDisplayLayer`: the camera's H.264 / H.265 access units go to the
/// layer as they are (`LiveVideoSampleBuilder`), which decodes them in hardware and shows each at once — no timeline, no
/// buffering, the lowest latency. Nothing is transcoded or copied through the CPU.
///
/// Keyframe first: after a reset, an error or lost frames the layer is given nothing until the next keyframe, so it never
/// decodes a delta frame whose reference it never saw. One task owns the layer's render-synchronizer receiver and feeds it
/// in order, waiting while the layer is not ready (the replay of the newest GOP arrives as a burst); the frames waiting are
/// capped, and a backlog that long is dropped for the next keyframe. `layer` is hosted by `LiveVideoView`.
nonisolated final class LiveVideoRenderer: LiveVideoSink, @unchecked Sendable {
    /// Frames waiting for the layer; beyond this the oldest are lost and the picture restarts at the next keyframe.
    static let maximumPending = 300

    private enum Command: Sendable {
        case frame(EncodedVideoFrame)
        /// Look at the shared control state (a reset or clear was requested).
        case wake
    }

    /// What the producers tell the task, apart from the frames (a reset must never be lost with a dropped frame).
    private struct Control {
        var resetEpoch = 0
        var clearEpoch = 0
        var framesLost = false
    }

    private final class ControlBox: Sendable {
        let state = Mutex(Control())
    }

    let layer: AVSampleBufferDisplayLayer
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let commands: AsyncStream<Command>.Continuation
    private let control = ControlBox()
    private let audio = LiveAudioPlayer()
    private let pump: Task<Void, Never>

    @MainActor
    init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor
        let output = VideoOutputs.make(renderer: layer.sampleBufferRenderer, synchronizer: synchronizer)
        synchronizer.rate = 1
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self, bufferingPolicy: .bufferingNewest(Self.maximumPending))
        commands = continuation
        let control = control
        pump = Task.detached(priority: .userInitiated) { [output] in
            await Self.run(stream, output: output, control: control)
        }
    }

    deinit {
        commands.finish()
        pump.cancel()
    }

    // MARK: LiveVideoSink

    func show(_ frame: EncodedVideoFrame) {
        if case .dropped = commands.yield(.frame(frame)) {
            control.state.withLock { $0.framesLost = true }
        }
    }

    func play(_ frame: EncodedAudioFrame) {
        audio.play(frame)
    }

    func reset() {
        control.state.withLock { $0.resetEpoch += 1 }
        commands.yield(.wake)
        audio.silence()
    }

    func silence() {
        audio.silence()
    }

    func clear() {
        control.state.withLock { $0.clearEpoch += 1 }
        commands.yield(.wake)
        audio.silence()
    }

    /// The picture on screen right now as a pixel buffer (the snapshot button); nil before the first picture.
    @MainActor
    func displayedPicture() -> CVPixelBuffer? {
        layer.sampleBufferRenderer.displayedPixelBuffer()
    }

    // MARK: Task

    private static func run(_ commands: AsyncStream<Command>, output: any VideoOutput, control: ControlBox) async {
        let log = Log(category: "LiveVideo")
        let builder = LiveVideoSampleBuilder()
        var needsKeyframe = true
        var seen = Control()
        var loggedFailure = false

        for await command in commands {
            // Resets and clears requested since the last command, and frames lost to a full queue.
            let now = control.state.withLock { state -> Control in
                defer { state.framesLost = false }
                return state
            }
            if now.clearEpoch != seen.clearEpoch {
                await output.flush(removingDisplayedImage: true)
                needsKeyframe = true
            } else if now.resetEpoch != seen.resetEpoch || now.framesLost {
                await output.flush(removingDisplayedImage: false)   // the last picture stays
                needsKeyframe = true
            }
            seen = now
            guard case .frame(let frame) = command else { continue }
            if needsKeyframe {
                guard frame.isKeyframe else { continue }
                needsKeyframe = false
            }
            do {
                guard let sample = try builder.sampleBuffer(for: frame) else { continue }
                switch try await output.enqueue(sample) {
                case .enqueued:
                    break
                case .restart:
                    // The decoder was reset (sleep, GPU change): start over at the next keyframe.
                    await output.flush(removingDisplayedImage: false)
                    needsKeyframe = true
                case .failed(let error):
                    await output.flush(removingDisplayedImage: false)
                    needsKeyframe = true
                    if !loggedFailure {
                        loggedFailure = true
                        log.warning("The live picture failed to display (\(error)); waiting for the next keyframe")
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // The format (parameter sets) was refused, or the layer failed: nothing to show until the next keyframe.
                needsKeyframe = true
                if !loggedFailure {
                    loggedFailure = true
                    log.warning("A live picture could not be shown (\(error)); waiting for the next keyframe")
                }
            }
        }
    }
}

/// Where the renderer's task hands pictures: the render-synchronizer receiver of macOS 27, or the display layer's own
/// renderer on macOS 15 and 26 (`CAMERABRIDGE_CLASSIC_RENDERER=1` forces it, for tests on a newer system).
nonisolated protocol VideoOutput: Sendable {
    func flush(removingDisplayedImage: Bool) async
    func enqueue(_ sample: sending CMSampleBuffer) async throws -> VideoEnqueueResult
}

nonisolated enum VideoEnqueueResult: Sendable {
    case enqueued
    /// The decoder or output was reset: flush and wait for the next keyframe.
    case restart
    case failed(any Error)
}

nonisolated enum VideoOutputs {
    @MainActor
    static func make(renderer: AVSampleBufferVideoRenderer, synchronizer: AVSampleBufferRenderSynchronizer) -> any VideoOutput {
        if #available(macOS 27, *), ProcessInfo.processInfo.environment["CAMERABRIDGE_CLASSIC_RENDERER"] != "1" {
            return ReceiverVideoOutput(receiver: synchronizer.sampleBufferReceiver(adding: renderer))
        }
        synchronizer.addRenderer(renderer)
        return ClassicVideoOutput(renderer: renderer)
    }
}

@available(macOS 27, *)
nonisolated struct ReceiverVideoOutput: VideoOutput, @unchecked Sendable {
    let receiver: AVSampleBufferVideoRenderer.Receiver

    func flush(removingDisplayedImage: Bool) async {
        if removingDisplayedImage { await receiver.flush(removingDisplayedImage: true) } else { receiver.flush() }
    }

    func enqueue(_ sample: sending CMSampleBuffer) async throws -> VideoEnqueueResult {
        switch try await receiver.enqueue(CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sample)) {
        case .enqueued, .enqueuedWithDecodeFailures, .cancelledDueToFlush: .enqueued
        case .cancelledDueToFlushRequiredToResume: .restart
        case .cancelledDueToError(let error): .failed(error)
        @unknown default: .restart
        }
    }
}

/// `AVSampleBufferVideoRenderer` itself: frames are enqueued when it is ready for more, and a failed renderer is flushed.
nonisolated struct ClassicVideoOutput: VideoOutput, @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer
    /// How long a renderer may stay unready before the picture restarts (a stuck decoder).
    static let readyTimeout = Duration.seconds(2)

    func flush(removingDisplayedImage: Bool) async {
        if removingDisplayedImage { renderer.flush(removingDisplayedImage: true, completionHandler: nil) } else { renderer.flush() }
    }

    func enqueue(_ sample: sending CMSampleBuffer) async throws -> VideoEnqueueResult {
        let deadline = ContinuousClock.now + Self.readyTimeout
        while renderer.status != .failed, !renderer.isReadyForMoreMediaData {
            guard ContinuousClock.now < deadline else { return .restart }
            try await Task.sleep(for: .milliseconds(4))
        }
        if renderer.status == .failed { return .failed(renderer.error ?? CocoaError(.coderInvalidValue)) }
        renderer.enqueue(sample)
        return .enqueued
    }
}

/// Plays a camera's audio (AAC, G.711, Opus, PCM) with `AVSampleBufferAudioRenderer`, which decodes the compressed access
/// units itself. The samples get one contiguous timeline of their own on an `AVSampleBufferRenderSynchronizer` (the
/// camera's timestamps are its clock's), started a moment ahead of the first one; a gap that lets playback overtake the
/// samples, or a buffer that grows beyond a second, starts the timeline again. Called from one thread at a time (the feed's
/// reader), `silence()` from anywhere: a lock keeps the calls apart.
nonisolated final class LiveAudioPlayer: @unchecked Sendable {
    /// The lead the timeline starts ahead of the first sample, and the buffered audio that makes it start again.
    static let startLead = 0.12
    static let maximumLead = 1.0

    private struct State {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let builder = LiveAudioSampleBuilder()
        var output: (any AudioOutput)?
        var nextTime: CMTime?
    }

    private let state = Mutex(State())
    private let log = Log(category: "LiveVideo")

    func play(_ frame: EncodedAudioFrame) {
        state.withLock { state in
            if state.output == nil { state.output = AudioOutputs.make(synchronizer: state.synchronizer) }
            guard let receiver = state.output else { return }
            let rate = max(1, frame.format.sampleRate)
            let frames = frame.sampleCount > 0 ? frame.sampleCount : max(frame.format.samplesPerFrame, 1)
            var start: CMTime
            if let next = state.nextTime, case let lead = (next - state.synchronizer.currentTime()).seconds, lead >= 0, lead <= Self.maximumLead {
                start = next
            } else {
                // First sample, or playback overtook the samples (or buffers too much): a new timeline from now.
                if state.nextTime != nil { receiver.flush() }
                let now = state.synchronizer.currentTime()
                if state.synchronizer.rate == 0 { state.synchronizer.setRate(1, time: now) }
                start = now + CMTime(seconds: Self.startLead, preferredTimescale: 90_000)
            }
            guard let sample = try? state.builder.sampleBuffer(for: frame, presentationTime: start) else { return }
            switch receiver.enqueueImmediately(sample) {
            case .enqueued:
                break
            case .suggestedFlush:
                receiver.flush()   // the output changed (another device): start again
                state.nextTime = nil
                return
            case .failed(let error):
                log.warning("The camera’s sound could not be played (\(error))")
                receiver.flush()
                state.nextTime = nil
                return
            }
            state.nextTime = start + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
        }
    }

    func silence() {
        state.withLock { state in
            guard state.nextTime != nil else { return }
            state.output?.flush()
            state.nextTime = nil
            state.synchronizer.rate = 0
        }
    }
}

/// The audio counterpart of `VideoOutput`.
nonisolated protocol AudioOutput: Sendable {
    func flush()
    func enqueueImmediately(_ sample: sending CMSampleBuffer) -> AudioEnqueueResult
}

nonisolated enum AudioEnqueueResult: Sendable {
    case enqueued
    case suggestedFlush
    case failed(any Error)
}

nonisolated enum AudioOutputs {
    static func make(synchronizer: AVSampleBufferRenderSynchronizer) -> any AudioOutput {
        let renderer = AVSampleBufferAudioRenderer()
        if #available(macOS 27, *), ProcessInfo.processInfo.environment["CAMERABRIDGE_CLASSIC_RENDERER"] != "1" {
            return ReceiverAudioOutput(receiver: synchronizer.sampleBufferReceiver(adding: renderer))
        }
        synchronizer.addRenderer(renderer)
        return ClassicAudioOutput(renderer: renderer)
    }
}

@available(macOS 27, *)
nonisolated struct ReceiverAudioOutput: AudioOutput, @unchecked Sendable {
    let receiver: AVSampleBufferAudioRenderer.Receiver

    func flush() { receiver.flush() }

    func enqueueImmediately(_ sample: sending CMSampleBuffer) -> AudioEnqueueResult {
        switch receiver.enqueueImmediately(CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sample)) {
        case .enqueued, .cancelledDueToFlush: .enqueued
        case .enqueuedWithSuggestedFlush: .suggestedFlush
        case .cancelledDueToError(let error): .failed(error)
        @unknown default: .enqueued
        }
    }
}

nonisolated struct ClassicAudioOutput: AudioOutput, @unchecked Sendable {
    let renderer: AVSampleBufferAudioRenderer

    func flush() { renderer.flush() }

    func enqueueImmediately(_ sample: sending CMSampleBuffer) -> AudioEnqueueResult {
        if renderer.status == .failed { return .failed(renderer.error ?? CocoaError(.coderInvalidValue)) }
        renderer.enqueue(sample)
        return .enqueued
    }
}
