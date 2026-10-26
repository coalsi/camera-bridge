import Foundation
import MediaCore
import Testing
@testable import PlatformLinux

// The Sky Watcher's small pictures (`MediaCodecs.croppedJPEG`): the part of a still around a light, scaled down, as a JPEG. What the arguments say and
// how a crop that is not inside the picture is refused are tested with a fake ffmpeg; the picture that comes out against a real ffmpeg, where there is
// one.

@Suite struct CroppedPictureArgumentTests {
    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    @Test func theFilterCutsTheExactPartAndScalesItDown() throws {
        let arguments = FFmpegArguments.cropImage(ImageCrop(x: 700, y: 310, width: 640, height: 360), width: 480, height: 270, quality: 0.8)
        let filters = try #require(value(after: "-vf", in: arguments))
        #expect(filters == "crop=640:360:700:310:exact=1,scale=480:270:flags=lanczos,scale=out_range=pc,format=yuvj420p", "\(filters)")
        #expect(value(after: "-f", in: arguments) == "image2pipe" && value(after: "-i", in: arguments) == "pipe:0", "the picture comes in on stdin")
        #expect(arguments.suffix(3) == ["-f", "mjpeg", "pipe:1"], "and goes out on stdout as a JPEG")
        #expect(value(after: "-c:v", in: arguments) == "mjpeg" && value(after: "-frames:v", in: arguments) == "1")
        #expect(value(after: "-q:v", in: arguments) == "8", "0.8 is the scale the other pictures use")
    }

    @Test func aPartThatIsNotScaledIsNotScaled() throws {
        let arguments = FFmpegArguments.cropImage(ImageCrop(x: 0, y: 0, width: 213, height: 120), width: 213, height: 120, quality: 0.5)
        let filters = try #require(value(after: "-vf", in: arguments))
        #expect(filters == "crop=213:120:0:0:exact=1,scale=out_range=pc,format=yuvj420p", "no scale filter: a small close-up stays as sharp as it was")
    }
}

