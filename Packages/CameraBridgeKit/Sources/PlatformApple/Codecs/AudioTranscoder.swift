#if os(macOS)
import AudioToolbox
import Foundation
import MediaCore
import Synchronization

/// Audio transcoding: decode (G.711 in Swift; AAC / AAC-ELD / Opus with AudioToolbox; LPCM as is) → resample / remix
/// (AudioToolbox, only when rate or channel count differ) → encode (AAC-LC 1024, AAC-ELD 480, Opus 20 ms with
/// AudioToolbox; G.711 / LPCM in 20 ms chunks in Swift).
///
/// Output timestamps are on the output sample clock and contiguous (`pts[n+1] = pts[n] + sampleCount`), so that decoded
/// audio labelled time T carries the input from time T. The encoder's delay (`kAudioConverterPrimeInfo` leading
/// frames: AAC-LC 2112 samples, AAC-ELD about 256, Opus 6.5 ms) is compensated by dropping the first
/// ⌈delay / packet⌉ packets, which hold priming, and starting the timeline at the first input PTS plus the rest of
/// those packets (AAC-LC: + 960 samples); outputs without an encoder (G.711, LPCM) start at the first input PTS. An
/// input gap or jump larger than max(100 ms, two input frames) shifts the output timeline by the same amount.
/// `flush()` drains every stage (the final G.711 / LPCM chunk may be shorter than 20 ms) and resets the timeline to
/// the next input frame (the encoder primes again).
///
/// Opus input packets may have any duration RFC 6716 allows (2.5 ms … 120 ms, one or several frames): the decoder is
/// created with a variable packet duration (`mFramesPerPacket` 0), which AudioToolbox's Opus decoder accepts for every
/// valid packet (a fixed duration makes packets of any other duration fail with 'bada').
final class AppleAudioTranscoder: AudioTranscoding {
    let outputFormat: AudioFormat
    private let inputFormat: AudioFormat
    private let state: Mutex<Pipeline>

    init(input: AudioFormat, output: AudioEncoderSettings) throws {
        guard input.sampleRate > 0, (1...8).contains(input.channels) else {
            throw MediaCodecError.unsupported("audio input \(input.codec) \(input.sampleRate) Hz × \(input.channels)")
        }
        guard output.sampleRate > 0, (1...8).contains(output.channels) else {
            throw MediaCodecError.unsupported("audio output \(output.codec) \(output.sampleRate) Hz × \(output.channels)")
        }
        let pipeline = try Pipeline(input: input, output: output)
        inputFormat = input
        outputFormat = pipeline.outputFormat
        state = Mutex(pipeline)
    }

    func transcode(_ frame: EncodedAudioFrame) throws -> [EncodedAudioFrame] {
        try state.withLock { try $0.transcode(frame) }
    }

    func flush() throws -> [EncodedAudioFrame] {
        try state.withLock { try $0.flush() }
    }
}

/// The transcoder's stages and timeline (accessed under the transcoder's lock).
private final class Pipeline {
    let input: AudioFormat
    let outputFormat: AudioFormat
    private let outputSettings: AudioEncoderSettings
    private let decoder: AudioConverterStream?      // compressed input → PCM
    private let resampler: AudioConverterStream?    // PCM → PCM at the output rate / channels
    private let encoder: AudioConverterStream?      // PCM → compressed output
    private let chunkFrames: Int                    // G.711 / LPCM output chunk (20 ms)
    private var pendingPCM = Data()                 // G.711 / LPCM output not yet a full chunk
    /// Encoder delay compensation: packets of priming dropped at the start of a run, and the samples of real input
    /// they also held (the timeline starts that much after the first input PTS).
    private let primingPackets: Int
    private let primingOffset: Int64
    private var primingPacketsLeft: Int

    // Timeline (output sample clock).
    private var anchorPTS: Int64?
    private var anchorWallClock = Date()
    private var produced: Int64 = 0
    private var expectedInputPTS: MediaTime?

