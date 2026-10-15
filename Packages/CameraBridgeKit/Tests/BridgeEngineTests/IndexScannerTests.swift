import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// Rebuilding an index from the mp4 (Mac spec 4.5 and 15, "Index and recovery"). The files are written by the real muxer; their indexes by the
/// fixture writer, from the numbers it fed to the muxer.
@Suite struct IndexScannerTests {
    static let camera = ArchiveStoreHarness.camera

    /// A folder with one fixture file and no sidecar.
    static func fixture(fragments: [ArchiveFixtureFragment] = Array(repeating: ArchiveFixtureFragment(), count: 6), hasAudio: Bool = false) throws -> (TemporaryDirectory, ArchiveFixtureResult) {
        let directory = try TemporaryDirectory()
        let result = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString, fragments: fragments, hasAudio: hasAudio, writesIndex: false),
                                                    root: directory.url)
        return (directory, result)
    }

    static func indexed(_ outcome: IndexScanOutcome) -> (index: CBIndexFile, wholeSize: UInt64, fileSize: UInt64)? {
        if case .indexed(let index, let whole, let size) = outcome { return (index, whole, size) }
        return nil
    }

    @Test func rebuildsExactlyTheIndexTheWriterMade() throws {
        let plans: [(String, [ArchiveFixtureFragment], Bool)] = [
            ("plain", Array(repeating: ArchiveFixtureFragment(), count: 6), false),
            ("a long group of pictures in continuation fragments", [ArchiveFixtureFragment(), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(),
                                                                    ArchiveFixtureFragment(frames: 17, startsOnKey: false)], false),
            ("with sound", Array(repeating: ArchiveFixtureFragment(), count: 5), true),
            ("a long recording", Array(repeating: ArchiveFixtureFragment(), count: 100), false),
        ]
        for (name, plan, sound) in plans {
            let (directory, result) = try Self.fixture(fragments: plan, hasAudio: sound)
            defer { directory.remove() }
            let found = try #require(Self.indexed(try IndexScanner.scan(mp4: result.mp4, camera: Self.camera)), Comment(rawValue: name))
            #expect(found.index == result.index, Comment(rawValue: name))
            #expect(found.index.encoded() == result.index.encoded(), "byte for byte: \(name)")
            #expect(found.wholeSize == found.fileSize && found.fileSize == result.index.mp4Size)
            #expect(found.index.hasAudio == sound)
        }
    }

    @Test func theIndexIsTheOneTheRecorderBuildsFromTheBytesOfEachFragment() throws {
        // The recorder measures every whole fragment with `FragmentIndexer`; the scanner reads only the box headers. Both give the same file.
        let plan = [ArchiveFixtureFragment(), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(frames: 17, startsOnKey: false), ArchiveFixtureFragment(),
                    ArchiveFixtureFragment(frames: 33)]
        for sound in [false, true] {
            let (directory, result) = try Self.fixture(fragments: plan, hasAudio: sound)
            defer { directory.remove() }
            var records: [CBIndexFragmentRecord] = []
            var offset = UInt64(result.initData.count)
            var first: UInt64?
            var startWallMs: Int64?
            for data in result.fragments {
                let measurement = try FragmentIndexer.measure(data)
                first = first ?? measurement.mediaStart
                startWallMs = startWallMs ?? Int64(((measurement.wallClock ?? .distantPast).timeIntervalSince1970 * 1_000).rounded())
                records.append(try FragmentIndexer.record(measurement, offset: offset, firstMediaTime: first!, previousBackToKey: records.last.map { Int($0.backToKey) }))
                offset += UInt64(data.count)
            }
            let start = try #require(startWallMs)
            let found = try #require(Self.indexed(try IndexScanner.scan(mp4: result.mp4, camera: Self.camera))).index
            #expect(found.fragments == records && found.startWallMs == start && found.startWallMs == result.file.startMs)
            #expect(found.endWallMs == FragmentIndexer.endWallMs(startWallMs: start, records: records))
            #expect(found.rollups == FragmentIndexer.rollups(startWallMs: start, records: records))
            #expect(found.rollups == CBIndexRollups.make(fragments: records) && found.rollups == ArchiveFixtureWriter.bruteForceRollups(records))
        }
    }

    @Test func repairWritesTheSidecarAndLeavesAWholeFileAsItWas() throws {
        let (directory, result) = try Self.fixture()
        defer { directory.remove() }
        let before = try Data(contentsOf: result.mp4)
        let outcome = try IndexScanner.repair(mp4: result.mp4, sidecar: result.sidecar, camera: Self.camera)
        #expect(Self.indexed(outcome)?.index == result.index)
        #expect(try Data(contentsOf: result.mp4) == before && (try Data(contentsOf: result.sidecar)) == result.index.encoded())
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: result.sidecar.path(percentEncoded: false))[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        // The loader trusts what repair wrote, and repairing again changes nothing.
        let scan = CatalogLoader.scan(root: directory.url)
        #expect(scan.files.count == 1 && scan.needsRepair.isEmpty && scan.files[0].fragmentCount == 6)
        _ = try IndexScanner.repair(mp4: result.mp4, sidecar: result.sidecar, camera: Self.camera)
        #expect(try Data(contentsOf: result.mp4) == before && (try Data(contentsOf: result.sidecar)) == result.index.encoded(), "idempotent")
    }

    /// Where each fragment starts and ends in the file, and the places worth cutting at.
    static func cutPoints(_ result: ArchiveFixtureResult) -> [UInt64] {
        var points: Set<UInt64> = [UInt64(result.index.initLength) - 1, UInt64(result.index.initLength), UInt64(result.index.initLength) + 1]
        for record in result.index.fragments {
            let start = record.offset, end = record.offset + UInt64(record.length)
            for delta: UInt64 in [0, 1, 3, 4, 7, 8, 9, 31, 32, 33, 40, 41, 100] { points.insert(start + delta) }
            for delta: UInt64 in [1, 2, 8, 9, 100, 1000] { points.insert(end - delta) }
            points.insert(start + UInt64(record.headerLength) - 1)
            points.insert(start + UInt64(record.headerLength))
            points.insert(start + UInt64(record.headerLength) + 1)
            points.insert(end)
        }
        return points.sorted()
    }

    @Test func aFileCutAnywhereKeepsEveryWholeFragmentAndLosesOnlyTheTail() throws {
        let (directory, result) = try Self.fixture()
        defer { directory.remove() }
        let whole = try Data(contentsOf: result.mp4)
        let ends = result.index.fragments.map { $0.offset + UInt64($0.length) }
        var checked = 0
        for cut in Self.cutPoints(result) where cut <= UInt64(whole.count) {
            let torn = directory.file("torn.mp4")
            try whole.prefix(Int(cut)).write(to: torn)
            let outcome = try IndexScanner.scan(mp4: torn, camera: Self.camera)
            let wholeFragments = ends.filter { $0 <= cut }.count
            if cut < UInt64(result.index.initLength) {
                guard case .unusable = outcome else { Issue.record("cut at \(cut) inside the init segment: \(outcome)"); continue }
            } else if wholeFragments == 0 {
                #expect(outcome == .empty, "cut at \(cut): no whole fragment")
            } else {
                let found = try #require(Self.indexed(outcome), "cut at \(cut)")
                #expect(found.index.fragments == Array(result.index.fragments.prefix(wholeFragments)), "cut at \(cut)")
                #expect(found.wholeSize == ends[wholeFragments - 1] && found.fileSize == cut && found.index.mp4Size == found.wholeSize)
                // Repair cuts the file to that size and the sidecar then matches it.
                let repaired = try IndexScanner.repair(mp4: torn, sidecar: directory.file("torn.cbidx"), camera: Self.camera)
                #expect(Self.indexed(repaired)?.index == found.index)
                #expect(try Data(contentsOf: torn).count == Int(found.wholeSize))
                #expect(throws: Never.self) { _ = try CBIndexFile.decode(try Data(contentsOf: directory.file("torn.cbidx")), mp4Size: found.wholeSize) }
                try? FileManager.default.removeItem(at: directory.file("torn.cbidx"))
            }
            checked += 1
        }
        #expect(checked > 100, "\(checked) cut points")
    }

    @Test func aFileThatIsNotOursIsUnusableWhateverItHolds() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        func outcome(_ data: Data) throws -> IndexScanOutcome {
            try data.write(to: directory.file("x.mp4"))
            return try IndexScanner.scan(mp4: directory.file("x.mp4"), camera: Self.camera)
        }
        for data in [Data(), Data("hello".utf8), Data(repeating: 0, count: 100), Data(count: 7), Data("ftypisom".utf8)] {
            guard case .unusable = try outcome(data) else { Issue.record("expected unusable for \(data.count) bytes"); continue }
        }
        // Fragments without a producer reference time carry no wall clock: the file cannot be placed in time.
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: ArchiveFixtureWriter.format, audio: nil, videoTimescale: 90_000, writeProducerReferenceTime: false))
        let frame = EncodedVideoFrame(format: ArchiveFixtureWriter.format, nalUnits: [Data([0x65] + Array(repeating: 1, count: 100))], isKeyframe: true,
                                      pts: .init(value: 0, timescale: 90_000), wallClock: Date())
        let fragment = try muxer.fragment(video: [frame], audio: [], nextDecodeTime: nil)
        guard case .unusable(let reason) = try outcome(muxer.initializationSegment() + fragment) else { Issue.record("no prft must be unusable"); return }
        #expect(reason.contains("producer reference time"))
        // An init segment alone is a file that never got to write a fragment.
        #expect(try outcome(muxer.initializationSegment()) == .empty)
    }

    @Test func damageInTheMiddleOfAFileIsKeptAndIndexedUpToThereButATornTailIsCut() throws {
        let (directory, result) = try Self.fixture()
        defer { directory.remove() }
        let record = result.index.fragments[3]
        var bytes = try Data(contentsOf: result.mp4)
        bytes.replaceSubrange(Int(record.offset) + 4..<Int(record.offset) + 8, with: Data("junk".utf8))   // fragment 3's prft is not a prft
        try bytes.write(to: result.mp4)
        // Little after it: it could be a torn tail, so it is cut (the three whole fragments are kept).
        let short = try #require(Self.indexed(try IndexScanner.scan(mp4: result.mp4, camera: Self.camera)))
        #expect(short.index.fragments.count == 3 && short.wholeSize == record.offset)
        // A lot after it (more than a crash can leave): damage in the middle. The file is kept whole and the index lists what comes before.
        let handle = try FileHandle(forWritingTo: result.mp4)
        try handle.truncate(atOffset: UInt64(bytes.count) + IndexScanner.maximumTornTail + 1)
        try handle.close()
        let outcome = try IndexScanner.repair(mp4: result.mp4, sidecar: result.sidecar, camera: Self.camera)
        let kept = try #require(Self.indexed(outcome))
        #expect(kept.index.fragments.count == 3 && kept.wholeSize == kept.fileSize && kept.index.mp4Size == kept.fileSize)
        #expect(try FileManager.default.attributesOfItem(atPath: result.mp4.path(percentEncoded: false))[.size] as? UInt64 == kept.fileSize, "nothing was cut")
        let scan = CatalogLoader.scan(root: directory.url)
        #expect(scan.files.count == 1 && scan.files[0].fragmentCount == 3 && scan.needsRepair.isEmpty, "and the loader trusts it")
    }

    @Test func randomBytesAndRandomDamageNeverTrapAndEveryIndexIsTrusted() throws {
        let (directory, result) = try Self.fixture(fragments: [ArchiveFixtureFragment(), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(), ArchiveFixtureFragment(frames: 5)])
        defer { directory.remove() }
        let whole = try Data(contentsOf: result.mp4)
        var generator = ArchiveStoreGenerator(seed: 0xF00D)
        var indexed = 0, unusable = 0, empty = 0
        for round in 0..<400 {
            var bytes = whole
            switch round % 4 {
            case 0:   // flip a few bits anywhere
                for _ in 0..<Int.random(in: 1...4, using: &generator) { bytes[Int.random(in: 0..<bytes.count, using: &generator)] ^= UInt8(1 << Int.random(in: 0..<8, using: &generator)) }
            case 1:   // overwrite a run with noise
                let start = Int.random(in: 0..<bytes.count - 16, using: &generator)
                for offset in start..<start + 16 { bytes[offset] = UInt8.random(in: 0...255, using: &generator) }
            case 2:   // damage the headers of the boxes: sizes and types
                let record = result.index.fragments[Int.random(in: 0..<result.index.fragments.count, using: &generator)]
                let position = Int(record.offset) + [0, 1, 2, 3, 4, 5, 6, 7, 32, 33, 34, 35, 36, 37, 38, 39][Int.random(in: 0..<16, using: &generator)]
                bytes[position] = UInt8.random(in: 0...255, using: &generator)
            default:  // pure noise
                bytes = Data((0..<Int.random(in: 0...300, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            }
            try bytes.write(to: directory.file("fuzz.mp4"))
            switch try IndexScanner.scan(mp4: directory.file("fuzz.mp4"), camera: Self.camera) {
            case .indexed(let index, let wholeSize, let fileSize):
                indexed += 1
                #expect(wholeSize <= fileSize && fileSize == UInt64(bytes.count))
                #expect(throws: Never.self) { _ = try CBIndexFile.decode(index.encoded(), mp4Size: wholeSize) }
            case .empty: empty += 1
            case .unusable: unusable += 1
            }
        }
        #expect(indexed > 0 && unusable > 0 && empty >= 0, "\(indexed) indexed, \(empty) empty, \(unusable) unusable")
    }
}
