import BridgeSupport
import Foundation
import MediaCore
import RTP
import Testing
@testable import RTSP

/// Cameras that code their pictures with more than one PPS (field report, a Tapo: the IDR decoded, every P picture after it
/// failed in VideoToolbox with kVTVideoDecoderBadDataErr): the format the depacketizer hands out must carry every SPS and PPS the
/// stream sent, by id, or a decoder cannot resolve the PPS a slice names.
@Suite struct MultipleParameterSetTests {
    let sps = RealParameterSets.h264Main640x360.sps
    let pps0 = RealParameterSets.h264Main640x360.pps
    let pps1 = H264StreamEditing.pps(RealParameterSets.h264Main640x360.pps, id: 1)
    let big = RealParameterSets.h264High1080p

    private func ids(_ format: VideoFormat) -> [String] {
        format.parameterSets.map { set in
            switch NALUnits.h264Type(set) {
            case 7: "SPS\(NALUnits.h264SPSID(set) ?? 99)"
            case 8: "PPS\(NALUnits.h264PPSIDs(set)?.id ?? 99)"
            default: "?"
            }
        }
    }

    // MARK: Depacketizer

    @Test func theTestPPSAreWhatTheyClaimToBe() {
        #expect(NALUnits.h264PPSIDs(pps0)?.id == 0 && NALUnits.h264PPSIDs(pps0)?.spsID == 0)
        #expect(NALUnits.h264PPSIDs(pps1)?.id == 1 && NALUnits.h264PPSIDs(pps1)?.spsID == 0)
        #expect(NALUnits.h264SPSID(sps) == 0)
        #expect(NALUnits.h264SPSID(H264StreamEditing.sps(sps, id: 3)) == 3)
        #expect(H264SPS.parse(H264StreamEditing.sps(sps, id: 3))?.width == 640)
    }

    @Test func twoInBandPPSBothReachTheFormat() throws {
        var depacketizer = VideoDepacketizer(codec: .h264, format: nil)
        var factory = PacketFactory()
        let idr = h264NAL(type: 5, size: 300)
        var units = depacketizer.push(factory.packet(stapA([sps, pps1, pps0]), timestamp: 3000))
        units += depacketizer.push(factory.packet(idr, timestamp: 3000, marker: true))
        let unit = try #require(units.first)
        #expect(unit.nalUnits == [idr])
        #expect(Set(unit.format.parameterSets) == [sps, pps0, pps1])
        #expect(unit.format.parameterSets.first == sps, "the SPS stays first, as every reader of the format expects")
        #expect(unit.format.width == 640 && unit.format.height == 360)
    }

    @Test func aSecondPPSSentOnlyWithTheIDRJoinsTheOneFromTheSDP() throws {
        let initial = RTSPSessionDescription.makeH264Format(sps: sps, pps: pps0)
        var depacketizer = VideoDepacketizer(codec: .h264, format: initial)
        var factory = PacketFactory()
        var units: [VideoAccessUnit] = []
        units += depacketizer.push(factory.packet(pps1, timestamp: 3000))
        units += depacketizer.push(factory.packet(h264NAL(type: 5, size: 200), timestamp: 3000, marker: true))
        units += depacketizer.push(factory.packet(h264NAL(type: 1, size: 100, seed: 7), timestamp: 6000, marker: true))
        #expect(units.count == 2)
        #expect(Set(units[0].format.parameterSets) == [sps, pps0, pps1])
        #expect(units[1].format == units[0].format, "later pictures keep both")
        #expect(units[0].format.extends(initial))
    }

    /// A PPS in front of a P picture (a second PPS sent when it is first used): that picture's format has it; the pictures
    /// before keep the SDP's.
    @Test func aPPSSentInFrontOfAPPictureExtendsTheFormatFromThatPicture() throws {
        let initial = RTSPSessionDescription.makeH264Format(sps: sps, pps: pps0)
        var depacketizer = VideoDepacketizer(codec: .h264, format: initial)
        var factory = PacketFactory()
        var units = depacketizer.push(factory.packet(h264NAL(type: 5, size: 200), timestamp: 3000, marker: true))
        units += depacketizer.push(factory.packet(pps1, timestamp: 6000))
        units += depacketizer.push(factory.packet(h264NAL(type: 1, size: 100, seed: 7), timestamp: 6000, marker: true))
        #expect(units.count == 2)
        #expect(units[0].format == initial)
        #expect(Set(units[1].format.parameterSets) == [sps, pps0, pps1])
        #expect(units[1].format.extends(units[0].format))
    }

