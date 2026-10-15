import Foundation
import Testing
@testable import BridgeEngine

/// The per-minute rollups and the activity bins built from them or from fragment tables (Mac spec 4.4 and 7).
@Suite struct CatalogActivityTests {
    static let camera = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    static let start: Int64 = 1_760_088_000_000

    /// `count` fragments of 2.5 s, 300 non-keyframe bytes each (120 bytes a second), one keyframe fragment in four.
    static func index(count: Int, startMs: Int64 = start, nonKeyBytes: UInt32 = 300) -> CBIndexFile {
        ArchiveFixtureWriter.sparseIndex(camera: camera, startMs: startMs, fragmentCount: count, nonKeyBytes: nonKeyBytes)
    }

    // MARK: Rollups

    @Test func rollupsOfARegularFile() {
        let index = Self.index(count: 60)   // 150 s: two whole minutes and half a minute
        #expect(index.rollups.count == 3)
        #expect(index.rollups.map(\.coveredMs) == [60_000, 60_000, 30_000])
        #expect(index.rollups.map(\.nonKeyBytes) == [7_200, 7_200, 3_600], "24 fragments of 300 bytes a minute")
        #expect(index.rollups.map(\.peakRate) == [120, 120, 120])
        #expect(CBIndexRollups.make(fragments: []).isEmpty)
    }

    @Test func aFragmentThatCrossesAMinuteGivesEachMinuteItsShare() {
        // One 40 s fragment from 40 s to 80 s: 2,000 bytes, half in each minute; the one before it fills 0...40 s.
        let records = [
            CBIndexFragmentRecord(offset: 100, length: 10, wallDeltaMs: 0, mediaStart: 0, durationTicks: 3_600_000, headerLength: 5, keyLength: 5, nonKeyBytes: 400,
                                  samples: 10, backToKey: 0),
            CBIndexFragmentRecord(offset: 110, length: 10, wallDeltaMs: 40_000, mediaStart: 3_600_000, durationTicks: 3_600_000, headerLength: 5, keyLength: 0,
                                  nonKeyBytes: 2_000, samples: 10, backToKey: 1),
        ]
        let rollups = CBIndexRollups.make(fragments: records)
        #expect(rollups == [CBIndexRollup(nonKeyBytes: 400 + 1_000, peakRate: 50, coveredMs: 60_000), CBIndexRollup(nonKeyBytes: 1_000, peakRate: 50, coveredMs: 20_000)])
    }

    @Test func rollupsAgreeWithTheBruteForceDefinitionOnRandomFiles() {
        var generator = ArchiveStoreGenerator(seed: 0x5EED)
        for _ in 0..<200 {
            var records: [CBIndexFragmentRecord] = []
            var wall: UInt32 = 0
            for index in 0..<Int.random(in: 1...60, using: &generator) {
                let length = UInt32.random(in: 200...9_000, using: &generator)
                records.append(CBIndexFragmentRecord(offset: UInt64(1_000 + index * 10), length: 10, wallDeltaMs: wall, mediaStart: wall * 90, durationTicks: length * 90,
                                                     headerLength: 5, keyLength: index == 0 ? 5 : 0, nonKeyBytes: UInt32.random(in: 0...400_000, using: &generator),
                                                     samples: 10, backToKey: UInt16(index)))
                wall += length
            }
            #expect(CBIndexRollups.make(fragments: records) == ArchiveFixtureWriter.bruteForceRollups(records))
        }
    }

    @Test func rollupsAgreeWithTheBruteForceDefinitionWhenSpansAreRaggedAndOverlap() {
        // Durations unrelated to the gaps between starts (rounding in the recorder does this): spans that overlap, leave gaps, or are a millisecond.
        var generator = ArchiveStoreGenerator(seed: 0xFACE)
        for _ in 0..<200 {
            var records: [CBIndexFragmentRecord] = []
            var wall: UInt32 = UInt32.random(in: 0...30_000, using: &generator)
            for index in 0..<Int.random(in: 1...80, using: &generator) {
                records.append(CBIndexFragmentRecord(offset: UInt64(1_000 + index * 10), length: 10, wallDeltaMs: wall, mediaStart: wall * 90,
                                                     durationTicks: UInt32.random(in: 0...1_200_000, using: &generator), headerLength: 5, keyLength: index == 0 ? 5 : 0,
                                                     nonKeyBytes: UInt32.random(in: 0...90_000, using: &generator), samples: 10, backToKey: UInt16(index)))
                wall += UInt32.random(in: 1...15_000, using: &generator)
            }
            #expect(CBIndexRollups.make(fragments: records) == ArchiveFixtureWriter.bruteForceRollups(records))
        }
    }

