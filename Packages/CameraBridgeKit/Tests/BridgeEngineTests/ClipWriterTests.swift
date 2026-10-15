import FMP4
import Foundation
import Synchronization
import Testing
@testable import BridgeEngine

/// A sink that keeps what it is given, and may refuse or cancel.
final class CollectingSink: ClipSink, Sendable {
    private let state = Mutex<(data: Data, writes: Int, failAfter: Int?, cancelAfter: Int?)>((Data(), 0, nil, nil))
    struct Refused: Error {}

    init(failAfter: Int? = nil, cancelAfter: Int? = nil) {
        state.withLock { $0.failAfter = failAfter; $0.cancelAfter = cancelAfter }
    }

    var data: Data { state.withLock { $0.data } }
    var writes: Int { state.withLock { $0.writes } }

    func write(_ bytes: Data) async throws {
        let (fail, cancel) = state.withLock { state -> (Bool, Bool) in
            state.writes += 1
            if let limit = state.failAfter, state.writes > limit { return (true, false) }
            state.data.append(bytes)
            return (false, state.cancelAfter.map { state.writes >= $0 } ?? false)
        }
        if fail { throw Refused() }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

/// The file `ClipWriter` writes (export-clip spec 4): sizes, order, tables and the pictures themselves.
@Suite struct ClipWriterTests {
    typealias Fixture = PlannerFixture

    static func planned(_ from: Int64, _ to: Int64, file: PlannerFixtureFile = PlannerFixtureFile()) async throws
        -> (ClipPlan, PlannerFixtureArchive, PlannerFixtureArchive.Built) {
        let archive = PlannerFixtureArchive()
        let built = try archive.add(file)
        let plan = try await Fixture.planner(archive, sizing: ClipSizing.totalBytes(of:)).plan(Fixture.request(from, to))
        return (plan, archive, built)
    }

    static func u32(_ data: Data, _ at: Int) -> Int {
        (0..<4).reduce(0) { ($0 << 8) | Int(data[data.startIndex + at + $1]) }
    }

    @Test func aClipWithSoundHasASoundTrackWhoseChunksAreTheRecordedSound() async throws {
        let (plan, archive, _) = try await Self.planned(500, 12_000, file: PlannerFixtureFile(audio: true))
        let tables = try #require(plan.tables.first)
        let sound = try #require(tables.sound)
        let sink = CollectingSink()
        try await ClipWriter(archive: archive).write(plan, part: 1, to: sink) { _ in }
        let file = sink.data
        #expect(Int64(file.count) == plan.parts[0].byteCount)
        let boxes = try MP4BoxReader.parse(file)
        #expect(boxes.map(\.type) == ["ftyp", "moov", "mdat"])
        let moov = try #require(boxes.first { $0.type == "moov" })
        let traks = moov.children(ofType: "trak")
        #expect(traks.count == 2)
        let soundTrak = try #require(traks.last)
        let stbl = try #require(soundTrak.descendant(atPath: "mdia/minf/stbl"))
        #expect(stbl.children.map(\.type) == ["stsd", "stts", "stsc", "stsz", "stco"])
        #expect(soundTrak.descendant(atPath: "mdia/minf/smhd") != nil)
        // Every sound chunk is, byte for byte, the bytes the plan says to copy from its fragment.
        let stco = try #require(stbl.child("stco"))
        let count = Self.u32(file, stco.payloadOffset + 4)
        #expect(count == sound.copies.count)
        let mdat = try #require(boxes.last)
        for (index, copy) in sound.copies.enumerated() {
            let offset = Self.u32(file, stco.payloadOffset + 8 + index * 4)
            #expect(offset >= mdat.payloadOffset && offset + copy.length <= mdat.offset + mdat.size)
            let stored = try await archive.read(copy.fragment, .fragment)
            #expect(file.subdata(in: offset..<offset + copy.length) == stored.subdata(in: stored.startIndex + copy.skipBytes..<stored.startIndex + copy.skipBytes + copy.length))
        }
    }

    @Test func theFileHasTheSizeThePlanSaidAndTheBoxesInOrder() async throws {
        let (plan, archive, _) = try await Self.planned(500, 12_000)
        let sink = CollectingSink()
        try await ClipWriter(archive: archive).write(plan, part: 1, to: sink) { _ in }
        let file = sink.data
        #expect(Int64(file.count) == plan.parts[0].byteCount && plan.byteCount == plan.parts[0].byteCount)
        let boxes = try MP4BoxReader.parse(file)
        #expect(boxes.map(\.type) == ["ftyp", "moov", "mdat"])
        let moov = try #require(boxes.first { $0.type == "moov" })
        #expect(moov.children.map(\.type) == ["mvhd", "trak"], "no mvex, no udta")
        #expect(moov.descendant(atPath: "trak/edts") == nil, "no edit list: the clip starts on a key picture")
        let stbl = try #require(moov.descendant(atPath: "trak/mdia/minf/stbl"))
        #expect(stbl.children.map(\.type) == ["stsd", "stts", "stss", "stsc", "stsz", "stco"], "equal offsets: no ctts; not all key: stss")
    }

    @Test func theTablesDescribeThePicturesAndTheChunksStartWhereTheyAre() async throws {
        let (plan, archive, built) = try await Self.planned(500, 12_000)
        let sink = CollectingSink()
        try await ClipWriter(archive: archive).write(plan, part: 1, to: sink) { _ in }
        let file = sink.data
        let boxes = try MP4BoxReader.parse(file)
        let mdat = try #require(boxes.first { $0.type == "mdat" })
        let stbl = try #require(boxes.first { $0.type == "moov" }?.descendant(atPath: "trak/mdia/minf/stbl"))
        func payload(_ type: String) throws -> Int { try #require(stbl.child(type)).payloadOffset }
        let samples = Self.u32(file, try payload("stsz") + 8)
        #expect(samples == plan.parts[0].sampleCount && plan.tables[0].samples.count == samples)
        let chunkCount = Self.u32(file, try payload("stco") + 4)
        #expect(chunkCount == plan.tables[0].copies.count)
        // The first chunk starts right after the mdat header, and its first byte is the length prefix of the first picture.
        let first = Self.u32(file, try payload("stco") + 8)
        #expect(first == mdat.payloadOffset, "the pictures begin where the mdat's payload does")
        let copy = plan.tables[0].copies[0]
        let expected = built.fragments[copy.fragment.index].dropFirst(copy.skipBytes).prefix(copy.length)
        #expect(file.subdata(in: first ..< first + copy.length) == Data(expected), "copied untouched")
        #expect(file[first + 4] == 0x65, "a key picture's NAL header")
        // The sizes in stsz add up to the payload.
        var total = 0
        for index in 0..<samples { total += Self.u32(file, try payload("stsz") + 12 + 4 * index) }
        #expect(total == mdat.payloadSize)
        // Durations of 50 ms at 90 kHz in one run.
        let stts = try payload("stts")
        #expect(Self.u32(file, stts + 4) == 1 && Self.u32(file, stts + 8) == samples && Self.u32(file, stts + 12) == 4_500)
    }

    @Test func theWholePayloadIsTheCopiedFragmentsInOrder() async throws {
        let (plan, archive, built) = try await Self.planned(0, 15_000)
        let sink = CollectingSink()
        try await ClipWriter(archive: archive).write(plan, part: 1, to: sink) { _ in }
        let layout = try ClipLayout.make(plan.tables[0])
        var expected = Data()
        for copy in plan.tables[0].copies { expected.append(built.fragments[copy.fragment.index].dropFirst(copy.skipBytes).prefix(copy.length)) }
        #expect(sink.data.suffix(from: sink.data.startIndex + layout.ftyp.count + layout.moov.count + layout.mdatHeader.count) == expected)
        #expect(layout.totalBytes == Int64(sink.data.count))
    }

    @Test func progressCountsUpToTheSizeOfTheFile() async throws {
        let (plan, archive, _) = try await Self.planned(0, 15_000)
        let seen = Mutex<[Int64]>([])
        try await ClipWriter(archive: archive).write(plan, part: 1, to: CollectingSink()) { bytes in seen.withLock { $0.append(bytes) } }
        let values = seen.withLock { $0 }
        #expect(values == values.sorted() && values.last == plan.parts[0].byteCount && values.count >= 4 + plan.tables[0].copies.count - 1)
    }

    @Test func aSinkThatRefusesEndsTheWriteWithItsReason() async throws {
        let (plan, archive, _) = try await Self.planned(0, 15_000)
        await #expect(throws: ClipError.sink("Refused()")) { try await ClipWriter(archive: archive).write(plan, part: 1, to: CollectingSink(failAfter: 4)) { _ in } }
    }

    @Test func aCancelBetweenFragmentsStopsTheWrite() async throws {
        let (plan, archive, _) = try await Self.planned(0, 15_000)
        let sink = CollectingSink(cancelAfter: 5)
        let task = Task { try await ClipWriter(archive: archive).write(plan, part: 1, to: sink) { _ in } }
        await #expect(throws: ClipError.cancelled) { try await task.value }
        #expect(sink.writes == 5, "nothing is written after the cancel")
    }

    @Test func recordingsThatAreGoneAtTheFirstReadAreTheDriveAndLaterAreADamagedClip() async throws {
        let (plan, archive, _) = try await Self.planned(0, 15_000)
        archive.setHook { number, _, part in if part == .fragment { throw ArchiveError.fileGone } }
        await #expect(throws: ClipError.driveGone) { try await ClipWriter(archive: archive).write(plan, part: 1, to: CollectingSink()) { _ in } }
        let reads = Mutex(0)
        archive.setHook { _, fragment, part in
            if part == .fragment, reads.withLock({ $0 += 1; return $0 }) == 3 { throw ArchiveError.fileGone }
        }
        let start = plan.tables[0].copies[2].fragment.start
        await #expect(throws: ClipError.damaged(at: start)) { try await ClipWriter(archive: archive).write(plan, part: 1, to: CollectingSink()) { _ in } }
    }

    @Test func aFragmentShorterThanTheIndexSaidIsDamagedAndNothingFromItIsWritten() async throws {
        let (plan, archive, _) = try await Self.planned(0, 15_000)
        let damaged = plan.tables[0].copies[1].fragment
        archive.setTamper { fragment, part, data in part == .fragment && fragment.id == damaged.id ? data.prefix(data.count / 2) : data }
        let sink = CollectingSink()
        await #expect(throws: ClipError.damaged(at: damaged.start)) { try await ClipWriter(archive: archive).write(plan, part: 1, to: sink) { _ in } }
    }

    @Test func aPartThatIsNotInThePlanIsNotReady() async throws {
        let (plan, archive, _) = try await Self.planned(0, 15_000)
        await #expect(throws: ClipError.notReady) { try await ClipWriter(archive: archive).write(plan, part: 2, to: CollectingSink()) { _ in } }
        let bare = ClipPlan(request: plan.request, parts: plan.parts, gaps: [], soundOmitted: false)
        await #expect(throws: ClipError.notReady) { try await ClipWriter(archive: archive).write(bare, part: 1, to: CollectingSink()) { _ in } }
    }
}
