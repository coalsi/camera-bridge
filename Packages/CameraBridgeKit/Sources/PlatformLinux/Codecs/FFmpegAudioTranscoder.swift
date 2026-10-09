import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// Camera audio (AAC, AAC-ELD, Opus, G.711, PCM) → what HomeKit needs (Opus or AAC-LC, also G.711 or PCM for a camera's
/// return channel), with one ffmpeg child per run. Input and output are framed per codec (`FFmpegArguments.AudioWire`): AAC as
/// FLV, Opus as Ogg, G.711 and PCM as bare samples.
///
/// `transcode` writes the frame and returns the access units ffmpeg has finished so far (it never waits: audio is a steady
/// stream, so the output simply trails the input by the encoder's frame, 20 ms for Opus, 64 ms for AAC at 16 kHz). `flush`
/// ends the child's input, collects what is left and resets the timeline.
///
/// Output timestamps are on the output sample clock and contiguous (`pts[n+1] = pts[n] + sampleCount`), anchored at the first
/// input frame's PTS; an input gap or jump larger than max(100 ms, two input frames) shifts the timeline by the same amount
/// (the logic of `AppleAudioTranscoder`). ffmpeg's AAC encoder starts with 1024 samples of priming: that first access unit is
/// dropped, so the timeline matches the input.
///
/// A child that dies surfaces as a thrown `MediaCodecError`; the next call starts a new one after a pause of one second.
final class FFmpegAudioTranscoder: AudioTranscoding, @unchecked Sendable {
    let outputFormat: AudioFormat
    private let inputFormat: AudioFormat
    private let output: AudioEncoderSettings
    private let runtime: FFmpegRuntime
    private let encoderOptions: [String]
    /// Decoder choice for the input (`-c:a libfdk_aac` for AAC-ELD, which ffmpeg's own decoder cannot read).
    private let decoderOptions: [String]
    private let state = Mutex<State>(State())
    private let live = Mutex<FFmpegSession?>(nil)
    private let invalidatedFlag = Atomic<Bool>(false)
    private let log = Log(category: "AudioTranscoder")

    /// One packet out of ffmpeg: its payload and the samples (per channel, at the output rate) it holds.
    struct Packet: Equatable {
        var data: Data
        var samples: Int
    }

    private final class Pipeline: @unchecked Sendable {
        let session: FFmpegSession
        var oggWriter: OggOpus.Writer?
        var flvReader = FLVReader()
        var oggReader = OggOpus.Reader()
        /// Bytes of raw output not yet a full chunk.
        var pendingRaw = Data()
        var inputSamples: Int64 = 0
        var droppedPriming = false

        init(session: FFmpegSession) {
            self.session = session
        }

        deinit { session.terminate() }
    }

    private struct State {
        var pipeline: Pipeline?
        var anchorPTS: Int64?
        var anchorWallClock = Date()
        var produced: Int64 = 0
        var expectedInputPTS: MediaTime?
        var failedAt: ContinuousClock.Instant?
        var lastFailure: MediaCodecError?
    }

    static let restartPause = Duration.seconds(1)
    static let flushTimeout = Duration.seconds(5)

