import BridgeSupport
import Foundation
import MediaCore
import Testing
@testable import RTP

@Suite struct AudioPacketizerTests {
    static func frame(_ codec: AudioCodec, _ data: Data, sampleRate: Int = 24_000) -> EncodedAudioFrame {
        EncodedAudioFrame(format: AudioFormat(codec: codec, sampleRate: sampleRate, channels: 1), data: data, pts: .seconds(0, timescale: Int32(sampleRate)),
                          sampleCount: 480, wallClock: Date())
    }

    /// RFC 7587: one Opus packet per RTP packet, payload untouched; marker only on the first packet (start of talkspurt).
    @Test func opusIsOneFramePerPacket() {
        var packetizer = AudioPacketizer(codec: .opus, payloadType: 110, ssrc: 0x0102_0304, initialSequence: 65_535)
        let first = packetizer.packetize(Self.frame(.opus, Data([0x78, 1, 2, 3])), rtpTimestamp: 480)
        #expect(first.payload == Data([0x78, 1, 2, 3]))
        #expect(first.payloadType == 110 && first.ssrc == 0x0102_0304 && first.timestamp == 480 && first.sequenceNumber == 65_535)
        #expect(first.marker)
        let second = packetizer.packetize(Self.frame(.opus, Data([0x78, 9])), rtpTimestamp: 960)
        #expect(second.sequenceNumber == 0 && !second.marker && second.payload == Data([0x78, 9]) && second.timestamp == 960)
    }

    /// RFC 3640 AAC-hbr style: AU-headers-length = 16 bits, one AU header (13-bit size, 3-bit index 0), then the AU.
    @Test func aacELDUsesRFC3640AUHeaderSection() {
        var packetizer = AudioPacketizer(codec: .aacELD, payloadType: 110, ssrc: 1, initialSequence: 10)
        let au = Data((0..<291).map { UInt8(truncatingIfNeeded: $0) })
        let packet = packetizer.packetize(Self.frame(.aacELD, au, sampleRate: 16_000), rtpTimestamp: 7)
        #expect(packet.payload.prefix(4) == Data([0x00, 0x10, 0x09, 0x18]))   // 291 << 3 = 0x0918
        #expect(packet.payload.dropFirst(4) == au)
        #expect(packet.marker)   // RFC 3640 §3.2.1: set on every packet carrying complete AUs
        #expect(packetizer.packetize(Self.frame(.aacELD, Data([0xAA]), sampleRate: 16_000), rtpTimestamp: 8).payload == Data([0x00, 0x10, 0x00, 0x08, 0xAA]))
        // AAC-LC uses the same AU header section.
        var aac = AudioPacketizer(codec: .aac, payloadType: 97, ssrc: 1, initialSequence: 0)
        #expect(aac.packetize(Self.frame(.aac, Data([1, 2])), rtpTimestamp: 0).payload == Data([0x00, 0x10, 0x00, 0x10, 1, 2]))
    }

    /// The 13-bit AU-size field cannot describe more than 8191 bytes; longer frames are cut there.
    @Test func oversizedAACFrameIsClamped() throws {
        var packetizer = AudioPacketizer(codec: .aacELD, payloadType: 110, ssrc: 1, initialSequence: 0)
        let packet = packetizer.packetize(Self.frame(.aacELD, Data(count: 9_000)), rtpTimestamp: 0)
        #expect(packet.payload.prefix(4) == Data([0x00, 0x10, 0xFF, 0xF8]))
        #expect(packet.payload.count == 4 + 8_191)
        #expect(try RFC3640.accessUnits(in: packet.payload) == [Data(count: 8_191)])
    }

    @Test func g711IsRaw() {
        var packetizer = AudioPacketizer(codec: .pcmu, payloadType: 0, ssrc: 1, initialSequence: 0)
        let packet = packetizer.packetize(Self.frame(.pcmu, Data(repeating: 0xFF, count: 160), sampleRate: 8_000), rtpTimestamp: 160)
        #expect(packet.payload == Data(repeating: 0xFF, count: 160) && packet.payloadType == 0 && packet.marker)
    }

    @Test func rfc3640ParsesSeveralAccessUnits() throws {
        // AU-headers-length 32: sizes 3 and 2 (index 0, index-delta 0).
        let payload = try #require(Data(hex: "0020" + "0018" + "0010" + "aabbcc" + "ddee"))
        #expect(try RFC3640.accessUnits(in: payload) == [Data([0xAA, 0xBB, 0xCC]), Data([0xDD, 0xEE])])
        #expect(throws: RTPError.truncated) { try RFC3640.accessUnits(in: Data([0x00])) }
        #expect(throws: RTPError.truncated) { try RFC3640.accessUnits(in: try #require(Data(hex: "0010 0018 aabb"))) }   // AU shorter than its size
        #expect(throws: RTPError.truncated) { try RFC3640.accessUnits(in: try #require(Data(hex: "0020 0018"))) }        // header section cut
        #expect(try RFC3640.accessUnits(in: try #require(Data(hex: "0000"))) == [])
        // Slices.
        let sliced = try #require(Data(hex: "ff 0010 0008 42")).dropFirst()
        #expect(try RFC3640.accessUnits(in: sliced) == [Data([0x42])])
    }

