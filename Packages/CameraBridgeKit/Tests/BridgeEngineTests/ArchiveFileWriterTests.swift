import BridgeSupport
import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// `ArchiveFileWriter`: one file on the camera's disk queue, in the order the work was queued, reported to the store as it happens.
@Suite struct ArchiveFileWriterTests {
    struct Rig {
        let root: TemporaryDirectory
        let target = FakeWriteTarget(folder: nil)
        let camera = UUID()
        let uptime = Box<TimeInterval>(100)
        let failures = Box<[String]>([])
        let opened = Box(0)
        let queue = DispatchQueue(label: "ArchiveFileWriterTests")
        let fileSystem: any RecorderFileSystem
        let anchor = Date(timeIntervalSince1970: 1_791_590_405)

        init(fileSystem: any RecorderFileSystem = DiskFileSystem()) throws {
            root = try TemporaryDirectory()
            self.fileSystem = fileSystem
        }

        func writer(anchor: Date? = nil) -> ArchiveFileWriter {
            let directory = ArchiveCameraDirectory(naming: .cameraID, cameraID: camera, cameraName: "Test", fileSystem: fileSystem)
            let request = ArchiveFileWriter.Request(root: root.url, directory: directory, anchor: anchor ?? self.anchor, timeZone: TimeZone(identifier: "UTC")!)
            let uptime = uptime, failures = failures, opened = opened
            return ArchiveFileWriter(camera: camera, queue: queue, request: request, fileSystem: fileSystem, target: target, uptime: { uptime.value }, log: Log(category: "Test"),
                                     onOpened: { _ in opened.update { $0 += 1 } }, onFailure: { _, sentence in failures.update { $0.append(sentence) } })
        }

