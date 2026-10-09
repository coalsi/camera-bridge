import BridgeSupport
import Foundation
import MediaCore
import RTP
import Testing
@testable import RTSP

/// Builds RTP packets for depacketizer tests (sequence numbers advance automatically).
struct PacketFactory {
    var sequence: UInt16
    var payloadType: UInt8 = 96

    init(sequence: UInt16 = 1000) { self.sequence = sequence }

    mutating func packet(_ payload: Data, timestamp: UInt32, marker: Bool = false) -> RTPPacket {
        defer { sequence &+= 1 }
        return RTPPacket(marker: marker, payloadType: payloadType, sequenceNumber: sequence, timestamp: timestamp, ssrc: 0x1234, payload: payload)
    }

    mutating func skip(_ count: UInt16 = 1) { sequence &+= count }
}

/// NAL payload bytes that never contain `00 00`.
func filler(_ count: Int, seed: UInt8 = 1) -> Data {
    Data((0..<count).map { UInt8((Int(seed) + $0) % 255 + 1) })
}

func h264NAL(type: UInt8, size: Int, seed: UInt8 = 1, nri: UInt8 = 0x60) -> Data {
    var nal = Data([nri | type])
    nal.append(filler(size - 1, seed: seed))
    return nal
}

/// STAP-A payload (RFC 6184 §5.7.1).
func stapA(_ nals: [Data]) -> Data {
    var payload = Data([0x78])
    for nal in nals {
        payload.append(UInt8(nal.count >> 8))
        payload.append(UInt8(nal.count & 0xFF))
        payload.append(nal)
    }
    return payload
}

/// FU-A fragments of `nal` with at most `chunk` payload bytes each (RFC 6184 §5.8).
func fuA(_ nal: Data, chunk: Int) -> [Data] {
    let header = nal[nal.startIndex]
    let body = nal.dropFirst()
    var fragments: [Data] = []
    var offset = body.startIndex
    while offset < body.endIndex {
        let end = min(offset + chunk, body.endIndex)
        var fu = UInt8(header & 0x1F)
        if offset == body.startIndex { fu |= 0x80 }
        if end == body.endIndex { fu |= 0x40 }
        var payload = Data([(header & 0xE0) | 28, fu])
        payload.append(body[offset..<end])
        fragments.append(payload)
        offset = end
    }
    return fragments
}

@Suite struct H264DepacketizerTests {
    let sps = RealParameterSets.h264Main640x360.sps
    let pps = RealParameterSets.h264Main640x360.pps

    @Test func singleNALUnitsWithInBandParameterSets() throws {
        var depacketizer = VideoDepacketizer(codec: .h264, format: nil)
        var factory = PacketFactory()
        let idr = h264NAL(type: 5, size: 300)
        let sei = h264NAL(type: 6, size: 20)
        var units: [VideoAccessUnit] = []
        units += depacketizer.push(factory.packet(Data([0x09, 0xF0]), timestamp: 3000))            // AUD (dropped)
        units += depacketizer.push(factory.packet(sps, timestamp: 3000))
        units += depacketizer.push(factory.packet(pps, timestamp: 3000))
        units += depacketizer.push(factory.packet(sei, timestamp: 3000))
        units += depacketizer.push(factory.packet(idr, timestamp: 3000, marker: true))
        let p = h264NAL(type: 1, size: 100, seed: 9, nri: 0x40)
        units += depacketizer.push(factory.packet(p, timestamp: 6000, marker: true))

        #expect(units.count == 2)
        #expect(units[0].isKeyframe)
        #expect(units[0].nalUnits == [idr])   // the SEI is dropped
        #expect(units[0].rtpTimestamp == 3000)
        #expect(units[0].format.width == 640)
        #expect(units[0].format.height == 360)
        #expect(units[0].format.parameterSets == [sps, pps])
        #expect(!units[1].isKeyframe)
        #expect(units[1].nalUnits == [p])
    }

