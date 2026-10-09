// Cameras send malformed SEI NAL units (a Tapo's vendor SEI, payload type 764, declares 34 bytes and carries 32) in front of most
// pictures. VideoToolbox's software H.264 decoder rejects the picture after one (-8969); the decoder leaves SEI out.
#if os(macOS)
import Foundation
import MediaCore
import Testing
@testable import PlatformApple

@Suite(.timeLimit(.minutes(2))) struct SEIDecodingTests {
    static let malformedSEI = Data([0x06, 0xFF, 0xFF, 0xFE, 34] + (0..<32).map { UInt8(truncatingIfNeeded: 0x40 + $0) })

    /// A VideoToolbox stream with the malformed SEI in front of every delta frame.
    static func frames() throws -> [EncodedVideoFrame] {
        var frames = try CodecFixtures.encodedStream(width: 640, height: 360, count: 30, bitrateKbps: 1_500, keyframeInterval: .seconds(1))
        for index in frames.indices where !frames[index].isKeyframe { frames[index].nalUnits.insert(malformedSEI, at: 0) }
        return frames
    }

    @Test(arguments: [false, true]) func everyPictureDecodesDespiteTheSEI(software: Bool) throws {
        let frames = try Self.frames()
        try #require(frames.count == 30 && frames.contains { !$0.isKeyframe })
        let decoder = try AppleVideoDecoder(format: frames[0].format)
        defer { decoder.invalidate() }
        if software { decoder.useSoftwareDecoding(reason: "test") }
        var failed: [Int] = []
        var pictures = 0
        for (index, frame) in frames.enumerated() {
            do { pictures += try decoder.decodeAllNow(frame).count } catch { failed.append(index) }
        }
        #expect(failed.isEmpty, "decoding failed at \(failed.prefix(5)) of \(frames.count)")
        #expect(pictures == frames.count)
    }

    @Test func sampleBuffersLeaveSEIOut() throws {
        let frames = try Self.frames()
        let delta = try #require(frames.first { !$0.isKeyframe })
        #expect(delta.nalUnits.contains { NALUnits.h264Type($0) == 6 })
        let stripped = VideoSampleBuffers.withoutSEI(delta)
        #expect(!stripped.nalUnits.contains { NALUnits.h264Type($0) == 6 })
        #expect(stripped.nalUnits == delta.nalUnits.filter { NALUnits.h264Type($0) != 6 })
        #expect(stripped.pts == delta.pts && stripped.isKeyframe == delta.isKeyframe)
        // HEVC: prefix and suffix SEI (39, 40) go, everything else stays.
        let format = VideoFormat(codec: .hevc, width: 0, height: 0, parameterSets: [])
        let hevc = EncodedVideoFrame(format: format, nalUnits: [Data([39 << 1, 1, 9]), Data([1 << 1, 1, 8]), Data([40 << 1, 1, 7])], isKeyframe: false,
                                     pts: MediaTime(value: 0, timescale: 90_000), wallClock: Date())
        #expect(VideoSampleBuffers.withoutSEI(hevc).nalUnits == [Data([1 << 1, 1, 8])])
    }
}
#endif
