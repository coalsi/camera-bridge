import FMP4
import Foundation
import Testing
@testable import BridgeEngine

/// Opt in: `CAMERABRIDGE_CLIP_REAL_MP4=<a recorded fragmented MP4: ftyp, moov, then prft + moof + mdat>` and `CAMERABRIDGE_CLIP_REAL_OUT=<a directory>`
/// exports the whole file (and a slice of it) through `ClipExporter`, to be played and decoded by a real tool (`ffprobe`, `ffmpeg -f null`, QuickTime).
/// Without the variables the test passes at once and does nothing.
@Suite struct ClipExporterRealDataTests {
    @Test func aRealRecordingExportsToAFileARealDecoderPlays() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CAMERABRIDGE_CLIP_REAL_MP4"], let out = environment["CAMERABRIDGE_CLIP_REAL_OUT"] else { return }
        let source = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let boxes = try MP4BoxReader.parse(source)
        let firstFragment = try #require(boxes.first { $0.type == "prft" || $0.type == "moof" })
        let initData = source.prefix(firstFragment.offset)
        var fragments: [Data] = []
        var current = Data()
        for box in boxes where box.offset >= firstFragment.offset {
            current.append(source.subdata(in: box.offset ..< box.offset + box.size))
            if box.type == "mdat" { fragments.append(current); current = Data() }
        }
        let archive = PlannerFixtureArchive()
        _ = try archive.addRecorded(initData: Data(initData), fragments: fragments)
        let exporter = ClipExporter(archive: archive)
        let extent = try #require(archive.extent(camera: PlannerFixture.camera))
        let total = extent.newest.timeIntervalSince(extent.oldest)
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        for (label, from, to) in [("whole", 0.0, total), ("slice", total * 0.31, total * 0.62)] {
            let request = ClipRequest(camera: PlannerFixture.camera, cameraName: name, start: extent.oldest.addingTimeInterval(from),
                                      end: extent.oldest.addingTimeInterval(to), timeZone: TimeZone(identifier: "UTC")!)
            let plan = try await exporter.plan(request)
            for part in plan.parts {
                let sink = CollectingSink()
                try await exporter.export(plan, part: part.index, to: sink) { _ in }
                #expect(Int64(sink.data.count) == part.byteCount)
                try sink.data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name) \(label) \(part.index).mp4"))
            }
        }
    }
}
