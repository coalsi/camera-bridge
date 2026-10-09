import Foundation
import MediaCore
import Testing
@testable import PlatformLinux

@Suite struct ImageSizeTests {
    @Test func fittedSizeKeepsAspectAndNeverUpscales() {
        #expect(FFmpegPictures.fittedSize(width: 1920, height: 1080, maxWidth: 640, maxHeight: nil) == (640, 360))
        #expect(FFmpegPictures.fittedSize(width: 1920, height: 1080, maxWidth: nil, maxHeight: 270) == (480, 270))
        #expect(FFmpegPictures.fittedSize(width: 1920, height: 1080, maxWidth: 640, maxHeight: 100) == (178, 100))
        #expect(FFmpegPictures.fittedSize(width: 640, height: 360, maxWidth: 1920, maxHeight: 1080) == (640, 360))
        #expect(FFmpegPictures.fittedSize(width: 640, height: 360, maxWidth: 0, maxHeight: -5) == (640, 360))
        #expect(FFmpegPictures.fittedSize(width: 3, height: 1000, maxWidth: nil, maxHeight: 10) == (1, 10))
    }

    @Test func pngSizeComesFromTheHeader() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png += Data([0, 0, 0x05, 0x00, 0, 0, 0x02, 0xD0])   // 1280 × 720
        png += Data(count: 10)
        let size = FFmpegPictures.imageSize(png)
        #expect(size?.width == 1280 && size?.height == 720)
    }

    @Test func jpegSizeComesFromTheStartOfFrameMarker() {
        // SOI, an APP0 segment, a DQT-like segment, then SOF0 with 480 × 640.
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + Data(count: 14)
        jpeg += Data([0xFF, 0xDB, 0x00, 0x05, 1, 2, 3])
        jpeg += Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x02, 0x80, 0x01, 0xE0, 0x01, 0x01, 0x11, 0x00])
        let size = FFmpegPictures.imageSize(jpeg)
        #expect(size?.height == 640 && size?.width == 480)
    }

    @Test func otherDataHasNoSize() {
        #expect(FFmpegPictures.imageSize(Data("GIF89a".utf8)) == nil)
        #expect(FFmpegPictures.imageSize(Data()) == nil)
        #expect(FFmpegPictures.imageSize(Data([0xFF, 0xD8, 0xFF])) == nil)
        #expect(FFmpegPictures.imageSize(Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x04, 0, 0])) == nil)   // start of scan before any frame header
    }
}

