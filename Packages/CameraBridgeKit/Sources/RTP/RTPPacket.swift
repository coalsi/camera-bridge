import BridgeSupport
import Foundation

public enum RTPError: Error, Equatable, Sendable {
    case truncated
    case invalidVersion
    case invalidPadding
}

/// RTP fixed header + CSRCs + optional header extension (RFC 3550 §5.1, §5.3.1).
///
/// Every stored value is kept in its wire form, so `RTPPacket(parsing: p.serialized()) == p` for every packet
/// (padding aside, which `serialized()` never writes): `payloadType` keeps 7 bits, `csrcs` at most 15 entries, and the
/// header extension is canonicalised as described on `extensionProfile`.
public struct RTPPacket: Sendable, Equatable {
    public var marker: Bool
    /// 7 bits; higher bits are dropped on init and on assignment.
    public var payloadType: UInt8 {
        didSet { payloadType &= 0x7F }
    }
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    /// At most 15 (the CC field is 4 bits); extra entries are dropped on assignment.
    public var csrcs: [UInt32] {
        didSet { if csrcs.count > 15 { csrcs.removeLast(csrcs.count - 15) } }
    }
    /// Header extension "defined by profile" field. `extensionProfile` and `extensionData` are two views of one
    /// optional extension, so they are both nil or both non-nil: setting either to a value adds the extension
    /// (profile 0 / empty body if it was absent), setting either to nil removes it.
    public var extensionProfile: UInt16? {
        get { headerExtension?.profile }
        set {
            guard let newValue else { headerExtension = nil; return }
            headerExtension = HeaderExtension(profile: newValue, body: headerExtension?.body ?? Data())
        }
    }
    /// Header extension body, stored exactly as serialized: zero-padded to a multiple of 4 bytes and truncated to
    /// 65535 words (see `extensionProfile`).
    public var extensionData: Data? {
        get { headerExtension?.body }
        set {
            guard let newValue else { headerExtension = nil; return }
            headerExtension = HeaderExtension(profile: headerExtension?.profile ?? 0, body: newValue)
        }
    }
    public var payload: Data

    private var headerExtension: HeaderExtension?

    private struct HeaderExtension: Sendable, Equatable {
        static let maxBodyLength = Int(UInt16.max) * 4

        var profile: UInt16
        var body: Data

        init(profile: UInt16, body: Data) {
            var words = Data(body.prefix(Self.maxBodyLength))
            if words.count % 4 != 0 { words.append(Data(count: 4 - words.count % 4)) }
            self.profile = profile
            self.body = words
        }
    }

    public init(marker: Bool = false, payloadType: UInt8, sequenceNumber: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data) {
        self.marker = marker
        self.payloadType = payloadType & 0x7F
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.csrcs = []
        self.headerExtension = nil
        self.payload = payload
    }

    /// Parses a packet; padding (P bit) is removed from the payload.
    public init(parsing data: Data) throws {
        var reader = ByteReader(data)
        guard data.count >= 12 else { throw RTPError.truncated }
        let first = try reader.readUInt8()
        guard first >> 6 == 2 else { throw RTPError.invalidVersion }
        let hasPadding = first & 0x20 != 0
        let hasExtension = first & 0x10 != 0
        let csrcCount = Int(first & 0x0F)
        let second = try reader.readUInt8()
        marker = second & 0x80 != 0
        payloadType = second & 0x7F
        sequenceNumber = try reader.readUInt16BE()
        timestamp = try reader.readUInt32BE()
        ssrc = try reader.readUInt32BE()
        do {
            var csrcs: [UInt32] = []
            for _ in 0..<csrcCount { csrcs.append(try reader.readUInt32BE()) }
            self.csrcs = csrcs
            if hasExtension {
                let profile = try reader.readUInt16BE()
                let words = Int(try reader.readUInt16BE())
                headerExtension = HeaderExtension(profile: profile, body: try reader.readBytes(words * 4))
            } else {
                headerExtension = nil
            }
        } catch is ByteError {
            throw RTPError.truncated
        }
        var body = try reader.readBytes(reader.remaining)
        if hasPadding {
            guard let count = body.last.map(Int.init), count >= 1, count <= body.count else { throw RTPError.invalidPadding }
            body.removeLast(count)
        }
        payload = body
    }

    /// Serializes without padding.
    public func serialized() -> Data {
        var writer = ByteWriter()
        writer.write(0x80 | (headerExtension != nil ? 0x10 : 0) | UInt8(min(csrcs.count, 15)))
        writer.write((marker ? 0x80 : 0) | (payloadType & 0x7F))
        writer.writeUInt16BE(sequenceNumber)
        writer.writeUInt32BE(timestamp)
        writer.writeUInt32BE(ssrc)
        for csrc in csrcs.prefix(15) { writer.writeUInt32BE(csrc) }
        if let headerExtension {
            writer.writeUInt16BE(headerExtension.profile)
            writer.writeUInt16BE(UInt16(clamping: headerExtension.body.count / 4))
            writer.write(headerExtension.body)
        }
        writer.write(payload)
        return writer.data
    }

    /// RTP/RTCP multiplexing demux (RFC 5761 §4): true when the packet is version 2 and its second byte lies in
    /// 192–223 — the RTCP packet-type range, i.e. RTP payload types 64–95 with the marker bit. This covers
    /// SR/RR/SDES/BYE/APP (200–204) and the feedback messages RTPFB (205) and PSFB (206, PLI/FIR) that
    /// controllers send. Works on SRTCP too (its first 8 bytes are not encrypted).
    public static func isRTCP(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let first = data[data.startIndex]
        let type = data[data.startIndex + 1]
        return first >> 6 == 2 && (192...223).contains(type)
    }
}
