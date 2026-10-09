#if os(macOS)
import AudioToolbox
import BridgeSupport
import Foundation
import MediaCore

private let log = Log(category: "AudioCodec")

/// A streaming AudioToolbox `AudioConverter` (PCM ↔ AAC / AAC-ELD / Opus, PCM → PCM resampling).
///
/// Input is queued with `push`; `convert()` pulls every output packet the queued input allows. When the queue runs dry
/// the input callback returns `needMoreInput` with no data, which makes `AudioConverterFillComplexBuffer` return what
/// it has while the converter keeps its internal state (partial frames, priming) for the next call. `finish()`
/// signals end of stream, drains the tail and resets the converter so it can be reused. Not thread-safe: the owner
/// serialises access.
final class AudioConverterStream {
    struct Packet {
        var data: Data
        var frames: Int
    }

    /// Returned by the input callback when no queued input is left (not an AudioToolbox code).
    static let needMoreInput: OSStatus = 0x6E6D_6F72   // 'nmor'

    let input: AudioStreamBasicDescription
    let output: AudioStreamBasicDescription
    private let converter: AudioConverterRef
    private let inputIsPCM: Bool
    private let outputIsPCM: Bool
    private var maximumOutputPacketSize: Int

    private var pcmQueue = Data()
    private var pcmOffset = 0
    private var packetQueue: [Packet] = []
    private var endOfStream = false
    /// Input was pushed since the last reset (an idle converter must not be drained: encoders emit a tail anyway).
    private var hasInput = false

    /// Memory handed to the converter from the input callback; it must stay valid until the next callback.
    private var callbackBuffer: UnsafeMutableRawPointer
    private var callbackCapacity: Int
    private let callbackDescription: UnsafeMutablePointer<AudioStreamPacketDescription>

