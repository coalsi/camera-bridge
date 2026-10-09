#if os(macOS)
import Foundation
import MediaCore
import PlatformApple
import Testing
@testable import PlatformLinux

/// What ffmpeg writes must be what Apple's decoders read (the controller is Apple's), and what Apple's encoders write must be
/// what ffmpeg reads (HomeKit talkback is AAC-ELD or Opus from Apple's side). macOS only: AudioToolbox and VideoToolbox.
@Suite(.serialized, .enabled(if: FFmpegTesting.available)) struct AppleInteropTests {
    private let apple = AppleMediaCodecs()

    /// HomeKit's AAC-ELD, made by Apple's encoder. ffmpeg's native AAC decoder rejects every one of these access units with
    /// AVERROR_BUG ("Internal bug, should not have happened", ffmpeg 7.1.5 and 8.x), so AAC-ELD cannot be decoded on the Linux box;
    /// the streaming configuration offers Opus only (`StreamingConfiguration` in HAPCamera), which is why nothing needs it. The
    /// test records the limitation and starts to complain (known issue not hit) if an ffmpeg ever decodes it.
    private func appleELD() throws -> (frames: [EncodedAudioFrame], format: AudioFormat) {
        let pcm = AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1)
        let encoder = try apple.makeAudioTranscoder(input: pcm, output: AudioEncoderSettings(codec: .aacELD, sampleRate: 16_000))
        var eld: [EncodedAudioFrame] = []
        for frame in Tone.linearFrames(seconds: 1.0, rate: 16_000, frameSamples: 320) { eld += try encoder.transcode(frame) }
        eld += try encoder.flush()
        #expect(encoder.outputFormat.codec == .aacELD && encoder.outputFormat.audioSpecificConfig != nil && eld.count > 20)
        return (eld, encoder.outputFormat)
    }

    @Test func aacELDFromAudioToolboxIsNotDecodedByFFmpeg() throws {
        let (eld, format) = try appleELD()
        withKnownIssue("ffmpeg's native AAC decoder cannot read Apple's AAC-ELD", isIntermittent: true) {
            let decoder = try FFmpegTesting.makeCodecs().makeAudioTranscoder(input: format, output: AudioEncoderSettings(codec: .linearPCM, sampleRate: 16_000))
            var out: [EncodedAudioFrame] = []
            for frame in eld { out += try decoder.transcode(frame) }
            out += try decoder.flush()
            let samples = out.flatMap { Tone.int16($0.data) }
            #expect(samples.count > 12_000, "\(samples.count) samples from \(eld.count) ELD frames")
            let steady = samples[4_000..<(samples.count - 1_000)]
            #expect(abs(Tone.frequency(steady, rate: 16_000) - 440) < 20)
        }
    }

    @Test(.enabled(if: FFmpegTesting.capabilities?.decoders.contains("libfdk_aac") == false))
    func aacELDInputIsRefusedUpFront() throws {
        // Without libfdk_aac the talkback converter is not made at all, with the reason in the error (not a child that fails later).
        let (_, format) = try appleELD()
        let error = #expect(throws: MediaCodecError.self) {
            _ = try FFmpegTesting.makeCodecs().makeAudioTranscoder(input: format, output: AudioEncoderSettings(codec: .pcmu, sampleRate: 8_000))
        }
        #expect("\(try #require(error))".contains("libfdk_aac"))
    }

    @Test func opusFromFFmpegDecodesInAudioToolbox() throws {
        // What we send the controller for the live view: Opus from libopus, read by Apple's Opus decoder.
        let linux = FFmpegTesting.makeCodecs()
        let pcm = AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1)
        let encoder = try linux.makeAudioTranscoder(input: pcm, output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000))
        var opus: [EncodedAudioFrame] = []
        for frame in Tone.linearFrames(seconds: 1.0, rate: 16_000, frameSamples: 320) { opus += try encoder.transcode(frame) }
        opus += try encoder.flush()
        let decoder = try apple.makeAudioTranscoder(input: encoder.outputFormat, output: AudioEncoderSettings(codec: .linearPCM, sampleRate: 16_000))
        var out: [EncodedAudioFrame] = []
        for frame in opus { out += try decoder.transcode(frame) }
        out += try decoder.flush()
        let samples = out.flatMap { Tone.int16($0.data) }
        #expect(samples.count > 12_000)
        let steady = samples[3_200..<(samples.count - 800)]
        #expect(Tone.rms(steady) > 3_000 && abs(Tone.frequency(steady, rate: 16_000) - 440) < 20)
    }

    @Test func aacLCFromFFmpegDecodesInAudioToolbox() throws {
        // The recording track: ffmpeg's raw AAC-LC access units with the AudioSpecificConfig we declare.
        let linux = FFmpegTesting.makeCodecs()
        let pcm = AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1)
        let encoder = try linux.makeAudioTranscoder(input: pcm, output: AudioEncoderSettings(codec: .aac, sampleRate: 16_000))
        var aac: [EncodedAudioFrame] = []
        for frame in Tone.linearFrames(seconds: 1.0, rate: 16_000, frameSamples: 320) { aac += try encoder.transcode(frame) }
        aac += try encoder.flush()
        let decoder = try apple.makeAudioTranscoder(input: encoder.outputFormat, output: AudioEncoderSettings(codec: .linearPCM, sampleRate: 16_000))
        var out: [EncodedAudioFrame] = []
        for frame in aac { out += try decoder.transcode(frame) }
        out += try decoder.flush()
        let samples = out.flatMap { Tone.int16($0.data) }
        #expect(samples.count > 10_000)
        let steady = samples[3_200..<(samples.count - 1_600)]
        #expect(abs(Tone.frequency(steady, rate: 16_000) - 440) < 20)
    }

    @Test func appleAACFramesDecodeInFFmpeg() throws {
        // A camera's AAC is raw access units plus an AudioSpecificConfig; Apple's encoder makes the same thing.
        let linux = FFmpegTesting.makeCodecs()
        let pcm = AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1)
        let encoder = try apple.makeAudioTranscoder(input: pcm, output: AudioEncoderSettings(codec: .aac, sampleRate: 16_000))
        var aac: [EncodedAudioFrame] = []
        for frame in Tone.linearFrames(seconds: 1.0, rate: 16_000, frameSamples: 320) { aac += try encoder.transcode(frame) }
        aac += try encoder.flush()
        let decoder = try linux.makeAudioTranscoder(input: encoder.outputFormat, output: AudioEncoderSettings(codec: .linearPCM, sampleRate: 16_000))
        var out: [EncodedAudioFrame] = []
        for frame in aac { out += try decoder.transcode(frame) }
        out += try decoder.flush()
        let samples = out.flatMap { Tone.int16($0.data) }
        let steady = samples[3_200..<(samples.count - 1_600)]
        #expect(Tone.rms(steady) > 3_000 && abs(Tone.frequency(steady, rate: 16_000) - 440) < 20)
    }

    @Test func h264FromFFmpegDecodesInVideoToolbox() async throws {
        // The live view and recording carry ffmpeg's H.264 to Apple's decoder: parameter sets, AVCC framing and keyframes must be accepted.
        let source = try FFmpegTesting.sourceFrames(width: 640, height: 360, fps: 25, seconds: 2, gop: 25)
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: VideoEncoderSettings(width: 480, height: 270, fps: 25, bitrateKbps: 800,
                                                                                                         profile: .main, level: .level3_1, keyframeInterval: .seconds(1)))
        defer { transcoder.invalidate() }
        var out: [EncodedVideoFrame] = []
        for frame in source {
            out += try await transcoder.transcode(frame)
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(out.count >= source.count - 4)
        let decoder = try apple.makeVideoDecoder(format: out[0].format)
        defer { decoder.invalidate() }
        var decoded = 0
        for frame in out {
            if try await decoder.decode(frame) != nil { decoded += 1 }
        }
        #expect(decoded >= out.count - 2, "VideoToolbox decoded \(decoded) of \(out.count)")
        let picture = try #require(try await apple.makeVideoDecoder(format: out[0].format).decode(out[0]))
        #expect(picture.width == 480 && picture.height == 270)
    }

    @Test func h264FromVideoToolboxTranscodesInFFmpeg() async throws {
        // A camera's H.264 (here made by VideoToolbox) goes through the Linux transcoder.
        let pattern = apple.makeSyntheticSource(displayName: "Mac demo", width: 640, height: 360, fps: 25, keyframeInterval: .seconds(1), audio: nil, audioSampleRate: 0)
        let stream = try await pattern.samples()
        var frames: [EncodedVideoFrame] = []
        for try await sample in stream {
            if case .video(let frame) = sample { frames.append(frame) }
            if frames.count >= 60 { break }
        }
        await pattern.stop()
        let transcoder = try FFmpegTesting.makeCodecs().makeVideoTranscoder(output: VideoEncoderSettings(width: 320, height: 180, fps: 25, bitrateKbps: 500,
                                                                                                         profile: .main, level: .level3_1, keyframeInterval: .seconds(1)))
        defer { transcoder.invalidate() }
        var out: [EncodedVideoFrame] = []
        for frame in frames {
            out += try await transcoder.transcode(frame)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(out.count >= frames.count - 5)
        #expect(out[0].isKeyframe && out[0].format.width == 320)
    }
}
#endif