    init(input: AudioFormat, output: AudioEncoderSettings) throws {
        self.input = input
        outputSettings = output
        let decodedChannels = input.channels
        let decodedRate = input.sampleRate

        switch input.codec {
        case .pcmu, .pcma, .linearPCM:
            decoder = nil
        case .aac, .aacELD:
            guard let config = input.audioSpecificConfig, !config.isEmpty else {
                throw MediaCodecError.unsupported("\(input.codec) input without an AudioSpecificConfig")
            }
            let cookie = MPEG4ESDescriptor.make(audioSpecificConfig: config)
            let formatID = input.codec == .aac ? kAudioFormatMPEG4AAC : kAudioFormatMPEG4AAC_ELD
            let source = Self.streamDescription(fromESDS: cookie)
                ?? .compressed(formatID, sampleRate: input.sampleRate, channels: input.channels, framesPerPacket: input.samplesPerFrame)
            decoder = try AudioConverterStream(from: source, to: .pcm16(sampleRate: Int(source.mSampleRate), channels: Int(source.mChannelsPerFrame)),
                                               decoderCookie: cookie)
        case .opus:
            decoder = try AudioConverterStream(from: .compressed(kAudioFormatOpus, sampleRate: input.sampleRate, channels: input.channels, framesPerPacket: 0),
                                               to: .pcm16(sampleRate: input.sampleRate, channels: input.channels))
        }
        let pcmRate = decoder.map { Int($0.output.mSampleRate) } ?? decodedRate
        let pcmChannels = decoder.map { Int($0.output.mChannelsPerFrame) } ?? decodedChannels
        if pcmRate != output.sampleRate || pcmChannels != output.channels {
            resampler = try AudioConverterStream(from: .pcm16(sampleRate: pcmRate, channels: pcmChannels),
                                                 to: .pcm16(sampleRate: output.sampleRate, channels: output.channels))
        } else {
            resampler = nil
        }

        chunkFrames = max(1, output.sampleRate / 50)
        switch output.codec {
        case .pcmu, .pcma, .linearPCM:
            encoder = nil
            outputFormat = AudioFormat(codec: output.codec, sampleRate: output.sampleRate, channels: output.channels)
        case .aac:
            encoder = try AudioConverterStream(from: .pcm16(sampleRate: output.sampleRate, channels: output.channels),
                                               to: .compressed(kAudioFormatMPEG4AAC, sampleRate: output.sampleRate, channels: output.channels, framesPerPacket: 1024),
                                               bitrate: output.bitrate)
            outputFormat = AudioFormat.aacLC(sampleRate: output.sampleRate, channels: output.channels)
        case .aacELD:
            let eld = try AudioConverterStream(from: .pcm16(sampleRate: output.sampleRate, channels: output.channels),
                                               to: .compressed(kAudioFormatMPEG4AAC_ELD, sampleRate: output.sampleRate, channels: output.channels, framesPerPacket: 480),
                                               bitrate: output.bitrate)
            guard let config = eld.compressionMagicCookie.flatMap(MPEG4ESDescriptor.audioSpecificConfig(in:)) else {
                throw MediaCodecError.unsupported("AAC-ELD encoder without an AudioSpecificConfig")
            }
            encoder = eld
            outputFormat = AudioFormat(codec: .aacELD, sampleRate: output.sampleRate, channels: output.channels, audioSpecificConfig: config)
        case .opus:
            encoder = try AudioConverterStream(from: .pcm16(sampleRate: output.sampleRate, channels: output.channels),
                                               to: .compressed(kAudioFormatOpus, sampleRate: output.sampleRate, channels: output.channels,
                                                               framesPerPacket: output.sampleRate / 50),
                                               bitrate: output.bitrate)
            outputFormat = AudioFormat(codec: .opus, sampleRate: output.sampleRate, channels: output.channels)
        }
        if let encoder, encoder.output.mFramesPerPacket > 0 {
            let packetFrames = Int(encoder.output.mFramesPerPacket)
            let delay = encoder.leadingFrames
            primingPackets = (delay + packetFrames - 1) / packetFrames
            primingOffset = Int64(primingPackets * packetFrames - delay)
        } else {
            primingPackets = 0
            primingOffset = 0
        }
        primingPacketsLeft = primingPackets
    }

