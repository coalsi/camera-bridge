#if os(macOS)
import Accelerate
import CoreVideo
import Foundation
import MediaCore

/// Draws the timestamp overlay into NV12 pictures (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`, what the encoder
/// takes). The overlay bitmap is rendered once per distinct text (once a second, or a minute without seconds) and per
/// output size; each picture then only costs a blend of the pill's few thousand pixels: the picture behind the pill is
/// blurred (luma, a frosted look and fewer bits for the encoder), then the translucent pill, the text and its shadow are
/// blended over it. Not thread-safe (the encoder calls it under its lock).
final class TimestampOverlayCompositor {
    private struct Key: Equatable {
        var width: Int
        var height: Int
        var position: OverlayPosition
        var size: OverlaySize
        var text: TimestampOverlayText
    }

    private var cached: (key: Key, bitmap: OverlayBitmap?)?
    /// The blurred region, and the box blur's intermediate pass.
    private var blurred: [UInt8] = []
    private var intermediate: [UInt8] = []
    private(set) var renderCount = 0

    /// The bitmap for these inputs, rendered when they differ from the last call's; nil when the picture is too small.
    func bitmap(for text: TimestampOverlayText, settings: TimestampOverlaySettings, width: Int, height: Int) -> OverlayBitmap? {
        let key = Key(width: width, height: height, position: settings.position, size: settings.size, text: text)
        if let cached, cached.key == key { return cached.bitmap }
        let bitmap = TimestampOverlayRenderer.render(text, width: width, height: height, position: settings.position, size: settings.size)
        renderCount += 1
        cached = (key, bitmap)
        return bitmap
    }

    /// Blends the overlay for `text` into `pixelBuffer` in place. The buffer must be the caller's own (a decoder's output
    /// is shared with the decoder's reference frames). Returns false for a picture that is not 8-bit NV12 video range or
    /// is too small; the picture is then left as it is.
    @discardableResult
    func apply(_ text: TimestampOverlayText, settings: TimestampOverlaySettings, to pixelBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard let bitmap = bitmap(for: text, settings: settings, width: width, height: height) else { return false }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0), let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return false }
        blendLuma(bitmap, into: luma.assumingMemoryBound(to: UInt8.self), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
        blendChroma(bitmap, into: chroma.assumingMemoryBound(to: UInt8.self), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))
        return true
    }

    // MARK: Blending

    private func blendLuma(_ bitmap: OverlayBitmap, into plane: UnsafeMutablePointer<UInt8>, rowBytes: Int) {
        let width = bitmap.width, height = bitmap.height
        let region = plane + bitmap.originY * rowBytes + bitmap.originX
        if bitmap.blurKernel > 1, blur(region, rowBytes: rowBytes, width: width, height: height, kernel: bitmap.blurKernel) {
            // `blurred` holds the blurred region: mix it in where the pill is.
            blurred.withUnsafeBufferPointer { blurred in
                bitmap.pillCoverage.withUnsafeBufferPointer { coverage in
                    for y in 0..<height {
                        let row = region + y * rowBytes
                        for x in 0..<width {
                            let m = Int(coverage[y * width + x])
                            guard m > 0 else { continue }
                            let original = Int(row[x]), soft = Int(blurred[y * width + x])
                            row[x] = UInt8(original + ((soft - original) * m + (soft >= original ? 127 : -127)) / 255)
                        }
                    }
                }
            }
        }
        bitmap.alpha.withUnsafeBufferPointer { alpha in
            bitmap.lumaPremultiplied.withUnsafeBufferPointer { premultiplied in
                for y in 0..<height {
                    let row = region + y * rowBytes
                    for x in 0..<width {
                        let a = Int(alpha[y * width + x])
                        guard a > 0 else { continue }
                        row[x] = UInt8(min(255, Self.scale(Int(row[x]), by: 255 - a) + Int(premultiplied[y * width + x])))
                    }
                }
            }
        }
    }

    /// The overlay is neutral gray: the picture's chroma moves towards 128 by the overlay's alpha.
    private func blendChroma(_ bitmap: OverlayBitmap, into plane: UnsafeMutablePointer<UInt8>, rowBytes: Int) {
        let width = bitmap.width / 2, height = bitmap.height / 2
        let region = plane + (bitmap.originY / 2) * rowBytes + bitmap.originX
        bitmap.chromaAlpha.withUnsafeBufferPointer { alpha in
            for y in 0..<height {
                let row = region + y * rowBytes
                for x in 0..<width {
                    let a = Int(alpha[y * width + x])
                    guard a > 0 else { continue }
                    let rest = 255 - a
                    row[2 * x] = UInt8(min(255, Self.scale(Int(row[2 * x]), by: rest) + Self.scale(128, by: a)))
                    row[2 * x + 1] = UInt8(min(255, Self.scale(Int(row[2 * x + 1]), by: rest) + Self.scale(128, by: a)))
                }
            }
        }
    }

    /// `value × factor / 255`, rounded.
    @inline(__always) private static func scale(_ value: Int, by factor: Int) -> Int {
        let product = value * factor + 128
        return (product + (product >> 8)) >> 8
    }

    /// Blurs the luma region into `blurred` (two box passes, about a Gaussian) with Accelerate; false if vImage refuses.
    private func blur(_ region: UnsafeMutablePointer<UInt8>, rowBytes: Int, width: Int, height: Int, kernel: Int) -> Bool {
        let count = width * height
        if blurred.count != count { blurred = [UInt8](repeating: 0, count: count) }
        if intermediate.count != count { intermediate = [UInt8](repeating: 0, count: count) }
        var failed = false
        blurred.withUnsafeMutableBytes { first in
            intermediate.withUnsafeMutableBytes { second in
                var source = vImage_Buffer(data: region, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
                var middle = vImage_Buffer(data: second.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var output = vImage_Buffer(data: first.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                let size = UInt32(kernel)
                let flags = vImage_Flags(kvImageEdgeExtend)
                failed = vImageBoxConvolve_Planar8(&source, &middle, nil, 0, 0, size, size, 0, flags) != kvImageNoError
                    || vImageBoxConvolve_Planar8(&middle, &output, nil, 0, 0, size, size, 0, flags) != kvImageNoError
            }
        }
        return !failed
    }
}
#endif
