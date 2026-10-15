import FMP4
import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// `FragmentIndexer`: the index record of a stored fragment, measured from its own bytes; the same numbers for the recorder and a recovery scan.
@Suite struct FragmentIndexerTests {
    @Test func measuresSizesTimesAndTheKeyframe() throws {
        let fragments = try RecorderFixtures.fragments()
        let first = try FragmentIndexer.measure(fragments[0])
        #expect(first.length == fragments[0].count && first.samples == 10 && first.mediaStart == 0 && first.durationTicks == 30_000)
        let keySize = 4 + RecorderFixtures.video(0).nalUnits[0].count
        #expect(first.keyLength == keySize)
        #expect(first.nonKeyBytes == 9 * (4 + 300))
        #expect(first.headerLength == 32 + (fragments[0].count - 32 - 8 - (keySize + first.nonKeyBytes)) + 8, "prft + moof + the mdat header")
        #expect(abs((first.wallClock ?? .distantPast).timeIntervalSince(RecorderFixtures.base)) < 0.001, "the prft's time")
        let continuation = try FragmentIndexer.measure(fragments[1])
        #expect(continuation.keyLength == 0 && continuation.samples == 5 && continuation.mediaStart == 30_000 && continuation.nonKeyBytes == 5 * (4 + 300))
        #expect(continuation.wallClock != nil && !continuation.hasAudio)
        #expect(try FragmentIndexer.measure(fragments[2]).mediaStart == 45_000)
    }

    @Test func aFragmentWithSoundIsMeasuredByItsVideoOnly() throws {
        let fragments = try RecorderFixtures.fragments(audio: true)
        let measured = try FragmentIndexer.measure(fragments[0])
        #expect(measured.hasAudio && measured.samples == 10 && measured.length == fragments[0].count)
        let plain = try FragmentIndexer.measure(try RecorderFixtures.fragments()[0])
        #expect(plain.keyLength == measured.keyLength && plain.nonKeyBytes == measured.nonKeyBytes)
        #expect(measured.headerLength > plain.headerLength, "the audio track fragment makes the moof longer")
    }

    @Test func recordsChainBackToTheKeyframeAndTheWallDeltaIsRoundedMilliseconds() throws {
        let fragments = try RecorderFixtures.fragments()
        var offset: UInt64 = 1_000
        var records: [CBIndexFragmentRecord] = []
        for fragment in fragments {
            let record = try FragmentIndexer.record(try FragmentIndexer.measure(fragment), offset: offset, firstMediaTime: 0, previousBackToKey: records.last.map { Int($0.backToKey) })
            records.append(record)
            offset += UInt64(fragment.count)
        }
        #expect(records.map(\.backToKey) == [0, 1, 0])
        #expect(records.map(\.wallDeltaMs) == [0, 333, 500], "30000 ticks = 333.33 ms, 45000 ticks = 500 ms")
        #expect(records.map(\.mediaStart) == [0, 30_000, 45_000])
        #expect(records.map(\.offset) == [1_000, 1_000 + UInt64(fragments[0].count), 1_000 + UInt64(fragments[0].count + fragments[1].count)])
        #expect(records.map(\.keyLength).map { $0 > 0 } == [true, false, true])
        #expect(records[1].headerLength == records[1].length - UInt32(5 * 304), "the first video byte is where the samples start")
        // Relative to a file whose first tfdt was not 0 (a foreign file or a scan).
        let shifted = try FragmentIndexer.record(try FragmentIndexer.measure(fragments[1]), offset: 0, firstMediaTime: 30_000, previousBackToKey: 0)
        #expect(shifted.mediaStart == 0 && shifted.wallDeltaMs == 0)
        #expect(FragmentIndexer.endWallMs(startWallMs: 5_000, records: records) == 5_000 + 500 + 500)
        #expect(FragmentIndexer.endWallMs(startWallMs: 5_000, records: []) == 5_000)
    }

