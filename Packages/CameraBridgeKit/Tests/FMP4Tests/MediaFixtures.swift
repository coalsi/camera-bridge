#if canImport(VideoToolbox) && canImport(AVFoundation)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import Synchronization
import VideoToolbox

// Real media for the validation tests, generated in-process with Apple's encoders (AppleMediaCodecs is built in
// parallel by W1-2, so the tests talk to VideoToolbox / AVAudioConverter directly).

enum FixtureError: Error { case encoderUnavailable(OSStatus), encodeFailed(OSStatus), noOutput, noParameterSets, audio(String) }

struct EncodedClip: Sendable {
    var format: VideoFormat
    var frames: [EncodedVideoFrame]
    /// The avcC/hvcC VideoToolbox put in the output format description (SampleDescriptionExtensionAtoms).
    var decoderConfigurationAtom: Data?
}

private struct EncodedSample: Sendable {
    var index: Int
    var data: Data
    var parameterSets: [Data]
    var atom: Data?
}

/// Encodes `frameCount` frames of a moving test pattern with VideoToolbox (no B-frames), forcing an IDR every `gop` frames.
/// Frame `i` has pts `i / fps` (90 kHz) and wall clock `wallClockStart + i / fps`.
/// `pixelAspectRatio` asks the encoder to signal that sample aspect ratio in the SPS VUI.
func encodeVideo(codec: VideoCodec, width: Int = 320, height: Int = 240, fps: Int = 30, gop: Int, frameCount: Int,
                 pixelAspectRatio: (horizontal: Int, vertical: Int)? = nil,
                 wallClockStart: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> EncodedClip {
    let codecType = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
    // Prefer the software encoder: a hardware encoder shared by parallel tests inserts IDRs of its own.
    let software = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanFalse] as CFDictionary
    var sessionOut: VTCompressionSession?
    var status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codecType,
                                            encoderSpecification: software, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut)
    if status != noErr {
        status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codecType,
                                            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut)
    }
    guard status == noErr, let session = sessionOut else { throw FixtureError.encoderUnavailable(status) }
    defer { VTCompressionSessionInvalidate(session) }
    let profile = codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    // Keyframes only where forced below (every `gop` frames), never on the encoder's own initiative.
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (frameCount + gop) as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 500_000 as CFNumber)
    if let pixelAspectRatio {
        let spacing = [kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: pixelAspectRatio.horizontal,
                       kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: pixelAspectRatio.vertical] as CFDictionary
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PixelAspectRatio, value: spacing)
    }
    VTCompressionSessionPrepareToEncodeFrames(session)

    let collected = Mutex<[EncodedSample]>([])
    let failure = Mutex<OSStatus>(noErr)
    for index in 0..<frameCount {
        let pixelBuffer = try makePatternBuffer(width: width, height: height, frame: index)
        let properties = index % gop == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let encodeStatus = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)),
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else {
                failure.withLock { $0 = status == noErr ? -1 : status }
                return
            }
            if let sample = extract(sampleBuffer, index: index, codec: codec) {
                collected.withLock { $0.append(sample) }
            } else {
                failure.withLock { $0 = -2 }
            }
        }
        guard encodeStatus == noErr else { throw FixtureError.encodeFailed(encodeStatus) }
        // One frame at a time: with a queue of pending frames a contended hardware encoder (parallel tests) inserts IDRs.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    let failed = failure.withLock { $0 }
    guard failed == noErr else { throw FixtureError.encodeFailed(failed) }
    let samples = collected.withLock { $0 }.sorted { $0.index < $1.index }
    guard samples.count == frameCount, let first = samples.first else { throw FixtureError.noOutput }

    let sets = first.parameterSets
    let format: VideoFormat?
    switch codec {
    case .h264: format = sets.count >= 2 ? VideoFormat.h264(sps: sets[0], pps: sets[1]) : nil
    case .hevc: format = sets.count >= 3 ? VideoFormat.hevc(vps: sets[0], sps: sets[1], pps: sets[2]) : nil
    }
    guard let format else { throw FixtureError.noParameterSets }
    let parameterSetTypes: Set<UInt8> = codec == .h264 ? [7, 8, 9] : [32, 33, 34, 35]
    let frames = samples.map { sample in
        let nals = NALUnits.splitLengthPrefixed(sample.data).filter { nal in
            !parameterSetTypes.contains(codec == .h264 ? NALUnits.h264Type(nal) : NALUnits.hevcType(nal))
        }
        // IDR (H.264 type 5) / IRAP (HEVC 16…23) from the bitstream itself, as an RTSP ingest decides it.
        let isKeyframe = nals.contains { nal in codec == .h264 ? NALUnits.h264Type(nal) == 5 : (16...23).contains(NALUnits.hevcType(nal)) }
        return EncodedVideoFrame(format: format, nalUnits: nals, isKeyframe: isKeyframe,
                                 pts: MediaTime(value: Int64(sample.index) * 90_000 / Int64(fps), timescale: 90_000),
                                 wallClock: wallClockStart.addingTimeInterval(Double(sample.index) / Double(fps)))
    }
    return EncodedClip(format: format, frames: frames, decoderConfigurationAtom: first.atom)
}

