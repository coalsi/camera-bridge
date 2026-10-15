import BridgeEngine
import Foundation
import Synchronization
import Testing

/// What a test in another target needs from the clip types: a `ClipExporting` that makes a `ClipPlan` through the public initializer (no planner, no
/// tables) and writes to a `ClipSink`. The route tests of the box and the model tests of the Mac app stand on exactly this until the real exporter is
/// there, so it must keep compiling without `@testable`.
@Suite(.timeLimit(.minutes(1))) struct ClipTypesFromOutsideTests {
    /// Answers every request with the plan it was given, and writes `chunks` to the sink, one write each.
    private struct CannedExporter: ClipExporting {
        let canned: ClipPlan
        let chunks: [Data]

        func plan(_ request: ClipRequest) async throws -> ClipPlan { canned }

        func export(_ plan: ClipPlan, part: Int, to sink: any ClipSink, progress: @Sendable (Int64) -> Void) async throws {
            guard plan.parts.indices.contains(part - 1) else { throw ClipError.nothingRecorded }
            var written: Int64 = 0
            for chunk in chunks {
                try await sink.write(chunk)
                written += Int64(chunk.count)
                progress(written)
            }
        }
    }

    private final class CollectingSink: ClipSink {
        let writes = Mutex<[Data]>([])
        func write(_ bytes: Data) async throws { writes.withLock { $0.append(bytes) } }
    }

    private let start = Date(timeIntervalSince1970: 1_791_813_730)

    private func request() -> ClipRequest {
        ClipRequest(camera: UUID(), cameraName: "Driveway", start: start, end: start.addingTimeInterval(300), timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    @Test func aFakeBuildsAPlanThroughThePublicInitializerAndWritesToASink() async throws {
        let request = request()
        let name = ClipFileName.part(cameraName: request.cameraName, start: request.start, end: request.end, partIndex: 1, partCount: 1, timeZone: request.timeZone)
        let part = ClipPart(index: 1, count: 1, start: start.addingTimeInterval(-1.5), end: start.addingTimeInterval(300), leadIn: 1.5, byteCount: 8, sampleCount: 6_000,
                            fileName: name)
        let gap = ClipGap(from: start.addingTimeInterval(120), to: start.addingTimeInterval(122), held: true)
        let plan = ClipPlan(request: request, parts: [part], gaps: [gap], soundOmitted: false)
        let exporter: any ClipExporting = CannedExporter(canned: plan, chunks: [Data([1, 2, 3, 4, 5]), Data([6, 7, 8])])

        let planned = try await exporter.plan(request)
        #expect(planned.byteCount == 8 && planned.duration == 301.5 && planned.parts == [part] && planned.gaps == [gap] && planned.request == request)
        #expect(planned.parts[0].fileName == "Driveway 2026-10-12 14.02.10 to 14.07.10.mp4")

        let sink = CollectingSink()
        let progressed = Mutex<[Int64]>([])
        try await exporter.export(planned, part: 1, to: sink) { bytes in progressed.withLock { $0.append(bytes) } }
        #expect(sink.writes.withLock { $0 } == [Data([1, 2, 3, 4, 5]), Data([6, 7, 8])], "each call is one write, in order")
        #expect(progressed.withLock { $0 } == [5, 8], "progress is the bytes written so far")
        #expect(progressed.withLock { $0.last } == planned.byteCount, "and ends at the planned size")
    }

    @Test func aFakeThrowsTheEnginesErrorsAndASinkCanRefuse() async throws {
        let request = request()
        let plan = ClipPlan(request: request, parts: [], gaps: [], soundOmitted: false)
        let exporter = CannedExporter(canned: plan, chunks: [Data([1])])
        await #expect(throws: ClipError.nothingRecorded) { try await exporter.export(plan, part: 1, to: CollectingSink()) { _ in } }

        struct FullSink: ClipSink {
            func write(_ bytes: Data) async throws { throw ClipError.sink("There is not enough room.") }
        }
        let part = ClipPart(index: 1, count: 1, start: start, end: start.addingTimeInterval(1), leadIn: 0, byteCount: 1, sampleCount: 1, fileName: "A.mp4")
        let one = ClipPlan(request: request, parts: [part], gaps: [], soundOmitted: false)
        await #expect(throws: ClipError.sink("There is not enough room.")) { try await exporter.export(one, part: 1, to: FullSink()) { _ in } }
    }
}
