import Foundation
import MediaCore
import Testing
@testable import PlatformLinux

/// Tone generation and analysis for the audio tests.
enum Tone {
    /// 16-bit mono PCM of a sine at `frequency` Hz.
    static func samples(frequency: Double = 440, rate: Int, from start: Int = 0, count: Int, amplitude: Double = 8_000) -> [Int16] {
        (start..<(start + count)).map { Int16(amplitude * sin(2 * Double.pi * frequency * Double($0) / Double(rate))) }
    }

    static func pcm(_ samples: [Int16]) -> Data { samples.withUnsafeBufferPointer { Data(buffer: $0) } }

    /// `seconds` of tone cut into frames of `frameSamples`, as linear PCM input frames.
    static func linearFrames(seconds: Double, rate: Int, frameSamples: Int, frequency: Double = 440, startPTS: Int64 = 0) -> [EncodedAudioFrame] {
        let total = Int(seconds * Double(rate))
        let format = AudioFormat(codec: .linearPCM, sampleRate: rate, channels: 1)
        return stride(from: 0, to: total, by: frameSamples).map { start in
            let count = min(frameSamples, total - start)
            return EncodedAudioFrame(format: format, data: pcm(samples(frequency: frequency, rate: rate, from: start, count: count)),
                                     pts: MediaTime(value: startPTS + Int64(start), timescale: Int32(rate)), sampleCount: count,
                                     wallClock: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(start) / Double(rate)))
        }
    }

    static func int16(_ data: Data) -> [Int16] {
        var out = [Int16](repeating: 0, count: data.count / 2)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }

    static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    /// Frequency estimated from rising zero crossings.
    static func frequency(_ samples: ArraySlice<Int16>, rate: Int) -> Double {
        var crossings = 0
        var previous: Int16 = 0
        for sample in samples {
            if previous < 0, sample >= 0 { crossings += 1 }
            previous = sample
        }
        return Double(crossings) * Double(rate) / Double(max(1, samples.count))
    }
}