    @Test func refusesWhatTheIndexCannotHold() throws {
        let fragments = try RecorderFixtures.fragments()
        #expect(throws: FragmentIndexer.Failure.self) {
            _ = try FragmentIndexer.record(try FragmentIndexer.measure(fragments[1]), offset: 0, firstMediaTime: 0, previousBackToKey: nil)   // a first fragment without a keyframe
        }
        #expect(throws: FragmentIndexer.Failure.self) {
            _ = try FragmentIndexer.record(try FragmentIndexer.measure(fragments[2]), offset: 0, firstMediaTime: 50_000, previousBackToKey: 0)   // before the first fragment
        }
        #expect(throws: FragmentIndexer.Failure.self) {
            _ = try FragmentIndexer.record(try FragmentIndexer.measure(fragments[1]), offset: 0, firstMediaTime: 0, previousBackToKey: 65_535)   // a group of 65 536 fragments
        }
        var big = try FragmentIndexer.measure(fragments[0])
        big.mediaStart = UInt64(UInt32.max) + 1
        #expect(throws: FragmentIndexer.Failure.self) { _ = try FragmentIndexer.record(big, offset: 0, firstMediaTime: 0, previousBackToKey: nil) }
        big = try FragmentIndexer.measure(fragments[0])
        big.samples = 70_000
        #expect(throws: FragmentIndexer.Failure.self) { _ = try FragmentIndexer.record(big, offset: 0, firstMediaTime: 0, previousBackToKey: nil) }
    }

    @Test func onlyExactlyOneFragmentIsMeasured() throws {
        let fragments = try RecorderFixtures.fragments()
        #expect(throws: FragmentIndexer.Failure.self) { _ = try FragmentIndexer.measure(fragments[0] + fragments[1]) }
        #expect(throws: FragmentIndexer.Failure.self) { _ = try FragmentIndexer.measure(fragments[0] + Data([0])) }
        #expect(throws: FragmentIndexer.Failure.self) { _ = try FragmentIndexer.measure(Data()) }
        // Cut at every byte: a failure, never a trap.
        for length in 0..<fragments[1].count {
            #expect(throws: (any Error).self) { _ = try FragmentIndexer.measure(fragments[1].prefix(length)) }
        }
        // A slice with a start index other than 0 is measured too.
        let padded = Data(repeating: 0, count: 10) + fragments[0]
        #expect(try FragmentIndexer.measure(padded[10...]).samples == 10)
    }

    // MARK: Rollups

    func record(at wallDeltaMs: UInt32, seconds: Double, nonKeyBytes: UInt32) -> CBIndexFragmentRecord {
        CBIndexFragmentRecord(offset: 1_000, length: 100, wallDeltaMs: wallDeltaMs, mediaStart: wallDeltaMs * 90, durationTicks: UInt32(seconds * 90_000),
                              headerLength: 40, keyLength: 0, nonKeyBytes: nonKeyBytes, samples: 10, backToKey: 1)
    }

    @Test func aFragmentOnAMinuteBoundaryIsSplitByOverlap() {
        let records = [record(at: 0, seconds: 2.5, nonKeyBytes: 1_000), record(at: 58_000, seconds: 5, nonKeyBytes: 5_000)]
        let rollups = FragmentIndexer.rollups(startWallMs: 1_000_000, records: records)
        #expect(rollups == [CBIndexRollup(nonKeyBytes: 1_000 + 2_000, peakRate: 1_000, coveredMs: 2_500 + 2_000),
                            CBIndexRollup(nonKeyBytes: 3_000, peakRate: 1_000, coveredMs: 3_000)])
        #expect(FragmentIndexer.endWallMs(startWallMs: 1_000_000, records: records) == 1_000_000 + 63_000)
    }

    @Test func aContinuousFileGivesWholeMinutesAndAPartialLastOne() {
        let records = (0..<360).map { record(at: UInt32($0) * 2_500, seconds: 2.5, nonKeyBytes: 500) }
        let rollups = FragmentIndexer.rollups(startWallMs: 0, records: records)
        #expect(rollups.count == 15)
        #expect(rollups.allSatisfy { $0 == CBIndexRollup(nonKeyBytes: 12_000, peakRate: 200, coveredMs: 60_000) })
        let partial = FragmentIndexer.rollups(startWallMs: 0, records: Array(records.prefix(30)))
        #expect(partial.count == 2 && partial[1] == CBIndexRollup(nonKeyBytes: 6 * 500, peakRate: 200, coveredMs: 15_000))
        #expect(FragmentIndexer.rollups(startWallMs: 0, records: []).isEmpty)
    }

    @Test func aGapInsideAMinuteIsNotCovered() {
        let records = [record(at: 0, seconds: 2.5, nonKeyBytes: 100), record(at: 30_000, seconds: 2.5, nonKeyBytes: 400)]
        let rollups = FragmentIndexer.rollups(startWallMs: 0, records: records)
        #expect(rollups == [CBIndexRollup(nonKeyBytes: 500, peakRate: 160, coveredMs: 5_000)])
    }

    @Test func rollupsAreBoundedAndEncodeIntoAValidSidecar() throws {
        let records = (0..<10).map { record(at: UInt32($0) * 2_500, seconds: 2.5, nonKeyBytes: 500) }
        // The records are made up (offsets overlap), so only the encoded sizes are checked here.
        let index = CBIndexFile(camera: UUID(), startWallMs: 0, endWallMs: 25_000, mp4Size: 0, initLength: 0,
                                rollups: FragmentIndexer.rollups(startWallMs: 0, records: records), fragments: [])
        #expect(index.encoded().count == CBIndexFile.byteCount(rollups: 1, fragments: 0))
    }
}

