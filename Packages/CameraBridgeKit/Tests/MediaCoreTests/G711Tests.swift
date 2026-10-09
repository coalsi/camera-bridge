import Foundation
import Testing
@testable import MediaCore

/// ITU-T G.711 µ-law / A-law (the classic 14-bit / 13-bit segment companding; values in 16-bit PCM units).
@Suite struct G711Tests {
    // MARK: µ-law

    @Test func muLawReferenceValues() {
        // Code 0xFF is +0, 0x7F is −0; 0x80 / 0x00 are the extremes (±32124).
        #expect(G711.decodeMuLaw(Data([0xFF, 0x7F, 0x80, 0x00, 0xFE, 0xEF, 0xF0])) == [0, 0, 32124, -32124, 8, 132, 120])
        #expect(G711.encodeMuLaw([0, 8, -8, 132, 32767, -32768, 32124, -32124]) == Data([0xFF, 0xFE, 0x7E, 0xEF, 0x80, 0x00, 0x80, 0x00]))
    }

    @Test func muLawCodeRoundTripIsIdentityExceptNegativeZero() {
        for code in 0...255 {
            let decoded = G711.decodeMuLaw(Data([UInt8(code)]))
            let reencoded = G711.encodeMuLaw(decoded)
            #expect(reencoded == Data([code == 0x7F ? 0xFF : UInt8(code)]), "code \(code)")
        }
    }

    @Test func muLawSampleRoundTripStaysWithinQuantisationError() {
        var previous = Int.min
        for x in stride(from: -32768, through: 32767, by: 3) {
            let y = Int(G711.decodeMuLaw(G711.encodeMuLaw([Int16(x)]))[0])
            let clamped = min(max(x, -32124), 32124)
            // Segment s has 16 steps of 2^(s+3) (16-bit units): the error is at most half a step plus the 2-bit
            // truncation, which stays below |x|/16 + 4.
            #expect(abs(clamped - y) <= abs(clamped) / 16 + 4, "x \(x) → \(y)")
            #expect(y >= previous, "not monotonic at \(x)")
            previous = y
        }
    }

    // MARK: A-law

    @Test func aLawReferenceValues() {
        #expect(G711.decodeALaw(Data([0xD5, 0x55, 0xAA, 0x2A, 0xD4])) == [8, -8, 32256, -32256, 24])
        #expect(G711.encodeALaw([0, -1, 8, -8, 32767, -32768, 24]) == Data([0xD5, 0x55, 0xD5, 0x55, 0xAA, 0x2A, 0xD4]))
    }

    @Test func aLawCodeRoundTripIsIdentity() {
        for code in 0...255 {
            let decoded = G711.decodeALaw(Data([UInt8(code)]))
            #expect(G711.encodeALaw(decoded) == Data([UInt8(code)]), "code \(code)")
        }
    }

    @Test func aLawSampleRoundTripStaysWithinQuantisationError() {
        var previous = Int.min
        for x in stride(from: -32768, through: 32767, by: 3) {
            let y = Int(G711.decodeALaw(G711.encodeALaw([Int16(x)]))[0])
            let clamped = min(max(x, -32256), 32256)
            #expect(abs(clamped - y) <= abs(clamped) / 32 + 8, "x \(x) → \(y)")
            #expect(y >= previous, "not monotonic at \(x)")
            previous = y
        }
    }

    // MARK: Buffers

    @Test func lengthsMatchAndEmptyInputIsEmpty() {
        let samples: [Int16] = (0..<160).map { Int16(truncatingIfNeeded: $0 * 400 - 32000) }
        #expect(G711.encodeMuLaw(samples).count == 160 && G711.encodeALaw(samples).count == 160)
        #expect(G711.decodeMuLaw(Data(repeating: 0xFF, count: 320)).count == 320)
        #expect(G711.decodeMuLaw(Data()).isEmpty && G711.decodeALaw(Data()).isEmpty)
        #expect(G711.encodeMuLaw([]).isEmpty && G711.encodeALaw([]).isEmpty)
    }

    @Test func decodesSlicedData() {
        let data = Data([0x00, 0xFF, 0x80, 0xD5, 0x55])
        #expect(G711.decodeMuLaw(data[1..<3]) == [0, 32124])
        #expect(G711.decodeALaw(data[3...]) == [8, -8])
    }

    @Test func sineToneSurvivesARoundTrip() {
        let tone: [Int16] = (0..<800).map { Int16(12_000 * sin(2 * Double.pi * 440 * Double($0) / 8_000)) }
        for (encode, decode) in [(G711.encodeMuLaw, G711.decodeMuLaw), (G711.encodeALaw, G711.decodeALaw)] {
            let back = decode(encode(tone))
            let noise = zip(tone, back).map { Double(Int($0) - Int($1)) }.reduce(0) { $0 + $1 * $1 }
            let signal = tone.map { Double($0) }.reduce(0) { $0 + $1 * $1 }
            #expect(10 * log10(signal / noise) > 30)   // G.711 gives ~38 dB SNR on a loud tone
        }
    }
}
