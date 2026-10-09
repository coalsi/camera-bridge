import BridgeSupport
import Foundation

/// One reception report block of an SR or RR (RFC 3550 §6.4.1): what the sender of the report received from `ssrc`.
/// A controller that gets none of our packets sends receiver reports without a block for our SSRC (or with the whole
/// fraction lost), which is how `ControllerReceptionMonitor` tells "alive but receiving nothing".
public struct RTCPReportBlock: Sendable, Equatable {
    /// The source this block reports on.
    public var ssrc: UInt32
    /// Fraction of packets lost since the previous report, in 1/256 (255 = all).
    public var fractionLost: UInt8
    /// Cumulative packets lost; a 24-bit signed value on the wire (negative with duplicates).
    public var cumulativeLost: Int32
    /// The highest sequence number received, with the cycle count in the upper 16 bits.
    public var extendedHighestSequence: UInt32
    public var jitter: UInt32
    /// The middle 32 bits of the NTP time of the last SR received from the source, 0 when none.
    public var lastSenderReport: UInt32
    /// Delay since that SR, in 1/65536 s.
    public var delaySinceLastSenderReport: UInt32

    public init(ssrc: UInt32, fractionLost: UInt8 = 0, cumulativeLost: Int32 = 0, extendedHighestSequence: UInt32 = 0, jitter: UInt32 = 0,
                lastSenderReport: UInt32 = 0, delaySinceLastSenderReport: UInt32 = 0) {
        self.ssrc = ssrc
        self.fractionLost = fractionLost
        self.cumulativeLost = cumulativeLost
        self.extendedHighestSequence = extendedHighestSequence
        self.jitter = jitter
        self.lastSenderReport = lastSenderReport
        self.delaySinceLastSenderReport = delaySinceLastSenderReport
    }

    static let size = 24
    /// The most a 24-bit signed `cumulativeLost` holds.
    static let cumulativeLostRange: ClosedRange<Int32> = -0x80_0000...0x7F_FFFF

    init(reader: inout ByteReader) throws {
        ssrc = try reader.readUInt32BE()
        fractionLost = try reader.readUInt8()
        let high = Int32(try reader.readUInt8()), middle = Int32(try reader.readUInt8()), low = Int32(try reader.readUInt8())
        var lost = high << 16 | middle << 8 | low
        if lost & 0x80_0000 != 0 { lost -= 0x100_0000 }   // sign-extend the 24-bit value
        cumulativeLost = lost
        extendedHighestSequence = try reader.readUInt32BE()
        jitter = try reader.readUInt32BE()
        lastSenderReport = try reader.readUInt32BE()
        delaySinceLastSenderReport = try reader.readUInt32BE()
    }

    func write(to writer: inout ByteWriter) {
        writer.writeUInt32BE(ssrc)
        writer.write(fractionLost)
        let lost = UInt32(bitPattern: min(max(cumulativeLost, Self.cumulativeLostRange.lowerBound), Self.cumulativeLostRange.upperBound)) & 0xFF_FFFF
        writer.write(UInt8(lost >> 16))
        writer.write(UInt8((lost >> 8) & 0xFF))
        writer.write(UInt8(lost & 0xFF))
        writer.writeUInt32BE(extendedHighestSequence)
        writer.writeUInt32BE(jitter)
        writer.writeUInt32BE(lastSenderReport)
        writer.writeUInt32BE(delaySinceLastSenderReport)
    }
}

/// The RTCP packets a HomeKit live stream uses (RFC 3550 §6.4 SR/RR, §6.6 BYE; RFC 4585 §6.3.1 PLI; RFC 5104 §4.3.1 FIR).
/// SDES items, BYE reasons and other feedback messages are skipped when parsing; SR and RR keep their report blocks (at
/// most 31, the RC field is 5 bits).
public enum RTCPPacket: Sendable, Equatable {
    case senderReport(ssrc: UInt32, ntp: UInt64, rtpTimestamp: UInt32, packetCount: UInt32, octetCount: UInt32, blocks: [RTCPReportBlock] = [])
    case receiverReport(ssrc: UInt32, blocks: [RTCPReportBlock] = [])
    case bye(ssrcs: [UInt32])
    case pictureLossIndication(senderSSRC: UInt32, mediaSSRC: UInt32)
    case fullIntraRequest(senderSSRC: UInt32, mediaSSRC: UInt32)
    /// Any other packet type (SDES 202, APP 204, RTPFB 205, other PSFB 206 formats, XR 207, …).
    case other(type: UInt8)

    static let typeSR: UInt8 = 200, typeRR: UInt8 = 201, typeSDES: UInt8 = 202, typeBYE: UInt8 = 203, typePSFB: UInt8 = 206

