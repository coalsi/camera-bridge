import Foundation
import Testing
@testable import BridgeEngine

@Suite struct ArchiveFragmentTests {
    @Test func idEndAndIdentity() {
        let start = Date(timeIntervalSince1970: 1_760_099_000)
        let fragment = ArchiveFragment(camera: UUID(), segment: "cam/2026-10-10/13-24-05", index: 3, start: start, duration: 2.5, mediaStart: 675_000,
                                       hasKeyframe: false, gopStart: start.addingTimeInterval(-5), backToKey: 2, byteLength: 4_096)
        #expect(fragment.end == start.addingTimeInterval(2.5))
        #expect(fragment.fileKey == ArchiveIdentity.fileKey(forSegment: "cam/2026-10-10/13-24-05"))
        #expect(fragment.id == "\(fragment.fileKey).3" && ArchiveIdentity.parseFragmentID(fragment.id)?.index == 3)
        #expect(fragment.byteOffset == 0 && fragment.headerLength == 0 && fragment.keyLength == 0 && fragment.samples == 0)
        var other = fragment
        other.byteOffset = 7
        #expect(other != fragment, "the reader's internal fields take part in equality")
    }
}