    @Test func repeatedParameterSetsChangeNothing() throws {
        let initial = RTSPSessionDescription.makeH264Format(sps: sps, pps: pps0)
        var depacketizer = VideoDepacketizer(codec: .h264, format: initial)
        var factory = PacketFactory()
        var units: [VideoAccessUnit] = []
        for index in 0..<3 {
            let timestamp = UInt32(3000 * (index + 1))
            units += depacketizer.push(factory.packet(stapA([sps, pps0]), timestamp: timestamp))
            units += depacketizer.push(factory.packet(h264NAL(type: 5, size: 100, seed: UInt8(index + 1)), timestamp: timestamp, marker: true))
        }
        #expect(units.count == 3)
        #expect(units.allSatisfy { $0.format == initial })
        #expect(initial.parameterSets == [sps, pps0], "one SPS and one PPS: the list is what it always was")
    }

    @Test func aPPSWithTheSameIdAndNewContentReplacesTheOldOne() throws {
        var depacketizer = VideoDepacketizer(codec: .h264, format: RTSPSessionDescription.makeH264Format(sps: sps, pps: pps0))
        var factory = PacketFactory()
        let changed = big.pps   // PPS id 0 again, other content
        #expect(NALUnits.h264PPSIDs(changed)?.id == 0 && changed != pps0)
        var units = depacketizer.push(factory.packet(changed, timestamp: 3000))
        units += depacketizer.push(factory.packet(h264NAL(type: 5, size: 100), timestamp: 3000, marker: true))
        let unit = try #require(units.first)
        #expect(unit.format.parameterSets == [sps, changed])
    }

    @Test func aNewPictureSizeDropsTheOldSets() throws {
        var depacketizer = VideoDepacketizer(codec: .h264, format: RTSPSessionDescription.makeH264Format(sps: sps, pps: pps0))
        var factory = PacketFactory()
        // The camera comes back at 1920×1080 with its sets on other ids; the 640×360 ones are stale and must not be picked as
        // the format's SPS (they would give the format the wrong size).
        let newSPS = H264StreamEditing.sps(big.sps, id: 1)
        let newPPS = H264StreamEditing.pps(big.pps, id: 1, spsID: 1)
        var units = depacketizer.push(factory.packet(stapA([newSPS, newPPS]), timestamp: 3000))
        units += depacketizer.push(factory.packet(h264NAL(type: 5, size: 100), timestamp: 3000, marker: true))
        let unit = try #require(units.first)
        #expect(unit.format.parameterSets == [newSPS, newPPS], "\(ids(unit.format))")
        #expect(unit.format.width == 1920 && unit.format.height == 1080)
    }

    @Test func theNumberOfParameterSetsIsBounded() throws {
        var depacketizer = VideoDepacketizer(codec: .h264, format: nil)
        var factory = PacketFactory()
        var units = depacketizer.push(factory.packet(sps, timestamp: 3000))
        for id in 0..<60 { units += depacketizer.push(factory.packet(H264StreamEditing.pps(pps0, id: UInt32(id)), timestamp: 3000)) }
        units += depacketizer.push(factory.packet(h264NAL(type: 5, size: 100), timestamp: 3000, marker: true))
        let unit = try #require(units.first)
        #expect(unit.format.parameterSets.count <= 1 + H264ParameterSetStore.maximumPPS)
        #expect(unit.format.parameterSets.first == sps)
    }

    // MARK: SDP and FLV

    @Test func everySPSAndPPSOfTheSDPReachesTheFormat() throws {
        let sprop = [sps, pps0, pps1].map { $0.base64EncodedString() }.joined(separator: ",")
        let text = """
        v=0\r
        o=- 0 0 IN IP4 127.0.0.1\r
        s=Tapo\r
        t=0 0\r
        m=video 0 RTP/AVP 96\r
        a=rtpmap:96 H264/90000\r
        a=fmtp:96 packetization-mode=1;profile-level-id=4D001E;sprop-parameter-sets=\(sprop)\r
        a=control:track1\r
        """
        let tracks = RTSPSessionDescription.tracks(in: try SDPSession.parse(text), backchannelRequested: false)
        let format = try #require(RTSPSessionDescription.videoFormat(for: tracks[0]))
        #expect(Set(format.parameterSets) == [sps, pps0, pps1])
        #expect(format.parameterSets.first == sps)
        #expect(format.width == 640)
    }

