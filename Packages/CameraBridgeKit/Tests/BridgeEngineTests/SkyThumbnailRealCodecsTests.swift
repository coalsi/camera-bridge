import Foundation
import MediaCore
import Testing
@testable import BridgeEngine
#if os(macOS)
import CoreGraphics
import ImageIO
import PlatformApple
#endif
#if os(Linux)
@testable import PlatformLinux
#endif

/// A real picture and the real codecs of this platform (ImageIO on the Mac, where the daemon runs its codecs for development; ffmpeg on the box).
enum RealPictures {
    /// The codecs the daemon has on this platform; nil when there are none to try (no ffmpeg).
    static func codecs() -> (any MediaCodecs)? {
        #if os(macOS)
        return AppleMediaCodecs()
        #else
        let codecs = FFmpegMediaCodecs()
        return codecs.isAvailable ? codecs : nil
        #endif
    }

    /// A JPEG of `width` × `height` that gets brighter from the left to the right, as a camera's still is made.
    static func still(width: Int, height: Int) throws -> Data {
        #if os(macOS)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = UInt8(x * 255 / max(1, width - 1)) } }
        let image = try pixels.withUnsafeMutableBytes { bytes -> CGImage in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            return try #require(context.makeImage())
        }
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
        #else
        var picture = Data(repeating: 128, count: RawVideoFrame.byteCount(width: width, height: height))
        for y in 0..<height { for x in 0..<width { picture[y * width + x] = UInt8(16 + x * 200 / max(1, width - 1)) } }
        let frame = RawVideoFrame(width: width, height: height, pts: MediaTime(value: 0, timescale: 90_000), pixels: picture)
        return try FFmpegMediaCodecs().jpeg(from: frame, maxWidth: nil, maxHeight: nil, quality: 0.9)
        #endif
    }

    #if os(macOS)
    /// The mean brightness of a JPEG, 0 to 255.
    static func brightness(_ jpeg: Data) throws -> Double {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(max(1, pixels.count))
    }
    #endif
}

/// The whole way, with the codecs this platform really has: a real still, the entry in the log, the thumbnail the page would be sent.
@Suite(.timeLimit(.minutes(2))) struct SkyThumbnailRealCodecsTests {
    @MainActor @Test func aRealPictureGetsItsCloseUpAndItsWholeSmallPicture() async throws {
        guard let codecs = RealPictures.codecs() else { return }   // no codecs here (no ffmpeg): nothing to try
        let still = try RealPictures.still(width: 1920, height: 852)
        let size = try #require(JPEGHeader.size(of: still), "the real encoder’s header can be read")
        #expect(size == SkyPictureSize(width: 1920, height: 852))
        let rig = try await SkyThumbnailEngineTests.Rig(codecs: codecs)
        let left: [(Double, Double)] = [(0.15, 0.4), (0.18, 0.42), (0.2, 0.45)], right: [(Double, Double)] = [(0.75, 0.4), (0.78, 0.42), (0.8, 0.45)]
        await rig.file("r-1", path: left, still: still)
        await rig.file("r-2", path: right, still: still)
        await rig.file("r-3", path: SkyThumbnailEngineTests.across, still: still)

        let first = try await rig.thumbnail("r-1")
        let second = try await rig.thumbnail("r-2")
        #expect(first.isThumbnail && second.isThumbnail)
        for (picture, path) in [(first, left), (second, right)] {
            let crop = try #require(SkyCloseUp.pixels(path: SkyCloseUpTests.points(path), width: 1920, height: 852))
            let made = try #require(JPEGHeader.size(of: picture.jpeg))
            let wide = min(SkyThumbnails.width, crop.width)
            #expect(made.width == wide && abs(made.height - Int((Double(crop.height) * Double(wide) / Double(crop.width)).rounded())) <= 1,
                    "the close-up \(crop), at most \(SkyThumbnails.width) wide: made \(made)")
            #expect(picture.jpeg.count < 40_000, "a small picture: \(picture.jpeg.count) bytes")
        }
        #if os(macOS)
        let darker = try RealPictures.brightness(first.jpeg), brighter = try RealPictures.brightness(second.jpeg)
        #expect(brighter - darker > 100, "the picture brightens to the right: the close-up of a light on the right is brighter (\(darker), \(brighter))")
        #endif

        let whole = try await rig.thumbnail("r-3")
        let wholeSize = try #require(JPEGHeader.size(of: whole.jpeg))
        #expect(whole.isThumbnail && wholeSize.width == 480 && abs(wholeSize.height - 213) <= 1, "all of the picture, small: \(wholeSize)")

        // Kept: the second time the same bytes come from the file.
        let again = try await rig.thumbnail("r-1")
        #expect(again.jpeg == first.jpeg && again.isThumbnail)
        let file = SkyLogStore.thumbnailFile(folder: rig.recordings.url, camera: rig.cameraID, night: SkyThumbnailEngineTests.night, id: "r-1")
        #expect(try Data(contentsOf: file) == first.jpeg && SkyLogStoreTests.mode(file) == 0o600)
    }
}