private func extract(_ sampleBuffer: CMSampleBuffer, index: Int, codec: VideoCodec) -> EncodedSample? {
    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer), let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
    let length = CMBlockBufferGetDataLength(block)
    var data = Data(count: length)
    let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
        guard let base = raw.baseAddress else { return -1 }
        return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
    }
    guard copied == noErr else { return nil }
    var sets: [Data] = []
    var count = 0
    var setIndex = 0
    repeat {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let result: OSStatus = codec == .hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: setIndex, parameterSetPointerOut: &pointer,
                                                                parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: setIndex, parameterSetPointerOut: &pointer,
                                                                parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        guard result == noErr, let pointer else { return nil }
        sets.append(Data(bytes: pointer, count: size))
        setIndex += 1
    } while setIndex < count
    let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
        as? [String: Any]
    let atom = atoms?[codec == .h264 ? "avcC" : "hvcC"] as? Data
    return EncodedSample(index: index, data: data, parameterSets: sets, atom: atom)
}

/// NV12 frame: a static diagonal gradient with a bright 32×32 square moving 4 px per frame, so P-frames carry real motion
/// without looking like scene cuts (which make the encoder insert IDRs of its own).
private func makePatternBuffer(width: Int, height: Int, frame: Int) throws -> CVPixelBuffer {
    var bufferOut: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &bufferOut)
    guard status == kCVReturnSuccess, let buffer = bufferOut else { throw FixtureError.encodeFailed(status) }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let boxX = (frame * 4) % max(1, width - 32)
        let boxY = (frame * 2) % max(1, height - 32)
        for row in 0..<rows {
            for column in 0..<rowBytes {
                let inBox = plane == 0 && (boxY..<boxY + 32).contains(row) && (boxX..<boxX + 32).contains(column)
                pointer[row * rowBytes + column] = plane == 0 ? (inBox ? 0xEB : UInt8(truncatingIfNeeded: (row + column) / 3 + 16)) : 0x80
            }
        }
    }
    return buffer
}

/// AAC-LC frames (one access unit each, no ADTS) of a 440 Hz tone, encoded with AVAudioConverter.
/// Frame `i` has pts `i · 1024` at `sampleRate`.
func encodeAAC(sampleRate: Int = 32_000, seconds: Double, wallClockStart: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> [EncodedAudioFrame] {
    guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false) else {
        throw FixtureError.audio("PCM format")
    }
    var description = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                                  mFramesPerPacket: 1_024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
    guard let aacFormat = AVAudioFormat(streamDescription: &description), let converter = AVAudioConverter(from: pcmFormat, to: aacFormat) else {
        throw FixtureError.audio("AAC converter")
    }
    let total = AVAudioFrameCount(seconds * Double(sampleRate))
    guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: total), let channel = pcm.floatChannelData?[0] else {
        throw FixtureError.audio("PCM buffer")
    }
    pcm.frameLength = total
    for i in 0..<Int(total) { channel[i] = 0.3 * sin(2 * Float.pi * 440 * Float(i) / Float(sampleRate)) }

    final class InputState { var supplied = false }
    let input = InputState()
    var packets: [Data] = []
    while true {
        let output = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 16, maximumPacketSize: max(converter.maximumOutputPacketSize, 1_536))
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let first = !input.supplied
            input.supplied = true
            inputStatus.pointee = first ? .haveData : .endOfStream
            return first ? pcm : nil
        }
        if let descriptions = output.packetDescriptions {
            for index in 0..<Int(output.packetCount) {
                let packet = descriptions[index]
                packets.append(Data(bytes: output.data.advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize)))
            }
        }
        if status == .error { throw FixtureError.audio(error?.localizedDescription ?? "convert") }
        if status == .endOfStream || (status == .inputRanDry && output.packetCount == 0) { break }
    }
    let format = AudioFormat.aacLC(sampleRate: sampleRate, channels: 1)
    return packets.enumerated().map { index, data in
        EncodedAudioFrame(format: format, data: data, pts: MediaTime(value: Int64(index) * 1_024, timescale: Int32(sampleRate)), sampleCount: 1_024,
                          wallClock: wallClockStart.addingTimeInterval(Double(index) * 1_024 / Double(sampleRate)))
    }
}

/// What AVFoundation makes of a file.
struct PlaybackReport: Sendable {
    var duration: Double
    var decodedVideoFrames: Int
    var videoTrackCount: Int
    var audioTrackCount: Int
    var decodedAudioSamples: Int
    var videoReaderCompleted: Bool
    var audioReaderCompleted: Bool
}

func readBack(_ url: URL) async throws -> PlaybackReport {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    var report = PlaybackReport(duration: duration, decodedVideoFrames: 0, videoTrackCount: videoTracks.count, audioTrackCount: audioTracks.count,
                                decodedAudioSamples: 0, videoReaderCompleted: false, audioReaderCompleted: audioTracks.isEmpty)
    if let track = videoTracks.first {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        while let sample = output.copyNextSampleBuffer() {
            report.decodedVideoFrames += CMSampleBufferGetImageBuffer(sample) != nil ? 1 : 0
        }
        report.videoReaderCompleted = reader.status == .completed
    }
    if let track = audioTracks.first {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        while let sample = output.copyNextSampleBuffer() {
            report.decodedAudioSamples += CMSampleBufferGetNumSamples(sample)
        }
        report.audioReaderCompleted = reader.status == .completed
    }
    return report
}
#endif
