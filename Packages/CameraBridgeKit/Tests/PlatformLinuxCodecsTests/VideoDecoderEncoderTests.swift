import Foundation
import MediaCore
import Testing
@testable import PlatformLinux

@Suite(.serialized, .enabled(if: FFmpegTesting.available)) struct VideoDecoderTests {
    @Test func decodesAKeyframeToItsPicture() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 1, gop: 25)
        let decoder = try FFmpegTesting.makeCodecs().makeVideoDecoder(format: source[0].format)
        defer { decoder.invalidate() }
        let begun = ContinuousClock.now
        let picture = try #require(try await decoder.decode(source[0]) as? RawVideoFrame)
        #expect(ContinuousClock.now - begun < .seconds(6))
        #expect(picture.width == 320 && picture.height == 180 && picture.isComplete)
        #expect(picture.pts == source[0].pts)
        let statistics = try #require(picture.pictureStatistics())
        #expect(!statistics.isBlank && statistics.lumaDeviation > 10)
        let gray = try #require(picture.grayThumbnail(maxWidth: 64))
        #expect(gray.width == 64 && gray.height == 36 && gray.pixels.count == 64 * 36)
        #expect(Set(gray.pixels).count > 5)
    }

    @Test func eachFrameYieldsItsOwnPictureWithItsOwnTime() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 1, gop: 25)
        let decoder = try FFmpegTesting.makeCodecs().makeVideoDecoder(format: source[0].format)
        defer { decoder.invalidate() }
        var pictures: [RawVideoFrame] = []
        let begun = ContinuousClock.now
        for frame in source {
            if let picture = try await decoder.decode(frame) as? RawVideoFrame { pictures.append(picture) }
        }
        #expect(pictures.count == source.count, "\(pictures.count) of \(source.count)")
        #expect(pictures.map(\.pts) == source.map(\.pts))
        // After the first picture there is no 0.4 s wait per frame: the whole second decodes quickly.
        #expect(ContinuousClock.now - begun < .seconds(8))
        // The pictures differ from one another (the test pattern moves).
        #expect(pictures[0].pixels != pictures[10].pixels)
    }

    @Test func aDeltaFrameBeforeAnyKeyframeGivesNothing() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 1, gop: 25)
        let decoder = try FFmpegTesting.makeCodecs().makeVideoDecoder(format: source[0].format)
        defer { decoder.invalidate() }
        #expect(try await decoder.decode(source[3]) == nil)
    }

    @Test(.enabled(if: FFmpegTesting.canEncodeHEVC))
    func hevcDecodes() async throws {
        let source = try FFmpegTesting.sourceFrames(codec: .hevc, width: 320, height: 180, fps: 25, seconds: 1, gop: 25)
        let decoder = try FFmpegTesting.makeCodecs().makeVideoDecoder(format: source[0].format)
        defer { decoder.invalidate() }
        let picture = try #require(try await decoder.decode(source[0]) as? RawVideoFrame)
        #expect(picture.width == 320 && picture.height == 180 && picture.isComplete)
    }

    @Test func bFramesComeOutInPresentationOrder() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 1, gop: 25, bFrames: true)
        let decoder = try FFmpegTesting.makeCodecs().makeVideoDecoder(format: source[0].format)
        defer { decoder.invalidate() }
        var pictures: [RawVideoFrame] = []
        for frame in source {
            if let picture = try await decoder.decode(frame) as? RawVideoFrame { pictures.append(picture) }
        }
        #expect(pictures.count >= source.count - 4)
        #expect(zip(pictures, pictures.dropFirst()).allSatisfy { $0.pts <= $1.pts })
    }

    @Test func aNewStreamOnAKeyframeStartsANewChild() async throws {
        let small = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 1, gop: 25)
        let large = try FFmpegTesting.sourceFrames(width: 480, height: 270, fps: 25, seconds: 1, gop: 25)
        let decoder = try FFmpegTesting.makeCodecs().makeVideoDecoder(format: small[0].format)
        defer { decoder.invalidate() }
        let first = try #require(try await decoder.decode(small[0]) as? RawVideoFrame)
        #expect(first.width == 320)
        let second = try #require(try await decoder.decode(large[0]) as? RawVideoFrame)
        #expect(second.width == 480 && second.height == 270)
    }

    @Test func snapshotAndProbeDecodersAreTheSameKindOfDecoder() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 320, height: 180, fps: 25, seconds: 1, gop: 25)
        let codecs = FFmpegTesting.makeCodecs()
        for decoder in [try codecs.makeSnapshotDecoder(format: source[0].format), try codecs.makeProbeDecoder(format: source[0].format)] {
            defer { decoder.invalidate() }
            #expect(try await decoder.decode(source[0]) != nil)
        }
    }

    @Test func invalidateKillsTheChild() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 326, height: 184, fps: 25, seconds: 1, gop: 25)
        let decoder = try FFmpegTesting.makeCodecs().makeVideoDecoder(format: source[0].format)
        _ = try await decoder.decode(source[0])
        #expect(ChildProcesses.count(commandContaining: "scale=326:184") == 1)
        decoder.invalidate()
        let gone = try await FFmpegTesting.eventually(timeout: .seconds(5)) { ChildProcesses.count(commandContaining: "scale=326:184") == 0 ? true : nil }
        #expect(gone == true)
        #expect(try await decoder.decode(source[0]) == nil)
    }

    @Test func releasingTheDecoderKillsTheChild() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 334, height: 188, fps: 25, seconds: 1, gop: 25)
        var decoder: (any VideoDecoding)? = try FFmpegTesting.makeCodecs().makeVideoDecoder(format: source[0].format)
        _ = try await decoder?.decode(source[0])
        #expect(ChildProcesses.count(commandContaining: "scale=334:188") == 1)
        decoder = nil
        let gone = try await FFmpegTesting.eventually(timeout: .seconds(5)) { ChildProcesses.count(commandContaining: "scale=334:188") == 0 ? true : nil }
        #expect(gone == true)
    }

    @Test func aFormatWithoutParameterSetsIsRefused() throws {
        let broken = VideoFormat(codec: .h264, width: 320, height: 180, parameterSets: [])
        #expect(throws: MediaCodecError.self) { _ = try FFmpegTesting.makeCodecs().makeVideoDecoder(format: broken) }
    }

    @Test func aKeyframeBecomesAJPEGThroughTheProtocolExtension() async throws {
        let source = try FFmpegTesting.sourceFrames(width: 640, height: 360, fps: 25, seconds: 1, gop: 25)
        let codecs = FFmpegTesting.makeCodecs()
        let jpeg = try await codecs.jpeg(fromKeyframe: source[0], maxWidth: 320, maxHeight: nil)
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]) && jpeg.suffix(2) == Data([0xFF, 0xD9]))
        let size = try #require(FFmpegPictures.imageSize(jpeg))
        #expect(size.width == 320 && size.height == 180)
        await #expect(throws: MediaCodecError.self) { _ = try await codecs.jpeg(fromKeyframe: source[3], maxWidth: nil, maxHeight: nil) }
    }
}

