import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// How long a store test waits for something that happens in the background. Correctness never depends on speed, so this is generous: the
/// tests also run on loaded machines and in a debug build.
let archiveStorePatience: Duration = .seconds(30)

/// One fragment of a fixture file: 20 frames a second, so 50 frames are 2.5 s (225,000 ticks at 90 kHz).
struct ArchiveFixtureFragment: Sendable {
    var frames = 50
    /// The first frame is a keyframe; false makes a continuation fragment (the middle of a long group of pictures).
    var startsOnKey = true
    /// Bytes of the one NAL unit of a keyframe / a delta frame (the sample is 4 bytes longer: the length prefix).
    var keyBytes = 6_000
    var deltaBytes = 400
}

/// An mp4 + `.cbidx` pair for a test, written from the contracts' description of the format, without the recorder (task T01): the video is
/// built by the real `FMP4Muxer`, the index records are computed here from what was fed to it, and the rollups by the brute-force definition
/// (every fragment against every minute), so the store's code is checked against numbers it did not compute.
struct ArchiveFixtureFile: Sendable {
    var camera: UUID
    var cameraDirectory: String
    var date = "2026-10-10"
    var baseName = "13-00-00"
    /// The file's anchor, Unix epoch milliseconds.
    var startMs: Int64 = 1_760_101_200_000
    var fragments: [ArchiveFixtureFragment] = Array(repeating: ArchiveFixtureFragment(), count: 6)
    var hasAudio = false
    var writesIndex = true

    var segment: String { ArchiveLayout.segment(cameraDirectory: cameraDirectory, dateDirectory: date, baseName: baseName) }
    var key: String { ArchiveIdentity.fileKey(forSegment: segment) }
}

struct ArchiveFixtureResult: Sendable {
    var file: ArchiveFixtureFile
    var mp4: URL
    var sidecar: URL
    var index: CBIndexFile
    var initData: Data
    /// The bytes of each fragment as the muxer wrote them (prft + moof + mdat).
    var fragments: [Data]
}

enum ArchiveFixtureWriter {
    static let ticksPerFrame: Int64 = 4_500
    static let audioBytes = 20

    static var format: VideoFormat {
        VideoFormat.h264(sps: Data(hex: "6764001eacb201405ff2e022000003000200000300781e2c5c90")!, pps: Data(hex: "68ebc3cb22c0")!)!
    }

    /// `{"id": ..., "name": ...}` in `<root>/<directory>/camera.json`.
    static func writeManifest(camera: UUID, directory: String, name: String = "Driveway", root: URL) throws {
        let folder = root.appending(path: directory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"id":"\#(camera.uuidString)","name":"\#(name)"}"#.utf8).write(to: folder.appending(path: "camera.json"))
    }