        func drain(_ writer: ArchiveFileWriter) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in writer.drain { continuation.resume() } }
        }

        var segment: String { "\(camera.uuidString)/2026-10-10/00-00-05" }
    }

    /// An initialization segment and three real fragments, with the index records the recorder would give them.
    static func parts() throws -> (initialization: Data, fragments: [Data], records: [CBIndexFragmentRecord]) {
        let format = RecorderFixtures.h264
        let muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil, writeProducerReferenceTime: true))
        let initialization = muxer.initializationSegment()
        let fragments = try RecorderFixtures.fragments()
        var offset = UInt64(initialization.count)
        var records: [CBIndexFragmentRecord] = []
        for fragment in fragments {
            records.append(try FragmentIndexer.record(try FragmentIndexer.measure(fragment), offset: offset, firstMediaTime: 0, previousBackToKey: records.last.map { Int($0.backToKey) }))
            offset += UInt64(fragment.count)
        }
        return (initialization, fragments, records)
    }

    @Test func opensWritesAndClosesInOrderAndTellsTheStore() async throws {
        let rig = try Rig()
        defer { rig.root.remove() }
        let parts = try Self.parts()
        let writer = rig.writer()
        writer.open(initialization: parts.initialization, startWallMs: 1_791_590_405_000, hasAudio: false)
        for (fragment, record) in zip(parts.fragments, parts.records) { writer.append(fragment, record: record, synchronize: false) }
        writer.close()
        await rig.drain(writer)
        #expect(rig.target.events == [
            .opened(segment: rig.segment, startWallMs: 1_791_590_405_000, initLength: UInt32(parts.initialization.count), hasAudio: false),
            .wrote(segment: rig.segment, record: parts.records[0]), .wrote(segment: rig.segment, record: parts.records[1]), .wrote(segment: rig.segment, record: parts.records[2]),
            .closed(segment: rig.segment, index: rig.target.closedIndex(of: rig.segment) ?? nil),
        ])
        let mp4 = try Data(contentsOf: rig.root.url.appending(path: "\(rig.segment).mp4"))
        #expect(mp4 == parts.fragments.reduce(parts.initialization) { $0 + $1 })
        let index = try CBIndexFile.decode(try Data(contentsOf: rig.root.url.appending(path: "\(rig.segment).cbidx")), mp4Size: UInt64(mp4.count))
        #expect(index.fragments == parts.records && index.camera == rig.camera && index.startWallMs == 1_791_590_405_000 && index.initLength == UInt32(parts.initialization.count))
        #expect(index.endWallMs == FragmentIndexer.endWallMs(startWallMs: index.startWallMs, records: parts.records) && !index.hasAudio)
        #expect(try posixPermissions(of: rig.root.url.appending(path: "\(rig.segment).mp4")) == 0o600)
        #expect(writer.isIdle && writer.pending == ArchiveFileWriter.Pending(bytes: 0, oldest: nil, count: 0) && !writer.hasFailed && rig.opened.value == 1)
    }

    @Test func aWriteThatFailsCutsTheFileBackToItsLastWholeFragmentAndSkipsTheRest() async throws {
        let disk = FaultyFileSystem(.init(failWrite: 3))                      // the init segment, one fragment, then "no space left on device"
        let rig = try Rig(fileSystem: disk)
        defer { rig.root.remove() }
        let parts = try Self.parts()
        let writer = rig.writer()
        writer.open(initialization: parts.initialization, startWallMs: 1_791_590_405_000, hasAudio: false)
        for (fragment, record) in zip(parts.fragments, parts.records) { writer.append(fragment, record: record, synchronize: false) }
        writer.close()
        await rig.drain(writer)
        #expect(writer.hasFailed && rig.failures.value == ["The recordings drive is full."])
        let mp4 = try Data(contentsOf: rig.root.url.appending(path: "\(rig.segment).mp4"))
        #expect(mp4 == parts.initialization + parts.fragments[0], "cut back to the whole fragment; the third append never ran")
        let index = try CBIndexFile.decode(try Data(contentsOf: rig.root.url.appending(path: "\(rig.segment).cbidx")), mp4Size: UInt64(mp4.count))
        #expect(index.fragments == [parts.records[0]])
        let kinds = rig.target.events.map { event -> String in
            switch event {
            case .opened: "opened"
            case .wrote: "wrote"
            case .closed(_, let index): index == nil ? "closed without index" : "closed"
            case .failed(let message): "failed \(message)"
            }
        }
        #expect(kinds == ["opened", "wrote", "closed", "failed NSCocoaErrorDomain 640"], "closed (with the sidecar) before the failure is reported")
    }

    @Test func aFileWhoseFirstWriteFailsIsRemovedAndNeverReported() async throws {
        let disk = FaultyFileSystem(.init(failWrite: 1))
        let rig = try Rig(fileSystem: disk)
        defer { rig.root.remove() }
        let parts = try Self.parts()
        let writer = rig.writer()
        writer.open(initialization: parts.initialization, startWallMs: 1, hasAudio: false)
        writer.append(parts.fragments[0], record: parts.records[0], synchronize: false)
        writer.close()
        await rig.drain(writer)
        #expect(rig.target.openedSegments.isEmpty && rig.target.closedSegments.isEmpty && rig.target.failures.count == 1)
        let date = rig.root.url.appending(path: "\(rig.camera.uuidString)/2026-10-10")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: date.path(percentEncoded: false))) == [], "no mp4, no sidecar")
    }

    @Test func aFolderThatIsGoneIsAFailureNotACrash() async throws {
        let rig = try Rig()
        let parts = try Self.parts()
        let writer = rig.writer()
        rig.root.remove()
        writer.open(initialization: parts.initialization, startWallMs: 1, hasAudio: false)
        await rig.drain(writer)
        #expect(rig.failures.value == ["The recordings folder isn’t available."] && rig.target.failures == ["BridgeEngine.RecorderFailure 0"] && rig.target.openedSegments.isEmpty)
    }

    @Test func anAbandonedWriterReportsItsFileClosedOnceAndNothingElse() async throws {
        let disk = FaultyFileSystem(.init(blockWrite: 2))                     // the first fragment never returns
        let rig = try Rig(fileSystem: disk)
        defer { disk.release(); rig.root.remove() }
        let parts = try Self.parts()
        let writer = rig.writer()
        writer.open(initialization: parts.initialization, startWallMs: 1_791_590_405_000, hasAudio: false)
        writer.append(parts.fragments[0], record: parts.records[0], synchronize: false)
        writer.append(parts.fragments[1], record: parts.records[1], synchronize: false)
        #expect(await eventually(timeout: .seconds(10)) { rig.target.openedSegments.count == 1 })
        #expect(writer.pending.bytes == parts.fragments[0].count + parts.fragments[1].count && writer.pending.count == 2 && writer.pending.oldest == 100)
        writer.abandon()
        writer.abandon()
        #expect(rig.target.closedSegments == [rig.segment], "once, whatever the number of calls")
        disk.release()
        await rig.drain(writer)
        #expect(rig.target.events.filter { if case .wrote = $0 { true } else { false } }.isEmpty, "nothing is reported after abandon")
        #expect(rig.target.failures.isEmpty && writer.isIdle)
    }

    @Test func pendingBytesAndAgeFallToZeroWhenTheQueueRunsOut() async throws {
        let rig = try Rig()
        defer { rig.root.remove() }
        let parts = try Self.parts()
        let writer = rig.writer()
        writer.open(initialization: parts.initialization, startWallMs: 1, hasAudio: false)
        writer.append(parts.fragments[0], record: parts.records[0], synchronize: true)
        await rig.drain(writer)
        #expect(writer.pending.bytes == 0 && writer.pending.oldest == nil && writer.isIdle)
    }

    /// The race that made the Linux suite flaky: `drain`'s completion used to run before the drained entry left `queued`, so `isIdle` was false
    /// right after a drain in about one run in two with 2 CPUs. 200 rounds of write, close, drain must always leave the writer idle.
    @Test func aDrainAlwaysLeavesTheWriterIdle() async throws {
        let rig = try Rig()
        defer { rig.root.remove() }
        let parts = try Self.parts()
        for round in 0..<200 {
            let writer = rig.writer(anchor: rig.anchor.addingTimeInterval(Double(round)))
            writer.open(initialization: parts.initialization, startWallMs: 1_791_590_405_000 + Int64(round) * 1_000, hasAudio: false)
            writer.append(parts.fragments[0], record: parts.records[0], synchronize: false)
            writer.close()
            await rig.drain(writer)
            #expect(writer.isIdle && writer.pending.count == 0, "round \(round)")
        }
        let marker = rig.writer()
        await rig.drain(marker)
        #expect(marker.isIdle && marker.pending == ArchiveFileWriter.Pending(bytes: 0, oldest: nil, count: 0), "an empty writer drains to idle too")
    }

    @Test func twoWritersOfOneCameraOnOneQueueNeverShareAFile() async throws {
        let rig = try Rig()
        defer { rig.root.remove() }
        let parts = try Self.parts()
        let first = rig.writer(), second = rig.writer()                       // the same second: the same wish for a name
        for writer in [first, second] {
            writer.open(initialization: parts.initialization, startWallMs: 1, hasAudio: false)
            writer.append(parts.fragments[0], record: parts.records[0], synchronize: false)
            writer.close()
        }
        await rig.drain(second)
        #expect(rig.target.openedSegments == [rig.segment, rig.segment + "-2"])
        #expect(rig.target.closedSegments.count == 2)
    }
}