    init(runtime: FFmpegRuntime, input: AudioFormat, output: AudioEncoderSettings) throws {
        guard input.sampleRate > 0, (1...8).contains(input.channels) else {
            throw MediaCodecError.unsupported("audio input \(input.codec) \(input.sampleRate) Hz × \(input.channels)")
        }
        guard output.sampleRate > 0, (1...8).contains(output.channels) else {
            throw MediaCodecError.unsupported("audio output \(output.codec) \(output.sampleRate) Hz × \(output.channels)")
        }
        _ = try runtime.requireExecutable()
        let capabilities = try runtime.capabilities()
        if input.codec == .aac || input.codec == .aacELD {
            guard let config = input.audioSpecificConfig, !config.isEmpty else {
                throw MediaCodecError.unsupported("\(input.codec) input without an AudioSpecificConfig")
            }
        }
        var decoderOptions: [String] = []
        if input.codec == .aacELD {
            // ffmpeg's native AAC decoder rejects Apple's AAC-ELD ("Internal bug, should not have happened"); libfdk_aac reads it.
            guard capabilities.decoders.contains("libfdk_aac") else {
                throw MediaCodecError.unsupported("AAC-ELD input needs libfdk_aac, which this ffmpeg does not have (ffmpeg's own AAC decoder cannot read AAC-ELD)")
            }
            decoderOptions = ["-c:a", "libfdk_aac"]
        }
        guard let options = FFmpegArguments.audioEncoderOptions(output, available: capabilities.encoders) else {
            let why = output.codec == .aacELD ? "AAC-ELD needs libfdk_aac, which this ffmpeg does not have (it is non-free and not in Debian)"
                : "this ffmpeg has no encoder for \(output.codec.rawValue)"
            throw MediaCodecError.unsupported(why)
        }
        if output.codec == .opus, ![8_000, 12_000, 16_000, 24_000, 48_000].contains(output.sampleRate) {
            throw MediaCodecError.unsupported("Opus at \(output.sampleRate) Hz (8, 12, 16, 24 or 48 kHz)")
        }
        self.runtime = runtime
        inputFormat = input
        self.output = output
        encoderOptions = options
        self.decoderOptions = decoderOptions
        switch output.codec {
        case .aac:
            outputFormat = AudioFormat.aacLC(sampleRate: output.sampleRate, channels: output.channels)
        case .aacELD:
            let channelConfiguration = output.channels == 8 ? 7 : output.channels
            let config = AudioSpecificConfig(objectType: AudioSpecificConfig.aacELD, sampleRate: output.sampleRate, channelConfiguration: channelConfiguration)
            outputFormat = AudioFormat(codec: .aacELD, sampleRate: output.sampleRate, channels: output.channels, audioSpecificConfig: config.encoded)
        case .opus, .pcmu, .pcma, .linearPCM:
            outputFormat = AudioFormat(codec: output.codec, sampleRate: output.sampleRate, channels: output.channels)
        }
    }

    deinit { invalidate() }

    func invalidate() {
        invalidatedFlag.store(true, ordering: .relaxed)
        live.withLock { session in
            session?.terminate()
            session = nil
        }
    }

    // MARK: AudioTranscoding

    func transcode(_ frame: EncodedAudioFrame) throws -> [EncodedAudioFrame] {
        guard !frame.data.isEmpty, !invalidatedFlag.load(ordering: .relaxed) else { return [] }
        return try state.withLock { state in
            let pipeline = try ensurePipeline(&state)
            track(frame, state: &state)
            do {
                try write(frame, to: pipeline)
            } catch {
                throw fail(pipeline, error, state: &state)
            }
            let packets = collect(pipeline, finishing: false)
            if pipeline.session.exit != nil, packets.isEmpty, pipeline.session.bufferedOutputBytes == 0 {
                throw fail(pipeline, pipeline.session.failure, state: &state)
            }
            return emit(packets, state: &state)
        }
    }

    func flush() throws -> [EncodedAudioFrame] {
        try state.withLock { state in
            defer {
                state.anchorPTS = nil
                state.produced = 0
                state.expectedInputPTS = nil
            }
            guard let pipeline = state.pipeline else { return [] }
            state.pipeline = nil
            live.withLock { $0 = nil }
            if var writer = pipeline.oggWriter { try? pipeline.session.send(writer.end()); pipeline.oggWriter = writer }
            pipeline.session.closeInput()
            var packets: [Packet] = []
            let deadline = ContinuousClock.now + Self.flushTimeout
            while ContinuousClock.now < deadline {
                pipeline.session.waitForOutput(timeout: .milliseconds(100))
                packets += collect(pipeline, finishing: false)
                if pipeline.session.exit != nil, pipeline.session.bufferedOutputBytes == 0 { break }
            }
            packets += collect(pipeline, finishing: true)
            let ended = pipeline.session.exit
            let failure = pipeline.session.failure
            pipeline.session.terminate()
            if ended == nil { log.warning("ffmpeg (audio transcoder) did not finish within \(Self.flushTimeout / .seconds(1)) s of the flush; it was killed") }
            // What was converted before a failure is still returned; a child that failed and produced nothing is an error.
            if let ended, ended.status != 0 || ended.signaled, packets.isEmpty { throw failure }
            return emit(packets, state: &state)
        }
    }

