#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import MediaCore
import Testing
@testable import PlatformApple

/// The Sky Watcher's small pictures on the Mac (`MediaCodecs.croppedJPEG`, the daemon's codecs there): the part of a picture inside a rectangle,
/// scaled down to a limit, never up, as a JPEG. The Linux ones (ffmpeg) are tested in `CroppedPictureTests`.
@Suite(.timeLimit(.minutes(1))) struct CroppedPictureAppleTests {
    let codecs = CodecFixtures.codecs

    /// A JPEG of `width` × `height` that gets brighter from the left (black) to the right (white).
    static func gradient(width: Int = 640, height: Int = 360) throws -> Data {
        let space = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = UInt8(x * 255 / max(1, width - 1)) } }
        let image = try pixels.withUnsafeMutableBytes { bytes -> CGImage in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.none.rawValue))
            return try #require(context.makeImage())
        }
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

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

    @Test func thePartComesOutAtItsOwnSizeOrScaledDownAndShowsThatPartOfThePicture() throws {
        let original = try Self.gradient()
        let left = try codecs.croppedJPEG(original, crop: ImageCrop(x: 40, y: 100, width: 200, height: 113), maxWidth: 480, quality: 0.8)
        let right = try codecs.croppedJPEG(original, crop: ImageCrop(x: 400, y: 100, width: 200, height: 113), maxWidth: 480, quality: 0.8)
        for jpeg in [left, right] {
            #expect(jpeg.starts(with: [0xFF, 0xD8]))
            let size = try #require(CodecFixtures.decodedImageSize(jpeg))
            #expect(size.width == 200 && size.height == 113, "the part's own size, not scaled up: \(size)")
        }
        // 40…240 of 640 is about 22 % grey, 400…600 about 78 %: the right part is brighter by about 140 levels.
        let difference = try Self.brightness(right) - Self.brightness(left)
        #expect(difference > 100 && difference < 180, "\(difference)")

        // A part wider than the limit is scaled down to it, its shape kept.
        let wide = try codecs.croppedJPEG(original, crop: ImageCrop(x: 0, y: 0, width: 640, height: 360), maxWidth: 160, quality: 0.8)
        let size = try #require(CodecFixtures.decodedImageSize(wide))
        #expect(size.width == 160 && size.height == 90, "\(size)")
    }

    @Test func aPartIsCutWhereItWasAskedAtAnOddPlaceToo() throws {
        let original = try Self.gradient()
        let odd = try codecs.croppedJPEG(original, crop: ImageCrop(x: 301, y: 121, width: 201, height: 113), maxWidth: 480, quality: 0.9)
        let even = try codecs.croppedJPEG(original, crop: ImageCrop(x: 300, y: 120, width: 200, height: 112), maxWidth: 480, quality: 0.9)
        let size = try #require(CodecFixtures.decodedImageSize(odd))
        #expect(size.width == 201 && size.height == 113, "\(size)")
        #expect(abs(try Self.brightness(odd) - Self.brightness(even)) < 4)
    }

    @Test func theWholePictureIsMadeSmallerAndOneThatFitsComesBackAsItWas() throws {
        let original = try Self.gradient()
        let small = try codecs.croppedJPEG(original, crop: nil, maxWidth: 320, quality: 0.8)
        let size = try #require(CodecFixtures.decodedImageSize(small))
        #expect(size.width == 320 && size.height == 180, "\(size)")
        #expect(try codecs.croppedJPEG(original, crop: nil, maxWidth: 640, quality: 0.8) == original)
        #expect(try codecs.croppedJPEG(original, crop: nil, maxWidth: 4_000, quality: 0.8) == original)
    }

    @Test func theQualityChangesTheSize() throws {
        let picture = try #require(try CodecFixtures.pictures(width: 1280, height: 720, count: 1).first)
        let original = try codecs.jpeg(from: picture, maxWidth: nil, maxHeight: nil, quality: 0.95)
        let part = ImageCrop(x: 0, y: 0, width: 1280, height: 720)
        let low = try codecs.croppedJPEG(original, crop: part, maxWidth: 640, quality: 0.1)
        let high = try codecs.croppedJPEG(original, crop: part, maxWidth: 640, quality: 0.95)
        #expect(low.count < high.count, "\(low.count) bytes at 0.1, \(high.count) at 0.95")
    }

    @Test func aCropOutsideThePictureOrDataThatIsNoImageIsRefused() throws {
        let original = try Self.gradient()
        for crop in [ImageCrop(x: 600, y: 0, width: 100, height: 100), ImageCrop(x: 0, y: 300, width: 100, height: 100), ImageCrop(x: -1, y: 0, width: 100, height: 100),
                     ImageCrop(x: 0, y: 0, width: 0, height: 100), ImageCrop(x: 0, y: 0, width: 100, height: 0), ImageCrop(x: 0, y: 0, width: 641, height: 360)] {
            #expect(throws: MediaCodecError.self, "\(crop)") { _ = try codecs.croppedJPEG(original, crop: crop, maxWidth: 480, quality: 0.8) }
        }
        #expect(throws: MediaCodecError.self) { _ = try codecs.croppedJPEG(Data("not a jpeg".utf8), crop: nil, maxWidth: 480, quality: 0.8) }
        #expect(throws: MediaCodecError.self) { _ = try codecs.croppedJPEG(Data(), crop: ImageCrop(x: 0, y: 0, width: 10, height: 10), maxWidth: 480, quality: 0.8) }
    }
}
#endif
