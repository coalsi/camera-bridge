import Foundation

public enum SRTPError: Error, Equatable {
    case authenticationFailed, malformed, replay
}

/// AES_CM_128_HMAC_SHA1_80 (RFC 3711), key derivation rate 0; 16-byte master key, 14-byte master salt, 80-bit tags.
///
/// One context holds independent per-SSRC state for each of the four operations, so the same value can protect one
/// direction and unprotect the other. Outbound: the rollover counter advances when the sequence number wraps; the
/// SRTCP index starts at 1 for each SSRC (as libsrtp and werift number it) and always sets the E bit. Inbound: the
/// index is estimated per RFC 3711 §3.3.1, the tag is checked (constant time) before anything else, then a 64-packet
/// replay window; state changes only after a packet authenticates, so forged packets leave no trace.
/// Inputs may be `Data` slices; outputs always start at index 0.
public struct SRTPContext: Sendable {
    private let rtpKeys: SRTPSessionKeys
    private let rtcpKeys: SRTPSessionKeys
    private var outboundRTP: [UInt32: SRTPStreamState] = [:]
    private var inboundRTP: [UInt32: SRTPStreamState] = [:]
    private var outboundRTCPIndex: [UInt32: UInt32] = [:]
    private var inboundRTCP: [UInt32: ReplayWindow] = [:]

    /// Throws `SRTPError.malformed` unless the key is 16 bytes and the salt 14 bytes.
    public init(masterKey: Data, masterSalt: Data) throws {
        rtpKeys = try SRTPSessionKeys(masterKey: masterKey, masterSalt: masterSalt, rtcp: false)
        rtcpKeys = try SRTPSessionKeys(masterKey: masterKey, masterSalt: masterSalt, rtcp: true)
    }

    // MARK: SRTP

    /// Encrypts the payload (everything after the fixed header, CSRCs and header extension, including any padding)
    /// and appends the 10-byte tag.
    public mutating func protectRTP(_ packet: Data) throws -> Data {
        var output = Data(packet)
        let headerLength = try Self.rtpHeaderLength(output, count: output.count)
        let (sequence, ssrc) = Self.sequenceAndSSRC(output)
        var state = outboundRTP[ssrc] ?? SRTPStreamState(firstSequence: sequence)
        let rollover = state.estimate(sequence)?.rolloverCounter ?? state.rolloverCounter
        let index = UInt64(rollover) << 16 | UInt64(sequence)
        try AESCounterMode.apply(key: rtpKeys.encryptionKey, iv: rtpKeys.iv(ssrc: ssrc, index: index), to: &output, from: headerLength)
        output.append(rtpKeys.tag(for: output, rolloverCounter: rollover))
        state.commit(rolloverCounter: rollover, sequence: sequence, index: index)
        outboundRTP[ssrc] = state
        return output
    }

    /// Verifies the tag, checks for replay and decrypts; returns the plain RTP packet.
    public mutating func unprotectRTP(_ packet: Data) throws -> Data {
        let input = Data(packet)
        let tagLength = SRTPSessionKeys.tagLength
        guard input.count >= 12 + tagLength else { throw SRTPError.malformed }
        let authenticatedCount = input.count - tagLength
        let headerLength = try Self.rtpHeaderLength(input, count: authenticatedCount)
        let (sequence, ssrc) = Self.sequenceAndSSRC(input)
        var state = inboundRTP[ssrc] ?? SRTPStreamState(firstSequence: sequence)
        guard let (rollover, index) = state.estimate(sequence) else { throw SRTPError.replay }
        var output = Data(input.prefix(authenticatedCount))
        let expected = rtpKeys.tag(for: output, rolloverCounter: rollover)
        guard SRTPSessionKeys.constantTimeEquals(expected, Data(input.suffix(tagLength))) else { throw SRTPError.authenticationFailed }
        guard state.replay.allows(index) else { throw SRTPError.replay }
        try AESCounterMode.apply(key: rtpKeys.encryptionKey, iv: rtpKeys.iv(ssrc: ssrc, index: index), to: &output, from: headerLength)
        state.commit(rolloverCounter: rollover, sequence: sequence, index: index)
        inboundRTP[ssrc] = state
        return output
    }

    // MARK: SRTCP

    /// Encrypts everything after the first 8 bytes (header + sender SSRC) and appends E‖SRTCP index and the tag.
    public mutating func protectRTCP(_ packet: Data) throws -> Data {
        var output = Data(packet)
        guard output.count >= 8, output[0] >> 6 == 2 else { throw SRTPError.malformed }
        let ssrc = Self.uint32(output, at: 4)
        let index = ((outboundRTCPIndex[ssrc] ?? 0) &+ 1) & 0x7FFF_FFFF
        outboundRTCPIndex[ssrc] = index
        try AESCounterMode.apply(key: rtcpKeys.encryptionKey, iv: rtcpKeys.iv(ssrc: ssrc, index: UInt64(index)), to: &output, from: 8)
        let word = 0x8000_0000 | index
        output.append(contentsOf: [UInt8(word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)])
        output.append(rtcpKeys.tag(for: output))
        return output
    }

    /// Verifies the tag, checks the SRTCP index for replay and decrypts when the E bit is set.
    public mutating func unprotectRTCP(_ packet: Data) throws -> Data {
        let input = Data(packet)
        let tagLength = SRTPSessionKeys.tagLength
        guard input.count >= 8 + 4 + tagLength else { throw SRTPError.malformed }
        let authenticatedCount = input.count - tagLength
        let expected = rtcpKeys.tag(for: Data(input.prefix(authenticatedCount)))
        guard SRTPSessionKeys.constantTimeEquals(expected, Data(input.suffix(tagLength))) else { throw SRTPError.authenticationFailed }
        let word = Self.uint32(input, at: authenticatedCount - 4)
        let index = UInt64(word & 0x7FFF_FFFF)
        let ssrc = Self.uint32(input, at: 4)
        var window = inboundRTCP[ssrc] ?? ReplayWindow()
        guard window.allows(index) else { throw SRTPError.replay }
        var output = Data(input.prefix(authenticatedCount - 4))
        if word & 0x8000_0000 != 0 {
            try AESCounterMode.apply(key: rtcpKeys.encryptionKey, iv: rtcpKeys.iv(ssrc: ssrc, index: index), to: &output, from: 8)
        }
        window.accept(index)
        inboundRTCP[ssrc] = window
        return output
    }

    // MARK: Header helpers (indices start at 0)

    /// Fixed header + CSRCs + header extension; throws unless version 2 and the header fits in `count` bytes.
    static func rtpHeaderLength(_ packet: Data, count: Int) throws -> Int {
        guard count >= 12, packet.count >= count, packet[0] >> 6 == 2 else { throw SRTPError.malformed }
        var length = 12 + 4 * Int(packet[0] & 0x0F)
        if packet[0] & 0x10 != 0 {
            guard count >= length + 4 else { throw SRTPError.malformed }
            length += 4 + 4 * (Int(packet[length + 2]) << 8 | Int(packet[length + 3]))
        }
        guard length <= count else { throw SRTPError.malformed }
        return length
    }

    private static func sequenceAndSSRC(_ packet: Data) -> (UInt16, UInt32) {
        (UInt16(packet[2]) << 8 | UInt16(packet[3]), uint32(packet, at: 8))
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}
