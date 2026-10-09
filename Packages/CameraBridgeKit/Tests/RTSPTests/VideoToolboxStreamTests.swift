// Real H.264 from VideoToolbox through the RTSP test server and client (macOS only).
#if canImport(VideoToolbox) && os(macOS)
import BridgeSupport
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import PlatformApple
import Synchronization
import TestSupport
import Testing
import VideoToolbox
@testable import RTSP

enum VideoToolboxFrames {
    enum Failure: Error { case session(OSStatus), noPixelBuffer, noFrames }

    private struct Output: Sendable {
        var nalUnits: [Data]
        var sets: [Data]
        var index: Int
    }

    /// Encodes `count` frames of a moving noise texture with VideoToolbox (no B-frames) and returns them as
    /// `EncodedVideoFrame`s (parameter sets in `format`, none in `nalUnits`). Keyframes are forced every
    /// `keyframeInterval` frames and at `extraKeyframes`; VideoToolbox may add more (`MaxKeyFrameInterval` is only a
    /// maximum, and with concurrent encoder sessions it inserts IDRs of its own). `baseline`: Baseline profile (CAVLC; the
    /// slice headers can then be edited bit by bit, see `H264StreamEditing`).
    static func encodeH264(width: Int, height: Int, count: Int, keyframeInterval: Int, extraKeyframes: Set<Int> = [],
                           baseline: Bool = false) throws -> [EncodedVideoFrame] {
        var sessionOut: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut)
        guard status == noErr, let session = sessionOut else { throw Failure.session(status) }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: baseline ? kVTProfileLevel_H264_Baseline_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 1_500_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)

        // Deterministic noise rows (a shifting texture) so keyframes are large enough to need FU-A.
        var seed: UInt32 = 0x1234_5678
        let noise: [UInt8] = (0..<(width * 2)).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
        let outputs = Mutex<[Output]>([])
        for index in 0..<count {
            var bufferOut: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &bufferOut)
            guard let pixelBuffer = bufferOut else { throw Failure.noPixelBuffer }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                for row in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) {
                    if plane == 0 {
                        let offset = (row * 13 + index * 5) % width
                        noise.withUnsafeBufferPointer { buffer in
                            if let address = buffer.baseAddress { memcpy(base + row * bytesPerRow, address + offset, min(width, bytesPerRow)) }
                        }
                    } else {
                        memset(base + row * bytesPerRow, 0x80, bytesPerRow)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let forceKeyframe = index % keyframeInterval == 0 || extraKeyframes.contains(index)
            let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                                            duration: CMTime(value: 1, timescale: 30), frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample),
                      let description = CMSampleBufferGetFormatDescription(sample) else { return }
                var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr else { return }
                var sets: [Data] = []
                var setCount = 0
                var setIndex = 0
                repeat {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: setIndex, parameterSetPointerOut: &pointer,
                                                                            parameterSetSizeOut: &size, parameterSetCountOut: &setCount,
                                                                            nalUnitHeaderLengthOut: nil) == noErr, let pointer else { break }
                    sets.append(Data(bytes: pointer, count: size))
                    setIndex += 1
                } while setIndex < setCount
                let nals = NALUnits.splitLengthPrefixed(Data(bytes)).filter { ![7, 8, 9].contains(NALUnits.h264Type($0)) }
                outputs.withLock { $0.append(Output(nalUnits: nals, sets: sets, index: index)) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let sorted = outputs.withLock { $0 }.sorted { $0.index < $1.index }
        guard sorted.count == count else { throw Failure.noFrames }
        return sorted.compactMap { output in
            guard output.sets.count >= 2 else { return nil }
            let format = RTSPSessionDescription.makeH264Format(sps: output.sets[0], pps: output.sets[1])
            return EncodedVideoFrame(format: format, nalUnits: output.nalUnits, isKeyframe: output.nalUnits.contains { NALUnits.h264Type($0) == 5 },
                                     pts: MediaTime(value: Int64(output.index) * 3000, timescale: 90_000), wallClock: Date())
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct VideoToolboxStreamTests {
    /// Besides the keyframes every 30 frames, one is forced at 16, like the IDRs VideoToolbox inserts on its own under
    /// load: the test server may start the stream at any of them.
    @Test func realH264SurvivesRTSPRoundTrip() async throws {
        let frames = try VideoToolboxFrames.encodeH264(width: 640, height: 360, count: 60, keyframeInterval: 30, extraKeyframes: [16])
        try #require(frames.count == 60)
        // The forced keyframes; VideoToolbox may add others, so their number is not fixed.
        #expect(frames[0].isKeyframe && frames[16].isKeyframe && frames[30].isKeyframe)
        // Large keyframes exercise FU-A; the SPS parses to the encoded size.
        #expect(frames[0].nalUnits.reduce(0) { $0 + $1.count } > 1400)
        #expect(frames[0].format.width == 640 && frames[0].format.height == 360)

        let server = RTSPTestServer(source: ReplayMediaSource(frames: frames, fps: 30), transport: AppleNetworkTransport())
        try await server.start()
        let client = RTSPClient(configuration: RTSPConfiguration(url: server.url, credentials: nil), transport: AppleNetworkTransport())
        let info = try await client.connect()
        #expect(info.videoFormat?.width == 640)
        #expect(info.videoFormat?.height == 360)
        #expect(info.videoFormat?.parameterSets == frames[0].format.parameterSets)
        let collected = await collect(try await client.play(), timeout: .seconds(10)) { videoFrameCount($0) >= 45 }
        await client.close()
        await server.stop()

        let received = collected.video
        #expect(received.count >= 45)
        guard let first = received.first else { return }
        #expect(first.isKeyframe)
        // The server starts at the first keyframe of the loop after PLAY (whichever one: forced or added by VideoToolbox);
        // every later frame follows in order.
        // The ingest drops SEI NAL units.
        func slices(_ frame: EncodedVideoFrame) -> [Data] { frame.nalUnits.filter { NALUnits.h264Type($0) != 6 } }
        let start = try #require(frames.firstIndex { slices($0) == slices(first) }, "the first received frame is an encoded frame")
        #expect(frames[start].isKeyframe)
        for (offset, frame) in received.enumerated() {
            let original = frames[(start + offset) % frames.count]
            #expect(slices(frame) == slices(original), "frame \(offset)")
            #expect(frame.isKeyframe == original.isKeyframe)
        }
        let deltas = zip(received.dropFirst(), received).map { $0.pts.value - $1.pts.value }
        #expect(deltas.allSatisfy { $0 == 3000 })
    }
}
#endif