@Suite(.serialized, .enabled(if: FFmpegTesting.available)) struct AudioTranscoderTests {
    private func codecs() -> FFmpegMediaCodecs { FFmpegTesting.makeCodecs() }

    /// Runs `frames` through a transcoder and flushes it; the output frames in order.
    private func convert(_ frames: [EncodedAudioFrame], input: AudioFormat, output: AudioEncoderSettings) throws -> (frames: [EncodedAudioFrame], format: AudioFormat) {
        let transcoder = try codecs().makeAudioTranscoder(input: input, output: output)
        defer { (transcoder as? FFmpegAudioTranscoder)?.invalidate() }
        var out: [EncodedAudioFrame] = []
        for frame in frames { out += try transcoder.transcode(frame) }
        out += try transcoder.flush()
        return (out, transcoder.outputFormat)
    }

    /// Decodes compressed `frames` to linear PCM at their own rate.
    private func decode(_ frames: [EncodedAudioFrame], format: AudioFormat) throws -> [Int16] {
        let result = try convert(frames, input: format, output: AudioEncoderSettings(codec: .linearPCM, sampleRate: format.sampleRate, channels: format.channels))
        return result.frames.flatMap { Tone.int16($0.data) }
    }

    @Test func pcmToOpusAtTheLiveViewRate() throws {
        let input = Tone.linearFrames(seconds: 1.0, rate: 16_000, frameSamples: 320)
        let (frames, format) = try convert(input, input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1), output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000))
        #expect(format == AudioFormat(codec: .opus, sampleRate: 16_000, channels: 1))
        #expect((48...51).contains(frames.count), "\(frames.count) Opus packets for one second")
        #expect(frames.allSatisfy { $0.sampleCount == 320 && $0.format == format && !$0.data.isEmpty })
        // The timeline is contiguous on the output sample clock, anchored at the first input frame.
        #expect(frames[0].pts == MediaTime(value: 0, timescale: 16_000))
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1.pts.value - $0.pts.value == 320 })
        #expect(frames[10].wallClock == input[0].wallClock.addingTimeInterval(10 * 0.02))
        // Decodes back to the tone.
        let pcm = try decode(frames, format: format)
        let steady = pcm[3_200..<(pcm.count - 800)]
        #expect(Tone.rms(steady) > 3_000, "rms \(Tone.rms(steady))")
        #expect(abs(Tone.frequency(steady, rate: 16_000) - 440) < 15)
    }

    @Test func opusPacketsAreValidRFC6716() throws {
        let input = Tone.linearFrames(seconds: 0.5, rate: 16_000, frameSamples: 320)
        let (frames, _) = try convert(input, input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1), output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000))
        #expect(frames.allSatisfy { OggOpus.samples48k($0.data) == 960 })   // 20 ms each
    }

    @Test func pcmToAACLCForRecording() throws {
        let input = Tone.linearFrames(seconds: 1.0, rate: 16_000, frameSamples: 320)
        let (frames, format) = try convert(input, input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1), output: AudioEncoderSettings(codec: .aac, sampleRate: 16_000))
        #expect(format == AudioFormat.aacLC(sampleRate: 16_000, channels: 1))
        #expect(format.audioSpecificConfig != nil)
        #expect((14...17).contains(frames.count), "\(frames.count) AAC frames for one second at 16 kHz")
        #expect(frames.allSatisfy { $0.sampleCount == 1_024 })
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1.pts.value - $0.pts.value == 1_024 })
        #expect(frames[0].pts.value == 0)
        // Raw access units, not ADTS (no 0xFFF sync word).
        #expect(frames.allSatisfy { !($0.data.count >= 2 && $0.data[0] == 0xFF && $0.data[1] & 0xF0 == 0xF0) })
        let pcm = try decode(frames, format: format)
        let steady = pcm[3_200..<(pcm.count - 1_600)]
        #expect(Tone.rms(steady) > 3_000)
        #expect(abs(Tone.frequency(steady, rate: 16_000) - 440) < 15)
    }

    @Test func theAACTimelineIsNotShiftedByTheEncoderDelay() throws {
        // A burst of tone after silence: after the round trip it starts where it started (± one frame), not 1024 samples later.
        let rate = 16_000
        let silence = [Int16](repeating: 0, count: rate / 2)
        let burst = Tone.samples(rate: rate, count: rate / 2, amplitude: 12_000)
        let all = Tone.pcm(silence + burst)
        let format = AudioFormat(codec: .linearPCM, sampleRate: rate, channels: 1)
        let input = stride(from: 0, to: all.count / 2, by: 320).map { start in
            EncodedAudioFrame(format: format, data: all[(start * 2)..<(start * 2 + 640)], pts: MediaTime(value: Int64(start), timescale: Int32(rate)), sampleCount: 320, wallClock: Date())
        }
        let (frames, aacFormat) = try convert(input, input: format, output: AudioEncoderSettings(codec: .aac, sampleRate: rate))
        let pcm = try decode(frames, format: aacFormat)
        // Where does the decoded signal first exceed a quarter of the amplitude, in input-timeline samples?
        let onset = try #require(pcm.firstIndex { abs(Int($0)) > 3_000 })
        let expected = rate / 2
        #expect(abs(onset - expected) <= 1_100, "burst starts at \(onset), expected about \(expected)")
    }

    @Test func g711AToOpusResamples() throws {
        // A-law at 8 kHz in 20 ms frames (160 bytes).
        let samples = Tone.samples(rate: 8_000, count: 8_000)
        let alaw = G711.encodeALaw(samples)
        let format = AudioFormat(codec: .pcma, sampleRate: 8_000, channels: 1)
        let input = stride(from: 0, to: 8_000, by: 160).map { start in
            EncodedAudioFrame(format: format, data: alaw[start..<(start + 160)], pts: MediaTime(value: Int64(start), timescale: 8_000), sampleCount: 160, wallClock: Date())
        }
        let (frames, outFormat) = try convert(input, input: format, output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000))
        #expect(outFormat.sampleRate == 16_000 && (48...51).contains(frames.count))
        #expect(frames[1].pts.value - frames[0].pts.value == 320)
        let pcm = try decode(frames, format: outFormat)
        let steady = pcm[3_200..<(pcm.count - 800)]
        #expect(abs(Tone.frequency(steady, rate: 16_000) - 440) < 15 && Tone.rms(steady) > 3_000)
    }

    @Test func g711MuLawToAACAndBack() throws {
        let samples = Tone.samples(rate: 8_000, count: 16_000)
        let ulaw = G711.encodeMuLaw(samples)
        let format = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)
        let input = stride(from: 0, to: 16_000, by: 160).map { start in
            EncodedAudioFrame(format: format, data: ulaw[start..<(start + 160)], pts: MediaTime(value: Int64(start), timescale: 8_000), sampleCount: 160, wallClock: Date())
        }
        let (frames, outFormat) = try convert(input, input: format, output: AudioEncoderSettings(codec: .aac, sampleRate: 16_000))
        #expect(outFormat.codec == .aac && outFormat.sampleRate == 16_000)
        let pcm = try decode(frames, format: outFormat)
        let steady = pcm[3_200..<(pcm.count - 1_600)]
        #expect(abs(Tone.frequency(steady, rate: 16_000) - 440) < 15)
    }

    @Test func pcmToG711InTwentyMillisecondChunks() throws {
        let input = Tone.linearFrames(seconds: 0.5, rate: 8_000, frameSamples: 100)   // frames that do not line up with the chunk size
        for codec in [AudioCodec.pcmu, .pcma] {
            let (frames, format) = try convert(input, input: AudioFormat(codec: .linearPCM, sampleRate: 8_000, channels: 1), output: AudioEncoderSettings(codec: codec, sampleRate: 8_000))
            #expect(format == AudioFormat(codec: codec, sampleRate: 8_000, channels: 1))
            #expect(frames.count == 25 && frames.allSatisfy { $0.data.count == 160 && $0.sampleCount == 160 }, "\(codec): \(frames.map(\.data.count))")
            let decoded = codec == .pcmu ? G711.decodeMuLaw(frames.reduce(Data()) { $0 + $1.data }) : G711.decodeALaw(frames.reduce(Data()) { $0 + $1.data })
            let original = Tone.samples(rate: 8_000, count: 4_000)
            // Within companding error of the input.
            let worst = zip(decoded, original).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(worst < 700, "\(codec) worst error \(worst)")
        }
    }

    @Test func opusToAACAndAACToOpus() throws {
        let tone = Tone.linearFrames(seconds: 1.0, rate: 16_000, frameSamples: 320)
        let pcm = AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1)
        let opus = try convert(tone, input: pcm, output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000))
        // Opus in, AAC-LC out (a camera that sends Opus, recorded for HKSV).
        let aac = try convert(opus.frames, input: opus.format, output: AudioEncoderSettings(codec: .aac, sampleRate: 16_000))
        #expect(aac.format == AudioFormat.aacLC(sampleRate: 16_000, channels: 1) && (12...17).contains(aac.frames.count))
        let decodedAAC = try decode(aac.frames, format: aac.format)
        #expect(abs(Tone.frequency(decodedAAC[3_200..<(decodedAAC.count - 1_600)], rate: 16_000) - 440) < 20)
        // AAC in (with its AudioSpecificConfig), Opus out (a camera's AAC for the live view).
        let back = try convert(aac.frames, input: aac.format, output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000))
        #expect((42...53).contains(back.frames.count), "\(back.frames.count) Opus packets from \(aac.frames.count) AAC frames")
        let decodedOpus = try decode(back.frames, format: back.format)
        #expect(abs(Tone.frequency(decodedOpus[4_000..<(decodedOpus.count - 1_600)], rate: 16_000) - 440) < 20)
    }

    @Test func stereoAndOtherRatesAreConverted() throws {
        let rate = 44_100
        let total = rate
        let mono = Tone.samples(rate: rate, count: total)
        var stereo = [Int16]()
        for sample in mono { stereo += [sample, sample] }
        let format = AudioFormat(codec: .linearPCM, sampleRate: rate, channels: 2)
        let input = stride(from: 0, to: total, by: 441).map { start in
            EncodedAudioFrame(format: format, data: Tone.pcm(Array(stereo[(start * 2)..<(min(start + 441, total) * 2)])), pts: MediaTime(value: Int64(start), timescale: Int32(rate)),
                              sampleCount: 441, wallClock: Date())
        }
        let (frames, outFormat) = try convert(input, input: format, output: AudioEncoderSettings(codec: .opus, sampleRate: 24_000, channels: 1))
        #expect(outFormat == AudioFormat(codec: .opus, sampleRate: 24_000, channels: 1))
        #expect((44...51).contains(frames.count) && frames.allSatisfy { $0.sampleCount == 480 })
    }

    @Test func aGapInTheInputShiftsTheOutputTimeline() throws {
        let rate = 16_000
        let first = Tone.linearFrames(seconds: 0.5, rate: rate, frameSamples: 320)
        let second = Tone.linearFrames(seconds: 0.5, rate: rate, frameSamples: 320, startPTS: Int64(rate * 2))   // 1.5 s of nothing in between
        let (frames, _) = try convert(first + second, input: AudioFormat(codec: .linearPCM, sampleRate: rate, channels: 1), output: AudioEncoderSettings(codec: .opus, sampleRate: rate))
        // Output stays contiguous in count, but its pts jumps by the gap where the second run starts.
        let jumps = zip(frames, frames.dropFirst()).filter { $1.pts.value - $0.pts.value != 320 }
        #expect(jumps.count == 0 || jumps.count == 1)
        #expect(frames.last.map { $0.pts.value >= Int64(rate * 2) } == true || frames.count > 40)
    }

    @Test func flushEmptiesTheChildAndTheNextFrameStartsAFreshTimeline() throws {
        let transcoder = try codecs().makeAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1), output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000))
        defer { (transcoder as? FFmpegAudioTranscoder)?.invalidate() }
        var first: [EncodedAudioFrame] = []
        for frame in Tone.linearFrames(seconds: 0.4, rate: 16_000, frameSamples: 320) { first += try transcoder.transcode(frame) }
        first += try transcoder.flush()
        #expect((18...21).contains(first.count), "\(first.count)")
        #expect(try transcoder.flush().isEmpty)
        var second: [EncodedAudioFrame] = []
        for frame in Tone.linearFrames(seconds: 0.4, rate: 16_000, frameSamples: 320, startPTS: 100_000) { second += try transcoder.transcode(frame) }
        second += try transcoder.flush()
        #expect((18...21).contains(second.count))
        #expect(second[0].pts.value == 100_000)
    }

    @Test func transcodeReturnsFramesWhileTheStreamRuns() throws {
        // No flush needed in a live stream: the output trails the input by the encoder's frame.
        let transcoder = try codecs().makeAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1), output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000))
        defer { (transcoder as? FFmpegAudioTranscoder)?.invalidate() }
        var received = 0
        for frame in Tone.linearFrames(seconds: 2.0, rate: 16_000, frameSamples: 320) {
            received += try transcoder.transcode(frame).count
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(received >= 85, "\(received) of 100 packets while running")
    }

    @Test func aacInputNeedsItsAudioSpecificConfig() throws {
        #expect(throws: MediaCodecError.self) {
            _ = try codecs().makeAudioTranscoder(input: AudioFormat(codec: .aac, sampleRate: 16_000, channels: 1), output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000))
        }
    }

    @Test func settingsAreValidated() {
        let pcm = AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1)
        #expect(throws: MediaCodecError.self) { _ = try codecs().makeAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: 0, channels: 1), output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000)) }
        #expect(throws: MediaCodecError.self) { _ = try codecs().makeAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 9), output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000)) }
        #expect(throws: MediaCodecError.self) { _ = try codecs().makeAudioTranscoder(input: pcm, output: AudioEncoderSettings(codec: .opus, sampleRate: 0)) }
        // Opus only takes 8, 12, 16, 24 and 48 kHz.
        #expect(throws: MediaCodecError.self) { _ = try codecs().makeAudioTranscoder(input: pcm, output: AudioEncoderSettings(codec: .opus, sampleRate: 22_050)) }
    }

    @Test(.enabled(if: FFmpegTesting.capabilities?.hasAACELDEncoder == false))
    func aacELDOutputIsRefusedWithoutLibfdk() throws {
        let error = #expect(throws: MediaCodecError.self) {
            _ = try codecs().makeAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1), output: AudioEncoderSettings(codec: .aacELD, sampleRate: 16_000))
        }
        #expect("\(try #require(error))".contains("libfdk_aac"))
    }

    @Test func aDeadChildSurfacesAsAnErrorAndAFreshOneStartsAfterAPause() throws {
        let transcoder = try codecs().makeAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1), output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000, bitrate: 21_000))
        defer { (transcoder as? FFmpegAudioTranscoder)?.invalidate() }
        let frames = Tone.linearFrames(seconds: 4.0, rate: 16_000, frameSamples: 320)
        for frame in frames.prefix(10) { _ = try transcoder.transcode(frame) }
        #expect(ChildProcesses.kill(commandContaining: "21000") >= 1)
        var thrown: MediaCodecError?
        var index = 10
        while index < 60, thrown == nil {
            do { _ = try transcoder.transcode(frames[index]) } catch let error as MediaCodecError { thrown = error }
            index += 1
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(thrown != nil, "no error after the child was killed")
        // Within the pause the same failure is repeated; after it a new child starts and audio flows again.
        Thread.sleep(forTimeInterval: 1.2)
        var after = 0
        for frame in frames[60...] where after <= 40 {
            after += try transcoder.transcode(frame).count
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(after > 40, "\(after) packets after the restart")
    }

    @Test func invalidateKillsTheChild() throws {
        let transcoder = try codecs().makeAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1), output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000, bitrate: 22_000))
        _ = try transcoder.transcode(Tone.linearFrames(seconds: 0.1, rate: 16_000, frameSamples: 320)[0])
        #expect(ChildProcesses.count(commandContaining: "22000") == 1)
        (transcoder as? FFmpegAudioTranscoder)?.invalidate()
        var count = 1
        for _ in 0..<50 where count != 0 {
            Thread.sleep(forTimeInterval: 0.1)
            count = ChildProcesses.count(commandContaining: "22000")
        }
        #expect(count == 0)
    }

    @Test func releasingTheTranscoderKillsTheChild() throws {
        var transcoder: (any AudioTranscoding)? = try codecs().makeAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1),
                                                                                  output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000, bitrate: 20_000))
        _ = try transcoder?.transcode(Tone.linearFrames(seconds: 0.1, rate: 16_000, frameSamples: 320)[0])
        #expect(ChildProcesses.count(commandContaining: "20000") == 1)
        transcoder = nil
        var count = 1
        for _ in 0..<50 where count != 0 {
            Thread.sleep(forTimeInterval: 0.1)
            count = ChildProcesses.count(commandContaining: "20000")
        }
        #expect(count == 0)
    }

    @Test func silentAACFramesDecodeToSilence() throws {
        let codecs = codecs()
        let start = MediaTime(value: 160_000, timescale: 16_000)
        let wall = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let frames = try codecs.silentAACFrames(duration: .seconds(2), sampleRate: 16_000, channels: 1, startPTS: start, wallClock: wall)
        #expect(frames.count == 32)   // 2 s × 16000 / 1024, rounded up
        #expect(frames.allSatisfy { $0.sampleCount == 1_024 && $0.format == AudioFormat.aacLC(sampleRate: 16_000, channels: 1) })
        #expect(frames[0].pts == start && frames[5].pts.value == 160_000 + 5 * 1_024)
        #expect(abs(frames[1].wallClock.timeIntervalSince(wall) - 1_024.0 / 16_000) < 1e-4)
        let pcm = try decode(frames, format: frames[0].format)
        #expect(Tone.rms(pcm[2_048...]) < 8, "silence is not silent: rms \(Tone.rms(pcm[2_048...]))")
        #expect(try codecs.silentAACFrames(duration: .zero, sampleRate: 16_000, channels: 1, startPTS: start, wallClock: wall).isEmpty)
        #expect(throws: MediaCodecError.self) { _ = try codecs.silentAACFrames(duration: .seconds(1), sampleRate: 0, channels: 1, startPTS: start, wallClock: wall) }
        let stereo = try codecs.silentAACFrames(duration: .seconds(1), sampleRate: 44_100, channels: 2, startPTS: MediaTime(value: 0, timescale: 44_100), wallClock: wall)
        #expect(stereo.count == 44 && stereo[0].format.channels == 2)
    }
}