    /// `decoderCookie`: magic cookie for compressed input (AAC: ES_Descriptor). `bitrate`: encoder bit rate (bit/s); a
    /// rate outside the encoder's applicable range is clamped into it (logged). Compressed input may declare
    /// `mFramesPerPacket` 0 (variable packet durations, e.g. Opus).
    init(from input: AudioStreamBasicDescription, to output: AudioStreamBasicDescription, decoderCookie: Data? = nil, bitrate: Int? = nil) throws {
        var source = input
        var destination = output
        var converter: AudioConverterRef?
        let status = AudioConverterNew(&source, &destination, &converter)
        guard status == noErr, let converter else { throw MediaCodecError.sessionFailed(status) }
        self.converter = converter
        self.input = input
        self.output = output
        inputIsPCM = input.mFormatID == kAudioFormatLinearPCM
        outputIsPCM = output.mFormatID == kAudioFormatLinearPCM
        callbackCapacity = 4_096
        callbackBuffer = UnsafeMutableRawPointer.allocate(byteCount: callbackCapacity, alignment: 16)
        callbackDescription = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        callbackDescription.initialize(to: AudioStreamPacketDescription())
        maximumOutputPacketSize = outputIsPCM ? Int(output.mBytesPerPacket) : 8_192

        // Every stored property is initialised, so a throw below runs deinit (which disposes the converter).
        if let decoderCookie, !decoderCookie.isEmpty {
            let result = decoderCookie.withUnsafeBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return kAudio_ParamError }
                return AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(bytes.count), base)
            }
            guard result == noErr else { throw MediaCodecError.sessionFailed(result) }
        }
        if let bitrate, bitrate > 0, !outputIsPCM {
            try Self.setBitRate(bitrate, on: converter)
        }
        if !outputIsPCM {
            var size = UInt32(MemoryLayout<UInt32>.size)
            var value: UInt32 = 0
            if AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &value) == noErr, value > 0 {
                maximumOutputPacketSize = Int(value)
            }
        }
    }

    deinit {
        AudioConverterDispose(converter)
        callbackBuffer.deallocate()
        callbackDescription.deallocate()
    }

    /// The encoder's magic cookie (AAC / AAC-ELD: an MPEG-4 ES_Descriptor), if it has one.
    var compressionMagicCookie: Data? {
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &size, nil) == noErr, size > 0 else { return nil }
        var cookie = Data(count: Int(size))
        let status = cookie.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kAudio_ParamError }
            return AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &size, base)
        }
        guard status == noErr else { return nil }
        return cookie.prefix(Int(size))
    }

    /// Samples of encoder delay (priming) before the first input sample appears in the decoded output
    /// (`kAudioConverterPrimeInfo.leadingFrames`: AAC-LC 2112, AAC-ELD about 256, Opus 6.5 ms); 0 if not reported.
    var leadingFrames: Int {
        var info = AudioConverterPrimeInfo()
        var size = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        guard AudioConverterGetProperty(converter, kAudioConverterPrimeInfo, &size, &info) == noErr else { return 0 }
        return Int(info.leadingFrames)
    }

    /// The encoder's bit rate (bit/s); nil for decoders and PCM converters.
    var encodeBitRate: Int? {
        guard !outputIsPCM else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioConverterGetProperty(converter, kAudioConverterEncodeBitRate, &size, &value) == noErr else { return nil }
        return Int(value)
    }

    /// Interleaved PCM in the input format.
    func push(pcm data: Data) {
        guard !data.isEmpty else { return }
        pcmQueue.append(data)
        hasInput = true
    }

    /// One compressed packet.
    func push(packet data: Data) {
        guard !data.isEmpty else { return }
        packetQueue.append(Packet(data: data, frames: 0))
        hasInput = true
    }

    func convert() throws -> [Packet] {
        try pull()
    }

    /// Converts the rest of the queued input, flushes the converter and resets it. Returns nothing if no input
    /// arrived since the last reset.
    func finish() throws -> [Packet] {
        guard hasInput else { return [] }
        endOfStream = true
        defer {
            endOfStream = false
            hasInput = false
            pcmQueue.removeAll()
            pcmOffset = 0
            packetQueue.removeAll()
            AudioConverterReset(converter)
        }
        return try pull()
    }

    // MARK: - Private

    private func pull() throws -> [Packet] {
        let capacity: UInt32 = outputIsPCM ? 4_096 : 16
        let byteCapacity = outputIsPCM ? Int(capacity) * Int(output.mBytesPerFrame) : Int(capacity) * maximumOutputPacketSize
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCapacity, alignment: 16)
        defer { buffer.deallocate() }
        let descriptions = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: Int(capacity))
        defer { descriptions.deallocate() }

        var packets: [Packet] = []
        while true {
            var count = capacity
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: output.mChannelsPerFrame, mDataByteSize: UInt32(byteCapacity), mData: buffer))
            let status = AudioConverterFillComplexBuffer(converter, { _, packetCount, data, descriptions, context in
                guard let context else { return kAudio_ParamError }
                return Unmanaged<AudioConverterStream>.fromOpaque(context).takeUnretainedValue().provideInput(packetCount, data, descriptions)
            }, Unmanaged.passUnretained(self).toOpaque(), &count, &list, outputIsPCM ? nil : descriptions)
            guard status == noErr || status == Self.needMoreInput else { throw MediaCodecError.sessionFailed(status) }
            if outputIsPCM {
                let bytes = Int(list.mBuffers.mDataByteSize)
                if bytes > 0 { packets.append(Packet(data: Data(bytes: buffer, count: bytes), frames: bytes / Int(output.mBytesPerFrame))) }
            } else {
                for index in 0..<Int(count) {
                    let description = descriptions[index]
                    let size = Int(description.mDataByteSize)
                    guard size > 0, Int(description.mStartOffset) + size <= byteCapacity else { continue }
                    let frames = description.mVariableFramesInPacket > 0 ? Int(description.mVariableFramesInPacket) : Int(output.mFramesPerPacket)
                    packets.append(Packet(data: Data(bytes: buffer + Int(description.mStartOffset), count: size), frames: frames))
                }
            }
            if status == Self.needMoreInput || count == 0 { break }
        }
        return packets
    }

    fileprivate func provideInput(_ packetCount: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutablePointer<AudioBufferList>,
                                  _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        if inputIsPCM {
            let bytesPerFrame = max(1, Int(input.mBytesPerFrame))
            let available = (pcmQueue.count - pcmOffset) / bytesPerFrame
            guard available > 0, packetCount.pointee > 0 else { return noInput(packetCount) }
            let frames = min(available, Int(packetCount.pointee))
            let bytes = frames * bytesPerFrame
            reserve(bytes)
            let start = pcmQueue.startIndex + pcmOffset
            pcmQueue.copyBytes(to: callbackBuffer.assumingMemoryBound(to: UInt8.self), from: start..<(start + bytes))
            pcmOffset += bytes
            if pcmOffset >= 65_536 {
                pcmQueue.removeFirst(pcmOffset)
                pcmOffset = 0
            }
            buffers[0] = AudioBuffer(mNumberChannels: input.mChannelsPerFrame, mDataByteSize: UInt32(bytes), mData: callbackBuffer)
            packetCount.pointee = UInt32(frames)
            return noErr
        }
        guard !packetQueue.isEmpty, packetCount.pointee > 0 else { return noInput(packetCount) }
        let packet = packetQueue.removeFirst()
        reserve(packet.data.count)
        packet.data.copyBytes(to: callbackBuffer.assumingMemoryBound(to: UInt8.self), count: packet.data.count)
        callbackDescription.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.data.count))
        descriptions?.pointee = callbackDescription
        buffers[0] = AudioBuffer(mNumberChannels: input.mChannelsPerFrame, mDataByteSize: UInt32(packet.data.count), mData: callbackBuffer)
        packetCount.pointee = 1
        return noErr
    }

    /// Sets `bitrate` clamped to the encoder's applicable range (rates in between are accepted), or the listed rate
    /// nearest to it if AudioToolbox still refuses. Clamping first matters: a refused rate leaves the converter
    /// failing every later call until a valid rate is set.
    private static func setBitRate(_ bitrate: Int, on converter: AudioConverterRef) throws {
        let applicable = applicableBitRates(converter)
        var target = bitrate
        if let lowest = applicable.min(), let highest = applicable.max() { target = min(max(bitrate, lowest), highest) }
        var status = set(target, on: converter)
        if status != noErr, let nearest = applicable.min(by: { abs($0 - target) < abs($1 - target) }), nearest != target {
            target = nearest
            status = set(target, on: converter)
        }
        guard status == noErr else { throw MediaCodecError.sessionFailed(status) }
        if target != bitrate { log.notice("encoder bit rate \(bitrate) bit/s is not offered; using \(target) bit/s") }
    }

    private static func set(_ bitrate: Int, on converter: AudioConverterRef) -> OSStatus {
        var value = UInt32(clamping: bitrate)
        return AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// The encoder's applicable bit rates (range bounds; AudioToolbox pads the list with zero entries).
    private static func applicableBitRates(_ converter: AudioConverterRef) -> [Int] {
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        guard count > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        let status = ranges.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kAudio_ParamError }
            return AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &size, base)
        }
        guard status == noErr else { return [] }
        return ranges.prefix(Int(size) / MemoryLayout<AudioValueRange>.size)
            .flatMap { [Int($0.mMinimum), Int($0.mMaximum)] }
            .filter { $0 > 0 }
    }

    private func noInput(_ packetCount: UnsafeMutablePointer<UInt32>) -> OSStatus {
        packetCount.pointee = 0
        return endOfStream ? noErr : Self.needMoreInput
    }

    private func reserve(_ bytes: Int) {
        guard bytes > callbackCapacity else { return }
        callbackBuffer.deallocate()
        callbackCapacity = max(bytes, 2 * callbackCapacity)
        callbackBuffer = UnsafeMutableRawPointer.allocate(byteCount: callbackCapacity, alignment: 16)
    }
}

extension AudioStreamBasicDescription {
    /// Interleaved signed 16-bit native-endian PCM.
    static func pcm16(sampleRate: Int, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                    mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    }

    /// A compressed format with a fixed packet duration.
    static func compressed(_ formatID: AudioFormatID, sampleRate: Int, channels: Int, framesPerPacket: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: formatID, mFormatFlags: 0, mBytesPerPacket: 0,
                                    mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                                    mBitsPerChannel: 0, mReserved: 0)
    }
}
#endif
