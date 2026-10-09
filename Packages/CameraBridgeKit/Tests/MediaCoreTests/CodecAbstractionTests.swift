import BridgeSupport
import Foundation
import Synchronization
import Testing
@testable import MediaCore

@Suite struct AACConfigurationTests {
    /// AudioSpecificConfig (ISO/IEC 14496-3 §1.6.2.1): AOT 2 (5 bits), frequency index (4), channel config (4),
    /// GASpecificConfig 000.
    @Test func buildsTwoByteAudioSpecificConfigForTableRates() {
        #expect(AudioFormat.aacLC(sampleRate: 32_000, channels: 1).audioSpecificConfig == Data([0x12, 0x88]))
        #expect(AudioFormat.aacLC(sampleRate: 44_100, channels: 2).audioSpecificConfig == Data([0x12, 0x10]))
        #expect(AudioFormat.aacLC(sampleRate: 48_000, channels: 2).audioSpecificConfig == Data([0x11, 0x90]))
        #expect(AudioFormat.aacLC(sampleRate: 16_000, channels: 1).audioSpecificConfig == Data([0x14, 0x08]))
        #expect(AudioFormat.aacLC(sampleRate: 8_000, channels: 1).audioSpecificConfig == Data([0x15, 0x88]))
        let format = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        #expect(format.codec == .aac && format.sampleRate == 32_000 && format.channels == 1 && format.samplesPerFrame == 1024)
    }

    @Test func usesTheExplicitFrequencyEscapeForOtherRates() {
        // AOT 2, index 15, 24-bit 20000 (0x004E20), channel config 1, 000 → 40 bits.
        #expect(AudioFormat.aacLC(sampleRate: 20_000, channels: 1).audioSpecificConfig == Data([0x17, 0x80, 0x27, 0x10, 0x08]))
    }

    @Test func eightChannelsUseChannelConfiguration7() {
        #expect(AudioFormat.aacLC(sampleRate: 48_000, channels: 8).audioSpecificConfig == Data([0x11, 0xB8]))
    }
}

@Suite struct GrayImageTests {
    @Test func valueSemantics() {
        var image = GrayImage(width: 2, height: 1, pixels: [0, 255])
        let copy = image
        image.pixels[0] = 9
        #expect(copy.pixels == [0, 255] && image != copy)
    }
}

@Suite(.timeLimit(.minutes(1))) struct MediaCodecsExtensionTests {
    private let keyframe = EncodedVideoFrame(format: VideoFormat(codec: .h264, width: 64, height: 36, parameterSets: [Data([0x67]), Data([0x68])]),
                                             nalUnits: [Data([0x65, 0x88])], isKeyframe: true, pts: .seconds(1), wallClock: Date())

    @Test func jpegFromKeyframeDecodesWithAFreshDecoderThenEncodes() async throws {
        let codecs = FakeCodecs(decodes: true)
        let jpeg = try await codecs.jpeg(fromKeyframe: keyframe, maxWidth: 320, maxHeight: nil)
        #expect(jpeg == Data("jpeg 64x36 max 320 q0.8".utf8))
        #expect(codecs.log.withLock { $0 } == ["decoder h264", "decode 1.0", "jpeg", "invalidate"])
    }

    @Test func jpegFromKeyframeWithoutAPictureThrowsNoFrame() async {
        let codecs = FakeCodecs(decodes: false)
        await #expect(throws: MediaCodecError.noFrame) { _ = try await codecs.jpeg(fromKeyframe: keyframe, maxWidth: nil, maxHeight: nil) }
        #expect(codecs.log.withLock { $0 } == ["decoder h264", "decode 1.0", "invalidate"])
    }

    @Test func jpegFromKeyframeRejectsDeltaFrames() async {
        var delta = keyframe
        delta.isKeyframe = false
        await #expect(throws: MediaCodecError.self) { _ = try await FakeCodecs(decodes: true).jpeg(fromKeyframe: delta, maxWidth: nil, maxHeight: nil) }
    }
}

// MARK: - Fakes

private struct FakePicture: DecodedVideoFrame {
    var width: Int
    var height: Int
    var pts: MediaTime
    func grayThumbnail(maxWidth: Int) -> GrayImage? { nil }
}

private final class FakeDecoder: VideoDecoding {
    let codecs: FakeCodecs
    init(codecs: FakeCodecs) { self.codecs = codecs }
    func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
        codecs.log.withLock { $0.append("decode \(frame.pts.seconds)") }
        return codecs.decodes ? FakePicture(width: frame.format.width, height: frame.format.height, pts: frame.pts) : nil
    }
    func invalidate() { codecs.log.withLock { $0.append("invalidate") } }
}

private final class FakeCodecs: MediaCodecs {
    let decodes: Bool
    let log = Mutex<[String]>([])
    init(decodes: Bool) { self.decodes = decodes }

    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding {
        log.withLock { $0.append("decoder \(format.codec)") }
        return FakeDecoder(codecs: self)
    }
    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { throw MediaCodecError.unsupported("fake") }
    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { throw MediaCodecError.unsupported("fake") }
    func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding { throw MediaCodecError.unsupported("fake") }
    func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
        log.withLock { $0.append("jpeg") }
        return Data("jpeg \(frame.width)x\(frame.height) max \(maxWidth ?? 0) q\(quality)".utf8)
    }
    func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { jpeg }
    func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] { [] }
    func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration,
                             audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource { FakeSource() }
}

private final class FakeSource: MediaSource {
    var displayName: String { "fake" }
    func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> { AsyncThrowingStream { $0.finish() } }
    func stop() async {}
}
