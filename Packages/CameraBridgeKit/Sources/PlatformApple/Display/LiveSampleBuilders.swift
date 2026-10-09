#if os(macOS)
import AudioToolbox
import CoreMedia
import Foundation
import MediaCore

/// CoreMedia sample buffers for the app's live viewer (`AVSampleBufferDisplayLayer`, `AVSampleBufferAudioRenderer`): the
/// camera's access units as they are, no transcoding. CoreMedia is not portable, so the conversion lives here; the app
/// owns the layers.

/// H.264 / HEVC access units as sample buffers a display layer shows at once (no timeline, no buffering: the lowest
/// latency). One builder per consumer (not thread-safe): it keeps the format description of the stream it converts and makes
/// a new one when a keyframe brings another format (a camera that reconnected with other settings).
public final class LiveVideoSampleBuilder {
    private var current: (format: VideoFormat, description: CMVideoFormatDescription)?

    public init() {}

    /// The access unit as a ready sample buffer marked "display immediately" (delta frames also `NotSync`), nil for a frame
    /// without picture data. Throws `MediaCodecError` when CoreMedia refuses the format's parameter sets or the data.
    public func sampleBuffer(for frame: EncodedVideoFrame) throws -> sending CMSampleBuffer? {
        let description: CMVideoFormatDescription
        if let current, current.format == frame.format {
            description = current.description
        } else {
            description = try frame.format.makeFormatDescription()
            current = (frame.format, description)
        }
        // A new sample buffer, shared with nobody: the caller may hand it to another task.
        nonisolated(unsafe) let made = try VideoSampleBuffers.sampleBuffer(for: frame, description: description)
        guard let sample = made else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// The format description of the stream converted last (tests).
    public var formatDescription: CMVideoFormatDescription? { current?.description }
}

/// Audio access units (AAC, AAC-ELD, Opus, G.711, 16-bit LPCM) as sample buffers an `AVSampleBufferAudioRenderer` decodes
/// and plays. One builder per consumer (not thread-safe).
public final class LiveAudioSampleBuilder {
    private var current: (format: AudioFormat, description: CMAudioFormatDescription)?

    public init() {}

    /// The access unit at `presentationTime` on the renderer's timeline (the frame's own timestamps are the camera's).
    /// Nil for an empty frame. Throws `MediaCodecError` when CoreMedia refuses the format or the data.
    public func sampleBuffer(for frame: EncodedAudioFrame, presentationTime: CMTime) throws -> sending CMSampleBuffer? {
        guard !frame.data.isEmpty else { return nil }
        let description: CMAudioFormatDescription
        if let current, current.format == frame.format {
            description = current.description
        } else {
            description = try frame.format.makeFormatDescription()
            current = (frame.format, description)
        }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.data.count, blockAllocator: nil,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: frame.data.count,
                                                        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw MediaCodecError.sessionFailed(status) }
        status = frame.data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw MediaCodecError.sessionFailed(status) }

        // Compressed formats with variable-size packets (AAC, Opus) are one packet with a description; the constant-size
        // formats (G.711, LPCM) are counted in frames.
        var sample: CMSampleBuffer?
        switch frame.format.codec {
        case .aac, .aacELD, .opus:
            var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.data.count))
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: description,
                                                                          sampleCount: 1, presentationTimeStamp: presentationTime,
                                                                          packetDescriptions: &packet, sampleBufferOut: &sample)
        case .pcmu, .pcma, .linearPCM:
            let bytesPerFrame = max(1, frame.format.channels * (frame.format.codec == .linearPCM ? 2 : 1))
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: description,
                                                                          sampleCount: frame.data.count / bytesPerFrame, presentationTimeStamp: presentationTime,
                                                                          packetDescriptions: nil, sampleBufferOut: &sample)
        }
        guard status == noErr else { throw MediaCodecError.sessionFailed(status) }
        nonisolated(unsafe) let made = sample   // a new sample buffer, shared with nobody
        return made
    }
}
#endif
