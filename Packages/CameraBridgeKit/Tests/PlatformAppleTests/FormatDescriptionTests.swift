#if os(macOS)
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import Testing
import VideoToolbox
@testable import PlatformApple

@Suite(.timeLimit(.minutes(1))) struct VideoFormatDescriptionTests {
    @Test func h264FromVideoToolboxParameterSets() throws {
        let sets = try encoderParameterSets(codec: kCMVideoCodecType_H264, width: 1920, height: 1080, profileLevel: kVTProfileLevel_H264_High_4_0)
        let format = try #require(VideoFormat.h264(sps: sets[0], pps: sets[1]))
        let description = try format.makeFormatDescription()
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264)
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        #expect(dimensions.width == 1920 && dimensions.height == 1080)
        #expect(try Self.parameterSets(of: description, hevc: false) == (sets, 4))
    }

    @Test func hevcFromVideoToolboxParameterSets() throws {
        guard let sets = try? encoderParameterSets(codec: kCMVideoCodecType_HEVC, width: 1280, height: 720, profileLevel: kVTProfileLevel_HEVC_Main_AutoLevel) else {
            return   // no HEVC encoder on this Mac
        }
        let format = try #require(VideoFormat.hevc(vps: sets[0], sps: sets[1], pps: sets[2]))
        let description = try format.makeFormatDescription()
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC)
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        #expect(dimensions.width == 1280 && dimensions.height == 720)
        #expect(try Self.parameterSets(of: description, hevc: true) == (sets, 4))
    }

    @Test func missingParameterSetsAreUnsupported() {
        #expect(throws: MediaCodecError.self) {
            _ = try VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: []).makeFormatDescription()
        }
        #expect(throws: MediaCodecError.self) {
            _ = try VideoFormat(codec: .hevc, width: 640, height: 360, parameterSets: [Data([0x40, 0x01])]).makeFormatDescription()
        }
    }

    @Test func malformedParameterSetsThrowInsteadOfTrapping() {
        #expect(throws: MediaCodecError.self) {
            _ = try VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [Data([0x67]), Data([0x68])]).makeFormatDescription()
        }
    }

    static func parameterSets(of description: CMFormatDescription, hevc: Bool) throws -> ([Data], Int32) {
        var sets: [Data] = []
        var count = 0
        var headerLength: Int32 = 0
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            guard status == noErr, let pointer else { throw MediaCodecError.sessionFailed(status) }
            sets.append(Data(bytes: pointer, count: size))
            index += 1
        } while index < count
        return (sets, headerLength)
    }
}

@Suite(.timeLimit(.minutes(1))) struct AudioFormatDescriptionTests {
    @Test func aacLCCarriesAValidESDSMagicCookie() throws {
        let format = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        let description = try format.makeFormatDescription()
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC && asbd.mSampleRate == 32_000 && asbd.mChannelsPerFrame == 1)
        #expect(asbd.mFramesPerPacket == 1024)
        let cookie = try #require(Self.magicCookie(description))
        // AudioToolbox parses the cookie as an MPEG-4 ES_Descriptor and recovers the stream format from it.
        var fromESDS = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = cookie.withUnsafeBytes { bytes in
            AudioFormatGetProperty(kAudioFormatProperty_ASBDFromESDS, UInt32(bytes.count), bytes.baseAddress, &size, &fromESDS)
        }
        #expect(status == noErr)
        #expect(fromESDS.mFormatID == kAudioFormatMPEG4AAC && fromESDS.mSampleRate == 32_000 && fromESDS.mChannelsPerFrame == 1)
    }

    @Test func aacLCStereo48k() throws {
        let asbd = try Self.streamDescription(AudioFormat.aacLC(sampleRate: 48_000, channels: 2))
        #expect(asbd.mSampleRate == 48_000 && asbd.mChannelsPerFrame == 2)
    }

    @Test func aacWithoutAudioSpecificConfigIsUnsupported() {
        #expect(throws: MediaCodecError.self) {
            _ = try AudioFormat(codec: .aac, sampleRate: 32_000, channels: 1).makeFormatDescription()
        }
    }

    @Test func g711OpusAndLinearPCM() throws {
        let mu = try Self.streamDescription(AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1))
        #expect(mu.mFormatID == kAudioFormatULaw && mu.mSampleRate == 8_000 && mu.mBytesPerFrame == 1 && mu.mFramesPerPacket == 1 && mu.mBitsPerChannel == 8)
        let a = try Self.streamDescription(AudioFormat(codec: .pcma, sampleRate: 8_000, channels: 1))
        #expect(a.mFormatID == kAudioFormatALaw)
        let opus = try Self.streamDescription(AudioFormat(codec: .opus, sampleRate: 24_000, channels: 1))
        #expect(opus.mFormatID == kAudioFormatOpus && opus.mSampleRate == 24_000 && opus.mFramesPerPacket == 480)
        let pcm = try Self.streamDescription(AudioFormat(codec: .linearPCM, sampleRate: 16_000, channels: 2))
        #expect(pcm.mFormatID == kAudioFormatLinearPCM && pcm.mBitsPerChannel == 16 && pcm.mBytesPerFrame == 4 && pcm.mChannelsPerFrame == 2)
        #expect(pcm.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && pcm.mFormatFlags & kAudioFormatFlagIsPacked != 0)
    }

    @Test func invalidAudioParametersThrow() {
        #expect(throws: MediaCodecError.self) { _ = try AudioFormat(codec: .pcmu, sampleRate: 0, channels: 1).makeFormatDescription() }
        #expect(throws: MediaCodecError.self) { _ = try AudioFormat(codec: .opus, sampleRate: 24_000, channels: 0).makeFormatDescription() }
    }

    /// Copies the ASBD while the description is alive (the returned pointer is owned by the description).
    static func streamDescription(_ format: AudioFormat) throws -> AudioStreamBasicDescription {
        let description = try format.makeFormatDescription()
        return try withExtendedLifetime(description) {
            try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        }
    }

    static func magicCookie(_ description: CMAudioFormatDescription) -> Data? {
        var size = 0
        guard let pointer = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size), size > 0 else { return nil }
        return Data(bytes: pointer, count: size)
    }
}

@Suite(.timeLimit(.minutes(1))) struct PixelBufferFrameTests {
    @Test func reportsBufferDimensionsAndPTS() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let frame = PixelBufferFrame(pixelBuffer: try #require(buffer), pts: .seconds(2))
        #expect(frame.width == 320 && frame.height == 180 && frame.pts == .seconds(2))
    }
}
#endif
