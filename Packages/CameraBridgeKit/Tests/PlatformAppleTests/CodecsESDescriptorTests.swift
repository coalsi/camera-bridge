#if os(macOS)
import Foundation
import MediaCore
import Testing
@testable import PlatformApple

@Suite struct CodecsESDescriptorTests {
    @Test func audioSpecificConfigRoundTripsThroughTheESDescriptor() {
        for config in [Data([0x12, 0x88]), Data([0x17, 0x80, 0x27, 0x10, 0x08]), Data([0xF8, 0xF0, 0x30, 0x00]), Data(repeating: 0x11, count: 200)] {
            #expect(MPEG4ESDescriptor.audioSpecificConfig(in: MPEG4ESDescriptor.make(audioSpecificConfig: config)) == config)
        }
    }

    @Test func parsesOptionalESDescriptorFieldsAndSkipsUnknownDescriptors() {
        // ES_Descriptor with dependsOn + URL + OCR flags, then an unknown descriptor (0x0A) before the config descriptor.
        let decoderConfig: [UInt8] = [0x04, 17, 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x05, 2, 0x12, 0x10]
        let body: [UInt8] = [0x00, 0x01, 0xE0, 0x00, 0x02, 3, 0x61, 0x62, 0x63, 0x00, 0x03, 0x0A, 1, 0xFF] + decoderConfig + [0x06, 1, 2]
        let descriptor = Data([0x03, UInt8(body.count)] + body)
        #expect(MPEG4ESDescriptor.audioSpecificConfig(in: descriptor) == Data([0x12, 0x10]))
    }

    @Test func bareConfigsPassThroughAndMalformedDescriptorsAreNil() {
        #expect(MPEG4ESDescriptor.audioSpecificConfig(in: Data([0x12, 0x88])) == Data([0x12, 0x88]))
        #expect(MPEG4ESDescriptor.audioSpecificConfig(in: Data()) == nil)
        #expect(MPEG4ESDescriptor.audioSpecificConfig(in: Data([0x03])) == nil)
        #expect(MPEG4ESDescriptor.audioSpecificConfig(in: Data([0x03, 0x7F, 0x00])) == nil)          // size beyond the data
        #expect(MPEG4ESDescriptor.audioSpecificConfig(in: Data([0x03, 0x05, 0, 0, 0, 0x04, 0x01])) == nil)   // truncated config descriptor
        #expect(MPEG4ESDescriptor.audioSpecificConfig(in: Data([0x03, 0xFF, 0xFF, 0xFF, 0xFF])) == nil)   // unterminated size
    }

    @Test func fuzzedDescriptorsNeverTrap() {
        var generator = SystemRandomNumberGenerator()
        let valid = [UInt8](MPEG4ESDescriptor.make(audioSpecificConfig: Data([0x12, 0x88])))
        for _ in 0..<5_000 {
            var bytes = valid
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &generator)))
            _ = MPEG4ESDescriptor.audioSpecificConfig(in: Data(bytes))
        }
    }

    /// TOC = config << 3 | code; at 16 kHz. SILK config 1 = 20 ms, config 0 = 10 ms; hybrid 15 = 20 ms; CELT 31 = 20 ms.
    /// Code 0 = one frame, 1 = two equal frames, 3 = count in the next byte (3 here).
    @Test(arguments: [(UInt8(0x08), 320), (0x78, 320), (0xF8, 320), (0x09, 640), (0x0B, 960), (0x03, 480)])
    func opusPacketDurations(toc: UInt8, samples: Int) {
        var packet = Data([toc])
        if toc & 0x03 == 3 { packet.append(0x03) }
        #expect(OpusPacket.sampleCount(packet, sampleRate: 16_000) == samples)
    }

    @Test func opusPacketEdgeCases() {
        #expect(OpusPacket.sampleCount(Data(), sampleRate: 16_000) == nil)
        #expect(OpusPacket.sampleCount(Data([0x03]), sampleRate: 16_000) == nil)            // code 3 without a count byte
        #expect(OpusPacket.sampleCount(Data([0x80]), sampleRate: 48_000) == 120)            // CELT 2.5 ms
        #expect(OpusPacket.sampleCount(Data([0x9D, 0x00]), sampleRate: 48_000) == 1_920)    // CELT 20 ms, two frames
    }
}
#endif