    @discardableResult
    static func write(_ file: ArchiveFixtureFile, root: URL) throws -> ArchiveFixtureResult {
        try writeManifest(camera: file.camera, directory: file.cameraDirectory, root: root)
        let folder = root.appending(path: "\(file.cameraDirectory)/\(file.date)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let audioFormat = AudioFormat.aacLC(sampleRate: 16_000, channels: 1)
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: file.hasAudio ? audioFormat : nil, videoTimescale: 90_000,
                                                                   writeProducerReferenceTime: true))
        let initData = muxer.initializationSegment()
        var mp4 = initData
        var records: [CBIndexFragmentRecord] = []
        var fragments: [Data] = []
        var ticks: Int64 = 0
        for (position, fragment) in file.fragments.enumerated() {
            let wall = Date(timeIntervalSince1970: Double(file.startMs + (ticks + 45) / 90) / 1_000)
            var frames: [EncodedVideoFrame] = []
            for frame in 0..<fragment.frames {
                let isKey = frame == 0 && fragment.startsOnKey
                let decode = ticks + Int64(frame) * ticksPerFrame
                frames.append(EncodedVideoFrame(format: format, nalUnits: [nal(isKey: isKey, bytes: isKey ? fragment.keyBytes : fragment.deltaBytes, seed: decode)],
                                                isKeyframe: isKey, pts: MediaTime(value: decode, timescale: 90_000), dts: nil,
                                                wallClock: frame == 0 ? wall : wall.addingTimeInterval(Double(frame) * 0.05)))
            }
            // Audio on the same clock: 1024-sample frames at 16 kHz (40,000 samples are 2.5 s).
            var audio: [EncodedAudioFrame] = []
            if file.hasAudio {
                let from = Int((ticks * 16_000 / 90_000 + 1_023) / 1_024)
                let to = Int(((ticks + Int64(fragment.frames) * ticksPerFrame) * 16_000 / 90_000 + 1_023) / 1_024)
                audio = (from..<to).map { index in
                    EncodedAudioFrame(format: audioFormat, data: Data(repeating: UInt8(truncatingIfNeeded: index), count: audioBytes),
                                      pts: MediaTime(value: Int64(index) * 1_024, timescale: 16_000), sampleCount: 1_024, wallClock: wall)
                }
            }
            let next = ticks + Int64(fragment.frames) * ticksPerFrame
            let data = try muxer.fragment(video: frames, audio: audio, nextDecodeTime: position + 1 < file.fragments.count ? MediaTime(value: next, timescale: 90_000) : nil,
                                          continuation: !fragment.startsOnKey)
            let videoBytes = fragment.frames * 4 + (fragment.startsOnKey ? fragment.keyBytes + (fragment.frames - 1) * fragment.deltaBytes : fragment.frames * fragment.deltaBytes)
            let acceptedAudio = muxer.lastFragmentStatistics.audioSamples
            records.append(CBIndexFragmentRecord(
                offset: UInt64(mp4.count), length: UInt32(data.count), wallDeltaMs: UInt32((ticks + 45) / 90), mediaStart: UInt32(ticks),
                durationTicks: UInt32(Int64(fragment.frames) * ticksPerFrame), headerLength: UInt32(data.count - videoBytes - acceptedAudio * audioBytes),
                keyLength: fragment.startsOnKey ? UInt32(4 + fragment.keyBytes) : 0,
                nonKeyBytes: UInt32((fragment.frames - (fragment.startsOnKey ? 1 : 0)) * (4 + fragment.deltaBytes)), samples: UInt16(fragment.frames),
                backToKey: fragment.startsOnKey ? 0 : (records.last.map { $0.backToKey + 1 } ?? 1)))
            mp4.append(data)
            fragments.append(data)
            ticks = next
        }
        // The end of the last fragment: its start plus its duration, each rounded to the millisecond (T00 B.8).
        let endMs = file.startMs + (records.last.map { Int64($0.wallDeltaMs) + (Int64($0.durationTicks) + 45) / 90 } ?? 0)
        let index = CBIndexFile(flags: file.hasAudio ? 1 : 0, camera: file.camera, startWallMs: file.startMs, endWallMs: endMs, mp4Size: UInt64(mp4.count),
                                initLength: UInt32(initData.count), rollups: bruteForceRollups(records), fragments: records)
        let mp4URL = folder.appending(path: file.baseName + ".mp4")
        let sidecarURL = folder.appending(path: file.baseName + ".cbidx")
        try mp4.write(to: mp4URL)
        if file.writesIndex { try index.encoded().write(to: sidecarURL) }
        return ArchiveFixtureResult(file: file, mp4: mp4URL, sidecar: sidecarURL, index: index, initData: initData, fragments: fragments)
    }

    /// Per-minute rollups by the definition in the contracts (B.8), computed minute by minute against every fragment. A fragment covers
    /// `[wallDeltaMs, wallDeltaMs + max(1, round(durationTicks / 90)))`; a minute gets the fragment's non-key bytes in proportion to the overlap,
    /// the fragment's non-key bytes per second if that is the highest, and the overlap as `coveredMs`. The sums are `Double`, in fragment order
    /// and rounded once at the end, as the recorder's do, so the numbers agree to the byte.
    static func bruteForceRollups(_ records: [CBIndexFragmentRecord]) -> [CBIndexRollup] {
        guard let last = records.last else { return [] }
        let end = Int64(last.wallDeltaMs) + (Int64(last.durationTicks) + 45) / 90
        let count = min(CBIndexFormat.maximumRollups, Int((end + 59_999) / 60_000))
        return (0..<count).map { minute in
            let from = Int64(minute) * 60_000, to = from + 60_000
            var nonKey = 0.0, peak = 0.0, covered: Int64 = 0
            for record in records {
                let start = Int64(record.wallDeltaMs)
                let finish = start + max(1, (Int64(record.durationTicks) + 45) / 90)
                let overlap = min(finish, to) - max(start, from)
                guard overlap > 0 else { continue }
                nonKey += Double(record.nonKeyBytes) * Double(overlap) / Double(finish - start)
                peak = max(peak, Double(record.nonKeyBytes) / (Double(finish - start) / 1_000))
                covered += overlap
            }
            return CBIndexRollup(nonKeyBytes: UInt32(clamping: Int64(nonKey.rounded())), peakRate: UInt32(clamping: Int64(peak.rounded())),
                                 coveredMs: UInt16(clamping: min(covered, 60_000)))
        }
    }

    private static func nal(isKey: Bool, bytes: Int, seed: Int64) -> Data {
        var data = Data([isKey ? 0x65 : 0x41])
        for offset in 1..<max(2, bytes) { data.append(UInt8(truncatingIfNeeded: Int(truncatingIfNeeded: seed) &+ offset &* 31)) }
        return data
    }

    /// The index of a file of `fragmentCount` fragments of 2.5 s without any video behind it (for tests of the catalog's arithmetic): every
    /// fourth fragment starts a group of pictures; the mp4 it describes would be `mp4Size` bytes.
    static func sparseIndex(camera: UUID, startMs: Int64, fragmentCount: Int, fragmentLength: UInt32 = 4_096, nonKeyBytes: UInt32 = 300,
                            keyEvery: Int = 4) -> CBIndexFile {
        let initLength: UInt32 = 600
        var records: [CBIndexFragmentRecord] = []
        for index in 0..<fragmentCount {
            let offset = UInt64(initLength) + UInt64(index) * UInt64(fragmentLength)
            records.append(CBIndexFragmentRecord(offset: offset, length: fragmentLength, wallDeltaMs: UInt32(index * 2_500), mediaStart: UInt32(index * 225_000),
                                                 durationTicks: 225_000, headerLength: 150, keyLength: index % keyEvery == 0 ? 200 : 0,
                                                 nonKeyBytes: nonKeyBytes, samples: 50, backToKey: UInt16(index % keyEvery)))
        }
        let endMs = startMs + Int64(fragmentCount) * 2_500
        return CBIndexFile(camera: camera, startWallMs: startMs, endWallMs: endMs,
                           mp4Size: UInt64(initLength) + UInt64(fragmentCount) * UInt64(fragmentLength), initLength: initLength,
                           rollups: bruteForceRollups(records), fragments: records)
    }

    /// `sparseIndex` on disk: an mp4 of the right size (sparse: no disk is used) and the sidecar. For tests that need thousands of files.
    @discardableResult
    static func writeSparse(root: URL, camera: UUID, directory: String, date: String, baseName: String, startMs: Int64, fragmentCount: Int,
                            fragmentLength: UInt32 = 4_096, nonKeyBytes: UInt32 = 300, writesManifest: Bool = true) throws -> (mp4: URL, index: CBIndexFile) {
        if writesManifest { try writeManifest(camera: camera, directory: directory, root: root) }
        let folder = root.appending(path: "\(directory)/\(date)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = sparseIndex(camera: camera, startMs: startMs, fragmentCount: fragmentCount, fragmentLength: fragmentLength, nonKeyBytes: nonKeyBytes)
        let mp4 = folder.appending(path: baseName + ".mp4")
        FileManager.default.createFile(atPath: mp4.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: mp4)
        try handle.truncate(atOffset: index.mp4Size)
        try handle.close()
        try index.encoded().write(to: folder.appending(path: baseName + ".cbidx"))
        return (mp4, index)
    }
}

