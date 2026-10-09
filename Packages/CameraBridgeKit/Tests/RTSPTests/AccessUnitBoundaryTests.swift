import BridgeSupport
import Foundation
import MediaCore
import RTP
import Testing
@testable import RTSP

/// An H.264 coded slice (type 1 or 5) of `size` bytes whose slice header starts with first_mb_in_slice = `firstMB` (0, 1 or 2:
/// ue(v) '1', '010', '011', then bits that keep the byte non-zero).
func h264Slice(type: UInt8, size: Int, firstMB: Int, seed: UInt8 = 1) -> Data {
    let header: UInt8 = firstMB == 0 ? 0xB0 : (firstMB == 1 ? 0x58 : 0x78)
    var nal = Data([0x60 | type, header])
    nal.append(filler(size - 2, seed: seed))
    return nal
}

/// An HEVC slice segment (type 0...31) with first_slice_segment_in_pic_flag `first`.
func hevcSlice(type: UInt8, size: Int, first: Bool, seed: UInt8 = 1) -> Data {
    var nal = Data([type << 1, 0x01, first ? 0xA1 : 0x21])
    nal.append(filler(size - 3, seed: seed))
    return nal
}

/// Access units end where the codec says a picture ends (ITU-T H.264 7.4.1.2.3), not only at the RTP marker bit and
/// timestamp change: cameras stamp consecutive pictures alike and mark only some, and two pictures in one access unit make
/// VideoToolbox fail every one of them (-12909).
@Suite struct AccessUnitBoundaryTests {
    let sps = RealParameterSets.h264Main640x360.sps
    let pps = RealParameterSets.h264Main640x360.pps
    var h264Format: VideoFormat { RTSPSessionDescription.makeH264Format(sps: sps, pps: pps) }

