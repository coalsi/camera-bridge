#if os(macOS)
import Accelerate
import CoreVideo
import Foundation
import MediaCore

/// A decoded picture backed by a CVPixelBuffer (VideoToolbox output). CVPixelBuffer is immutable once decoded and
/// safe to share across threads, hence `@unchecked Sendable`.
public struct PixelBufferFrame: DecodedVideoFrame, @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let pts: MediaTime

    public init(pixelBuffer: CVPixelBuffer, pts: MediaTime) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
    }

    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }

    /// Luma, area-averaged down to `min(maxWidth, width)` columns keeping the aspect ratio (height rounded, ≥ 1): each
    /// output pixel is the rounded mean of every source pixel in its block, so the thumbnail carries no aliasing from
    /// sparse sampling into motion detection. Reads the luma plane of 8-bit (420v/420f, planar 420, OneComponent8;
    /// summed with Accelerate/vDSP) and 10-bit biplanar buffers, or derives BT.601 video-range luma from 32BGRA/32ARGB.
    /// Returns nil for `maxWidth ≤ 0` or other pixel formats.
    public func grayThumbnail(maxWidth: Int) -> GrayImage? {
        let sourceWidth = width
        let sourceHeight = height
        guard maxWidth > 0, sourceWidth > 0, sourceHeight > 0 else { return nil }
        let outWidth = min(maxWidth, sourceWidth)
        let outHeight = max(1, Int((Double(sourceHeight) * Double(outWidth) / Double(sourceWidth)).rounded()))
        guard let reader = LumaReader(pixelBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = reader.baseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = reader.bytesPerRow(pixelBuffer)

        let columns = Self.blockBounds(count: outWidth, source: sourceWidth)
        let rows = Self.blockBounds(count: outHeight, source: sourceHeight)
        var pixels = [UInt8](repeating: 0, count: outWidth * outHeight)
        if reader.layout == .planar8 {
            Self.averagePlanar8(base: base, bytesPerRow: bytesPerRow, width: sourceWidth, rows: rows, columns: columns, into: &pixels)
            return GrayImage(width: outWidth, height: outHeight, pixels: pixels)
        }
        var sums = [Int](repeating: 0, count: outWidth)
        pixels.withUnsafeMutableBufferPointer { output in
            sums.withUnsafeMutableBufferPointer { sums in
                for (oy, row) in rows.enumerated() {
                    for index in sums.indices { sums[index] = 0 }
                    for y in row {
                        reader.addRow(base + y * bytesPerRow, columns: columns, into: sums)
                    }
                    for (ox, column) in columns.enumerated() {
                        let count = row.count * column.count
                        output[oy * outWidth + ox] = UInt8(clamping: (sums[ox] + count / 2) / count)
                    }
                }
            }
        }
        return GrayImage(width: outWidth, height: outHeight, pixels: pixels)
    }

    /// Luma mean and deviation and the chroma means on a grid of 64 columns (and as many rows as the aspect gives) of the
    /// centres of equal cells: a few thousand reads, so one per second costs nothing. 8-bit biplanar 4:2:0 only (what the
    /// decoder and the encoder's pool buffers are); nil for any other format.
    public func pictureStatistics() -> PictureStatistics? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              width >= 2, height >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let columns = min(64, width / 2)
        let rows = max(1, min(64, columns * height / width))
        var lumaSum = 0.0, lumaSquares = 0.0, cbSum = 0.0, crSum = 0.0
        for row in 0..<rows {
            let y = min(height - 1, (2 * row + 1) * height / (2 * rows))
            for column in 0..<columns {
                let x = min(width - 1, (2 * column + 1) * width / (2 * columns))
                let luma = Double(lumaBase[y * lumaStride + x])
                lumaSum += luma
                lumaSquares += luma * luma
                let chroma = (y / 2) * chromaStride + (x / 2) * 2
                cbSum += Double(chromaBase[chroma])
                crSum += Double(chromaBase[chroma + 1])
            }
        }
        let count = Double(rows * columns)
        let mean = lumaSum / count
        return PictureStatistics(meanLuma: mean, lumaDeviation: max(0, lumaSquares / count - mean * mean).squareRoot(), meanCb: cbSum / count,
                                 meanCr: crSum / count)
    }

    /// Block means of an 8-bit plane: the rows of each output row are summed into a Double accumulator (exact integer
    /// sums), then each column block of it is summed and divided (rounded half up).
    private static func averagePlanar8(base: UnsafePointer<UInt8>, bytesPerRow: Int, width: Int, rows: [Range<Int>], columns: [Range<Int>],
                                       into pixels: inout [UInt8]) {
        let length = vDSP_Length(width)
        var accumulator = [Double](repeating: 0, count: width)
        var converted = [Double](repeating: 0, count: width)
        pixels.withUnsafeMutableBufferPointer { output in
            accumulator.withUnsafeMutableBufferPointer { accumulator in
                converted.withUnsafeMutableBufferPointer { converted in
                    guard let sums = accumulator.baseAddress, let row = converted.baseAddress else { return }
                    for (oy, block) in rows.enumerated() {
                        vDSP_vclrD(sums, 1, length)
                        for y in block {
                            vDSP_vfltu8D(base + y * bytesPerRow, 1, row, 1, length)
                            vDSP_vaddD(sums, 1, row, 1, sums, 1, length)
                        }
                        for (ox, column) in columns.enumerated() {
                            var sum = 0.0
                            vDSP_sveD(sums + column.lowerBound, 1, &sum, vDSP_Length(column.count))
                            let mean = (sum / Double(block.count * column.count)).rounded()
                            output[oy * columns.count + ox] = UInt8(clamping: Int(mean))
                        }
                    }
                }
            }
        }
    }

    /// Source index ranges [i·source/count, (i+1)·source/count), each at least one pixel wide.
    private static func blockBounds(count: Int, source: Int) -> [Range<Int>] {
        (0..<count).map { index in
            let lower = min(index * source / count, source - 1)
            let upper = max(lower + 1, min((index + 1) * source / count, source))
            return lower..<upper
        }
    }
}

