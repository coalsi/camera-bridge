import BridgeSupport
import Foundation
import MediaCore
import RTP

/// One depacketized audio access unit.
struct AudioAccessUnit: Sendable, Equatable {
    var data: Data
    var rtpTimestamp: UInt32
    /// Samples per channel.
    var sampleCount: Int
}

/// RTP → audio access units for G.711 (one frame per packet) and MPEG-4 audio in RFC 3640 `mpeg4-generic`
/// (AAC-hbr / AAC-lbr and generic header layouts: several AUs per packet, or one AU fragmented over packets).
///
/// Late packets (up to `VideoDepacketizer.lateWindow` behind) are ignored; a larger backwards jump or a new SSRC with
/// a sequence discontinuity is a restarted sender and resynchronises at once. Access units larger than
/// `maxAccessUnitSize` are dropped (a fragment is never buffered past it).
struct AudioDepacketizer: Sendable {
    /// Far above any real audio access unit (an AAC frame is at most 6144 bits per channel).
    static let maxAccessUnitSize = 256 * 1024

    enum Kind: Sendable { case g711(channels: Int), mpeg4Generic(AUHeaderLayout) }

    /// RFC 3640 §3.2.1 AU header section layout from the fmtp parameters.
    struct AUHeaderLayout: Sendable {
        var sizeLength = 0
        var indexLength = 0
        var indexDeltaLength = 0
        var ctsDeltaLength = 0
        var dtsDeltaLength = 0
        var randomAccessIndication = false
        var streamStateIndication = 0
        var auxiliaryDataSizeLength = 0
        var constantSize = 0
        var samplesPerUnit = 1024

        var hasHeaders: Bool {
            sizeLength > 0 || indexLength > 0 || indexDeltaLength > 0 || ctsDeltaLength > 0 || dtsDeltaLength > 0
                || randomAccessIndication || streamStateIndication > 0
        }
    }

    private struct Fragment {
        var timestamp: UInt32
        /// Announced AU size (0 without AU headers: the marker ends the unit).
        var size: Int
        var data: Data
        /// Grew past `maxAccessUnitSize`: its remaining packets are skipped and the unit is dropped.
        var discarded = false
    }

    let kind: Kind
    private var expectedSequence: UInt16?
    private var ssrc: UInt32?
    private var fragment: Fragment?

    /// Bytes held for a fragmented access unit.
    var bufferedByteCount: Int { fragment?.data.count ?? 0 }

