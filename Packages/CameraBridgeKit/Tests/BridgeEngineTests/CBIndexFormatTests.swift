import Foundation
import Testing
@testable import BridgeEngine

/// The `.cbidx` v1 byte layout (Mac spec 4.4), pinned by bytes written independently of the encoder (Python `struct`, field by field).
@Suite struct CBIndexFormatTests {
    static let camera = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    static let startWallMs: Int64 = 1_760_099_000_000

    /// 64-byte header: magic, version 1, flags 1 (audio), camera, startWallMs, endWallMs = start + 5000, mp4Size 1000, initLength 100, count 2,
    /// rollupCount 1, six reserved zero bytes.
    static let headerHex = "43424e58" + "0001" + "0001" + "00112233445566778899aabbccddeeff" + "00000199ce135ec0" + "00000199ce137248"
        + "00000000000003e8" + "00000064" + "00000002" + "0001" + "000000000000"
    /// One rollup: nonKeyBytes 3000, peakRate 1200, coveredMs 5000, reserved 0.
    static let rollupHex = "00000bb8" + "000004b0" + "1388" + "0000"
    /// Fragment 0: offset 100, length 400, wallDelta 0, mediaStart 0, duration 225000, header 150, key 200, nonKey 100, samples 50, back 0.
    static let record0Hex = "0000000000000064" + "00000190" + "00000000" + "00000000" + "00036ee8" + "00000096" + "000000c8" + "00000064" + "0032" + "0000"
    /// Fragment 1: offset 500, length 500, wallDelta 2500, mediaStart 225000, duration 225000, header 150, key 0, nonKey 300, samples 50, back 1.
    static let record1Hex = "00000000000001f4" + "000001f4" + "000009c4" + "00036ee8" + "00036ee8" + "00000096" + "00000000" + "0000012c" + "0032" + "0001"

    static var golden: Data { Data(hex: headerHex + rollupHex + record0Hex + record1Hex)! }

    static var file: CBIndexFile {
        CBIndexFile(flags: CBIndexFormat.flagHasAudio, camera: camera, startWallMs: startWallMs, endWallMs: startWallMs + 5_000, mp4Size: 1_000,
                    initLength: 100, rollups: [CBIndexRollup(nonKeyBytes: 3_000, peakRate: 1_200, coveredMs: 5_000)],
                    fragments: [CBIndexFragmentRecord(offset: 100, length: 400, wallDeltaMs: 0, mediaStart: 0, durationTicks: 225_000, headerLength: 150,
                                                      keyLength: 200, nonKeyBytes: 100, samples: 50, backToKey: 0),
                                CBIndexFragmentRecord(offset: 500, length: 500, wallDeltaMs: 2_500, mediaStart: 225_000, durationTicks: 225_000,
                                                      headerLength: 150, keyLength: 0, nonKeyBytes: 300, samples: 50, backToKey: 1)])
    }

    @Test func encodesTheGoldenBytes() {
        #expect(Self.file.encoded() == Self.golden)
        #expect(Self.golden.count == 156 && Self.golden.count == CBIndexFile.byteCount(rollups: 1, fragments: 2))
    }

    @Test func decodesTheGoldenBytes() throws {
        let decoded = try CBIndexFile.decode(Self.golden, mp4Size: 1_000)
        #expect(decoded == Self.file)
        #expect(decoded.hasAudio && decoded.fragments[0].hasKeyframe && !decoded.fragments[1].hasKeyframe)
    }

    @Test func decodesFromASliceOfALargerBuffer() throws {
        var padded = Data([0xAA, 0xBB])
        padded.append(Self.golden)
        #expect(try CBIndexFile.decode(padded.dropFirst(2), mp4Size: 1_000) == Self.file)
    }

    @Test func anIndexWithoutFragmentsOrRollupsIsJustTheHeader() throws {
        let empty = CBIndexFile(camera: Self.camera, startWallMs: 1, endWallMs: 1, mp4Size: 80, initLength: 80)
        #expect(empty.encoded().count == 64)
        #expect(try CBIndexFile.decode(empty.encoded(), mp4Size: 80) == empty)
    }

    @Test func refusesWhatItCannotTrust() throws {
        func decode(_ data: Data, size: UInt64 = 1_000) -> CBIndexError? {
            do { _ = try CBIndexFile.decode(data, mp4Size: size) } catch let error as CBIndexError { return error } catch { return nil }
            return nil
        }
        var badMagic = Self.golden
        badMagic[0] = UInt8(ascii: "X")
        #expect(decode(badMagic) == .badMagic)
        var newer = Self.golden
        newer[5] = 2
        #expect(decode(newer) == .unsupportedVersion(2))
        #expect(decode(Self.golden.prefix(63)) == .truncated)
        #expect(decode(Self.golden.dropLast()) == .sizeMismatch, "the size is exactly 64 + rollups x 12 + records x 40")
        #expect(decode(Self.golden + Data([0])) == .sizeMismatch)
        #expect(decode(Self.golden, size: 1_001) == .mp4SizeMismatch, "the mp4 grew or was replaced after the index was written")
        var manyRecords = Self.golden
        manyRecords.replaceSubrange(52..<56, with: [0x7F, 0xFF, 0xFF, 0xFF])
        #expect(decode(manyRecords) == .sizeMismatch, "a count that cannot be true is refused before anything is allocated")
    }

    @Test func refusesRecordsThatPointOutsideTheFile() {
        func decode(changing change: (inout CBIndexFile) -> Void, size: UInt64 = 1_000) -> CBIndexError? {
            var file = Self.file
            change(&file)
            do { _ = try CBIndexFile.decode(file.encoded(), mp4Size: size) } catch let error as CBIndexError { return error } catch { return nil }
            return nil
        }
        #expect(decode(changing: { $0.fragments[0].offset = 50 }) == .inconsistentRecord(0), "inside the init segment")
        #expect(decode(changing: { $0.fragments[1].offset = 450 }) == .inconsistentRecord(1), "overlaps the first fragment")
        #expect(decode(changing: { $0.fragments[1].length = 501 }) == .inconsistentRecord(1), "runs past the end of the mp4")
        #expect(decode(changing: { $0.fragments[0].offset = UInt64.max - 10 }) == .inconsistentRecord(0), "offset + length overflows")
        #expect(decode(changing: { $0.fragments[0].length = 0 }) == .inconsistentRecord(0))
        #expect(decode(changing: { $0.fragments[1].backToKey = 2 }) == .inconsistentRecord(1), "more fragments back than there are")
        #expect(decode(changing: { $0.fragments[0].backToKey = 1 }) == .inconsistentRecord(0))
        #expect(decode(changing: { $0.fragments[1].keyLength = 10 }) == .inconsistentRecord(1), "a keyframe fragment has nothing to go back to")
        #expect(decode(changing: { $0.fragments[0].headerLength = 401 }) == .inconsistentRecord(0))
    }

    @Test func everyPrefixOfAnIndexIsRefusedWithoutTrapping() {
        for count in 0..<Self.golden.count {
            #expect((try? CBIndexFile.decode(Self.golden.prefix(count), mp4Size: 1_000)) == nil, "prefix of \(count) bytes")
        }
    }
}

extension Data {
    /// Hex digits to bytes (nil for an odd length or a non-hex character).
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