/// The note that says a camera's keyframes are far apart.
@Suite struct KeyframeIntervalNoteTests {
    func feed(_ note: inout KeyframeIntervalNote, gaps: [Double], from start: Int64 = 0) -> Int64 {
        var time = start
        _ = note.observe(keyframeAt: time)
        for gap in gaps {
            time += Int64(gap * 90_000)
            _ = note.observe(keyframeAt: time)
        }
        return time
    }

    @Test func aShortIntervalHasNoNote() {
        var note = KeyframeIntervalNote()
        _ = feed(&note, gaps: [2, 2, 2, 2])
        #expect(note.note == nil)
        _ = feed(&note, gaps: [10, 10, 10, 10, 10])
        #expect(note.note == nil, "exactly 10 s does not exceed 10 s")
    }

    @Test func aLongIntervalShowsItsLengthInWholeSeconds() {
        var note = KeyframeIntervalNote()
        _ = feed(&note, gaps: [12, 12, 12])
        #expect(note.note == ArchiveNote(id: .keyframe, text: "keyframe every 12 s: scrubbing is slow"))
        var changed = KeyframeIntervalNote()
        _ = changed.observe(keyframeAt: 0)
        let afterOneGap = changed.observe(keyframeAt: 12 * 90_000)
        let afterTwoGaps = changed.observe(keyframeAt: 24 * 90_000)
        #expect(!afterOneGap, "one gap is not enough to say anything")
        #expect(afterTwoGaps, "the second gap makes the note appear")
    }

    @Test func theNumberFollowsTheMedianOnlyByThreeSecondsAndTheNoteGoesAtEightOrLess() {
        var note = KeyframeIntervalNote()
        var time = feed(&note, gaps: [12, 12, 12])
        time = feed(&note, gaps: [13, 11, 13], from: time)
        #expect(note.shown == 12, "within 3 s of what is shown")
        time = feed(&note, gaps: [20, 20, 20, 20, 20], from: time)
        #expect(note.shown == 20)
        time = feed(&note, gaps: [9, 9, 9, 9, 9], from: time)
        #expect(note.shown == 9 || note.shown == 20, "still above 8 s: the note stays")
        time = feed(&note, gaps: [8, 8, 8, 8, 8], from: time)
        #expect(note.note == nil)
        _ = time
    }

    @Test func aRestartedTimelineDoesNotMakeAGap() {
        var note = KeyframeIntervalNote()
        let time = feed(&note, gaps: [2, 2, 2])
        note.restart()
        let first = note.observe(keyframeAt: time + 600 * 90_000)
        #expect(!first, "the first keyframe after a restart starts a new gap")
        #expect(note.note == nil)
        _ = note.observe(keyframeAt: 5)                                                     // a timeline that went backwards is ignored too
        #expect(note.note == nil)
    }
}