    @Test func stapAAndFUAReassembly() throws {
        var depacketizer = VideoDepacketizer(codec: .h264, format: nil)
        var factory = PacketFactory(sequence: 65_534)   // wraps during the access unit
        let idr = h264NAL(type: 5, size: 5000)
        var units = depacketizer.push(factory.packet(stapA([sps, pps]), timestamp: 90_000))
        let fragments = fuA(idr, chunk: 1200)
        #expect(fragments.count == 5)
        for (index, fragment) in fragments.enumerated() {
            units += depacketizer.push(factory.packet(fragment, timestamp: 90_000, marker: index == fragments.count - 1))
        }
        #expect(units.count == 1)
        #expect(units.first?.nalUnits == [idr])
        #expect(units.first?.isKeyframe == true)
    }

    @Test func timestampChangeEndsAccessUnitWithoutMarker() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: RTSPSessionDescription.makeH264Format(sps: sps, pps: pps))
        var factory = PacketFactory()
        let idr = h264NAL(type: 5, size: 50)
        let p1 = h264NAL(type: 1, size: 50, seed: 3)
        var units = depacketizer.push(factory.packet(idr, timestamp: 0))
        #expect(units.isEmpty)
        units += depacketizer.push(factory.packet(p1, timestamp: 3000))
        #expect(units.count == 1)
        #expect(units.first?.nalUnits == [idr])
        units += depacketizer.push(factory.packet(h264NAL(type: 1, size: 50, seed: 4), timestamp: 6000))
        #expect(units.count == 2)
        #expect(units[1].nalUnits == [p1])
        #expect(units[1].rtpTimestamp == 3000)
    }

    @Test func missingFragmentDropsUntilNextIDR() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: RTSPSessionDescription.makeH264Format(sps: sps, pps: pps))
        var factory = PacketFactory()
        var delivered: [VideoAccessUnit] = []

        let idr1 = h264NAL(type: 5, size: 3000, seed: 1)
        for (i, fragment) in fuA(idr1, chunk: 1000).enumerated() {
            delivered += depacketizer.push(factory.packet(fragment, timestamp: 0, marker: i == 2))
        }
        // P frame with its middle fragment lost.
        let p1 = h264NAL(type: 1, size: 3000, seed: 2)
        for (i, fragment) in fuA(p1, chunk: 1000).enumerated() {
            if i == 1 { factory.skip(); continue }
            delivered += depacketizer.push(factory.packet(fragment, timestamp: 3000, marker: i == 2))
        }
        // Intact P frame: still dropped (its reference is gone).
        delivered += depacketizer.push(factory.packet(h264NAL(type: 1, size: 100, seed: 3), timestamp: 6000, marker: true))
        // Next IDR recovers.
        let idr2 = h264NAL(type: 5, size: 200, seed: 4)
        delivered += depacketizer.push(factory.packet(idr2, timestamp: 9000, marker: true))
        let p3 = h264NAL(type: 1, size: 100, seed: 5)
        delivered += depacketizer.push(factory.packet(p3, timestamp: 12_000, marker: true))

        #expect(delivered.map(\.nalUnits) == [[idr1], [idr2], [p3]])
        #expect(depacketizer.droppedAccessUnits == 2)
    }

    @Test func missingStartFragmentIsDetectedWithoutSequenceGap() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: RTSPSessionDescription.makeH264Format(sps: sps, pps: pps))
        var factory = PacketFactory()
        var delivered = depacketizer.push(factory.packet(h264NAL(type: 5, size: 50), timestamp: 0, marker: true))
        // A camera that skipped the FU start without a sequence gap.
        let fragments = fuA(h264NAL(type: 1, size: 2000, seed: 7), chunk: 1000)
        delivered += depacketizer.push(factory.packet(fragments[1], timestamp: 3000, marker: true))
        delivered += depacketizer.push(factory.packet(h264NAL(type: 1, size: 50, seed: 8), timestamp: 6000, marker: true))
        #expect(delivered.count == 1)
    }

    @Test func framesBeforeFirstKeyframeAreDropped() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: RTSPSessionDescription.makeH264Format(sps: sps, pps: pps))
        var factory = PacketFactory()
        var delivered = depacketizer.push(factory.packet(h264NAL(type: 1, size: 50), timestamp: 0, marker: true))
        delivered += depacketizer.push(factory.packet(h264NAL(type: 5, size: 50), timestamp: 3000, marker: true))
        #expect(delivered.count == 1)
        #expect(delivered.first?.isKeyframe == true)
    }

    @Test func keyframeWithoutParameterSetsIsDropped() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: nil)
        var factory = PacketFactory()
        var delivered = depacketizer.push(factory.packet(h264NAL(type: 5, size: 50), timestamp: 0, marker: true))
        #expect(delivered.isEmpty)
        delivered += depacketizer.push(factory.packet(stapA([sps, pps]), timestamp: 3000))
        delivered += depacketizer.push(factory.packet(h264NAL(type: 5, size: 50), timestamp: 3000, marker: true))
        #expect(delivered.count == 1)
    }

    @Test func inBandParameterSetChangeUpdatesFormat() throws {
        var depacketizer = VideoDepacketizer(codec: .h264, format: RTSPSessionDescription.makeH264Format(sps: sps, pps: pps))
        var factory = PacketFactory()
        var delivered = depacketizer.push(factory.packet(h264NAL(type: 5, size: 50), timestamp: 0, marker: true))
        let big = RealParameterSets.h264High1080p
        delivered += depacketizer.push(factory.packet(stapA([big.sps, big.pps]), timestamp: 3000))
        delivered += depacketizer.push(factory.packet(h264NAL(type: 5, size: 50), timestamp: 3000, marker: true))
        #expect(delivered.count == 2)
        #expect(delivered[0].format.width == 640)
        #expect(delivered[1].format.width == 1920)
        #expect(delivered[1].format.height == 1080)
        #expect(delivered[1].format.parameterSets == [big.sps, big.pps])
    }

    @Test func parameterSetsAndIDRPackedInOneFUA() throws {
        // Camera quirk: "sps | start code | pps | start code | idr" inside a single FU-A NAL.
        var depacketizer = VideoDepacketizer(codec: .h264, format: nil)
        var factory = PacketFactory()
        let idr = h264NAL(type: 5, size: 2500)
        var packed = sps
        packed.append(contentsOf: [0, 0, 0, 1])
        packed.append(pps)
        packed.append(contentsOf: [0, 0, 1])
        packed.append(idr)
        var delivered: [VideoAccessUnit] = []
        let fragments = fuA(packed, chunk: 1000)
        for (i, fragment) in fragments.enumerated() {
            delivered += depacketizer.push(factory.packet(fragment, timestamp: 0, marker: i == fragments.count - 1))
        }
        #expect(delivered.count == 1)
        #expect(delivered.first?.nalUnits == [idr])
        #expect(delivered.first?.format.width == 640)
    }

    @Test func fillerAndDuplicatesAreIgnored() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: RTSPSessionDescription.makeH264Format(sps: sps, pps: pps))
        var factory = PacketFactory()
        let idr = h264NAL(type: 5, size: 50)
        let first = factory.packet(idr, timestamp: 0)
        var delivered = depacketizer.push(first)
        delivered += depacketizer.push(first)                                             // duplicate
        delivered += depacketizer.push(factory.packet(Data([0x0C, 0xFF, 0xFF]), timestamp: 0, marker: true))   // filler
        #expect(delivered.count == 1)
        #expect(delivered.first?.nalUnits == [idr])
    }

    @Test func malformedAggregationPacketDropsAccessUnit() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: RTSPSessionDescription.makeH264Format(sps: sps, pps: pps))
        var factory = PacketFactory()
        var delivered = depacketizer.push(factory.packet(Data([0x78, 0x10, 0x00, 0x65, 0x01]), timestamp: 0, marker: true))
        #expect(delivered.isEmpty)
        delivered += depacketizer.push(factory.packet(Data([0x1C]), timestamp: 3000, marker: true))   // truncated FU-A
        delivered += depacketizer.push(factory.packet(Data(), timestamp: 6000, marker: true))        // empty payload
        delivered += depacketizer.push(factory.packet(h264NAL(type: 5, size: 50), timestamp: 9000, marker: true))
        #expect(delivered.count == 1)
    }
}