    // MARK: Child

    private func ensurePipeline(_ state: inout State) throws -> Pipeline {
        if let pipeline = state.pipeline { return pipeline }
        if let failedAt = state.failedAt, ContinuousClock.now - failedAt < Self.restartPause, let failure = state.lastFailure { throw failure }
        let executable = try runtime.requireExecutable()
        let arguments = FFmpegArguments.audioTranscoder(input: inputFormat, output: output, encoder: encoderOptions, decoder: decoderOptions)
        let session = try FFmpegSession(launcher: runtime.launcher, spec: FFmpegProcessSpec(executable: executable, arguments: arguments, label: "audio transcoder"))
        let pipeline = Pipeline(session: session)
        do {
            switch FFmpegArguments.audioInputWire(inputFormat.codec) {
            case .flv:
                try session.send(FLVWriter.fileHeader(video: false, audio: true) + FLVWriter.aacSequenceHeader(audioSpecificConfig: inputFormat.audioSpecificConfig ?? Data()))
            case .ogg:
                var writer = OggOpus.Writer(channels: inputFormat.channels, inputRate: inputFormat.sampleRate)
                try session.send(writer.headers())
                pipeline.oggWriter = writer
            case .raw:
                break
            }
        } catch {
            session.terminate()
            throw error
        }
        state.pipeline = pipeline
        state.failedAt = nil
        live.withLock { $0 = session }
        log.info("ffmpeg audio transcoder started: \(inputFormat.codec.rawValue) \(inputFormat.sampleRate) Hz × \(inputFormat.channels) → \(output.codec.rawValue) \(output.sampleRate) Hz × \(output.channels)")
        return pipeline
    }

    private func fail(_ pipeline: Pipeline, _ error: any Error, state: inout State) -> MediaCodecError {
        let failure = pipeline.session.exit != nil ? pipeline.session.failure : (error as? MediaCodecError) ?? .unsupported("\(error)")
        pipeline.session.terminate()
        live.withLock { $0 = nil }
        state.pipeline = nil
        state.failedAt = .now
        state.lastFailure = failure
        state.anchorPTS = nil
        state.produced = 0
        state.expectedInputPTS = nil
        return failure
    }

    private func write(_ frame: EncodedAudioFrame, to pipeline: Pipeline) throws {
        switch FFmpegArguments.audioInputWire(inputFormat.codec) {
        case .raw:
            try pipeline.session.send(frame.data)
        case .ogg:
            guard var writer = pipeline.oggWriter else { return }
            let page = writer.packet(frame.data)
            pipeline.oggWriter = writer
            try pipeline.session.send(page)
        case .flv:
            let samples = Int64(inputSampleCount(frame))
            let milliseconds = pipeline.inputSamples * 1_000 / Int64(max(1, inputFormat.sampleRate))
            pipeline.inputSamples += samples
            try pipeline.session.send(FLVWriter.aacFrame(frame.data, timestamp: UInt32(clamping: milliseconds)))
        }
    }