    @Test func aDocumentedSinglePairGivesTheSamePairAsBefore() throws {
        let sprop = [sps, pps0].map { $0.base64EncodedString() }.joined(separator: ",")
        let text = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=x\r\nt=0 0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
            + "a=fmtp:96 packetization-mode=1;sprop-parameter-sets=\(sprop)\r\na=control:track1\r\n"
        let tracks = RTSPSessionDescription.tracks(in: try SDPSession.parse(text), backchannelRequested: false)
        #expect(RTSPSessionDescription.videoFormat(for: tracks[0]) == RTSPSessionDescription.makeH264Format(sps: sps, pps: pps0))
    }

    @Test func aConfigurationRecordWithTwoPPSGivesBoth() throws {
        var record = Data([0x01, sps[1], sps[2], sps[3], 0xFF, 0xE1])
        record.append(contentsOf: [UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)]); record.append(sps)
        record.append(0x02)
        for pps in [pps0, pps1] {
            record.append(contentsOf: [UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)]); record.append(pps)
        }
        var header = Data([0x17, 0x00, 0, 0, 0])
        header.append(record)
        var stream = FLVWriter.header(audio: false)
        stream.append(FLVWriter.tag(type: 9, timestamp: 0, body: header))
        stream.append(FLVWriter.avcNALUs([h264NAL(type: 5, size: 10)], keyframe: true, timestamp: 0))
        var demuxer = FLVDemuxer()
        let samples = try demuxer.append(stream)
        guard case .video(let frame)? = samples.first else {
            Issue.record("no video frame")
            return
        }
        #expect(Set(frame.format.parameterSets) == [sps, pps0, pps1])
    }
}

#if canImport(VideoToolbox) && os(macOS)
import PlatformApple
import TestSupport

/// A camera with two PPS through RTP, the depacketizer and VideoToolbox: every picture decodes.
@Suite(.timeLimit(.minutes(1))) struct MultipleParameterSetStreamTests {
    @Test func aStreamWhoseDeltaFramesUseAnotherPPSDecodesThroughTheRTSPClient() async throws {
        // Baseline (CAVLC), so slice headers can be edited: the IDR pictures keep PPS 0, the P pictures use PPS 1. The camera
        // sends no parameter sets in its SDP and puts PPS 1, then PPS 0 in front of each IDR: a decoder built from "the last
        // PPS" gets PPS 0, decodes the IDR and rejects every P picture.
        let encoded = try VideoToolboxFrames.encodeH264(width: 640, height: 360, count: 40, keyframeInterval: 20, baseline: true)
        let single = encoded[0].format
        let pps1 = H264StreamEditing.pps(single.parameterSets[1], id: 1)
        var both = single
        both.parameterSets = [single.parameterSets[0], pps1, single.parameterSets[1]]
        let frames: [EncodedVideoFrame] = encoded.map { frame in
            var edited = frame
            edited.format = both
            edited.nalUnits = frame.nalUnits.map { NALUnits.h264Type($0) == 1 ? H264StreamEditing.slice($0, ppsID: 1) : $0 }
            return edited
        }
        try #require(frames[0].isKeyframe)

        var configuration = RTSPTestServer.Configuration()
        configuration.parameterSetsInSDP = false
        let server = RTSPTestServer(source: ReplayMediaSource(frames: frames, fps: 30), transport: AppleNetworkTransport(), configuration: configuration)
        try await server.start()
        let client = RTSPClient(configuration: RTSPConfiguration(url: server.url, credentials: nil), transport: AppleNetworkTransport())
        _ = try await client.connect()
        let collected = await collect(try await client.play(), timeout: .seconds(10)) { videoFrameCount($0) >= 30 }
        await client.close()
        await server.stop()

        let received = collected.video
        try #require(received.count >= 30)
        #expect(Set(received[0].format.parameterSets) == Set(both.parameterSets), "the format carries both PPS")
        let decoder = try AppleMediaCodecs().makeVideoDecoder(format: received[0].format)
        defer { decoder.invalidate() }
        var decoded = 0
        for frame in received {
            if try await decoder.decode(frame) != nil { decoded += 1 }
        }
        #expect(decoded == received.count, "\(decoded) of \(received.count) pictures decoded")
    }
}
#endif
