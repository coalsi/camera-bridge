import BridgeSupport
import Foundation
import MediaCore
import RTP

/// One depacketized video access unit.
struct VideoAccessUnit: Sendable {
    /// No start codes or length prefixes; parameter sets, AUDs, filler and end-of-sequence NALs removed.
    var nalUnits: [Data]
    var isKeyframe: Bool
    /// The keyframe is an IDR (H.264 type 5; HEVC IDR_W_RADL / IDR_N_LP): no later picture is presented before it.
    var isIDR = false
    var rtpTimestamp: UInt32
    var format: VideoFormat
}

/// RTP → access units for H.264 (RFC 6184: single NAL, STAP-A, FU-A) and H.265 (RFC 7798: single NAL, AP, FU,
/// optional DONL/DOND).
///
/// - An access unit ends where the codec says a picture ends, and also at the marker bit and when the RTP timestamp
///   changes. Cameras do not keep to RTP's rule of one timestamp and one marker per picture (a Tapo sends consecutive
///   pictures with the same timestamp, and marker bits on only some), and two pictures in one access unit are undecodable
///   (VideoToolbox: kVTVideoDecoderBadDataErr, -12909 on every delta frame). So a unit also ends before the first slice of
///   a new picture (H.264 first_mb_in_slice 0, HEVC first_slice_segment_in_pic_flag) and before an AUD, SPS, PPS or SEI
///   (HEVC: VPS, SPS, PPS, AUD, prefix SEI) that follows a slice (ITU-T H.264 §7.4.1.2.3). The timestamp and the marker
///   only end a unit that holds a slice: a SEI or parameter set stamped differently from its picture stays with it.
/// - H.264 SEI NAL units are dropped: a decoder does not need them, and cameras send malformed ones (a Tapo's vendor SEI
///   declares 34 bytes and carries 32) that other decoders and recorders would have to survive.
/// - Loss (a sequence gap, an FU without its start or end, a malformed aggregation packet) drops the access unit and
///   every following one until the next keyframe (IDR / IRAP); output also starts at a keyframe.
/// - A packet up to `lateWindow` behind the expected sequence number is late or a duplicate and ignored. Further
///   behind, or with a new SSRC and a sequence discontinuity, the sender restarted (encoder reconfiguration, a proxy
///   reconnecting upstream): the partial access unit is dropped and output resumes at the new stream's next keyframe.
/// - An access unit (including a fragmented NAL in reassembly) larger than `maxAccessUnitSize` is dropped like a
///   loss, so a sender that never ends a unit cannot grow memory without bound.
/// - Parameter sets come from the SDP and in band; a changed or new set yields a new `VideoFormat` on the following units.
///   H.264 keeps every SPS and PPS sent, by id (`H264ParameterSetStore`): pictures that refer to a second PPS decode only
///   if the format carries it.
/// - Camera quirk: a NAL that contains Annex B start codes (e.g. "SPS | start code | PPS | start code | IDR" packed
///   into one FU-A) is split. Emulation prevention guarantees `00 00 01` never occurs inside a real NAL unit.
struct VideoDepacketizer: Sendable {
    static let lateWindow: Int16 = 100
    /// Far above any real access unit (a 4K IDR is a few MiB).
    static let maxAccessUnitSize = 16 * 1024 * 1024

    let codec: VideoCodec
    /// RFC 7798 `sprop-max-don-diff` > 0: single NAL unit packets, aggregation packets and FU starts carry decoding
    /// order numbers.
    let hevcDONPresent: Bool
    private(set) var format: VideoFormat?
    private(set) var droppedAccessUnits = 0

    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    /// H.264: every SPS / PPS sent, by id (a stream may use several PPS: `H264ParameterSetStore`).
    private var h264Sets = H264ParameterSetStore()
    private var parameterSetsChanged = false

