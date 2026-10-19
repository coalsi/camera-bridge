import BridgeEngine
import Foundation
import Testing

@Suite struct WaveformTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func activity(_ bins: [(coverage: Double, level: Double)], typical: Double?) -> ArchiveActivity {
        ArchiveActivity(start: start, binDuration: 60, bins: bins.map { .init(coverage: $0.coverage, level: $0.level, peak: $0.level * 2) }, typical: typical, isComplete: true)
    }

    @Test func oneCamerasColumnsAreRelativeToItsTypicalLevel() {
        let columns = WaveformColumns.combine([activity([(1, 2_000), (1, 6_000), (0.5, 1_000), (0, 0)], typical: 2_000)])
        #expect(columns.coverage == [1, 1, 0.5, 0])
        #expect(columns.level == [1, 3, 0.5, 0])
    }

    @Test func theGridTakesTheLargestRelativeLevelOverTheCamerasThatRecorded() {
        let quiet = activity([(1, 100), (1, 100), (0, 0), (0, 0)], typical: 100)       // normal 100 B/s
        let busy = activity([(1, 5_000), (0, 0), (1, 20_000), (0, 0)], typical: 10_000)  // normal 10 kB/s
        let columns = WaveformColumns.combine([quiet, busy])
        #expect(columns.level == [1, 1, 2, 0], "bin 0: quiet is at 1x, busy at 0.5x; bin 1: quiet 1x, busy did not record; bin 2: busy at 2x")
        #expect(columns.coverage == [1, 1, 1, 0], "a bin no camera recorded is empty")
    }

    @Test func aCameraWithoutATypicalLevelIsJudgedAgainstAQuarterOfItsOwnP99() {
        let bins = (1...100).map { (coverage: 1.0, level: Double($0) * 100) }    // 100 ... 10_000 B/s
        let columns = WaveformColumns.combine([activity(bins, typical: nil)])
        // p99 is 9_900; a quarter of it is 2_475.
        #expect(abs(columns.level[99] - 10_000 / 2_475) < 0.0001)
        let young = WaveformColumns.combine([activity([(1, 50), (1, 100)], typical: nil)])
        #expect(young.level[1] == 100.0 / 250, "at least 250 B/s counts as normal: quiet noise stays small")
        #expect(WaveformColumns.combine([activity([(1, 5)], typical: 0)]).level[0] > 0, "a typical of 0 is not used")
    }

    @Test func columnsFollowTheShortestAnswer() {
        let a = activity([(1, 1), (1, 1), (1, 1)], typical: 1)
        let b = activity([(1, 1)], typical: 1)
        #expect(WaveformColumns.combine([a, b]).level.count == 1)
        #expect(WaveformColumns.combine([]) == .empty)
        #expect(WaveformColumns.combine([activity([], typical: 1)]) == .empty)
    }

    @Test func theReferenceIsFourTimesTypicalOrTheP99WithAFloor() {
        #expect(WaveformScale.reference(typical: 500, visibleLevels: [1, 2, 3]) == 2_000)
        #expect(WaveformScale.reference(typical: nil, visibleLevels: (1...100).map { Double($0) * 100 }) == 9_900)
        #expect(WaveformScale.reference(typical: nil, visibleLevels: [10, 20]) == 1_000, "a 1 KB/s floor")
        #expect(WaveformScale.reference(typical: nil, visibleLevels: []) == 1_000)
        #expect(WaveformScale.reference(typical: 0, visibleLevels: [5_000]) == 5_000, "a typical of 0 falls back to the p99")
        #expect(WaveformScale.reference(typical: 1, visibleLevels: []) == 4, "relative levels: normal is 1 and the reference 4")
    }

    @Test func heightIsTheSquareRootOfTheLevelUpToTheReference() {
        #expect(WaveformScale.height(level: 1, reference: 4) == 0.5, "normal sits at half height")
        #expect(WaveformScale.height(level: 4, reference: 4) == 1)
        #expect(WaveformScale.height(level: 40, reference: 4) == 1, "capped")
        #expect(WaveformScale.height(level: 0, reference: 4) == 0)
        #expect(WaveformScale.height(level: -3, reference: 4) == 0)
        #expect(WaveformScale.height(level: 1, reference: 0) == 0)
        #expect(WaveformScale.highActivity == 1.5)
        #expect(WaveformScale.height(level: WaveformScale.highActivity, reference: 4) > WaveformScale.height(level: 1, reference: 4), "amber bars are also taller than the line")
    }

    @Test func theP99OfAFewValuesIsTheLargest() {
        #expect(WaveformScale.percentile99([]) == 0)
        #expect(WaveformScale.percentile99([7]) == 7)
        #expect(WaveformScale.percentile99([1, 9, 5]) == 9)
        #expect(WaveformScale.percentile99((1...200).map(Double.init)) == 198)
    }
}