// MARK: - HEVC

func hevcNAL(type: UInt8, size: Int, seed: UInt8 = 1) -> Data {
    var nal = Data([type << 1, 0x01])
    nal.append(filler(size - 2, seed: seed))
    return nal
}

/// HEVC aggregation packet (RFC 7798 §4.4.2), optionally with DONL/DOND.
func hevcAP(_ nals: [Data], don: Bool = false) -> Data {
    var payload = Data([48 << 1, 0x01])
    for (index, nal) in nals.enumerated() {
        if don { payload.append(contentsOf: index == 0 ? [0x00, 0x05] : [0x00]) }
        payload.append(UInt8(nal.count >> 8))
        payload.append(UInt8(nal.count & 0xFF))
        payload.append(nal)
    }
    return payload
}

/// HEVC fragmentation units (RFC 7798 §4.4.3).
func hevcFU(_ nal: Data, chunk: Int, don: Bool = false) -> [Data] {
    let bytes = [UInt8](nal)
    let type = (bytes[0] >> 1) & 0x3F
    let body = bytes[2...]
    var fragments: [Data] = []
    var offset = body.startIndex
    while offset < body.endIndex {
        let end = min(offset + chunk, body.endIndex)
        var fu = type
        if offset == body.startIndex { fu |= 0x80 }
        if end == body.endIndex { fu |= 0x40 }
        var payload = Data([(bytes[0] & 0x81) | (49 << 1), bytes[1], fu])
        if don, offset == body.startIndex { payload.append(contentsOf: [0x00, 0x07]) }
        payload.append(contentsOf: body[offset..<end])
        fragments.append(payload)
        offset = end
    }
    return fragments
}