@Suite(.serialized) struct CroppedPictureTests {
    /// A JPEG of `width` × `height` as far as its header goes (start of image, one frame header).
    private static func header(_ width: Int, _ height: Int) -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 0x01, 0x01, 0x11, 0x00])
            + Data(count: 16) + Data([0xFF, 0xD9])
    }

    private static let answer = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00]) + Data(count: 24) + Data([0xFF, 0xD9])

    /// Codecs over a fake ffmpeg that answers every picture job with `answer`.
    private func rig() -> (launcher: FakeFFmpegLauncher, codecs: FFmpegMediaCodecs) {
        let launcher = FakeFFmpegLauncher()
        let codecs = FFmpegMediaCodecs.fake(launcher)
        let probe = launcher.onLaunch
        launcher.onLaunch = { child in
            probe?(child)
            guard child.spec.label == "snapshot crop" else { return }
            child.onWrite = { child, _ in
                child.emit(Self.answer)
                child.exit(status: 0)
            }
        }
        return (launcher, codecs)
    }

    private func crops(_ launcher: FakeFFmpegLauncher) -> [FakeFFmpegLauncher.Child] { launcher.children.filter { $0.spec.label == "snapshot crop" } }

    private func filterChain(of child: FakeFFmpegLauncher.Child) throws -> String {
        try #require(child.arguments.firstIndex(of: "-vf").map { child.arguments[$0 + 1] })
    }

    @Test func aCropRunsOneChildAtLowPriorityWithTheFilterForItsPart() throws {
        let (launcher, codecs) = rig()
        let jpeg = try codecs.croppedJPEG(Self.header(1920, 852), crop: ImageCrop(x: 800, y: 300, width: 640, height: 360), maxWidth: 480, quality: 0.8)
        #expect(jpeg == Self.answer)
        let child = try #require(crops(launcher).first)
        #expect(crops(launcher).count == 1)
        #expect(child.spec.niceness == 10, "under nice: the grid is made while video is being recorded")
        let filters = try filterChain(of: child)
        #expect(filters.hasPrefix("crop=640:360:800:300:exact=1,scale=480:270:flags=lanczos,"), "\(filters)")
        #expect(child.input == Self.header(1920, 852), "the picture went in as it was")
    }

    @Test func aPartNarrowerThanTheLimitKeepsItsSize() throws {
        let (launcher, codecs) = rig()
        _ = try codecs.croppedJPEG(Self.header(1920, 852), crop: ImageCrop(x: 10, y: 20, width: 213, height: 120), maxWidth: 480, quality: 0.8)
        let filters = try filterChain(of: try #require(crops(launcher).first))
        #expect(filters.hasPrefix("crop=213:120:10:20:exact=1,scale=out_range=pc"), "never scaled up: \(filters)")
    }

    @Test func theWholePictureIsScaledToTheLimitAndAWholePictureThatFitsIsLeftAlone() throws {
        let (launcher, codecs) = rig()
        _ = try codecs.croppedJPEG(Self.header(1920, 852), crop: nil, maxWidth: 480, quality: 0.8)
        let filters = try filterChain(of: try #require(crops(launcher).first))
        #expect(filters.hasPrefix("crop=1920:852:0:0:exact=1,scale=480:213:flags=lanczos,"), "the shape is kept: \(filters)")
        let small = Self.header(400, 177)
        #expect(try codecs.croppedJPEG(small, crop: nil, maxWidth: 480, quality: 0.8) == small, "already fits: returned as it came")
        #expect(crops(launcher).count == 1, "and no child for it")
    }

    @Test func aCropOutsideThePictureOrDataThatIsNoImageIsRefusedWithoutAChild() throws {
        let (launcher, codecs) = rig()
        let picture = Self.header(1920, 852)
        for crop in [ImageCrop(x: 1800, y: 0, width: 200, height: 100), ImageCrop(x: 0, y: 800, width: 100, height: 100), ImageCrop(x: -1, y: 0, width: 100, height: 100),
                     ImageCrop(x: 0, y: 0, width: 0, height: 100), ImageCrop(x: 0, y: 0, width: 100, height: 0), ImageCrop(x: 0, y: 0, width: 1921, height: 852)] {
            #expect(throws: MediaCodecError.self, "\(crop)") { _ = try codecs.croppedJPEG(picture, crop: crop, maxWidth: 480, quality: 0.8) }
        }
        #expect(throws: MediaCodecError.self) { _ = try codecs.croppedJPEG(Data("not an image".utf8), crop: nil, maxWidth: 480, quality: 0.8) }
        #expect(throws: MediaCodecError.self) { _ = try codecs.croppedJPEG(Data(), crop: ImageCrop(x: 0, y: 0, width: 10, height: 10), maxWidth: 480, quality: 0.8) }
        #expect(crops(launcher).isEmpty, "nothing was run for any of them")
    }

    @Test func anAnswerThatIsNoJPEGIsAFailure() throws {
        let launcher = FakeFFmpegLauncher()
        let codecs = FFmpegMediaCodecs.fake(launcher)
        let probe = launcher.onLaunch
        launcher.onLaunch = { child in
            probe?(child)
            guard child.spec.label == "snapshot crop" else { return }
            child.onWrite = { child, _ in
                child.emit(Data("nothing".utf8))
                child.exit(status: 0)
            }
        }
        #expect(throws: MediaCodecError.self) {
            _ = try codecs.croppedJPEG(Self.header(1920, 852), crop: ImageCrop(x: 0, y: 0, width: 640, height: 360), maxWidth: 480, quality: 0.8)
        }
    }
}

