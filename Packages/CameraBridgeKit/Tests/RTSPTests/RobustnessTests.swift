import BridgeSupport
import Foundation
import MediaCore
import RTP
import Testing
@testable import RTSP

/// Hostile input must never crash a parser (external input: cameras and the network).
@Suite struct RobustnessTests {
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
        mutating func bytes(_ count: Int) -> Data { Data((0..<count).map { _ in next() }) }
    }

    @Test func randomBytesThroughEveryParser() throws {
        var generator = Generator(state: 42)
        let aac = RTSPTrack(kind: .audio, control: "", payloadType: 97, encoding: "MPEG4-GENERIC", clockRate: 16_000, channels: 1,
                            fmtp: ["mode": "AAC-hbr", "sizelength": "13", "indexlength": "3", "indexdeltalength": "3",
                                   "ctsdeltalength": "2", "dtsdeltalength": "2", "randomaccessindication": "1",
                                   "streamstateindication": "3", "auxiliarydatasizelength": "8", "config": "1408"])
        var h264 = VideoDepacketizer(codec: .h264, format: nil)
        var hevc = VideoDepacketizer(codec: .hevc, format: nil, hevcDONPresent: true)
        var audio = try #require(AudioDepacketizer(track: aac))
        var messages = RTSPMessageParser(maxHeaderSize: 4096, maxBodySize: 4096)
        for round in 0..<3000 {
            let length = Int(generator.next()) + Int(generator.next()) % 8 * 256
            var payload = generator.bytes(length)
            if round % 3 == 0, !payload.isEmpty { payload[payload.startIndex] = [0x7C, 0x78, 0x62, 0x60][round % 4] }   // FU-A/STAP-A/HEVC FU/AP
            let packet = RTPPacket(marker: generator.next() & 1 == 0, payloadType: 96, sequenceNumber: UInt16(round % 70), timestamp: UInt32(round / 3),
                                   ssrc: 1, payload: payload)
            _ = h264.push(packet)
            _ = hevc.push(packet)
            _ = audio.push(packet)
            _ = RTCPSenderReport.parse(payload)
            _ = try? RTPPacket(parsing: payload)
            _ = AudioSpecificConfig(payload)
            messages.append(payload)
            do {
                while try messages.next() != nil {}
            } catch {
                messages = RTSPMessageParser(maxHeaderSize: 4096, maxBodySize: 4096)
            }
            _ = try? SDPSession.parse(String(decoding: payload, as: UTF8.self))
            var flv = FLVDemuxer()
            var stream = FLVWriter.header()
            stream.append(payload)
            _ = try? flv.append(stream)
        }
    }

    @Test func truncatedFLVTagsAtEveryLength() throws {
        var stream = FLVWriter.header()
        stream.append(FLVWriter.avcSequenceHeader(sps: RealParameterSets.h264Main640x360.sps, pps: RealParameterSets.h264Main640x360.pps))
        stream.append(FLVWriter.avcNALUs([h264NAL(type: 5, size: 40)], keyframe: true, timestamp: 0))
        stream.append(FLVWriter.aacSequenceHeader(Data([0x14, 0x08])))
        stream.append(FLVWriter.aacRaw(filler(20), timestamp: 0))
        for cut in 0..<stream.count {
            var demuxer = FLVDemuxer()
            _ = try? demuxer.append(stream.prefix(cut))
        }
        // Tag bodies cut short inside the tag (size fields still consistent).
        for cut in 1..<30 {
            var demuxer = FLVDemuxer()
            var truncated = FLVWriter.header()
            truncated.append(FLVWriter.tag(type: 9, timestamp: 0, body: Data([0x17, 0x00, 0, 0, 0, 0x01, 0x4D, 0x00]).prefix(cut)))
            truncated.append(FLVWriter.tag(type: 8, timestamp: 0, body: Data([0xAF, 0x00, 0x14]).prefix(cut)))
            _ = try demuxer.append(truncated)
        }
    }

    // MARK: Arithmetic on hostile timing input must saturate or re-time, never trap.

    @Test(arguments: [0, -5, 1, 5_000_000_000_000_000_000, Int.max, Int.min])
    func absurdClockRatesNeverTrap(_ clockRate: Int) {
        var smoother = TimestampSmoother(clockRate: clockRate)
        var clock = TrackWallClock(clockRate: clockRate)
        let start = Date(timeIntervalSince1970: 1000)
        var last: Int64 = -1
        for (i, raw) in [Int64(0), 100, 200, 1_000_000, Int64.max / 2, Int64.max, Int64.min, 0].enumerated() {
            let arrival = start + Double(i) * 1e5   // long real gaps too
            let out = smoother.smooth(raw, arrival: arrival)
            #expect(out > last)
            last = out
            _ = clock.wallClock(rtpTimestamp: UInt32(truncatingIfNeeded: raw), arrival: arrival)
        }
    }

    @Test func hostileTimestampStepsStayMonotonicWithoutTrapping() {
        var smoother = TimestampSmoother(clockRate: 90_000)
        let start = Date(timeIntervalSince1970: 1000)
        var raw: Int64 = 0
        var last: Int64 = -1
        for i in 0..<10_000 {
            raw = raw &+ (i % 3 == 0 ? Int64.max / 3 : Int64(Int32.max))
            let out = smoother.smooth(raw, arrival: start + Double(i) / 30)
            #expect(out > last)
            last = out
        }
        // Each hostile step was re-timed, so the timeline is still about 10_000 frames long (not saturated).
        #expect(last < 10_000 * 90_000)
    }

    @Test func unwrapperSaturatesAtTheEndOfTheRange() {
        var unwrapper = RTPTimestampUnwrapper(last: Int64.max - 10)
        let value = unwrapper.unwrap(UInt32(truncatingIfNeeded: Int64.max - 10) &+ 1_000_000)
        #expect(value == Int64.max)
        var low = RTPTimestampUnwrapper(last: Int64.min + 10)
        #expect(low.unwrap(UInt32(truncatingIfNeeded: Int64.min + 10) &- 1_000_000) == Int64.min)
    }

    @Test func flvTimelineSurvivesHostileTimestamps() {
        var timeline = FLVTimeline()
        let sets = RealParameterSets.h264Main640x360
        let format = RTSPSessionDescription.makeH264Format(sps: sets.sps, pps: sets.pps)
        let arrival = Date()
        _ = timeline.map(.video(FLVVideoFrame(nalUnits: [h264NAL(type: 5, size: 10)], isKeyframe: true, timestamp: 0, compositionOffset: 0,
                                              format: format)), arrival: arrival)
        // An explicit 24-bit AudioSpecificConfig sample rate and timestamps that advance by 2^31 - 1 ms per tag.
        let audio = AudioFormat(codec: .aac, sampleRate: 16_777_215, channels: 1, audioSpecificConfig: Data([0x17, 0x80, 0x00, 0x00, 0x08]))
        var timestamp: Int64 = 0
        var last = MediaTime(value: -1, timescale: 1)
        for i in 0..<5000 {
            timestamp = timestamp &+ (i % 7 == 0 ? Int64.max / 5 : 2_147_483_647)
            guard case .audio(let frame)? = timeline.map(.audio(FLVAudioFrame(data: Data([1]), timestamp: timestamp, format: audio)),
                                                           arrival: arrival) else { continue }
            #expect(frame.pts > last)
            last = frame.pts
        }
        var videoLast = MediaTime(value: -1, timescale: 1)
        for i in 0..<5000 {
            timestamp = timestamp &+ (i % 5 == 0 ? Int64.max / 3 : 2_147_483_647)
            let offset: Int32 = i % 2 == 0 ? 8_388_607 : -8_388_608
            guard case .video(let frame)? = timeline.map(.video(FLVVideoFrame(nalUnits: [h264NAL(type: 1, size: 10)], isKeyframe: false,
                                                                               timestamp: timestamp, compositionOffset: offset, format: format)),
                                                           arrival: arrival) else { continue }
            let dts = frame.dts ?? frame.pts
            #expect(dts > videoLast)
            videoLast = dts
        }
    }

    @Test func audioSpecificConfigRejectsAbsurdExplicitSampleRates() {
        // AAC-LC, frequency index 15 (explicit), 24-bit rate 0xFFFFFF, mono.
        #expect(AudioSpecificConfig(Data([0x17, 0xFF, 0xFF, 0xFF, 0x88])) == nil)
        // Explicit 0 Hz.
        #expect(AudioSpecificConfig(Data([0x17, 0x80, 0x00, 0x00, 0x08])) == nil)
        // Explicit 16 kHz is fine.
        #expect(AudioSpecificConfig(Data([0x17, 0x80, 0x1F, 0x40, 0x08]))?.sampleRate == 16_000)
    }

    @Test func sdpClockRatesAreSanitised() throws {
        let sdp = try SDPSession.parse("""
        v=0
        m=video 0 RTP/AVP 96
        a=rtpmap:96 H264/5000000000000000000
        m=audio 0 RTP/AVP 97
        a=rtpmap:97 MPEG4-GENERIC/99999999999
        a=fmtp:97 mode=AAC-hbr;config=1408;sizelength=13
        m=audio 0 RTP/AVP 98
        a=rtpmap:98 PCMU/0/9223372036854775807
        """)
        let tracks = RTSPSessionDescription.tracks(in: sdp, backchannelRequested: false)
        #expect(tracks.map(\.clockRate) == [90_000, 0, 8000])
        #expect(tracks[2].channels == RTSPSessionDescription.maxChannels)
        #expect(!RTSPSessionDescription.isUsableAudio(tracks[1]))
        #expect(RTSPSessionDescription.isUsableAudio(tracks[2]))
    }

    /// RFC 3640 `constantsize` from a hostile DESCRIBE: a negative or oversized constant AU size makes the AAC track
    /// unusable, and AU headers announcing it can never trap the in-process pipeline (the AU-size sum used to overflow).
    @Test(arguments: ["-1", "-4611686018427387905", "-9223372036854775808", "262145", "9223372036854775807"])
    func hostileConstantSizeIsRejected(_ constantSize: String) throws {
        let sdp = try SDPSession.parse("""
        v=0
        m=audio 0 RTP/AVP 97
        a=rtpmap:97 MPEG4-GENERIC/16000
        a=fmtp:97 mode=AAC-hbr; config=1408; randomaccessindication=1; constantsize=\(constantSize)
        """)
        let track = try #require(RTSPSessionDescription.tracks(in: sdp, backchannelRequested: false).first)
        #expect(track.fmtp["constantsize"] == constantSize)
        #expect(AudioDepacketizer(track: track) == nil)
        #expect(!RTSPSessionDescription.isUsableAudio(track))

        // The pipeline a misbehaving client would build from it: 1-bit random-access AU headers, two to sixteen per packet.
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
        let pipeline = MediaPipeline(plans: [MediaPipeline.TrackPlan(track: track, rtpChannel: 0, rtcpChannel: 1, videoFormat: nil,
                                                                     audioFormat: RTSPSessionDescription.audioFormat(for: track))],
                                     continuation: continuation, log: Log(category: "test"))
        for (sequence, headers) in [2, 3, 16].enumerated() {
            var payload = Data([0x00, UInt8(headers)])
            payload.append(Data(repeating: 0xFF, count: (headers + 7) / 8))
            payload.append(0xAA)
            let packet = RTPPacket(marker: true, payloadType: 97, sequenceNumber: UInt16(sequence), timestamp: UInt32(sequence * 1024), ssrc: 1,
                                   payload: payload)
            pipeline.handle(channel: 0, payload: packet.serialized(), arrival: Date())
        }
        pipeline.finish(throwing: nil)
        withExtendedLifetime(stream) {}
    }

    @Test func pipelineWithAbsurdClockRateNeverTraps() {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
        let track = RTSPTrack(kind: .video, control: "", payloadType: 96, encoding: "H264", clockRate: Int.max)
        let format = RTSPSessionDescription.makeH264Format(sps: RealParameterSets.h264Main640x360.sps, pps: RealParameterSets.h264Main640x360.pps)
        let pipeline = MediaPipeline(plans: [MediaPipeline.TrackPlan(track: track, rtpChannel: 0, rtcpChannel: 1, videoFormat: format, audioFormat: nil)],
                                     continuation: continuation, log: Log(category: "test"))
        let start = Date()
        for i in 0..<20 {
            let packet = RTPPacket(marker: true, payloadType: 96, sequenceNumber: UInt16(i), timestamp: UInt32(truncatingIfNeeded: i * 1_000_000_007),
                                   ssrc: 1, payload: h264NAL(type: i == 0 ? 5 : 1, size: 20))
            pipeline.handle(channel: 0, payload: packet.serialized(), arrival: start + Double(i) * 1e5)
        }
        pipeline.finish(throwing: nil)
        withExtendedLifetime(stream) {}
    }
}
