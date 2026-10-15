import FMP4
import Foundation
import Testing
@testable import BridgeEngine

/// `ClipLayout`: the tables of the file (export-clip spec 4), which need no pictures to be built.
@Suite struct ClipLayoutTests {
    typealias Fixture = PlannerFixture

    /// Tables over the standard fixture's first fragments, with the samples given.
    static func tables(_ samples: [ClipSample], chunks: [Int]? = nil) async throws -> ClipPartTables {
        let archive = PlannerFixtureArchive()
        let built = try archive.add(PlannerFixtureFile())
        let fragment = try #require(await archive.fragment(camera: Fixture.camera, id: built.id(0)))
        let counts = chunks ?? [samples.count]
        var first = 0
        var copies: [ClipCopy] = []
        for count in counts {
            let length = samples[first..<first + count].reduce(0) { $0 + Int($1.size) }
            copies.append(ClipCopy(fragment: fragment, skipBytes: 100, length: length, firstSample: first, sampleCount: count))
            first += count
        }
        return ClipPartTables(initialization: built.initData, samples: samples, copies: copies, wallStart: Fixture.at(0), width: 640, height: 360)
    }

    static func sample(_ size: UInt32 = 100, duration: UInt32 = 4_500, offset: Int32 = 0, sync: Bool = false) -> ClipSample {
        ClipSample(size: size, duration: duration, compositionOffset: offset, isSync: sync)
    }

    static func stbl(_ layout: ClipLayout) throws -> MP4Box {
        var file = layout.ftyp
        file.append(layout.moov)
        let boxes = try MP4BoxReader.parse(file)
        return try #require(boxes.first { $0.type == "moov" }?.descendant(atPath: "trak/mdia/minf/stbl"))
    }

    @Test func equalOffsetsAndAllKeyPicturesNeedNeitherCttsNorStss() async throws {
        let layout = try ClipLayout.make(try await Self.tables((0..<10).map { _ in Self.sample(sync: true) }))
        #expect(try Self.stbl(layout).children.map(\.type) == ["stsd", "stts", "stsc", "stsz", "stco"])
    }

    @Test func offsetsThatVaryMakeACttsAndANegativeOneMakesItVersionOne() async throws {
        let positive = try ClipLayout.make(try await Self.tables([Self.sample(offset: 0, sync: true), Self.sample(offset: 9_000), Self.sample(offset: 0)]))
        let box = try #require(try Self.stbl(positive).child("ctts"))
        var file = positive.ftyp; file.append(positive.moov)
        #expect(file[file.startIndex + box.payloadOffset] == 0, "version 0")
        let negative = try ClipLayout.make(try await Self.tables([Self.sample(offset: -4_500, sync: true), Self.sample(offset: 4_500)]))
        var other = negative.ftyp; other.append(negative.moov)
        let boxN = try #require(try Self.stbl(negative).child("ctts"))
        #expect(other[other.startIndex + boxN.payloadOffset] == 1, "version 1")
    }

    @Test func chunksOfTheSameCountShareOneSampleToChunkEntry() async throws {
        let samples = (0..<12).map { Self.sample(sync: $0 % 4 == 0) }
        let layout = try ClipLayout.make(try await Self.tables(samples, chunks: [4, 4, 4]))
        var file = layout.ftyp; file.append(layout.moov)
        let stsc = try #require(try Self.stbl(layout).child("stsc"))
        #expect(ClipWriterTests.u32(file, stsc.payloadOffset + 4) == 1, "one entry")
        let uneven = try ClipLayout.make(try await Self.tables(samples, chunks: [5, 4, 3]))
        var other = uneven.ftyp; other.append(uneven.moov)
        let unevenBox = try #require(try Self.stbl(uneven).child("stsc"))
        #expect(ClipWriterTests.u32(other, unevenBox.payloadOffset + 4) == 3)
    }

    @Test func aClipOfFourGibOrMoreHasA64BitMdatAndLongOffsets() async throws {
        let big = (0..<5).map { _ in Self.sample(1 << 30, sync: true) }
        let layout = try ClipLayout.make(try await Self.tables(big, chunks: [1, 1, 1, 1, 1]))
        #expect(layout.usesLongOffsets && layout.mdatHeader.count == 16 && layout.payloadBytes == 5 << 30)
        #expect(layout.totalBytes == Int64(layout.ftyp.count + layout.moov.count + 16) + (5 << 30))
        let stbl = try Self.stbl(layout)
        #expect(stbl.child("co64") != nil && stbl.child("stco") == nil)
        var file = layout.ftyp; file.append(layout.moov)
        let co64 = try #require(stbl.child("co64"))
        let first = (0..<8).reduce(0) { ($0 << 8) | Int(file[file.startIndex + co64.payloadOffset + 8 + $1]) }
        #expect(first == layout.ftyp.count + layout.moov.count + 16)
        let small = try ClipLayout.make(try await Self.tables([Self.sample(sync: true)]))
        #expect(!small.usesLongOffsets && small.mdatHeader.count == 8)
    }

    @Test func tablesThatDoNotAddUpAreDamagedAndNotWritten() async throws {
        var tables = try await Self.tables([Self.sample(sync: true), Self.sample()])
        tables.copies[0].length += 1
        #expect(throws: ClipError.damaged(at: Fixture.at(0))) { try ClipLayout.make(tables) }
        var noVideo = try await Self.tables([Self.sample(sync: true)])
        noVideo.initialization = Data()
        #expect(throws: ClipError.damaged(at: Fixture.at(0))) { try ClipLayout.make(noVideo) }
        var none = try await Self.tables([Self.sample(sync: true)])
        none.samples = []
        #expect(throws: ClipError.damaged(at: Fixture.at(0))) { try ClipLayout.make(none) }
    }

    @Test func theSizeIsTheSizeOfTheFilesPartsAndTheDurationsAreRoundedIntoTheMovieTimescale() async throws {
        let tables = try await Self.tables((0..<30).map { _ in Self.sample(sync: false) })
        let layout = try ClipLayout.make(tables)
        #expect(try ClipSizing.totalBytes(of: tables) == layout.totalBytes)
        var file = layout.ftyp; file.append(layout.moov)
        let boxes = try MP4BoxReader.parse(file)
        let mvhd = try #require(boxes.first { $0.type == "moov" }?.child("mvhd"))
        #expect(ClipWriterTests.u32(file, mvhd.payloadOffset + 16) == 1_500, "30 pictures of 50 ms in milliseconds")
        let created = Int(Fixture.at(0).timeIntervalSince1970) + 2_082_844_800
        #expect(ClipWriterTests.u32(file, mvhd.payloadOffset + 4) == created, "creation time: the clip's wall start in MP4 seconds")
    }
}
