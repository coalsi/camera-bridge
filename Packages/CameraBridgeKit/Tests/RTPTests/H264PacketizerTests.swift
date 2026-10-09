import BridgeSupport
import Foundation
import MediaCore
import Testing
@testable import RTP

/// In-test RFC 6184 depacketizer (single NAL unit, STAP-A, FU-A), written independently of `H264Packetizer`.
struct H264TestDepacketizer {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private var fragment: Data?
    private var units: [Data] = []
    private(set) var timestamp: UInt32?

    /// Returns the access unit's NAL units when `packet` carries the marker bit.
    mutating func push(_ packet: RTPPacket) throws -> [Data]? {
        if let timestamp, timestamp != packet.timestamp, !units.isEmpty || fragment != nil {
            throw Failure(description: "timestamp changed inside an access unit")
        }
        timestamp = packet.timestamp
        let payload = Data(packet.payload)
        guard let indicator = payload.first else { throw Failure(description: "empty payload") }
        switch indicator & 0x1F {
        case 1...23:
            guard fragment == nil else { throw Failure(description: "single NAL inside a fragmented unit") }
            units.append(payload)
        case 24:
            guard fragment == nil else { throw Failure(description: "STAP-A inside a fragmented unit") }
            var offset = 1
            while offset < payload.count {
                guard offset + 2 <= payload.count else { throw Failure(description: "STAP-A size truncated") }
                let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2
                guard size > 0, offset + size <= payload.count else { throw Failure(description: "STAP-A unit truncated") }
                units.append(payload[offset..<offset + size])
                offset += size
            }
        case 28:
            guard payload.count > 2 else { throw Failure(description: "FU-A without data") }
            let header = payload[1]
            let start = header & 0x80 != 0
            let end = header & 0x40 != 0
            if start {
                guard fragment == nil else { throw Failure(description: "FU-A start while a unit is open") }
                fragment = Data([(indicator & 0xE0) | (header & 0x1F)])
            }
            guard fragment != nil else { throw Failure(description: "FU-A continuation without start") }
            fragment?.append(payload[2...])
            if end, let unit = fragment {
                units.append(unit)
                fragment = nil
            }
        default:
            throw Failure(description: "unexpected NAL type \(indicator & 0x1F)")
        }
        guard packet.marker else { return nil }
        guard fragment == nil else { throw Failure(description: "marker inside a fragmented unit") }
        defer {
            units = []
            timestamp = nil
        }
        return units.map { Data($0) }
    }
}