/// The writer is the yardstick of the other tests: its files must be what the contracts describe.
@Suite struct ArchiveFixtureWriterTests {
    @Test func theIndexIsValidAndMatchesTheBytesOfTheFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let camera = UUID()
        let result = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString), root: directory.url)
        let bytes = try Data(contentsOf: result.mp4)
        let decoded = try CBIndexFile.decode(try Data(contentsOf: result.sidecar), mp4Size: UInt64(bytes.count))
        #expect(decoded == result.index && decoded.fragments.count == 6)
        #expect(bytes.prefix(result.initData.count) == result.initData && result.initData.dropFirst(4).prefix(4) == Data("ftyp".utf8))
        for (record, fragment) in zip(decoded.fragments, result.fragments) {
            let stored = bytes.subdata(in: Int(record.offset)..<Int(record.offset) + Int(record.length))
            #expect(stored == fragment && stored.dropFirst(4).prefix(4) == Data("prft".utf8))
            // The first video byte is where the index says: the length-prefixed keyframe NAL unit (6,000 bytes).
            let first = bytes.subdata(in: Int(record.offset) + Int(record.headerLength)..<Int(record.offset) + Int(record.headerLength) + 8)
            #expect(first.prefix(4) == Data([0, 0, 0x17, 0x70]) && first[4] == 0x65)
            #expect(record.keyLength == 6_004 && record.nonKeyBytes == 49 * 404 && record.samples == 50 && record.durationTicks == 225_000)
        }
        #expect(decoded.fragments.map(\.wallDeltaMs) == [0, 2_500, 5_000, 7_500, 10_000, 12_500])
        #expect(decoded.endWallMs - decoded.startWallMs == 15_000 && decoded.rollups.count == 1 && decoded.rollups[0].coveredMs == 15_000)
    }

    @Test func continuationFragmentsAndSoundAreDescribedToo() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let camera = UUID()
        let plan = [ArchiveFixtureFragment(), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment()]
        let result = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: "Porch", fragments: plan, hasAudio: true), root: directory.url)
        #expect(result.index.hasAudio && result.index.fragments.map(\.backToKey) == [0, 1, 2, 0] && result.index.fragments.map(\.keyLength) == [6_004, 0, 0, 6_004])
        // With sound the fragment holds audio after the video; the header still ends where the video begins.
        let bytes = try Data(contentsOf: result.mp4)
        let record = result.index.fragments[1]
        #expect(bytes[Int(record.offset) + Int(record.headerLength) + 4] == 0x41, "a delta frame's NAL unit header")
        #expect(Int(record.length) > Int(record.headerLength) + 50 * 404, "audio samples follow the video in the mdat")
        #expect(throws: Never.self) { _ = try CBIndexFile.decode(result.index.encoded(), mp4Size: UInt64(bytes.count)) }
    }

    @Test func theSparseWriterMakesDecodableIndexes() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let camera = UUID()
        let (mp4, index) = try ArchiveFixtureWriter.writeSparse(root: directory.url, camera: camera, directory: "cam", date: "2026-10-10", baseName: "09-00-00",
                                                                startMs: 1_760_000_000_000, fragmentCount: 8)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: mp4.path(percentEncoded: false))[.size] as? UInt64)
        #expect(size == index.mp4Size)
        #expect(throws: Never.self) { _ = try CBIndexFile.decode(index.encoded(), mp4Size: size) }
    }

    @Test func bruteForceRollupsAgreeWithTheSharedFunction() {
        var records: [CBIndexFragmentRecord] = []
        for index in 0..<100 {
            let nonKey = UInt32(1_000 + index * 37)
            records.append(CBIndexFragmentRecord(offset: UInt64(1_000 + index * 100), length: 100, wallDeltaMs: UInt32(index * 2_500),
                                                 mediaStart: UInt32(index * 225_000), durationTicks: 225_000, headerLength: 50,
                                                 keyLength: index % 3 == 0 ? 40 : 0, nonKeyBytes: nonKey, samples: 50, backToKey: UInt16(index % 3)))
        }
        #expect(ArchiveFixtureWriter.bruteForceRollups(records) == CBIndexRollups.make(fragments: records))
        // Odd fragment lengths that cut the minutes unevenly.
        var uneven: [CBIndexFragmentRecord] = []
        for index in 0..<40 {
            let nonKey = UInt32(2_000 + index * 91)
            uneven.append(CBIndexFragmentRecord(offset: UInt64(1_000 + index * 100), length: 100, wallDeltaMs: UInt32(index * 7_919),
                                                mediaStart: UInt32(index * 712_710), durationTicks: 712_710, headerLength: 50, keyLength: 40,
                                                nonKeyBytes: nonKey, samples: 30, backToKey: 0))
        }
        #expect(ArchiveFixtureWriter.bruteForceRollups(uneven) == CBIndexRollups.make(fragments: uneven))
    }
}
