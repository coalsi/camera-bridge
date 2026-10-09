import BridgeSupport
import Foundation
import Testing
@testable import RTP

@Suite struct RTPPacketTests {
    @Test func serializesMinimalPacket() {
        let packet = RTPPacket(marker: true, payloadType: 96, sequenceNumber: 0x1234, timestamp: 0xDEADBEEF, ssrc: 0x01020304, payload: Data([0xAA, 0xBB]))
        #expect(packet.serialized().hexString == "80e01234deadbeef01020304aabb")
        #expect(packet.csrcs.isEmpty && packet.extensionProfile == nil && packet.extensionData == nil)
    }

    @Test func parsesMinimalPacket() throws {
        let packet = try RTPPacket(parsing: try #require(Data(hex: "80e01234deadbeef01020304aabb")))
        #expect(packet.marker)
        #expect(packet.payloadType == 96)
        #expect(packet.sequenceNumber == 0x1234)
        #expect(packet.timestamp == 0xDEADBEEF)
        #expect(packet.ssrc == 0x01020304)
        #expect(packet.payload == Data([0xAA, 0xBB]))
    }

    @Test func roundTripsCSRCsAndExtension() throws {
        var packet = RTPPacket(payloadType: 99, sequenceNumber: 65_535, timestamp: 90_000, ssrc: 0xCAFEBABE, payload: Data(repeating: 0x42, count: 100))
        packet.csrcs = [1, 0xFFFF_FFFF]
        packet.extensionProfile = 0xBEDE
        packet.extensionData = Data([0x10, 0xAA, 0x21, 0xBB, 0xCC, 0x00, 0x00, 0x00])
        let wire = packet.serialized()
        #expect(wire.count == 12 + 8 + 4 + 8 + 100)
        #expect(wire[0] == 0x92)   // V=2, X=1, CC=2
        #expect(try RTPPacket(parsing: wire) == packet)
    }

    @Test func extensionDataIsPaddedToWords() throws {
        var packet = RTPPacket(payloadType: 99, sequenceNumber: 1, timestamp: 2, ssrc: 3, payload: Data([9]))
        packet.extensionProfile = 0x1000
        packet.extensionData = Data([1, 2, 3, 4, 5])
        #expect(packet.extensionData == Data([1, 2, 3, 4, 5, 0, 0, 0]))   // stored as serialized
        let parsed = try RTPPacket(parsing: packet.serialized())
        #expect(parsed.extensionData == Data([1, 2, 3, 4, 5, 0, 0, 0]))
        #expect(parsed.payload == Data([9]))
        #expect(parsed == packet)
    }

    /// `extensionProfile` and `extensionData` are two views of one optional extension.
    @Test func extensionFieldsAreCanonical() throws {
        var packet = RTPPacket(payloadType: 99, sequenceNumber: 1, timestamp: 2, ssrc: 3, payload: Data())
        packet.extensionProfile = 0xBEDE
        #expect(packet.extensionData == Data())
        #expect(try RTPPacket(parsing: packet.serialized()) == packet)

        var dataOnly = RTPPacket(payloadType: 99, sequenceNumber: 1, timestamp: 2, ssrc: 3, payload: Data())
        dataOnly.extensionData = Data([7])
        #expect(dataOnly.extensionProfile == 0 && dataOnly.extensionData == Data([7, 0, 0, 0]))
        #expect(try RTPPacket(parsing: dataOnly.serialized()) == dataOnly)

        dataOnly.extensionProfile = nil
        #expect(dataOnly.extensionData == nil)
        #expect(dataOnly.serialized()[0] & 0x10 == 0)
        packet.extensionData = nil
        #expect(packet.extensionProfile == nil)

        var huge = RTPPacket(payloadType: 99, sequenceNumber: 1, timestamp: 2, ssrc: 3, payload: Data([1]))
        huge.extensionData = Data(count: 65_535 * 4 + 3)
        #expect(huge.extensionData?.count == 65_535 * 4)
        #expect(try RTPPacket(parsing: huge.serialized()) == huge)
    }

    @Test func payloadTypeAndCSRCsKeepTheirWireWidth() throws {
        var packet = RTPPacket(payloadType: 0xE0, sequenceNumber: 1, timestamp: 2, ssrc: 3, payload: Data())
        #expect(packet.payloadType == 0x60)
        packet.payloadType = 0xFF
        #expect(packet.payloadType == 0x7F)
        packet.csrcs = Array(1...20)
        #expect(packet.csrcs == Array(1...15))
        #expect(try RTPPacket(parsing: packet.serialized()) == packet)
    }

    /// `RTPPacket(parsing: p.serialized()) == p` for arbitrary packets built through the public API.
    @Test func randomPacketsRoundTripExactly() throws {
        var rng = SeededGenerator(state: 3550)
        for _ in 0..<2_000 {
            var packet = RTPPacket(marker: Bool.random(using: &rng), payloadType: UInt8.random(in: 0...255, using: &rng),
                                   sequenceNumber: UInt16.random(in: 0...UInt16.max, using: &rng),
                                   timestamp: UInt32.random(in: 0...UInt32.max, using: &rng), ssrc: UInt32.random(in: 0...UInt32.max, using: &rng),
                                   payload: Data((0..<Int.random(in: 0..<40, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }))
            packet.csrcs = (0..<Int.random(in: 0..<20, using: &rng)).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) }
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: break
            case 1: packet.extensionProfile = UInt16.random(in: 0...UInt16.max, using: &rng)
            case 2: packet.extensionData = Data((0..<Int.random(in: 0..<11, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            default:
                packet.extensionData = Data((0..<Int.random(in: 0..<11, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
                packet.extensionProfile = UInt16.random(in: 0...UInt16.max, using: &rng)
            }
            #expect(try RTPPacket(parsing: packet.serialized()) == packet)
        }
    }

    @Test func stripsPadding() throws {
        // P bit set, 3 padding bytes (last byte = count).
        let packet = try RTPPacket(parsing: try #require(Data(hex: "a060000100000002000000030102 000003")))
        #expect(packet.payload == Data([0x01, 0x02]))
        #expect(packet.marker == false)
        #expect(packet.payloadType == 96)
    }

    @Test func rejectsMalformedPackets() throws {
        #expect(throws: RTPError.truncated) { try RTPPacket(parsing: Data(count: 11)) }
        #expect(throws: RTPError.invalidVersion) { try RTPPacket(parsing: Data([0x40] + Array(repeating: 0, count: 11))) }
        #expect(throws: RTPError.truncated) { try RTPPacket(parsing: Data([0x81] + Array(repeating: 0, count: 13))) }   // CC=1, no CSRC
        #expect(throws: RTPError.truncated) {
            try RTPPacket(parsing: try #require(Data(hex: "900000010000000200000003 10000002 aabbccdd")))   // extension claims 2 words
        }
        #expect(throws: RTPError.invalidPadding) { try RTPPacket(parsing: try #require(Data(hex: "a0600001000000020000000301 00"))) }
        #expect(throws: RTPError.invalidPadding) { try RTPPacket(parsing: try #require(Data(hex: "a0600001000000020000000301 05"))) }
    }

    @Test func detectsRTCPByPacketType() throws {
        #expect(RTPPacket.isRTCP(try #require(Data(hex: "80c80006 01020304"))))   // SR
        #expect(RTPPacket.isRTCP(try #require(Data(hex: "81c90001 01020304"))))   // RR
        #expect(RTPPacket.isRTCP(try #require(Data(hex: "81cc0001"))))            // APP (204)
        #expect(RTPPacket.isRTCP(try #require(Data(hex: "81cd0002 01020304 05060708"))))   // RTPFB (205, generic NACK)
        #expect(RTPPacket.isRTCP(try #require(Data(hex: "81ce0002 01020304 05060708"))))   // PSFB PLI (206, FMT 1)
        #expect(RTPPacket.isRTCP(try #require(Data(hex: "84ce0004 01020304 00000000 05060708 01000000"))))   // FIR (FMT 4)
        #expect(!RTPPacket.isRTCP(try #require(Data(hex: "80e01234deadbeef01020304"))))   // PT 96, marker
        #expect(!RTPPacket.isRTCP(try #require(Data(hex: "80631234deadbeef01020304"))))   // PT 99, no marker
        #expect(!RTPPacket.isRTCP(try #require(Data(hex: "806e1234deadbeef01020304"))))   // PT 110 (Opus)
        #expect(!RTPPacket.isRTCP(try #require(Data(hex: "000d0000"))))           // version 0
        #expect(!RTPPacket.isRTCP(Data([0x80])))
        #expect(!RTPPacket.isRTCP(Data()))
    }

    /// RFC 5761 §4: the demux range is exactly 192–223 in the second byte.
    @Test func rtcpRangeBoundaries() {
        for type in 0...255 {
            #expect(RTPPacket.isRTCP(Data([0x80, UInt8(type)])) == (192...223).contains(type), "second byte \(type)")
        }
        // Works on a slice whose indices do not start at 0.
        let buffer = Data([0xFF, 0x80, 0xCE, 0x00, 0x02])
        #expect(RTPPacket.isRTCP(buffer.dropFirst()))
    }
}

/// Deterministic generator for reproducible fuzzing (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