    @Test func picturesSharingATimestampAreSeparateAccessUnits() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: h264Format)
        var factory = PacketFactory()
        let idr = h264Slice(type: 5, size: 80, firstMB: 0)
        let pictures = (0..<4).map { h264Slice(type: 1, size: 60 + $0, firstMB: 0, seed: UInt8(3 + $0)) }
        var units = depacketizer.push(factory.packet(idr, timestamp: 9000))
        for picture in pictures { units += depacketizer.push(factory.packet(picture, timestamp: 9000)) }   // no marker bits at all
        #expect(units.count == 4)   // the last picture is still open
        #expect(units.map(\.nalUnits) == [[idr]] + pictures.dropLast().map { [$0] })
        #expect(units.map(\.isKeyframe) == [true, false, false, false])
        #expect(units.map(\.isIDR) == [true, false, false, false])
        #expect(units.allSatisfy { $0.rtpTimestamp == 9000 })
        #expect(depacketizer.droppedAccessUnits == 0)
    }

    @Test func aMarkerOnlyEndsAUnitThatHoldsASlice() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: h264Format)
        var factory = PacketFactory()
        let idr = h264Slice(type: 5, size: 80, firstMB: 0)
        let p = h264Slice(type: 1, size: 70, firstMB: 0, seed: 7)
        var units = depacketizer.push(factory.packet(idr, timestamp: 0, marker: true))
        // A SEI packet that carries the marker bit and is stamped differently from its picture ends nothing.
        units += depacketizer.push(factory.packet(h264NAL(type: 6, size: 20), timestamp: 3000, marker: true))
        #expect(units.count == 1)
        units += depacketizer.push(factory.packet(p, timestamp: 3600, marker: true))
        #expect(units.count == 2)
        #expect(units[1].nalUnits == [p])
        #expect(units[1].rtpTimestamp == 3600, "the picture's own packet stamps it")
        #expect(depacketizer.droppedAccessUnits == 0)
    }

    @Test func seiAndParameterSetsAfterASliceBelongToTheNextPicture() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: nil)
        var factory = PacketFactory()
        let idr = h264Slice(type: 5, size: 80, firstMB: 0)
        let p1 = h264Slice(type: 1, size: 70, firstMB: 0, seed: 5)
        let p2 = h264Slice(type: 1, size: 70, firstMB: 0, seed: 6)
        let sei = h264NAL(type: 6, size: 34)
        var units = depacketizer.push(factory.packet(stapA([sps, pps, sei, idr]), timestamp: 100))   // SPS PPS SEI IDR in one packet
        units += depacketizer.push(factory.packet(stapA([sei, p1]), timestamp: 100))                  // SEI P1 (same timestamp, no marker)
        units += depacketizer.push(factory.packet(sei, timestamp: 100))                                // SEI alone, then P2
        units += depacketizer.push(factory.packet(p2, timestamp: 100, marker: true))
        #expect(units.map(\.nalUnits) == [[idr], [p1], [p2]], "SEI NAL units are dropped")
        #expect(units.map(\.isKeyframe) == [true, false, false])
        #expect(units.first?.format.parameterSets == [sps, pps])
    }

    @Test func aPictureSplitIntoSlicesStaysOneAccessUnit() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: h264Format)
        var factory = PacketFactory()
        let slices = (0..<3).map { h264Slice(type: 5, size: 60, firstMB: $0, seed: UInt8(2 + $0)) }
        var units: [VideoAccessUnit] = []
        for slice in slices { units += depacketizer.push(factory.packet(slice, timestamp: 0)) }
        #expect(units.isEmpty)
        units += depacketizer.push(factory.packet(h264Slice(type: 1, size: 60, firstMB: 0, seed: 9), timestamp: 3000, marker: true))
        #expect(units.count == 2)
        #expect(units[0].nalUnits == slices)
    }

    @Test func aFragmentedSliceDoesNotSplit() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: h264Format)
        var factory = PacketFactory()
        let idr = h264Slice(type: 5, size: 3000, firstMB: 0)
        let p = h264Slice(type: 1, size: 100, firstMB: 0, seed: 4)
        var units: [VideoAccessUnit] = []
        for fragment in fuA(idr, chunk: 1000) { units += depacketizer.push(factory.packet(fragment, timestamp: 0)) }
        units += depacketizer.push(factory.packet(p, timestamp: 0, marker: true))
        #expect(units.map(\.nalUnits) == [[idr], [p]])
    }

    /// A packet lost between pictures that share a timestamp costs the pictures around it, not the stream: output resumes at
    /// the next keyframe.
    @Test func lossWithSharedTimestampsResumesAtTheNextKeyframe() {
        var depacketizer = VideoDepacketizer(codec: .h264, format: h264Format)
        var factory = PacketFactory()
        var units = depacketizer.push(factory.packet(h264Slice(type: 5, size: 80, firstMB: 0), timestamp: 0))
        units += depacketizer.push(factory.packet(h264Slice(type: 1, size: 60, firstMB: 0, seed: 3), timestamp: 0))
        factory.skip()   // lost
        units += depacketizer.push(factory.packet(h264Slice(type: 1, size: 60, firstMB: 0, seed: 4), timestamp: 0))
        units += depacketizer.push(factory.packet(h264Slice(type: 1, size: 60, firstMB: 0, seed: 5), timestamp: 0))
        let idr = h264Slice(type: 5, size: 80, firstMB: 0, seed: 6)
        units += depacketizer.push(factory.packet(idr, timestamp: 0))
        units += depacketizer.push(factory.packet(h264Slice(type: 1, size: 60, firstMB: 0, seed: 7), timestamp: 0))
        // The first IDR; the picture open when the packet went missing and the ones after it are dropped; then the next IDR (the
        // last picture is still open).
        #expect(units.map(\.isKeyframe) == [true, true])
        #expect(units.last?.nalUnits == [idr])
        #expect(depacketizer.droppedAccessUnits >= 1)
    }

    @Test func hevcPicturesSharingATimestampAreSeparateAccessUnits() {
        let sets = RealParameterSets.hevcMain640x360
        var depacketizer = VideoDepacketizer(codec: .hevc, format: RTSPSessionDescription.makeHEVCFormat(vps: sets.vps, sps: sets.sps, pps: sets.pps))
        var factory = PacketFactory()
        let idr = hevcSlice(type: 19, size: 80, first: true)
        let second = hevcSlice(type: 19, size: 60, first: false, seed: 4)   // a second slice segment of the same picture
        let p1 = hevcSlice(type: 1, size: 60, first: true, seed: 5)
        let p2 = hevcSlice(type: 1, size: 60, first: true, seed: 6)
        var units: [VideoAccessUnit] = []
        for nal in [idr, second, p1, p2] { units += depacketizer.push(factory.packet(nal, timestamp: 500)) }
        units += depacketizer.push(factory.packet(hevcNAL(type: 35, size: 4), timestamp: 500))   // AUD ends P2
        #expect(units.map(\.nalUnits) == [[idr, second], [p1], [p2]])
        #expect(units.map(\.isIDR) == [true, false, false])
    }
}
