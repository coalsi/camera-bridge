#if os(macOS)
// Same helper as Tests/MediaCoreTests/VideoToolboxFixtures.swift (test targets cannot share sources).
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

enum FixtureError: Error { case encoderUnavailable(OSStatus), noOutput, noParameterSets }

/// Encodes one frame with VideoToolbox and returns the parameter sets from the output format description:
/// H.264 → [SPS, PPS]; HEVC → [VPS, SPS, PPS]. Raw NAL units without start codes.
func encoderParameterSets(codec: CMVideoCodecType, width: Int, height: Int, profileLevel: CFString?) throws -> [Data] {
    var sessionOut: VTCompressionSession?
    let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
                                            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut)
    guard status == noErr, let session = sessionOut else { throw FixtureError.encoderUnavailable(status) }
    defer { VTCompressionSessionInvalidate(session) }
    if let profileLevel { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel) }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)

    var bufferOut: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &bufferOut)
    guard let pixelBuffer = bufferOut else { throw FixtureError.noOutput }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
            memset(base, plane == 0 ? 0x60 : 0x80, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let output = Mutex<CMFormatDescription?>(nil)
    let frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
    VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: CMTime(value: 0, timescale: 30),
                                    duration: CMTime(value: 1, timescale: 30), frameProperties: frameProperties, infoFlagsOut: nil) { status, _, sampleBuffer in
        guard status == noErr, let sampleBuffer, let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        output.withLock { $0 = description }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    guard let description = output.withLock({ $0 }) else { throw FixtureError.noOutput }

    var sets: [Data] = []
    var count = 0
    var index = 0
    repeat {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let result: OSStatus = codec == kCMVideoCodecType_HEVC
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        guard result == noErr, let pointer else { throw FixtureError.noParameterSets }
        sets.append(Data(bytes: pointer, count: size))
        index += 1
    } while index < count
    return sets
}

func hevcEncoderAvailable() -> Bool {
    (try? encoderParameterSets(codec: kCMVideoCodecType_HEVC, width: 640, height: 360, profileLevel: kVTProfileLevel_HEVC_Main_AutoLevel)) != nil
}
#endif
