import Foundation

public struct AudioEncoderSettings: Sendable, Equatable {
    public var codec: AudioCodec
    public var sampleRate: Int
    public var channels: Int
    public var bitrate: Int?

    public init(codec: AudioCodec, sampleRate: Int, channels: Int = 1, bitrate: Int? = nil) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrate = bitrate
    }
}

/// AAC/AAC-ELD/Opus/G.711/PCM ↔ AAC-LC/AAC-ELD/Opus/G.711.
public protocol AudioTranscoding: AnyObject, Sendable {
    var outputFormat: AudioFormat { get }
    func transcode(_ frame: EncodedAudioFrame) throws -> [EncodedAudioFrame]
    func flush() throws -> [EncodedAudioFrame]
}

/// ITU-T G.711 µ-law / A-law companding, pure Swift. Samples are 16-bit linear PCM; µ-law quantises the top 14 bits
/// (bias 33, clip ±32124), A-law the top 13 bits (clip ±32256). µ-law 0xFF and A-law 0xD5 encode silence.
public enum G711 {
    public static func decodeMuLaw(_ data: Data) -> [Int16] { data.map { muLawTable[Int($0)] } }

    public static func encodeMuLaw(_ samples: [Int16]) -> Data { Data(samples.map(muLaw(from:))) }

    public static func decodeALaw(_ data: Data) -> [Int16] { data.map { aLawTable[Int($0)] } }

    public static func encodeALaw(_ samples: [Int16]) -> Data { Data(samples.map(aLaw(from:))) }

    // MARK: µ-law

    private static let muLawTable: [Int16] = (0...255).map { muLawDecode(UInt8($0)) }

    /// Reconstruction value of the (inverted) code: ((mantissa << 3) + 132) << segment − 132, sign in bit 7.
    private static func muLawDecode(_ code: UInt8) -> Int16 {
        let inverted = ~code
        let segment = Int(inverted >> 4) & 0x07
        let mantissa = Int(inverted) & 0x0F
        let magnitude = (((mantissa << 3) + 132) << segment) - 132
        return Int16(inverted & 0x80 != 0 ? -magnitude : magnitude)
    }

    private static func muLaw(from sample: Int16) -> UInt8 {
        // 14-bit magnitude (one's complement for negative samples, as in ITU-T G.191), clipped to 8159, plus the
        // bias 33: segment s holds 2^(s+5)…2^(s+6)−1.
        let mask: UInt8 = sample < 0 ? 0x7F : 0xFF
        var value = Int(sample < 0 ? ~sample : sample) >> 2
        value = min(value, 8_159) + 33
        var segment = 0
        while segment < 8 && value >= (0x40 << segment) { segment += 1 }
        guard segment < 8 else { return 0x7F ^ mask }
        let code = UInt8(segment << 4) | UInt8((value >> (segment + 1)) & 0x0F)
        return code ^ mask
    }

    // MARK: A-law

    private static let aLawTable: [Int16] = (0...255).map { aLawDecode(UInt8($0)) }

    /// Reconstruction value of the code (even bits inverted): the midpoint of its quantisation interval.
    private static func aLawDecode(_ code: UInt8) -> Int16 {
        let value = code ^ 0x55
        var magnitude = (Int(value) & 0x0F) << 4
        let segment = (Int(value) & 0x70) >> 4
        switch segment {
        case 0: magnitude += 8
        case 1: magnitude += 0x108
        default: magnitude = (magnitude + 0x108) << (segment - 1)
        }
        return Int16(value & 0x80 != 0 ? magnitude : -magnitude)
    }

    private static func aLaw(from sample: Int16) -> UInt8 {
        // 13-bit magnitude; negative values use the one's-complement magnitude (−1 → 0).
        var value = Int(sample) >> 3
        let mask: UInt8
        if value >= 0 {
            mask = 0xD5
        } else {
            mask = 0x55
            value = -value - 1
        }
        var segment = 0
        while segment < 8 && value >= (0x20 << segment) { segment += 1 }
        guard segment < 8 else { return 0x7F ^ mask }
        let mantissa = (segment < 2 ? value >> 1 : value >> segment) & 0x0F
        return (UInt8(segment << 4) | UInt8(mantissa)) ^ mask
    }
}
