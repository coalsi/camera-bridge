import FMP4
import Foundation
import Testing
@testable import BridgeEngine

/// `ArchiveReadPart.header` on the real store (export clip, design 3.2): the bytes of a fragment from its `prft` to its first video byte, which a clip is
/// planned from, read through the same queue, checks and cache as every other part.
@Suite struct ArchiveStoreHeaderReadTests {
    static let camera = ArchiveStoreHarness.camera
    static let start: Int64 = 1_760_101_200_000

    /// A store started on one real file of six fragments (the 3rd and 4th are continuation fragments), with sound or without.
    static func started(sound: Bool = false) async throws -> (ArchiveStoreHarness, ArchiveFixtureResult) {
        var result: ArchiveFixtureResult?
        let plan = [ArchiveFixtureFragment(), ArchiveFixtureFragment(), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(startsOnKey: false), ArchiveFixtureFragment(), ArchiveFixtureFragment()]
        let harness = try ArchiveStoreHarness { root in
            result = try ArchiveFixtureWriter.write(ArchiveFixtureFile(camera: camera, cameraDirectory: camera.uuidString, fragments: plan, hasAudio: sound), root: root)
        }
        await harness.start()
        return (harness, try #require(result))
    }

    @Test func theHeaderIsTheFragmentUpToItsFirstVideoByte() async throws {
        for sound in [false, true] {
            let (harness, result) = try await Self.started(sound: sound)
            for (position, record) in result.index.fragments.enumerated() {
                let label = "fragment \(position), sound \(sound)"
                let fragment = try #require(await harness.store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + Int64(position) * 2_500 + 1)))
                let header = try await harness.store.read(fragment, .header)
                let whole = result.fragments[position]
                #expect(header == whole.prefix(Int(record.headerLength)), "\(label): the first headerLength bytes of the fragment")
                #expect(header.count == fragment.headerLength && header.count < fragment.byteLength, "\(label): shorter than the fragment")
                // It begins with the producer reference time box, then the moof, and ends with the 8-byte header of the mdat that holds the rest of the fragment.
                #expect(header.dropFirst(4).prefix(4) == Data("prft".utf8), "\(label)")
                let bytes = [UInt8](header)
                #expect(try MP4BoxReader.parse(Data(bytes.dropLast(8))).map(\.type) == ["prft", "moof"], "\(label): prft and moof")
                let mdatSize = bytes.suffix(8).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                #expect(String(decoding: bytes.suffix(4), as: UTF8.self) == "mdat" && mdatSize == whole.count - (bytes.count - 8), "\(label): the mdat header")
                // The first video byte follows at once: the length prefix of the first NAL unit, then its header (0x65 for an IDR picture, 0x41 for the rest).
                #expect(whole[whole.startIndex + header.count + 4] == (record.keyLength > 0 ? 0x65 : 0x41), "\(label): the video begins where the header ends")
            }
        }
    }

    @Test func aHeaderIsCachedLikeAnyOtherRead() async throws {
        let (harness, result) = try await Self.started()
        let store = harness.store
        let fragment = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start)))
        let header = try await store.read(fragment, .header)
        var blocks = store.state.withLock { (count: $0.blocks.count, bytes: $0.blocks.bytes) }
        #expect(blocks.count == 1 && blocks.bytes == header.count, "one block, as long as the header and no longer")
        #expect(try await store.read(fragment, .header) == header)
        blocks = store.state.withLock { (count: $0.blocks.count, bytes: $0.blocks.bytes) }
        #expect(blocks.count == 1, "the second read added nothing")
        // The file goes: the header is still there to read (the 64 MB cache), the rest of the fragment is not (it was never read).
        await store.stop()
        try FileManager.default.removeItem(at: result.mp4)
        #expect(try await store.read(fragment, .header) == header, "served from the cache")
        await #expect(throws: ArchiveError.fileGone) { try await store.read(fragment, .fragment) }
    }

    @Test func aFragmentTheIndexDescribesWrongHasNoHeader() async throws {
        let (harness, _) = try await Self.started()
        let store = harness.store
        let real = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start)))
        func lying(offset: UInt64? = nil, headerLength: Int? = nil) -> ArchiveFragment {
            var fragment = real
            if let offset { fragment.byteOffset = offset }
            if let headerLength { fragment.headerLength = headerLength }
            return fragment
        }
        let notThere = ArchiveError.unreadable("That part is not in the file.")
        await #expect(throws: notThere) { try await store.read(lying(headerLength: 0), .header) }
        await #expect(throws: notThere) { try await store.read(lying(headerLength: -1), .header) }
        await #expect(throws: notThere) { try await store.read(lying(headerLength: real.byteLength + 1), .header) }
        await #expect(throws: notThere) { try await store.read(lying(offset: UInt64.max - 10, headerLength: 100), .header) }
        await #expect(throws: notThere) { try await store.read(lying(offset: 100_000_000, headerLength: 100), .header) }
        #expect(try await store.read(real, .header).count == real.headerLength, "and the real one still reads")
    }

    @Test func aHeaderThatIsNotWhereTheIndexSaysTakesItsFileOutOfTheTimeline() async throws {
        let (harness, result) = try await Self.started()
        let store = harness.store
        let fragment = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 8_000)))
        // Something overwrote the start of fragment 3 (the index is right about the file's size, wrong about what is in it).
        let handle = try FileHandle(forWritingTo: result.mp4)
        try handle.seek(toOffset: result.index.fragments[3].offset + 4)
        try handle.write(contentsOf: Data("junk".utf8))
        try handle.close()
        await #expect(throws: ArchiveError.unreadable("This part of the recording is damaged.")) { try await store.read(fragment, .header) }
        #expect(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 1_000)) == nil, "the file is out of the timeline: a gap")
        #expect(store.extent(camera: Self.camera) == nil)
    }

    @Test func aHeaderLooksRightWhenItStartsWithPrftOrMoof() {
        func box(_ type: String, size: Int = 32) -> Data {
            var data = Data([0, 0, 0, UInt8(size)])
            data.append(Data(type.utf8))
            data.append(Data(count: size - 8))
            return data
        }
        #expect(ArchiveStore.looksRight(box("prft"), .header) && ArchiveStore.looksRight(box("moof", size: 24), .header))
        #expect(!ArchiveStore.looksRight(box("mdat"), .header) && !ArchiveStore.looksRight(box("ftyp"), .header))
        #expect(!ArchiveStore.looksRight(Data(), .header) && !ArchiveStore.looksRight(Data(count: 15), .header), "too short to hold a box")
    }

    @Test func aStoreThatIsStillLoadingHasNoHeaders() async throws {
        let harness = try ArchiveStoreHarness { _ in }
        let fragment = ArchiveFragment(camera: Self.camera, segment: "c/2026-10-10/13-00-00", index: 0, start: Date(), duration: 1, mediaStart: 0, hasKeyframe: true,
                                       gopStart: Date(), backToKey: 0, byteLength: 4_096)
        await #expect(throws: ArchiveError.unreadable("The recordings are still loading.")) { try await harness.store.read(fragment, .header) }
    }

    @Test func theHeaderOfAFragmentOfAnOpenFileReadsAsSoonAsTheRecorderSaysItWasWritten() async throws {
        let (harness, result) = try await ArchiveStoreWriteTargetTests.recording()
        let store = harness.store, file = ArchiveStoreWriteTargetTests.open(result)
        store.recorderOpened(file, startWallMs: Self.start, initLength: result.index.initLength, hasAudio: false)
        for position in 0..<3 { store.recorderWrote(file, result.index.fragments[position]) }
        let newest = try #require(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 6_000)))
        #expect(try await store.read(newest, .header) == result.fragments[2].prefix(Int(result.index.fragments[2].headerLength)), "an open file is read through its own handle")
        // The fourth fragment is on the disk but nobody said it was written: it is not offered, so nothing can plan or read it.
        #expect(await store.fragment(camera: Self.camera, containing: ArchiveTime.date(ms: Self.start + 8_000)) == nil)
    }
}
