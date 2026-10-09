import BridgeSupport
import FMP4
import Foundation
import HAPCamera
import HDS
import MediaCore
import Synchronization

/// Limits of one HKSV recording stream (integration brief §5.3).
struct RecordingTiming: Sendable, Equatable {
    /// After this long the next fragment is the last one (the hub keeps recording by opening a new stream). This is the
    /// recording's one cap: `CameraController` sends every packet as marked and only backstops a stream still running
    /// one fragment plus `CameraControllerTimings.recordingCapGrace` after its own `maximumRecordingDuration`, which is
    /// where this default comes from (3 minutes).
    var maximumDuration: Duration = CameraControllerTimings.standard.maximumRecordingDuration
    /// At most one fragment per this interval: the prebuffer replays instantly and "HAP will terminate the connection if
    /// too much prebuffer is sent too quickly" (Scrypted); live fragments are `fragmentLength` apart anyway.
    var fragmentPacing: Duration = .milliseconds(250)
}

/// One HKSV recording stream (plan W3-1 item 5, research brief §3.9, integration brief §5.2–§5.3): a `MediaHub`
/// `.prebuffer(prebufferLength)` subscription → `TimelineRebaser` → passthrough (the source fits the selected
/// configuration, `MediaFit.recording` with the ingest's `StreamTraits`: no B-frames, longest recent GOP — or, before two
/// keyframes were seen, the age of the GOP still open as its lower bound) or `VideoTranscoding` at the selected size, bit
/// rate and I-frame interval → `GOPFragmenter(fragmentLength)` → `FMP4Muxer` (additive `pushGroups` + `fragment(_:)` path:
/// every tfdt is the previous tfdt plus that fragment's durations). Audio is AAC-LC at the selected rate and channels, only
/// while RecordingAudioActive: the camera's AAC-LC as is, other camera audio transcoded, silence when the camera has none
/// (or its audio is disabled). The initialization segment is the first packet; fragments follow, paced to one per
/// `fragmentPacing`; the fragment after `maximumDuration` is marked last and ends the stream, as does the end of the
/// subscription (the last open group is flushed as the last fragment, or two when one would run past `fragmentLength`:
/// `GOPFragmenter.flushGroups()`). A source keyframe whose parameter sets the
/// initialization segment cannot describe (the camera came back at another resolution) ends the stream the same way
/// (the hub opens a new stream, which starts with its own initialization segment), and so does video that would take the
/// open fragment past `fragmentLength`: a passed-through GOP that outgrows the fragment, or video on either path that comes
/// back after a gap (a lost IDR, a stall, a keyframe the decoder rejected), whose last picture would be stretched over the
/// gap (research brief §3.9: no fragment longer than `fragmentLength`). The last fragment ends before the frame that would
/// overrun it; the next stream decides again. A transcoded recording starts at the requested prebuffer: the hub replays
/// from the newest source keyframe at least `prebufferLength` old, up to a GOP earlier (10 s and more for the long-GOP
/// cameras that are transcoded); the frames before that point are decoded but not recorded, and the first one from there
/// on is encoded as a keyframe (integration brief §5.3: do not burst the whole buffer).
/// Camera audio that comes back in another format (any codec, transcoded or passed through) gets its own converter to
/// the audio track's format (dropped when there is none); a frame that cannot be converted is dropped. Cancelling
/// (`cancel()`, the controller dropping the stream) stops at once: the subscription is cancelled and codecs are
/// invalidated. Fragment statistics are logged at debug level. A frame the transcoder fails on is dropped (logged) and
/// the recording goes on from the next keyframe, as live view does; three failures in a row (the second gets a new
/// transcoder) and other errors end the stream with `HDSProtocolReason.unexpectedFailure` (logged with the cause).
final class RecordingProducer: Sendable {
    let streamID: Int
    private let configuration: CameraRecordingConfiguration
    private let audioActive: Bool
    private let cameraAudioEnabled: Bool
    private let hub: MediaHub
    private let traits: StreamTraits
    private let codecs: any MediaCodecs
    private let timing: RecordingTiming
    private let log: Log
    private let task = Mutex<Task<Void, Never>?>(nil)
    /// `CameraConfiguration.recordingQualityMode` (`MediaFit.recording`).
    let qualityMode: RecordingQualityMode
    /// The camera's timestamp overlay (nil: none); while it is on every picture is transcoded and drawn on.
    let overlay: TimestampOverlayControl?
    /// Whether this producer reads the sub stream (`CameraConfiguration.recordingStreamMode`; `CameraStatus`).
    let usesSubStream: Bool

