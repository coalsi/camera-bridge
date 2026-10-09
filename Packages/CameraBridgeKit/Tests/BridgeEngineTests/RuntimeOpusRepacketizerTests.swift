import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// Live audio at the requested packet time (HomeKit asks for 20 ms on the LAN, 60 ms remotely; the Opus encoder
/// emits 20 ms packets): consecutive single-frame packets are joined into one RFC 6716 code-3 packet.
@Suite struct RuntimeOpusRepacketizerTests {
    static let format = AudioFormat(codec: .opus, sampleRate: 24_000, channels: 1)

    /// A code-0 packet (one 20 ms CELT frame, config 31: FB 20 ms) with `size` payload bytes.
    static func packet(_ index: Int, size: Int, toc: UInt8 = 0xF8) -> EncodedAudioFrame {
        var data = Data([toc])
        data.append(contentsOf: (0..<size).map { UInt8(truncatingIfNeeded: $0 &+ index) })
        return EncodedAudioFrame(format: format, data: data, pts: MediaTime(value: Int64(index) * 480, timescale: 24_000), sampleCount: 480,
                                 wallClock: Date(timeIntervalSince1970: Double(index) * 0.02))
    }

    /// Frames of a code-3 packet (independent parser, RFC 6716 §3.2.5).
    static func frames(ofCode3 data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        try #require(bytes.count >= 2 && bytes[0] & 0x03 == 3)
        let count = Int(bytes[1] & 0x3F)
        let vbr = bytes[1] & 0x80 != 0
        #expect(bytes[1] & 0x40 == 0, "no padding")
        var offset = 2
        var lengths: [Int] = []
        if vbr {
            for _ in 0..<(count - 1) {
                let first = Int(bytes[offset])
                if first < 252 {
                    lengths.append(first)
                    offset += 1
                } else {
                    lengths.append(first + 4 * Int(bytes[offset + 1]))
                    offset += 2
                }
            }
            lengths.append(bytes.count - offset - lengths.reduce(0, +))
        } else {
            let each = (bytes.count - offset) / count
            lengths = Array(repeating: each, count: count)
        }
        var result: [Data] = []
        for length in lengths {
            result.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }
        #expect(offset == bytes.count)
        return result
    }

    @Test func twentyMillisecondsPassesPacketsThrough() {
        var repacketizer = OpusRepacketizer(packetTime: .milliseconds(20))
        let input = Self.packet(0, size: 40)
        let output = repacketizer.push(input)
        #expect(output.count == 1 && output[0].data == input.data && output[0].sampleCount == 480)
        #expect(repacketizer.flush() == nil)
    }

    @Test func sixtyMillisecondsJoinsThreeFrames() throws {
        var repacketizer = OpusRepacketizer(packetTime: .milliseconds(60))
        let inputs = [Self.packet(0, size: 40), Self.packet(1, size: 300), Self.packet(2, size: 60)]
        #expect(repacketizer.push(inputs[0]).isEmpty)
        #expect(repacketizer.push(inputs[1]).isEmpty)
        let output = repacketizer.push(inputs[2])
        let joined = try #require(output.first)
        #expect(output.count == 1)
        #expect(joined.data[0] == 0xFB, "same config and channels, code 3")
        #expect(try Self.frames(ofCode3: joined.data) == inputs.map { $0.data.dropFirst() }.map { Data($0) })
        #expect(joined.pts == inputs[0].pts && joined.sampleCount == 1_440 && joined.wallClock == inputs[0].wallClock)
        // Next group starts fresh.
        #expect(repacketizer.push(Self.packet(3, size: 10)).isEmpty)
        let flushed = repacketizer.flush()
        let tail = try #require(flushed)
        #expect(tail.data == Self.packet(3, size: 10).data)
    }

    @Test func fortyMillisecondsJoinsTwoAndThirtyRoundsDown() throws {
        var forty = OpusRepacketizer(packetTime: .milliseconds(40))
        #expect(forty.push(Self.packet(0, size: 20)).isEmpty)
        let pair = forty.push(Self.packet(1, size: 20))
        let joined = try #require(pair.first)
        #expect(try Self.frames(ofCode3: joined.data).count == 2 && joined.sampleCount == 960)
        var thirty = OpusRepacketizer(packetTime: .milliseconds(30))
        #expect(thirty.push(Self.packet(0, size: 20)).count == 1)
    }

    @Test func packetsThatCannotBeJoinedAreFlushedAsTheyAre() throws {
        var repacketizer = OpusRepacketizer(packetTime: .milliseconds(60))
        #expect(repacketizer.push(Self.packet(0, size: 20)).isEmpty)
        // A different configuration (TOC) cannot share a code-3 packet: the pending one goes out alone first.
        let changed = Self.packet(1, size: 20, toc: 0x78)
        let output = repacketizer.push(changed)
        #expect(output.map(\.data) == [Self.packet(0, size: 20).data])
        // A packet that already holds several frames (code 1) is sent as is.
        var code1 = Self.packet(2, size: 20, toc: 0x79)
        code1.sampleCount = 960
        let passed = repacketizer.push(code1)
        #expect(passed.map(\.data) == [changed.data, code1.data])
        // Empty packets are dropped.
        #expect(repacketizer.push(EncodedAudioFrame(format: Self.format, data: Data(), pts: .init(value: 0, timescale: 24_000), sampleCount: 0,
                                                    wallClock: Date())).isEmpty)
    }

    @Test func longFramesUseTwoByteLengths() throws {
        var repacketizer = OpusRepacketizer(packetTime: .milliseconds(60))
        let inputs = [Self.packet(0, size: 1_000), Self.packet(1, size: 252), Self.packet(2, size: 5)]
        _ = repacketizer.push(inputs[0])
        _ = repacketizer.push(inputs[1])
        let output = repacketizer.push(inputs[2])
        let joined = try #require(output.first)
        #expect(try Self.frames(ofCode3: joined.data) == inputs.map { Data($0.data.dropFirst()) })
    }
}
