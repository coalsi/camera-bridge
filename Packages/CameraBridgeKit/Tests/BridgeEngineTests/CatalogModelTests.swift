import Foundation
import Testing
@testable import BridgeEngine

/// The catalog's lookups (Mac spec 7, "Behavior"): exact boundaries, the later file wins an overlap, gaps, ids, extent and the byte counts.
/// In memory only: the files are indexes from `ArchiveFixtureWriter.sparseIndex`.
@Suite struct CatalogModelTests {
    static let camera = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    /// 2025-10-10 09:20:00 UTC, an exact second.
    static let t0: Int64 = 1_760_088_000_000

    static func segment(_ base: String) -> String { ArchiveLayout.segment(cameraDirectory: camera.uuidString, dateDirectory: "2026-10-10", baseName: base) }

    /// A closed file of `count` fragments of 2.5 s starting `offsetSeconds` after `t0`.
    static func file(_ base: String, at offsetSeconds: Double, count: Int = 6, keyEvery: Int = 4) -> (CatalogFile, CBIndexFile) {
        let index = ArchiveFixtureWriter.sparseIndex(camera: camera, startMs: t0 + Int64(offsetSeconds * 1_000), fragmentCount: count, keyEvery: keyEvery)
        return (CatalogFile(segment: segment(base), index: index, sidecarBytes: UInt64(index.encoded().count)), index)
    }

    static func catalog(_ files: [(CatalogFile, CBIndexFile)], cached: Bool = true) -> CatalogState {
        var catalog = CatalogState()
        for (file, index) in files { catalog.insert(file, table: cached ? index.fragments : nil) }
        return catalog
    }

    static func date(_ offsetSeconds: Double) -> Date { ArchiveTime.date(ms: t0 + Int64(offsetSeconds * 1_000)) }

    static func containing(_ catalog: inout CatalogState, _ seconds: Double) -> ArchiveFragment? {
        if case .found(let fragment) = catalog.fragment(camera: camera, containingMicros: ArchiveTime.micros(date(seconds))) { return fragment }
        return nil
    }

    static func after(_ catalog: inout CatalogState, _ seconds: Double) -> ArchiveFragment? {
        if case .found(let fragment) = catalog.fragment(camera: camera, startingAfterMicros: ArchiveTime.micros(date(seconds))) { return fragment }
        return nil
    }

    @Test func boundariesAreExact() {
        var catalog = Self.catalog([Self.file("13-00-00", at: 0)])
        #expect(Self.containing(&catalog, 0)?.index == 0, "t == start is that fragment")
        #expect(Self.containing(&catalog, 2.4999)?.index == 0)
        #expect(Self.containing(&catalog, 2.5)?.index == 1, "t == end is the next fragment")
        #expect(Self.containing(&catalog, 14.999)?.index == 5)
        #expect(Self.containing(&catalog, 15) == nil, "the end of the last fragment is nothing")
        #expect(Self.containing(&catalog, -0.001) == nil)
        // Whatever `start + duration` rounds to, it finds the next fragment: a caller walking `fragment.end` never gets the same one twice.
        var cursor = Self.date(0)
        var seen: [Int] = []
        while let fragment = Self.containing(&catalog, cursor.timeIntervalSince(Self.date(0))) {
            seen.append(fragment.index)
            cursor = fragment.end
        }
        #expect(seen == [0, 1, 2, 3, 4, 5])
    }

