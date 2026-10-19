import BridgeEngine
import CoreGraphics
import Foundation
import Synchronization
import Testing

@MainActor @Suite(.timeLimit(.minutes(1))) struct TimelineActivityModelTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func theRequestFillsTheViewportWithTwoPointColumnsAlignedToTheBinLength() throws {
        let viewport = TimelineViewport(start: start.addingTimeInterval(1_234.5), duration: 3_600)
        let request = try #require(ActivityRequest.make(viewport: viewport, width: 800))
        #expect(request.binCount == 401 && abs(request.binDuration - 9) < 0.0001, "400 visible bins of 9 s, and one more for the right edge")
        let steps = request.range.lowerBound.timeIntervalSinceReferenceDate / request.binDuration
        #expect(abs(steps - steps.rounded()) < 1e-6, "aligned to a multiple of the bin length")
        #expect(request.range.lowerBound <= viewport.start && request.range.upperBound >= viewport.end)
        #expect(request.offset <= 0 && request.offset > -request.binDuration)
        // Panning by exactly one bin moves the grid by one bin and nothing shimmers.
        let panned = try #require(ActivityRequest.make(viewport: TimelineViewport(start: viewport.start.addingTimeInterval(9), duration: 3_600), width: 800))
        #expect(abs(panned.range.lowerBound.timeIntervalSince(request.range.lowerBound) - 9) < 0.0001)
        #expect(abs(panned.offset - request.offset) < 0.0001)
        #expect(ActivityRequest.make(viewport: viewport, width: 1) == nil && ActivityRequest.make(viewport: TimelineViewport(start: start, duration: 0), width: 800) == nil)
    }

    @Test func oneQuestionIsInFlightAndOnlyTheNewestAnswerIsShown() async {
        let id = UUID()
        let archive = FakeArchiveReader([FakeTimeline(camera: id, fragments: 10)])
        let gate = Gate()
        let asked = Mutex<[Range<Date>]>([])
        archive.setActivity { _, range, count in
            asked.withLock { $0.append(range) }
            await gate.wait()
            return ArchiveActivity(start: range.lowerBound, binDuration: range.upperBound.timeIntervalSince(range.lowerBound) / Double(count),
                                   bins: Array(repeating: .init(coverage: 1, level: Double(count), peak: 0), count: count), typical: 1, isComplete: true)
        }
        let model = TimelineActivityModel(archive: archive)
        model.setCameras([id])
        model.update(viewport: TimelineViewport(start: start, duration: 600), width: 400)   // asks: 201 bins
        await eventually { asked.withLock { $0.count } == 1 }
        model.update(viewport: TimelineViewport(start: start, duration: 1_200), width: 600)   // 301 bins, while the first is out
        model.update(viewport: TimelineViewport(start: start, duration: 1_200), width: 800)   // 401 bins: the one that counts
        #expect(asked.withLock { $0.count } == 1, "nothing else is sent while one question is out")
        gate.open()
        await eventually { model.answered?.binCount == 401 }
        #expect(model.answered?.binCount == 401 && model.columns.level.count == 401)
        #expect(asked.withLock { $0.count } == 2, "the first answer was dropped; one more question, the newest")
    }

    @Test func theSameViewportIsNotAskedTwice() async {
        let id = UUID()
        let archive = FakeArchiveReader([FakeTimeline(camera: id, fragments: 10)])
        let model = TimelineActivityModel(archive: archive)
        model.setCameras([id])
        let viewport = TimelineViewport(start: start, duration: 600)
        model.update(viewport: viewport, width: 400)
        await eventually { model.answered != nil }
        model.update(viewport: viewport, width: 400)
        model.setCameras([id])
        try? await Task.sleep(for: .milliseconds(30))
        #expect(archive.activityCalls == 1)
        #expect(model.normalIsKnown && model.isComplete && model.columns.coverage.count == 201)
    }

    @Test func camerasAreCombinedAndAnIncompleteAnswerAsksAgainButNotMoreOftenThanEveryTwoSeconds() async {
        let ids = [UUID(), UUID()]
        let archive = FakeArchiveReader(ids.map { FakeTimeline(camera: $0, fragments: 10) })
        let complete = Mutex(false)
        archive.setActivity { camera, range, count in
            ArchiveActivity(start: range.lowerBound, binDuration: 3, bins: Array(repeating: .init(coverage: 1, level: camera == ids[0] ? 100 : 400, peak: 0), count: count),
                            typical: camera == ids[0] ? 100 : 200, isComplete: complete.withLock { $0 })
        }
        let uptime = Mutex<TimeInterval>(100)
        let model = TimelineActivityModel(archive: archive, uptime: { uptime.withLock { $0 } }, minimumInterval: 2)
        model.setCameras(ids)
        model.update(viewport: TimelineViewport(start: start, duration: 600), width: 400)
        await eventually { model.answered != nil }
        #expect(model.columns.level.allSatisfy { $0 == 2 }, "max over cameras of level / typical: 100/100 and 400/200")
        #expect(!model.isComplete)
        let asks = archive.activityCalls
        uptime.withLock { $0 += 1 }
        model.catalogMayHaveChanged()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(archive.activityCalls == asks, "one second after the last answer: too soon")
        uptime.withLock { $0 += 1.5 }
        complete.withLock { $0 = true }
        model.catalogMayHaveChanged()
        await eventually { model.isComplete }
        #expect(archive.activityCalls > asks && model.isComplete)
        let settled = archive.activityCalls
        uptime.withLock { $0 += 10 }
        model.catalogMayHaveChanged()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(archive.activityCalls == settled, "a complete answer and an unchanged catalog: nothing to ask")
        archive.setCatalogVersion(5)
        model.catalogMayHaveChanged()
        await eventually { archive.activityCalls > settled }
        #expect(archive.activityCalls == settled + 2, "a new catalog version asks again: once per camera")
    }

    @Test func noCamerasNoWaveform() async {
        let model = TimelineActivityModel(archive: FakeArchiveReader([]))
        model.update(viewport: TimelineViewport(start: start, duration: 600), width: 400)
        model.setCameras([])
        #expect(model.columns == .empty)
    }
}