@Suite(.serialized, .enabled(if: FFmpegTesting.available)) struct PicturesTests {
    private let pattern = YUVTestPattern(width: 640, height: 360)

    private func picture(_ index: Int = 3) -> RawVideoFrame { pattern.frame(index: index, pts: MediaTime(value: 0, timescale: 90_000)) }

    @Test func aPictureBecomesAJPEGOfTheRightSize() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let jpeg = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.8)
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]) && jpeg.suffix(2) == Data([0xFF, 0xD9]))
        let size = try #require(FFmpegPictures.imageSize(jpeg))
        #expect(size.width == 640 && size.height == 360)
        // Bounds scale it down keeping the aspect, never up.
        let small = try codecs.jpeg(from: picture(), maxWidth: 160, maxHeight: 120, quality: 0.8)
        let smallSize = try #require(FFmpegPictures.imageSize(small))
        #expect(smallSize.width == 160 && smallSize.height == 90)
        let notUp = try codecs.jpeg(from: picture(), maxWidth: 4_000, maxHeight: 4_000, quality: 0.8)
        #expect(FFmpegPictures.imageSize(notUp)?.width == 640)
        #expect(small.count < jpeg.count)
    }

    @Test func qualityChangesTheSize() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let low = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.2)
        let high = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.95)
        #expect(low.count < high.count, "\(low.count) vs \(high.count)")
    }

    @Test func oddSizesWork() throws {
        let odd = YUVTestPattern(width: 322, height: 182).frame(index: 1, pts: MediaTime(value: 0, timescale: 90_000))
        let jpeg = try FFmpegTesting.makeCodecs().jpeg(from: odd, maxWidth: 161, maxHeight: nil, quality: 0.8)
        let size = try #require(FFmpegPictures.imageSize(jpeg))
        #expect(size.width == 161 && size.height == 91, "\(size)")
    }

    @Test func theJPEGShowsThePicture() async throws {
        // Decode the JPEG again with ffmpeg through the decoder-free path: compare brightness of the left and right halves.
        let codecs = FFmpegTesting.makeCodecs()
        let jpeg = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.9)
        let runtime = FFmpegTesting.makeRuntime()
        let raw = try FFmpegOneShot.run(runtime: runtime, label: "test decode", arguments: FFmpegArguments.common + ["-f", "image2pipe", "-i", "pipe:0", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"],
                                        input: jpeg, timeout: .seconds(10))
        #expect(raw.count == 640 * 360)
        // The pattern's background gets brighter to the right.
        let left = raw[(640 * 100)..<(640 * 100 + 100)].reduce(0) { $0 + Int($1) } / 100
        let right = raw[(640 * 100 + 540)..<(640 * 101)].reduce(0) { $0 + Int($1) } / 100
        #expect(right > left + 30, "left \(left) right \(right)")
    }

    @Test func aPictureThatIsNotARawVideoFrameIsRefused() {
        struct Foreign: DecodedVideoFrame {
            var width = 2, height = 2, pts = MediaTime(value: 0, timescale: 90_000)
            func grayThumbnail(maxWidth: Int) -> GrayImage? { nil }
        }
        #expect(throws: MediaCodecError.self) { _ = try FFmpegTesting.makeCodecs().jpeg(from: Foreign(), maxWidth: nil, maxHeight: nil, quality: 0.8) }
        #expect(throws: MediaCodecError.self) {
            _ = try FFmpegTesting.makeCodecs().jpeg(from: RawVideoFrame(width: 64, height: 64, pts: MediaTime(value: 0, timescale: 90_000), pixels: Data(count: 100)),
                                                    maxWidth: nil, maxHeight: nil, quality: 0.8)
        }
    }

    @Test func resizeJPEGShrinksAndLeavesSmallImagesAlone() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let original = try codecs.jpeg(from: picture(), maxWidth: nil, maxHeight: nil, quality: 0.9)
        #expect(try codecs.resizeJPEG(original, maxWidth: 1_000, maxHeight: 1_000) == original)
        #expect(try codecs.resizeJPEG(original, maxWidth: nil, maxHeight: nil) == original)
        let smaller = try codecs.resizeJPEG(original, maxWidth: 320, maxHeight: nil)
        #expect(smaller.prefix(2) == Data([0xFF, 0xD8]))
        let size = try #require(FFmpegPictures.imageSize(smaller))
        #expect(size.width == 320 && size.height == 180)
    }

    @Test func resizeJPEGAcceptsPNGAndRefusesOtherData() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let runtime = FFmpegTesting.makeRuntime()
        let png = try FFmpegOneShot.run(runtime: runtime, label: "test png", arguments: FFmpegArguments.common + ["-f", "rawvideo", "-pix_fmt", "yuv420p", "-video_size", "640x360", "-i", "pipe:0", "-frames:v", "1", "-f", "image2pipe", "-c:v", "png", "pipe:1"],
                                        input: picture().pixels, timeout: .seconds(10))
        #expect(FFmpegPictures.imageSize(png)?.width == 640)
        let fromPNG = try codecs.resizeJPEG(png, maxWidth: 200, maxHeight: nil)
        #expect(fromPNG.prefix(2) == Data([0xFF, 0xD8]) && FFmpegPictures.imageSize(fromPNG)?.width == 200)
        #expect(throws: MediaCodecError.self) { _ = try codecs.resizeJPEG(Data("not an image".utf8), maxWidth: 10, maxHeight: 10) }
        #expect(throws: MediaCodecError.self) { _ = try codecs.resizeJPEG(Data(), maxWidth: 10, maxHeight: 10) }
    }
}