    @Test func fragmentsAbutAndCarryTheIndexFields() throws {
        var catalog = Self.catalog([Self.file("13-00-00", at: 0, count: 8)])
        let fragments = (0..<8).compactMap { Self.containing(&catalog, Double($0) * 2.5 + 0.1) }
        #expect(fragments.count == 8)
        for (first, second) in zip(fragments, fragments.dropFirst()) { #expect(first.end == second.start, "fragment \(first.index) ends where the next starts") }
        let sixth = fragments[5]
        #expect(sixth.start == Self.date(12.5) && sixth.duration == 2.5 && sixth.mediaStart == 5 * 225_000)
        #expect(!sixth.hasKeyframe && sixth.backToKey == 1 && sixth.gopStart == Self.date(10), "fragment 5 is one past the keyframe at fragment 4")
        #expect(sixth.byteOffset == 600 + 5 * 4_096 && sixth.byteLength == 4_096 && sixth.headerLength == 150 && sixth.samples == 50 && sixth.nonKeyBytes == 300)
        #expect(fragments[4].hasKeyframe && fragments[4].keyLength == 200 && fragments[4].gopStart == fragments[4].start)
        #expect(sixth.id == "\(ArchiveIdentity.fileKey(forSegment: Self.segment("13-00-00"))).5" && sixth.camera == Self.camera)
    }

    @Test func theLaterFileWinsAnOverlap() {
        // A covers 0...15 s. B starts at 12.5 s, inside A's last fragment (a recorder that was replaced replays a little).
        var catalog = Self.catalog([Self.file("13-00-00", at: 0), Self.file("13-00-12", at: 12.5, count: 4)])
        #expect(Self.containing(&catalog, 12)?.segment == Self.segment("13-00-00"))
        #expect(Self.containing(&catalog, 12)?.index == 4)
        let winner = Self.containing(&catalog, 12.5)
        #expect(winner?.segment == Self.segment("13-00-12") && winner?.index == 0, "from B's start on, B")
        #expect(Self.containing(&catalog, 14)?.segment == Self.segment("13-00-12"))
        #expect(Self.containing(&catalog, 22.4)?.segment == Self.segment("13-00-12") && Self.containing(&catalog, 22.5) == nil)
        // A's own last fragment (12.5...15 s) is hidden: the walk goes A4, B0, B1 ...
        var walked: [String] = []
        var cursor = -1.0
        while let next = Self.after(&catalog, cursor) {
            walked.append("\(next.segment.suffix(8)):\(next.index)")
            cursor = next.start.timeIntervalSince(Self.date(0))
        }
        #expect(walked == ["13-00-00:0", "13-00-00:1", "13-00-00:2", "13-00-00:3", "13-00-00:4", "13-00-12:0", "13-00-12:1", "13-00-12:2", "13-00-12:3"])
    }

    @Test func twoFilesThatStartTogetherAreOrderedByName() {
        var catalog = Self.catalog([Self.file("13-00-00", at: 0, count: 2), Self.file("13-00-00-2", at: 0, count: 2)])
        #expect(Self.containing(&catalog, 1)?.segment == Self.segment("13-00-00-2"), "the later in order wins")
        #expect(Self.after(&catalog, -1)?.segment == Self.segment("13-00-00-2"))
    }

    @Test func gapsAnswerNilAndStartingAfterCrossesThem() {
        var catalog = Self.catalog([Self.file("13-00-00", at: 0, count: 2), Self.file("13-01-00", at: 60, count: 2)])
        #expect(Self.containing(&catalog, 4.9) != nil && Self.containing(&catalog, 5) == nil && Self.containing(&catalog, 30) == nil)
        #expect(Self.containing(&catalog, 59.999) == nil && Self.containing(&catalog, 60)?.segment == Self.segment("13-01-00"))
        #expect(Self.after(&catalog, -100)?.start == Self.date(0))
        #expect(Self.after(&catalog, 0)?.index == 1, "start > time: the fragment that starts at the time is not after it")
        let next = Self.after(&catalog, 2.5)
        #expect(next?.segment == Self.segment("13-01-00") && next?.index == 0 && next?.start == Self.date(60), "across the gap and into the next file")
        #expect(Self.after(&catalog, 30)?.start == Self.date(60))
        #expect(Self.after(&catalog, 62.5) == nil, "nothing after the last fragment")
        #expect(Self.after(&catalog, 65) == nil)
    }

    @Test func idsFindFragmentsEvenWhenAnOverlapHidesThem() {
        var catalog = Self.catalog([Self.file("13-00-00", at: 0), Self.file("13-00-12", at: 12.5, count: 4)])
        let key = ArchiveIdentity.fileKey(forSegment: Self.segment("13-00-00"))
        guard case .found(let hidden) = catalog.fragment(camera: Self.camera, fileKey: key, index: 5) else { Issue.record("hidden fragment not found"); return }
        #expect(hidden.start == Self.date(12.5) && hidden.segment == Self.segment("13-00-00"))
        if case .notFound = catalog.fragment(camera: Self.camera, fileKey: key, index: 6) {} else { Issue.record("index 6 does not exist") }
        if case .notFound = catalog.fragment(camera: Self.camera, fileKey: "0123456789ab", index: 0) {} else { Issue.record("unknown file key") }
        if case .notFound = catalog.fragment(camera: UUID(), fileKey: key, index: 0) {} else { Issue.record("another camera") }
    }

    @Test func aClosedFilesTableIsReadWhenALookupNeedsIt() {
        var catalog = Self.catalog([Self.file("13-00-00", at: 0)], cached: false)
        let micros = ArchiveTime.micros(Self.date(3))
        guard case .needsTable(let segment) = catalog.fragment(camera: Self.camera, containingMicros: micros) else { Issue.record("expected a table request"); return }
        #expect(segment == Self.segment("13-00-00"))
        catalog.store(table: Self.file("13-00-00", at: 0).1.fragments, forSegment: segment)
        #expect(Self.containing(&catalog, 3)?.index == 1)
        #expect(catalog.extent(camera: Self.camera, typicalGOP: nil)?.newest == Self.date(15), "the extent needs no table")
    }

    @Test func extentSpansTheFilesThatHoldVideo() {
        var catalog = Self.catalog([Self.file("13-00-00", at: 0), Self.file("13-05-00", at: 300, count: 4)])
        let extent = catalog.extent(camera: Self.camera, typicalGOP: 2)
        #expect(extent == ArchiveExtent(oldest: Self.date(0), newest: Self.date(310), typicalGOP: 2))
        #expect(catalog.extent(camera: UUID(), typicalGOP: nil) == nil)
        // An open file with no fragment yet holds no video; with one it does.
        catalog.open(CatalogFile(camera: Self.camera, segment: Self.segment("14-00-00"), startMs: Self.t0 + 3_600_000, endMs: Self.t0 + 3_600_000, initLength: 600,
                                 flags: 0, mp4Bytes: 600, sidecarBytes: 0, fragmentCount: 0, rollups: [], isOpen: true))
        #expect(catalog.extent(camera: Self.camera, typicalGOP: nil)?.newest == Self.date(310))
        catalog.append(Self.file("x", at: 0).1.fragments[0], toSegment: Self.segment("14-00-00"), camera: Self.camera)
        #expect(catalog.extent(camera: Self.camera, typicalGOP: nil)?.newest == Self.date(3_602.5))
        #expect(catalog.span?.oldest == Self.t0 && catalog.span?.newest == Self.t0 + 3_602_500)
    }

    @Test func anOpenFilesFragmentsAreVisibleAsSoonAsTheyAreWritten() {
        var catalog = CatalogState()
        let template = Self.file("x", at: 0).1
        catalog.open(CatalogFile(camera: Self.camera, segment: Self.segment("13-00-00"), startMs: Self.t0, endMs: Self.t0, initLength: 600, flags: 0, mp4Bytes: 600,
                                 sidecarBytes: 0, fragmentCount: 0, rollups: [], isOpen: true))
        #expect(catalog.usedBytes == 600 && catalog.version == 0)
        #expect(Self.containing(&catalog, 1) == nil)
        for record in template.fragments.prefix(3) { catalog.append(record, toSegment: Self.segment("13-00-00"), camera: Self.camera) }
        #expect(catalog.version == 3, "+1 per written fragment")
        #expect(Self.containing(&catalog, 6)?.index == 2 && Self.containing(&catalog, 7.5) == nil)
        #expect(catalog.usedBytes == 600 + 3 * 4_096 && catalog.openFiles.count == 1 && catalog.closedFiles.isEmpty)
        // A fragment for a file the catalog does not have changes nothing.
        catalog.append(template.fragments[0], toSegment: Self.segment("99-99-99"), camera: Self.camera)
        #expect(catalog.version == 3)
        // The recorder closes the file: its index replaces the open entry, the table stays, the version moves.
        let final = ArchiveFixtureWriter.sparseIndex(camera: Self.camera, startMs: Self.t0, fragmentCount: 3)
        catalog.close(segment: Self.segment("13-00-00"), index: final, sidecarBytes: 300)
        #expect(catalog.version == 4 && catalog.openFiles.isEmpty && catalog.closedFiles.count == 1)
        #expect(catalog.usedBytes == final.mp4Size + 300)
        #expect(Self.containing(&catalog, 6)?.index == 2)
    }

    @Test func bytesAreCountedOncePerFileAndLeaveWithTheFile() {
        let (first, firstIndex) = Self.file("13-00-00", at: 0)
        var catalog = Self.catalog([(first, firstIndex)])
        let size = first.bytes
        #expect(catalog.usedBytes == size)
        catalog.insert(first)   // the same segment replaces the entry
        #expect(catalog.usedBytes == size && catalog.fileCount == 1)
        let (second, secondIndex) = Self.file("13-05-00", at: 300, count: 2)
        catalog.insert(second, table: secondIndex.fragments)
        #expect(catalog.usedBytes == size + second.bytes && catalog.cameras == [Self.camera])
        #expect(catalog.remove(segment: first.segment, camera: Self.camera)?.segment == first.segment)
        #expect(catalog.usedBytes == second.bytes && catalog.remove(segment: first.segment, camera: Self.camera) == nil)
        catalog.remove(segment: second.segment, camera: Self.camera)
        #expect(catalog.isEmpty && catalog.usedBytes == 0 && catalog.cachedTableCount == 0)
    }

    @Test func theTableCacheKeepsTheMostRecentlyUsedTables() {
        var cache = CatalogTableCache(capacity: 3)
        let table = Self.file("x", at: 0).1.fragments
        for name in ["a", "b", "c"] { cache.insert(table, for: name) }
        #expect(cache.table(for: "a") != nil, "touching a makes b the oldest")
        cache.insert(table, for: "d")
        #expect(cache.count == 3 && cache.table(for: "b") == nil && cache.table(for: "a") != nil && cache.table(for: "c") != nil && cache.table(for: "d") != nil)
        var catalog = CatalogState()
        for position in 0..<300 {
            let index = ArchiveFixtureWriter.sparseIndex(camera: Self.camera, startMs: Self.t0 + Int64(position) * 100_000, fragmentCount: 2)
            catalog.insert(CatalogFile(segment: Self.segment(String(format: "%02d-%02d-00", position / 60, position % 60)), index: index, sidecarBytes: 10),
                           table: index.fragments)
        }
        #expect(catalog.fileCount == 300 && catalog.cachedTableCount == min(300, ArchiveConstants.tableCacheFiles))
    }

    @Test func timeIsComparedInMicrosecondsSoAnEndFindsTheNextFragment() {
        // 1,760,088,002.5 seconds as a Date is not exactly 2.5 s after 1,760,088,000: the lookup must not care.
        var catalog = Self.catalog([Self.file("13-00-00", at: 0)])
        let first = Self.containing(&catalog, 0)!
        let end = first.start.addingTimeInterval(first.duration)
        #expect(ArchiveTime.micros(end) == ArchiveTime.micros(Self.date(2.5)))
        if case .found(let next) = catalog.fragment(camera: Self.camera, containingMicros: ArchiveTime.micros(end)) { #expect(next.index == 1) } else { Issue.record("no next") }
        #expect(ArchiveTime.ms(Date(timeIntervalSince1970: .infinity)) > 0 && ArchiveTime.ms(Date(timeIntervalSince1970: .nan)) == 0)
    }

    @Test func aBatchReplacesTheSameSegmentSortsAndCountsOnce() {
        var catalog = Self.catalog([Self.file("13-00-00", at: 0)])
        let before = catalog.version
        let newer = Self.file("13-00-00", at: 0, count: 3).0                 // the same segment again, smaller
        let others = [Self.file("13-30-00", at: 1_800).0, Self.file("13-15-00", at: 900).0]
        catalog.insert(batch: [others[0], newer, others[1]])
        #expect(catalog.version == before + 1 && catalog.fileCount == 3)
        #expect(catalog.files[Self.camera]?.map(\.startMs) == [Self.t0, Self.t0 + 900_000, Self.t0 + 1_800_000], "in start order")
        #expect(catalog.files[Self.camera]?.first?.fragmentCount == 3)
        #expect(catalog.usedBytes == newer.bytes + others[0].bytes + others[1].bytes)
        catalog.insert(batch: [])
        #expect(catalog.version == before + 2 && catalog.fileCount == 3)
    }
}
