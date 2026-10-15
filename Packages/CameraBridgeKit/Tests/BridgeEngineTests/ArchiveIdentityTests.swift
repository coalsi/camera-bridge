import Foundation
import Testing
@testable import BridgeEngine

@Suite struct ArchiveIdentityTests {
    @Test func fnv1a64MatchesTheReferenceVectors() {
        #expect(ArchiveIdentity.fnv1a64([UInt8]()) == 0xcbf2_9ce4_8422_2325)
        #expect(ArchiveIdentity.fnv1a64(Array("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
        #expect(ArchiveIdentity.fnv1a64(Array("foobar".utf8)) == 0x8594_4171_f739_67e8)
    }

    @Test func fileKeyIsTheHighTwelveHexDigitsOfTheHash() {
        // 0xcbf29ce484222325 (the hash of the empty segment) -> its first 12 digits.
        #expect(ArchiveIdentity.fileKey(forSegment: "") == "cbf29ce48422")
        #expect(ArchiveIdentity.fileKey(forSegment: "a") == "af63dc4c8601")
        let segment = "6F9619FF-8B86-D011-B42D-00C04FC964FF/2026-10-10/13-24-05"
        #expect(ArchiveIdentity.fileKey(forSegment: segment) == ArchiveIdentity.fileKey(forSegment: segment), "stable")
        #expect(ArchiveIdentity.fileKey(forSegment: segment) != ArchiveIdentity.fileKey(forSegment: segment + "-2"))
    }

    @Test func fileKeyKeepsLeadingZeros() throws {
        // A segment whose 64-bit hash prints with fewer than 16 hex digits.
        let short = try #require((0..<10_000).map { "short-\($0)" }.first { String(ArchiveIdentity.fnv1a64($0.utf8), radix: 16).count < 16 })
        let key = ArchiveIdentity.fileKey(forSegment: short)
        let digits = String(ArchiveIdentity.fnv1a64(short.utf8), radix: 16)
        #expect(key.count == 12 && key == String((String(repeating: "0", count: 16 - digits.count) + digits).prefix(12)))
        #expect(key.hasPrefix("0"))
    }

    @Test func fragmentIDsParseStrictly() {
        let id = ArchiveIdentity.fragmentID(fileKey: "a1b2c3d4e5f6", index: 17)
        #expect(id == "a1b2c3d4e5f6.17")
        let parsed = ArchiveIdentity.parseFragmentID(id)
        #expect(parsed?.fileKey == "a1b2c3d4e5f6" && parsed?.index == 17)
        #expect(ArchiveIdentity.parseFragmentID("a1b2c3d4e5f6.0")?.index == 0)
        #expect(ArchiveIdentity.parseFragmentID("a1b2c3d4e5f6.9999999")?.index == 9_999_999)
        for bad in ["", "a1b2c3d4e5f6", "a1b2c3d4e5f6.", "a1b2c3d4e5f6.-1", "a1b2c3d4e5f6.007", "a1b2c3d4e5f6.10000000", "A1B2C3D4E5F6.1",
                    "a1b2c3d4e5f.1", "a1b2c3d4e5f67.1", "a1b2c3d4e5fg.1", "a1b2c3d4e5f6.1 ", " a1b2c3d4e5f6.1", "a1b2c3d4e5f6.1\n", "../a1b2c3d4e5f6.1"] {
            #expect(ArchiveIdentity.parseFragmentID(bad) == nil, "\(bad.debugDescription)")
        }
    }
}

@Suite struct ArchiveLayoutTests {
    @Test func dateDirectoryNames() {
        #expect(ArchiveLayout.isDateDirectoryName("2026-10-10"))
        #expect(ArchiveLayout.isDateDirectoryName("2026-02-31"), "the pattern, not the calendar: a day number up to 31")
        for bad in ["", "2026-13-01", "2026-00-10", "2026-10-00", "2026-10-32", "26-10-10", "2026-1-10", "2026-10-10 ", "2026/10/10", "..", "2026-10-10.mp4"] {
            #expect(!ArchiveLayout.isDateDirectoryName(bad), "\(bad.debugDescription)")
        }
    }

    @Test func ownFileNames() {
        for good in ["13-24-05", "00-00-00", "23-59-60", "13-24-05-2", "13-24-05-999"] {
            #expect(ArchiveLayout.isOwnFileBaseName(good), "\(good)")
        }
        for bad in ["", "13-24-5", "24-00-00", "12-60-00", "12-00-61", "13-24-05-0", "13-24-05-1000", "13-24-05-", "13-24-05.mp4", "13-24-05 copy", "x13-24-05", ".13-24-05"] {
            #expect(!ArchiveLayout.isOwnFileBaseName(bad), "\(bad.debugDescription)")
        }
    }

    @Test func segmentsRoundTripAndRefuseAnythingElse() {
        let camera = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let segment = ArchiveLayout.segment(cameraDirectory: camera, dateDirectory: "2026-10-10", baseName: "13-24-05")
        #expect(segment == "\(camera)/2026-10-10/13-24-05")
        let parts = ArchiveLayout.parseSegment(segment)
        #expect(parts?.cameraDirectory == camera && parts?.dateDirectory == "2026-10-10" && parts?.baseName == "13-24-05")
        for bad in ["", "a/b", "a/2026-10-10", "/2026-10-10/13-24-05", "../2026-10-10/13-24-05", "./2026-10-10/13-24-05", "a/2026-10-10/13-24-05/x",
                    "a/2026-10-10/13-24-05.mp4", "a//13-24-05", "a/2026-10-10/../13-24-05"] {
            #expect(ArchiveLayout.parseSegment(bad) == nil, "\(bad.debugDescription)")
        }
    }
}