@Suite struct HEVCDepacketizerTests {
    let sets = RealParameterSets.hevcMain640x360

    @Test func aggregationAndFragmentation() throws {
        var depacketizer = VideoDepacketizer(codec: .hevc, format: nil)
        var factory = PacketFactory()
        let idr = hevcNAL(type: 19, size: 4000)
        var delivered = depacketizer.push(factory.packet(hevcAP([sets.vps, sets.sps, sets.pps]), timestamp: 0))
        let fragments = hevcFU(idr, chunk: 1100)
        for (i, fragment) in fragments.enumerated() {
            delivered += depacketizer.push(factory.packet(fragment, timestamp: 0, marker: i == fragments.count - 1))
        }
        let trail = hevcNAL(type: 1, size: 300, seed: 5)
        delivered += depacketizer.push(factory.packet(trail, timestamp: 3000, marker: true))

        #expect(delivered.count == 2)
        #expect(delivered[0].isKeyframe)
        #expect(delivered[0].nalUnits == [idr])
        #expect(delivered[0].format.codec == .hevc)
        #expect(delivered[0].format.width == 640)
        #expect(delivered[0].format.height == 360)
        #expect(delivered[0].format.parameterSets == [sets.vps, sets.sps, sets.pps])
        #expect(!delivered[1].isKeyframe)
        #expect(delivered[1].nalUnits == [trail])
    }

    @Test func craIsAKeyframeAndLossWaitsForNextIRAP() {
        var depacketizer = VideoDepacketizer(codec: .hevc, format: RTSPSessionDescription.makeHEVCFormat(vps: sets.vps, sps: sets.sps, pps: sets.pps))
        var factory = PacketFactory()
        var delivered = depacketizer.push(factory.packet(hevcNAL(type: 21, size: 100), timestamp: 0, marker: true))   // CRA
        let lost = hevcFU(hevcNAL(type: 1, size: 3000, seed: 2), chunk: 1000)
        delivered += depacketizer.push(factory.packet(lost[0], timestamp: 3000))
        factory.skip()
        delivered += depacketizer.push(factory.packet(lost[2], timestamp: 3000, marker: true))
        delivered += depacketizer.push(factory.packet(hevcNAL(type: 1, size: 100, seed: 3), timestamp: 6000, marker: true))
        delivered += depacketizer.push(factory.packet(hevcNAL(type: 20, size: 100, seed: 4), timestamp: 9000, marker: true))  // IDR_N_LP
        #expect(delivered.map(\.isKeyframe) == [true, true])
        #expect(depacketizer.droppedAccessUnits == 2)
    }

