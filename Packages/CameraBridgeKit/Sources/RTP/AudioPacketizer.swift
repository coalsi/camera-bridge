import BridgeSupport
import Foundation
import MediaCore

/// One audio frame per RTP packet.
/// - Opus (RFC 7587), G.711 and LPCM: the frame bytes as the payload; marker only on the first packet (start of the
///   talkspurt, RFC 3551 §4.1 — no DTX is signalled afterwards).
/// - AAC-ELD and AAC (RFC 3640 AAC-hbr: sizeLength 13, indexLength 3): AU-headers-length = 16, one 2-byte AU header
///   (13-bit AU size, 3-bit AU-index 0), then the AU; marker on every packet (each carries a complete AU). The size
///   field cannot describe more than 8191 bytes, so longer frames are cut there.
/// Sequence numbers advance by one per packet and wrap.
public struct AudioPacketizer: Sendable {
    private let codec: AudioCodec
    private let payloadType: UInt8
    private let ssrc: UInt32
    private var sequence: UInt16
    private var sentFirstPacket = false

    public init(codec: AudioCodec, payloadType: UInt8, ssrc: UInt32, initialSequence: UInt16 = .random(in: 0...UInt16.max)) {
        self.codec = codec
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.sequence = initialSequence
    }

    public mutating func packetize(_ frame: EncodedAudioFrame, rtpTimestamp: UInt32) -> RTPPacket {
        let payload: Data
        let marker: Bool
        switch codec {
        case .aac, .aacELD:
            payload = RFC3640.payload(for: frame.data)
            marker = true
        case .opus, .pcmu, .pcma, .linearPCM:
            payload = Data(frame.data)
            marker = !sentFirstPacket
        }
        sentFirstPacket = true
        defer { sequence &+= 1 }
        return RTPPacket(marker: marker, payloadType: payloadType, sequenceNumber: sequence, timestamp: rtpTimestamp, ssrc: ssrc, payload: payload)
    }
}

/// RFC 3640 AU header section with sizeLength 13 / indexLength 3 / indexDeltaLength 3 (AAC-hbr, as HomeKit uses
/// for AAC-ELD).
enum RFC3640 {
    static let maximumAccessUnitSize = 0x1FFF

    static func payload(for accessUnit: Data) -> Data {
        let unit = accessUnit.prefix(maximumAccessUnitSize)
        let header = UInt16(unit.count) << 3
        var payload = Data(capacity: 4 + unit.count)
        payload.append(contentsOf: [0x00, 0x10, UInt8(header >> 8), UInt8(truncatingIfNeeded: header)])
        payload.append(unit)
        return payload
    }

    /// The access units of one packet. Throws `RTPError.truncated` when the header section or an AU does not fit.
    static func accessUnits(in payload: Data) throws -> [Data] {
        var reader = ByteReader(payload)
        do {
            let headerBits = Int(try reader.readUInt16BE())
            var sizes: [Int] = []
            var headerReader = ByteReader(try reader.readBytes((headerBits + 7) / 8))
            for _ in 0..<(headerBits / 16) {
                sizes.append(Int(try headerReader.readUInt16BE() >> 3))
            }
            return try sizes.map { try reader.readBytes($0) }
        } catch is ByteError {
            throw RTPError.truncated
        }
    }
}
