#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import VideoToolbox

/// Conversions between MediaCore's video frames and CoreMedia sample buffers.
enum VideoSampleBuffers {
    /// `frame` without its SEI NAL units. A decoder has no use for them (they carry no picture data), and cameras send
    /// malformed ones: a Tapo's vendor SEI declares 34 bytes and holds 32, which makes VideoToolbox's software H.264 decoder
    /// reject every delta frame (-8969).
    static func withoutSEI(_ frame: EncodedVideoFrame) -> EncodedVideoFrame {
        let isSEI: (Data) -> Bool = switch frame.format.codec {
        case .h264: { NALUnits.h264Type($0) == 6 }
        case .hevc: { [39, 40].contains(NALUnits.hevcType($0)) }
        }
        guard frame.nalUnits.contains(where: isSEI) else { return frame }
        var stripped = frame
        stripped.nalUnits = frame.nalUnits.filter { !isSEI($0) }
        return stripped
    }

    /// One access unit as a ready CMSampleBuffer (4-byte length prefixes, `NotSync` on delta frames; SEI NAL units left
    /// out, see `withoutSEI`). Nil for a frame without NAL units.
    static func sampleBuffer(for frame: EncodedVideoFrame, description: CMVideoFormatDescription) throws -> CMSampleBuffer? {
        let frame = withoutSEI(frame)
        let payload = frame.lengthPrefixedData
        guard !frame.nalUnits.isEmpty, !payload.isEmpty else { return nil }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: payload.count,
                                                        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw MediaCodecError.sessionFailed(status) }
        status = payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw MediaCodecError.sessionFailed(status) }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: cmTime(frame.pts), decodeTimeStamp: frame.dts.map(cmTime) ?? .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: 1, sampleTimingEntryCount: 1,
                                           sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw MediaCodecError.sessionFailed(status) }
        if !frame.isKeyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// An encoder output, copied out of its CMSampleBuffer.
    struct EncodedOutput: Sendable {
        var codec: VideoCodec
        var nalUnits: [Data]
        var parameterSets: [Data]
        var isKeyframe: Bool
        var pts: MediaTime
        var dts: MediaTime?
    }

    /// Copies an encoder's CMSampleBuffer: NAL units without parameter sets / AUDs, the parameter sets from the format
    /// description (H.264 [SPS, PPS], HEVC [VPS, SPS, PPS]), sync flag and 90 kHz timestamps.
    static func encodedOutput(_ sample: CMSampleBuffer) throws -> EncodedOutput {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { throw MediaCodecError.unsupported("encoder output without a format") }
        let codec: VideoCodec
        switch CMFormatDescriptionGetMediaSubType(description) {
        case kCMVideoCodecType_H264: codec = .h264
        case kCMVideoCodecType_HEVC: codec = .hevc
        case let other: throw MediaCodecError.unsupported("encoder output codec \(other)")
        }
        let (parameterSets, lengthSize) = try Self.parameterSets(of: description, codec: codec)

        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw MediaCodecError.unsupported("encoder output without data") }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else { throw MediaCodecError.sessionFailed(status) }
        let nalUnits = NALUnits.splitLengthPrefixed(data, lengthSize: lengthSize).filter { nal in
            switch codec {
            case .h264: ![7, 8, 9].contains(NALUnits.h264Type(nal))
            case .hevc: !(32...35).contains(NALUnits.hevcType(nal))
            }
        }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self) as NSDictionary
            if let notSync = dictionary[kCMSampleAttachmentKey_NotSync as String] as? Bool, notSync { isKeyframe = false }
        }
        let pts = mediaTime(CMSampleBufferGetPresentationTimeStamp(sample))
        let decodeTime = CMSampleBufferGetDecodeTimeStamp(sample)
        let dts = decodeTime.isValid ? mediaTime(decodeTime) : nil
        return EncodedOutput(codec: codec, nalUnits: nalUnits, parameterSets: parameterSets, isKeyframe: isKeyframe, pts: pts, dts: dts == pts ? nil : dts)
    }

    /// Parameter sets (VPS/SPS/PPS only, in that order) and the NAL length size of an H.264/HEVC description.
    static func parameterSets(of description: CMFormatDescription, codec: VideoCodec) throws -> ([Data], Int) {
        var sets: [Data] = []
        var count = 0
        var lengthSize: Int32 = 4
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus = switch codec {
            case .h264:
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
            case .hevc:
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
            }
            guard status == noErr, let pointer else { throw MediaCodecError.sessionFailed(status) }
            sets.append(Data(bytes: pointer, count: size))
            index += 1
        } while index < count
        let order: [UInt8] = codec == .h264 ? [7, 8] : [32, 33, 34]
        let ordered = order.compactMap { type in
            sets.first { !$0.isEmpty && (codec == .h264 ? NALUnits.h264Type($0) : NALUnits.hevcType($0)) == type }
        }
        guard ordered.count == order.count else { throw MediaCodecError.unsupported("\(codec) format without parameter sets") }
        return (ordered, Int(lengthSize))
    }

    static func cmTime(_ time: MediaTime) -> CMTime {
        time.timescale > 0 ? CMTime(value: time.value, timescale: time.timescale) : .invalid
    }

    /// 90 kHz.
    static func mediaTime(_ time: CMTime) -> MediaTime {
        guard time.isNumeric else { return MediaTime(value: 0, timescale: 90_000) }
        return MediaTime(value: time.value, timescale: time.timescale).converted(to: 90_000)
    }
}

/// Scales pictures with a VTPixelTransferSession (letterboxed when the aspect ratio changes). Not thread-safe.
final class PixelScaler {
    private var session: VTPixelTransferSession?

    init() throws {
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard status == noErr, let session else { throw MediaCodecError.sessionFailed(status) }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        self.session = session
    }

    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }

    /// A `width`×`height` copy of `source`, from `pool` when given (else a new IOSurface-backed NV12 buffer).
    func scale(_ source: CVPixelBuffer, width: Int, height: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        guard let session else { throw MediaCodecError.unsupported("scaler invalidated") }
        var destination: CVPixelBuffer?
        var status: OSStatus
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        } else {
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary] as CFDictionary
            status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &destination)
        }
        guard status == kCVReturnSuccess, let destination else { throw MediaCodecError.sessionFailed(status) }
        status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == noErr else { throw MediaCodecError.sessionFailed(status) }
        return destination
    }
}
#endif
