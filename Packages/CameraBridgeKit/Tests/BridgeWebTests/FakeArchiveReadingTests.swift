import BridgeEngine
import FMP4
import Foundation
import Testing
import TestSupport

/// The fake archive the NVR route tests stand on: files made by the recorder's muxer, and the lookups, boundaries and switches of
/// `ArchiveReading` (T00-contracts.md B.2). If the fake were wrong the route tests would prove nothing, so it has tests of its own.
@Suite(.timeLimit(.minutes(1))) struct NVRFakeArchiveTests {
    private let camera = UUID()
    private func file(_ name: String, startMs: Double = 0, fragments: Int = 4, gop: Int = 2, audio: Bool = false) throws -> ArchiveFixtureFile {
        try ArchiveFixture.file(camera: camera, segment: "\(camera.uuidString)/2026-09-14/\(name)", startMs: 1_789_387_200_000 + startMs, fragments: fragments, gopFragments: gop, audio: audio)
    }

    private func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: (1_789_387_200_000 + ms) / 1000) }

    @Test func aFixtureFileIsWhatTheRecordersMuxerWritesAndTheStoreWouldDescribe() throws {
        let file = try file("13-24-05", fragments: 4, gop: 2)
        let initBoxes = try MP4BoxReader.parse(file.initData)
        #expect(initBoxes.map(\.type) == ["ftyp", "moov"])
        for (index, stored) in file.stored.enumerated() {
            let boxes = try MP4BoxReader.parse(stored)
            #expect(boxes.map(\.type) == ["prft", "moof", "mdat"], "fragment \(index)")
            #expect(boxes.first?.size == 32)
            #expect(file.fragments[index].byteLength == stored.count && file.fragments[index].index == index)
        }
        #expect(file.fragments.map(\.hasKeyframe) == [true, false, true, false])
        #expect(file.fragments.map(\.backToKey) == [0, 1, 0, 1])
        #expect(file.fragments.map(\.mediaStart) == [0, 90_000, 180_000, 270_000])
        #expect(file.fragments.map(\.duration) == [1, 1, 1, 1])
        #expect(file.fragments.map { $0.start.timeIntervalSince(date(0)) } == [0, 1, 2, 3])
        #expect(file.fragments[2].gopStart == file.fragments[2].start && file.fragments[3].gopStart == file.fragments[2].start)
        #expect(file.fragments.allSatisfy { $0.fileKey == file.fileKey && $0.fileKey.count == 12 && $0.id == "\(file.fileKey).\($0.index)" })
        #expect(file.videoBytes.allSatisfy { $0 > 0 })
    }

    @Test func theDescribedMediaStartIsTheTfdtInTheBytes() throws {
        for audio in [false, true] {
            let file = try ArchiveFixture.file(camera: camera, segment: "\(camera.uuidString)/2026-09-14/13-24-05", startMs: 1_789_387_200_000, fragments: 6, framesPerFragment: 15,
                                               frameTicks: 3_003, gopFragments: 3, audio: audio)
            for (index, stored) in file.stored.enumerated() {
                #expect(try baseMediaDecodeTime(in: stored) == file.fragments[index].mediaStart, "fragment \(index), sound \(audio)")
            }
            #expect(file.fragments[0].mediaStart == 0, "a fresh muxer starts every file at 0")
        }
    }

    @Test func aFileWithSoundHasASecondTrackFragmentOfItsOwn() throws {
        let file = try file("13-24-05", fragments: 2, gop: 1, audio: true)
        let moof = try #require(MP4BoxReader.parse(file.stored[0]).first { $0.type == "moof" })
        #expect(moof.children(ofType: "traf").count == 2)
        #expect(try MP4BoxReader.parse(file.initData).first { $0.type == "moov" }?.children(ofType: "trak").count == 2)
        let plain = try self.file("13-24-06", fragments: 2, gop: 1)
        #expect(file.stored[0].count > plain.stored[0].count)
    }

    @Test func aTimeBelongsToTheFragmentThatStartsAtOrBeforeItAndEndsAfterIt() async throws {
        let archive = FakeArchiveReading([try file("13-24-05", fragments: 4)])
        let first = await archive.fragment(camera: camera, containing: date(0))
        #expect(first?.index == 0)
        #expect(await archive.fragment(camera: camera, containing: date(999.9))?.index == 0)
        #expect(await archive.fragment(camera: camera, containing: date(1_000))?.index == 1, "the end of one is the start of the next")
        #expect(await archive.fragment(camera: camera, containing: date(3_999))?.index == 3)
        let atTheEnd = await archive.fragment(camera: camera, containing: date(4_000)), beforeTheStart = await archive.fragment(camera: camera, containing: date(-1))
        #expect(atTheEnd == nil && beforeTheStart == nil)
        #expect(await archive.fragment(camera: UUID(), containing: date(0)) == nil)
    }

    @Test func theNextFragmentIsTheFirstThatStartsStrictlyLaterAcrossFiles() async throws {
        let archive = FakeArchiveReading([try file("13-24-05", fragments: 2), try file("13-24-20", startMs: 15_000, fragments: 2)])
        #expect(await archive.fragment(camera: camera, startingAfter: date(-5))?.index == 0)
        #expect(await archive.fragment(camera: camera, startingAfter: date(0))?.index == 1, "strictly later")
        let across = await archive.fragment(camera: camera, startingAfter: date(1_000))
        #expect(across?.segment.hasSuffix("13-24-20") == true && across?.index == 0, "across the gap and into the next file")
        #expect(await archive.fragment(camera: camera, startingAfter: date(16_000)) == nil)
    }

    @Test func aLaterStartedFileWinsAnOverlap() async throws {
        let archive = FakeArchiveReading([try file("13-24-05", fragments: 3), try file("13-24-06", startMs: 1_500, fragments: 3)])
        #expect(await archive.fragment(camera: camera, containing: date(1_200))?.segment.hasSuffix("13-24-05") == true)
        #expect(await archive.fragment(camera: camera, containing: date(1_700))?.segment.hasSuffix("13-24-06") == true, "the file that started later")
    }

    @Test func anIdFindsItsFragmentUntilRetentionRemovesIt() async throws {
        let one = try file("13-24-05", fragments: 3)
        let archive = FakeArchiveReading([one])
        let id = one.fragments[2].id
        #expect(await archive.fragment(camera: camera, id: id) == one.fragments[2])
        let unknown = await archive.fragment(camera: camera, id: "aaaaaaaaaaaa.0"), otherCamera = await archive.fragment(camera: UUID(), id: id)
        #expect(unknown == nil && otherCamera == nil)
        archive.remove(id)
        let byID = await archive.fragment(camera: camera, id: id), byTime = await archive.fragment(camera: camera, containing: date(2_500))
        #expect(byID == nil && byTime == nil)
        await #expect(throws: ArchiveError.fileGone) { _ = try await archive.read(one.fragments[2], .fragment) }
    }

    @Test func readsReturnTheStoredBytesAndTheSwitchesBehave() async throws {
        let one = try file("13-24-05", fragments: 3)
        let archive = FakeArchiveReading([one])
        #expect(try await archive.read(one.fragments[1], .fragment) == one.stored[1])
        #expect(try await archive.read(one.fragments[1], .initialization) == one.initData)
        await #expect(throws: ArchiveError.noKeyframe) { _ = try await archive.read(one.fragments[1], .keyframe) }
        archive.fail(one.fragments[0].id, with: .timedOut)
        await #expect(throws: ArchiveError.timedOut) { _ = try await archive.read(one.fragments[0], .fragment) }
        archive.corrupt(one.fragments[2].id)
        #expect(try await archive.read(one.fragments[2], .fragment).count == one.stored[2].count / 2)
        #expect(archive.reads.count == 5 && archive.mostReadsInFlight == 1 && archive.readsInFlight == 0)
        #expect(archive.isReady)
        archive.setReady(false)
        #expect(!archive.isReady)
    }

    @Test func theHeaderOfAFragmentIsEverythingBeforeItsVideo() async throws {
        for audio in [false, true] {
            let one = try file("13-24-05", fragments: 3, gop: 2, audio: audio)
            let archive = FakeArchiveReading([one])
            for (index, stored) in one.stored.enumerated() {
                let header = try await archive.read(one.fragments[index], .header)
                #expect(header == stored.prefix(header.count) && header.count < stored.count, "fragment \(index), sound \(audio)")
                #expect(header.dropFirst(4).prefix(4) == Data("prft".utf8) && header.suffix(4) == Data("mdat".utf8), "prft, moof and the mdat header")
                #expect(stored[header.count + 4] == (one.fragments[index].hasKeyframe ? 0x65 : 0x41), "the video starts right after it")
                if !audio { #expect(header.count == stored.count - one.videoBytes[index], "without sound everything after the header is video") }
            }
            let whole = try await archive.read(one.fragments[0], .header)
            archive.corrupt(one.fragments[0].id)
            #expect(try await archive.read(one.fragments[0], .header).count == whole.count / 2, "a damaged file answers half")
            archive.remove(one.fragments[1].id)
            await #expect(throws: ArchiveError.fileGone) { _ = try await archive.read(one.fragments[1], .header) }
        }
    }

    @Test func aGateHoldsReadsInFlightWithoutBlockingAThread() async throws {
        let one = try file("13-24-05", fragments: 3)
        let archive = FakeArchiveReading([one])
        let gate = AsyncGate()
        archive.setReadGate(gate)
        let readers = (0..<3).map { index in Task { try await archive.read(one.fragments[index], .fragment) } }
        #expect(await eventually { archive.readsInFlight == 3 && gate.waiting == 3 })
        gate.open()
        for (index, reader) in readers.enumerated() { #expect(try await reader.value == one.stored[index]) }
        #expect(archive.mostReadsInFlight == 3 && archive.readsInFlight == 0)
    }

    @Test func theExtentAndTheActivityCoverTheRecordedTime() async throws {
        let archive = FakeArchiveReading([try file("13-24-05", fragments: 4)])
        #expect(archive.extent(camera: UUID()) == nil)
        archive.setTypicalGOP(2)
        #expect(archive.extent(camera: camera) == ArchiveExtent(oldest: date(0), newest: date(4_000), typicalGOP: 2))
        let activity = await archive.activity(camera: camera, range: date(0)..<date(8_000), binCount: 4)
        #expect(activity.bins.map(\.coverage) == [1, 1, 0, 0] && activity.binDuration == 2 && activity.isComplete)
        let before = archive.catalogVersion
        archive.bumpCatalogVersion()
        #expect(archive.catalogVersion == before + 1)
    }
}
