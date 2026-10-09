#if os(macOS)
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import MediaCore
import Testing
@testable import PlatformApple

/// Shared helpers for the AppleMediaCodecs tests.
enum CodecFixtures {
    static let codecs = AppleMediaCodecs()
    static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Test-pattern pictures at `fps` (pts on the 90 kHz clock).
    static func pictures(width: Int, height: Int, count: Int, fps: Int = 30, firstIndex: Int = 0) throws -> [PixelBufferFrame] {
        let pattern = TestPattern(width: width, height: height)
        return try (firstIndex..<(firstIndex + count)).map { index in
            try pattern.makeFrame(index: index, pts: MediaTime(value: Int64(index * 90_000 / fps), timescale: 90_000))
        }
    }

    /// Encodes test-pattern pictures with the given settings (H.264 unless `codec` says otherwise).
    static func encodedStream(width: Int, height: Int, count: Int, fps: Int = 30, bitrateKbps: Int, profile: VideoEncoderSettings.EncoderProfile = .main,
                              level: VideoEncoderSettings.EncoderLevel = .auto, keyframeInterval: Duration, codec: VideoCodec = .h264) throws -> [EncodedVideoFrame] {
        let settings = VideoEncoderSettings(width: width, height: height, fps: fps, bitrateKbps: bitrateKbps, profile: profile, level: level,
                                            keyframeInterval: keyframeInterval, realtime: false)
        let encoder = try AppleVideoEncoder(settings: settings, codec: codec)
        defer { encoder.invalidate() }
        let pattern = TestPattern(width: width, height: height)
        var frames: [EncodedVideoFrame] = []
        for index in 0..<count {
            let picture = try pattern.makeFrame(index: index, pts: MediaTime(value: Int64(index * 90_000 / fps), timescale: 90_000))
            frames += try encoder.encodeNow(picture, wallClock: origin.addingTimeInterval(Double(index) / Double(fps)), forceKeyframe: false)
        }
        return frames
    }

    /// 10 s of 1920×1080 H.264 High at 30 fps, 8 Mbit/s, keyframe every 4 s (transcoder input), built once.
    static let fullHDInput: [EncodedVideoFrame] = (try? encodedStream(width: 1920, height: 1080, count: 300, bitrateKbps: 8_000, profile: .high,
                                                                      keyframeInterval: .seconds(4))) ?? []

