import BridgeSupport
import Foundation
import Testing
@testable import RTP

/// RFC 3711 AES_CM_128_HMAC_SHA1_80. Vectors: RFC 3711 Appendix B.2 (AES-CM keystream) and B.3 (key derivation);
/// the full-packet vectors are libsrtp's reference packets (`srtp_driver.c`), re-derived independently with
/// `openssl enc -aes-128-ctr` and `openssl dgst -sha1 -mac HMAC` from the B.3 session keys.
@Suite struct SRTPTests {
    static let masterKey = Data(hex: "E1F97A0D3E018BE0D64FA32C06DE4139")!
    static let masterSalt = Data(hex: "0EC675AD498AFEEBB6960B3AABE6")!

    // MARK: RFC 3711 Appendix B

    @Test func aesCounterModeKeystreamMatchesRFC3711B2() throws {
        let key = try #require(Data(hex: "2B7E151628AED2A6ABF7158809CF4F3C"))
        let start = try AESCounterMode.keystream(key: key, iv: try #require(Data(hex: "F0F1F2F3F4F5F6F7F8F9FAFBFCFD0000")), count: 48)
        #expect(start.hexString == "e03ead0935c95e80e166b16dd92b4eb4" + "d23513162b02d0f72a43a2fe4a5f97ab" + "41e95b3bb0a2e8dd477901e4fca894c0")
        // The counter carries from byte 15 into byte 14 (FEFF → FF00 → FF01).
        let end = try AESCounterMode.keystream(key: key, iv: try #require(Data(hex: "F0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF")), count: 48)
        #expect(end.hexString == "ec8cdf7398607cb0f2d21675ea9ea1e4" + "362b7c3c6773516318a077d7fc5073ae" + "6a2cc3787889374fbeb4c81b17ba6c44")
        // XOR form used for payloads: applying the keystream twice is the identity; partial blocks work.
        var buffer = Data((0..<37).map { UInt8($0) })
        try AESCounterMode.apply(key: key, iv: try #require(Data(hex: "F0F1F2F3F4F5F6F7F8F9FAFBFCFD0000")), to: &buffer, from: 3)
        #expect(Array(buffer.prefix(3)) == [0, 1, 2])
        #expect(buffer[3] == 3 ^ 0xE0)
        try AESCounterMode.apply(key: key, iv: try #require(Data(hex: "F0F1F2F3F4F5F6F7F8F9FAFBFCFD0000")), to: &buffer, from: 3)
        #expect(buffer == Data((0..<37).map { UInt8($0) }))
    }

    @Test func keyDerivationMatchesRFC3711B3() throws {
        let rtp = try SRTPSessionKeys(masterKey: Self.masterKey, masterSalt: Self.masterSalt, rtcp: false)
        #expect(rtp.encryptionKey.hexString == "c61e7a93744f39ee10734afe3ff7a087")
        #expect(rtp.salt.hexString == "30cbbc08863d8c85d49db34a9ae1")
        #expect(rtp.authenticationKey.hexString == "cebe321f6ff7716b6fd4ab49af256a156d38baa4")
        // Labels 3/4/5 (SRTCP), same PRF (values computed with openssl from the B.3 master key/salt).
        let rtcp = try SRTPSessionKeys(masterKey: Self.masterKey, masterSalt: Self.masterSalt, rtcp: true)
        #expect(rtcp.encryptionKey.hexString == "4c1aa45a81f73d61c800bbb00fbb1eaa")
        #expect(rtcp.salt.hexString == "9581c7ad87b3e530bf3e4454a8b3")
        #expect(rtcp.authenticationKey.hexString == "8d54534feb49ae8e7993a6bd0b844fc323a93dfd")
    }

    // MARK: SRTP

    @Test func protectMatchesReferencePacket() throws {
        var context = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        let plain = try #require(Data(hex: "800f1234decafbadcafebabe" + String(repeating: "ab", count: 16)))
        let protected = try context.protectRTP(plain)
        #expect(protected.hexString == "800f1234decafbadcafebabe" + "4e55dc4ce79978d88ca4d215949d2402" + "b78d6acc99ea179b8dbb")

        var receiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        #expect(try receiver.unprotectRTP(protected) == plain)
    }

    @Test func protectUnprotectRoundTripKeepsHeaderInClear() throws {
        var rng = SeededGenerator(state: 3711)
        var sender = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        var receiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        var sequence: UInt16 = 40_000
        for _ in 0..<300 {
            var packet = RTPPacket(marker: Bool.random(using: &rng), payloadType: 99, sequenceNumber: sequence, timestamp: UInt32.random(in: 0...UInt32.max, using: &rng),
                                   ssrc: 0x1234_5678, payload: Data((0..<Int.random(in: 0..<1_300, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }))
            if Bool.random(using: &rng) { packet.csrcs = [1, 2, 3] }
            if Bool.random(using: &rng) { packet.extensionProfile = 0xBEDE; packet.extensionData = Data([0x10, 0xAA, 0, 0]) }
            let wire = packet.serialized()
            let protected = try sender.protectRTP(wire)
            #expect(protected.count == wire.count + 10)
            let headerLength = wire.count - packet.payload.count
            #expect(protected.prefix(headerLength) == wire.prefix(headerLength))
            if packet.payload.count >= 8 { #expect(protected[headerLength..<wire.count] != wire[headerLength...]) }
            #expect(try receiver.unprotectRTP(protected) == wire)
            sequence &+= 1
        }
    }

    @Test func tamperingFailsAuthentication() throws {
        var sender = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        let plain = RTPPacket(payloadType: 99, sequenceNumber: 7, timestamp: 9, ssrc: 0xCAFE_BABE, payload: Data(repeating: 0x55, count: 40)).serialized()
        let protected = try sender.protectRTP(plain)
        for index in [1, 3, 8, 12, 30, protected.count - 10, protected.count - 1] {
            var tampered = protected
            tampered[index] ^= 0x01
            var receiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
            #expect(throws: SRTPError.authenticationFailed) { try receiver.unprotectRTP(tampered) }
            // A failed packet leaves no state behind: the genuine packet still passes.
            #expect(try receiver.unprotectRTP(protected) == plain)
        }
        var otherKey = try SRTPContext(masterKey: Data(repeating: 7, count: 16), masterSalt: Self.masterSalt)
        #expect(throws: SRTPError.authenticationFailed) { try otherKey.unprotectRTP(protected) }
    }

    @Test func malformedInputThrows() throws {
        #expect(throws: SRTPError.malformed) { try SRTPContext(masterKey: Data(count: 15), masterSalt: Self.masterSalt) }
        #expect(throws: SRTPError.malformed) { try SRTPContext(masterKey: Self.masterKey, masterSalt: Data(count: 16)) }
        var context = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        #expect(throws: SRTPError.malformed) { try context.protectRTP(Data()) }
        #expect(throws: SRTPError.malformed) { try context.protectRTP(Data(count: 11)) }
        #expect(throws: SRTPError.malformed) { try context.protectRTP(Data([0x40] + Array(repeating: 0, count: 11))) }   // version 1
        #expect(throws: SRTPError.malformed) { try context.protectRTP(Data([0x81] + Array(repeating: 0, count: 13))) }   // CC=1, no CSRC
        #expect(throws: SRTPError.malformed) { try context.unprotectRTP(Data(count: 21)) }
        #expect(throws: SRTPError.malformed) { try context.unprotectRTP(Data([0x8F] + Array(repeating: 0, count: 40))) }   // 15 CSRCs > packet
        #expect(throws: SRTPError.malformed) { try context.protectRTCP(Data(count: 7)) }
        #expect(throws: SRTPError.malformed) { try context.unprotectRTCP(Data(count: 21)) }
        // Slices whose indices do not start at 0 are handled.
        let plain = RTPPacket(payloadType: 99, sequenceNumber: 1, timestamp: 2, ssrc: 3, payload: Data([1, 2, 3])).serialized()
        let protected = try context.protectRTP((Data([0xFF]) + plain).dropFirst())
        #expect(try context.unprotectRTP((Data([0xEE]) + protected).dropFirst()) == plain)
    }

    @Test func headerOnlyPacketsRoundTrip() throws {
        var sender = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        var receiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        let plain = RTPPacket(payloadType: 13, sequenceNumber: 100, timestamp: 2, ssrc: 3, payload: Data()).serialized()
        #expect(try receiver.unprotectRTP(try sender.protectRTP(plain)) == plain)
    }

    /// The rollover counter advances when the sequence number wraps (RFC 3711 §3.3.1), on both sides.
    @Test func rolloverCounterAdvancesAtSequenceWrap() throws {
        var sender = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        var receiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        let payload = String(repeating: "ab", count: 16)
        var protected: [Data] = []
        for sequence in ["fffe", "ffff", "0000", "0001"] {
            protected.append(try sender.protectRTP(try #require(Data(hex: "800f" + sequence + "decafbadcafebabe" + payload))))
        }
        // Sequence 0 after the wrap is encrypted and authenticated with ROC = 1 (openssl-computed vector).
        #expect(protected[2].hexString == "800f0000decafbadcafebabe" + "24ecf92d9c97bf2ac679b796fdfd365a" + "267beecdc56456590e62")
        for packet in protected {
            #expect(try receiver.unprotectRTP(packet).suffix(16) == Data(repeating: 0xAB, count: 16))
        }
        // A late packet from before the wrap still decrypts with ROC = 0 (v = ROC − 1).
        var lateReceiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        _ = try lateReceiver.unprotectRTP(protected[0])
        _ = try lateReceiver.unprotectRTP(protected[2])
        _ = try lateReceiver.unprotectRTP(protected[3])
        #expect(try lateReceiver.unprotectRTP(protected[1]).prefix(4).hexString == "800fffff")
        // Many wraps: 200 000 packets → ROC 3, still in sync.
        var longSender = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        var longReceiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        var sequence: UInt16 = 65_000
        for index in 0..<200_000 {
            let packet = try longSender.protectRTP(RTPPacket(payloadType: 99, sequenceNumber: sequence, timestamp: 0, ssrc: 1, payload: Data([UInt8(truncatingIfNeeded: index)])).serialized())
            if index % 997 == 0 || index > 199_990 { _ = try longReceiver.unprotectRTP(packet) }
            sequence &+= 1
        }
    }

    @Test func replayedPacketsAreRejected() throws {
        var sender = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        var receiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        var packets: [Data] = []
        for sequence in UInt16(10)..<UInt16(110) {
            packets.append(try sender.protectRTP(RTPPacket(payloadType: 99, sequenceNumber: sequence, timestamp: 0, ssrc: 5, payload: Data([1])).serialized()))
        }
        _ = try receiver.unprotectRTP(packets[0])
        #expect(throws: SRTPError.replay) { try receiver.unprotectRTP(packets[0]) }
        _ = try receiver.unprotectRTP(packets[99])
        // Out of order inside the 64-packet window is fine, once.
        _ = try receiver.unprotectRTP(packets[50])
        #expect(throws: SRTPError.replay) { try receiver.unprotectRTP(packets[50]) }
        // Older than the window.
        #expect(throws: SRTPError.replay) { try receiver.unprotectRTP(packets[20]) }
    }

    // MARK: SRTCP

    @Test func srtcpMatchesReferencePacketWithIndexAndEBit() throws {
        var sender = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        let plain = try #require(Data(hex: "81c8000bcafebabe" + String(repeating: "ab", count: 16)))
        let first = try sender.protectRTCP(plain)
        // Index 1 (first SRTCP packet, as libsrtp and werift number them), E bit set, 80-bit tag.
        #expect(first.hexString == "81c8000bcafebabe" + "7128035be487b9bdbef89041f977a5a8" + "80000001" + "993e08cd54d6c1230798")
        let second = try sender.protectRTCP(plain)
        #expect(second.count == plain.count + 14)
        #expect(second[second.count - 14..<second.count - 10].hexString == "80000002")
        #expect(second.prefix(8) == plain.prefix(8))   // header + sender SSRC stay in clear

        var receiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        #expect(try receiver.unprotectRTCP(first) == plain)
        #expect(try receiver.unprotectRTCP(second) == plain)
        #expect(throws: SRTPError.replay) { try receiver.unprotectRTCP(first) }

        var tampered = second
        tampered[10] ^= 0x80
        var fresh = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        #expect(throws: SRTPError.authenticationFailed) { try fresh.unprotectRTCP(tampered) }
        var flippedEBit = second
        flippedEBit[flippedEBit.count - 14] ^= 0x80
        #expect(throws: SRTPError.authenticationFailed) { try fresh.unprotectRTCP(flippedEBit) }
    }

    /// E = 0: the payload is sent in clear but still authenticated.
    @Test func unencryptedSRTCPIsAccepted() throws {
        let keys = try SRTPSessionKeys(masterKey: Self.masterKey, masterSalt: Self.masterSalt, rtcp: true)
        var packet = RTCPPacket.receiverReport(ssrc: 0x0102_0304).serialized()
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x07])
        packet.append(keys.tag(for: packet))
        var receiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        #expect(try receiver.unprotectRTCP(packet) == RTCPPacket.receiverReport(ssrc: 0x0102_0304).serialized())
    }

    @Test func srtcpIndexIsPerSSRC() throws {
        var sender = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        let a = try sender.protectRTCP(RTCPPacket.receiverReport(ssrc: 1).serialized())
        let b = try sender.protectRTCP(RTCPPacket.receiverReport(ssrc: 2).serialized())
        let a2 = try sender.protectRTCP(RTCPPacket.receiverReport(ssrc: 1).serialized())
        #expect(a[8..<12].hexString == "80000001")
        #expect(b[8..<12].hexString == "80000001")
        #expect(a2[8..<12].hexString == "80000002")
    }
}