@Suite struct H264PacketizerTests {
    static let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0x50, 0x05, 0xBB, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00, 0x10])
    static let pps = Data([0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0])
    static let format = VideoFormat(codec: .h264, width: 1280, height: 720, parameterSets: [sps, pps], profile: 0x64, level: 0x1F)

    static func nal(_ header: UInt8, count: Int, seed: UInt8 = 1) -> Data {
        Data([header]) + Data((0..<max(0, count - 1)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    static func frame(_ nals: [Data], keyframe: Bool, format: VideoFormat = format) -> EncodedVideoFrame {
        EncodedVideoFrame(format: format, nalUnits: nals, isKeyframe: keyframe, pts: .seconds(0), wallClock: Date())
    }

    static func depacketize(_ packets: [RTPPacket]) throws -> [[Data]] {
        var depacketizer = H264TestDepacketizer()
        return try packets.compactMap { try depacketizer.push($0) }
    }

    @Test func keyframeStartsWithSTAPAThenFUA() throws {
        var packetizer = H264Packetizer(payloadType: 99, ssrc: 0xAABB_CCDD, maxPacketSize: 1200, initialSequence: 100)
        let idr = Self.nal(0x65, count: 3_000)
        let packets = packetizer.packetize(Self.frame([idr], keyframe: true), rtpTimestamp: 1234)
        #expect(packets.count == 4)
        // STAP-A header 24 with F = 0 and NRI = 0 (no NRI aggregation), then SPS and PPS with 16-bit sizes.
        #expect(packets[0].payload == Data([24, 0, UInt8(Self.sps.count)]) + Self.sps + Data([0, UInt8(Self.pps.count)]) + Self.pps)
        #expect(packets[1].payload.prefix(2) == Data([0x7C, 0x85]))   // FU indicator NRI 3 | 28, S bit | type 5
        #expect(packets[2].payload.prefix(2) == Data([0x7C, 0x05]))
        #expect(packets[3].payload.prefix(2) == Data([0x7C, 0x45]))   // E bit
        #expect(packets.map(\.marker) == [false, false, false, true])
        #expect(packets.map(\.sequenceNumber) == [100, 101, 102, 103])
        #expect(packets.allSatisfy { $0.timestamp == 1234 && $0.ssrc == 0xAABB_CCDD && $0.payloadType == 99 })
        #expect(packets.allSatisfy { $0.serialized().count <= 1200 })
        #expect(packets[1].serialized().count == 1200)   // fragments fill the packet
        #expect(try Self.depacketize(packets) == [[Self.sps, Self.pps, idr]])
    }

    @Test func deltaFrameIsASingleNALPacket() throws {
        var packetizer = H264Packetizer(payloadType: 99, ssrc: 1, initialSequence: 7)
        let slice = Self.nal(0x41, count: 500)
        let packets = packetizer.packetize(Self.frame([slice], keyframe: false), rtpTimestamp: 90_000)
        #expect(packets.count == 1)
        #expect(packets[0].payload == slice && packets[0].marker && packets[0].sequenceNumber == 7)
        // The next frame continues the sequence.
        #expect(packetizer.packetize(Self.frame([slice], keyframe: false), rtpTimestamp: 93_000).first?.sequenceNumber == 8)
    }

    @Test func everyNALGetsItsOwnPacketsAndOnlyTheLastIsMarked() throws {
        var packetizer = H264Packetizer(payloadType: 99, ssrc: 1, maxPacketSize: 1000, initialSequence: 0)
        let nals = [Self.nal(0x06, count: 20), Self.nal(0x41, count: 2_500, seed: 2), Self.nal(0x41, count: 100, seed: 3)]
        let packets = packetizer.packetize(Self.frame(nals, keyframe: false), rtpTimestamp: 5)
        #expect(packets.count == 1 + 3 + 1)
        #expect(packets.map(\.marker) == [false, false, false, false, true])
        #expect(packets.allSatisfy { $0.serialized().count <= 1000 })
        #expect(try Self.depacketize(packets) == [nals])
    }

    @Test func singleNALBoundary() throws {
        var packetizer = H264Packetizer(payloadType: 99, ssrc: 1, maxPacketSize: 300, initialSequence: 0)
        let fits = Self.nal(0x41, count: 300 - 12)
        #expect(packetizer.packetize(Self.frame([fits], keyframe: false), rtpTimestamp: 0).map(\.payload) == [fits])
        let tooBig = Self.nal(0x41, count: 300 - 11)
        let packets = packetizer.packetize(Self.frame([tooBig], keyframe: false), rtpTimestamp: 0)
        #expect(packets.count == 2)
        #expect(packets.allSatisfy { $0.payload[0] & 0x1F == 28 && $0.serialized().count <= 300 })
        #expect(try Self.depacketize(packets) == [[tooBig]])
    }

    @Test func sequenceNumbersWrap() {
        var packetizer = H264Packetizer(payloadType: 99, ssrc: 1, maxPacketSize: 200, initialSequence: 65_534)
        let packets = packetizer.packetize(Self.frame([Self.nal(0x65, count: 600)], keyframe: true), rtpTimestamp: 0)
        #expect(packets.map(\.sequenceNumber) == [65_534, 65_535, 0, 1, 2])
    }

    /// Parameter sets carried in the access unit replace the format's; access unit delimiters are dropped.
    @Test func inBandParameterSetsAndDelimiters() throws {
        var packetizer = H264Packetizer(payloadType: 99, ssrc: 1, initialSequence: 0)
        let bare = VideoFormat(codec: .h264, width: 0, height: 0, parameterSets: [])
        let newSPS = Data([0x67, 0x4D, 0x00, 0x28, 0x01])
        let newPPS = Data([0x68, 0xEE, 0x01])
        let idr = Self.nal(0x65, count: 200)
        let aud = Data([0x09, 0xF0])
        let packets = packetizer.packetize(Self.frame([aud, newSPS, newPPS, idr], keyframe: true, format: bare), rtpTimestamp: 0)
        #expect(packets.count == 2 && packets[0].payload.first == 24)
        #expect(try Self.depacketize(packets) == [[newSPS, newPPS, idr]])

        let inBandOverFormat = packetizer.packetize(Self.frame([newSPS, newPPS, idr], keyframe: true), rtpTimestamp: 0)
        #expect(try Self.depacketize(inBandOverFormat) == [[newSPS, newPPS, idr]])

        // A keyframe without any parameter sets still goes out (no STAP-A); a delta frame never gets one.
        let noSets = packetizer.packetize(Self.frame([idr], keyframe: true, format: bare), rtpTimestamp: 0)
        #expect(noSets.count == 1 && noSets[0].payload == idr)
        #expect(packetizer.packetize(Self.frame([Self.nal(0x41, count: 10)], keyframe: false), rtpTimestamp: 0).count == 1)
    }

    @Test func oversizedParameterSetsAreSentSeparately() throws {
        var packetizer = H264Packetizer(payloadType: 99, ssrc: 1, maxPacketSize: 400, initialSequence: 0)
        let bigSPS = Self.nal(0x67, count: 700)
        let format = VideoFormat(codec: .h264, width: 0, height: 0, parameterSets: [bigSPS, Self.pps])
        let idr = Self.nal(0x65, count: 50)
        let packets = packetizer.packetize(Self.frame([idr], keyframe: true, format: format), rtpTimestamp: 0)
        #expect(packets.allSatisfy { $0.serialized().count <= 400 })
        #expect(try Self.depacketize(packets) == [[bigSPS, Self.pps, idr]])
    }

    @Test func emptyInputProducesNothing() {
        var packetizer = H264Packetizer(payloadType: 99, ssrc: 1, initialSequence: 0)
        #expect(packetizer.packetize(Self.frame([], keyframe: true), rtpTimestamp: 0).isEmpty)
        #expect(packetizer.packetize(Self.frame([Data(), Data([0x09, 0x10])], keyframe: false), rtpTimestamp: 0).isEmpty)
        // Nothing was consumed from the sequence.
        #expect(packetizer.packetize(Self.frame([Self.nal(0x41, count: 5)], keyframe: false), rtpTimestamp: 0).first?.sequenceNumber == 0)
    }

    /// Nonsensical limits are raised to the smallest workable packet (12-byte header + 2-byte FU header + 1 byte).
    @Test func tinyMaxPacketSizeStillWorks() throws {
        var packetizer = H264Packetizer(payloadType: 99, ssrc: 1, maxPacketSize: 0, initialSequence: 0)
        let idr = Self.nal(0x65, count: 40)
        let packets = packetizer.packetize(Self.frame([idr], keyframe: true), rtpTimestamp: 0)
        #expect(packets.allSatisfy { $0.serialized().count <= 15 })
        #expect(try Self.depacketize(packets) == [[Self.sps, Self.pps, idr]])
    }

    @Test func randomAccessUnitsRoundTrip() throws {
        var rng = SeededGenerator(state: 6184)
        for _ in 0..<250 {
            let maxPacketSize = Int.random(in: 40...1_500, using: &rng)
            var packetizer = H264Packetizer(payloadType: 96, ssrc: 9, maxPacketSize: maxPacketSize, initialSequence: UInt16.random(in: 0...UInt16.max, using: &rng))
            var depacketizer = H264TestDepacketizer()
            var expectedSequence: UInt16?
            for frameIndex in 0..<4 {
                let keyframe = frameIndex == 0 || Bool.random(using: &rng)
                var nals: [Data] = []
                for n in 0..<Int.random(in: 1...5, using: &rng) {
                    let header: UInt8 = keyframe && n == 0 ? 0x65 : [0x41, 0x01, 0x06, 0x21].randomElement(using: &rng) ?? 0x41
                    nals.append(Self.nal(header, count: Int.random(in: 1...6_000, using: &rng), seed: UInt8.random(in: 0...255, using: &rng)))
                }
                let timestamp = UInt32.random(in: 0...UInt32.max, using: &rng)
                let packets = packetizer.packetize(Self.frame(nals, keyframe: keyframe), rtpTimestamp: timestamp)
                #expect(packets.allSatisfy { $0.serialized().count <= maxPacketSize && $0.timestamp == timestamp })
                #expect(packets.filter(\.marker).count == 1 && packets.last?.marker == true)
                for packet in packets {
                    if let expectedSequence { #expect(packet.sequenceNumber == expectedSequence) }
                    expectedSequence = packet.sequenceNumber &+ 1
                }
                let units = try packets.compactMap { try depacketizer.push($0) }
                #expect(units == [(keyframe ? [Self.sps, Self.pps] : []) + nals])
            }
        }
    }
}