    /// Whether this Mac can encode HEVC (checked once; HEVC tests are skipped, not passed, without it).
    static let hevcAvailable: Bool = (try? AppleVideoEncoder(settings: VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 1_000), codec: .hevc))
        .map { encoder in encoder.invalidate(); return true } ?? false

    /// Width and height of an image ImageIO can decode (full decode, not just the header).
    static func decodedImageSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    static func sps(of frame: EncodedVideoFrame) -> H264SPS? {
        frame.format.parameterSets.first.flatMap(H264SPS.parse)
    }

    static func bytes(_ frames: [EncodedVideoFrame]) -> Int {
        frames.reduce(0) { $0 + $1.nalUnits.reduce(0) { $0 + $1.count } }
    }

    /// Mean absolute luma difference between two same-sized thumbnails.
    static func meanDifference(_ a: GrayImage, _ b: GrayImage) -> Double {
        guard a.width == b.width, a.height == b.height, !a.pixels.isEmpty else { return .infinity }
        return Double(zip(a.pixels, b.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.pixels.count)
    }

    // MARK: Audio

    /// A sine tone as 16-bit PCM.
    static func tone(frequency: Double, sampleRate: Int, seconds: Double, amplitude: Double = 10_000) -> [Int16] {
        (0..<Int(Double(sampleRate) * seconds)).map { Int16(amplitude * sin(2 * .pi * frequency * Double($0) / Double(sampleRate))) }
    }

    /// Splits PCM into `frameSamples`-sized input frames of `format` (G.711 or LPCM), pts on the sample clock.
    static func frames(_ pcm: [Int16], format: AudioFormat, frameSamples: Int, startSample: Int = 0) -> [EncodedAudioFrame] {
        stride(from: 0, to: pcm.count, by: frameSamples).map { start in
            let chunk = Array(pcm[start..<min(start + frameSamples, pcm.count)])
            let data: Data
            switch format.codec {
            case .pcmu: data = G711.encodeMuLaw(chunk)
            case .pcma: data = G711.encodeALaw(chunk)
            default: data = chunk.withUnsafeBufferPointer { Data(buffer: $0) }
            }
            return EncodedAudioFrame(format: format, data: data, pts: MediaTime(value: Int64(startSample + start), timescale: Int32(format.sampleRate)),
                                     sampleCount: chunk.count, wallClock: origin.addingTimeInterval(Double(startSample + start) / Double(format.sampleRate)))
        }
    }

    /// Decodes any supported audio to 16-bit PCM at `sampleRate` with the codecs under test.
    static func decodeToPCM(_ frames: [EncodedAudioFrame], sampleRate: Int) throws -> [Int16] {
        guard let first = frames.first else { return [] }
        let decoder = try codecs.makeAudioTranscoder(input: first.format, output: AudioEncoderSettings(codec: .linearPCM, sampleRate: sampleRate, channels: 1))
        let output = try frames.flatMap { try decoder.transcode($0) } + decoder.flush()
        return output.flatMap { frame in frame.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } }
    }

    static func rms(_ samples: some Collection<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    /// Goertzel power ratio of `frequency` in `samples` relative to total energy (1 = pure tone).
    static func toneRatio(_ samples: [Int16], frequency: Double, sampleRate: Int) -> Double {
        guard samples.count > 16 else { return 0 }
        let coefficient = 2 * cos(2 * .pi * frequency / Double(sampleRate))
        var (s1, s2) = (0.0, 0.0)
        var energy = 0.0
        for sample in samples {
            let x = Double(sample)
            energy += x * x
            let s0 = x + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        return energy > 0 ? 2 * power / (Double(samples.count) * energy) : 0
    }

    /// Asserts contiguous pts (spacing = sampleCount) on the output sample clock.
    static func expectContiguous(_ frames: [EncodedAudioFrame], sourceLocation: SourceLocation = #_sourceLocation) {
        for (previous, next) in zip(frames, frames.dropFirst()) {
            #expect(next.pts.timescale == Int32(next.format.sampleRate), sourceLocation: sourceLocation)
            #expect(next.pts.value - previous.pts.value == Int64(previous.sampleCount), sourceLocation: sourceLocation)
        }
    }

    /// Decodes to 16-bit PCM at `sampleRate` and returns the samples with the first one's PTS (on the `sampleRate` clock).
    static func decodeWithTimeline(_ frames: [EncodedAudioFrame], sampleRate: Int) throws -> (start: Int64, samples: [Int16]) {
        guard let first = frames.first else { return (0, []) }
        let decoder = try codecs.makeAudioTranscoder(input: first.format, output: AudioEncoderSettings(codec: .linearPCM, sampleRate: sampleRate, channels: 1))
        let output = try frames.flatMap { try decoder.transcode($0) } + decoder.flush()
        let samples = output.flatMap { frame in frame.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } }
        return (output.first?.pts.converted(to: Int32(sampleRate)).value ?? 0, samples)
    }

    /// Index of the first sample whose magnitude reaches half the peak magnitude (nil for silence).
    static func onset(_ samples: [Int16]) -> Int? {
        guard let peak = samples.map({ abs(Int($0)) }).max(), peak > 0 else { return nil }
        return samples.firstIndex { 2 * abs(Int($0)) >= peak }
    }

    // MARK: Opus packets

    /// Raw Opus packets of `framesPerPacket` samples each (Apple's encoder; 40/60 ms give single SILK frames, code 0).
    static func opusPackets(_ pcm: [Int16], sampleRate: Int, framesPerPacket: Int) throws -> [Data] {
        let encoder = try AudioConverterStream(from: .pcm16(sampleRate: sampleRate, channels: 1),
                                               to: .compressed(kAudioFormatOpus, sampleRate: sampleRate, channels: 1, framesPerPacket: framesPerPacket))
        encoder.push(pcm: pcm.withUnsafeBufferPointer { Data(buffer: $0) })
        return try encoder.finish().map(\.data)
    }

    /// RFC 6716 §3.2.1 frame length (1 or 2 bytes).
    private static func opusLength(_ length: Int) -> [UInt8] {
        length < 252 ? [UInt8(length)] : [UInt8(252 + (length & 3)), UInt8((length - 252 - (length & 3)) >> 2)]
    }

    /// Two single-frame (code 0) packets of the same configuration as one code-2 packet.
    static func opusCode2(_ first: Data, _ second: Data) -> Data {
        var packet = Data([(first[first.startIndex] & 0xFC) | 2])
        packet.append(contentsOf: opusLength(first.count - 1))
        packet.append(first.dropFirst())
        packet.append(second.dropFirst())
        return packet
    }

    /// Single-frame (code 0) packets of the same configuration as one VBR code-3 packet.
    static func opusCode3(_ frames: [Data]) -> Data {
        var packet = Data([(frames[0][frames[0].startIndex] & 0xFC) | 3, 0x80 | UInt8(frames.count)])
        for frame in frames.dropLast() { packet.append(contentsOf: opusLength(frame.count - 1)) }
        for frame in frames { packet.append(frame.dropFirst()) }
        return packet
    }

    /// Opus input frames (pts on the `sampleRate` clock, durations from the TOC) starting at `startSample`.
    static func opusFrames(_ packets: [Data], sampleRate: Int, startSample: Int = 0) -> [EncodedAudioFrame] {
        let format = AudioFormat(codec: .opus, sampleRate: sampleRate, channels: 1)
        var position = startSample
        return packets.map { packet in
            let count = OpusPacket.sampleCount(packet, sampleRate: sampleRate) ?? sampleRate / 50
            defer { position += count }
            return EncodedAudioFrame(format: format, data: packet, pts: MediaTime(value: Int64(position), timescale: Int32(sampleRate)),
                                     sampleCount: count, wallClock: origin.addingTimeInterval(Double(position) / Double(sampleRate)))
        }
    }
}
#endif