/// How to read one luma value per pixel for the supported pixel formats.
private struct LumaReader {
    enum Layout { case planar8, planar16, bgra, argb }

    let layout: Layout
    let plane: Int?

    init?(_ pixelBuffer: CVPixelBuffer) {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8Planar, kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            (layout, plane) = (.planar8, 0)
        case kCVPixelFormatType_OneComponent8:
            (layout, plane) = (.planar8, nil)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            (layout, plane) = (.planar16, 0)
        case kCVPixelFormatType_32BGRA:
            (layout, plane) = (.bgra, nil)
        case kCVPixelFormatType_32ARGB:
            (layout, plane) = (.argb, nil)
        default:
            return nil
        }
    }

    func baseAddress(_ pixelBuffer: CVPixelBuffer) -> UnsafePointer<UInt8>? {
        let raw = plane.map { CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, $0) } ?? CVPixelBufferGetBaseAddress(pixelBuffer)
        return raw.map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) }
    }

    func bytesPerRow(_ pixelBuffer: CVPixelBuffer) -> Int {
        plane.map { CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, $0) } ?? CVPixelBufferGetBytesPerRow(pixelBuffer)
    }

    /// Adds each column block's luma over one source row to `sums` (the formats vDSP does not sum directly).
    func addRow(_ line: UnsafePointer<UInt8>, columns: [Range<Int>], into sums: UnsafeMutableBufferPointer<Int>) {
        for (index, column) in columns.enumerated() {
            var sum = 0
            for x in column { sum &+= luma(line, x) }
            sums[index] &+= sum
        }
    }

    @inline(__always) func luma(_ line: UnsafePointer<UInt8>, _ x: Int) -> Int {
        switch layout {
        case .planar8:
            return Int(line[x])
        case .planar16:
            return Int(line[2 * x + 1])   // little-endian 16-bit sample, value in the high bits
        case .bgra:
            return Self.bt601(red: Int(line[4 * x + 2]), green: Int(line[4 * x + 1]), blue: Int(line[4 * x]))
        case .argb:
            return Self.bt601(red: Int(line[4 * x + 1]), green: Int(line[4 * x + 2]), blue: Int(line[4 * x + 3]))
        }
    }

    /// BT.601 video-range luma (16…235) from full-range RGB, so RGB and YCbCr sources compare alike.
    @inline(__always) static func bt601(red: Int, green: Int, blue: Int) -> Int {
        16 + (66 * red + 129 * green + 25 * blue + 128) >> 8
    }
}
#endif