    /// nil for encodings this module cannot depacketize, and for RFC 3640 parameters out of range (an AU header field
    /// over 32 bits, `constantsize` outside 0...`maxAccessUnitSize`).
    init?(track: RTSPTrack) {
        switch track.encoding {
        case "PCMU", "PCMA":
            kind = .g711(channels: max(1, track.channels))
        case "MPEG4-GENERIC":
            func value(_ key: String) -> Int { track.fmtp[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0 }
            var layout = AUHeaderLayout()
            layout.sizeLength = value("sizelength")
            layout.indexLength = value("indexlength")
            layout.indexDeltaLength = value("indexdeltalength")
            layout.ctsDeltaLength = value("ctsdeltalength")
            layout.dtsDeltaLength = value("dtsdeltalength")
            layout.randomAccessIndication = value("randomaccessindication") != 0
            layout.streamStateIndication = value("streamstateindication")
            layout.auxiliaryDataSizeLength = value("auxiliarydatasizelength")
            layout.constantSize = value("constantsize")
            if let hex = track.fmtp["config"], let config = Data(hex: hex), let parsed = AudioSpecificConfig(config) {
                layout.samplesPerUnit = parsed.objectType == AudioSpecificConfig.aacELD ? 480 : 1024
            }
            let lengths = [layout.sizeLength, layout.indexLength, layout.indexDeltaLength, layout.ctsDeltaLength, layout.dtsDeltaLength,
                           layout.streamStateIndication, layout.auxiliaryDataSizeLength]
            // The SDP is camera input: a negative or absurd constant AU size would reach the AU-size arithmetic below.
            guard lengths.allSatisfy({ (0...32).contains($0) }), (0...Self.maxAccessUnitSize).contains(layout.constantSize) else { return nil }
            kind = .mpeg4Generic(layout)
        default:
            return nil
        }
    }

    mutating func push(_ packet: RTPPacket) -> [AudioAccessUnit] {
        if let expected = expectedSequence {
            let gap = Int16(bitPattern: packet.sequenceNumber &- expected)
            let restarted = gap < -VideoDepacketizer.lateWindow || (packet.ssrc != ssrc && gap != 0)
            if gap < 0, !restarted { return [] }   // duplicate or late packet
            if gap != 0 { fragment = nil }         // loss or a restarted sender
        }
        expectedSequence = packet.sequenceNumber &+ 1
        ssrc = packet.ssrc
        switch kind {
        case .g711(let channels):
            guard !packet.payload.isEmpty else { return [] }
            return [AudioAccessUnit(data: packet.payload, rtpTimestamp: packet.timestamp, sampleCount: packet.payload.count / channels)]
        case .mpeg4Generic(let layout):
            return depacketizeMPEG4(packet, layout: layout)
        }
    }

    private mutating func depacketizeMPEG4(_ packet: RTPPacket, layout: AUHeaderLayout) -> [AudioAccessUnit] {
        let bytes = [UInt8](packet.payload)
        var offset = 0
        var headers: [(size: Int, index: Int)] = []
        if layout.hasHeaders {
            guard bytes.count >= 2 else { return dropFragment() }
            let headerBits = Int(bytes[0]) << 8 | Int(bytes[1])
            let headerBytes = (headerBits + 7) / 8
            guard headerBits > 0, bytes.count >= 2 + headerBytes else { return dropFragment() }
            var bits = BitReader(Array(bytes[2..<(2 + headerBytes)]))
            var consumed = 0
            while consumed < headerBits {
                let before = bits.position
                guard let size = bits.read(layout.sizeLength),
                      let index = bits.read(headers.isEmpty ? layout.indexLength : layout.indexDeltaLength) else { return dropFragment() }
                if layout.ctsDeltaLength > 0 {
                    guard let flag = bits.read(1) else { return dropFragment() }
                    if flag == 1, bits.read(layout.ctsDeltaLength) == nil { return dropFragment() }
                }
                if layout.dtsDeltaLength > 0 {
                    guard let flag = bits.read(1) else { return dropFragment() }
                    if flag == 1, bits.read(layout.dtsDeltaLength) == nil { return dropFragment() }
                }
                if layout.randomAccessIndication, bits.read(1) == nil { return dropFragment() }
                if layout.streamStateIndication > 0, bits.read(layout.streamStateIndication) == nil { return dropFragment() }
                consumed += bits.position - before
                guard bits.position > before else { return dropFragment() }
                let unitSize = layout.sizeLength > 0 ? size : layout.constantSize
                guard (0...Self.maxAccessUnitSize).contains(unitSize) else { return dropFragment() }
                headers.append((unitSize, index))
            }
            offset = 2 + headerBytes
        }
        if layout.auxiliaryDataSizeLength > 0 {
            var bits = BitReader(Array(bytes[offset...]))
            guard let auxBits = bits.read(layout.auxiliaryDataSizeLength) else { return dropFragment() }
            offset += (layout.auxiliaryDataSizeLength + auxBits + 7) / 8
        }
        guard offset <= bytes.count else { return dropFragment() }
        let data = bytes[offset...]

        // No AU header section: the whole payload is one AU (or a fragment when the marker is clear).
        guard !headers.isEmpty else {
            if var partial = fragment, partial.timestamp == packet.timestamp {
                if !partial.discarded {
                    if partial.data.count + data.count > Self.maxAccessUnitSize {
                        partial = Fragment(timestamp: partial.timestamp, size: 0, data: Data(), discarded: true)
                    } else {
                        partial.data.append(contentsOf: data)
                    }
                }
                fragment = packet.marker ? nil : partial
                return packet.marker && !partial.discarded ? [unit(partial.data, packet.timestamp, layout)] : []
            }
            if packet.marker {
                fragment = nil
                return data.isEmpty ? [] : [unit(Data(data), packet.timestamp, layout)]
            }
            fragment = Fragment(timestamp: packet.timestamp, size: 0, data: Data(data))
            return []
        }

        // One AU header whose size exceeds the data: a fragment (RFC 3640 §3.2.3).
        if headers.count == 1, headers[0].size > data.count {
            let size = headers[0].size
            if var partial = fragment, partial.timestamp == packet.timestamp, partial.size == size {
                partial.data.append(contentsOf: data)
                if partial.data.count == size {
                    fragment = nil
                    return [unit(partial.data, packet.timestamp, layout)]
                }
                guard partial.data.count < size else { return dropFragment() }
                fragment = partial
                return []
            }
            fragment = Fragment(timestamp: packet.timestamp, size: size, data: Data(data))
            return []
        }
        fragment = nil

        // Every size is in 0...maxAccessUnitSize and the running total stops at the payload size: no overflow.
        var total = 0
        for header in headers {
            total += header.size
            guard total <= data.count else { return [] }
        }
        guard total == data.count else { return [] }
        var units: [AudioAccessUnit] = []
        var cursor = data.startIndex
        var index = 0
        for (position, header) in headers.enumerated() {
            index = position == 0 ? 0 : index + 1 + header.index
            let timestamp = packet.timestamp &+ UInt32(truncatingIfNeeded: index * layout.samplesPerUnit)
            units.append(unit(Data(data[cursor..<(cursor + header.size)]), timestamp, layout))
            cursor += header.size
        }
        return units
    }

    private func unit(_ data: Data, _ timestamp: UInt32, _ layout: AUHeaderLayout) -> AudioAccessUnit {
        AudioAccessUnit(data: data, rtpTimestamp: timestamp, sampleCount: layout.samplesPerUnit)
    }

    private mutating func dropFragment() -> [AudioAccessUnit] {
        fragment = nil
        return []
    }
}

extension BitReader {
    /// An AU header field (RFC 3640 §3.2.1, at most 32 bits), nil past the end.
    fileprivate mutating func read(_ count: Int) -> Int? {
        guard count <= 32, let value = try? bits(count) else { return nil }
        return Int(value)
    }
}
