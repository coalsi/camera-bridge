#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import Testing
@testable import PlatformApple

@Suite(.timeLimit(.minutes(1))) struct CodecsVideoEncodeDecodeTests {
    let codecs = CodecFixtures.codecs

    @Test func encodesSynthetic720pFramesAndDecodesThemBack() async throws {
        let settings = VideoEncoderSettings(width: 1280, height: 720, fps: 30, bitrateKbps: 2_000, keyframeInterval: .seconds(1))
        let encoder = try codecs.makeVideoEncoder(settings: settings)
        let pictures = try CodecFixtures.pictures(width: 1280, height: 720, count: 45)
        var encoded: [EncodedVideoFrame] = []
        for (index, picture) in pictures.enumerated() {
            encoded += try await encoder.encode(picture, wallClock: CodecFixtures.origin.addingTimeInterval(Double(index) / 30), forceKeyframe: false)
        }
        encoder.invalidate()
        #expect(encoded.count == 45)
        let first = try #require(encoded.first)
        #expect(first.isKeyframe && first.format.codec == .h264)
        #expect(first.format.width == 1280 && first.format.height == 720 && first.format.parameterSets.count == 2)
        #expect(first.nalUnits.contains { NALUnits.h264Type($0) == 5 })   // IDR
        for frame in encoded {
            // Parameter sets and AUDs live in the format, never in the access unit.
            #expect(!frame.nalUnits.contains { [7, 8, 9].contains(NALUnits.h264Type($0)) })
            #expect(frame.dts == nil)
        }
        #expect(encoded.map(\.pts) == pictures.map(\.pts))
        #expect(encoded[10].wallClock == CodecFixtures.origin.addingTimeInterval(10.0 / 30))

        let decoder = try codecs.makeVideoDecoder(format: first.format)
        defer { decoder.invalidate() }
        for (frame, original) in zip(encoded, pictures) {
            let decoded = try #require(try await decoder.decode(frame) as? PixelBufferFrame)
            #expect(decoded.width == 1280 && decoded.height == 720 && decoded.pts == frame.pts)
            let a = try #require(decoded.grayThumbnail(maxWidth: 160))
            let b = try #require(original.grayThumbnail(maxWidth: 160))
            #expect(CodecFixtures.meanDifference(a, b) < 12)   // same picture after a lossy round trip
        }
    }

    @Test func encoderHonoursKeyframeIntervalProfileAndLevel() async throws {
        let frames = try CodecFixtures.encodedStream(width: 1280, height: 720, count: 150, bitrateKbps: 1_500, profile: .main, level: .level4_0,
                                                     keyframeInterval: .seconds(1))
        #expect(frames.count == 150)
        let keyframes = frames.indices.filter { frames[$0].isKeyframe }
        #expect(keyframes == [0, 30, 60, 90, 120])
        for index in keyframes { #expect(frames[index].nalUnits.contains { NALUnits.h264Type($0) == 5 }) }
        let sps = try #require(CodecFixtures.sps(of: frames[0]))
        #expect(sps.profileIDC == 77 && sps.levelIDC == 40 && sps.width == 1280 && sps.height == 720)
    }

    @Test(arguments: [(VideoEncoderSettings.EncoderProfile.baseline, UInt8(66)), (.high, UInt8(100))])
    func encoderProfiles(profile: VideoEncoderSettings.EncoderProfile, profileIDC: UInt8) throws {
        let frames = try CodecFixtures.encodedStream(width: 640, height: 360, count: 3, bitrateKbps: 800, profile: profile, level: .level3_1,
                                                     keyframeInterval: .seconds(1))
        let sps = try #require(frames.first.flatMap(CodecFixtures.sps))
        #expect(sps.profileIDC == profileIDC && sps.levelIDC == 31)
    }

    @Test func forceKeyframeProducesAnIDROnThatFrame() async throws {
        let encoder = try codecs.makeVideoEncoder(settings: VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 800, keyframeInterval: .seconds(10)))
        defer { encoder.invalidate() }
        var keyframes: [Int] = []
        var idrs: [Int] = []
        for (index, picture) in try CodecFixtures.pictures(width: 640, height: 360, count: 20).enumerated() {
            let output = try await encoder.encode(picture, wallClock: Date(), forceKeyframe: index == 7)
            if output.first?.isKeyframe == true { keyframes.append(index) }
            if output.first?.nalUnits.contains(where: { NALUnits.h264Type($0) == 5 }) == true { idrs.append(index) }
        }
        #expect(keyframes == [0, 7])
        #expect(idrs == [0, 7])   // an IDR access unit (NAL type 5), not just a flag
    }

    @Test func encoderRestartsWhenTheTimelineGoesBackwards() async throws {
        // A reconnected source starts its PTS again (more than 1 s back); the encoder starts a new session with an IDR.
        let encoder = try codecs.makeVideoEncoder(settings: VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 800, keyframeInterval: .seconds(10)))
        defer { encoder.invalidate() }
        let pictures = try CodecFixtures.pictures(width: 640, height: 360, count: 45)   // 1.5 s
        var outputs: [EncodedVideoFrame] = []
        for picture in pictures + pictures.prefix(5) {
            outputs += try await encoder.encode(picture, wallClock: Date(), forceKeyframe: false)
        }
        #expect(outputs.count == 50)
        #expect(outputs.indices.filter { outputs[$0].isKeyframe } == [0, 45])
        #expect(outputs[45].nalUnits.contains { NALUnits.h264Type($0) == 5 })
        #expect(outputs[45].pts == pictures[0].pts && outputs[49].pts == pictures[4].pts)
    }

    @Test func duplicateOrSlightlyEarlierTimestampsDoNotRestartTheEncoder() async throws {
        // Cameras send duplicate or jittery timestamps; VideoToolbox accepts them, so no new session (and no IDR).
        let encoder = try codecs.makeVideoEncoder(settings: VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 800, keyframeInterval: .seconds(10)))
        defer { encoder.invalidate() }
        let pattern = TestPattern(width: 640, height: 360)
        let timestamps: [Int64] = [0, 3_000, 3_000, 6_000, 6_000, 9_000, 8_000, 12_000, 12_000, 15_000]
        var outputs: [EncodedVideoFrame] = []
        for (index, pts) in timestamps.enumerated() {
            let picture = try pattern.makeFrame(index: index, pts: MediaTime(value: pts, timescale: 90_000))
            outputs += try await encoder.encode(picture, wallClock: Date(), forceKeyframe: false)
        }
        #expect(outputs.map(\.pts.value) == timestamps)   // one output per picture, same PTS
        #expect(outputs.indices.filter { outputs[$0].isKeyframe } == [0])
    }

    @Test func encoderScalesPicturesOfAnotherSize() async throws {
        let encoder = try codecs.makeVideoEncoder(settings: VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 800))
        defer { encoder.invalidate() }
        let picture = try #require(try CodecFixtures.pictures(width: 1280, height: 720, count: 1).first)
        let output = try await encoder.encode(picture, wallClock: Date(), forceKeyframe: false)
        #expect(output.first?.format.width == 640 && output.first?.format.height == 360)
    }

    @Test func encoderRejectsForeignPictures() async throws {
        let encoder = try codecs.makeVideoEncoder(settings: VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 800))
        defer { encoder.invalidate() }
        await #expect(throws: MediaCodecError.self) {
            _ = try await encoder.encode(ForeignPicture(), wallClock: Date(), forceKeyframe: false)
        }
    }

    @Test func invalidEncoderSettingsThrow() {
        #expect(throws: MediaCodecError.self) { _ = try codecs.makeVideoEncoder(settings: VideoEncoderSettings(width: 0, height: 360, fps: 30, bitrateKbps: 800)) }
        #expect(throws: MediaCodecError.self) { _ = try codecs.makeVideoEncoder(settings: VideoEncoderSettings(width: 640, height: 360, fps: 0, bitrateKbps: 800)) }
    }

    /// HomeKit advertises levels 3.1/3.2/4.0 for every resolution, so a controller may pick 1080p at level 3.1, which
    /// VideoToolbox refuses (-12902). The encoder raises the level to the lowest one whose frame size and macroblock
    /// rate fit (H.264 Table A-1), never below the requested one.
    @Test(arguments: [(1920, 1080, 30, VideoEncoderSettings.EncoderLevel.level3_1, UInt8(40)), (1920, 1080, 30, .level3_2, 40),
                      (1280, 720, 60, .level3_1, 32), (1920, 1080, 60, .level4_0, 42), (1920, 1440, 30, .level4_0, 50),
                      (640, 360, 30, .level4_1, 41), (1280, 720, 30, .level3_1, 31)])
    func levelIsRaisedToFitTheFrameSizeAndRate(width: Int, height: Int, fps: Int, level: VideoEncoderSettings.EncoderLevel, levelIDC: UInt8) throws {
        let frames = try CodecFixtures.encodedStream(width: width, height: height, count: 2, fps: fps, bitrateKbps: 2_000, profile: .main, level: level,
                                                     keyframeInterval: .seconds(1))
        let sps = try #require(frames.first.flatMap(CodecFixtures.sps))
        #expect(sps.levelIDC == levelIDC && sps.profileIDC == 77 && sps.width == width && sps.height == height)
    }

    @Test func levelFittingFollowsTableA1() {
        typealias Level = VideoEncoderSettings.EncoderLevel
        #expect(AppleVideoEncoder.fittedH264Level(width: 1920, height: 1080, fps: 30, requested: .level3_1) == 40)
        #expect(AppleVideoEncoder.fittedH264Level(width: 1920, height: 1080, fps: 25, requested: .level3_1) == 40)
        #expect(AppleVideoEncoder.fittedH264Level(width: 1920, height: 1080, fps: 31, requested: .level4_0) == 42)   // 252 960 MB/s > 245 760
        #expect(AppleVideoEncoder.fittedH264Level(width: 1280, height: 720, fps: 30, requested: .level3_1) == 31)
        #expect(AppleVideoEncoder.fittedH264Level(width: 1280, height: 720, fps: 31, requested: .level3_1) == 32)
        #expect(AppleVideoEncoder.fittedH264Level(width: 1280, height: 960, fps: 15, requested: .level3_1) == 32)    // 4800 MBs > 3600
        #expect(AppleVideoEncoder.fittedH264Level(width: 3840, height: 2160, fps: 30, requested: .level4_0) == 51)
        #expect(AppleVideoEncoder.fittedH264Level(width: 3840, height: 2160, fps: 60, requested: .level4_0) == 52)
        #expect(AppleVideoEncoder.fittedH264Level(width: 4096, height: 2304, fps: 60, requested: .level4_0) == nil)   // 2 211 840 MB/s > 5.2
        #expect(AppleVideoEncoder.fittedH264Level(width: 7680, height: 4320, fps: 30, requested: .level4_0) == nil)   // beyond 5.2: AutoLevel
        #expect(AppleVideoEncoder.fittedH264Level(width: 320, height: 240, fps: 30, requested: .level5_1) == 51)     // never lowered
        #expect(AppleVideoEncoder.fittedH264Level(width: 1920, height: 1080, fps: 30, requested: .auto) == nil)
    }

    @Test func decoderFollowsAFormatChange() async throws {
        let small = try CodecFixtures.encodedStream(width: 640, height: 360, count: 2, bitrateKbps: 800, keyframeInterval: .seconds(1))
        let large = try CodecFixtures.encodedStream(width: 1280, height: 720, count: 2, bitrateKbps: 1_500, keyframeInterval: .seconds(1))
        let decoder = try codecs.makeVideoDecoder(format: small[0].format)
        defer { decoder.invalidate() }
        #expect(try await decoder.decode(small[0])?.width == 640)
        #expect(try await decoder.decode(large[0])?.width == 1280)
        #expect(try await decoder.decode(large[1])?.height == 720)
    }

    @Test func decoderRejectsInvalidInputWithoutCrashing() async throws {
        #expect(throws: MediaCodecError.self) {
            _ = try codecs.makeVideoDecoder(format: VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: []))
        }
        let valid = try CodecFixtures.encodedStream(width: 640, height: 360, count: 1, bitrateKbps: 800, keyframeInterval: .seconds(1))[0]
        let decoder = try codecs.makeVideoDecoder(format: valid.format)
        defer { decoder.invalidate() }
        var garbage = valid
        garbage.nalUnits = [Data([0x65, 0xFF, 0x00, 0x12, 0x34])]
        do {
            _ = try await decoder.decode(garbage)   // either no picture or a codec error
        } catch let error as MediaCodecError {
            #expect(error != .noFrame)
        }
        var empty = valid
        empty.nalUnits = []
        #expect(try await decoder.decode(empty) == nil)
        // Still usable afterwards.
        #expect(try await decoder.decode(valid)?.width == 640)
    }

    @Test(.enabled(if: CodecFixtures.hevcAvailable, "no HEVC encoder on this Mac"))
    func hevcInputDecodes() async throws {
        let hevc = try CodecFixtures.encodedStream(width: 1280, height: 720, count: 10, bitrateKbps: 2_000, keyframeInterval: .seconds(1), codec: .hevc)
        #expect(hevc.count == 10 && hevc[0].format.codec == .hevc && hevc[0].format.parameterSets.count == 3)
        #expect(hevc[0].isKeyframe && !hevc[0].nalUnits.contains { (32...35).contains(NALUnits.hevcType($0)) })
        let decoder = try codecs.makeVideoDecoder(format: hevc[0].format)
        defer { decoder.invalidate() }
        for frame in hevc {
            let picture = try #require(try await decoder.decode(frame))
            #expect(picture.width == 1280 && picture.height == 720 && picture.pts == frame.pts)
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct CodecsVideoTranscoderTests {
    let codecs = CodecFixtures.codecs
    let output = VideoEncoderSettings(width: 1280, height: 720, fps: 30, bitrateKbps: 1_000, profile: .main, level: .level4_0, keyframeInterval: .seconds(2))

    @Test func transcodes1080pTo720pMain40WithKeyframeSpacingAndBitrate() async throws {
        let input = CodecFixtures.fullHDInput
        try #require(input.count == 300)
        #expect(input[0].format.width == 1920 && input[0].format.height == 1080)
        let transcoder = try codecs.makeVideoTranscoder(output: output)
        defer { transcoder.invalidate() }
        var frames: [EncodedVideoFrame] = []
        for frame in input { frames += try await transcoder.transcode(frame) }
        #expect(frames.count == 300)
        #expect(frames.map(\.pts) == input.map(\.pts) && frames.map(\.wallClock) == input.map(\.wallClock))
        let sps = try #require(frames.first.flatMap(CodecFixtures.sps))
        #expect(sps.width == 1280 && sps.height == 720 && sps.profileIDC == 77 && sps.levelIDC == 40)
        // IDR every 2 s (60 frames at 30 fps), independent of the input's 4 s GOP.
        let keyframes = frames.indices.filter { frames[$0].isKeyframe }
        #expect(keyframes == [0, 60, 120, 180, 240])
        for index in keyframes { #expect(frames[index].nalUnits.contains { NALUnits.h264Type($0) == 5 }) }
        // Average bitrate over the 10 s within ±30 % of the 1000 kbit/s target.
        let kbps = Double(CodecFixtures.bytes(frames) * 8) / 10 / 1000
        #expect(kbps > 700 && kbps < 1_300, "measured \(kbps) kbit/s")
        // Peak over any 1 s window (30 frames) within the DataRateLimits cap of 1.5 × the average target.
        let peak = (0...(frames.count - 30)).map { Double(CodecFixtures.bytes(Array(frames[$0..<($0 + 30)])) * 8) / 1000 }.max() ?? 0
        #expect(peak <= 1_500, "peak \(peak) kbit/s over 1 s")
    }

    @Test func requestKeyframeMakesTheNextFrameAnIDR() async throws {
        let input = CodecFixtures.fullHDInput
        try #require(input.count >= 90)
        let transcoder = try codecs.makeVideoTranscoder(output: output)
        defer { transcoder.invalidate() }
        var keyframes: [Int] = []
        var idrs: [Int] = []
        for index in 0..<90 {
            if index == 45 { transcoder.requestKeyframe() }
            if index == 20 { transcoder.updateBitrate(kbps: 600) }
            let frames = try await transcoder.transcode(input[index])
            #expect(frames.count == 1)
            if frames.first?.isKeyframe == true { keyframes.append(index) }
            if frames.first?.nalUnits.contains(where: { NALUnits.h264Type($0) == 5 }) == true { idrs.append(index) }
        }
        #expect(keyframes.first == 0 && keyframes.contains(45))
        #expect(!keyframes.contains { $0 > 0 && $0 < 45 })
        #expect(idrs == keyframes)   // IDR access units (NAL type 5)
    }

    @Test func transcoderFitsTheLevelOfA1080pOutput() async throws {
        let input = CodecFixtures.fullHDInput
        try #require(input.count >= 3)
        let transcoder = try codecs.makeVideoTranscoder(output: VideoEncoderSettings(width: 1920, height: 1080, fps: 30, bitrateKbps: 2_000, profile: .main,
                                                                                     level: .level3_1, keyframeInterval: .seconds(4)))
        defer { transcoder.invalidate() }
        var frames: [EncodedVideoFrame] = []
        for frame in input.prefix(3) { frames += try await transcoder.transcode(frame) }
        #expect(frames.count == 3)
        let sps = try #require(frames.first.flatMap(CodecFixtures.sps))
        #expect(sps.width == 1920 && sps.height == 1080 && sps.levelIDC >= 40)
    }

    /// A 30 fps camera transcoded for a 15 fps request yields 15 fps (every other picture), keeping the IDR cadence.
    @Test func transcoderHonoursALowerOutputFrameRate() async throws {
        let input = CodecFixtures.fullHDInput
        try #require(input.count == 300)
        let transcoder = try codecs.makeVideoTranscoder(output: VideoEncoderSettings(width: 640, height: 360, fps: 15, bitrateKbps: 500, profile: .main,
                                                                                     level: .level3_1, keyframeInterval: .seconds(2)))
        defer { transcoder.invalidate() }
        var frames: [EncodedVideoFrame] = []
        for (index, frame) in input.enumerated() {
            if index == 151 { transcoder.requestKeyframe() }   // an odd frame, which decimation would skip
            frames += try await transcoder.transcode(frame)
        }
        #expect(frames.count >= 148 && frames.count <= 152, "\(frames.count) frames for 10 s")
        let spacing = zip(frames, frames.dropFirst()).map { $1.pts.value - $0.pts.value }
        #expect(spacing.filter { $0 < 6_000 }.count <= 1, "\(spacing)")   // only around the requested keyframe
        let keyframes = frames.filter(\.isKeyframe).map(\.pts.value)
        #expect(keyframes.first == 0 && keyframes.contains(input[151].pts.value), "\(keyframes)")
        #expect(keyframes.count >= 5 && zip(keyframes, keyframes.dropFirst()).allSatisfy { $1 - $0 <= 180_000 }, "\(keyframes)")   // IDR ≤ 2 s apart
        // 30 → 30 fps keeps every picture.
        let same = try codecs.makeVideoTranscoder(output: VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 500))
        defer { same.invalidate() }
        var all = 0
        for frame in input.prefix(60) { all += try await same.transcode(frame).count }
        #expect(all == 60)
    }

    @Test func dropsDeltaFramesUntilTheFirstKeyframe() async throws {
        let input = CodecFixtures.fullHDInput
        try #require(input.count >= 125)
        let transcoder = try codecs.makeVideoTranscoder(output: VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 500))
        defer { transcoder.invalidate() }
        #expect(try await transcoder.transcode(input[118]).isEmpty)
        #expect(try await transcoder.transcode(input[119]).isEmpty)
        let first = try await transcoder.transcode(input[120])   // the input's keyframe at 4 s
        #expect(first.count == 1 && first[0].isKeyframe && first[0].format.width == 640)
        #expect(try await transcoder.transcode(input[121]).count == 1)
    }

    @Test(.enabled(if: CodecFixtures.hevcAvailable, "no HEVC encoder on this Mac"))
    func transcodesHEVCToH264() async throws {
        let hevc = try CodecFixtures.encodedStream(width: 1280, height: 720, count: 30, bitrateKbps: 2_000, keyframeInterval: .seconds(1), codec: .hevc)
        let transcoder = try codecs.makeVideoTranscoder(output: VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 600, keyframeInterval: .seconds(1)))
        defer { transcoder.invalidate() }
        var frames: [EncodedVideoFrame] = []
        for frame in hevc { frames += try await transcoder.transcode(frame) }
        #expect(frames.count == 30 && frames[0].isKeyframe)
        #expect(frames.allSatisfy { $0.format.codec == .h264 && $0.format.width == 640 && $0.format.height == 360 })
    }
}

