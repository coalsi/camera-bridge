import FMP4
import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// Parts and sound (export-clip spec 3.3, steps 5 and 8): a file whose initialization segment differs from the part's ends it.
@Suite struct ClipPlannerPartTests {
    typealias Fixture = PlannerFixture
    /// 640 x 360 and 2688 x 1520: two sets of codec settings, so two different initialization segments.
    static let small = ArchiveMediaFixtures.smallH264Format
    static let large = ArchiveMediaFixtures.tapoFormat

    /// One standard file (15 s) per entry of `formats`, each starting `gapMs` after the end of the one before, and the plan of everything in them.
    static func plan(_ formats: [VideoFormat], gapMs: Int64 = 0, sound: [Bool] = [], request: ClipRequest = Fixture.request(0, 100_000))
        async throws -> (ClipPlan, PlannerFixtureArchive, [PlannerFixtureArchive.Built]) {
        let archive = PlannerFixtureArchive()
        var built: [PlannerFixtureArchive.Built] = []
        for (position, format) in formats.enumerated() {
            built.append(try archive.add(PlannerFixtureFile(name: "13-00-\(10 + position)", startMs: Fixture.t0 + Int64(position) * (15_000 + gapMs), format: format,
                                                            audio: position < sound.count && sound[position])))
        }
        return (try await Fixture.planner(archive).plan(request), archive, built)
    }

    @Test func aChangedInitializationSegmentEndsThePartAndStartsTheNext() async throws {
        let (plan, _, built) = try await Self.plan([Self.small, Self.large])
        #expect(plan.parts.count == 2 && plan.tables.count == 2 && plan.gaps.isEmpty)
        let (one, two) = (plan.parts[0], plan.parts[1])
        #expect(one.index == 1 && one.count == 2 && two.index == 2 && two.count == 2)
        #expect(Fixture.offset(one.start) == 0 && Fixture.offset(one.end) == 15_000 && one.sampleCount == 300 && one.leadIn == 0)
        #expect(Fixture.offset(two.start) == 15_000 && Fixture.offset(two.end) == 30_000 && two.sampleCount == 300 && two.leadIn == 0)
        #expect(plan.tables[0].initialization == built[0].initData && plan.tables[1].initialization == built[1].initData)
        #expect(plan.tables[0].initialization != plan.tables[1].initialization)
        #expect(plan.tables[0].width == 640 && plan.tables[0].height == 360 && plan.tables[1].width == 2_688 && plan.tables[1].height == 1_520)
        #expect(plan.tables[0].copies.map(\.fragment.fileKey) == Array(repeating: built[0].fileKey, count: 6))
        #expect(plan.tables[1].copies.map(\.fragment.fileKey) == Array(repeating: built[1].fileKey, count: 6))
        #expect(plan.tables[1].copies.map(\.firstSample) == (0..<6).map { $0 * 50 }, "each part counts its own samples")
        #expect(plan.tables[0].wallStart == one.start && plan.tables[1].wallStart == two.start)
        #expect(plan.parts.map(\.byteCount) == plan.tables.map { Int64($0.copies.reduce(0) { $0 + $1.length }) + 100 } && plan.byteCount == one.byteCount + two.byteCount)
    }

    @Test func eachPartHasItsOwnNumberedFileName() async throws {
        let (plan, _, _) = try await Self.plan([Self.small, Self.large])
        let request = Fixture.request(0, 100_000)
        for part in plan.parts {
            #expect(part.fileName == ClipFileName.part(cameraName: "Driveway", start: part.start, end: part.end, partIndex: part.index, partCount: 2, timeZone: request.timeZone))
        }
        #expect(plan.parts[0].fileName.hasSuffix("(part 1 of 2).mp4") && plan.parts[1].fileName.hasSuffix("(part 2 of 2).mp4"))
        #expect(plan.parts[0].fileName != plan.parts[1].fileName)
    }

    @Test func partsFollowTheChangesAndNotTheFiles() async throws {
        let (same, sameArchive, _) = try await Self.plan([Self.small, Self.small])
        #expect(same.parts.count == 1 && same.parts[0].sampleCount == 600)
        #expect(sameArchive.reads(of: .initialization).count == 2, "one initialization segment per file, compared byte for byte")
        let (changes, changesArchive, built) = try await Self.plan([Self.small, Self.small, Self.large])
        #expect(changes.parts.map(\.sampleCount) == [600, 300] && changes.tables[0].copies.count == 12 && changes.tables[1].copies.count == 6)
        #expect(changesArchive.reads(of: .initialization) == [built[0].id(0), built[1].id(0), built[2].id(0)])
        let (back, _, _) = try await Self.plan([Self.small, Self.large, Self.small])
        #expect(back.parts.map(\.sampleCount) == [300, 300, 300], "a third file like the first is still another part: the one before it differs")
        #expect(back.parts.map(\.index) == [1, 2, 3] && back.parts.allSatisfy { $0.count == 3 })
    }