    init(streamID: Int, configuration: CameraRecordingConfiguration, audioActive: Bool, cameraAudioEnabled: Bool, hub: MediaHub,
         traits: StreamTraits = StreamTraits(), codecs: any MediaCodecs, timing: RecordingTiming, log: Log,
         qualityMode: RecordingQualityMode = .matchHubRequest, usesSubStream: Bool = false, overlay: TimestampOverlayControl? = nil) {
        self.streamID = streamID
        self.configuration = configuration
        self.audioActive = audioActive
        self.cameraAudioEnabled = cameraAudioEnabled
        self.hub = hub
        self.traits = traits
        self.codecs = codecs
        self.timing = timing
        self.log = log
        self.qualityMode = qualityMode
        self.usesSubStream = usesSubStream
        self.overlay = overlay
    }

    /// The controller's reading may fall behind by this many packets (an initialization segment or a fragment each: about 30 s of
    /// video) before the stream is ended. Unbounded, a stalled HDS connection let the producer queue up to `maximumDuration` of
    /// fragments in memory; a gap in the packets would corrupt the recording, so the stream ends instead of dropping any.
    static let queuedPacketLimit = 8

    /// The consumer stopped reading and `queuedPacketLimit` packets are waiting.
    struct ConsumerTooSlow: Error {}

