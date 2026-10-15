import BridgeEngine
import FMP4
import Foundation
import MediaCore
import Testing

/// The real frame source (`ArchiveFrameSource`: bytes from an `ArchiveReading`, frames from `FMP4InitReader`, `MovieFragmentReader` and `FMP4FrameSlicer`)
/// against the made-up recordings of `-demoScenario nvr`, whose bytes come from the real muxer. This is where the app meets T01's readers.
@MainActor @Suite(.timeLimit(.minutes(2))) struct ArchiveFrameSourceTests {
    private func firstFragment() async throws -> (archive: any ArchiveReading, fragment: ArchiveFragment) {
        let engine = BridgeEngine.preview(scenario: .nvr)
        let camera = try #require(engine.cameras.first).id
        let fragment = try #require(await engine.archive.fragment(camera: camera, containing: Date().addingTimeInterval(-3_600)))
        return (engine.archive, fragment)
    }

    @Test func aFragmentComesBackAsItsFramesOnTheWallClock() async throws {
        let (archive, fragment) = try await firstFragment()
        let source = ArchiveFrameSource(archive: archive)
        let info = try await source.initInfo(for: fragment)
        #expect(info.video.codec == .h264 && info.video.width == 1_280 && info.video.height == 720 && info.audio == nil)
        let decoded = try await source.frames(of: fragment, info: info, withAudio: true)
        #expect(decoded.video.count == 30 && decoded.audio.isEmpty, "two seconds at 15 frames per second; the sample recordings have no sound")
        #expect(decoded.video.first?.isKeyframe == true && decoded.video.dropFirst().allSatisfy { !$0.isKeyframe })
        let start = Int64((fragment.start.timeIntervalSinceReferenceDate * 90_000).rounded())
        #expect(decoded.video.first?.pts.converted(to: 90_000).value == start, "the first frame is at the fragment's start")
        let steps = zip(decoded.video, decoded.video.dropFirst()).map { $1.pts.converted(to: 90_000).value - $0.pts.converted(to: 90_000).value }
        #expect(steps.allSatisfy { $0 == 6_000 }, "15 fps in ticks of 90 kHz")
        #expect(decoded.video.allSatisfy { $0.format == info.video && !$0.nalUnits.isEmpty })
    }

    @Test func theKeyframeAloneIsTheFirstFrameOfTheFragment() async throws {
        let (archive, fragment) = try await firstFragment()
        let source = ArchiveFrameSource(archive: archive)
        let info = try await source.initInfo(for: fragment)
        let key = try await source.keyframe(of: fragment, info: info)
        let whole = try await source.frames(of: fragment, info: info, withAudio: false)
        let first = try #require(whole.video.first)
        #expect(key.isKeyframe && key.pts == first.pts && key.nalUnits == first.nalUnits)
    }

    /// Scrubs a cell over the sample recordings to `seconds` into the first fragment; returns what the cell gave its sink and the fragment's start in ticks.
    private func scrub(toSecond seconds: TimeInterval) async throws -> (sink: FakeArchiveSink, start: Int64) {
        let (archive, fragment) = try await firstFragment()
        let sink = FakeArchiveSink()
        let cell = CellPlayback(sink: sink, archive: archive, camera: fragment.camera, clock: PlaybackClock())
        cell.request(PlaybackDesire(target: fragment.start.addingTimeInterval(seconds), precision: .exact, playing: false, epoch: 1))
        await eventually { cell.isIdle && !sink.displayed.isEmpty }
        #expect(cell.coverage == .recorded && cell.hasPicture)
        await cell.stop()
        return (sink, Int64((fragment.start.timeIntervalSinceReferenceDate * 90_000).rounded()))
    }

    @Test func aLongLeadInShowsTheKeyframeThenPrimesTheDecoderAndShowsTheFrameAtTheTime() async throws {
        let (sink, start) = try await scrub(toSecond: 1)   // frame 15 of the fragment's 30
        #expect(sink.displayed.map(\.pts) == [start, start + 15 * 6_000], "the keyframe, then the frame at the time: nothing in between is shown")
        #expect(sink.shows.map(\.pts) == (0...15).map { start + Int64($0) * 6_000 }, "every frame in decode order, once")
        #expect(sink.shows.filter(\.decodeOnly).count == 14 && sink.shows.first?.isKeyframe == true)
    }

    @Test func aShortLeadInGoesStraightToTheFrameAtTheTime() async throws {
        let (sink, start) = try await scrub(toSecond: 0.2)   // frame 3
        #expect(sink.displayed.map(\.pts) == [start + 3 * 6_000])
        #expect(sink.shows.count == 4 && sink.shows.dropLast().allSatisfy(\.decodeOnly) && sink.shows.first?.isKeyframe == true)
    }

    @Test func aDamagedFragmentIsAnErrorNotACrash() async throws {
        let (archive, fragment) = try await firstFragment()
        let source = ArchiveFrameSource(archive: DamagedArchive(archive))
        let info = try await source.initInfo(for: fragment)
        await #expect(throws: (any Error).self) { _ = try await source.frames(of: fragment, info: info, withAudio: false) }
    }
}

/// An archive whose fragments are cut short.
private nonisolated struct DamagedArchive: ArchiveReading {
    let base: any ArchiveReading
    init(_ base: any ArchiveReading) { self.base = base }
    var isReady: Bool { base.isReady }
    var catalogVersion: Int { base.catalogVersion }
    func extent(camera: UUID) -> ArchiveExtent? { base.extent(camera: camera) }
    func fragment(camera: UUID, containing time: Date) async -> ArchiveFragment? { await base.fragment(camera: camera, containing: time) }
    func fragment(camera: UUID, startingAfter time: Date) async -> ArchiveFragment? { await base.fragment(camera: camera, startingAfter: time) }
    func fragment(camera: UUID, id: String) async -> ArchiveFragment? { await base.fragment(camera: camera, id: id) }
    func activity(camera: UUID, range: Range<Date>, binCount: Int) async -> ArchiveActivity { await base.activity(camera: camera, range: range, binCount: binCount) }
    func read(_ fragment: ArchiveFragment, _ part: ArchiveReadPart) async throws -> Data {
        let data = try await base.read(fragment, part)
        return part == .fragment ? data.prefix(data.count / 2) : data
    }
}
