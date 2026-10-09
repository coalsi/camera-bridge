#if os(macOS)
import CoreVideo
import Foundation
import MediaCore

/// The synthetic camera picture (demo camera, tests): scrolling 75 % colour bars, a bouncing white box, a patch of
/// per-frame noise (so the encoder has real work and bitrates look like a camera's) and a six-digit frame counter.
/// Renders into IOSurface-backed NV12 (`420v`) buffers row by row, cheap enough for real time in debug builds.
/// Not thread-safe; use one instance per producer.
final class TestPattern {
    let width: Int
    let height: Int
    private let pool: CVPixelBufferPool?
    /// Two periods of the bar pattern, so any scroll offset is one contiguous copy per row.
    private let lumaBars: [UInt8]
    private let chromaBars: [UInt8]

    /// BT.601 video-range (Y, Cb, Cr) of 75 % bars: white, yellow, cyan, green, magenta, red, blue, black.
    private static let bars: [(UInt8, UInt8, UInt8)] = [
        (180, 128, 128), (162, 44, 142), (131, 156, 44), (112, 72, 58), (84, 184, 198), (65, 100, 212), (35, 212, 114), (16, 128, 128),
    ]

    /// 5×7 digit glyphs, one row per byte (bit 4 = leftmost column).
    private static let glyphs: [[UInt8]] = [
        [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E], [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
        [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F], [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
        [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02], [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
        [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E], [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E], [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
    ]
    private static let digitCount = 6

    init(width: Int, height: Int) {
        self.width = max(2, width & ~1)
        self.height = max(2, height & ~1)
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: self.width,
            kCVPixelBufferHeightKey: self.height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        self.pool = pool

        var luma = [UInt8](repeating: 0, count: 2 * self.width)
        var chroma = [UInt8](repeating: 0, count: 2 * self.width)   // 2 periods × width/2 pairs × 2 bytes
        for x in 0..<self.width {
            let (y, cb, cr) = Self.bars[x * Self.bars.count / self.width]
            luma[x] = y
            luma[x + self.width] = y
            if x % 2 == 0 {
                chroma[x] = cb
                chroma[x + 1] = cr
                chroma[x + self.width] = cb
                chroma[x + self.width + 1] = cr
            }
        }
        lumaBars = luma
        chromaBars = chroma
    }

    /// Where the frame counter is drawn (tests).
    static func counterRect(width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let scale = max(1, (height & ~1) / 120)
        return (x: max(2, (width & ~1) / 32) & ~1, y: max(2, (height & ~1) / 24) & ~1, width: (digitCount * 6 + 1) * scale, height: 9 * scale)
    }

    func makeFrame(index: Int, pts: MediaTime) throws -> PixelBufferFrame {
        var buffer: CVPixelBuffer?
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        }
        guard status == kCVReturnSuccess, let buffer else { throw MediaCodecError.sessionFailed(status) }
        render(index: index, into: buffer)
        return PixelBufferFrame(pixelBuffer: buffer, pts: pts)
    }

    func render(index: Int, into buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) else { return }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let luma = Plane(base: lumaBase, stride: lumaStride)
        let chroma = Plane(base: chromaBase, stride: chromaStride)

        // Bars scrolling left by 4 px per frame.
        let offset = (index &* 4) % width & ~1
        lumaBars.withUnsafeBufferPointer { bars in
            guard let source = bars.baseAddress else { return }
            for y in 0..<height { (lumaBase + y * lumaStride).update(from: source + offset, count: width) }
        }
        chromaBars.withUnsafeBufferPointer { bars in
            guard let source = bars.baseAddress else { return }
            for y in 0..<(height / 2) { (chromaBase + y * chromaStride).update(from: source + offset, count: width) }
        }

        // Bouncing box (triangle waves with different periods on each axis).
        let box = max(2, height / 5) & ~1
        let x = Self.bounce(index * 6, range: width - box) & ~1
        let y = Self.bounce(index * 4, range: height - box) & ~1
        fill(luma: luma, chroma: chroma, x: x, y: y, width: box, height: box, value: 235)

        // Noise patch in the bottom-right corner, new every frame.
        let noiseWidth = max(2, width / 5) & ~1
        let noiseHeight = max(2, height / 5) & ~1
        var seed = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15 | 1
        for row in (height - noiseHeight)..<height {
            let line = lumaBase + row * lumaStride
            var column = width - noiseWidth
            while column < width {
                seed ^= seed << 13
                seed ^= seed >> 7
                seed ^= seed << 17
                for byte in 0..<min(8, width - column) { line[column + byte] = 16 + UInt8(truncatingIfNeeded: seed >> (8 * byte)) % 220 }
                column += 8
            }
        }

        // Frame counter: white digits on a black label.
        let label = Self.counterRect(width: width, height: height)
        let scale = max(1, height / 120)
        fill(luma: luma, chroma: chroma, x: label.x, y: label.y, width: min(label.width, width - label.x), height: min(label.height, height - label.y), value: 16)
        var digits = String(index % 1_000_000)
        digits = String(repeating: "0", count: Self.digitCount - digits.count) + digits
        for (position, character) in digits.enumerated() {
            guard let digit = character.wholeNumberValue else { continue }
            for (row, bits) in Self.glyphs[digit].enumerated() {
                for column in 0..<5 where bits & (0x10 >> column) != 0 {
                    let px = label.x + (1 + position * 6 + column) * scale
                    let py = label.y + (1 + row) * scale
                    guard px + scale <= width, py + scale <= height else { continue }
                    for dy in 0..<scale { (lumaBase + (py + dy) * lumaStride + px).update(repeating: 235, count: scale) }
                }
            }
        }
    }

    private struct Plane {
        let base: UnsafeMutablePointer<UInt8>
        let stride: Int
    }

    /// Fills a rectangle with a neutral-chroma luma value (x, y, width, height even).
    private func fill(luma: Plane, chroma: Plane, x: Int, y: Int, width w: Int, height h: Int, value: UInt8) {
        guard w > 0, h > 0 else { return }
        for row in y..<min(y + h, height) { (luma.base + row * luma.stride + x).update(repeating: value, count: min(w, width - x)) }
        for row in (y / 2)..<min((y + h) / 2, height / 2) { (chroma.base + row * chroma.stride + x).update(repeating: 128, count: min(w, width - x)) }
    }

    private static func bounce(_ position: Int, range: Int) -> Int {
        guard range > 0 else { return 0 }
        let period = 2 * range
        let phase = position % period
        return phase <= range ? phase : period - phase
    }
}
#endif
