import Foundation
import MediaCore
import Testing
@testable import FMP4

/// Builds `size | type | payload` with a 32-bit size.
private func box(_ type: String, _ payload: Data = Data()) -> Data {
    var data = Data()
    let size = UInt32(8 + payload.count)
    data.append(contentsOf: [UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16), UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
    data.append(contentsOf: Array(type.utf8))
    data.append(payload)
    return data
}

private func concat(_ parts: Data...) -> Data { parts.reduce(into: Data()) { $0.append($1) } }

@Suite struct MP4BoxReaderTests {
    @Test func parsesSiblingsAndNestedContainers() throws {
        let data = concat(box("ftyp", Data(repeating: 1, count: 8)),
                          box("moov", concat(box("mvhd", Data(count: 4)), box("trak", box("tkhd", Data(count: 2))))),
                          box("free"))
        let boxes = try MP4BoxReader.parse(data)
        #expect(boxes.map(\.type) == ["ftyp", "moov", "free"])
        #expect(boxes.map(\.offset) == [0, 16, 16 + 8 + 12 + 18])
        #expect(boxes.map(\.size) == [16, 38, 8])
        #expect(boxes[0].children.isEmpty)
        let moov = boxes[1]
        #expect(moov.children.map(\.type) == ["mvhd", "trak"])
        #expect(moov.children.map(\.offset) == [24, 36])
        #expect(moov.child("trak")?.children.first?.type == "tkhd")
        #expect(moov.child("trak")?.children.first?.offset == 44)
        #expect(MP4BoxReader.box(atPath: "moov/trak/tkhd", in: boxes)?.size == 10)
        #expect(moov.descendant(atPath: "trak/tkhd")?.offset == 44)
        #expect(MP4BoxReader.box(atPath: "moov/mvex", in: boxes) == nil)
    }

    @Test func offsetsAreRelativeToTheStartOfASlice() throws {
        let whole = concat(Data([0xAA, 0xBB, 0xCC]), box("moof", box("mfhd", Data(count: 8))))
        let slice = whole[3...]
        let boxes = try MP4BoxReader.parse(slice)
        #expect(boxes.first?.offset == 0)
        #expect(boxes.first?.children.first?.offset == 8)
    }

    @Test func largeSizeAndSizeZero() throws {
        var large = Data([0, 0, 0, 1])
        large.append(contentsOf: Array("mdat".utf8))
        large.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 20])
        large.append(Data([1, 2, 3, 4]))
        let toEnd = concat(Data([0, 0, 0, 0]), Data("free".utf8), Data(count: 5))
        let boxes = try MP4BoxReader.parse(concat(large, toEnd))
        #expect(boxes.map(\.type) == ["mdat", "free"])
        #expect(boxes[0].size == 20 && boxes[0].headerSize == 16)
        #expect(boxes[1].offset == 20 && boxes[1].size == 13)
    }

    @Test func descendsIntoSampleEntriesAndFullBoxContainers() throws {
        // stsd (full box + entry count) → avc1 (78-byte visual sample entry) → avcC
        let avc1 = box("avc1", concat(Data(count: 78), box("avcC", Data([1, 2, 3]))))
        let stsd = box("stsd", concat(Data([0, 0, 0, 0, 0, 0, 0, 1]), avc1))
        // mp4a (28-byte audio sample entry, version 0) → esds
        let mp4a = box("mp4a", concat(Data(count: 28), box("esds", Data(count: 4))))
        let dref = box("dref", concat(Data([0, 0, 0, 0, 0, 0, 0, 1]), box("url ", Data([0, 0, 0, 1]))))
        let meta = box("meta", concat(Data(count: 4), box("hdlr", Data(count: 25))))
        let boxes = try MP4BoxReader.parse(concat(stsd, box("stsd", concat(Data([0, 0, 0, 0, 0, 0, 0, 1]), mp4a)), dref, meta))
        #expect(boxes[0].descendant(atPath: "avc1/avcC")?.size == 11)
        #expect(boxes[1].descendant(atPath: "mp4a/esds")?.size == 12)
        #expect(boxes[2].child("url ")?.size == 12)
        #expect(boxes[3].child("hdlr")?.size == 33)
    }

    @Test func toleratesQuickTimeZeroTerminatorInsideContainers() throws {
        let udta = box("udta", concat(box("name", Data("x".utf8)), Data(count: 4)))
        let boxes = try MP4BoxReader.parse(udta)
        #expect(boxes[0].children.map(\.type) == ["name"])
    }

    @Test func emptyInputHasNoBoxes() throws {
        #expect(try MP4BoxReader.parse(Data()).isEmpty)
    }

    @Test func rejectsMalformedInput() {
        // Box longer than the data.
        #expect(throws: FMP4Error.self) { try MP4BoxReader.parse(concat(Data([0, 0, 0, 40]), Data("moov".utf8), Data(count: 8))) }
        // Size below the header size.
        #expect(throws: FMP4Error.self) { try MP4BoxReader.parse(concat(Data([0, 0, 0, 7]), Data("free".utf8))) }
        // Truncated header.
        #expect(throws: FMP4Error.self) { try MP4BoxReader.parse(Data([0, 0, 0, 8, 0x66])) }
        // Truncated 64-bit size.
        #expect(throws: FMP4Error.self) { try MP4BoxReader.parse(concat(Data([0, 0, 0, 1]), Data("mdat".utf8), Data([0, 0]))) }
        // 64-bit size smaller than its header.
        #expect(throws: FMP4Error.self) {
            try MP4BoxReader.parse(concat(Data([0, 0, 0, 1]), Data("mdat".utf8), Data([0, 0, 0, 0, 0, 0, 0, 8])))
        }
        // Child overflowing its parent.
        #expect(throws: FMP4Error.self) { try MP4BoxReader.parse(box("moov", concat(Data([0, 0, 0, 20]), Data("trak".utf8)))) }
        // Non-zero garbage too short for a child header.
        #expect(throws: FMP4Error.self) { try MP4BoxReader.parse(box("moov", Data([1, 2, 3]))) }
        // Sample entry shorter than its fixed fields.
        #expect(throws: FMP4Error.self) {
            try MP4BoxReader.parse(box("stsd", concat(Data([0, 0, 0, 0, 0, 0, 0, 1]), box("avc1", Data(count: 10)))))
        }
    }

    @Test func boundsNestingDepth() {
        var nested = box("free")
        for _ in 0..<(MP4BoxReader.maximumDepth + 2) { nested = box("moov", nested) }
        #expect(throws: FMP4Error.self) { try MP4BoxReader.parse(nested) }
    }

    /// Deterministic seeds, so an input that ever traps can be regenerated.
    @Test(arguments: [1, 2, 3, 4] as [UInt64]) func neverTrapsOnRandomInput(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        for _ in 0..<2_000 {
            var data = Data((0..<Int.random(in: 0..<96, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            // Bias towards plausible headers so the recursive paths run.
            if data.count >= 8, Bool.random(using: &generator) {
                let types = ["moov", "trak", "stsd", "avc1", "mp4a", "meta", "mdat", "uuid"]
                data.replaceSubrange(4..<8, with: Array(types[Int.random(in: 0..<types.count, using: &generator)].utf8))
                data[0] = 0; data[1] = 0; data[2] = 0
                data[3] = UInt8.random(in: 0...UInt8(min(data.count, 255)), using: &generator)
            }
            _ = try? MP4BoxReader.parse(data)
        }
    }

    /// Mutations of a real recording (init segment with avc1 + mp4a, then prft/moof/mdat fragments): bit flips, random
    /// bytes, size fields rewritten to nearby or extreme values, truncation and splicing. Deterministic seeds.
    @Test(arguments: [21, 22, 23] as [UInt64]) func neverTrapsOnMutatedRecordings(seed: UInt64) throws {
        let format = try Golden.h264Format
        let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac, writeProducerReferenceTime: true))
        var original = muxer.initializationSegment()
        for fragment in 0..<2 {
            let video = (0..<3).map { Synthetic.videoFrame(format, index: fragment * 3 + $0, isKeyframe: $0 == 0, pts: Int64(fragment * 3 + $0) * 3_000) }
            let audio = (0..<2).map { Synthetic.audioFrame(aac, index: fragment * 2 + $0, pts: Int64(fragment * 2 + $0) * 1_024) }
            original.append(try muxer.fragment(video: video, audio: audio))
        }
        // Offsets of every box header, so size fields are mutated often.
        var headers: [Int] = []
        func collect(_ boxes: [MP4Box]) { for box in boxes { headers.append(box.offset); collect(box.children) } }
        collect(try MP4BoxReader.parse(original))
        #expect(headers.count > 40)

        var generator = SeededGenerator(seed: seed)
        let sizes: [UInt32] = [0, 1, 7, 8, 9, 15, 16, 0x7FFF_FFFF, 0xFFFF_FFFF]
        for _ in 0..<4_000 {
            var bytes = [UInt8](original)
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                switch Int.random(in: 0..<6, using: &generator) {
                case 0:
                    bytes[Int.random(in: 0..<bytes.count, using: &generator)] ^= UInt8(1) << UInt8.random(in: 0...7, using: &generator)
                case 1:
                    bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                case 2, 3:
                    let offset = headers[Int.random(in: 0..<headers.count, using: &generator)]
                    guard offset + 4 <= bytes.count else { continue }
                    let current = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    let size = Bool.random(using: &generator) ? sizes[Int.random(in: 0..<sizes.count, using: &generator)]
                        : current &+ UInt32(bitPattern: Int32.random(in: -16...16, using: &generator))
                    bytes.replaceSubrange(offset..<offset + 4, with: [UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                                                                      UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
                case 4:
                    bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &generator)))
                default:
                    let start = Int.random(in: 0..<bytes.count, using: &generator)
                    let end = min(bytes.count, start + Int.random(in: 1...64, using: &generator))
                    bytes.insert(contentsOf: bytes[start..<end], at: Int.random(in: 0...bytes.count, using: &generator))
                }
                if bytes.isEmpty { break }
            }
            _ = try? MP4BoxReader.parse(Data(bytes))
        }
    }
}