    @Test func theEndOfAFileIsTheStartOfItsLastFragmentPlusItsDurationBothRounded() {
        // Starts 90,036 ticks (1,000.4 ms) into the file, which the record rounds to 1,000 ms; lasts 100,044 ticks (1,111.6 ms), which rounds to 1,112 ms.
        let last = CBIndexFragmentRecord(offset: 100, length: 10, wallDeltaMs: 1_000, mediaStart: 90_036, durationTicks: 100_044, headerLength: 5, keyLength: 5,
                                         nonKeyBytes: 0, samples: 10, backToKey: 0)
        #expect(CBIndexRollups.endWallMs(startWallMs: 5_000, last: last) == 5_000 + 1_000 + 1_112)
        let tiny = CBIndexFragmentRecord(offset: 100, length: 10, wallDeltaMs: 0, mediaStart: 0, durationTicks: 44, headerLength: 5, keyLength: 5,
                                         nonKeyBytes: 0, samples: 1, backToKey: 0)
        #expect(CBIndexRollups.endWallMs(startWallMs: 0, last: tiny) == 0, "44 ticks round down to nothing, as the recorder's end does")
        #expect(CBIndexRollups.make(fragments: [tiny]).isEmpty, "a file that ends where it starts has no minute")
    }

    @Test func rollupsSaturateInsteadOfTrapping() {
        let huge = [CBIndexFragmentRecord(offset: 100, length: 10, wallDeltaMs: 0, mediaStart: 0, durationTicks: 90, headerLength: 5, keyLength: 0,
                                          nonKeyBytes: UInt32.max, samples: 1, backToKey: 0)]
        let rollups = CBIndexRollups.make(fragments: huge)
        #expect(rollups.count == 1 && rollups[0].peakRate == UInt32.max && rollups[0].nonKeyBytes == UInt32.max && rollups[0].coveredMs == 1)
        // A second fragment 2,000 minutes in: the file is longer than the format holds, so the rollups stop at the format's limit.
        let long = CBIndexRollups.make(fragments: huge + [CBIndexFragmentRecord(offset: 110, length: 10, wallDeltaMs: 2_000 * 60_000, mediaStart: 0, durationTicks: 90,
                                                                                headerLength: 5, keyLength: 0, nonKeyBytes: 1, samples: 1, backToKey: 1)])
        #expect(long.count == CBIndexFormat.maximumRollups, "no more rollups than the format holds")
    }

    // MARK: Bins from rollups

    @Test func binsOfAMinuteOrMoreComeFromTheRollups() {
        let index = Self.index(count: 60)
        let intervals = CatalogActivity.intervals(rollups: index.rollups, fileStartMs: Self.start, visibleEndMs: index.endWallMs)
        let bins = CatalogActivity.bins(rangeStartMs: Self.start - 60_000, binMs: 60_000, binCount: 5, intervals: intervals)
        #expect(bins.map(\.coverage) == [0, 1, 1, 0.5, 0], "a minute before, two whole minutes, half a minute, nothing")
        #expect(bins.map(\.level) == [0, 120, 120, 120, 0], "the mean over the recorded part, not over the bin")
        #expect(bins.map(\.peak) == [0, 120, 120, 120, 0])
    }

    @Test func binsThatCutTheMinutesUnevenlyShareThem() {
        let index = Self.index(count: 60)
        let intervals = CatalogActivity.intervals(rollups: index.rollups, fileStartMs: Self.start, visibleEndMs: index.endWallMs)
        // Two bins of 90 s from the start: [0, 90 s) holds minute 0 and half of minute 1; [90, 180) the rest and the 30 s tail.
        let bins = CatalogActivity.bins(rangeStartMs: Self.start, binMs: 90_000, binCount: 2, intervals: intervals)
        #expect(bins.map(\.coverage) == [1, 60_000.0 / 90_000])
        #expect(bins.map(\.level) == [120, 120])
        // 7,200 + 3,600 bytes in the first bin; 3,600 + 3,600 in the second.
        let bytes = zip(bins, [90.0, 90.0]).map { $0.level * $0.coverage * $1 }
        #expect(abs(bytes[0] - 10_800) < 1e-6 && abs(bytes[1] - 7_200) < 1e-6)
    }

    @Test func levelTimesCoverageIsConservedForBinsOfAMinuteOrMore() {
        // Four files with gaps between them; the bins cut them anywhere. Every non-keyframe byte is in some bin.
        var intervals: [CatalogActivity.Interval] = []
        var total = 0.0
        for (position, count) in [96, 40, 120, 8].enumerated() {
            let start = Self.start + Int64(position) * 700_000
            let index = Self.index(count: count, startMs: start, nonKeyBytes: UInt32(300 + position * 100))
            intervals += CatalogActivity.intervals(rollups: index.rollups, fileStartMs: start, visibleEndMs: index.endWallMs)
            total += Double(index.fragments.reduce(0) { $0 + Int($1.nonKeyBytes) })
        }
        for binSeconds in [60.0, 75.0, 120.0, 330.0, 3_600.0] {
            let count = Int(3_000.0 / binSeconds) + 1
            let bins = CatalogActivity.bins(rangeStartMs: Self.start - 20_000, binMs: binSeconds * 1_000, binCount: count, intervals: intervals)
            let sum = bins.reduce(0.0) { $0 + $1.level * $1.coverage * binSeconds }
            #expect(abs(sum - total) < 1e-6 * total, "bins of \(binSeconds) s: \(sum) bytes of \(total)")
            #expect(bins.allSatisfy { $0.coverage >= 0 && $0.coverage <= 1.000_000_001 })
        }
    }