    /// ISO/IEC 14496-3 AudioSpecificConfig for AAC-ELD (object type 39 via the escape), 480-sample frames, no SBR.
    @Test func aacELDAudioSpecificConfig() {
        #expect(AudioDepacketizer.aacELDConfig(sampleRate: 16_000, channels: 1)?.hexString == "f8f03000")
        #expect(AudioDepacketizer.aacELDConfig(sampleRate: 24_000, channels: 1)?.hexString == "f8ec3000")
        #expect(AudioDepacketizer.aacELDConfig(sampleRate: 16_000, channels: 2)?.hexString == "f8f05000")
        #expect(AudioDepacketizer.aacELDConfig(sampleRate: 12_345, channels: 1) == nil)
    }
}

@Suite struct AudioDepacketizerTests {
    @Test func opusFramesKeepPayloadAndUnwrapTimestamps() throws {
        var depacketizer = AudioDepacketizer(codec: .opus, payloadType: 110, clockRate: 24_000, packetTime: .milliseconds(20))
        let start = UInt32.max - 479
        var frames: [EncodedAudioFrame] = []
        for index in 0..<3 {
            let packet = RTPPacket(payloadType: 110, sequenceNumber: UInt16(index), timestamp: start &+ UInt32(index * 480), ssrc: 1, payload: Data([0x78, UInt8(index)]))
            frames += depacketizer.depacketize(packet)
        }
        #expect(frames.map(\.data) == [Data([0x78, 0]), Data([0x78, 1]), Data([0x78, 2])])
        #expect(frames.map(\.pts) == [MediaTime(value: 0, timescale: 24_000), MediaTime(value: 480, timescale: 24_000), MediaTime(value: 960, timescale: 24_000)])
        #expect(frames.allSatisfy { $0.format.codec == .opus && $0.format.sampleRate == 24_000 && $0.format.channels == 1 && $0.sampleCount == 480 })
        // Comfort noise (PT 13) and other payload types are ignored; so are empty payloads.
        #expect(depacketizer.depacketize(RTPPacket(payloadType: 13, sequenceNumber: 3, timestamp: 0, ssrc: 1, payload: Data([0x40]))).isEmpty)
        #expect(depacketizer.depacketize(RTPPacket(payloadType: 110, sequenceNumber: 4, timestamp: 0, ssrc: 1, payload: Data())).isEmpty)
        // A late (reordered) packet maps to an earlier pts instead of a huge jump.
        let late = depacketizer.depacketize(RTPPacket(payloadType: 110, sequenceNumber: 1, timestamp: start &+ 480, ssrc: 1, payload: Data([0x78])))
        #expect(late.first?.pts == MediaTime(value: 480, timescale: 24_000))
    }

    @Test func aacELDFramesAreSplitByAUHeaders() throws {
        var depacketizer = AudioDepacketizer(codec: .aacELD, payloadType: 110, clockRate: 16_000, packetTime: .milliseconds(30))
        let payload = try #require(Data(hex: "0020" + "0018" + "0010" + "aabbcc" + "ddee"))
        let frames = depacketizer.depacketize(RTPPacket(payloadType: 110, sequenceNumber: 0, timestamp: 1_000, ssrc: 1, payload: payload))
        #expect(frames.map(\.data) == [Data([0xAA, 0xBB, 0xCC]), Data([0xDD, 0xEE])])
        #expect(frames.map(\.pts.value) == [0, 480])
        #expect(frames.allSatisfy { $0.sampleCount == 480 && $0.format.audioSpecificConfig?.hexString == "f8f03000" })
        // Malformed AU sections are dropped, not trapped on.
        #expect(depacketizer.depacketize(RTPPacket(payloadType: 110, sequenceNumber: 1, timestamp: 1_480, ssrc: 1, payload: Data([0x00, 0x10, 0xFF]))).isEmpty)
    }

    @Test func packetizerOutputRoundTrips() {
        var packetizer = AudioPacketizer(codec: .aacELD, payloadType: 110, ssrc: 1, initialSequence: 0)
        var depacketizer = AudioDepacketizer(codec: .aacELD, payloadType: 110, clockRate: 16_000, packetTime: .milliseconds(30))
        let au = Data((0..<120).map { UInt8($0) })
        let frame = EncodedAudioFrame(format: AudioFormat(codec: .aacELD, sampleRate: 16_000, channels: 1), data: au, pts: .seconds(0, timescale: 16_000),
                                      sampleCount: 480, wallClock: Date())
        #expect(depacketizer.depacketize(packetizer.packetize(frame, rtpTimestamp: 42)).map(\.data) == [au])
    }
}
