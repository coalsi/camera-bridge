#if os(macOS)
// Same helper in PlatformAppleTests, RTSPTests and BridgeEngineTests (test targets cannot share sources).
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import Synchronization
import VideoToolbox

/// H.264 Main with B-frames from VideoToolbox (AllowFrameReordering), in decode order with presentation and decode times
/// on the 90 kHz clock. Picture `i` shows a centre square of luma 16 + 4 × (i % 50) over a moving noise texture (the
/// motion keeps VideoToolbox choosing B-frames); `index(of:)` reads the number back from a decoded picture.
enum BFrameStream {
    enum Failure: Error { case session(OSStatus), noPixelBuffer, missingFrames(Int) }

    static let width = 640
    static let height = 360
    static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// `count` pictures at `fps`, IDRs at picture 0 and at `keyframes` (picture indices); no other keyframes.
    static func encode(count: Int, fps: Int = 25, keyframes: Set<Int> = []) throws -> [EncodedVideoFrame] {
        var sessionOut: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut)
        guard status == noErr, let session = sessionOut else { throw Failure.session(status) }
        defer { VTCompressionSessionInvalidate(session) }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue),
            (kVTCompressionPropertyKey_RealTime, kCFBooleanFalse),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, 10_000 as CFNumber),
            (kVTCompressionPropertyKey_AverageBitRate, 2_000_000 as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber),
        ]
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value) }

        var seed: UInt32 = 0x2468_ACE1
        let noise: [UInt8] = (0..<(width * 2)).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
        let outputs = Mutex<[EncodedVideoFrame]>([])
        for index in 0..<count {
            let buffer = try picture(index: index, noise: noise)
            let options = index == 0 || keyframes.contains(index) ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)),
                                            duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: options,
                                            infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample, let frame = frame(from: sample) else { return }
                outputs.withLock { $0.append(frame) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let frames = outputs.withLock { $0 }
        guard frames.count == count else { throw Failure.missingFrames(frames.count) }
        return frames
    }

    /// The picture number shown by a decoded picture of this stream (nil if unreadable).
    static func index(of picture: any DecodedVideoFrame) -> Int? {
        guard let thumbnail = picture.grayThumbnail(maxWidth: 64), thumbnail.width == 64, thumbnail.height == 36 else { return nil }
        var sum = 0
        for y in 16..<20 {
            for x in 30..<34 { sum += Int(thumbnail.pixels[y * 64 + x]) }
        }
        return Int(((Double(sum) / 16 - 16) / 4).rounded())
    }

    /// Whether presentation times step back somewhere in decode order (the stream has B-frames).
    static func reorders(_ frames: [EncodedVideoFrame]) -> Bool {
        zip(frames.dropFirst(), frames).contains { $0.pts < $1.pts }
    }

    /// Picture number of a frame from its presentation time.
    static func index(ofPTS pts: MediaTime, fps: Int = 25) -> Int {
        Int((pts.seconds * Double(fps)).rounded())
    }

    private static func picture(index: Int, noise: [UInt8]) throws -> CVPixelBuffer {
        var bufferOut: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &bufferOut)
        guard let buffer = bufferOut else { throw Failure.noPixelBuffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { throw Failure.noPixelBuffer }
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let square = UInt8(16 + 4 * (index % 50))
        for row in 0..<height {
            let offset = (row * 13 + index * 7) % width
            noise.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { memcpy(luma + row * lumaRow, base + offset, width) }
            }
            if (116..<244).contains(row) { (luma + row * lumaRow + 256).update(repeating: square, count: 128) }
        }
        memset(chroma, 0x80, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        return buffer
    }

    private static func frame(from sample: CMSampleBuffer) -> EncodedVideoFrame? {
        guard let description = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var sets: [Data] = []
        var setCount = 0
        var setIndex = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: setIndex, parameterSetPointerOut: &pointer,
                                                                    parameterSetSizeOut: &size, parameterSetCountOut: &setCount,
                                                                    nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
            setIndex += 1
        } while setIndex < setCount
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard sets.count >= 2, CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr,
              let format = VideoFormat.h264(sps: sets[0], pps: sets[1]) else { return nil }
        let nalUnits = NALUnits.splitLengthPrefixed(Data(bytes)).filter { ![7, 8, 9].contains(NALUnits.h264Type($0)) }
        let pts = mediaTime(CMSampleBufferGetPresentationTimeStamp(sample))
        let decodeTime = CMSampleBufferGetDecodeTimeStamp(sample)
        let dts = decodeTime.isNumeric ? mediaTime(decodeTime) : nil
        return EncodedVideoFrame(format: format, nalUnits: nalUnits, isKeyframe: nalUnits.contains { NALUnits.h264Type($0) == 5 }, pts: pts,
                                 dts: dts == pts ? nil : dts, wallClock: origin.addingTimeInterval(pts.seconds))
    }

    private static func mediaTime(_ time: CMTime) -> MediaTime {
        MediaTime(value: time.value, timescale: time.timescale).converted(to: 90_000)
    }
}
#endif
