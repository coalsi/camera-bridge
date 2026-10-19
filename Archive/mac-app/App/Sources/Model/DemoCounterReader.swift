#if DEBUG
import CoreImage
import CoreVideo
import Foundation

/// Debug builds only: reads the six-digit frame counter that the engine's demo camera draws into every picture
/// (`PlatformApple/Codecs/TestPattern.swift`: white 5x7 glyphs, scale `height / 120`, on a black label whose corner is at
/// `(width / 32, height / 24)`, both rounded down to even). `NVRProbe` uses it to learn which recorded frame the display layer shows,
/// so a scrub can be checked to the frame and timed to the picture rather than to the hand-over. The glyphs below mirror
/// `TestPattern.glyphs`; `DemoCounterReaderTests` renders a picture by the same rule and reads it back.
nonisolated enum DemoCounterReader {
    static let digitCount = 6
    /// 5x7 digit glyphs, one row per byte (bit 4 = leftmost column): the same table as `TestPattern`.
    static let glyphs: [[UInt8]] = [
        [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E], [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
        [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F], [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
        [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02], [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
        [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E], [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E], [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
    ]
    /// The midpoint between the label (luma 16) and a lit pixel (luma 235).
    static let threshold: UInt8 = 126

    /// Where the label starts and how large one glyph pixel is, for a picture of `width` x `height`.
    static func geometry(width: Int, height: Int) -> (x: Int, y: Int, scale: Int) {
        let evenWidth = width & ~1, evenHeight = height & ~1
        return (x: max(2, evenWidth / 32) & ~1, y: max(2, evenHeight / 24) & ~1, scale: max(1, evenHeight / 120))
    }

    /// The counter, or nil when a digit cell matches no glyph (a transition, a blank layer, another picture). `luma(x, y)` is 0...255.
    static func read(width: Int, height: Int, luma: (Int, Int) -> UInt8) -> Int? {
        let label = geometry(width: width, height: height)
        guard label.x + (1 + digitCount * 6) * label.scale <= width, label.y + 9 * label.scale <= height else { return nil }
        var value = 0
        for position in 0..<digitCount {
            var rows = [UInt8](repeating: 0, count: 7)
            for row in 0..<7 {
                for column in 0..<5 {
                    let x = label.x + (1 + position * 6 + column) * label.scale + label.scale / 2
                    let y = label.y + (1 + row) * label.scale + label.scale / 2
                    if luma(x, y) >= threshold { rows[row] |= 0x10 >> UInt8(column) }
                }
            }
            guard let digit = glyphs.firstIndex(of: rows) else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    /// The counter in a decoded picture. Bi-planar 4:2:0 (luma plane 0) and 32-bit BGRA are read directly; anything else (the display layer hands back its
    /// picture in a lossless compressed format, '&8v0', that cannot be read through the base address) goes through CoreImage, which renders only the label.
    /// `viaCoreImage` forces that path (the test compares it with the direct one).
    static func read(pixelBuffer: CVPixelBuffer, viaCoreImage: Bool = false) -> Int? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let direct = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA].contains(format)
        if viaCoreImage || !direct { return readViaCoreImage(pixelBuffer) }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            return read(width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)) { bytes[$1 * stride + $0] }
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            return read(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)) { bytes[$1 * stride + $0 * 4 + 1] }
        default:
            return nil
        }
    }

    /// CoreImage reads any format a picture can be in; only the rectangle of the label is converted (to RGBA, row 0 on top), so a poll costs little.
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func readViaCoreImage(_ pixelBuffer: CVPixelBuffer) -> Int? {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let label = geometry(width: width, height: height)
        let cropWidth = (1 + digitCount * 6) * label.scale, cropHeight = 9 * label.scale
        guard label.x + cropWidth <= width, label.y + cropHeight <= height else { return nil }
        // CoreImage's origin is the bottom left; the label's is measured from the top.
        let rect = CGRect(x: label.x, y: height - label.y - cropHeight, width: cropWidth, height: cropHeight)
        let image = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        var bytes = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
        context.render(image, toBitmap: &bytes, rowBytes: cropWidth * 4, bounds: CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return read(width: width, height: height) { x, y in bytes[((y - label.y) * cropWidth + (x - label.x)) * 4 + 1] }
    }
}
#endif