    @Test func aRollupCutWhereALaterFileTakesOverCountsOnlyWhatComesBefore() {
        let index = Self.index(count: 60)   // minute 1 is [60 s, 120 s)
        let intervals = CatalogActivity.intervals(rollups: index.rollups, fileStartMs: Self.start, visibleEndMs: Self.start + 90_000)
        #expect(intervals.map { $0.endMs - $0.startMs } == [60_000, 30_000], "minute 1 is cut at 90 s, and the third minute is gone")
        #expect(intervals[1].nonKeyBytes == 3_600 && intervals[1].peakRate == 120, "half of its bytes: the share of the minute that is left")
    }

    // MARK: Bins from fragments

    @Test func binsFinerThanAMinuteComeFromTheFragments() {
        // Four fragments of 2.5 s; the third is busy (1,000 bytes), the others 100.
        var records: [CBIndexFragmentRecord] = []
        for (position, bytes) in [100, 100, 1_000, 100].enumerated() {
            records.append(CBIndexFragmentRecord(offset: UInt64(100 + position * 10), length: 10, wallDeltaMs: UInt32(position * 2_500), mediaStart: UInt32(position * 225_000),
                                                 durationTicks: 225_000, headerLength: 5, keyLength: 0, nonKeyBytes: UInt32(bytes), samples: 50, backToKey: UInt16(position)))
        }
        let intervals = CatalogActivity.intervals(table: records, fileStartMs: Self.start, fileEndMs: Self.start + 10_000, visibleEndMs: Self.start + 10_000)
        let bins = CatalogActivity.bins(rangeStartMs: Self.start, binMs: 2_000, binCount: 6, intervals: intervals)
        #expect(bins.map(\.coverage) == [1, 1, 1, 1, 1, 0])
        // Bin 2 is [4 s, 6 s): 1 s of fragment 1 (40 B/s) and 1 s of the busy fragment 2 (400 B/s): 440 bytes over 2 s.
        #expect(abs(bins[2].level - 220) < 1e-9 && bins[2].peak == 400)
        #expect(abs(bins[0].level - 40) < 1e-9 && bins[0].peak == 40)
        #expect(abs(bins[4].level - 40) < 1e-9, "[8 s, 10 s) is the last fragment")
        let sum = bins.reduce(0.0) { $0 + $1.level * $1.coverage * 2 }
        #expect(abs(sum - 1_300) < 1e-9, "all the bytes")
    }

    @Test func binsOutsideTheRangeAndDegenerateRequestsAreHarmless() {
        let intervals = [CatalogActivity.Interval(startMs: Self.start, endMs: Self.start + 1_000, nonKeyBytes: 100, peakRate: 100)]
        #expect(CatalogActivity.bins(rangeStartMs: Self.start + 5_000, binMs: 1_000, binCount: 3, intervals: intervals).allSatisfy { $0.coverage == 0 && $0.level == 0 })
        #expect(CatalogActivity.bins(rangeStartMs: Self.start - 10_000_000_000, binMs: 1_000, binCount: 3, intervals: intervals).allSatisfy { $0.coverage == 0 })
        #expect(CatalogActivity.bins(rangeStartMs: Self.start, binMs: 0, binCount: 3, intervals: intervals).isEmpty)
        #expect(CatalogActivity.bins(rangeStartMs: Self.start, binMs: 1_000, binCount: 0, intervals: intervals).isEmpty)
    }

    // MARK: The typical level

    @Test func typicalIsTheMedianOfTheRecordedMinutesAndNeedsHalfAnHour() {
        func minutes(_ rates: [Double]) -> [(coveredMs: Int, nonKeyBytes: UInt32)] { rates.map { (60_000, UInt32($0 * 60)) } }
        #expect(CatalogActivity.typical(minutes: minutes(Array(repeating: 100, count: 29))) == nil, "29 minutes are not enough")
        #expect(CatalogActivity.typical(minutes: minutes(Array(repeating: 100, count: 30))) == 100)
        #expect(CatalogActivity.typical(minutes: minutes((1...31).map(Double.init))) == 16, "the median of 1...31")
        #expect(CatalogActivity.typical(minutes: minutes((1...32).map(Double.init))) == 16.5, "between the two middle values")
        // Minutes with less than 30 s of video do not count, and do not drag the median.
        let sparse: [(coveredMs: Int, nonKeyBytes: UInt32)] = minutes(Array(repeating: 100, count: 30)) + Array(repeating: (5_000, UInt32(10)), count: 100)
        #expect(CatalogActivity.typical(minutes: sparse) == 100)
        #expect(CatalogActivity.typical(minutes: []) == nil)
    }
}

/// SplitMix64: a deterministic generator, so any input a test produces can be regenerated from its seed.
struct ArchiveStoreGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