@Suite(.serialized, .enabled(if: FFmpegTesting.available)) struct VideoEncoderTests {
    private func settings(width: Int = 320, height: Int = 180, fps: Int = 25, bitrate: Int = 600) -> VideoEncoderSettings {
        VideoEncoderSettings(width: width, height: height, fps: fps, bitrateKbps: bitrate, profile: .main, level: .level3_1, keyframeInterval: .seconds(1))
    }

    private func pictures(count: Int, width: Int = 320, height: Int = 180, fps: Int = 25, from first: Int = 0) -> [RawVideoFrame] {
        let pattern = YUVTestPattern(width: width, height: height)
        return (first..<(first + count)).map { pattern.frame(index: $0, pts: MediaTime(value: Int64($0) * 90_000 / Int64(fps), timescale: 90_000)) }
    }

    @Test func encodesOneFramePerPictureWithItsPTS() async throws {
        let encoder = try FFmpegTesting.makeCodecs().makeVideoEncoder(settings: settings())
        defer { encoder.invalidate() }
        var out: [EncodedVideoFrame] = []
        let input = pictures(count: 60)
        for (index, picture) in input.enumerated() {
            let frames = try await encoder.encode(picture, wallClock: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) / 25), forceKeyframe: false)
            #expect(frames.count == 1, "picture \(index) gave \(frames.count) frames")
            out += frames
        }
        #expect(out.map(\.pts) == input.map(\.pts))
        #expect(out[0].isKeyframe && out[0].format.width == 320 && out[0].format.height == 180)
        #expect(out[0].format.profile == 77)
        #expect(out.allSatisfy { $0.dts == nil })
        #expect(out[3].wallClock == Date(timeIntervalSinceReferenceDate: 800_000_000 + 3.0 / 25))
        // A one-second keyframe interval at 25 fps: IDRs at 0 and 25 and 50.
        #expect(out.enumerated().filter { $0.element.isKeyframe }.map(\.offset) == [0, 25, 50])
        // Roughly the requested bit rate (the test pattern is easy to code, so allow a wide band).
        let bytes = out.reduce(0) { $0 + $1.nalUnits.reduce(0) { $0 + $1.count } }
        #expect(bytes > 1_000 && bytes * 8 < 600_000 * 3 * 60 / 25)
    }

    @Test func aForcedKeyframeIsAnIDR() async throws {
        let encoder = try FFmpegTesting.makeCodecs().makeVideoEncoder(settings: settings())
        defer { encoder.invalidate() }
        var out: [EncodedVideoFrame] = []
        for (index, picture) in pictures(count: 10).enumerated() {
            out += try await encoder.encode(picture, wallClock: Date(), forceKeyframe: index == 5)
        }
        #expect(out.map(\.isKeyframe) == [true, false, false, false, false, true, false, false, false, false])
    }

    @Test func theOutputDecodesBackToThePicture() async throws {
        let encoder = try FFmpegTesting.makeCodecs().makeVideoEncoder(settings: settings(bitrate: 1_500))
        defer { encoder.invalidate() }
        let input = pictures(count: 5)
        var out: [EncodedVideoFrame] = []
        for picture in input { out += try await encoder.encode(picture, wallClock: Date(), forceKeyframe: false) }
        let decoder = try FFmpegTesting.makeCodecs().makeVideoDecoder(format: out[0].format)
        defer { decoder.invalidate() }
        let decoded = try #require(try await decoder.decode(out[0]) as? RawVideoFrame)
        let before = try #require(input[0].pictureStatistics()), after = try #require(decoded.pictureStatistics())
        #expect(abs(before.meanLuma - after.meanLuma) < 4 && abs(before.meanCb - after.meanCb) < 3)
        #expect(decoded.width == 320 && decoded.height == 180)
    }

    @Test func aPictureOfAnotherSizeIsScaledWithBars() async throws {
        let encoder = try FFmpegTesting.makeCodecs().makeVideoEncoder(settings: settings(width: 320, height: 320))
        defer { encoder.invalidate() }
        let out = try await encoder.encode(pictures(count: 1, width: 640, height: 360)[0], wallClock: Date(), forceKeyframe: false)
        #expect(out.first?.format.width == 320 && out.first?.format.height == 320)
    }

    @Test func aNewTimelineStartsANewKeyframe() async throws {
        let encoder = try FFmpegTesting.makeCodecs().makeVideoEncoder(settings: settings())
        defer { encoder.invalidate() }
        var out: [EncodedVideoFrame] = []
        for picture in pictures(count: 5, from: 100) { out += try await encoder.encode(picture, wallClock: Date(), forceKeyframe: false) }
        for picture in pictures(count: 3, from: 0) { out += try await encoder.encode(picture, wallClock: Date(), forceKeyframe: false) }
        #expect(out.map(\.isKeyframe) == [true, false, false, false, false, true, false, false])
    }

    @Test func releasingTheEncoderKillsTheChild() async throws {
        var encoder: (any VideoEncoding)? = try FFmpegTesting.makeCodecs().makeVideoEncoder(settings: settings())
        _ = try await encoder?.encode(pictures(count: 1, width: 338, height: 190)[0], wallClock: Date(), forceKeyframe: false)
        #expect(ChildProcesses.count(commandContaining: "338x190") == 1)
        encoder = nil
        let gone = try await FFmpegTesting.eventually(timeout: .seconds(5)) { ChildProcesses.count(commandContaining: "338x190") == 0 ? true : nil }
        #expect(gone == true)
    }

    @Test func settingsAndPicturesAreValidated() async throws {
        #expect(throws: MediaCodecError.self) { _ = try FFmpegTesting.makeCodecs().makeVideoEncoder(settings: VideoEncoderSettings(width: 0, height: 100, fps: 25, bitrateKbps: 100)) }
        let encoder = try FFmpegTesting.makeCodecs().makeVideoEncoder(settings: settings())
        defer { encoder.invalidate() }
        await #expect(throws: MediaCodecError.self) { _ = try await encoder.encode(RawVideoFrame(width: 320, height: 180, pts: MediaTime(value: 0, timescale: 90_000), pixels: Data(count: 10)), wallClock: Date(), forceKeyframe: false) }
        struct Foreign: DecodedVideoFrame {
            var width = 2, height = 2, pts = MediaTime(value: 0, timescale: 90_000)
            func grayThumbnail(maxWidth: Int) -> GrayImage? { nil }
        }
        await #expect(throws: MediaCodecError.self) { _ = try await encoder.encode(Foreign(), wallClock: Date(), forceKeyframe: false) }
    }

    @Test func invalidateKillsTheChild() async throws {
        let encoder = try FFmpegTesting.makeCodecs().makeVideoEncoder(settings: settings())
        _ = try await encoder.encode(pictures(count: 1, width: 330, height: 186)[0], wallClock: Date(), forceKeyframe: false)
        #expect(ChildProcesses.count(commandContaining: "330x186") == 1)
        encoder.invalidate()
        let gone = try await FFmpegTesting.eventually(timeout: .seconds(5)) { ChildProcesses.count(commandContaining: "330x186") == 0 ? true : nil }
        #expect(gone == true)
    }
}
