#if os(macOS)
import CoreMedia
import Foundation
import MediaCore
import Testing
@testable import PlatformApple

/// The sample buffers the app's live viewer enqueues (`LiveVideoSampleBuilder`, `LiveAudioSampleBuilder`).
@Suite(.timeLimit(.minutes(1))) struct LiveSampleBuilderTests {
    private func attachment(_ sample: CMSampleBuffer, _ key: CFString) -> Bool? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false), CFArrayGetCount(attachments) > 0 else { return nil }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self) as NSDictionary
        return dictionary[key as String] as? Bool
    }

    @Test(arguments: [VideoCodec.h264, .hevc]) func accessUnitsBecomeSamplesDisplayedAtOnce(codec: VideoCodec) throws {
        let frames = try CodecFixtures.encodedStream(width: 320, height: 240, count: 6, bitrateKbps: 500, keyframeInterval: .seconds(1), codec: codec)
        let builder = LiveVideoSampleBuilder()
        var descriptions: [CMVideoFormatDescription] = []
        for frame in frames {
            let sample = try #require(try builder.sampleBuffer(for: frame))
            #expect(CMSampleBufferGetNumSamples(sample) == 1)
            #expect(CMSampleBufferGetTotalSampleSize(sample) == VideoSampleBuffers.withoutSEI(frame).lengthPrefixedData.count, "SEI left out")
            let description = try #require(CMSampleBufferGetFormatDescription(sample))
            #expect(CMFormatDescriptionGetMediaSubType(description) == (codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC))
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            #expect(dimensions.width == 320 && dimensions.height == 240)
            #expect(attachment(sample, kCMSampleAttachmentKey_DisplayImmediately) == true, "no timeline, no buffering")
            #expect((attachment(sample, kCMSampleAttachmentKey_NotSync) == true) == !frame.isKeyframe)
            descriptions.append(description)
        }
        #expect(frames.first?.isKeyframe == true)
        #expect(descriptions.dropFirst().allSatisfy { $0 === descriptions[0] }, "one format description for one stream")
    }

    @Test func aNewFormatGetsANewDescription() throws {
        let small = try CodecFixtures.encodedStream(width: 320, height: 240, count: 1, bitrateKbps: 500, keyframeInterval: .seconds(1))
        let large = try CodecFixtures.encodedStream(width: 640, height: 360, count: 1, bitrateKbps: 500, keyframeInterval: .seconds(1))
        let builder = LiveVideoSampleBuilder()
        let first = try #require(try builder.sampleBuffer(for: small[0]))
        let second = try #require(try builder.sampleBuffer(for: large[0]))
        #expect(CMVideoFormatDescriptionGetDimensions(try #require(CMSampleBufferGetFormatDescription(first))).width == 320)
        #expect(CMVideoFormatDescriptionGetDimensions(try #require(CMSampleBufferGetFormatDescription(second))).width == 640)
    }

    @Test func aFrameWithoutPictureDataMakesNoSample() throws {
        let frames = try CodecFixtures.encodedStream(width: 320, height: 240, count: 1, bitrateKbps: 500, keyframeInterval: .seconds(1))
        var empty = frames[0]
        empty.nalUnits = []
        #expect(try LiveVideoSampleBuilder().sampleBuffer(for: empty) == nil)
    }

    @Test func audioAccessUnitsBecomePlayableSamples() throws {
        let aac = try CodecFixtures.codecs.silentAACFrames(duration: .milliseconds(200), sampleRate: 16_000, channels: 1, startPTS: MediaTime(value: 0, timescale: 16_000),
                                                           wallClock: Date())
        let builder = LiveAudioSampleBuilder()
        let sample = try #require(try builder.sampleBuffer(for: aac[0], presentationTime: CMTime(value: 5, timescale: 1)))
        #expect(CMSampleBufferGetNumSamples(sample) == 1)
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: 5, timescale: 1))
        #expect(CMSampleBufferGetTotalSampleSize(sample) == aac[0].data.count)
        let description = try #require(CMSampleBufferGetFormatDescription(sample))
        #expect(CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC)

        let ulaw = EncodedAudioFrame(format: AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1), data: Data(repeating: 0xFF, count: 160),
                                     pts: MediaTime(value: 0, timescale: 8_000), sampleCount: 160, wallClock: Date())
        let pcmu = try #require(try builder.sampleBuffer(for: ulaw, presentationTime: .zero))
        #expect(CMSampleBufferGetNumSamples(pcmu) == 160, "G.711 is counted in frames")
        #expect(try builder.sampleBuffer(for: EncodedAudioFrame(format: ulaw.format, data: Data(), pts: ulaw.pts, sampleCount: 0, wallClock: Date()),
                                         presentationTime: .zero) == nil)
    }
}
#endif
