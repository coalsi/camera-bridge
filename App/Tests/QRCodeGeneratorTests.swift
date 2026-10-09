import CoreGraphics
import CoreImage
import Foundation
import Testing

@Suite struct QRCodeGeneratorTests {
    private let uri = "X-HM://0081YCYEP3QXO"

    @Test func encodesTheSetupURIReadablyByADetector() throws {
        let image = try #require(QRCodeGenerator.image(for: uri))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        #expect(features.map(\.messageString) == [uri])
    }

    @Test func isSquareAndScaledByWholeModules() throws {
        let one = try #require(QRCodeGenerator.image(for: uri, moduleScale: 1))
        let ten = try #require(QRCodeGenerator.image(for: uri, moduleScale: 10))
        #expect(one.width == one.height)
        #expect(ten.width == one.width * 10 && ten.height == one.height * 10)
    }

    /// Crisp scaling: nearest-neighbour sampling leaves only pure black and white pixels.
    @Test func scaledImageHasNoIntermediateGreys() throws {
        let image = try #require(QRCodeGenerator.image(for: uri, moduleScale: 7))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        #expect(Set(pixels).isSubset(of: [0, 255]))
        #expect(Set(pixels) == [0, 255])
    }

    /// ISO/IEC 18004 asks for a four-module white border; the generator itself draws only one.
    @Test func hasAFourModuleQuietZone() throws {
        let image = try #require(QRCodeGenerator.image(for: uri, moduleScale: 1))
        let pixels = try Self.grayPixels(image)
        let width = image.width, height = image.height
        func isDark(_ x: Int, _ y: Int) -> Bool { pixels[y * width + x] < 128 }
        let darkColumns = (0..<width).filter { x in (0..<height).contains { isDark(x, $0) } }
        let darkRows = (0..<height).filter { y in (0..<width).contains { isDark($0, y) } }
        let left = try #require(darkColumns.first), right = try #require(darkColumns.last)
        let top = try #require(darkRows.first), bottom = try #require(darkRows.last)
        #expect(left >= 4 && top >= 4)
        #expect(width - 1 - right >= 4 && height - 1 - bottom >= 4)
        #expect(left == width - 1 - right && top == height - 1 - bottom)   // centred
    }

    private static func grayPixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        return pixels
    }

    @Test func emptyMessageYieldsNoImage() {
        #expect(QRCodeGenerator.image(for: "") == nil)
    }
}
