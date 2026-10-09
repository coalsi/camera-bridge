#if os(macOS)
import AudioToolbox
import CoreMedia
import Foundation
import MediaCore
import Testing
@testable import PlatformApple

@Suite(.timeLimit(.minutes(1))) struct CodecsAudioTranscoderTests {
    let codecs = CodecFixtures.codecs
    let pcmu8k = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)

    /// 2 s of a 440 Hz tone as 20 ms µ-law frames starting at sample 16 000 (2 s).
    var pcmuInput: [EncodedAudioFrame] {
        CodecFixtures.frames(CodecFixtures.tone(frequency: 440, sampleRate: 8_000, seconds: 2), format: pcmu8k, frameSamples: 160, startSample: 16_000)
    }

    @Test func pcmu8kToAACLC32kMono() throws {
        let transcoder = try codecs.makeAudioTranscoder(input: pcmu8k, output: AudioEncoderSettings(codec: .aac, sampleRate: 32_000, channels: 1))
        #expect(transcoder.outputFormat == AudioFormat.aacLC(sampleRate: 32_000, channels: 1))
        #expect(transcoder.outputFormat.audioSpecificConfig == Data([0x12, 0x88]))
        let input = pcmuInput
        var output: [EncodedAudioFrame] = []
        for frame in input { output += try transcoder.transcode(frame) }
        output += try transcoder.flush()
        #expect(output.allSatisfy { $0.format == transcoder.outputFormat && $0.sampleCount == 1024 && !$0.data.isEmpty })
        // The 2112 priming samples fill the first 3 packets and 960 samples of input: those packets are dropped, so the
        // output starts 960 samples after the input (which started at 2 s) and still reaches its end.
        #expect(output.first?.pts == MediaTime(value: 64_000 + 960, timescale: 32_000))
        #expect(960 + output.count * 1024 >= 64_000)              // the 2 s that went in
        #expect(960 + output.count * 1024 <= 64_000 + 1024)       // plus the final packet's padding
        let firstWallClock = try #require(input.first?.wallClock).addingTimeInterval(960.0 / 32_000)
        #expect(abs(try #require(output.first?.wallClock).timeIntervalSince(firstWallClock)) < 1e-6)
        CodecFixtures.expectContiguous(output)

        let decoded = try CodecFixtures.decodeToPCM(output, sampleRate: 32_000)
        #expect(decoded.count >= 64_000 - 960)
        let middle = Array(decoded[16_000..<48_000])
        #expect(CodecFixtures.rms(middle) > 3_000)
        #expect(CodecFixtures.toneRatio(middle, frequency: 440, sampleRate: 32_000) > 0.8)
    }

    @Test func aacLC16kToAACLC32k() throws {
        let pcm16k = AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1)
        let encoder = try codecs.makeAudioTranscoder(input: pcm16k, output: AudioEncoderSettings(codec: .aac, sampleRate: 16_000, channels: 1))
        let tone = CodecFixtures.frames(CodecFixtures.tone(frequency: 700, sampleRate: 16_000, seconds: 2), format: pcm16k, frameSamples: 320)
        let aac16k = try tone.flatMap { try encoder.transcode($0) } + encoder.flush()
        #expect(aac16k.first?.format == AudioFormat.aacLC(sampleRate: 16_000, channels: 1))

        let transcoder = try codecs.makeAudioTranscoder(input: aac16k[0].format, output: AudioEncoderSettings(codec: .aac, sampleRate: 32_000, channels: 1))
        let aac32k = try aac16k.flatMap { try transcoder.transcode($0) } + transcoder.flush()
        #expect(aac32k.allSatisfy { $0.format == AudioFormat.aacLC(sampleRate: 32_000, channels: 1) && $0.sampleCount == 1024 })
        // Each encoder drops its priming: the 16 kHz stream starts 960 samples in, the 32 kHz one 960 more.
        #expect(aac16k.first?.pts == MediaTime(value: 960, timescale: 16_000))
        #expect(aac32k.first?.pts == MediaTime(value: 2 * 960 + 960, timescale: 32_000))
        #expect(try #require(aac32k.last).pts.value + 1024 >= 64_000)
        CodecFixtures.expectContiguous(aac32k)
        let decoded = try CodecFixtures.decodeToPCM(aac32k, sampleRate: 32_000)
        let middle = Array(decoded[16_000..<48_000])
        #expect(CodecFixtures.toneRatio(middle, frequency: 700, sampleRate: 32_000) > 0.8)
    }

    @Test(arguments: [16_000, 24_000])
    func pcmuToOpus(sampleRate: Int) throws {
        let transcoder = try codecs.makeAudioTranscoder(input: pcmu8k, output: AudioEncoderSettings(codec: .opus, sampleRate: sampleRate, channels: 1, bitrate: 24_000))
        #expect(transcoder.outputFormat == AudioFormat(codec: .opus, sampleRate: sampleRate, channels: 1))
        let output = try pcmuInput.flatMap { try transcoder.transcode($0) } + transcoder.flush()
        let frameSamples = sampleRate / 50   // 20 ms
        #expect(output.count >= 100)
        for frame in output {
            #expect(frame.sampleCount == frameSamples)
            #expect(frame.sampleCount * 48_000 / sampleRate == frame.format.samplesPerFrame)   // 960 at the 48 kHz Opus clock
            #expect(!frame.data.isEmpty && frame.data.count < 400)
            // TOC: one 20 ms frame (configs 1, 5, 9 SILK; 13, 15 hybrid; 19, 23, 27, 31 CELT), code 0.
            let toc = frame.data[frame.data.startIndex]
            #expect([1, 5, 9, 13, 15, 19, 23, 27, 31].contains(toc >> 3) && toc & 0x03 == 0, "TOC \(toc)")
        }
        // The input started at 2 s; the first packet (the encoder's 6.5 ms lookahead) is dropped.
        let first = try #require(output.first).pts
        #expect(first.timescale == Int32(sampleRate) && (Int64(2 * sampleRate + 1)..<Int64(2 * sampleRate + frameSamples)).contains(first.value))
        CodecFixtures.expectContiguous(output)
    }

    @Test func opusToPCMU8kForTalkback() throws {
        let toOpus = try codecs.makeAudioTranscoder(input: pcmu8k, output: AudioEncoderSettings(codec: .opus, sampleRate: 16_000, channels: 1))
        let opus = try pcmuInput.flatMap { try toOpus.transcode($0) } + toOpus.flush()
        let transcoder = try codecs.makeAudioTranscoder(input: opus[0].format, output: AudioEncoderSettings(codec: .pcmu, sampleRate: 8_000, channels: 1))
        #expect(transcoder.outputFormat == pcmu8k)
        let output = try opus.flatMap { try transcoder.transcode($0) } + transcoder.flush()
        // 20 ms chunks; only the flushed tail may be shorter.
        #expect(output.allSatisfy { $0.format == pcmu8k && $0.data.count == $0.sampleCount })
        #expect(output.dropLast().allSatisfy { $0.sampleCount == 160 })
        #expect((1...160).contains(output.last?.sampleCount ?? 0))
        let total = output.reduce(0) { $0 + $1.sampleCount }
        #expect(total >= 15_000 && total <= 17_000)
        CodecFixtures.expectContiguous(output)
        let pcm = G711.decodeMuLaw(output.reduce(into: Data()) { $0.append($1.data) })
        let middle = Array(pcm[4_000..<12_000])
        #expect(CodecFixtures.rms(middle) > 2_000)
        #expect(CodecFixtures.toneRatio(middle, frequency: 440, sampleRate: 8_000) > 0.7)
    }

    @Test func aacELD16kEncodesAndDecodes() throws {
        let pcm16k = AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1)
        let encoder = try codecs.makeAudioTranscoder(input: pcm16k, output: AudioEncoderSettings(codec: .aacELD, sampleRate: 16_000, channels: 1))
        let eld = encoder.outputFormat
        #expect(eld.codec == .aacELD && eld.sampleRate == 16_000 && eld.channels == 1 && eld.samplesPerFrame == 480)
        #expect((eld.audioSpecificConfig?.count ?? 0) >= 2)
        let input = CodecFixtures.frames(CodecFixtures.tone(frequency: 500, sampleRate: 16_000, seconds: 2), format: pcm16k, frameSamples: 320)
        let frames = try input.flatMap { try encoder.transcode($0) } + encoder.flush()
        #expect(frames.allSatisfy { $0.sampleCount == 480 && $0.format == eld })
        #expect(frames.count * 480 >= 32_000)
        CodecFixtures.expectContiguous(frames)

        let decoded = try CodecFixtures.decodeToPCM(frames, sampleRate: 16_000)
        #expect(decoded.count >= 32_000)
        let middle = Array(decoded[8_000..<24_000])
        #expect(CodecFixtures.toneRatio(middle, frequency: 500, sampleRate: 16_000) > 0.8)
    }

    @Test func aacELDToPCMUForTalkback() throws {
        let encoder = try codecs.makeAudioTranscoder(input: pcmu8k, output: AudioEncoderSettings(codec: .aacELD, sampleRate: 16_000, channels: 1))
        let eld = try pcmuInput.flatMap { try encoder.transcode($0) } + encoder.flush()
        let transcoder = try codecs.makeAudioTranscoder(input: encoder.outputFormat, output: AudioEncoderSettings(codec: .pcmu, sampleRate: 8_000))
        let pcmu = try eld.flatMap { try transcoder.transcode($0) } + transcoder.flush()
        let pcm = G711.decodeMuLaw(pcmu.reduce(into: Data()) { $0.append($1.data) })
        #expect(pcm.count >= 15_000)
        #expect(CodecFixtures.toneRatio(Array(pcm[4_000..<12_000]), frequency: 440, sampleRate: 8_000) > 0.7)
    }

    @Test func flushReturnsTheTailAndTheTranscoderStaysUsable() throws {
        let transcoder = try codecs.makeAudioTranscoder(input: pcmu8k, output: AudioEncoderSettings(codec: .aac, sampleRate: 32_000, channels: 1))
        let second = CodecFixtures.frames(CodecFixtures.tone(frequency: 440, sampleRate: 8_000, seconds: 0.5), format: pcmu8k, frameSamples: 160, startSample: 8_000)
        let first = Array(second.prefix(10))   // 200 ms: less than the encoder's latency
        let beforeFlush = try first.flatMap { try transcoder.transcode($0) }
        let tail = try transcoder.flush()
        #expect(!tail.isEmpty)
        #expect(960 + (beforeFlush.count + tail.count) * 1024 >= 6_400)   // the 200 ms at 32 kHz, after the 960-sample offset
        #expect(try transcoder.flush().isEmpty)                    // nothing left
        // A new run after the flush starts from its own input timestamp.
        let later = CodecFixtures.frames(CodecFixtures.tone(frequency: 440, sampleRate: 8_000, seconds: 1), format: pcmu8k, frameSamples: 160, startSample: 80_000)
        let again = try later.flatMap { try transcoder.transcode($0) } + transcoder.flush()
        #expect(again.first?.pts == MediaTime(value: 320_000 + 960, timescale: 32_000))   // primed again after the flush
        #expect(960 + again.count * 1024 >= 32_000)
    }

    @Test func inputGapsShiftTheOutputTimeline() throws {
        let transcoder = try codecs.makeAudioTranscoder(input: pcmu8k, output: AudioEncoderSettings(codec: .pcmu, sampleRate: 8_000))
        let tone = CodecFixtures.tone(frequency: 440, sampleRate: 8_000, seconds: 0.2)
        let before = CodecFixtures.frames(tone, format: pcmu8k, frameSamples: 160, startSample: 0)
        let after = CodecFixtures.frames(tone, format: pcmu8k, frameSamples: 160, startSample: 8_000)   // 1 s later: a 0.8 s gap
        let output = try before.flatMap { try transcoder.transcode($0) } + after.flatMap { try transcoder.transcode($0) } + transcoder.flush()
        #expect(output.count == 20)
        #expect(output[0].pts.value == 0 && output[9].pts.value == 1_440)
        #expect(output[10].pts.value == 8_000 && output[19].pts.value == 9_440)
    }

    @Test func linearPCMAndALawPassThroughTheSameRate() throws {
        let pcma = AudioFormat(codec: .pcma, sampleRate: 8_000, channels: 1)
        let transcoder = try codecs.makeAudioTranscoder(input: pcma, output: AudioEncoderSettings(codec: .linearPCM, sampleRate: 8_000))
        #expect(transcoder.outputFormat == AudioFormat(codec: .linearPCM, sampleRate: 8_000, channels: 1))
        let tone = CodecFixtures.tone(frequency: 440, sampleRate: 8_000, seconds: 0.1)
        let output = try CodecFixtures.frames(tone, format: pcma, frameSamples: 80).flatMap { try transcoder.transcode($0) } + transcoder.flush()
        let pcm = output.flatMap { frame in frame.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } }
        #expect(pcm == G711.decodeALaw(G711.encodeALaw(tone)))
        #expect(output.allSatisfy { $0.sampleCount == 160 })
    }

    @Test func unsupportedConversionsThrow() {
        #expect(throws: MediaCodecError.self) {
            _ = try codecs.makeAudioTranscoder(input: AudioFormat(codec: .aac, sampleRate: 16_000, channels: 1), output: AudioEncoderSettings(codec: .aac, sampleRate: 32_000))
        }
        #expect(throws: MediaCodecError.self) {
            _ = try codecs.makeAudioTranscoder(input: AudioFormat(codec: .pcmu, sampleRate: 0, channels: 1), output: AudioEncoderSettings(codec: .aac, sampleRate: 32_000))
        }
        #expect(throws: MediaCodecError.self) {
            _ = try codecs.makeAudioTranscoder(input: pcmu8k, output: AudioEncoderSettings(codec: .aac, sampleRate: 32_000, channels: 0))
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct CodecsOpusPacketTimeTests {
    let codecs = CodecFixtures.codecs
    let pcmu8k = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)

    /// Talkback from a remote viewer arrives in 40 or 60 ms packets (brief §3.6): single long SILK frames (code 0) or
    /// several 20 ms frames (codes 2 and 3, up to 120 ms). Every packet must decode, whatever its duration.
    @Test(arguments: [16_000, 24_000])
    func opusPacketsOfEveryDurationDecodeToPCMU(sampleRate: Int) throws {
        let tone = CodecFixtures.tone(frequency: 440, sampleRate: sampleRate, seconds: 2)
        let twenty = try CodecFixtures.opusPackets(tone, sampleRate: sampleRate, framesPerPacket: sampleRate / 50)
        let streams: [(name: String, packets: [Data], samples: Int)] = [
            ("SILK 40 ms, code 0", try CodecFixtures.opusPackets(tone, sampleRate: sampleRate, framesPerPacket: sampleRate / 25), sampleRate / 25),
            ("SILK 60 ms, code 0", try CodecFixtures.opusPackets(tone, sampleRate: sampleRate, framesPerPacket: 3 * sampleRate / 50), 3 * sampleRate / 50),
            ("2 × 20 ms, code 2", stride(from: 0, to: twenty.count - 1, by: 2).map { CodecFixtures.opusCode2(twenty[$0], twenty[$0 + 1]) }, sampleRate / 25),
            ("3 × 20 ms, code 3", stride(from: 0, to: twenty.count - 2, by: 3).map { CodecFixtures.opusCode3(Array(twenty[$0..<($0 + 3)])) }, 3 * sampleRate / 50),
            ("6 × 20 ms, code 3", stride(from: 0, to: twenty.count - 5, by: 6).map { CodecFixtures.opusCode3(Array(twenty[$0..<($0 + 6)])) }, 6 * sampleRate / 50),
        ]
        for stream in streams {
            #expect(stream.packets.allSatisfy { OpusPacket.sampleCount($0, sampleRate: sampleRate) == stream.samples }, "\(stream.name)")
            let transcoder = try codecs.makeAudioTranscoder(input: AudioFormat(codec: .opus, sampleRate: sampleRate, channels: 1),
                                                            output: AudioEncoderSettings(codec: .pcmu, sampleRate: 8_000, channels: 1))
            let input = CodecFixtures.opusFrames(stream.packets, sampleRate: sampleRate, startSample: sampleRate)
            let output = try input.flatMap { try transcoder.transcode($0) } + transcoder.flush()
            let expected = stream.packets.count * stream.samples * 8_000 / sampleRate
            let total = output.reduce(0) { $0 + $1.sampleCount }
            #expect(abs(total - expected) <= 160, "\(stream.name): \(total) samples, expected about \(expected)")
            #expect(output.first?.pts == MediaTime(value: 8_000, timescale: 8_000), "\(stream.name)")
            CodecFixtures.expectContiguous(output)
            let pcm = G711.decodeMuLaw(output.reduce(into: Data()) { $0.append($1.data) })
            if pcm.count > 12_000 {
                #expect(CodecFixtures.toneRatio(Array(pcm[4_000..<12_000]), frequency: 440, sampleRate: 8_000) > 0.7, "\(stream.name)")
            } else {
                Issue.record("\(stream.name): only \(pcm.count) samples decoded")
            }
        }
    }

    @Test func opusPacketTimeMayChangeMidStream() throws {
        let tone = CodecFixtures.tone(frequency: 440, sampleRate: 16_000, seconds: 1)
        let twenty = try CodecFixtures.opusPackets(tone, sampleRate: 16_000, framesPerPacket: 320)
        let sixty = try CodecFixtures.opusPackets(tone, sampleRate: 16_000, framesPerPacket: 960)
        let packets = Array(twenty.prefix(20)) + Array(sixty.prefix(10)) + Array(twenty.prefix(10))   // 400 + 600 + 200 ms
        let transcoder = try codecs.makeAudioTranscoder(input: AudioFormat(codec: .opus, sampleRate: 16_000, channels: 1),
                                                        output: AudioEncoderSettings(codec: .pcmu, sampleRate: 8_000, channels: 1))
        let output = try CodecFixtures.opusFrames(packets, sampleRate: 16_000).flatMap { try transcoder.transcode($0) } + transcoder.flush()
        let total = output.reduce(0) { $0 + $1.sampleCount }
        #expect(abs(total - 9_600) <= 160, "\(total) samples for 1.2 s")
        CodecFixtures.expectContiguous(output)
    }

    @Test func malformedOpusPacketsThrowAndTheDecoderRecovers() throws {
        let transcoder = try codecs.makeAudioTranscoder(input: AudioFormat(codec: .opus, sampleRate: 16_000, channels: 1),
                                                        output: AudioEncoderSettings(codec: .pcmu, sampleRate: 8_000, channels: 1))
        var generator = SystemRandomNumberGenerator()
        let junk = (0..<50).map { _ in Data((0..<Int.random(in: 1...200, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
        for frame in CodecFixtures.opusFrames(junk, sampleRate: 16_000) { _ = try? transcoder.transcode(frame) }
        _ = try? transcoder.flush()
        let tone = CodecFixtures.tone(frequency: 440, sampleRate: 16_000, seconds: 1)
        let valid = try CodecFixtures.opusPackets(tone, sampleRate: 16_000, framesPerPacket: 960)
        let output = try CodecFixtures.opusFrames(valid, sampleRate: 16_000).flatMap { try transcoder.transcode($0) } + transcoder.flush()
        #expect(output.reduce(0) { $0 + $1.sampleCount } >= 7_500)
    }

    /// RFC 6716 §3.2.5: a code-3 packet holds 1…48 frames and at most 120 ms. TOC 0x1B = SILK 60 ms, code 3.
    @Test func opusPacketDurationRejectsInvalidFrameCounts() {
        #expect(OpusPacket.sampleCount(Data([0x1B, 0x80]), sampleRate: 16_000) == nil)          // zero frames
        #expect(OpusPacket.sampleCount(Data([0x1B, 0x83]), sampleRate: 16_000) == nil)          // 3 × 60 ms = 180 ms
        #expect(OpusPacket.sampleCount(Data([0x1B, 0x82]), sampleRate: 16_000) == 1_920)        // 2 × 60 ms = 120 ms
    }
}

@Suite(.timeLimit(.minutes(1))) struct CodecsAudioEncoderDelayTests {
    let codecs = CodecFixtures.codecs
    let pcmu8k = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)

    /// 1 s of µ-law at 8 kHz from `startSample`: silence, then a 1 kHz burst from 0.5 s.
    func burst(startSample: Int) -> [EncodedAudioFrame] {
        let pcm = (0..<8_000).map { $0 < 4_000 ? Int16(0) : Int16(12_000 * sin(2 * .pi * 1_000 * Double($0) / 8_000)) }
        return CodecFixtures.frames(pcm, format: pcmu8k, frameSamples: 160, startSample: startSample)
    }

    /// The encoder's delay (AAC-LC 2112 samples of priming, AAC-ELD ~255, Opus ~104 at 16 kHz) is compensated: decoded
    /// audio labelled time T carries the input from time T, also after a `flush()` (the encoder primes again).
    @Test(arguments: [(MediaCore.AudioCodec.aac, 32_000), (.aac, 16_000), (.aacELD, 16_000), (.opus, 16_000), (.opus, 24_000)])
    func decodedAudioLinesUpWithTheInput(codec: MediaCore.AudioCodec, sampleRate: Int) throws {
        let transcoder = try codecs.makeAudioTranscoder(input: pcmu8k, output: AudioEncoderSettings(codec: codec, sampleRate: sampleRate, channels: 1))
        for start in [16_000, 80_000] {   // 2 s, then 10 s after a flush
            let encoded = try burst(startSample: start).flatMap { try transcoder.transcode($0) } + transcoder.flush()
            let first = try #require(encoded.first)
            #expect(first.pts.value >= Int64(start * sampleRate / 8_000))            // never before the input
            CodecFixtures.expectContiguous(encoded)
            let (decodedStart, decoded) = try CodecFixtures.decodeWithTimeline(encoded, sampleRate: sampleRate)
            let onset = try #require(CodecFixtures.onset(decoded))
            let measured = Double(decodedStart + Int64(onset)) / Double(sampleRate)
            let expected = Double(start + 4_000) / 8_000
            // Uncompensated: AAC-LC +66/+132 ms, AAC-ELD +16 ms, Opus +4 ms. Opus reports its 6.5 ms pre-skip (lookahead
            // incl. the 2.5 ms CELT overlap), while its SILK-mode output here is 4 ms late, so it lands 2.5 ms early.
            let tolerance = codec == .opus ? 0.003 : 0.0005
            #expect(abs(measured - expected) < tolerance, "\(codec) @ \(sampleRate): burst at \(measured) s, input at \(expected) s")
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct CodecsAudioBitrateTests {
    let codecs = CodecFixtures.codecs
    let pcmu8k = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)

    /// A bit rate the encoder does not offer (AAC-LC 32 kHz mono: 24–96 kbit/s) is clamped to the nearest one it does.
    @Test(arguments: [(MediaCore.AudioCodec.aac, 32_000, 8_000, 24_000), (.aac, 32_000, 16_000, 24_000), (.aac, 32_000, 128_000, 96_000),
                      (.aac, 32_000, 256_000, 96_000), (.aac, 16_000, 64_000, 48_000), (.aacELD, 16_000, 8_000, 12_000),
                      (.aacELD, 16_000, 64_000, 48_000), (.aac, 32_000, 64_000, 64_000), (.opus, 16_000, 24_000, 24_000)])
    func unsupportedBitratesAreClamped(codec: MediaCore.AudioCodec, sampleRate: Int, requested: Int, applied: Int) throws {
        let formatID: AudioFormatID = switch codec {
        case .aac: kAudioFormatMPEG4AAC
        case .aacELD: kAudioFormatMPEG4AAC_ELD
        default: kAudioFormatOpus
        }
        let framesPerPacket = codec == .aac ? 1024 : codec == .aacELD ? 480 : sampleRate / 50
        let encoder = try AudioConverterStream(from: .pcm16(sampleRate: sampleRate, channels: 1),
                                               to: .compressed(formatID, sampleRate: sampleRate, channels: 1, framesPerPacket: framesPerPacket),
                                               bitrate: requested)
        #expect(encoder.encodeBitRate == applied)

        let transcoder = try codecs.makeAudioTranscoder(input: pcmu8k, output: AudioEncoderSettings(codec: codec, sampleRate: sampleRate, channels: 1, bitrate: requested))
        let tone = CodecFixtures.frames(CodecFixtures.tone(frequency: 440, sampleRate: 8_000, seconds: 1), format: pcmu8k, frameSamples: 160)
        let encoded = try tone.flatMap { try transcoder.transcode($0) } + transcoder.flush()
        let decoded = try CodecFixtures.decodeToPCM(encoded, sampleRate: sampleRate)
        #expect(decoded.count >= sampleRate * 3 / 4)
        #expect(CodecFixtures.toneRatio(Array(decoded[(sampleRate / 4)..<(sampleRate * 3 / 4)]), frequency: 440, sampleRate: sampleRate) > 0.7)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CodecsAudioFormatDescriptionTests {
    @Test func aacELDFormatDescriptionFromTheEncodersConfig() throws {
        let encoder = try CodecFixtures.codecs.makeAudioTranscoder(input: AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 1),
                                                                   output: AudioEncoderSettings(codec: .aacELD, sampleRate: 16_000, channels: 1))
        let format = encoder.outputFormat
        let description = try format.makeFormatDescription()
        let asbd = try withExtendedLifetime(description) { try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee) }
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC_ELD && asbd.mSampleRate == 16_000 && asbd.mChannelsPerFrame == 1 && asbd.mFramesPerPacket == 480)
        var size = 0
        let pointer = try #require(CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size))
        let cookie = Data(bytes: pointer, count: size)
        #expect(MPEG4ESDescriptor.audioSpecificConfig(in: cookie) == format.audioSpecificConfig)
        var fromESDS = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = cookie.withUnsafeBytes { AudioFormatGetProperty(kAudioFormatProperty_ASBDFromESDS, UInt32($0.count), $0.baseAddress, &asbdSize, &fromESDS) }
        #expect(status == noErr && fromESDS.mFormatID == kAudioFormatMPEG4AAC_ELD && fromESDS.mSampleRate == 16_000)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CodecsSilentAudioTests {
    let codecs = CodecFixtures.codecs

    @Test func silentAACFramesAreDecodableAndEvenlySpaced() throws {
        let start = MediaTime(value: 900_000, timescale: 90_000)   // 10 s on the video clock
        let frames = try codecs.silentAACFrames(duration: .seconds(2), sampleRate: 32_000, channels: 1, startPTS: start, wallClock: CodecFixtures.origin)
        #expect(frames.count == 63)   // ⌈2 s × 32000 / 1024⌉
        #expect(frames.allSatisfy { $0.format == AudioFormat.aacLC(sampleRate: 32_000, channels: 1) && $0.sampleCount == 1024 && !$0.data.isEmpty })
        for (index, frame) in frames.enumerated() {
            #expect(frame.pts == MediaTime(value: 320_000 + Int64(index) * 1024, timescale: 32_000))
            #expect(abs(frame.wallClock.timeIntervalSince(CodecFixtures.origin) - Double(index) * 1024 / 32_000) < 1e-6)
        }
        let decoded = try CodecFixtures.decodeToPCM(frames, sampleRate: 32_000)
        #expect(decoded.count >= 62 * 1024)
        #expect(decoded.allSatisfy { abs(Int($0)) <= 1 })
    }

    @Test func stereo48kAndShortDurations() throws {
        let frames = try codecs.silentAACFrames(duration: .milliseconds(10), sampleRate: 48_000, channels: 2, startPTS: MediaTime(value: 0, timescale: 48_000),
                                                wallClock: Date())
        #expect(frames.count == 1 && frames[0].format == AudioFormat.aacLC(sampleRate: 48_000, channels: 2))
        #expect(try codecs.silentAACFrames(duration: .zero, sampleRate: 32_000, channels: 1, startPTS: MediaTime(value: 0, timescale: 32_000), wallClock: Date()).isEmpty)
        #expect(throws: MediaCodecError.self) {
            _ = try codecs.silentAACFrames(duration: .seconds(1), sampleRate: 0, channels: 1, startPTS: MediaTime(value: 0, timescale: 1), wallClock: Date())
        }
    }
}
#endif