    private var pending: [Data] = []
    private var pendingSize = 0
    /// The unit in progress holds a slice (kept or not: a unit being dropped still ends where its picture ends).
    private var pendingHasSlice = false
    /// RTP timestamp of the unit in progress: that of the packet with its first slice (until it has one, of the latest packet).
    private var pendingTimestamp: UInt32?
    /// Timestamp of the packet being parsed.
    private var packetTimestamp: UInt32 = 0
    /// Units completed while parsing the current packet (a packet can end one unit and start the next).
    private var completed: [VideoAccessUnit] = []
    private var pendingKeyframe = false
    private var pendingIDR = false
    private var pendingCorrupt = false
    private var fragment: Data?
    private var expectedSequence: UInt16?
    private var ssrc: UInt32?
    private var waitingForKeyframe = true
    private var loggedUnsupported = false
    private var loggedOversize = false
    /// The session's (tagged with its camera).
    private let log: Log

    /// Bytes held for the access unit in progress.
    var bufferedByteCount: Int { pendingSize + (fragment?.count ?? 0) }

    init(codec: VideoCodec, format: VideoFormat?, hevcDONPresent: Bool = false, log: Log = Log(category: "rtsp")) {
        self.codec = codec
        self.log = log
        self.hevcDONPresent = hevcDONPresent
        if let format, format.codec == codec {
            self.format = format
            switch codec {
            case .h264 where format.parameterSets.count >= 2:
                h264Sets = H264ParameterSetStore(parameterSets: format.parameterSets)
            case .hevc where format.parameterSets.count >= 3:
                vps = format.parameterSets[0]
                sps = format.parameterSets[1]
                pps = format.parameterSets[2]
            default:
                break
            }
        }
    }

    mutating func push(_ packet: RTPPacket) -> [VideoAccessUnit] {
        var output: [VideoAccessUnit] = []
        if let expected = expectedSequence {
            let gap = Int16(bitPattern: packet.sequenceNumber &- expected)
            if gap < -Self.lateWindow || (packet.ssrc != ssrc && gap != 0) {
                resynchronize()
            } else if gap < 0 {
                return []   // duplicate or late packet
            } else if gap > 0 {
                markLoss()
            }
        }
        expectedSequence = packet.sequenceNumber &+ 1
        ssrc = packet.ssrc

        if let timestamp = pendingTimestamp, timestamp != packet.timestamp, pendingHasSlice || pendingCorrupt || fragment != nil {
            output += flush()
        }
        packetTimestamp = packet.timestamp
        if !pendingHasSlice { pendingTimestamp = packet.timestamp }

        switch codec {
        case .h264: parseH264(packet.payload)
        case .hevc: parseHEVC(packet.payload)
        }
        output += completed
        completed = []
        if packet.marker, pendingHasSlice || pendingCorrupt { output += flush() }
        return output
    }

    // MARK: Loss and flushing

    private mutating func markLoss() {
        pendingCorrupt = true
        fragment = nil
    }

    /// The sender restarted: forget the unit in progress and start over at the new stream's next keyframe.
    private mutating func resynchronize() {
        if !pending.isEmpty || fragment != nil || pendingCorrupt { droppedAccessUnits += 1 }
        pending = []
        pendingSize = 0
        pendingHasSlice = false
        pendingTimestamp = nil
        pendingKeyframe = false
        pendingIDR = false
        pendingCorrupt = false
        fragment = nil
        completed = []
        waitingForKeyframe = true
    }

    /// The unit in progress grew past `maxAccessUnitSize`: release it; it is dropped when it ends.
    private mutating func discardOversizeAccessUnit() {
        if !loggedOversize {
            loggedOversize = true
            log.warning("Dropping a \(codec.rawValue) access unit larger than \(Self.maxAccessUnitSize) bytes")
        }
        pending = []
        pendingSize = 0
        fragment = nil
        pendingCorrupt = true
    }

    private mutating func flush() -> [VideoAccessUnit] {
        defer {
            pending = []
            pendingSize = 0
            pendingHasSlice = false
            pendingTimestamp = nil
            pendingKeyframe = false
            pendingIDR = false
            pendingCorrupt = false
        }
        if fragment != nil {   // the access unit ended inside a fragmented NAL
            fragment = nil
            pendingCorrupt = true
        }
        guard pendingHasSlice || pendingCorrupt else { return [] }   // nothing but SEI / parameter sets so far: not a picture
        guard let timestamp = pendingTimestamp else { return [] }
        if pendingCorrupt || pending.isEmpty {
            drop()
            return []
        }
        if waitingForKeyframe && !pendingKeyframe {
            droppedAccessUnits += 1
            return []
        }
        if parameterSetsChanged { rebuildFormat() }
        guard let format else {
            drop()
            return []
        }
        waitingForKeyframe = false
        return [VideoAccessUnit(nalUnits: pending, isKeyframe: pendingKeyframe, isIDR: pendingIDR, rtpTimestamp: timestamp,
                                format: format)]
    }

