import Foundation
import MediaCore
import RTP

/// RTP packetization for the ONVIF audio backchannel (client → camera): G.711 in packets of at most
/// `maxPayload` bytes, AAC as RFC 3640 AAC-hbr (one AU per packet). RTP timestamps advance by the samples sent
/// (a continuous talk spurt; the marker bit is set on its first packet), so callers need not provide exact pts.
struct BackchannelPacketizer: Sendable {
    let format: AudioFormat
    let payloadType: UInt8
    let ssrc: UInt32
    let clockRate: Int
    let maxPayload: Int
    private var sequence: UInt16
    private var timestamp: UInt32
    private var started = false

    init(format: AudioFormat, payloadType: UInt8, clockRate: Int, ssrc: UInt32 = .random(in: 1...UInt32.max), maxPayload: Int = 1024) {
        self.format = format
        self.payloadType = payloadType
        self.clockRate = clockRate > 0 ? clockRate : format.sampleRate
        self.ssrc = ssrc
        self.maxPayload = max(1, maxPayload)
        sequence = .random(in: 0...UInt16.max)
        timestamp = .random(in: 0...UInt32.max)
    }

    /// Throws `RTSPError.unsupportedCodec` when the frame's codec or sample rate is not the backchannel's.
    mutating func packetize(_ frame: EncodedAudioFrame) throws -> [RTPPacket] {
        guard frame.format.codec == format.codec else { throw RTSPError.unsupportedCodec(frame.format.codec.rawValue) }
        guard frame.format.sampleRate == format.sampleRate else {
            throw RTSPError.unsupportedCodec("\(frame.format.codec.rawValue)@\(frame.format.sampleRate)")
        }
        guard !frame.data.isEmpty else { return [] }
        var packets: [RTPPacket] = []
        switch format.codec {
        case .pcmu, .pcma:
            let channels = max(1, format.channels)
            var offset = frame.data.startIndex
            while offset < frame.data.endIndex {
                let end = min(offset + maxPayload - maxPayload % channels, frame.data.endIndex)
                let chunk = Data(frame.data[offset..<max(end, offset + 1)])
                packets.append(next(chunk, samples: chunk.count / channels))
                offset += chunk.count
            }
        case .aac:
            // AAC-hbr: the 13-bit AU size field limits an access unit to 8191 bytes (real AAC frames are far smaller).
            guard frame.data.count <= 0x1FFF else { throw RTSPError.protocolError("AAC frame of \(frame.data.count) bytes exceeds AAC-hbr") }
            var payload = Data([0x00, 0x10])
            let header = UInt16(truncatingIfNeeded: frame.data.count << 3)
            payload.append(UInt8(header >> 8))
            payload.append(UInt8(header & 0xFF))
            payload.append(frame.data)
            let samples = Int64(frame.sampleCount > 0 ? frame.sampleCount : 1024)
            let ticks = samples.clampedMultiplied(by: Int64(clockRate)) / Int64(max(1, format.sampleRate))
            packets.append(next(payload, samples: Int(truncatingIfNeeded: ticks)))
        default:
            throw RTSPError.unsupportedCodec(format.codec.rawValue)
        }
        return packets
    }

    private mutating func next(_ payload: Data, samples: Int) -> RTPPacket {
        let packet = RTPPacket(marker: !started, payloadType: payloadType, sequenceNumber: sequence, timestamp: timestamp, ssrc: ssrc, payload: payload)
        started = true
        sequence &+= 1
        timestamp &+= UInt32(truncatingIfNeeded: samples)
        return packet
    }
}