    @Test func decodingOrderNumbersAreSkippedWhenSignalled() {
        var depacketizer = VideoDepacketizer(codec: .hevc, format: nil, hevcDONPresent: true)
        var factory = PacketFactory()
        let idr = hevcNAL(type: 19, size: 2500)
        var delivered = depacketizer.push(factory.packet(hevcAP([sets.vps, sets.sps, sets.pps], don: true), timestamp: 0))
        let fragments = hevcFU(idr, chunk: 1000, don: true)
        for (i, fragment) in fragments.enumerated() {
            delivered += depacketizer.push(factory.packet(fragment, timestamp: 0, marker: i == fragments.count - 1))
        }
        #expect(delivered.count == 1)
        #expect(delivered.first?.nalUnits == [idr])
        #expect(delivered.first?.format.width == 640)
    }
}

// MARK: - Audio

/// RFC 3640 AAC-hbr payload: 16-bit AU-headers-length, then 13-bit size + 3-bit index/delta per AU.
func aacHBR(_ units: [Data], announcedSizes: [Int]? = nil) -> Data {
    var payload = Data()
    let bits = units.count * 16
    payload.append(UInt8(bits >> 8))
    payload.append(UInt8(bits & 0xFF))
    for (index, unit) in units.enumerated() {
        let size = announcedSizes?[index] ?? unit.count
        let header = UInt16(size << 3)
        payload.append(UInt8(header >> 8))
        payload.append(UInt8(header & 0xFF))
    }
    for unit in units { payload.append(unit) }
    return payload
}

@Suite struct AudioDepacketizerTests {
    let aacTrack = RTSPTrack(kind: .audio, control: "", payloadType: 97, encoding: "MPEG4-GENERIC", clockRate: 16_000, channels: 1,
                             fmtp: ["mode": "AAC-hbr", "sizelength": "13", "indexlength": "3", "indexdeltalength": "3", "config": "1408"])

    @Test func multipleAACUnitsPerPacket() throws {
        var depacketizer = try #require(AudioDepacketizer(track: aacTrack))
        var factory = PacketFactory()
        let units = [filler(200, seed: 1), filler(180, seed: 2), filler(210, seed: 3)]
        let out = depacketizer.push(factory.packet(aacHBR(units), timestamp: 50_000, marker: true))
        #expect(out.map(\.data) == units)
        #expect(out.map(\.rtpTimestamp) == [50_000, 51_024, 52_048])
        #expect(out.allSatisfy { $0.sampleCount == 1024 })
    }

    @Test func fragmentedAACUnit() throws {
        var depacketizer = try #require(AudioDepacketizer(track: aacTrack))
        var factory = PacketFactory()
        let unit = filler(3000)
        var out = depacketizer.push(factory.packet(aacHBR([unit.prefix(1400)], announcedSizes: [3000]), timestamp: 7000))
        out += depacketizer.push(factory.packet(aacHBR([unit.dropFirst(1400).prefix(1400)], announcedSizes: [3000]), timestamp: 7000))
        #expect(out.isEmpty)
        out += depacketizer.push(factory.packet(aacHBR([unit.dropFirst(2800)], announcedSizes: [3000]), timestamp: 7000, marker: true))
        #expect(out.map(\.data) == [unit])
        #expect(out.first?.rtpTimestamp == 7000)
    }

    @Test func lostAACFragmentDropsTheUnit() throws {
        var depacketizer = try #require(AudioDepacketizer(track: aacTrack))
        var factory = PacketFactory()
        let unit = filler(2000)
        var out = depacketizer.push(factory.packet(aacHBR([unit.prefix(1000)], announcedSizes: [2000]), timestamp: 0))
        factory.skip()
        out += depacketizer.push(factory.packet(aacHBR([filler(100)]), timestamp: 2048, marker: true))
        #expect(out.map(\.data) == [filler(100)])
    }