    func transcode(_ frame: EncodedAudioFrame) throws -> [EncodedAudioFrame] {
        guard !frame.data.isEmpty else { return [] }
        track(frame)
        let pcm = try decode(frame)
        return try emit(encode(resample(pcm, finishing: false), finishing: false))
    }

    func flush() throws -> [EncodedAudioFrame] {
        var pcm = try decoder?.finish().reduce(into: Data()) { $0.append($1.data) } ?? Data()
        pcm = try resample(pcm, finishing: true)
        let frames = try emit(encode(pcm, finishing: true))
        anchorPTS = nil
        produced = 0
        expectedInputPTS = nil
        primingPacketsLeft = primingPackets
        return frames
    }

    // MARK: - Stages

    private func decode(_ frame: EncodedAudioFrame) throws -> Data {
        switch input.codec {
        case .pcmu: return Self.pcmData(G711.decodeMuLaw(frame.data))
        case .pcma: return Self.pcmData(G711.decodeALaw(frame.data))
        case .linearPCM: return frame.data
        case .aac, .aacELD, .opus:
            guard let decoder else { return Data() }
            decoder.push(packet: frame.data)
            return try decoder.convert().reduce(into: Data()) { $0.append($1.data) }
        }
    }

    private func resample(_ pcm: Data, finishing: Bool) throws -> Data {
        guard let resampler else { return pcm }
        if !pcm.isEmpty { resampler.push(pcm: pcm) }
        let packets = finishing ? try resampler.finish() : try resampler.convert()
        return packets.reduce(into: Data()) { $0.append($1.data) }
    }

    /// Output payloads and their sample counts (the encoder's priming packets dropped).
    private func encode(_ pcm: Data, finishing: Bool) throws -> [AudioConverterStream.Packet] {
        if let encoder {
            if !pcm.isEmpty { encoder.push(pcm: pcm) }
            var packets = finishing ? try encoder.finish() : try encoder.convert()
            if primingPacketsLeft > 0 {
                let dropped = min(primingPacketsLeft, packets.count)
                packets.removeFirst(dropped)
                primingPacketsLeft -= dropped
            }
            return packets
        }
        pendingPCM.append(pcm)
        let bytesPerFrame = 2 * outputSettings.channels
        let chunkBytes = chunkFrames * bytesPerFrame
        var packets: [AudioConverterStream.Packet] = []
        var offset = pendingPCM.startIndex
        while pendingPCM.endIndex - offset >= chunkBytes || (finishing && pendingPCM.endIndex - offset >= bytesPerFrame) {
            let length = min(chunkBytes, (pendingPCM.endIndex - offset) / bytesPerFrame * bytesPerFrame)
            let chunk = pendingPCM[offset..<(offset + length)]
            packets.append(AudioConverterStream.Packet(data: outputPayload(chunk), frames: length / bytesPerFrame))
            offset += length
        }
        pendingPCM = finishing ? Data() : Data(pendingPCM[offset...])
        return packets
    }

    private func outputPayload(_ pcm: Data) -> Data {
        switch outputFormat.codec {
        case .pcmu: G711.encodeMuLaw(Self.samples(pcm))
        case .pcma: G711.encodeALaw(Self.samples(pcm))
        default: Data(pcm)
        }
    }

    // MARK: - Timeline