    /// The complete packets ffmpeg has written. `finishing`: the last, short chunk of raw output too.
    private func collect(_ pipeline: Pipeline, finishing: Bool) -> [Packet] {
        let bytes = pipeline.session.drain()
        var packets: [Packet] = []
        switch FFmpegArguments.audioOutputWire(output.codec) {
        case .flv:
            for tag in pipeline.flvReader.push(bytes) {
                guard case .frame(let unit)? = FLVAACPacket.parse(tag) else { continue }
                // The encoder's first access unit is its priming (1024 samples of delay).
                if !pipeline.droppedPriming {
                    pipeline.droppedPriming = true
                    continue
                }
                packets.append(Packet(data: unit, samples: output.codec == .aacELD ? 480 : 1_024))
            }
        case .ogg:
            for packet in pipeline.oggReader.push(bytes) {
                let samples48k = OggOpus.samples48k(packet) ?? 960
                packets.append(Packet(data: packet, samples: samples48k * output.sampleRate / 48_000))
            }
        case .raw:
            pipeline.pendingRaw.append(bytes)
            let bytesPerFrame = (output.codec == .linearPCM ? 2 : 1) * output.channels
            let chunk = max(1, output.sampleRate / 50) * bytesPerFrame
            var offset = 0
            while pipeline.pendingRaw.count - offset >= chunk || (finishing && pipeline.pendingRaw.count - offset >= bytesPerFrame) {
                let length = min(chunk, (pipeline.pendingRaw.count - offset) / bytesPerFrame * bytesPerFrame)
                packets.append(Packet(data: Data(pipeline.pendingRaw[offset..<(offset + length)]), samples: length / bytesPerFrame))
                offset += length
            }
            pipeline.pendingRaw = finishing ? Data() : Data(pipeline.pendingRaw[offset...])
        }
        return packets
    }

    // MARK: Timeline

    /// Anchors the output timeline on the first frame and shifts it when the input jumps.
    private func track(_ frame: EncodedAudioFrame, state: inout State) {
        let rate = Int32(output.sampleRate)
        let inputRate = Int32(inputFormat.sampleRate)
        let pts = frame.pts.converted(to: inputRate)
        if state.anchorPTS == nil {
            state.anchorPTS = pts.converted(to: rate).value
            state.anchorWallClock = frame.wallClock
        } else if let expected = state.expectedInputPTS {
            let jump = pts.value - expected.value
            let tolerance = max(Int64(inputFormat.sampleRate / 10), 2 * Int64(inputSampleCount(frame)))
            if abs(jump) > tolerance {
                let shift = MediaTime(value: jump, timescale: inputRate).converted(to: rate).value
                state.anchorPTS = (state.anchorPTS ?? 0) + shift
                state.anchorWallClock = state.anchorWallClock.addingTimeInterval(Double(shift) / Double(rate))
            }
        }
        state.expectedInputPTS = MediaTime(value: pts.value + Int64(inputSampleCount(frame)), timescale: inputRate)
    }

    private func inputSampleCount(_ frame: EncodedAudioFrame) -> Int {
        if frame.sampleCount > 0 { return frame.sampleCount }
        switch inputFormat.codec {
        case .pcmu, .pcma: return frame.data.count / max(1, inputFormat.channels)
        case .linearPCM: return frame.data.count / max(1, 2 * inputFormat.channels)
        case .aac: return 1_024
        case .aacELD: return 480
        case .opus: return (OggOpus.samples48k(frame.data) ?? 960) * inputFormat.sampleRate / 48_000
        }
    }

    private func emit(_ packets: [Packet], state: inout State) -> [EncodedAudioFrame] {
        let rate = output.sampleRate
        return packets.compactMap { packet in
            guard !packet.data.isEmpty, packet.samples > 0 else { return nil }
            let offset = state.produced
            state.produced += Int64(packet.samples)
            return EncodedAudioFrame(format: outputFormat, data: packet.data, pts: MediaTime(value: (state.anchorPTS ?? 0) + offset, timescale: Int32(rate)),
                                     sampleCount: packet.samples, wallClock: state.anchorWallClock.addingTimeInterval(Double(offset) / Double(rate)))
        }
    }
}