@Suite(.serialized, .enabled(if: FFmpegTesting.available)) struct SyntheticSourceTests {
    @Test func theDemoCameraDeliversTimedVideoAndAudio() async throws {
        let source = FFmpegTesting.makeCodecs().makeSyntheticSource(displayName: "Demo", width: 320, height: 180, fps: 15, keyframeInterval: .seconds(1), audio: .aac, audioSampleRate: 16_000)
        #expect(source.displayName == "Demo")
        let stream = try await source.samples()
        var video: [EncodedVideoFrame] = []
        var audio: [EncodedAudioFrame] = []
        let began = ContinuousClock.now
        for try await sample in stream {
            switch sample {
            case .video(let frame): video.append(frame)
            case .audio(let frame): audio.append(frame)
            }
            if video.count >= 40 || ContinuousClock.now - began > .seconds(10) { break }
        }
        await source.stop()
        #expect(video.count >= 40)
        #expect(video[0].isKeyframe && video[0].pts.value == 0 && video[0].format.width == 320 && video[0].format.height == 180)
        // Real time: 40 pictures at 15 fps take about 2.6 s.
        #expect(ContinuousClock.now - began > .seconds(2))
        #expect(zip(video, video.dropFirst()).allSatisfy { $1.pts.value - $0.pts.value == 6_000 })
        #expect(video.enumerated().filter { $0.element.isKeyframe }.map(\.offset).prefix(3) == [0, 15, 30])
        #expect(audio.count >= 25 && audio.allSatisfy { $0.format == AudioFormat.aacLC(sampleRate: 16_000, channels: 1) })
        #expect(zip(audio, audio.dropFirst()).allSatisfy { $1.pts.value - $0.pts.value == 1_024 })
    }

    @Test func stopEndsTheStreamAndKillsTheChildren() async throws {
        let source = FFmpegTesting.makeCodecs().makeSyntheticSource(displayName: "Demo", width: 162, height: 92, fps: 10, keyframeInterval: .seconds(1), audio: nil, audioSampleRate: 0)
        let stream = try await source.samples()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        #expect(ChildProcesses.count(commandContaining: "162x92") == 1)
        await source.stop()
        var ended = false
        for _ in 0..<100 {
            if try await iterator.next() == nil { ended = true; break }
        }
        #expect(ended)
        let gone = try await FFmpegTesting.eventually(timeout: .seconds(5)) { ChildProcesses.count(commandContaining: "162x92") == 0 ? true : nil }
        #expect(gone == true)
    }

    @Test func aSecondSamplesCallReplacesTheFirst() async throws {
        let source = FFmpegTesting.makeCodecs().makeSyntheticSource(displayName: "Demo", width: 160, height: 90, fps: 10, keyframeInterval: .seconds(1), audio: nil, audioSampleRate: 0)
        let first = try await source.samples()
        var firstIterator = first.makeAsyncIterator()
        _ = try await firstIterator.next()
        let second = try await source.samples()
        var secondIterator = second.makeAsyncIterator()
        guard case .video(let frame)? = try await secondIterator.next() else { Issue.record("no video from the second stream"); return }
        #expect(frame.isKeyframe && frame.pts.value == 0)
        // The first stream ended.
        var ended = false
        for _ in 0..<50 {
            if try await firstIterator.next() == nil { ended = true; break }
        }
        #expect(ended)
        await source.stop()
    }
}

/// Needs no ffmpeg.
@Suite struct SyntheticPatternTests {
    @Test func tinyOrInvalidSizesAreRefused() async {
        let source = FFmpegTesting.makeCodecs().makeSyntheticSource(displayName: "Demo", width: 1, height: 1, fps: 10, keyframeInterval: .seconds(1), audio: nil, audioSampleRate: 0)
        await #expect(throws: MediaCodecError.self) { _ = try await source.samples() }
    }

    @Test func theTestPatternMovesAndKeepsItsSize() {
        let pattern = YUVTestPattern(width: 64, height: 48)
        let a = pattern.frame(index: 0, pts: MediaTime(value: 0, timescale: 90_000)), b = pattern.frame(index: 5, pts: MediaTime(value: 0, timescale: 90_000))
        #expect(a.isComplete && b.isComplete && a.width == 64 && a.height == 48)
        #expect(a.pixels != b.pixels)
        #expect(YUVTestPattern(width: 65, height: 49).width == 64)
    }
}