@Suite(.timeLimit(.minutes(1))) struct CodecsPixelBufferFrameTests {
    /// 640×360 NV12: left half luma 16, right half luma 235.
    private func splitLumaBuffer(format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, format, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if format == kCVPixelFormatType_32BGRA {
            let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<360 {
                for x in 0..<640 {
                    let value: UInt8 = x < 320 ? 0 : 255
                    (base + y * bytesPerRow + x * 4).update(repeating: value, count: 3)
                    (base + y * bytesPerRow + x * 4 + 3).pointee = 255
                }
            }
            return pixelBuffer
        }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for y in 0..<360 {
            (luma + y * bytesPerRow).update(repeating: 16, count: 320)
            (luma + y * bytesPerRow + 320).update(repeating: 235, count: 320)
        }
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) * 180)
        return pixelBuffer
    }

    @Test func grayThumbnailDownscalesTheLumaPlaneKeepingAspect() throws {
        let frame = PixelBufferFrame(pixelBuffer: try splitLumaBuffer(), pts: .seconds(1))
        let thumbnail = try #require(frame.grayThumbnail(maxWidth: 160))
        #expect(thumbnail.width == 160 && thumbnail.height == 90 && thumbnail.pixels.count == 160 * 90)
        for y in [0, 45, 89] {
            #expect(thumbnail.pixels[y * 160] == 16 && thumbnail.pixels[y * 160 + 79] == 16)
            #expect(thumbnail.pixels[y * 160 + 80] == 235 && thumbnail.pixels[y * 160 + 159] == 235)
        }
    }

    /// Every source pixel counts: a 1920-wide picture whose luma is 235 on every third column and 16 elsewhere
    /// averages to (235 + 16 + 16) / 3 = 89 per 12-pixel block, whatever the sampling phase.
    @Test func grayThumbnailAveragesEveryPixelOfItsBlock() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for y in 0..<1080 {
            for x in 0..<1920 { luma[y * bytesPerRow + x] = x % 3 == 0 ? 235 : 16 }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let thumbnail = try #require(PixelBufferFrame(pixelBuffer: pixelBuffer, pts: .zero).grayThumbnail(maxWidth: 160))
        #expect(thumbnail.width == 160 && thumbnail.height == 90)
        #expect(thumbnail.pixels.allSatisfy { $0 == 89 }, "\(Set(thumbnail.pixels).sorted())")
    }

    @Test func grayThumbnailNeverUpscalesAndRejectsBadWidths() throws {
        let frame = PixelBufferFrame(pixelBuffer: try splitLumaBuffer(), pts: .zero)
        let full = try #require(frame.grayThumbnail(maxWidth: 4_000))
        #expect(full.width == 640 && full.height == 360 && full.pixels[0] == 16 && full.pixels[639] == 235)
        #expect(frame.grayThumbnail(maxWidth: 0) == nil && frame.grayThumbnail(maxWidth: -5) == nil)
        let odd = try #require(frame.grayThumbnail(maxWidth: 99))
        #expect(odd.width == 99 && odd.height == 56)
    }

    @Test func grayThumbnailOfBGRAUsesLuma() throws {
        let frame = PixelBufferFrame(pixelBuffer: try splitLumaBuffer(format: kCVPixelFormatType_32BGRA), pts: .zero)
        let thumbnail = try #require(frame.grayThumbnail(maxWidth: 64))
        #expect(thumbnail.width == 64 && thumbnail.height == 36)
        #expect(thumbnail.pixels[0] < 20 && thumbnail.pixels[63] > 230)
    }

    @Test func decodedFramesHaveThumbnails() throws {
        let picture = try #require(try CodecFixtures.pictures(width: 1280, height: 720, count: 1).first)
        let thumbnail = try #require(picture.grayThumbnail(maxWidth: 320))
        #expect(thumbnail.width == 320 && thumbnail.height == 180)
        #expect(Set(thumbnail.pixels).count > 10)   // a real picture, not a flat field
    }
}

private struct ForeignPicture: DecodedVideoFrame {
    var width: Int { 640 }
    var height: Int { 360 }
    var pts: MediaTime { .zero }
    func grayThumbnail(maxWidth: Int) -> GrayImage? { nil }
}

extension MediaTime {
    fileprivate static var zero: MediaTime { MediaTime(value: 0, timescale: 90_000) }
}
#endif
