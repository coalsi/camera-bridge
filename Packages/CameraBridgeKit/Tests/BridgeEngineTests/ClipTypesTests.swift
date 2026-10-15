import Foundation
import Testing
@testable import BridgeEngine

/// The shared shapes of exporting a clip (the plan's README, contracts A and B): what a request and a plan hold and add up to, and what the planner
/// hands the writer. The tasks that follow build on these names and labels, so a change here is a change to them.
@Suite struct ClipTypesTests {
    private let start = Date(timeIntervalSince1970: 1_791_813_730)
    private let request = ClipRequest(camera: UUID(), cameraName: "Driveway", start: Date(timeIntervalSince1970: 1_791_813_730),
                                      end: Date(timeIntervalSince1970: 1_791_813_830), timeZone: .gmt)

    private func part(_ index: Int, of count: Int, from: TimeInterval, to: TimeInterval, bytes: Int64) -> ClipPart {
        ClipPart(index: index, count: count, start: start.addingTimeInterval(from), end: start.addingTimeInterval(to), leadIn: 0, byteCount: bytes, sampleCount: 10,
                 fileName: "Driveway part \(index).mp4")
    }

    @Test func theStandardLimitsAreTheSpecsNumbers() {
        let standard = ClipLimits.standard
        #expect(standard.maxSecondsPerCamera == 7_200 && standard.maxTotalBytes == 21_474_836_480 && standard.maxHold == 10 && standard.continuity == 1)
        #expect(standard.maxTotalBytes == 20 * 1_073_741_824)
        #expect(standard == ClipLimits(maxSecondsPerCamera: 7_200, maxTotalBytes: 20 << 30, maxHold: 10, continuity: 1))
        var changed = standard
        changed.maxHold = 5
        #expect(changed != standard, "a limit is a plain value a test can change")
    }

    @Test func aRequestKeepsItsFieldsAndNamesFilesInTheLocalZoneUnlessToldOtherwise() {
        let camera = UUID()
        let local = ClipRequest(camera: camera, cameraName: "Driveway", start: start, end: start.addingTimeInterval(60))
        #expect(local.camera == camera && local.cameraName == "Driveway" && local.end.timeIntervalSince(local.start) == 60)
        #expect(local.timeZone == TimeZone.current)
        #expect(request.timeZone == TimeZone.gmt && request != local)
    }

    @Test func aPlanAddsUpItsPartsAndTheGapsAreValues() {
        let parts = [part(1, of: 2, from: -2, to: 40, bytes: 1_000), part(2, of: 2, from: 40, to: 100, bytes: 2_500)]
        let gap = ClipGap(from: start.addingTimeInterval(20), to: start.addingTimeInterval(22), held: true)
        let plan = ClipPlan(request: request, parts: parts, gaps: [gap], soundOmitted: true)
        #expect(plan.byteCount == 3_500 && plan.duration == 102 && plan.soundOmitted && plan.parts == parts && plan.gaps == [gap] && plan.request == request)
        #expect(gap != ClipGap(from: gap.from, to: gap.to, held: false))
        #expect(plan.tables.isEmpty, "the public initializer is for fakes: no tables")
        let nothing = ClipPlan(request: request, parts: [], gaps: [], soundOmitted: false)
        #expect(nothing.byteCount == 0 && nothing.duration == 0)
    }

    @Test func thePackageInitializerCarriesThePlannersTablesToTheWriter() {
        let fragment = ArchiveFragment(camera: UUID(), segment: "cam/2026-10-12/14-00-00", index: 3, start: start, duration: 2.5, mediaStart: 675_000, hasKeyframe: true,
                                       gopStart: start, backToKey: 0, byteLength: 4_096)
        let samples = [ClipSample(size: 6_004, duration: 4_500, compositionOffset: 0, isSync: true),
                       ClipSample(size: 404, duration: 4_500, compositionOffset: -9_000, isSync: false)]
        let copy = ClipCopy(fragment: fragment, skipBytes: 150, length: 6_408, firstSample: 0, sampleCount: 2)
        let tables = ClipPartTables(initialization: Data([1, 2, 3]), samples: samples, copies: [copy], wallStart: start, width: 4_256, height: 1_888)
        let one = part(1, of: 1, from: 0, to: 100, bytes: 6_900)
        let plan = ClipPlan(request: request, parts: [one], gaps: [], soundOmitted: false, tables: [tables])
        #expect(plan.tables.count == 1 && plan.byteCount == 6_900)
        #expect(plan.tables[0].initialization == Data([1, 2, 3]) && plan.tables[0].samples == samples && plan.tables[0].copies == [copy])
        #expect(plan.tables[0].wallStart == start && plan.tables[0].width == 4_256 && plan.tables[0].height == 1_888)
        #expect(copy.fragment == fragment && copy.skipBytes == 150 && copy.length == 6_408 && copy.firstSample == 0 && copy.sampleCount == 2)
        #expect(samples[1].size == 404 && samples[1].duration == 4_500 && samples[1].compositionOffset == -9_000 && !samples[1].isSync)
        var moved = copy
        moved.skipBytes += 1
        #expect(moved != copy, "a copy is a plain value")
    }

    @Test func everyErrorIsAValueATestCanCompare() {
        #expect(ClipError.damaged(at: start) == .damaged(at: start) && ClipError.damaged(at: start) != .damaged(at: start.addingTimeInterval(1)))
        #expect(ClipError.tooLong(maxSeconds: 7_200) != .tooLong(maxSeconds: 3_600) && ClipError.tooLarge(maxBytes: 1) == .tooLarge(maxBytes: 1))
        #expect(ClipError.sink("disk full") == .sink("disk full") && ClipError.sink("disk full") != .sink("read-only") && ClipError.cancelled != .notReady)
        let thrown: any Error = ClipError.driveGone
        #expect(thrown as? ClipError == .driveGone)
    }
}
