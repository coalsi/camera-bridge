import BridgeSupport
import Foundation
import Testing
@testable import MediaCore

@Suite struct H264ParameterSetStoreTests {
    // H.264 Main 640×360 and High 1920×1080 (SPS, PPS), as RTSP cameras send them.
    let sps = Data(hex: "274d001eab281405ff2a")!
    let pps = Data(hex: "28ee3c80")!
    let bigSPS = Data(hex: "27640028ac56501e0089f950")!
    let bigPPS = Data(hex: "28ee3cb0")!

    private func summary(_ format: VideoFormat?) -> [String] {
        (format?.parameterSets ?? []).map { set in
            NALUnits.h264Type(set) == 7 ? "SPS\(NALUnits.h264SPSID(set) ?? 99)" : "PPS\(NALUnits.h264PPSIDs(set)?.id ?? 99)"
        }
    }

    @Test func idsAreReadFromTheNALUnits() {
        #expect(NALUnits.h264SPSID(sps) == 0)
        #expect(NALUnits.h264SPSID(H264StreamEditing.sps(sps, id: 7)) == 7)
        #expect(NALUnits.h264SPSID(H264StreamEditing.sps(sps, id: 31)) == 31)
        #expect(NALUnits.h264PPSIDs(pps).map { [$0.id, $0.spsID] } == [0, 0])
        let other = H264StreamEditing.pps(pps, id: 200, spsID: 5)
        #expect(NALUnits.h264PPSIDs(other).map { [$0.id, $0.spsID] } == [200, 5])
        // What is not an SPS / PPS, or is cut short, has no id.
        #expect(NALUnits.h264SPSID(pps) == nil && NALUnits.h264PPSIDs(sps) == nil)
        #expect(NALUnits.h264SPSID(Data([0x27, 0x4D])) == nil && NALUnits.h264PPSIDs(Data([0x28])) == nil)
        #expect(NALUnits.h264SPSID(Data()) == nil && NALUnits.h264PPSIDs(Data()) == nil)
    }

    @Test func idParsingNeverTrapsOnGarbage() {
        var seed: UInt64 = 7
        for _ in 0..<2_000 {
            let length = Int(seed % 12)
            let bytes = (0..<length).map { _ -> UInt8 in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: seed >> 33)
            }
            for header in [UInt8(0x27), 0x28, 0x67, 0x68] {
                let nal = Data([header] + bytes)
                _ = NALUnits.h264SPSID(nal)
                _ = NALUnits.h264PPSIDs(nal)
                var store = H264ParameterSetStore()
                store.add(nal)
                _ = store.format
            }
        }
    }

    @Test func oneSPSAndOnePPSMakeTheFormatTheyAlwaysMade() throws {
        var store = H264ParameterSetStore()
        #expect(store.format == nil)
        var changed = [store.add(sps)]
        #expect(store.format == nil, "an SPS alone is no format")
        changed.append(store.add(pps))
        changed += [store.add(sps), store.add(pps)]
        #expect(changed == [true, true, false, false], "a repeat changes nothing")
        let format = try #require(store.format)
        #expect(format == VideoFormat.h264(sps: sps, pps: pps))
        #expect(format.parameterSets == [sps, pps] && format.width == 640 && format.height == 360)
    }

    @Test func everyPPSIsKeptAndTheNewestIsFirst() throws {
        let pps1 = H264StreamEditing.pps(pps, id: 1)
        var store = H264ParameterSetStore(parameterSets: [sps, pps, pps1])
        #expect(summary(store.format) == ["SPS0", "PPS1", "PPS0"], "SPS first, then the newest PPS, then the rest by id")
        // Sent again in the other order, nothing changes; a changed one moves to the front.
        let repeats = [store.add(pps), store.add(pps1)]
        let changedContent = store.add(H264StreamEditing.pps(bigPPS, id: 0))
        #expect(repeats == [false, false] && changedContent)
        #expect(summary(store.format) == ["SPS0", "PPS0", "PPS1"])
        #expect(store.count == 3)
    }

    @Test func aPictureSizeChangeStartsANewSequence() throws {
        var store = H264ParameterSetStore(parameterSets: [sps, pps, H264StreamEditing.pps(pps, id: 1)])
        // 1920×1080 on SPS id 2 with its PPS: the 640×360 sets are stale.
        let newSPS = H264StreamEditing.sps(bigSPS, id: 2)
        let added = [store.add(newSPS), store.add(H264StreamEditing.pps(bigPPS, id: 4, spsID: 2))]
        #expect(added == [true, true])
        let format = try #require(store.format)
        #expect(summary(format) == ["SPS2", "PPS4"] && format.width == 1920 && format.height == 1080)
        #expect(store.count == 2)
    }

    @Test func aSecondSPSOfTheSameSizeIsKept() throws {
        var store = H264ParameterSetStore(parameterSets: [sps, pps])
        let second = H264StreamEditing.sps(sps, id: 1)
        let added = [store.add(second), store.add(H264StreamEditing.pps(pps, id: 1, spsID: 1))]
        #expect(added == [true, true])
        let format = try #require(store.format)
        #expect(summary(format) == ["SPS1", "PPS1", "SPS0", "PPS0"], "the newest SPS and its PPS lead")
        #expect(format.width == 640)
    }

    @Test func theSetsHeldAreBounded() throws {
        var store = H264ParameterSetStore(parameterSets: [sps])
        for id in 0..<300 { store.add(H264StreamEditing.pps(pps, id: UInt32(id))) }
        for id in 1..<31 { store.add(H264StreamEditing.sps(sps, id: UInt32(id))) }
        #expect(store.count <= H264ParameterSetStore.maximumPPS + H264ParameterSetStore.maximumSPS)
        let format = try #require(store.format)
        #expect(format.width == 640 && format.parameterSets.count == store.count)
    }

    @Test func aFormatExtendsAnotherThatItContains() throws {
        let one = try #require(H264ParameterSetStore(parameterSets: [sps, pps]).format)
        let two = try #require(H264ParameterSetStore(parameterSets: [sps, pps, H264StreamEditing.pps(pps, id: 1)]).format)
        let big = try #require(H264ParameterSetStore(parameterSets: [bigSPS, bigPPS]).format)
        #expect(two.extends(one) && one.extends(one))
        #expect(!one.extends(two), "less is not an extension")
        #expect(!big.extends(one) && !one.extends(big), "another stream")
        var empty = one
        empty.parameterSets = []
        #expect(!one.extends(empty))
    }
}
