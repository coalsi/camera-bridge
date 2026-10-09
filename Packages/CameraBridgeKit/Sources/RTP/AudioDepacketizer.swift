import BridgeSupport
import Foundation
import MediaCore

/// Turns RTP audio packets (as `AudioPacketizer` writes them) back into `EncodedAudioFrame`s; used for HomeKit
/// return audio. Packets with another payload type (e.g. comfort noise, 13) or an empty payload are ignored, and
/// malformed RFC 3640 sections are dropped.
///
/// Timestamps are unwrapped to 64 bits relative to the first packet (`pts` 0, timescale = `clockRate`); each packet's
/// offset is taken from the signed 32-bit difference to the previous packet, so reordering and wraps stay small.
/// Formats: `clockRate` Hz, mono; AAC-ELD carries its AudioSpecificConfig (480-sample frames).
/// Sample counts: Opus `clockRate × packetTime`, AAC-ELD 480 and AAC 1024 per AU (AUs of one packet are spaced by
/// that count), G.711 one byte per sample, LPCM 16-bit.
public struct AudioDepacketizer: Sendable {
    private let format: AudioFormat
    private let payloadType: UInt8
    private let samplesPerPacket: Int
    private var last: (timestamp: UInt32, extended: Int64)?

    public init(codec: AudioCodec, payloadType: UInt8, clockRate: Int, packetTime: Duration) {
        let config = codec == .aacELD ? Self.aacELDConfig(sampleRate: clockRate, channels: 1) : nil
        format = AudioFormat(codec: codec, sampleRate: clockRate, channels: 1, audioSpecificConfig: config)
        self.payloadType = payloadType
        samplesPerPacket = max(0, Int((Double(clockRate) * packetTime.timeInterval).rounded()))
    }

    public mutating func depacketize(_ packet: RTPPacket, wallClock: Date = Date()) -> [EncodedAudioFrame] {
        guard packet.payloadType == payloadType, !packet.payload.isEmpty else { return [] }
        let units: [(data: Data, samples: Int)]
        switch format.codec {
        case .aac, .aacELD:
            guard let accessUnits = try? RFC3640.accessUnits(in: packet.payload) else { return [] }
            units = accessUnits.filter { !$0.isEmpty }.map { ($0, format.samplesPerFrame) }
        case .opus:
            units = [(packet.payload, samplesPerPacket)]
        case .pcmu, .pcma:
            units = [(packet.payload, packet.payload.count)]
        case .linearPCM:
            units = [(packet.payload, packet.payload.count / 2)]
        }
        guard !units.isEmpty else { return [] }

        let extended: Int64
        if let last {
            extended = last.extended + Int64(Int32(bitPattern: packet.timestamp &- last.timestamp))
        } else {
            extended = 0
        }
        last = (packet.timestamp, extended)

        let timescale = Int32(clamping: format.sampleRate)
        var offset: Int64 = 0
        return units.map { unit in
            defer { offset += Int64(unit.samples) }
            return EncodedAudioFrame(format: format, data: Data(unit.data), pts: MediaTime(value: extended + offset, timescale: timescale),
                                     sampleCount: unit.samples, wallClock: wallClock)
        }
    }

    /// AudioSpecificConfig for AAC-ELD, written by MediaCore's `AudioSpecificConfig.encoded` (ISO/IEC 14496-3 §1.6.2.1
    /// with the object-type escape: 31 + 7 = 39; ELDSpecificConfig: frameLengthFlag 1 (480 samples), no resilience
    /// flags, no LD-SBR, ELDEXT_TERM; epConfig 0). Nil for sample rates outside the sampling-frequency table or channel
    /// counts outside 1…7.
    static func aacELDConfig(sampleRate: Int, channels: Int) -> Data? {
        guard AudioSpecificConfig.frequencies.contains(sampleRate), (1...7).contains(channels) else { return nil }
        return AudioSpecificConfig(objectType: AudioSpecificConfig.aacELD, sampleRate: sampleRate, channelConfiguration: channels).encoded
    }
}
