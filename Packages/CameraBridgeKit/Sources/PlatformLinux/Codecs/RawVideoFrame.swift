import Foundation
import MediaCore

/// A decoded picture as planar YUV 4:2:0 (ffmpeg's `yuv420p`: Y, then Cb, then Cr; chroma planes `⌈w/2⌉ × ⌈h/2⌉`, limited
/// range as H.264 and HEVC decode). The Linux counterpart of `PlatformApple.PixelBufferFrame`.
public struct RawVideoFrame: DecodedVideoFrame, Sendable {
    public let width: Int
    public let height: Int
    public let pts: MediaTime
    /// `RawVideoFrame.byteCount(width:height:)` bytes.
    public let pixels: Data

    public init(width: Int, height: Int, pts: MediaTime, pixels: Data) {
        self.width = width
        self.height = height
        self.pts = pts
        self.pixels = pixels
    }

    public static func chromaSize(width: Int, height: Int) -> (width: Int, height: Int) { ((width + 1) / 2, (height + 1) / 2) }

    public static func byteCount(width: Int, height: Int) -> Int {
        let chroma = chromaSize(width: width, height: height)
        return width * height + 2 * chroma.width * chroma.height
    }

    /// Whether `pixels` holds exactly one picture of this size.
    var isComplete: Bool { width > 0 && height > 0 && pixels.count == Self.byteCount(width: width, height: height) }

    /// Luma area-averaged down to `min(maxWidth, width)` columns keeping the aspect ratio (height rounded, at least 1).
    public func grayThumbnail(maxWidth: Int) -> GrayImage? {
        guard maxWidth > 0, isComplete else { return nil }
        let outWidth = min(maxWidth, width)
        let outHeight = max(1, Int((Double(height) * Double(outWidth) / Double(width)).rounded()))
        let columns = Self.blockBounds(count: outWidth, source: width)
        let rows = Self.blockBounds(count: outHeight, source: height)
        var out = [UInt8](repeating: 0, count: outWidth * outHeight)
        pixels.withUnsafeBytes { raw in
            let luma = raw.bindMemory(to: UInt8.self)
            for (oy, row) in rows.enumerated() {
                for (ox, column) in columns.enumerated() {
                    var sum = 0
                    for y in row {
                        let base = y * width
                        for x in column { sum += Int(luma[base + x]) }
                    }
                    let count = row.count * column.count
                    out[oy * outWidth + ox] = UInt8(clamping: (sum + count / 2) / count)
                }
            }
        }
        return GrayImage(width: outWidth, height: outHeight, pixels: out)
    }

    /// Luma mean and deviation and the chroma means on a grid of up to 64 columns of cell centres.
    public func pictureStatistics() -> PictureStatistics? {
        guard width >= 2, height >= 2, isComplete else { return nil }
        let chroma = Self.chromaSize(width: width, height: height)
        let cbBase = width * height
        let crBase = cbBase + chroma.width * chroma.height
        let columns = min(64, width / 2)
        let rows = max(1, min(64, columns * height / width))
        var lumaSum = 0.0, lumaSquares = 0.0, cbSum = 0.0, crSum = 0.0
        pixels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for row in 0..<rows {
                let y = min(height - 1, (2 * row + 1) * height / (2 * rows))
                for column in 0..<columns {
                    let x = min(width - 1, (2 * column + 1) * width / (2 * columns))
                    let luma = Double(bytes[y * width + x])
                    lumaSum += luma
                    lumaSquares += luma * luma
                    let chromaIndex = (y / 2) * chroma.width + x / 2
                    cbSum += Double(bytes[cbBase + chromaIndex])
                    crSum += Double(bytes[crBase + chromaIndex])
                }
            }
        }
        let count = Double(rows * columns)
        let mean = lumaSum / count
        return PictureStatistics(meanLuma: mean, lumaDeviation: max(0, lumaSquares / count - mean * mean).squareRoot(), meanCb: cbSum / count,
                                 meanCr: crSum / count)
    }

    /// `count` consecutive ranges covering `0..<source`, as even as integers allow.
    private static func blockBounds(count: Int, source: Int) -> [Range<Int>] {
        (0..<count).map { index in
            let start = index * source / count
            let end = max(start + 1, (index + 1) * source / count)
            return start..<min(end, source)
        }
    }
}
