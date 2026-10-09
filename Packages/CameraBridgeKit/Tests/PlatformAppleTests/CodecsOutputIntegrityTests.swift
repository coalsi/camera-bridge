#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import Testing
import VideoToolbox
@testable import PlatformApple

/// What the live view's encoder hands the controller (audit 2 section C, R1, F9): a letterboxed picture has black bars
/// whatever the pooled buffer held before, the stream is tagged BT.709, and the first keyframe is not starved of bits.
enum PictureProbe {
    static func luma(_ buffer: CVPixelBuffer, x: Int, y: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        return Int(base[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x])
    }

    /// (Cb, Cr) of the chroma sample covering luma position (x, y).
    static func chroma(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (cb: Int, cr: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) else { return (-1, -1) }
        let offset = (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + (x / 2) * 2
        return (Int(base[offset]), Int(base[offset + 1]))
    }

    /// Fills both planes with `luma` / `chroma`.
    static func fill(_ buffer: CVPixelBuffer, luma: UInt8, chroma: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            memset(base, Int32(plane == 0 ? luma : chroma), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
    }

    /// A pool of NV12 video-range buffers like an encoder session's.
    static func pool(width: Int, height: Int) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferWidthKey: width,
                                           kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary]
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey: 1] as CFDictionary
        CVPixelBufferPoolCreate(nil, poolAttributes, attributes as CFDictionary, &pool)
        return pool
    }

    /// A 2.25:1 test picture of `width`×`height` filled with bright content (so black bars are not the source's own).
    static func brightPicture(width: Int, height: Int) throws -> PixelBufferFrame {
        let frame = try TestPattern(width: width, height: height).makeFrame(index: 7, pts: MediaTime(value: 0, timescale: 90_000))
        fill(frame.pixelBuffer, luma: 180, chroma: 128)
        return frame
    }
}

@Suite(.timeLimit(.minutes(2))) struct CodecsLetterboxTests {
    /// 2.25:1 source into a 16:9 frame: bars (top and bottom) must be video-range black (Y 16, Cb = Cr = 128) over a fresh
    /// buffer and over 100 recycled ones, each of which held a bright, coloured picture before.
    @Test func letterboxBarsAreBlackOverFreshAndRecycledBuffers() throws {
        let source = try PictureProbe.brightPicture(width: 1800, height: 800)   // 2.25:1
        let pool = try #require(PictureProbe.pool(width: 1280, height: 720))
        let scaler = try PixelScaler()
        // Picture height at 1280 wide: 1280 / 2.25 = 568.9 → bars of about 75 rows top and bottom.
        for round in 0..<101 {
            let output = try scaler.scale(source.pixelBuffer, width: 1280, height: 720, pool: pool)
            for y in [4, 20, 60, 660, 700, 715] {
                for x in [0, 300, 640, 1279] {
                    #expect(abs(PictureProbe.luma(output, x: x, y: y) - 16) <= 2, "round \(round): bar luma at (\(x), \(y))")
                    let chroma = PictureProbe.chroma(output, x: x, y: y)
                    #expect(abs(chroma.cb - 128) <= 2 && abs(chroma.cr - 128) <= 2, "round \(round): bar chroma at (\(x), \(y)) = \(chroma)")
                }
            }
            #expect(PictureProbe.luma(output, x: 640, y: 360) > 100, "the picture itself is in the middle")
            PictureProbe.fill(output, luma: 235, chroma: 90)   // dirty it before it returns to the pool
        }
    }

    @Test func pillarBarsAreBlackToo() throws {
        let source = try PictureProbe.brightPicture(width: 640, height: 640)   // 1:1 into 16:9: bars left and right
        let pool = try #require(PictureProbe.pool(width: 1280, height: 720))
        let scaler = try PixelScaler()
        for round in 0..<20 {
            let output = try scaler.scale(source.pixelBuffer, width: 1280, height: 720, pool: pool)
            for x in [2, 100, 1180, 1277] {
                #expect(abs(PictureProbe.luma(output, x: x, y: 360) - 16) <= 2, "round \(round): bar luma at x \(x)")
            }
            #expect(PictureProbe.luma(output, x: 640, y: 360) > 100)
            PictureProbe.fill(output, luma: 235, chroma: 90)
        }
    }

    @Test func aSameAspectPictureIsNotPaintedOver() throws {
        let source = try PictureProbe.brightPicture(width: 1920, height: 1080)
        let pool = try #require(PictureProbe.pool(width: 1280, height: 720))
        let output = try PixelScaler().scale(source.pixelBuffer, width: 1280, height: 720, pool: pool)
        #expect(PictureProbe.luma(output, x: 2, y: 2) > 100 && PictureProbe.luma(output, x: 1277, y: 717) > 100)
    }
}
#endif