    @Test func aacLowBitrateHeaderSizes() throws {
        var track = aacTrack
        track.fmtp = ["mode": "AAC-lbr", "sizelength": "6", "indexlength": "2", "indexdeltalength": "2", "config": "1408"]
        var depacketizer = try #require(AudioDepacketizer(track: track))
        var factory = PacketFactory()
        // Two 8-bit AU headers (6-bit size + 2-bit index): sizes 10 and 20.
        var payload = Data([0x00, 0x10, UInt8(10 << 2), UInt8(20 << 2)])
        payload.append(filler(10, seed: 1))
        payload.append(filler(20, seed: 2))
        let out = depacketizer.push(factory.packet(payload, timestamp: 100, marker: true))
        #expect(out.map(\.data) == [filler(10, seed: 1), filler(20, seed: 2)])
    }

    @Test func constantSizeUnitsWithoutSizeFields() throws {
        var track = aacTrack
        track.fmtp = ["mode": "AAC-hbr", "randomaccessindication": "1", "constantsize": "4", "config": "1408"]
        var depacketizer = try #require(AudioDepacketizer(track: track))
        var factory = PacketFactory()
        // Two 1-bit AU headers (random access flags only): two units of the constant size.
        var payload = Data([0x00, 0x02, 0xC0])
        payload.append(filler(4, seed: 1))
        payload.append(filler(4, seed: 2))
        let out = depacketizer.push(factory.packet(payload, timestamp: 100, marker: true))
        #expect(out.map(\.data) == [filler(4, seed: 1), filler(4, seed: 2)])
        #expect(out.map(\.rtpTimestamp) == [100, 1124])
        // Data that does not add up to the announced units is dropped.
        #expect(depacketizer.push(factory.packet(Data([0x00, 0x02, 0xC0]) + filler(7), timestamp: 2148, marker: true)).isEmpty)
        // The largest accepted constant size is the access-unit limit.
        track.fmtp["constantsize"] = String(AudioDepacketizer.maxAccessUnitSize)
        #expect(AudioDepacketizer(track: track) != nil)
    }

    @Test func malformedAACPacketsAreDropped() throws {
        var depacketizer = try #require(AudioDepacketizer(track: aacTrack))
        var factory = PacketFactory()
        #expect(depacketizer.push(factory.packet(Data([0x00]), timestamp: 0, marker: true)).isEmpty)
        #expect(depacketizer.push(factory.packet(Data([0x00, 0x40, 0x00]), timestamp: 0, marker: true)).isEmpty)
        #expect(depacketizer.push(factory.packet(aacHBR([filler(10)], announcedSizes: [5]), timestamp: 0, marker: true)).isEmpty)
    }

    @Test func g711PacketsBecomeFrames() throws {
        let track = RTSPTrack(kind: .audio, control: "", payloadType: 0, encoding: "PCMU", clockRate: 8000)
        var depacketizer = try #require(AudioDepacketizer(track: track))
        var factory = PacketFactory()
        let out = depacketizer.push(factory.packet(filler(160), timestamp: 800, marker: true))
        #expect(out.count == 1)
        #expect(out.first?.data == filler(160))
        #expect(out.first?.sampleCount == 160)
        #expect(out.first?.rtpTimestamp == 800)
    }

    @Test func unsupportedEncodingHasNoDepacketizer() {
        #expect(AudioDepacketizer(track: RTSPTrack(kind: .audio, control: "", payloadType: 97, encoding: "L16", clockRate: 16_000)) == nil)
    }
}

// MARK: - Sender restarts and hostile sizes

@Suite struct DepacketizerResyncTests {
    let format = RTSPSessionDescription.makeH264Format(sps: RealParameterSets.h264Main640x360.sps, pps: RealParameterSets.h264Main640x360.pps)

    private func frame(_ index: Int, sequence: UInt16, ssrc: UInt32 = 1, keyframeEvery: Int = 10) -> RTPPacket {
        RTPPacket(marker: true, payloadType: 96, sequenceNumber: sequence, timestamp: UInt32(index * 3600), ssrc: ssrc,
                  payload: h264NAL(type: index % keyframeEvery == 0 ? 5 : 1, size: 50, seed: UInt8(index % 200)))
    }

