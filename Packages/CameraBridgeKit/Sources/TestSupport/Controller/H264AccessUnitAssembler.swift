import Foundation
import MediaCore
import RTP

/// One H.264 access unit reassembled from RTP (RFC 6184 packetization mode 1).
public struct ReceivedVideoFrame: Sendable {
    /// NAL units without start codes, in order (SPS/PPS from a STAP-A included).
    public var nalUnits: [Data]
    public var rtpTimestamp: UInt32
    public var ssrc: UInt32
    public var payloadType: UInt8
    public var firstSequenceNumber: UInt16
    public var lastSequenceNumber: UInt16
    public var packetCount: Int
    /// No packet of this access unit was lost and every FU-A was whole.
    public var isComplete: Bool
    /// The access unit ended with the RTP marker bit (rather than a timestamp change).
    public var hadMarker: Bool
    public var receivedAt: ContinuousClock.Instant

    public var nalTypes: [UInt8] { nalUnits.compactMap { $0.first.map { $0 & 0x1F } } }
    /// Contains an IDR slice (NAL type 5).
    public var isKeyframe: Bool { nalTypes.contains(5) }
    public var sps: Data? { nalUnits.first { ($0.first ?? 0) & 0x1F == 7 } }
    public var pps: Data? { nalUnits.first { ($0.first ?? 0) & 0x1F == 8 } }
    /// The picture NAL units (everything but SPS, PPS, AUD, SEI).
    public var sliceNALUnits: [Data] { nalUnits.filter { ![6, 7, 8, 9].contains(($0.first ?? 0) & 0x1F) } }

    /// Annex B: every NAL unit behind a 4-byte start code (what `cbctl live` writes).
    public var annexB: Data {
        var out = Data()
        for nal in nalUnits {
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(nal)
        }
        return out
    }

    /// As a MediaCore frame (slices only; pts from the 90 kHz RTP timestamp relative to `baseTimestamp`).
    public func encodedFrame(format: VideoFormat, baseTimestamp: UInt32) -> EncodedVideoFrame {
        let ticks = Int64(Int32(bitPattern: rtpTimestamp &- baseTimestamp))
        return EncodedVideoFrame(format: format, nalUnits: sliceNALUnits, isKeyframe: isKeyframe, pts: MediaTime(value: ticks, timescale: 90_000),
                                 wallClock: Date())
    }
}

/// Depacketizes H.264 RTP (single NAL 1–23, STAP-A 24, FU-A 28) into access units. An access unit ends at the marker
/// bit or when the timestamp changes; a sequence gap or a broken FU-A marks it incomplete. A gap at a timestamp change
/// while a unit is still open (its marker packet not seen) cannot be attributed — the lost packets may be that unit's
/// tail or the next unit's head — so both units are marked incomplete. STAP-B/MTAP/FU-B (25–27, 29) are not used by
/// HomeKit and mark the unit incomplete.
public struct H264AccessUnitAssembler: Sendable {
    private var current: ReceivedVideoFrame?
    private var fragment: Data?
    private var lastSequence: UInt16?
    public private(set) var sequenceGaps = 0
    public private(set) var unsupportedPackets = 0

    public init() {}

    /// Feeds one RTP packet; returns the access units it completed.
    public mutating func push(_ packet: RTPPacket, receivedAt: ContinuousClock.Instant = .now) -> [ReceivedVideoFrame] {
        var completed: [ReceivedVideoFrame] = []
        let gap = lastSequence.map { packet.sequenceNumber != $0 &+ 1 } ?? false
        lastSequence = packet.sequenceNumber
        if gap { sequenceGaps += 1 }

        if var open = current, open.rtpTimestamp != packet.timestamp {
            // Ends without its marker; with a gap here its own last packet(s) may be the lost ones.
            if fragment != nil || gap { open.isComplete = false }
            completed.append(open)
            current = nil
            fragment = nil
        }
        if current == nil {
            current = ReceivedVideoFrame(nalUnits: [], rtpTimestamp: packet.timestamp, ssrc: packet.ssrc, payloadType: packet.payloadType,
                                         firstSequenceNumber: packet.sequenceNumber, lastSequenceNumber: packet.sequenceNumber, packetCount: 0,
                                         isComplete: true, hadMarker: false, receivedAt: receivedAt)
        }
        guard var unit = current else { return completed }
        if gap {
            unit.isComplete = false
            fragment = nil
        }
        unit.packetCount += 1
        unit.lastSequenceNumber = packet.sequenceNumber
        unit.receivedAt = receivedAt

        let payload = [UInt8](packet.payload)
        if let header = payload.first {
            let type = header & 0x1F
            switch type {
            case 1...23:
                unit.nalUnits.append(packet.payload)
            case 24:
                var offset = 1
                while offset + 2 <= payload.count {
                    let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                    offset += 2
                    guard size > 0, offset + size <= payload.count else {
                        unit.isComplete = false
                        break
                    }
                    unit.nalUnits.append(Data(payload[offset..<(offset + size)]))
                    offset += size
                }
            case 28:
                guard payload.count >= 2 else {
                    unit.isComplete = false
                    break
                }
                let fuHeader = payload[1]
                let start = fuHeader & 0x80 != 0
                let end = fuHeader & 0x40 != 0
                let body = payload[2...]
                if start {
                    if fragment != nil { unit.isComplete = false }
                    fragment = Data([(header & 0xE0) | (fuHeader & 0x1F)]) + Data(body)
                } else if fragment != nil {
                    fragment?.append(contentsOf: body)
                } else {
                    unit.isComplete = false
                }
                if end, let whole = fragment {
                    unit.nalUnits.append(whole)
                    fragment = nil
                }
            default:
                unsupportedPackets += 1
                unit.isComplete = false
            }
        } else {
            unit.isComplete = false
        }

        if packet.marker {
            if fragment != nil {
                unit.isComplete = false
                fragment = nil
            }
            unit.hadMarker = true
            completed.append(unit)
            current = nil
        } else {
            current = unit
        }
        return completed
    }

    /// The unit still being assembled (e.g. at the end of a capture), if any.
    public mutating func flush() -> ReceivedVideoFrame? {
        defer {
            current = nil
            fragment = nil
        }
        guard var unit = current else { return nil }
        if fragment != nil { unit.isComplete = false }
        return unit
    }
}
