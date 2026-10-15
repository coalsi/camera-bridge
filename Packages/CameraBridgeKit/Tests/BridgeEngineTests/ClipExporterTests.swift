import FMP4
import Foundation
import Testing
@testable import BridgeEngine

/// The two halves together (export-clip design, sections 3 and 4): what `plan` promises is what `export` writes, over the fixture archive and over
/// the preview archive and an archive that is not ready.
@Suite struct ClipExporterTests {
    typealias Fixture = PlannerFixture

    @Test func theFileIsExactlyThePlannedSizeForEveryRangeOfTheStandardFile() async throws {
        let archive = PlannerFixtureArchive()
        _ = try archive.add(PlannerFixtureFile())
        let exporter = ClipExporter(archive: archive)
        for (from, to) in [(0, 2_500), (500, 1_500), (3_000, 11_000), (0, 15_000), (7_400, 14_900), (12_500, 15_000)] as [(Int64, Int64)] {
            let plan = try await exporter.plan(Fixture.request(from, to))
            for part in plan.parts {
                let sink = CollectingSink()
                try await exporter.export(plan, part: part.index, to: sink) { _ in }
                #expect(Int64(sink.data.count) == part.byteCount, "\(from) to \(to): \(part.byteCount) bytes")
                let boxes = try MP4BoxReader.parse(sink.data)
                #expect(boxes.map(\.type) == ["ftyp", "moov", "mdat"])
                #expect(boxes.last.map { $0.offset + $0.size } == sink.data.count)
            }
        }
    }

    @Test func aRangeThatCrossesAGapOfFiveSecondsHoldsThePictureAndThePartKeepsItsTimeline() async throws {
        let archive = PlannerFixtureArchive()
        _ = try archive.add(PlannerFixtureFile())
        _ = try archive.add(PlannerFixtureFile(name: "13-00-20", startMs: Fixture.t0 + 20_000))
        let exporter = ClipExporter(archive: archive)
        let plan = try await exporter.plan(Fixture.request(10_000, 25_000))
        #expect(plan.gaps.count == 1 && plan.gaps[0].held && plan.parts.count == 1)
        let sink = CollectingSink()
        try await exporter.export(plan, part: 1, to: sink) { _ in }
        #expect(Int64(sink.data.count) == plan.byteCount)
        let moov = try #require(try MP4BoxReader.parse(sink.data).first { $0.type == "moov" })
        let stts = try #require(moov.descendant(atPath: "trak/mdia/minf/stbl/stts"))
        let entries = ClipWriterTests.u32(sink.data, stts.payloadOffset + 4)
        #expect(entries >= 2, "the lengthened sample is an entry of its own")
        let mvhd = try #require(moov.child("mvhd"))
        let milliseconds = ClipWriterTests.u32(sink.data, mvhd.payloadOffset + 16)
        #expect(abs(Double(milliseconds) - plan.duration * 1_000) < 100, "the movie lasts as long as the plan says")
    }

    @Test func anArchiveThatIsNotReadyAndOneWithoutRecordingsSaySoInTheCallersTerms() async throws {
        let archive = PlannerFixtureArchive()
        _ = try archive.add(PlannerFixtureFile())
        archive.setReady(false)
        await #expect(throws: ClipError.notReady) { try await ClipExporter(archive: archive).plan(Fixture.request(0, 5_000)) }
        archive.setReady(true)
        await #expect(throws: ClipError.nothingRecorded) { try await ClipExporter(archive: archive).plan(Fixture.request(0, 5_000, camera: UUID())) }
    }

    @Test func aPlanFromAnotherSourceIsNotWritten() async throws {
        let archive = PlannerFixtureArchive()
        _ = try archive.add(PlannerFixtureFile())
        let plan = try await ClipExporter(archive: archive).plan(Fixture.request(0, 5_000))
        let foreign = ClipPlan(request: plan.request, parts: plan.parts, gaps: plan.gaps, soundOmitted: false)
        await #expect(throws: ClipError.notReady) { try await ClipExporter(archive: archive).export(foreign, part: 1, to: CollectingSink()) { _ in } }
    }

    @Test func aCallerThatCancelsGetsCancelled() async throws {
        let archive = PlannerFixtureArchive()
        _ = try archive.add(PlannerFixtureFile())
        let exporter = ClipExporter(archive: archive)
        let plan = try await exporter.plan(Fixture.request(0, 15_000))
        let sink = CollectingSink(cancelAfter: 4)
        let task = Task { try await exporter.export(plan, part: 1, to: sink) { _ in } }
        await #expect(throws: ClipError.cancelled) { try await task.value }
    }
}