    @Test func aGapBetweenPartsIsSkippedAndNotHeld() async throws {
        let (plan, _, _) = try await Self.plan([Self.small, Self.large], gapMs: 2_000)
        #expect(plan.gaps == [ClipGap(from: Fixture.at(15_000), to: Fixture.at(17_000), held: false)], "there is no picture to freeze across two files")
        #expect(plan.tables[0].samples.map(\.duration) == Array(repeating: 4_500, count: 300))
        #expect(Fixture.offset(plan.parts[1].start) == 17_000)
        let (close, _, _) = try await Self.plan([Self.small, Self.large], gapMs: 500)
        #expect(close.gaps.isEmpty && close.parts.count == 2)
    }

    @Test func anOverlapBetweenPartsStillCutsTheEarlierFile() async throws {
        let (plan, _, _) = try await Self.plan([Self.small, Self.large], gapMs: -2_000)
        #expect(plan.gaps.isEmpty)
        #expect(plan.tables[0].copies[5].sampleCount == 10 && plan.parts.map(\.sampleCount) == [260, 300])
        #expect(Fixture.offset(plan.parts[0].end) == 13_000 && Fixture.offset(plan.parts[1].start) == 13_000)
    }

    @Test func aRangeThatEndsBeforeTheChangeIsOnePartAndReadsNoLaterFile() async throws {
        let (plan, archive, built) = try await Self.plan([Self.small, Self.large], request: Fixture.request(2_000, 10_000))
        #expect(plan.parts.count == 1 && plan.parts[0].count == 1 && plan.tables[0].width == 640)
        #expect(!archive.reads.contains { $0.fragment.hasPrefix(built[1].fileKey) })
    }

    @Test func soundGoesWithThePicturesFragmentByFragment() async throws {
        let (plan, _, built) = try await Self.plan([Self.small], sound: [true], request: Fixture.request(0, 5_000))
        #expect(!plan.soundOmitted && plan.parts.count == 1 && plan.parts[0].sampleCount == 100)
        let tables = try #require(plan.tables.first)
        #expect(tables.copies.map(\.length) == [104 + 49 * 44, 104 + 49 * 44], "the pictures are copied as before")
        #expect(tables.copies.map(\.skipBytes) == [Int(built[0].records[0].headerLength), Int(built[0].records[1].headerLength)])
        let sound = try #require(tables.sound)
        #expect(sound.follows == [0, 1], "each fragment's sound right after its pictures")
        #expect(sound.copies.map(\.skipBytes) == [Int(built[0].records[0].headerLength) + 104 + 49 * 44, Int(built[0].records[1].headerLength) + 104 + 49 * 44])
        #expect(zip(sound.copies, built[0].records).allSatisfy { $0.skipBytes + $0.length <= Int($1.length) }, "inside the fragment")
        #expect(sound.samples.count == sound.copies.reduce(0) { $0 + $1.sampleCount } && !sound.samples.isEmpty && sound.leadTicks >= 0)
        // The sound lasts as long as the pictures, within one sound frame.
        let pictures = Double(tables.samples.reduce(0) { $0 + Int($1.duration) }) / 90_000
        let heard = Double(sound.leadTicks + sound.samples.reduce(Int64(0)) { $0 + Int64($1.duration) }) / Double(sound.timescale)
        #expect(abs(pictures - heard) <= 1024 / Double(sound.timescale) + 0.001, "\(pictures) s of pictures, \(heard) s of sound")
        #expect(try FMP4InitReader.parse(tables.initialization).audio != nil)
    }

    @Test func aFileWithSoundCarriesItAndOneWithoutStaysSilent() async throws {
        let (silent, _, _) = try await Self.plan([Self.small, Self.small])
        #expect(!silent.soundOmitted && silent.tables.allSatisfy { $0.sound == nil })
        let (later, _, _) = try await Self.plan([Self.small, Self.small], sound: [false, true])
        #expect(!later.soundOmitted && later.parts.count == 2, "a track that appears is a changed initialization segment too")
        #expect(later.tables[0].sound == nil && later.tables[1].sound != nil)
    }
}
