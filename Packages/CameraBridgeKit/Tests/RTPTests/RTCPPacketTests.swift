import BridgeSupport
import Foundation
import Testing
@testable import RTP

/// RFC 3550 §6.4 (SR/RR), §6.6 (BYE); RFC 4585 §6.3.1 (PLI); RFC 5104 §4.3.1 (FIR).
@Suite struct RTCPPacketTests {
    @Test func serializesEachPacketType() {
        #expect(RTCPPacket.senderReport(ssrc: 0x0102_0304, ntp: 0x0102_0304_0506_0708, rtpTimestamp: 0x1122_3344, packetCount: 10, octetCount: 1_000)
            .serialized().hexString == "80c80006" + "01020304" + "0102030405060708" + "11223344" + "0000000a" + "000003e8")
        #expect(RTCPPacket.receiverReport(ssrc: 0xCAFE_BABE).serialized().hexString == "80c90001" + "cafebabe")
        #expect(RTCPPacket.bye(ssrcs: [1, 2]).serialized().hexString == "82cb0002" + "00000001" + "00000002")
        #expect(RTCPPacket.bye(ssrcs: []).serialized().hexString == "80cb0000")
        #expect(RTCPPacket.pictureLossIndication(senderSSRC: 0xAAAA_AAAA, mediaSSRC: 0xBBBB_BBBB).serialized().hexString
            == "81ce0002" + "aaaaaaaa" + "bbbbbbbb")
        // FIR: media source SSRC in the common header is 0; the target SSRC is in the FCI (seq nr 0, reserved 0).
        #expect(RTCPPacket.fullIntraRequest(senderSSRC: 0xAAAA_AAAA, mediaSSRC: 0xBBBB_BBBB).serialized().hexString
            == "84ce0004" + "aaaaaaaa" + "00000000" + "bbbbbbbb" + "00000000")
        #expect(RTCPPacket.other(type: 202).serialized().hexString == "80ca0000")
    }

    @Test func eachPacketRoundTrips() throws {
        let packets: [RTCPPacket] = [
            .senderReport(ssrc: 1, ntp: .max, rtpTimestamp: .max, packetCount: .max, octetCount: 0),
            .receiverReport(ssrc: 2),
            .bye(ssrcs: [3, 4, 5]),
            .bye(ssrcs: []),
            .pictureLossIndication(senderSSRC: 6, mediaSSRC: 7),
            .fullIntraRequest(senderSSRC: 8, mediaSSRC: 9),
            .other(type: 202), .other(type: 204), .other(type: 205), .other(type: 207),
        ]
        for packet in packets {
            #expect(try RTCPPacket.parseCompound(packet.serialized()) == [packet])
        }
        // Compound: concatenation parses back in order.
        let compound = packets.reduce(into: Data()) { $0.append($1.serialized()) }
        #expect(try RTCPPacket.parseCompound(compound) == packets)
    }

    @Test func parsesReportsWithReportBlocksAndCompoundWithSDES() throws {
        // SR with one report block (RC=1, length 12) + SDES CNAME + PSFB PLI, as a controller would send.
        let sr = "81c8000c" + "01020304" + "e1234567" + "89abcdef" + "00015f90" + "00000064" + "00001000"
            + "0a0b0c0d" + "00000000" + "0000ffff" + "00000010" + "00000000" + "00000000"
        let sdes = "81ca0003" + "01020304" + "01046e616d65" + "0000"
        let pli = "81ce0002" + "01020304" + "05060708"
        let parsed = try RTCPPacket.parseCompound(try #require(Data(hex: sr + sdes + pli)))
        #expect(parsed == [
            .senderReport(ssrc: 0x0102_0304, ntp: 0xE123_4567_89AB_CDEF, rtpTimestamp: 90_000, packetCount: 100, octetCount: 4_096,
                          blocks: [RTCPReportBlock(ssrc: 0x0A0B_0C0D, extendedHighestSequence: 0xFFFF, jitter: 0x10)]),
            .other(type: 202),
            .pictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708),
        ])
        // RR with one report block.
        let rr = "81c90007" + "cafebabe" + "0a0b0c0d" + "00000000" + "0000ffff" + "00000010" + "00000000" + "00000000"
        #expect(try RTCPPacket.parseCompound(try #require(Data(hex: rr))) == [.receiverReport(ssrc: 0xCAFE_BABE, blocks: [RTCPReportBlock(ssrc: 0x0A0B_0C0D, extendedHighestSequence: 0xFFFF, jitter: 0x10)])])
        // BYE with a reason string after the SSRC list.
        #expect(try RTCPPacket.parseCompound(try #require(Data(hex: "81cb0003" + "00000009" + "03627965" + "00000000")))
            == [.bye(ssrcs: [9])])
    }

    // MARK: Report blocks (RFC 3550 §6.4.1)

    @Test func reportBlocksSerializeAndParseBackForSendersAndReceivers() throws {
        let blocks = [RTCPReportBlock(ssrc: 0x1111_1111, fractionLost: 255, cumulativeLost: 0x7F_FFFF, extendedHighestSequence: 0x0001_FFFE, jitter: 77,
                                      lastSenderReport: 0xABCD_1234, delaySinceLastSenderReport: 65_536),
                      RTCPReportBlock(ssrc: 0x2222_2222, fractionLost: 0, cumulativeLost: -1, extendedHighestSequence: 5)]
        let receiver = RTCPPacket.receiverReport(ssrc: 9, blocks: blocks)
        // Header: RC = 2, length = 1 + 2 * 6 words.
        let expectedStart = ["82c9000d", "00000009", "11111111", "ff7fffff", "0001fffe", "0000004d", "abcd1234", "00010000"].joined()
        #expect(receiver.serialized().hexString.hasPrefix(expectedStart))
        #expect(try RTCPPacket.parseCompound(receiver.serialized()) == [receiver])
        let sender = RTCPPacket.senderReport(ssrc: 1, ntp: 2, rtpTimestamp: 3, packetCount: 4, octetCount: 5, blocks: blocks)
        #expect(sender.serialized().hexString.hasPrefix("82c80012"))
        #expect(try RTCPPacket.parseCompound(sender.serialized()) == [sender])
        // Without blocks the packets are the ones they always were.
        #expect(RTCPPacket.receiverReport(ssrc: 0xCAFE_BABE).serialized().hexString == "80c90001cafebabe")
    }

    @Test func cumulativeLostIsA24BitSignedValue() throws {
        for lost: Int32 in [0, 1, -1, 255, -256, 0x7F_FFFF, -0x80_0000, 12_345, -12_345] {
            let packet = RTCPPacket.receiverReport(ssrc: 1, blocks: [RTCPReportBlock(ssrc: 2, cumulativeLost: lost)])
            guard case let .receiverReport(_, parsed) = try RTCPPacket.parseCompound(packet.serialized())[0] else {
                Issue.record("not an RR")
                continue
            }
            #expect(parsed.first?.cumulativeLost == lost, "\(lost)")
        }
        // Out of range values saturate instead of wrapping into the other sign.
        let high = RTCPPacket.receiverReport(ssrc: 1, blocks: [RTCPReportBlock(ssrc: 2, cumulativeLost: 0x100_0000)])
        guard case let .receiverReport(_, blocks) = try RTCPPacket.parseCompound(high.serialized())[0] else { return }
        #expect(blocks.first?.cumulativeLost == 0x7F_FFFF)
        // Wire bytes: 0xFFFFFF is -1, 0x800000 the most negative value.
        let wireHex = ["81c90007", "00000001", "00000002", "00ffffff", "00000000", "00000000", "00000000", "00000000"].joined()
        let wire = try #require(Data(hex: wireHex))
        guard case let .receiverReport(_, minusOne) = try RTCPPacket.parseCompound(wire)[0] else { return }
        #expect(minusOne.first?.cumulativeLost == -1)
    }

    @Test func aReportCountThatDoesNotFitIsTruncated() throws {
        // RC = 2 but the packet holds one block.
        let shortHex = ["82c90007", "00000001", "00000002", "00000000", "00000000", "00000000", "00000000", "00000000"].joined()
        let short = try #require(Data(hex: shortHex))
        #expect(throws: RTPError.truncated) { try RTCPPacket.parseCompound(short) }
        // More than 31 blocks are not written (the count field is 5 bits).
        let many = RTCPPacket.receiverReport(ssrc: 1, blocks: (0..<40).map { RTCPReportBlock(ssrc: UInt32($0)) })
        guard case let .receiverReport(_, kept) = try RTCPPacket.parseCompound(many.serialized())[0] else { return }
        #expect(kept.count == 31)
    }

    @Test func feedbackMessagesOtherThanPLIAndFIRAreOther() throws {
        // RTPFB generic NACK (205/1), PSFB SLI (206/2), PSFB REMB (206/15).
        let nack = "81cd0003" + "01020304" + "05060708" + "00100000"
        let sli = "82ce0003" + "01020304" + "05060708" + "00000000"
        let remb = "8fce0005" + "01020304" + "00000000" + "52454d42" + "01000001" + "05060708"
        #expect(try RTCPPacket.parseCompound(try #require(Data(hex: nack + sli + remb))) == [.other(type: 205), .other(type: 206), .other(type: 206)])
        // FIR whose target is only in the FCI; the old RFC 2032 FIR (192) is `other`.
        let fir = "84ce0006" + "01020304" + "00000000" + "0a0b0c0d" + "07000000" + "0e0f1011" + "08000000"
        #expect(try RTCPPacket.parseCompound(try #require(Data(hex: fir))) == [.fullIntraRequest(senderSSRC: 0x0102_0304, mediaSSRC: 0x0A0B_0C0D)])
        #expect(try RTCPPacket.parseCompound(try #require(Data(hex: "80c00001" + "01020304"))) == [.other(type: 192)])
    }

    @Test func paddingInTheLastPacketIsIgnored() throws {
        // RR with P bit and 4 bytes of padding (included in the length).
        let padded = try #require(Data(hex: "a0c90002" + "01020304" + "00000004"))
        #expect(try RTCPPacket.parseCompound(padded) == [.receiverReport(ssrc: 0x0102_0304)])
    }

    @Test func malformedCompoundsThrow() throws {
        #expect(try RTCPPacket.parseCompound(Data()) == [])
        #expect(throws: RTPError.truncated) { try RTCPPacket.parseCompound(Data([0x80, 0xC9, 0x00])) }
        #expect(throws: RTPError.invalidVersion) { try RTCPPacket.parseCompound(try #require(Data(hex: "40c90001 01020304"))) }
        // Length field claims more than is present.
        #expect(throws: RTPError.truncated) { try RTCPPacket.parseCompound(try #require(Data(hex: "80c90002 01020304"))) }
        // SR too short for its sender info; RR without SSRC; PLI without media SSRC; BYE whose count exceeds its length.
        #expect(throws: RTPError.truncated) { try RTCPPacket.parseCompound(try #require(Data(hex: "80c80001 01020304"))) }
        #expect(throws: RTPError.truncated) { try RTCPPacket.parseCompound(try #require(Data(hex: "80c90000"))) }
        #expect(throws: RTPError.truncated) { try RTCPPacket.parseCompound(try #require(Data(hex: "81ce0001 01020304"))) }
        #expect(throws: RTPError.truncated) { try RTCPPacket.parseCompound(try #require(Data(hex: "82cb0001 01020304"))) }
        // SR report count larger than the packet.
        #expect(throws: RTPError.truncated) {
            try RTCPPacket.parseCompound(try #require(Data(hex: "81c80006" + "01020304" + "0000000000000000" + "00000000" + "00000000" + "00000000")))
        }
        // Trailing garbage after a valid packet.
        #expect(throws: RTPError.truncated) { try RTCPPacket.parseCompound(try #require(Data(hex: "80c90001 01020304 80"))) }
        // Works on slices.
        let buffer = try #require(Data(hex: "ff 80c90001 01020304"))
        #expect(try RTCPPacket.parseCompound(buffer.dropFirst()) == [.receiverReport(ssrc: 0x0102_0304)])
    }

    @Test func randomBytesNeverTrap() {
        var rng = SeededGenerator(state: 3550_2)
        for _ in 0..<5_000 {
            var bytes = (0..<Int.random(in: 0..<64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if !bytes.isEmpty { bytes[0] = 0x80 | (bytes[0] & 0x3F) }
            _ = try? RTCPPacket.parseCompound(Data(bytes))
        }
    }

    @Test func byeWithMoreThan31SSRCsKeepsTheFirst31() throws {
        let ssrcs = (0..<40).map { UInt32($0) }
        let wire = RTCPPacket.bye(ssrcs: ssrcs).serialized()
        #expect(try RTCPPacket.parseCompound(wire) == [.bye(ssrcs: Array(ssrcs.prefix(31)))])
    }
}
