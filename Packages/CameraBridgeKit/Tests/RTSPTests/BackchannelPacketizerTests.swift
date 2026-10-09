import Foundation
import MediaCore
import RTP
import Testing
@testable import RTSP

@Suite struct BackchannelPacketizerTests {
    @Test func g711PacketsCarrySamplesWithRunningTimestamps() throws {
        let pcmu = AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1)
        var packetizer = BackchannelPacketizer(format: pcmu, payloadType: 0, clockRate: 8000, ssrc: 42, maxPayload: 1024)
        let first = try packetizer.packetize(EncodedAudioFrame(format: pcmu, data: filler(160), pts: MediaTime(value: 0, timescale: 8000),
                                                               sampleCount: 160, wallClock: Date()))
        let second = try packetizer.packetize(EncodedAudioFrame(format: pcmu, data: filler(320), pts: MediaTime(value: 99, timescale: 8000),
                                                                sampleCount: 320, wallClock: Date()))
        #expect(first.count == 1 && second.count == 1)
        #expect(first[0].marker && !second[0].marker)
        #expect(second[0].timestamp == first[0].timestamp &+ 160)
        #expect(second[0].sequenceNumber == first[0].sequenceNumber &+ 1)
        #expect(first[0].ssrc == 42 && first[0].payloadType == 0)
        #expect(try packetizer.packetize(EncodedAudioFrame(format: pcmu, data: Data(), pts: MediaTime(value: 0, timescale: 8000),
                                                           sampleCount: 0, wallClock: Date())).isEmpty)
    }

    @Test func aacUsesRFC3640Framing() throws {
        let aac = AudioFormat.aacLC(sampleRate: 16_000, channels: 1)
        var packetizer = BackchannelPacketizer(format: aac, payloadType: 98, clockRate: 16_000)
        let unit = filler(300)
        let packets = try packetizer.packetize(EncodedAudioFrame(format: aac, data: unit, pts: MediaTime(value: 0, timescale: 16_000),
                                                                 sampleCount: 1024, wallClock: Date()))
        #expect(packets.count == 1)
        // Round trip through the receive-side depacketizer.
        let track = RTSPTrack(kind: .audio, control: "", payloadType: 98, encoding: "MPEG4-GENERIC", clockRate: 16_000, channels: 1,
                              fmtp: ["mode": "AAC-hbr", "sizelength": "13", "indexlength": "3", "indexdeltalength": "3", "config": "1408"])
        var depacketizer = try #require(AudioDepacketizer(track: track))
        #expect(depacketizer.push(packets[0]).map(\.data) == [unit])
        let next = try packetizer.packetize(EncodedAudioFrame(format: aac, data: unit, pts: MediaTime(value: 1024, timescale: 16_000),
                                                              sampleCount: 1024, wallClock: Date()))
        #expect(next[0].timestamp == packets[0].timestamp &+ 1024)
    }

    @Test func wrongSampleRateIsRejected() {
        let pcmu = AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1)
        var packetizer = BackchannelPacketizer(format: pcmu, payloadType: 0, clockRate: 8000)
        let wide = EncodedAudioFrame(format: AudioFormat(codec: .pcmu, sampleRate: 16_000, channels: 1), data: filler(320),
                                     pts: MediaTime(value: 0, timescale: 16_000), sampleCount: 320, wallClock: Date())
        #expect(throws: RTSPError.unsupportedCodec("pcmu@16000")) { try packetizer.packetize(wide) }
    }

    @Test func hostileClockRatesAndSampleCountsNeverTrap() throws {
        let aac = AudioFormat.aacLC(sampleRate: 16_000, channels: 1)
        var packetizer = BackchannelPacketizer(format: aac, payloadType: 98, clockRate: Int.max)
        let frame = EncodedAudioFrame(format: aac, data: filler(10), pts: MediaTime(value: 0, timescale: 16_000), sampleCount: Int.max,
                                      wallClock: Date())
        _ = try packetizer.packetize(frame)
        _ = try packetizer.packetize(frame)
    }

    @Test func aacFramesTooLargeForTheSizeFieldAreRejected() {
        let aac = AudioFormat.aacLC(sampleRate: 16_000, channels: 1)
        var packetizer = BackchannelPacketizer(format: aac, payloadType: 98, clockRate: 16_000)
        let frame = EncodedAudioFrame(format: aac, data: filler(0x2000), pts: MediaTime(value: 0, timescale: 16_000), sampleCount: 1024,
                                      wallClock: Date())
        #expect(throws: RTSPError.self) { try packetizer.packetize(frame) }
    }
}