    /// Anchors the output timeline on the first frame and shifts it when the input jumps.
    private func track(_ frame: EncodedAudioFrame) {
        let rate = Int32(outputFormat.sampleRate)
        let inputRate = Int32(input.sampleRate)
        let pts = frame.pts.converted(to: inputRate)
        if anchorPTS == nil {
            anchorPTS = pts.converted(to: rate).value
            anchorWallClock = frame.wallClock
        } else if let expected = expectedInputPTS {
            let jump = pts.value - expected.value
            let tolerance = max(Int64(input.sampleRate / 10), 2 * Int64(inputSampleCount(frame)))
            if abs(jump) > tolerance {
                let shift = MediaTime(value: jump, timescale: inputRate).converted(to: rate).value
                anchorPTS = (anchorPTS ?? 0) + shift
                anchorWallClock = anchorWallClock.addingTimeInterval(Double(shift) / Double(rate))
            }
        }
        expectedInputPTS = MediaTime(value: pts.value + Int64(inputSampleCount(frame)), timescale: inputRate)
    }

    private func inputSampleCount(_ frame: EncodedAudioFrame) -> Int {
        if frame.sampleCount > 0 { return frame.sampleCount }
        switch input.codec {
        case .pcmu, .pcma: return frame.data.count / max(1, input.channels)
        case .linearPCM: return frame.data.count / max(1, 2 * input.channels)
        case .aac: return 1024
        case .aacELD: return 480
        case .opus: return OpusPacket.sampleCount(frame.data, sampleRate: input.sampleRate) ?? input.sampleRate / 50
        }
    }

    private func emit(_ packets: [AudioConverterStream.Packet]) -> [EncodedAudioFrame] {
        let rate = outputFormat.sampleRate
        return packets.compactMap { packet in
            guard !packet.data.isEmpty, packet.frames > 0 else { return nil }
            let offset = primingOffset + produced
            produced += Int64(packet.frames)
            return EncodedAudioFrame(format: outputFormat, data: packet.data, pts: MediaTime(value: (anchorPTS ?? 0) + offset, timescale: Int32(rate)),
                                     sampleCount: packet.frames, wallClock: anchorWallClock.addingTimeInterval(Double(offset) / Double(rate)))
        }
    }

    // MARK: - Helpers

    private static func pcmData(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func samples(_ pcm: Data) -> [Int16] {
        var samples = [Int16](repeating: 0, count: pcm.count / 2)
        _ = samples.withUnsafeMutableBytes { pcm.copyBytes(to: $0) }
        return samples
    }

    /// The stream format AudioToolbox derives from an ES_Descriptor (handles HE-AAC / ELD variants), if it can.
    private static func streamDescription(fromESDS cookie: Data) -> AudioStreamBasicDescription? {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = cookie.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kAudio_ParamError }
            return AudioFormatGetProperty(kAudioFormatProperty_ASBDFromESDS, UInt32(bytes.count), base, &size, &description)
        }
        guard status == noErr, description.mSampleRate > 0, description.mChannelsPerFrame > 0 else { return nil }
        return description
    }
}

/// Opus packet durations from the TOC byte (RFC 6716 §3.1).
enum OpusPacket {
    /// Samples at `sampleRate` in the packet, or nil if the packet is malformed (no TOC, a code-3 packet without its
    /// frame count, no frames, or more than 120 ms).
    static func sampleCount(_ packet: Data, sampleRate: Int) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        // Frame duration in units of 2.5 ms: SILK 10/20/40/60, hybrid 10/20, CELT 2.5/5/10/20 ms.
        let quarterUnits: Int = switch config {
        case 0...11: [4, 8, 16, 24][config % 4]
        case 12...15: [4, 8][config % 2]
        default: [1, 2, 4, 8][config % 4]
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count >= 2 else { return nil }
            frames = Int(packet[packet.startIndex + 1] & 0x3F)
        }
        // §3.2.5: at least one frame and at most 120 ms (48 × 2.5 ms) per packet.
        guard frames > 0, frames * quarterUnits <= 48 else { return nil }
        return frames * quarterUnits * sampleRate / 400
    }
}
#endif