@Suite(.serialized, .enabled(if: FFmpegTesting.available)) struct CroppedPictureFFmpegTests {
    private let pattern = YUVTestPattern(width: 640, height: 360)

    private func picture() throws -> Data {
        try FFmpegTesting.makeCodecs().jpeg(from: pattern.frame(index: 3, pts: MediaTime(value: 0, timescale: 90_000)), maxWidth: nil, maxHeight: nil, quality: 0.9)
    }

    /// The mean luma of a JPEG, decoded again by ffmpeg.
    private func brightness(_ jpeg: Data) throws -> Double {
        let size = try #require(FFmpegPictures.imageSize(jpeg))
        let raw = try FFmpegOneShot.run(runtime: FFmpegTesting.makeRuntime(), label: "test decode",
                                        arguments: FFmpegArguments.common + ["-f", "image2pipe", "-i", "pipe:0", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"],
                                        input: jpeg, timeout: .seconds(10))
        #expect(raw.count == size.width * size.height)
        return Double(raw.reduce(0) { $0 + Int($1) }) / Double(max(1, raw.count))
    }

    @Test func thePartComesOutAtItsOwnSizeOrScaledDownAndShowsThatPartOfThePicture() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let original = try picture()
        // The pattern gets brighter to the right: two parts of the same size, away from the box that bounces at the left edge.
        let left = try codecs.croppedJPEG(original, crop: ImageCrop(x: 100, y: 120, width: 200, height: 113), maxWidth: 480, quality: 0.8)
        let right = try codecs.croppedJPEG(original, crop: ImageCrop(x: 440, y: 120, width: 200, height: 113), maxWidth: 480, quality: 0.8)
        for jpeg in [left, right] {
            #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]) && jpeg.suffix(2) == Data([0xFF, 0xD9]))
            let size = try #require(FFmpegPictures.imageSize(jpeg))
            #expect(size.width == 200 && size.height == 113, "the part's own size, not scaled up: \(size)")
        }
        let difference = try brightness(right) - brightness(left)
        #expect(difference > 40, "the right part is brighter by about 64 levels: \(difference)")

        // A part wider than the limit is scaled down to it, its shape kept.
        let wide = try codecs.croppedJPEG(original, crop: ImageCrop(x: 0, y: 0, width: 640, height: 360), maxWidth: 160, quality: 0.8)
        let wideSize = try #require(FFmpegPictures.imageSize(wide))
        #expect(wideSize.width == 160 && wideSize.height == 90, "\(wideSize)")
    }

    @Test func theWholePictureIsMadeSmallerAndOneThatFitsComesBackAsItWas() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let original = try picture()
        let small = try codecs.croppedJPEG(original, crop: nil, maxWidth: 320, quality: 0.8)
        let size = try #require(FFmpegPictures.imageSize(small))
        #expect(size.width == 320 && size.height == 180 && small.count < original.count, "\(size), \(small.count) of \(original.count) bytes")
        #expect(try codecs.croppedJPEG(original, crop: nil, maxWidth: 640, quality: 0.8) == original)
    }

    @Test func theQualityChangesTheSize() throws {
        let codecs = FFmpegTesting.makeCodecs()
        let original = try picture()
        let part = ImageCrop(x: 0, y: 0, width: 640, height: 360)
        let low = try codecs.croppedJPEG(original, crop: part, maxWidth: 320, quality: 0.1)
        let high = try codecs.croppedJPEG(original, crop: part, maxWidth: 320, quality: 0.95)
        #expect(low.count < high.count, "\(low.count) bytes at 0.1, \(high.count) at 0.95")
    }

    @Test func aCropAtAnOddPlaceIsCutWhereItWasAsked() throws {
        // `exact=1`: the part starts at the pixel asked for, not at the even one before it (the chroma is shared by two pixels).
        let codecs = FFmpegTesting.makeCodecs()
        let original = try picture()
        let odd = try codecs.croppedJPEG(original, crop: ImageCrop(x: 301, y: 121, width: 201, height: 113), maxWidth: 480, quality: 0.9)
        let even = try codecs.croppedJPEG(original, crop: ImageCrop(x: 300, y: 120, width: 200, height: 112), maxWidth: 480, quality: 0.9)
        let size = try #require(FFmpegPictures.imageSize(odd))
        #expect(size.width == 201 && size.height == 113, "\(size)")
        #expect(abs(try brightness(odd) - brightness(even)) < 3)
    }
}