    @Test func backwardsSequenceJumpResynchronisesAtOnce() {
        // The camera restarts its RTP sender inside the session: sequence numbers jump back by 1050.
        var depacketizer = VideoDepacketizer(codec: .h264, format: format)
        var delivered = 0
        for i in 0..<50 { delivered += depacketizer.push(frame(i, sequence: UInt16(5000 + i))).count }
        #expect(delivered == 50)
        var afterReset: [VideoAccessUnit] = []
        for i in 0..<200 { afterReset += depacketizer.push(frame(50 + i, sequence: UInt16(3950 + i))) }
        #expect(afterReset.count == 200, "the new sequence starts with a keyframe, so nothing is lost")
        #expect(afterReset.first?.isKeyframe == true)
    }

    @Test func backwardsJumpToDeltaFramesWaitsForKeyframe() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: format)
        var delivered: [VideoAccessUnit] = []
        for i in 0..<20 { delivered += depacketizer.push(frame(i, sequence: UInt16(30_000 + i))) }
        // After the jump the first frames are delta frames (indices 21...29): dropped until the keyframe at 30.
        for i in 21..<45 { delivered += depacketizer.push(frame(i, sequence: UInt16(100 + i))) }
        let indices = delivered.map { Int($0.rtpTimestamp) / 3600 }
        #expect(indices == Array(0..<20) + Array(30..<45))
    }

    @Test func slightlyLatePacketsAreStillDropped() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: format)
        var delivered = 0
        for i in 0..<30 { delivered += depacketizer.push(frame(i, sequence: UInt16(1000 + i))).count }
        // A duplicate of an earlier packet (within the reorder window) is ignored and does not disturb the stream.
        delivered += depacketizer.push(frame(25, sequence: 1025)).count
        delivered += depacketizer.push(frame(30, sequence: 1030)).count
        #expect(delivered == 31)
    }

    @Test func ssrcChangeResynchronises() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: format)
        var delivered = 0
        for i in 0..<20 { delivered += depacketizer.push(frame(i, sequence: UInt16(9000 + i), ssrc: 1)).count }
        // New SSRC, sequence numbers slightly behind the old ones: a new sender, not late packets.
        for i in 20..<60 { delivered += depacketizer.push(frame(i, sequence: UInt16(8990 + i), ssrc: 2)).count }
        #expect(delivered == 60)
    }

    @Test func audioBackwardsSequenceJumpResynchronises() throws {
        let track = RTSPTrack(kind: .audio, control: "", payloadType: 0, encoding: "PCMU", clockRate: 8000)
        var depacketizer = try #require(AudioDepacketizer(track: track))
        for i in 0..<10 {
            _ = depacketizer.push(RTPPacket(payloadType: 0, sequenceNumber: UInt16(30_000 + i), timestamp: UInt32(i * 160), ssrc: 1, payload: filler(160)))
        }
        var after = 0
        for i in 0..<500 {
            after += depacketizer.push(RTPPacket(payloadType: 0, sequenceNumber: UInt16(100 + i), timestamp: UInt32(i * 160), ssrc: 1,
                                                 payload: filler(160))).count
        }
        #expect(after == 500)
    }

    @Test func endlessFragmentIsCapped() {
        // FU-A middle fragments forever: same timestamp, never an end bit or marker.
        var depacketizer = VideoDepacketizer(codec: .h264, format: format)
        var factory = PacketFactory()
        _ = depacketizer.push(factory.packet(Data([0x7C, 0x85]) + filler(1400), timestamp: 7))
        let middle = Data([0x7C, 0x05]) + filler(1400)
        let count = VideoDepacketizer.maxAccessUnitSize / 1400 + 100
        for _ in 0..<count { _ = depacketizer.push(factory.packet(middle, timestamp: 7)) }
        #expect(depacketizer.bufferedByteCount <= VideoDepacketizer.maxAccessUnitSize)
        #expect(depacketizer.bufferedByteCount < 2 * 1400, "the oversized access unit was discarded")
        // The stream recovers at the next keyframe.
        var delivered = depacketizer.push(factory.packet(h264NAL(type: 5, size: 50), timestamp: 3607, marker: true))
        delivered += depacketizer.push(factory.packet(h264NAL(type: 1, size: 50), timestamp: 7207, marker: true))
        #expect(delivered.count == 2)
    }

    @Test func endlessSingleNALAccessUnitIsCapped() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: format)
        var factory = PacketFactory()
        let slice = h264NAL(type: 1, size: 1400)
        let count = VideoDepacketizer.maxAccessUnitSize / 1400 + 100
        for _ in 0..<count { _ = depacketizer.push(factory.packet(slice, timestamp: 99)) }
        #expect(depacketizer.bufferedByteCount <= VideoDepacketizer.maxAccessUnitSize)
    }

    @Test func endlessAudioFragmentIsCapped() throws {
        let aac = RTSPTrack(kind: .audio, control: "", payloadType: 97, encoding: "MPEG4-GENERIC", clockRate: 16_000, channels: 1,
                            fmtp: ["mode": "AAC-hbr", "config": "1408"])   // no AU headers: fragments are marker-delimited
        var depacketizer = try #require(AudioDepacketizer(track: aac))
        var factory = PacketFactory()
        let count = AudioDepacketizer.maxAccessUnitSize / 1400 + 100
        for _ in 0..<count { _ = depacketizer.push(factory.packet(filler(1400), timestamp: 5)) }
        #expect(depacketizer.bufferedByteCount <= AudioDepacketizer.maxAccessUnitSize)
        let out = depacketizer.push(factory.packet(filler(100), timestamp: 1029, marker: true))
        #expect(out.map(\.data) == [filler(100)])
    }

    @Test func oversizedAnnouncedAudioUnitIsRejected() throws {
        let aac = RTSPTrack(kind: .audio, control: "", payloadType: 97, encoding: "MPEG4-GENERIC", clockRate: 16_000, channels: 1,
                            fmtp: ["mode": "AAC-hbr", "sizelength": "32", "config": "1408"])
        var depacketizer = try #require(AudioDepacketizer(track: aac))
        var factory = PacketFactory()
        // One 32-bit AU header announcing a 4 GiB unit, then data: never buffered.
        var payload = Data([0x00, 0x20, 0xFF, 0xFF, 0xFF, 0xF0])
        payload.append(filler(1000))
        #expect(depacketizer.push(factory.packet(payload, timestamp: 0)).isEmpty)
        #expect(depacketizer.bufferedByteCount == 0)
    }
}

