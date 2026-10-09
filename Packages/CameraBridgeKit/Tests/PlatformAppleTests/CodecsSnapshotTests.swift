#if os(macOS)
import Foundation
import MediaCore
import Testing
@testable import PlatformApple

@Suite(.timeLimit(.minutes(1))) struct CodecsSnapshotTests {
    let codecs = CodecFixtures.codecs

    @Test func jpegFromPixelBufferKeepsAspectWithinTheBounds() throws {
        let picture = try #require(try CodecFixtures.pictures(width: 1280, height: 720, count: 1).first)
        let cases: [(Int?, Int?, Int, Int)] = [
            (640, nil, 640, 360),
            (nil, 180, 320, 180),
            (nil, nil, 1280, 720),
            (4_000, 4_000, 1280, 720),   // never upscales
            (640, 100, 178, 100),        // fits both bounds
        ]
        for (maxWidth, maxHeight, width, height) in cases {
            let jpeg = try codecs.jpeg(from: picture, maxWidth: maxWidth, maxHeight: maxHeight, quality: 0.8)
            #expect(jpeg.starts(with: [0xFF, 0xD8]))
            let size = try #require(CodecFixtures.decodedImageSize(jpeg))
            #expect(size.width == width && size.height == height, "\(String(describing: maxWidth))×\(String(describing: maxHeight))")
        }
    }

    @Test func qualityChangesTheSize() throws {
        let picture = try #require(try CodecFixtures.pictures(width: 1280, height: 720, count: 1).first)
        let low = try codecs.jpeg(from: picture, maxWidth: nil, maxHeight: nil, quality: 0.2)
        let high = try codecs.jpeg(from: picture, maxWidth: nil, maxHeight: nil, quality: 0.95)
        #expect(low.count < high.count)
    }

    @Test func jpegFromAKeyframe() async throws {
        let keyframe = try CodecFixtures.encodedStream(width: 1280, height: 720, count: 1, bitrateKbps: 2_000, keyframeInterval: .seconds(1))[0]
        let jpeg = try await codecs.jpeg(fromKeyframe: keyframe, maxWidth: 320, maxHeight: nil)
        let size = try #require(CodecFixtures.decodedImageSize(jpeg))
        #expect(size.width == 320 && size.height == 180)
    }

    @Test(.enabled(if: CodecFixtures.hevcAvailable, "no HEVC encoder on this Mac"))
    func jpegFromAnHEVCKeyframe() async throws {
        let keyframe = try CodecFixtures.encodedStream(width: 1280, height: 720, count: 1, bitrateKbps: 2_000, keyframeInterval: .seconds(1), codec: .hevc)[0]
        let jpeg = try await codecs.jpeg(fromKeyframe: keyframe, maxWidth: 640, maxHeight: 360)
        let size = try #require(CodecFixtures.decodedImageSize(jpeg))
        #expect(size.width == 640 && size.height == 360)
    }

    @Test func resizeJPEGKeepsAspect() throws {
        let picture = try #require(try CodecFixtures.pictures(width: 1280, height: 720, count: 1).first)
        let original = try codecs.jpeg(from: picture, maxWidth: nil, maxHeight: nil, quality: 0.8)
        let byWidth = try #require(CodecFixtures.decodedImageSize(try codecs.resizeJPEG(original, maxWidth: 320, maxHeight: nil)))
        #expect(byWidth.width == 320 && byWidth.height == 180)
        let byHeight = try #require(CodecFixtures.decodedImageSize(try codecs.resizeJPEG(original, maxWidth: 1000, maxHeight: 90)))
        #expect(byHeight.width == 160 && byHeight.height == 90)
        // Already within bounds: returned unchanged.
        #expect(try codecs.resizeJPEG(original, maxWidth: nil, maxHeight: nil) == original)
        #expect(try codecs.resizeJPEG(original, maxWidth: 1920, maxHeight: 1080) == original)
    }

    @Test func resizeRejectsNonImages() {
        #expect(throws: MediaCodecError.self) { _ = try codecs.resizeJPEG(Data("not a jpeg".utf8), maxWidth: 100, maxHeight: nil) }
        #expect(throws: MediaCodecError.self) { _ = try codecs.resizeJPEG(Data(), maxWidth: nil, maxHeight: nil) }
    }

    @Test func fittedSizeKeepsEvenAspectAndNeverUpscales() {
        #expect(JPEGSnapshot.fittedSize(width: 1920, height: 1080, maxWidth: 640, maxHeight: nil) == (640, 360))
        #expect(JPEGSnapshot.fittedSize(width: 1920, height: 1080, maxWidth: nil, maxHeight: nil) == (1920, 1080))
        #expect(JPEGSnapshot.fittedSize(width: 1280, height: 960, maxWidth: 640, maxHeight: 360) == (480, 360))
        #expect(JPEGSnapshot.fittedSize(width: 100, height: 100, maxWidth: 0, maxHeight: -1) == (100, 100))
        #expect(JPEGSnapshot.fittedSize(width: 3000, height: 10, maxWidth: 30, maxHeight: nil) == (30, 1))
    }
}
#endif
