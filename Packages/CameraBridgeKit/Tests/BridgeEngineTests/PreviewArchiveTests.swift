import FMP4
import Foundation
import MediaCore
import Synchronization
import Testing
@testable import BridgeEngine

/// The sample recordings of `-demoScenario nvr`: where fragments are, the gap, the ids, the activity, and (on the Mac, with real codecs) the video.
@Suite(.timeLimit(.minutes(1))) struct PreviewArchiveTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let camera = UUID()

    private func archive(codecs: any MediaCodecs = BridgeEnvironment.inert(directory: FileManager.default.temporaryDirectory).codecs) -> PreviewArchive {
        let gapStart = now.addingTimeInterval(-3 * 3_600)
        return PreviewArchive(recordings: [.init(camera: camera, oldest: now.addingTimeInterval(-2 * 86_400), newest: now.addingTimeInterval(-2.5))],
                              gap: gapStart..<gapStart.addingTimeInterval(25 * 60), codecs: codecs)
    }

    @Test func theExtentIsWhatWasRecordedAndAnUnknownCameraHasNone() {
        let archive = archive()
        let extent = archive.extent(camera: camera)
        #expect(extent?.oldest == now.addingTimeInterval(-2 * 86_400) && extent?.newest == now.addingTimeInterval(-2.5) && extent?.typicalGOP == 2)
        #expect(archive.extent(camera: UUID()) == nil && archive.isReady)
    }

    @Test func fragmentsAreTwoSecondGopsWithExactBoundaries() async throws {
        let archive = archive()
        let oldest = now.addingTimeInterval(-2 * 86_400)
        let first = try #require(await archive.fragment(camera: camera, containing: oldest))
        #expect(first.start == oldest && first.duration == 2 && first.hasKeyframe && first.backToKey == 0 && first.gopStart == first.start && first.index == 0)
        let inside = try #require(await archive.fragment(camera: camera, containing: oldest.addingTimeInterval(3.9)))
        #expect(inside.start == oldest.addingTimeInterval(2) && inside.index == 1)
        #expect(await archive.fragment(camera: camera, containing: oldest.addingTimeInterval(4))?.start == oldest.addingTimeInterval(4), "t == end is the next fragment")
        #expect(await archive.fragment(camera: camera, containing: oldest.addingTimeInterval(-0.001)) == nil, "before the oldest")
        #expect(await archive.fragment(camera: camera, containing: now) == nil, "after the newest")
        #expect(await archive.fragment(camera: UUID(), containing: oldest) == nil)
    }

    @Test func theGapHasNoFragmentsAndLookupsCrossIt() async throws {
        let archive = archive()
        let gapStart = now.addingTimeInterval(-3 * 3_600), gapEnd = gapStart.addingTimeInterval(25 * 60)
        #expect(await archive.fragment(camera: camera, containing: gapStart.addingTimeInterval(600)) == nil)
        let before = try #require(await archive.fragment(camera: camera, containing: gapStart.addingTimeInterval(-3)))
        #expect(before.end <= gapStart)
        let after = try #require(await archive.fragment(camera: camera, startingAfter: gapStart.addingTimeInterval(600)))
        #expect(after.start >= gapEnd && after.start < gapEnd.addingTimeInterval(2.001), "the first fragment after the gap")
        let across = try #require(await archive.fragment(camera: camera, startingAfter: before.start))
        #expect(across.start == before.end, "the next one is right after: starting after a fragment is the next fragment")
        #expect(await archive.fragment(camera: camera, startingAfter: now) == nil)
        let first = try #require(await archive.fragment(camera: camera, startingAfter: now.addingTimeInterval(-10 * 86_400)))
        #expect(first.start == now.addingTimeInterval(-2 * 86_400), "before everything: the first fragment")
    }

    @Test func idsAreStableUniqueAndLookUpTheSameFragment() async throws {
        let archive = archive()
        let a = try #require(await archive.fragment(camera: camera, containing: now.addingTimeInterval(-86_400)))
        let b = try #require(await archive.fragment(camera: camera, containing: now.addingTimeInterval(-86_400 + 2)))
        #expect(a.id != b.id && ArchiveIdentity.parseFragmentID(a.id) != nil)
        #expect(await archive.fragment(camera: camera, id: a.id) == a)
        #expect(await archive.fragment(camera: UUID(), id: a.id) == nil, "another camera's id")
        #expect(await archive.fragment(camera: camera, id: "000000000000.1") == nil)
        let files = Set(try await (0..<2_000).asyncMap { try #require(await archive.fragment(camera: camera, containing: now.addingTimeInterval(-86_400 + Double($0) * 2))).fileKey })
        #expect(files.count == 5, "450 fragments to a file: 2000 fragments touch five files")
    }

    @Test func activityFollowsADailyRhythmAndIsEmptyInTheGap() async {
        let archive = archive()
        let start = now.addingTimeInterval(-86_400)
        let day = await archive.activity(camera: camera, range: start..<start.addingTimeInterval(86_400), binCount: 288)   // five minute bins
        #expect(day.bins.count == 288 && day.typical == PreviewArchive.typicalLevel && day.isComplete)
        let gapStart = now.addingTimeInterval(-3 * 3_600)
        let gapBin = Int(gapStart.addingTimeInterval(600).timeIntervalSince(start) / 300)
        #expect(day.bins[gapBin].coverage == 0 && day.bins[gapBin].level == 0, "the gap")
        #expect(day.bins.first?.coverage == 1)
        #expect(day.bins.last.map { $0.coverage < 1 } == true, "the last bin ends at the recorded edge, 2.5 s short of now")
        let levels = day.bins.filter { $0.coverage == 1 }.map(\.level)
        #expect((levels.max() ?? 0) > 2 * (levels.min() ?? 0), "busy and quiet hours")
        let outside = await archive.activity(camera: camera, range: now.addingTimeInterval(-10 * 86_400)..<now.addingTimeInterval(-9 * 86_400), binCount: 24)
        #expect(outside.bins.allSatisfy { $0.coverage == 0 })
        let unknown = await archive.activity(camera: UUID(), range: start..<now, binCount: 10)
        #expect(unknown.bins.count == 10 && unknown.typical == nil && unknown.bins.allSatisfy { $0.coverage == 0 })
    }

    @Test func aRecordingCameraKeepsRecordingWithTheClock() async throws {
        let clock = Mutex(now)
        let gapStart = now.addingTimeInterval(-3 * 3_600)
        let archive = PreviewArchive(recordings: [.init(camera: camera, oldest: now.addingTimeInterval(-86_400), newest: now.addingTimeInterval(-2.5), followsClock: true)],
                                     gap: gapStart..<gapStart.addingTimeInterval(25 * 60),
                                     codecs: BridgeEnvironment.inert(directory: FileManager.default.temporaryDirectory).codecs, clock: { clock.withLock { $0 } })
        #expect(archive.extent(camera: camera)?.newest == now.addingTimeInterval(-2.5))
        #expect(await archive.fragment(camera: camera, containing: now.addingTimeInterval(1)) == nil, "not recorded yet")
        clock.withLock { $0 = now.addingTimeInterval(3_600) }   // an hour later: another 3,600 s, many files further on
        #expect(archive.extent(camera: camera)?.newest == now.addingTimeInterval(3_600 - 2.5))
        let later = try #require(await archive.fragment(camera: camera, containing: now.addingTimeInterval(3_000)))
        #expect(later.end <= now.addingTimeInterval(3_600 - 2.5))
        #expect(await archive.fragment(camera: camera, id: later.id) == later, "the id of a file that did not exist at the start")
        let last = try #require(await archive.fragment(camera: camera, containing: now.addingTimeInterval(3_600 - 6)))   // the last fragment that ended before the newest edge
        #expect(await archive.fragment(camera: camera, startingAfter: last.start) == nil, "nothing after the newest")
        let hour = await archive.activity(camera: camera, range: now..<now.addingTimeInterval(3_600), binCount: 60)
        #expect(hour.bins[0].coverage == 1 && hour.bins[59].coverage < 1 && hour.bins[59].coverage > 0.9, "the last bin stops 2.5 s short of the clock")
        let fixed = PreviewArchive(recordings: [.init(camera: camera, oldest: now.addingTimeInterval(-86_400), newest: now.addingTimeInterval(-2.5))],
                                   gap: gapStart..<gapStart.addingTimeInterval(25 * 60),
                                   codecs: BridgeEnvironment.inert(directory: FileManager.default.temporaryDirectory).codecs, clock: { clock.withLock { $0 } })
        #expect(fixed.extent(camera: camera)?.newest == now.addingTimeInterval(-2.5), "a camera that stopped recording stays where it stopped")
    }

    @Test func nothingCanBeExportedFromTheSampleRecordings() async throws {
        let archive = archive()
        let fragment = try #require(await archive.fragment(camera: camera, containing: now.addingTimeInterval(-86_400)))
        // The header is refused before the sample clip is looked at, so the answer is the same with or without codecs.
        await #expect(throws: ArchiveError.unreadable("The preview has no recordings to export.")) { try await archive.read(fragment, .header) }
        await #expect(throws: ArchiveError.unreadable("The sample recordings have no pictures in this build.")) { try await archive.read(fragment, .fragment) }
    }

    @Test func withoutCodecsReadsSaySoInASentence() async throws {
        let archive = archive()
        let fragment = try #require(await archive.fragment(camera: camera, containing: now.addingTimeInterval(-86_400)))
        await #expect(throws: ArchiveError.self) { try await archive.read(fragment, .fragment) }
    }

    @MainActor @Test func theNVRScenarioHasRecordingsStorageAndSettings() async throws {
        let engine = BridgeEngine.preview(scenario: .nvr)
        #expect(engine.cameras.count == 8 && PreviewScenario(rawValue: "nvr") == .nvr)
        #expect(engine.archive.isReady)
        let extents = engine.cameras.map { engine.archive.extent(camera: $0.id) }
        #expect(extents.allSatisfy { $0 != nil }, "every sample camera has recordings")
        let patio = try #require(engine.cameras.first { $0.name == "Patio" })
        #expect(patio.nvr.state == .off && engine.configurations.first { $0.id == patio.id }?.nvrEnabled == false)
        #expect(try #require(engine.archive.extent(camera: patio.id)).newest < Date().addingTimeInterval(-86_400), "Record was turned off two days ago")
        let driveway = try #require(engine.cameras.first { $0.name == "Driveway" })
        #expect(driveway.nvr.state == .recording && engine.configurations.first { $0.id == driveway.id }?.nvrRecordSound == true)
        let workshop = try #require(engine.cameras.first { $0.name == "Workshop" })
        #expect(workshop.nvr.state == .waiting("waiting for the camera"), "an offline camera that records waits for it")
        let storage = try #require(engine.nvrStorage)
        #expect(storage.pause == nil && storage.usedBytes == 212_000_000_000 && storage.oldest != nil && storage.newest != nil)
        #expect(engine.settings.nvrFolder == storage.folder?.path && engine.settings.nvrKeepDays == 7)
        #expect(BridgeEngine.preview(scenario: .standard).nvrStorage == nil && BridgeEngine.preview(scenario: .standard).cameras.allSatisfy { $0.nvr.state == .off })
    }

    #if canImport(Darwin)
    @Test func withRealCodecsTheFragmentsAreAFileIsOwnInitAndKeyframeBytes() async throws {
        let archive = archive(codecs: BridgeEnvironment.testing(directory: FileManager.default.temporaryDirectory).codecs)
        let one = try #require(await archive.fragment(camera: camera, containing: now.addingTimeInterval(-86_400)))
        let two = try #require(await archive.fragment(camera: camera, containing: now.addingTimeInterval(-86_400 + 2)))
        let initialization = try await archive.read(one, .initialization)
        #expect(try MP4BoxReader.parse(initialization).map(\.type) == ["ftyp", "moov"])
        for fragment in [one, two] {
            let bytes = try await archive.read(fragment, .fragment)
            #expect(try MP4BoxReader.parse(bytes).map(\.type) == ["prft", "moof", "mdat"], "the recorder's layout")
            let key = try await archive.read(fragment, .keyframe)
            #expect(!key.isEmpty && key.count < bytes.count, "the first sample alone")
        }
        let a = try await archive.read(one, .fragment), b = try await archive.read(two, .fragment)
        #expect(a != b, "two groups of pictures, used alternately")
        #expect(try await archive.read(one, .fragment) == a)
    }
    #endif
}

extension Sequence {
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
