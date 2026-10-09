import Foundation
import MediaCore

/// RFC 6184 packetization mode 1 for HomeKit live video (research brief §3.6).
///
/// Per access unit: a STAP-A carrying the parameter sets first (NAL header 24 with F = NRI = 0 — HomeKit wants no NRI
/// aggregation), then every NAL unit as a single-NAL packet when it fits, else as FU-A fragments; all packets share
/// `rtpTimestamp` and only the last has the marker bit. Every serialized packet (12-byte header, no CSRCs) is at most
/// `maxPacketSize` bytes; values below 15 (header + FU-A header + 1 byte) are raised to 15.
///
/// Parameter sets: SPS/PPS found in the access unit (types 7/8) are moved into the STAP-A; otherwise keyframes use
/// `frame.format.parameterSets`. A STAP-A that would not fit is replaced by one packetization per parameter set.
/// Access unit delimiters (type 9) and empty NAL units are dropped; an access unit with nothing else yields no packets.
public struct H264Packetizer: Sendable {
    static let rtpHeaderSize = 12
    static let minimumPacketSize = rtpHeaderSize + 2 + 1
    static let stapA: UInt8 = 24
    static let fuA: UInt8 = 28

    private let payloadType: UInt8
    private let ssrc: UInt32
    private let maxPayloadSize: Int
    private var sequence: UInt16

    public init(payloadType: UInt8, ssrc: UInt32, maxPacketSize: Int = 1200, initialSequence: UInt16 = .random(in: 0...UInt16.max)) {
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.maxPayloadSize = max(maxPacketSize, Self.minimumPacketSize) - Self.rtpHeaderSize
        self.sequence = initialSequence
    }

    /// STAP-A(SPS,PPS) before every keyframe, single-NAL when it fits, else FU-A; marker on the last packet of the AU.
    public mutating func packetize(_ frame: EncodedVideoFrame, rtpTimestamp: UInt32) -> [RTPPacket] {
        var parameterSets: [Data] = []
        var body: [Data] = []
        for nal in frame.nalUnits {
            guard let header = nal.first else { continue }
            switch header & 0x1F {
            case 7, 8: parameterSets.append(Data(nal))
            case 9: continue
            default: body.append(Data(nal))
            }
        }
        guard !body.isEmpty else { return [] }
        if parameterSets.isEmpty, frame.isKeyframe {
            parameterSets = frame.format.parameterSets.filter { !$0.isEmpty }.map { Data($0) }
        }

        var payloads: [Data] = []
        if !parameterSets.isEmpty {
            if let aggregate = aggregationPacket(parameterSets) {
                payloads.append(aggregate)
            } else {
                for set in parameterSets { payloads.append(contentsOf: fragments(of: set)) }
            }
        }
        for nal in body { payloads.append(contentsOf: fragments(of: nal)) }

        var packets: [RTPPacket] = []
        packets.reserveCapacity(payloads.count)
        for (index, payload) in payloads.enumerated() {
            packets.append(RTPPacket(marker: index == payloads.count - 1, payloadType: payloadType, sequenceNumber: sequence, timestamp: rtpTimestamp,
                                     ssrc: ssrc, payload: payload))
            sequence &+= 1
        }
        return packets
    }

    /// STAP-A (RFC 6184 §5.7.1) with F = NRI = 0, or nil when it would exceed the payload limit.
    private func aggregationPacket(_ units: [Data]) -> Data? {
        let size = units.reduce(1) { $0 + 2 + $1.count }
        guard size <= maxPayloadSize, units.allSatisfy({ $0.count <= Int(UInt16.max) }) else { return nil }
        var payload = Data(capacity: size)
        payload.append(Self.stapA)
        for unit in units {
            payload.append(UInt8(unit.count >> 8))
            payload.append(UInt8(truncatingIfNeeded: unit.count))
            payload.append(unit)
        }
        return payload
    }

    /// The NAL itself when it fits, else FU-A fragments (RFC 6184 §5.8) that fill each packet.
    private func fragments(of nal: Data) -> [Data] {
        guard nal.count > maxPayloadSize, let header = nal.first else { return [nal] }
        let indicator = (header & 0xE0) | Self.fuA
        let type = header & 0x1F
        let chunk = maxPayloadSize - 2
        var result: [Data] = []
        var offset = nal.startIndex + 1
        while offset < nal.endIndex {
            let end = min(offset + chunk, nal.endIndex)
            var fuHeader = type
            if offset == nal.startIndex + 1 { fuHeader |= 0x80 }
            if end == nal.endIndex { fuHeader |= 0x40 }
            var fragment = Data(capacity: 2 + end - offset)
            fragment.append(indicator)
            fragment.append(fuHeader)
            fragment.append(nal[offset..<end])
            result.append(fragment)
            offset = end
        }
        return result
    }
}