    /// Starts producing. The stream holds at most `queuedPacketLimit` packets: a consumer that falls further behind ends the
    /// stream (the recording stops with an error; the controller starts another) with one warning.
    func start() -> AsyncThrowingStream<RecordingPacket, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RecordingPacket.self, bufferingPolicy: .bufferingOldest(Self.queuedPacketLimit))
        let producer = Task { [self] in await run(continuation) }
        task.withLock { $0 = producer }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }

    func cancel() {
        task.withLock { $0 }?.cancel()
    }

    // MARK: - Production

    private struct Output {
        var muxer: FMP4Muxer
        var fragments = 0
        var lastFragmentAt: ContinuousClock.Instant?
    }

    private func run(_ continuation: AsyncThrowingStream<RecordingPacket, any Error>.Continuation) async {
        let started = ContinuousClock.now
        let prebuffer = Duration.milliseconds(max(0, configuration.prebufferLengthMs))
        let subscription = await hub.subscribe(from: .prebuffer(prebuffer), bufferLimit: 900)
        var pipeline = Pipeline(producer: self)
        if !traits.usesBFrames, let anchor = await hub.lastKeyframeArrival {   // reordered sources keep the whole replay
            pipeline.prebufferStart = Self.prebufferStart(anchor: anchor, prebuffer: prebuffer, now: .now)
        }
        defer {
            subscription.cancel()
            pipeline.invalidate()
        }
        do {
            for await sample in subscription.samples {
                try Task.checkCancellation()
                let isLast = ContinuousClock.now - started >= timing.maximumDuration
                if try await pipeline.process(sample, isLast: isLast, continuation: continuation) {
                    continuation.finish()
                    log.info("Recording stream \(streamID) "
                             + (pipeline.endReason ?? "reached \(Self.seconds(timing.maximumDuration)) s") + "; last fragment sent")
                    return
                }
            }
            try Task.checkCancellation()
            // The hub went away (runtime stopping): what is open goes out as the last fragment.
            try await pipeline.flush(continuation: continuation)
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch is ConsumerTooSlow {
            log.warning("Recording stream \(streamID): the controller reads its fragments too slowly (\(Self.queuedPacketLimit) are waiting); ending the stream")
            continuation.finish(throwing: HDSProtocolReason.unexpectedFailure)
        } catch {
            log.warning("Recording stream \(streamID) failed: \(error)")
            continuation.finish(throwing: HDSProtocolReason.unexpectedFailure)
        }
    }

    /// Per-stream state, owned by the producer task.
    private struct Pipeline {
        let producer: RecordingProducer
        var rebaser = TimelineRebaser()
        var fragmenter: GOPFragmenter
        var decided = false
        var transcoder: (any VideoTranscoding)?
        /// What `transcoder` was made with (a failing one is replaced with the same).
        var transcoderSettings: VideoEncoderSettings?
        /// `transcoder` failures since its last output.
        var transcodeFailures = 0
        var audioPlan = RecordingAudioPlan.none
        var audioFormat: AudioFormat?
        var output: Output?
        var silentCursor: MediaTime?
        var lastVideo: EncodedVideoFrame?
        var frameInterval = MediaTime(value: 3_000, timescale: 90_000)
        /// Why the stream ended before its maximum duration.
        var endReason: String?
        /// Camera audio → the audio track, for one input format: the transcoder chosen at the start, or one made when the
        /// camera came back with other audio (nil converter: that format cannot be converted, and is dropped).
        var audioConverter: (input: AudioFormat, converter: (any AudioTranscoding)?)?
        /// Decode time of the output keyframe that began the current GOP (output later than the fragment length after it
        /// ends the stream).
        var gopStart: MediaTime?
        /// Transcoded: the source decode time where the requested prebuffer begins inside the replay (which starts at a
        /// keyframe up to a GOP earlier). Earlier frames are decoded (the picture needs them) but not recorded; the first
        /// one from there on gets a keyframe and starts the recording. nil: nothing (more) to skip.
        var prebufferStart: MediaTime?
        var prebufferKeyframeRequested = false
        /// The warning about camera audio that does not line up with its video was given.
        var warnedAudioMisalignment = false

        init(producer: RecordingProducer) {
            self.producer = producer
            fragmenter = GOPFragmenter(targetDuration: .milliseconds(max(1, producer.configuration.fragmentLengthMs)))
        }

        mutating func invalidate() {
            transcoder?.invalidate()
            transcoder = nil
            audioConverter = nil
        }

        /// Handles one hub sample; true when the last fragment went out.
        mutating func process(_ sample: MediaSample, isLast: Bool,
                              continuation: AsyncThrowingStream<RecordingPacket, any Error>.Continuation) async throws -> Bool {
            switch sample {
            case .video(let source):
                if !decided { try await decide(first: source) }
                let frame = rebaser.video(source)
                var trimBefore: MediaTime?
                if let start = prebufferStart {
                    if transcoder != nil, rebaser.discontinuities == 0 {
                        // Pictures before the requested prebuffer are decoded, not recorded (outputs come in display
                        // order: B-frame sources hold some back); the first picture from there on is a keyframe.
                        trimBefore = start
                        if (source.dts ?? source.pts) >= start, !prebufferKeyframeRequested {
                            prebufferKeyframeRequested = true
                            transcoder?.requestKeyframe()
                        }
                    } else {
                        prebufferStart = nil   // passthrough, or a new timeline: nothing to skip
                    }
                }
                guard let transcoded = try await transcode(frame) else { return false }
                var outputs = transcoded
                if let trimBefore {
                    outputs = outputs.drop { $0.pts < trimBefore }.map { $0 }
                    if !outputs.isEmpty { prebufferStart = nil }
                }
                for out in outputs {
                    if output == nil {
                        guard out.isKeyframe else { continue }
                        try start(with: out, continuation: continuation)
                    } else if out.isKeyframe, let muxer = output?.muxer, !muxer.accepts(video: out.format) {
                        // New parameter sets (a reconnect at another size): the init segment cannot describe them.
                        // What is open goes out as the last fragment; the hub's next stream starts over.
                        endReason = "ended: the camera's video changed to \(out.format.width)×\(out.format.height)"
                        try await emitLast(fragmenter.flushGroups(), continuation: continuation)
                        return true
                    } else if let start = gopStart, (out.dts ?? out.pts).seconds - start.seconds > gopLimit,
                              transcoder == nil || step(to: out) > Self.videoGap {
                        // The open fragment cannot end within the fragment length any more: a passed-through GOP outgrew
                        // it (a smart codec, or a GOP not yet measured when the stream started), or the video comes back
                        // after a gap on either path (a lost IDR — the depacketizer drops its whole GOP —, a stall, a
                        // keyframe the decoder rejected), which would stretch the fragment's last picture over the gap.
                        // What fits goes out, the last fragment ending before this frame; the hub's next stream starts
                        // over (and decides again knowing the GOP). (The encoder's keyframe may land up to a frame after
                        // its interval: only a gap ends a transcoded stream.)
                        let fragment = producer.configuration.fragmentLengthMs
                        let gap = step(to: out)
                        if gap > Self.videoGap {
                            endReason = "ended: the video stopped for \(String(format: "%.1f", gap)) s, more than the \(fragment) ms fragment can hold"
                        } else {
                            endReason = "ended: the camera's GOP is longer than the \(fragment) ms fragment"
                        }
                        try await emitOpenGroupAsLast(continuation: continuation)
                        return true
                    }
                    if out.isKeyframe { gopStart = out.dts ?? out.pts }
                    // A keyframe can close two groups (a GOP that did not fit, then the fragment it starts): only the
                    // second may be the last.
                    let groups = fragmenter.pushGroups(.video(out))
                    for (index, group) in groups.enumerated() {
                        if try await emit(group, isLast: isLast && index == groups.count - 1, continuation: continuation) { return true }
                    }
                    lastVideo = out
                }
            case .audio(let frame):
                guard decided, audioPlan == .passthrough || audioPlan == .transcode else { return false }
                let frame = rebaser.audio(frame)
                let frames: [EncodedAudioFrame]
                if audioPlan == .passthrough, fitsAudioTrack(frame.format) {
                    frames = [frame]   // what the audio track describes, as is
                } else {
                    // The track's converter, or one for the audio the camera came back with (any codec).
                    guard let converter = audioConverter(for: frame.format) else { return false }
                    do {
                        frames = try converter.transcode(frame)
                    } catch {
                        producer.log.debug("Recording stream \(producer.streamID): dropping one audio frame (\(error))")
                        return false
                    }
                }
                for audio in frames {
                    for group in fragmenter.pushGroups(.audio(audio)) {
                        if try await emit(group, isLast: isLast, continuation: continuation) { return true }
                    }
                }
            }
            return false
        }

        /// The frame as it goes into the fragmenter: as is (passthrough), or what the transcoder made of it. A frame the
        /// transcoder fails on (a keyframe the decoder rejects, a VideoToolbox hiccup) is dropped, as live view drops it:
        /// the transcoder waits for the next keyframe, and the recording goes on from there (nil). A second failure in
        /// a row gets a new transcoder; a third ends the stream (`unexpectedFailure`): it records nothing any more.
        private mutating func transcode(_ frame: EncodedVideoFrame) async throws -> [EncodedVideoFrame]? {
            guard let transcoder else { return [frame] }
            do {
                let outputs = try await transcoder.transcode(frame)
                if !outputs.isEmpty { transcodeFailures = 0 }
                return outputs
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                transcodeFailures += 1
                guard transcodeFailures < Self.transcodeFailureLimit else { throw error }
                let what = frame.isKeyframe ? "keyframe" : "frame"
                producer.log.warning("Recording stream \(producer.streamID): transcoding failed for one \(what) (\(error)); "
                                     + "dropping it and going on from the next keyframe")
                if transcodeFailures > 1, let settings = transcoderSettings {
                    transcoder.invalidate()
                    self.transcoder = try producer.codecs.makeVideoTranscoder(
                        output: settings, overlay: producer.overlay.flatMap { $0.isEnabled ? $0.provider(for: producer.hub) : nil })
                }
                return nil
            }
        }

        /// Transcoder failures in a row (with no output in between) that end the stream.
        static let transcodeFailureLimit = 3

        /// A step between two pictures longer than this (seconds) is a gap in the video (cameras send at least one a
        /// second): a lost GOP, a stall, a keyframe the decoder rejected.
        static let videoGap = 1.0

        /// Seconds from the previous picture that went into the fragmenter to `frame` (0 for the first).
        private func step(to frame: EncodedVideoFrame) -> Double {
            (lastVideo?.dts ?? lastVideo?.pts).map { (frame.dts ?? frame.pts).seconds - $0.seconds } ?? 0
        }

        /// The longest GOP passthrough may carry: the fragment plus the fragmenter's jitter allowance (`MediaFit`).
        private var gopLimit: Double {
            let fragment = producer.configuration.fragmentLengthMs
            return Double(fragment) / 1000 + MediaFit.recordingGOPAllowance(fragmentLengthMs: fragment).timeInterval
        }

        /// Ends the stream with what the fragmenter holds: earlier whole GOPs as one fragment, the current GOP (which
        /// starts at its keyframe) as the last one.
        private mutating func emitOpenGroupAsLast(continuation: AsyncThrowingStream<RecordingPacket, any Error>.Continuation) async throws {
            guard let group = fragmenter.flushGroup(), !group.video.isEmpty else { return }
            guard let split = group.video.lastIndex(where: \.isKeyframe), split > 0 else {
                _ = try await emit(group, isLast: true, continuation: continuation)
                return
            }
            let boundary = group.video[split]
            let earlier = FragmentGroup(video: Array(group.video[..<split]), audio: group.audio.filter { $0.pts < boundary.pts },
                                        nextDecodeTime: boundary.dts ?? boundary.pts)
            let current = FragmentGroup(video: Array(group.video[split...]), audio: group.audio.filter { $0.pts >= boundary.pts })
            _ = try await emit(earlier, isLast: false, continuation: continuation)
            _ = try await emit(current, isLast: true, continuation: continuation)
        }

        /// Whether camera audio in `format` goes into the audio track as is (the muxer's own check once it exists).
        private func fitsAudioTrack(_ format: AudioFormat) -> Bool {
            if let muxer = output?.muxer { return muxer.accepts(audio: format) }
            guard let audioFormat else { return false }
            return format.codec == audioFormat.codec && format.sampleRate == audioFormat.sampleRate && format.channels == audioFormat.channels
        }

        /// The converter from `format` to the audio track: the one made at the start, or — the camera came back with
        /// other audio (any codec) during the recording — a new one; the old one is let go. nil: none can be made, and
        /// that audio is dropped (warned once per format).
        private mutating func audioConverter(for format: AudioFormat) -> (any AudioTranscoding)? {
            if let audioConverter, audioConverter.input == format { return audioConverter.converter }
            let configuration = producer.configuration
            var converter: (any AudioTranscoding)?
            do {
                let bitrate = configuration.audioMaxBitrateKbps > 0 ? configuration.audioMaxBitrateKbps * 1000 : nil
                let created = try producer.codecs.makeAudioTranscoder(
                    input: format, output: AudioEncoderSettings(codec: .aac, sampleRate: configuration.audioSampleRate.hertz,
                                                                channels: max(1, configuration.audioChannels), bitrate: bitrate))
                if fitsAudioTrack(created.outputFormat) { converter = created }
            } catch {}
            producer.log.warning("Recording stream \(producer.streamID): camera audio changed to \(format.codec.rawValue) \(format.sampleRate) Hz / "
                                 + "\(format.channels) ch; " + (converter == nil ? "dropping it until the next recording" : "converting it"))
            audioConverter = (format, converter)
            return converter
        }

        mutating func flush(continuation: AsyncThrowingStream<RecordingPacket, any Error>.Continuation) async throws {
            guard output != nil else { return }
            try await emitLast(fragmenter.flushGroups(), continuation: continuation)
        }

        /// Sends what the fragmenter flushed (one group, or two when one would run past the fragment length); the last
        /// one is the stream's last fragment.
        private mutating func emitLast(_ groups: [FragmentGroup],
                                       continuation: AsyncThrowingStream<RecordingPacket, any Error>.Continuation) async throws {
            let groups = groups.filter { !$0.video.isEmpty }
            for (index, group) in groups.enumerated() {
                _ = try await emit(group, isLast: index == groups.count - 1, continuation: continuation)
            }
        }

        /// Chooses the video path and audio plan at the subscription's first keyframe.
        private mutating func decide(first frame: EncodedVideoFrame) async throws {
            decided = true
            let hub = producer.hub
            let configuration = producer.configuration
            let fps = await hub.measuredFrameRate
            // The longest recent GOP: a smart codec's average can fit while single GOPs overrun the fragment. Not measured
            // yet (fewer than two keyframes since the runtime started), the GOP still open is at least as long as it is old.
            let traits = producer.traits
            var gop = [await hub.measuredGOPDuration, traits.longestGOP].compactMap { $0 }.max()
            if gop == nil, let open = await hub.lastKeyframeArrival { gop = ContinuousClock.now - open.arrival }
            let overlayOn = producer.overlay?.isEnabled ?? false
            switch MediaFit.recording(source: frame.format, frameRate: fps, gop: gop, bFrames: traits.usesBFrames, configuration: configuration,
                                      qualityMode: producer.qualityMode, timestampOverlay: overlayOn) {
            case .passthrough:
                // The replay starts at a source keyframe at most one GOP (≤ the fragment) before the prebuffer.
                prebufferStart = nil
                producer.log.info("Recording stream \(producer.streamID): passing \(frame.format.width)×\(frame.format.height) H.264 through")
            case .transcode(let reason):
                let settings = MediaFit.recordingEncoderSettings(for: configuration, source: frame.format, sourceFrameRate: fps,
                                                                 qualityMode: producer.qualityMode, timestampOverlay: overlayOn)
                transcoder = try producer.codecs.makeVideoTranscoder(output: settings, overlay: overlayOn ? producer.overlay?.provider(for: hub) : nil)
                transcoderSettings = settings
                producer.log.info("Recording stream \(producer.streamID): transcoding to \(settings.width)×\(settings.height) at "
                                  + "\(settings.bitrateKbps) kbit/s (\(reason))")
            }
            let rate = configuration.audioSampleRate.hertz
            let channels = max(1, configuration.audioChannels)
            let source = producer.cameraAudioEnabled ? await hub.audioFormat : nil
            audioPlan = MediaFit.recordingAudio(source: source, audioActive: producer.audioActive, configuration: configuration)
            switch audioPlan {
            case .none:
                audioFormat = nil
            case .passthrough:
                audioFormat = source
            case .silent:
                audioFormat = .aacLC(sampleRate: rate, channels: channels)
            case .transcode:
                guard let source else { break }
                do {
                    let bitrate = configuration.audioMaxBitrateKbps > 0 ? configuration.audioMaxBitrateKbps * 1000 : nil
                    let converter = try producer.codecs.makeAudioTranscoder(input: source,
                                                                           output: AudioEncoderSettings(codec: .aac, sampleRate: rate, channels: channels,
                                                                                                        bitrate: bitrate))
                    audioConverter = (source, converter)
                    audioFormat = converter.outputFormat
                } catch {
                    producer.log.warning("Recording stream \(producer.streamID): camera audio (\(source.codec.rawValue)) cannot be converted "
                                         + "(\(error)); recording silence")
                    audioPlan = .silent
                    audioFormat = .aacLC(sampleRate: rate, channels: channels)
                }
            }
            if audioPlan != .none {
                producer.log.debug("Recording stream \(producer.streamID): audio \(audioPlan) at \(rate) Hz")
            }
        }

        /// Creates the muxer for the first output keyframe and sends the initialization segment.
        private mutating func start(with keyframe: EncodedVideoFrame,
                                    continuation: AsyncThrowingStream<RecordingPacket, any Error>.Continuation) throws {
            let muxer = try FMP4Muxer(configuration: FMP4Configuration(video: keyframe.format, audio: audioFormat))
            output = Output(muxer: muxer)
            if case .dropped = continuation.yield(RecordingPacket(data: muxer.initializationSegment(), isLast: false)) { throw ConsumerTooSlow() }
        }

        /// Muxes and sends one group (after the pacing delay); true when it was the last one.
        private mutating func emit(_ group: FragmentGroup, isLast: Bool,
                                   continuation: AsyncThrowingStream<RecordingPacket, any Error>.Continuation) async throws -> Bool {
            guard var output, !group.video.isEmpty else { return false }
            var group = group
            if audioPlan == .silent { group.audio = try silence(for: group) }
            let data = try output.muxer.fragment(group)
            let statistics = output.muxer.lastFragmentStatistics
            output.fragments += 1
            let index = output.fragments
            if let previous = output.lastFragmentAt {
                let next = previous + producer.timing.fragmentPacing
                if ContinuousClock.now < next { try await Task.sleep(until: next, clock: .continuous) }
            }
            output.lastFragmentAt = .now
            self.output = output
            producer.log.debug("Recording stream \(producer.streamID) fragment \(index): \(data.count) bytes, \(statistics.videoSamples) video / "
                               + "\(statistics.audioSamples) audio samples, \(statistics.skippedVideoFrames) frames skipped, "
                               + "\(statistics.removedNALUnits) NAL units removed, \(statistics.droppedAudioFrames) audio dropped, "
                               + "\(statistics.outOfRangeAudioFrames) audio out of range")
            warnAboutAudioThatDoesNotLineUp(statistics, fragment: index, video: group.video)
            if case .dropped = continuation.yield(RecordingPacket(data: data, isLast: isLast)) { throw ConsumerTooSlow() }
            return isLast
        }

        /// Most of a fragment's audio left out (before the recording's first picture, or seconds after the fragment's end): the
        /// camera's audio clock and video clock do not line up. Said once per stream, with how far apart they are, so a log
        /// shows the offset instead of a recording that is silently quiet.
        private mutating func warnAboutAudioThatDoesNotLineUp(_ statistics: FMP4Muxer.FragmentStatistics, fragment index: Int,
                                                              video: [EncodedVideoFrame]) {
            let lost = statistics.droppedAudioFrames + statistics.outOfRangeAudioFrames
            guard !warnedAudioMisalignment, audioPlan == .passthrough || audioPlan == .transcode, lost >= 10, lost > statistics.audioSamples else { return }
            warnedAudioMisalignment = true
            producer.log.warning("Recording stream \(producer.streamID) fragment \(index): \(lost) of \(lost + statistics.audioSamples) camera audio frames "
                                 + "were left out (\(statistics.droppedAudioFrames) before the recording's first picture or out of order, "
                                 + "\(statistics.outOfRangeAudioFrames) more than \(Int(FMP4Muxer.audioHorizon / .seconds(1))) s after the fragment): "
                                 + "the camera's audio and video are not on one clock (RTSP sender reports vs. arrival; see the RTSP alignment lines)")
        }

        /// Silent AAC covering the group's video span, contiguous with the previous group's.
        private mutating func silence(for group: FragmentGroup) throws -> [EncodedAudioFrame] {
            guard let first = group.video.first, let last = group.video.last else { return [] }
            let configuration = producer.configuration
            let rate = configuration.audioSampleRate.hertz
            let start = (first.dts ?? first.pts).converted(to: Int32(rate))
            let cursor = silentCursor ?? start
            let end = (group.nextDecodeTime ?? ((last.dts ?? last.pts) + frameInterval)).converted(to: Int32(rate))
            if group.video.count >= 2, let previous = group.video.dropLast().last {
                let step = (last.dts ?? last.pts) - (previous.dts ?? previous.pts)
                if step.value > 0 { frameInterval = step }
            }
            let samples = end.value - cursor.value
            guard samples > 0 else { return [] }
            let frames = try producer.codecs.silentAACFrames(duration: .seconds(Double(samples) / Double(rate)), sampleRate: rate,
                                                             channels: max(1, configuration.audioChannels), startPTS: cursor, wallClock: first.wallClock)
            silentCursor = MediaTime(value: cursor.value + Int64(frames.reduce(0) { $0 + $1.sampleCount }), timescale: Int32(rate))
            return frames
        }
    }

    static func seconds(_ duration: Duration) -> String { MediaFit.seconds(duration) }

    /// The source decode time `prebuffer` before `now`: the hub's last keyframe (`anchor`, with its arrival on the hub's
    /// monotonic clock) moved forward by its age gives the live edge on the source timeline. The replay starts at the
    /// newest keyframe at least `prebuffer` old — up to a GOP before this point.
    static func prebufferStart(anchor: (frame: EncodedVideoFrame, arrival: ContinuousClock.Instant), prebuffer: Duration,
                               now: ContinuousClock.Instant) -> MediaTime {
        let keyframe = anchor.frame.dts ?? anchor.frame.pts
        let offset = max(.zero, now - anchor.arrival) - prebuffer
        return keyframe + .seconds(offset.timeInterval, timescale: keyframe.timescale)
    }
}