    private mutating func drop() {
        droppedAccessUnits += 1
        waitingForKeyframe = true
    }

    private mutating func rebuildFormat() {
        switch codec {
        case .h264:
            guard let rebuilt = h264Sets.format else { return }
            format = rebuilt
        case .hevc:
            guard let vps, let sps, let pps else { return }
            format = RTSPSessionDescription.makeHEVCFormat(vps: vps, sps: sps, pps: pps)
        }
        parameterSetsChanged = false
    }

    // MARK: H.264 (RFC 6184)

    private mutating func parseH264(_ payload: Data) {
        let bytes = [UInt8](payload)
        guard let first = bytes.first else { pendingCorrupt = true; return }
        let type = first & 0x1F
        switch type {
        case 1...23:
            appendNAL(payload)
        case 24:   // STAP-A
            guard let units = Self.aggregatedUnits(bytes, headerLength: 1, donFields: false) else { pendingCorrupt = true; return }
            units.forEach { appendNAL($0) }
        case 28:   // FU-A
            guard bytes.count >= 2 else { pendingCorrupt = true; return }
            let fuHeader = bytes[1]
            let nalHeader = Data([(first & 0xE0) | (fuHeader & 0x1F)])
            reassemble(start: fuHeader & 0x80 != 0, end: fuHeader & 0x40 != 0, header: nalHeader, body: bytes[2...])
        default:   // STAP-B, MTAP, FU-B and reserved types
            logUnsupported(type)
            pendingCorrupt = true
        }
    }

    // MARK: H.265 (RFC 7798)

    private mutating func parseHEVC(_ payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else { pendingCorrupt = true; return }
        let type = (bytes[0] >> 1) & 0x3F
        switch type {
        case 0...47:
            if hevcDONPresent {   // PayloadHdr, DONL, NAL payload (RFC 7798 §4.4.1)
                guard bytes.count > 4 else { pendingCorrupt = true; return }
                var nal = Data(bytes[0..<2])
                nal.append(contentsOf: bytes[4...])
                appendNAL(nal)
            } else {
                appendNAL(payload)
            }
        case 48:   // aggregation packet
            guard let units = Self.aggregatedUnits(bytes, headerLength: 2, donFields: hevcDONPresent) else { pendingCorrupt = true; return }
            units.forEach { appendNAL($0) }
        case 49:   // fragmentation unit
            guard bytes.count >= 3 else { pendingCorrupt = true; return }
            let fuHeader = bytes[2]
            let start = fuHeader & 0x80 != 0
            var bodyStart = 3
            if start && hevcDONPresent { bodyStart += 2 }
            guard bytes.count >= bodyStart else { pendingCorrupt = true; return }
            let nalHeader = Data([(bytes[0] & 0x81) | ((fuHeader & 0x3F) << 1), bytes[1]])
            reassemble(start: start, end: fuHeader & 0x40 != 0, header: nalHeader, body: bytes[bodyStart...])
        default:   // PACI and reserved types
            logUnsupported(type)
            pendingCorrupt = true
        }
    }

    // MARK: Shared

    /// NAL units of an aggregation packet: `[DON…][size16][NAL]…`. nil when malformed.
    private static func aggregatedUnits(_ bytes: [UInt8], headerLength: Int, donFields: Bool) -> [Data]? {
        var units: [Data] = []
        var index = headerLength
        while index < bytes.count {
            if donFields { index += units.isEmpty ? 2 : 1 }
            guard index + 2 <= bytes.count else { return nil }
            let size = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            guard size > 0, index + size <= bytes.count else { return nil }
            units.append(Data(bytes[index..<(index + size)]))
            index += size
        }
        return units.isEmpty ? nil : units
    }