@Suite struct HEVCDecodingOrderTests {
    let sets = RealParameterSets.hevcMain640x360

    @Test func singleNALUnitPacketsDropTheirDONL() throws {
        // RFC 7798 §4.4.1: with sprop-max-don-diff > 0, single NAL unit packets carry a 2-byte DONL after the header.
        var depacketizer = VideoDepacketizer(codec: .hevc, format: RTSPSessionDescription.makeHEVCFormat(vps: sets.vps, sps: sets.sps, pps: sets.pps),
                                             hevcDONPresent: true)
        var factory = PacketFactory()
        func withDONL(_ nal: Data, don: UInt16) -> Data {
            var payload = nal.prefix(2)
            payload.append(contentsOf: [UInt8(don >> 8), UInt8(don & 0xFF)])
            payload.append(nal.dropFirst(2))
            return payload
        }
        let idr = hevcNAL(type: 19, size: 300)
        let trail = hevcNAL(type: 1, size: 120, seed: 4)
        var delivered = depacketizer.push(factory.packet(withDONL(idr, don: 0), timestamp: 0, marker: true))
        delivered += depacketizer.push(factory.packet(withDONL(trail, don: 1), timestamp: 3000, marker: true))
        #expect(delivered.map(\.nalUnits) == [[idr], [trail]])
        // Too short to hold a DONL: dropped as malformed.
        delivered += depacketizer.push(factory.packet(Data([0x02, 0x01, 0x00]), timestamp: 6000, marker: true))
        #expect(delivered.count == 2)
    }
}