    /// Parses a (possibly single-packet) compound RTCP packet. Empty input is an empty compound. Throws
    /// `RTPError.invalidVersion`, `.truncated` (a length or count that does not fit) or `.invalidPadding`; never traps.
    public static func parseCompound(_ data: Data) throws -> [RTCPPacket] {
        var packets: [RTCPPacket] = []
        var reader = ByteReader(data)
        do {
            while !reader.isAtEnd {
                guard reader.remaining >= 4 else { throw RTPError.truncated }
                let first = try reader.readUInt8()
                guard first >> 6 == 2 else { throw RTPError.invalidVersion }
                let count = Int(first & 0x1F)
                let type = try reader.readUInt8()
                let length = Int(try reader.readUInt16BE()) * 4
                guard length <= reader.remaining else { throw RTPError.truncated }
                var body = try reader.readBytes(length)
                if first & 0x20 != 0 {
                    guard let padding = body.last.map(Int.init), padding >= 1, padding <= body.count else { throw RTPError.invalidPadding }
                    body.removeLast(padding)
                }
                packets.append(try parse(type: type, count: count, body: body))
            }
        } catch is ByteError {
            throw RTPError.truncated
        }
        return packets
    }

    private static func parse(type: UInt8, count: Int, body: Data) throws -> RTCPPacket {
        var reader = ByteReader(body)
        switch type {
        case typeSR:
            guard body.count >= 24 + 24 * count else { throw RTPError.truncated }
            return .senderReport(ssrc: try reader.readUInt32BE(), ntp: try reader.readUInt64BE(), rtpTimestamp: try reader.readUInt32BE(),
                                 packetCount: try reader.readUInt32BE(), octetCount: try reader.readUInt32BE(),
                                 blocks: try (0..<count).map { _ in try RTCPReportBlock(reader: &reader) })
        case typeRR:
            guard body.count >= 4 + 24 * count else { throw RTPError.truncated }
            return .receiverReport(ssrc: try reader.readUInt32BE(), blocks: try (0..<count).map { _ in try RTCPReportBlock(reader: &reader) })
        case typeBYE:
            guard body.count >= 4 * count else { throw RTPError.truncated }
            return .bye(ssrcs: try (0..<count).map { _ in try reader.readUInt32BE() })
        case typePSFB where count == 1:
            return .pictureLossIndication(senderSSRC: try reader.readUInt32BE(), mediaSSRC: try reader.readUInt32BE())
        case typePSFB where count == 4:
            let sender = try reader.readUInt32BE()
            let headerMedia = try reader.readUInt32BE()
            // RFC 5104: the header's media source SSRC is 0; the target is the first FCI entry's SSRC.
            let target = reader.remaining >= 8 ? try reader.readUInt32BE() : headerMedia
            return .fullIntraRequest(senderSSRC: sender, mediaSSRC: target)
        default:
            return .other(type: type)
        }
    }

    /// One RTCP packet without padding. BYE carries at most 31 SSRCs (the SC field is 5 bits); FIR uses sequence
    /// number 0; `.other` is a bare 4-byte header.
    public func serialized() -> Data {
        var writer = ByteWriter()
        func header(count: Int, type: UInt8, words: Int) {
            writer.write(0x80 | UInt8(count & 0x1F))
            writer.write(type)
            writer.writeUInt16BE(UInt16(words))
        }
        switch self {
        case let .senderReport(ssrc, ntp, rtpTimestamp, packetCount, octetCount, blocks):
            let listed = blocks.prefix(31)
            header(count: listed.count, type: Self.typeSR, words: 6 + 6 * listed.count)
            writer.writeUInt32BE(ssrc)
            writer.writeUInt64BE(ntp)
            writer.writeUInt32BE(rtpTimestamp)
            writer.writeUInt32BE(packetCount)
            writer.writeUInt32BE(octetCount)
            for block in listed { block.write(to: &writer) }
        case let .receiverReport(ssrc, blocks):
            let listed = blocks.prefix(31)
            header(count: listed.count, type: Self.typeRR, words: 1 + 6 * listed.count)
            writer.writeUInt32BE(ssrc)
            for block in listed { block.write(to: &writer) }
        case let .bye(ssrcs):
            let listed = ssrcs.prefix(31)
            header(count: listed.count, type: Self.typeBYE, words: listed.count)
            for ssrc in listed { writer.writeUInt32BE(ssrc) }
        case let .pictureLossIndication(senderSSRC, mediaSSRC):
            header(count: 1, type: Self.typePSFB, words: 2)
            writer.writeUInt32BE(senderSSRC)
            writer.writeUInt32BE(mediaSSRC)
        case let .fullIntraRequest(senderSSRC, mediaSSRC):
            header(count: 4, type: Self.typePSFB, words: 4)
            writer.writeUInt32BE(senderSSRC)
            writer.writeUInt32BE(0)
            writer.writeUInt32BE(mediaSSRC)
            writer.writeUInt32BE(0)   // seq nr 0 + 24 reserved bits
        case let .other(type):
            header(count: 0, type: type, words: 0)
        }
        return writer.data
    }
}