    private mutating func reassemble(start: Bool, end: Bool, header: Data, body: ArraySlice<UInt8>) {
        if start {
            if fragment != nil { pendingCorrupt = true }   // previous fragmented NAL never ended
            var nal = header
            nal.append(contentsOf: body)
            fragment = nal
        } else {
            guard fragment != nil else {
                pendingCorrupt = true   // start fragment missing
                return
            }
            fragment?.append(contentsOf: body)
        }
        if bufferedByteCount > Self.maxAccessUnitSize {
            discardOversizeAccessUnit()
            return
        }
        if end, let nal = fragment {
            fragment = nil
            appendNAL(nal)
        }
    }

    private mutating func appendNAL(_ nal: Data) {
        if Self.containsStartCode(nal) {
            var annexB = Data([0, 0, 0, 1])
            annexB.append(nal)
            NALUnits.splitAnnexB(annexB).forEach { appendSingleNAL($0) }
        } else {
            appendSingleNAL(nal)
        }
    }

    private mutating func appendSingleNAL(_ nal: Data) {
        guard !nal.isEmpty else { return }
        switch codec {
        case .h264:
            let type = NALUnits.h264Type(nal)
            switch type {
            case 1, 5:
                // The first slice of the next picture ends the unit in progress.
                if pendingHasSlice, NALUnits.h264FirstMBInSlice(nal) == 0 { completeAccessUnit() }
                startSlice()
                if type == 5 {
                    pendingKeyframe = true
                    pendingIDR = true
                }
                appendToPending(nal)
            case 6, 9, 14...18:   // SEI and AUD (both dropped), prefix NAL, subset SPS, reserved: these start an access unit
                if pendingHasSlice { completeAccessUnit() }
                if type != 6, type != 9 { appendToPending(nal) }
            case 7, 8:
                if pendingHasSlice { completeAccessUnit() }
                if h264Sets.add(nal) { parameterSetsChanged = true }
            case 10, 11, 12: break   // end of sequence/stream, filler
            default:
                appendToPending(nal)
            }
        case .hevc:
            guard nal.count >= 2 else { return }
            let type = NALUnits.hevcType(nal)
            switch type {
            case 0...31:
                if pendingHasSlice, NALUnits.hevcFirstSliceSegmentInPicture(nal) == true { completeAccessUnit() }
                startSlice()
                if (16...21).contains(type) { pendingKeyframe = true }
                if type == 19 || type == 20 { pendingIDR = true }
                appendToPending(nal)
            case 32, 33, 34:
                if pendingHasSlice { completeAccessUnit() }
                switch type {
                case 32: if vps != nal { vps = nal; parameterSetsChanged = true }
                case 33: if sps != nal { sps = nal; parameterSetsChanged = true }
                default: if pps != nal { pps = nal; parameterSetsChanged = true }
                }
            case 35:   // AUD
                if pendingHasSlice { completeAccessUnit() }
            case 36, 37, 38: break   // EOS, EOB, filler
            case 39, 41...44:   // prefix SEI, reserved: these start an access unit
                if pendingHasSlice { completeAccessUnit() }
                appendToPending(nal)
            default:
                appendToPending(nal)
            }
        }
    }

    /// The unit in progress is a whole picture: hand it over (or drop it) and start the next.
    private mutating func completeAccessUnit() {
        completed += flush()
    }

    /// A slice joins the unit in progress; the first one gives the unit its timestamp.
    private mutating func startSlice() {
        if !pendingHasSlice { pendingTimestamp = packetTimestamp }
        pendingHasSlice = true
    }

    private mutating func appendToPending(_ nal: Data) {
        guard !pendingCorrupt else { return }   // the unit is dropped when it ends: keep nothing
        pendingSize += nal.count
        if bufferedByteCount > Self.maxAccessUnitSize {
            discardOversizeAccessUnit()
            return
        }
        pending.append(nal)
    }

    private static func containsStartCode(_ nal: Data) -> Bool {
        var zeros = 0
        for byte in nal {
            if byte == 1, zeros >= 2 { return true }
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return false
    }

    private mutating func logUnsupported(_ type: UInt8) {
        guard !loggedUnsupported else { return }
        loggedUnsupported = true
        log.info("Unsupported \(codec.rawValue) RTP payload type \(type); dropping affected access units")
    }
}
