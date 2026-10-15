import BridgeSupport
import FMP4
import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

@Suite struct ArchiveMediaMimeTests {
    private func initSegment(_ format: VideoFormat) throws -> Data {
        try ArchiveMediaFixtures.mux(ArchiveMediaFixtures.syntheticFrames(format, count: 3, keyEvery: 3)).initSegment
    }

    @Test func theCaptureParameterSetsGiveTheCaptureMime() throws {
        #expect(try ArchiveMedia.mime(forInit: initSegment(ArchiveMediaFixtures.tapoFormat)) == "video/mp4; codecs=\"avc1.4d0032\"")
    }

    @Test func aStreamWithAnotherProfileAndLevelHasItsOwnMime() throws {
        #expect(try ArchiveMedia.mime(forInit: initSegment(ArchiveMediaFixtures.smallH264Format)) == "video/mp4; codecs=\"avc1.64001e\"")
    }

    /// The avcC bytes 1...3 are profile, compatibility and level, six lowercase hexadecimal digits whatever they are.
    @Test func theAvcMimeIsThreeBytesOfLowercaseHexadecimal() throws {
        let initData = try initSegment(ArchiveMediaFixtures.tapoFormat)
        let avcC = try #require(try ArchiveMediaBytes.boxes(in: initData, at: "moov/trak/mdia/minf/stbl/stsd/avc1/avcC").first)
        for (bytes, expected) in [([0x64, 0x00, 0x1F], "avc1.64001f"), ([0x42, 0xC0, 0x0C], "avc1.42c00c"), ([0xF4, 0x0A, 0xFF], "avc1.f40aff"), ([0x00, 0x00, 0x00], "avc1.000000")] as [([UInt8], String)] {
            let patched = ArchiveMediaBytes.patching(initData, at: avcC.payloadOffset + 1, bytes)
            #expect(try ArchiveMedia.mime(forInit: patched) == "video/mp4; codecs=\"\(expected)\"")
        }
    }

    @Test func theHevcParameterSetsGiveTheMainProfileMime() throws {
        #expect(try ArchiveMedia.mime(forInit: initSegment(ArchiveMediaFixtures.hevcFormat)) == "video/mp4; codecs=\"hvc1.1.6.L63.B0\"")
    }

    /// ISO/IEC 14496-15 Annex E.3, field by field, by changing the hvcC bytes 1...12 of a real init segment. `hvc1.1.6.L93.B0` and `hvc1.2.4.L93.B0` are the strings
    /// in common use for Main and Main 10 at level 3.1; the others exercise each rule on its own.
    @Test(arguments: [
        (UInt8(0x01), UInt32(0x6000_0000), [UInt8]([0xB0, 0, 0, 0, 0, 0]), UInt8(93), "hvc1.1.6.L93.B0"),
        (UInt8(0x02), UInt32(0x2000_0000), [UInt8]([0xB0, 0, 0, 0, 0, 0]), UInt8(93), "hvc1.2.4.L93.B0"),
        (UInt8(0x21), UInt32(0x6000_0000), [UInt8]([0x90, 0, 0, 0, 0, 0]), UInt8(153), "hvc1.1.6.H153.90"),
        (UInt8(0x44), UInt32(0x0800_0000), [UInt8]([0, 0, 0, 0, 0, 0]), UInt8(120), "hvc1.A4.10.L120"),
        (UInt8(0xE3), UInt32(0x1000_0000), [UInt8]([0x90, 0, 0, 0, 0, 0x40]), UInt8(60), "hvc1.C3.8.H60.90.00.00.00.00.40"),
        (UInt8(0x01), UInt32(0xFFFF_FFFF), [UInt8]([0x04, 0x0A, 0, 0, 0, 0]), UInt8(0), "hvc1.1.FFFFFFFF.L0.04.0A"),
        (UInt8(0x01), UInt32(0x0000_0001), [UInt8]([0, 0, 0, 0, 0, 0x01]), UInt8(255), "hvc1.1.80000000.L255.00.00.00.00.00.01"),
    ])
    func theHevcMimeFollowsAnnexE(profileByte: UInt8, compatibility: UInt32, constraints: [UInt8], level: UInt8, expected: String) throws {
        let initData = try initSegment(ArchiveMediaFixtures.hevcFormat)
        let hvcC = try #require(try ArchiveMediaBytes.boxes(in: initData, at: "moov/trak/mdia/minf/stbl/stsd/hvc1/hvcC").first)
        let fields = [profileByte] + ArchiveMediaBytes.u32(compatibility) + constraints + [level]
        let patched = ArchiveMediaBytes.patching(initData, at: hvcC.payloadOffset + 1, fields)
        #expect(try ArchiveMedia.mime(forInit: patched) == "video/mp4; codecs=\"\(expected)\"")
    }

    @Test func anAvcCOrHvcCOfAnotherVersionIsMalformed() throws {
        for (format, record, message) in [(ArchiveMediaFixtures.tapoFormat, "avcC", "the avcC is not version 1"), (ArchiveMediaFixtures.hevcFormat, "hvcC", "the hvcC is not a version 1 record")] {
            let initData = try initSegment(format)
            let box = try #require(try ArchiveMediaBytes.boxes(in: initData).first { $0.path.hasSuffix("/" + record) }).box
            let patched = ArchiveMediaBytes.patching(initData, at: box.payloadOffset, [2])
            #expect(throws: ArchiveMedia.Failure.malformed(message)) { _ = try ArchiveMedia.mime(forInit: patched) }
        }
    }

    @Test func aSampleEntryOtherThanAvc1AndHvc1IsUnsupported() throws {
        let initData = try initSegment(ArchiveMediaFixtures.tapoFormat)
        let entry = try #require(try ArchiveMediaBytes.boxes(in: initData, at: "moov/trak/mdia/minf/stbl/stsd/avc1").first)
        for type in ["avc3", "hev1"] {
            let patched = ArchiveMediaBytes.patching(initData, at: entry.offset + 4, Array(type.utf8))
            #expect(throws: ArchiveMedia.Failure.unsupported("the video sample entry '\(type)' (the recorder writes avc1 or hvc1)")) { _ = try ArchiveMedia.mime(forInit: patched) }
        }
    }
}
