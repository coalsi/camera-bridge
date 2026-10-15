import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// The scanner's repair on files the real recorder wrote (`CameraArchiveRecorder` through `RecorderRig`), not on the fixture writer's: what a
/// power cut or a pulled cable leaves of a recording, and what comes back.
@Suite struct IndexScannerRecorderTests {
    /// A recording with sound and six fragments, closed properly: the recorder's own mp4 and sidecar to compare with.
    static func recording() async throws -> (rig: RecorderRig, segment: String, file: RecordedFile, sidecar: Data) {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.interleaved(RecorderFixtures.videoFrames(0..<400, gop: 150), RecorderFixtures.audioFrames(seconds: 13)), to: recorder)
        await recorder.stop()
        let segment = try #require(rig.target.openedSegments.first)
        let file = try RecordedFile(rig, segment: segment)
        return (rig, segment, file, try Data(contentsOf: rig.files(segment).index))
    }

    @Test func aPowerCutRecordingWithoutASidecarGetsTheSidecarTheRecorderWouldHaveWritten() async throws {
        let (rig, segment, file, sidecar) = try await Self.recording()
        defer { rig.root.remove() }
        #expect(file.index.fragments.count == 6 && file.index.flags & CBIndexFormat.flagHasAudio != 0)
        let files = rig.files(segment)
        // The power went before the recorder could close the file: all the fragments are there, the sidecar is not.
        try FileManager.default.removeItem(at: files.index)
        let before = CatalogLoader.scan(root: rig.root.url)
        #expect(before.files.isEmpty && before.needsRepair.count == 1, "the loader asks for a repair")
        let outcome = try IndexScanner.repair(mp4: files.mp4, sidecar: files.index, camera: rig.camera.id)
        guard case .indexed(let index, let wholeSize, let fileSize) = outcome else {
            Issue.record("repair answered \(outcome)")
            return
        }
        #expect(wholeSize == fileSize && fileSize == UInt64(file.mp4.count), "nothing was torn: nothing is cut")
        #expect(index == file.index)
        let rebuilt = try Data(contentsOf: files.index), remaining = try Data(contentsOf: files.mp4)
        #expect(rebuilt == sidecar, "byte for byte the recorder's own sidecar")
        #expect(remaining == file.mp4)
        let after = CatalogLoader.scan(root: rig.root.url)
        #expect(after.needsRepair.isEmpty && after.files.map(\.fragmentCount) == [6], "and the loader trusts it")
    }

    @Test func aRecordingTornPastItsLastWholeFragmentIsCutBackToIt() async throws {
        let (rig, segment, original, _) = try await Self.recording()
        defer { rig.root.remove() }
        let files = rig.files(segment)
        let records = original.index.fragments
        let originalVideo = try original.videoFrames(), originalAudio = try original.audioFrames()
        var checked = 0
        for kept in 1..<records.count {
            let next = records[kept]
            // The cut lands in the next fragment's prft, in its moof, in the middle of its mdat, and one byte short of its end.
            let cuts: [(String, UInt64)] = [("inside the prft", next.offset + 5), ("inside the moof", next.offset + 40), ("in the middle", next.offset + UInt64(next.length) / 2),
                                            ("one byte short", next.offset + UInt64(next.length) - 1)]
            for (name, cut) in cuts {
                for keepsStaleSidecar in [false, true] {
                    let label = "\(kept) whole fragments, cut \(name), \(keepsStaleSidecar ? "with" : "without") the old sidecar"
                    try original.mp4.prefix(Int(cut)).write(to: files.mp4)
                    if keepsStaleSidecar { try original.index.encoded().write(to: files.index) } else { try? FileManager.default.removeItem(at: files.index) }
                    let scan = CatalogLoader.scan(root: rig.root.url)
                    #expect(scan.needsRepair.count == 1 && scan.files.isEmpty, "the loader does not trust it: \(label)")
                    let outcome = try IndexScanner.repair(mp4: files.mp4, sidecar: files.index, camera: rig.camera.id)
                    let found = try #require(IndexScannerTests.indexed(outcome), "\(label)")
                    let lastWhole = records[kept - 1]
                    let wholeEnd = lastWhole.offset + UInt64(lastWhole.length)
                    #expect(found.wholeSize == wholeEnd && found.fileSize == cut, "\(label)")
                    // The file is now exactly its whole fragments, and the sidecar says so.
                    let size = (try FileManager.default.attributesOfItem(atPath: files.mp4.path(percentEncoded: false))[.size] as? UInt64) ?? 0
                    let remaining = try Data(contentsOf: files.mp4)
                    #expect(size == wholeEnd && remaining == original.mp4.prefix(Int(wholeEnd)), "\(label)")
                    let repaired = try RecordedFile(rig, segment: segment)
                    #expect(repaired.index.fragments == Array(records.prefix(kept)), "\(label)")
                    #expect(repaired.index.startWallMs == original.index.startWallMs && repaired.index.flags == original.index.flags
                            && repaired.index.initLength == original.index.initLength && repaired.index.camera == original.index.camera, "\(label)")
                    #expect(repaired.index.endWallMs == FragmentIndexer.endWallMs(startWallMs: repaired.index.startWallMs, records: repaired.index.fragments), "\(label)")
                    #expect(repaired.index.rollups == FragmentIndexer.rollups(startWallMs: repaired.index.startWallMs, records: repaired.index.fragments), "\(label)")
                    // What was recorded before the cut plays back as it was recorded.
                    let video = try repaired.videoFrames()
                    #expect(video.map(\.nalUnits) == originalVideo.prefix(video.count).map(\.nalUnits) && video.count == repaired.frameCount, "\(label)")
                    let audio = try repaired.audioFrames()
                    #expect(audio.map(\.data) == originalAudio.prefix(audio.count).map(\.data) && !audio.isEmpty, "\(label)")
                    let trusted = CatalogLoader.scan(root: rig.root.url)
                    #expect(trusted.needsRepair.isEmpty && trusted.files.map(\.fragmentCount) == [kept], "the loader trusts what repair wrote: \(label)")
                    checked += 1
                }
            }
        }
        #expect(checked == 40, "5 fragment boundaries x 4 cuts x 2 sidecar states")
    }

    @Test func aRecordingCutInsideItsFirstFragmentHasNothingToKeepAndIsLeftAlone() async throws {
        let (rig, segment, original, _) = try await Self.recording()
        defer { rig.root.remove() }
        let files = rig.files(segment)
        let first = original.index.fragments[0]
        try original.mp4.prefix(Int(first.offset + UInt64(first.length) / 2)).write(to: files.mp4)
        try FileManager.default.removeItem(at: files.index)
        let before = try Data(contentsOf: files.mp4)
        #expect(try IndexScanner.repair(mp4: files.mp4, sidecar: files.index, camera: rig.camera.id) == .empty)
        let after = try Data(contentsOf: files.mp4)
        #expect(after == before && !FileManager.default.fileExists(atPath: files.index.path(percentEncoded: false)))
    }
}
