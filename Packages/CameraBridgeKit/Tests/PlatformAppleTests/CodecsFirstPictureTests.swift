#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import Testing
import VideoToolbox
@testable import PlatformApple

/// A detailed picture (gradient, waves and strong noise: a textured scene a starved encoder turns into blocks).
extension PictureProbe {
    static func detailedPicture(width: Int, height: Int, noise: Int = 40, seed: UInt64 = 77) -> PixelBufferFrame {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
        guard let buffer else { preconditionFailure("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var state = seed | 1
        for y in 0..<height {
            for x in 0..<width {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                let base = 40 + x * 150 / width + y * 40 / height + Int(sin(Double(x) / 37) * 20 + cos(Double(y) / 23) * 20)
                luma[y * stride + x] = UInt8(max(16, min(235, base + Int(state % UInt64(noise)) - noise / 2)))
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<(height / 2) { for x in 0..<width { chroma[y * chromaStride + x] = 128 + UInt8((x / 2) % 8) } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return PixelBufferFrame(pixelBuffer: buffer, pts: MediaTime(value: 0, timescale: 90_000))
    }

    /// Peak signal-to-noise ratio of two same-sized pictures' luma (dB).
    static func lumaPSNR(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        let width = CVPixelBufferGetWidth(a), height = CVPixelBufferGetHeight(a)
        guard width == CVPixelBufferGetWidth(b), height == CVPixelBufferGetHeight(b) else { return 0 }
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        let sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        var error = 0.0
        for y in 0..<height { for x in 0..<width { let d = Double(pa[y * sa + x]) - Double(pb[y * sb + x]); error += d * d } }
        let mse = error / Double(width * height)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
}

@Suite(.timeLimit(.minutes(2))) struct CodecsFirstPictureTests {
    private static func firstKeyframe(bitrateKbps: Int = 299, width: Int = 1280, height: Int = 720) throws -> (frame: EncodedVideoFrame, decoded: PixelBufferFrame, source: PixelBufferFrame) {
        let source = PictureProbe.detailedPicture(width: width, height: height)
        let settings = VideoEncoderSettings(width: width, height: height, fps: 30, bitrateKbps: bitrateKbps, profile: .main, level: .level4_0,
                                            keyframeInterval: .seconds(2), realtime: true)
        let encoder = try AppleVideoEncoder(settings: settings)
        defer { encoder.invalidate() }
        let frames = try encoder.encodeNow(source, wallClock: Date(), forceKeyframe: false)
        let frame = try #require(frames.first)
        let decoder = try AppleVideoDecoder(format: frame.format)
        defer { decoder.invalidate() }
        let decoded = try #require(try decoder.decodeNow(frame))
        return (frame, decoded, source)
    }

    /// Audit 2 F9 measured: at 299 kbit/s the first keyframe of a detailed 720p picture is about 1 kB (the rate controller
    /// starts it at a coarse quantiser), but it is a valid keyframe of the right size and the frames that follow refine the
    /// picture within a second. A quantiser cap would give a larger first keyframe but VideoToolbox cannot lift it (every later
    /// picture stays at that quality and the stream runs 35 % over its bit rate); a burst budget costs 1.4-3.7 times the first
    /// second's bytes for under 1.5 dB. Neither was adopted; this pins the behaviour that makes the first picture usable.
    @Test func theFirstKeyframeIsValidAndTheFramesThatFollowRefineIt() throws {
        let source = PictureProbe.detailedPicture(width: 1280, height: 720)
        let settings = VideoEncoderSettings(width: 1280, height: 720, fps: 30, bitrateKbps: 299, profile: .main, level: .level4_0,
                                            keyframeInterval: .seconds(2), realtime: true)
        let encoder = try AppleVideoEncoder(settings: settings)
        defer { encoder.invalidate() }
        var decoder: AppleVideoDecoder?
        defer { decoder?.invalidate() }
        var first: Double?
        var last: Double?
        for index in 0..<45 {
            let picture = PixelBufferFrame(pixelBuffer: source.pixelBuffer, pts: MediaTime(value: Int64(index * 3_000), timescale: 90_000))
            for frame in try encoder.encodeNow(picture, wallClock: Date(), forceKeyframe: false) {
                if index == 0 {
                    #expect(frame.isKeyframe && frame.format.width == 1280 && frame.format.height == 720 && frame.format.profile == 77)
                    decoder = try AppleVideoDecoder(format: frame.format)
                }
                let decoded = try #require(try decoder?.decodeNow(frame))
                let psnr = PictureProbe.lumaPSNR(source.pixelBuffer, decoded.pixelBuffer)
                if index == 0 { first = psnr }
                last = psnr
            }
        }
        let start = try #require(first), end = try #require(last)
        #expect(start >= 22, "the first picture is \(start) dB")
        #expect(end >= start + 1, "refined from \(start) to \(end) dB")
    }

    /// Standard-definition sizes would be read as BT.601 by a decoder that finds no tag.
    @Test(arguments: [(1280, 720), (640, 360), (320, 240)])
    func theOutputIsTaggedBT709(width: Int, height: Int) throws {
        let first = try Self.firstKeyframe(bitrateKbps: 1_500, width: width, height: height)
        // The SPS's VUI says it (the format description parsed from the parameter sets carries it), not just the decoder's defaults.
        let description = try first.frame.format.makeFormatDescription()
        let matrix = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        let primaries = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        #expect(matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String), "matrix \(matrix ?? "none")")
        #expect(primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String), "primaries \(primaries ?? "none")")
        #expect(transfer == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String), "transfer \(transfer ?? "none")")
    }
}

@Suite(.timeLimit(.minutes(2))) struct CodecsPictureStatisticsTests {
    @Test func tellsBlackUninitialisedAndRealPicturesApart() throws {
        let real = PictureProbe.detailedPicture(width: 640, height: 360)
        let realStats = try #require(real.pictureStatistics())
        #expect(!realStats.isBlank && realStats.isDetailed && realStats.meanLuma > 60)

        let black = PictureProbe.detailedPicture(width: 640, height: 360)
        PictureProbe.fill(black.pixelBuffer, luma: 16, chroma: 128)
        let blackStats = try #require(black.pictureStatistics())
        #expect(blackStats.isBlack && blackStats.isBlank && !blackStats.isUninitialized)

        let green = PictureProbe.detailedPicture(width: 640, height: 360)
        PictureProbe.fill(green.pixelBuffer, luma: 0, chroma: 0)
        let greenStats = try #require(green.pictureStatistics())
        #expect(greenStats.isUninitialized && greenStats.isBlank)

        let grey = PictureProbe.detailedPicture(width: 640, height: 360)
        PictureProbe.fill(grey.pixelBuffer, luma: 120, chroma: 128)
        #expect(try #require(grey.pictureStatistics()).isBlank == false)
    }

    @Test func aPictureOfAnotherFormatHasNoStatistics() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        #expect(PixelBufferFrame(pixelBuffer: try #require(buffer), pts: MediaTime(value: 0, timescale: 90_000)).pictureStatistics() == nil)
    }
}
#endif
