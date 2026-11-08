import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import BridgeWeb

/// A recorded ticket: a video-on-demand playlist planned once, at mint, from the fragments the recorder holds. A segment is a key fragment and
/// the continuation fragments after it, joined; a new recording file is a new map behind a discontinuity.
@Suite(.timeLimit(.minutes(5))) struct HLSRecordedTests {
    private static let base = NVRRig.base

    /// The clock the tests move (the time of day only).
    private final class Clock: Sendable {
        private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { time.withLock { $0 } }
        func set(milliseconds: Int64) { time.withLock { $0 = Date(timeIntervalSince1970: Double(milliseconds) / 1000) } }
    }

    private struct Bridge {
        var harness: Harness
        var tv: Harness.PairedTV
        var camera: CameraConfiguration
        var archive: FakeArchiveReading
        var clock: Clock

        func mint(from: Int64, to: Int64, camera: UUID? = nil) async -> Answer {
            let body: [String: Any] = ["camera": (camera ?? self.camera.id).uuidString, "kind": "recorded", "from": from, "to": to]
            return await harness.send("POST", "/api/v1/hls/tickets", json: body, headers: [("Authorization", "Bearer \(tv.key)")])
        }

        /// Mints a ticket for `from`...`to` (milliseconds after the base) and returns the ticket.
        func ticket(from: Int64 = 0, to: Int64) async throws -> String {
            let answer = await mint(from: HLSRecordedTests.base + from, to: HLSRecordedTests.base + to)
            #expect(answer.status == 200, "\(answer.text)")
            let url = try #require(answer.json["url"] as? String, "a url: \(answer.text)")
            let parts = url.split(separator: "/").map(String.init)
            return try #require(parts.count == 5 ? parts[3] : nil)
        }

        func fetch(_ ticket: String, _ file: String, query: String = "") async -> Answer {
            await harness.send("GET", "/api/v1/hls/\(ticket)/\(file)\(query)")
        }

        func head(_ ticket: String, _ file: String) async -> Answer {
            await harness.send("HEAD", "/api/v1/hls/\(ticket)/\(file)")
        }
    }

    private func makeBridge(files: (UUID) throws -> [ArchiveFixtureFile], audioEnabled: Bool = true, now: Int64? = nil,
                            modify: @escaping @Sendable (inout WebConfiguration) -> Void = { _ in }) async throws -> Bridge {
        let backend = FakeBackend()
        var porch = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "")
        porch.audioEnabled = audioEnabled
        try await backend.addCamera(porch, password: nil)
        let archive = FakeArchiveReading(try files(porch.id))
        backend.write { $0.archive = archive }
        let clock = Clock()
        if let now { clock.set(milliseconds: Self.base + now) }
        let harness = try Harness(backend: backend) {
            $0.now = { clock.now }
            modify(&$0)
        }
        let owner = try await harness.signIn()
        return Bridge(harness: harness, tv: try await harness.pairAppleTV(owner: owner), camera: porch, archive: archive, clock: clock)
    }

    private func file(_ camera: UUID, _ name: String = "13-24-05", offsetMs: Int64 = 0, fragments: Int = 9, gop: Int = 3, audio: Bool = false) throws -> ArchiveFixtureFile {
        try ArchiveFixture.file(camera: camera, segment: "\(camera.uuidString)/2026-09-14/\(name)", startMs: Double(Self.base + offsetMs), fragments: fragments,
                                gopFragments: gop, audio: audio)
    }

    /// What a segment of `fixture`'s fragments `indices` should hold: the stored fragments without their `prft`, one after the other.
    private func joined(_ fixture: ArchiveFixtureFile, _ indices: Range<Int>) throws -> Data {
        try indices.reduce(into: Data()) { out, index in
            try out.append(ArchiveMedia.segmentWithSound(fixture.stored[index]))
        }
    }

    private func lines(_ answer: Answer) -> [String] { answer.text.split(separator: "\n").map(String.init) }

    private func durations(_ answer: Answer) -> [Double] {
        lines(answer).filter { $0.hasPrefix("#EXTINF:") }.compactMap { Double($0.dropFirst(8).dropLast()) }
    }

    // MARK: Segments

    @Test func startsOnTheKeyFragmentBeforeTheStart() async throws {
        let bridge = try await makeBridge { [self] in [try file($0)] }
        let fixture = bridge.archive.files[0]
        // 4.5 s is inside fragment 4, a continuation: its key fragment is 3.
        let ticket = try await bridge.ticket(from: 4_500, to: 9_000)
        let media = await bridge.fetch(ticket, "media.m3u8")
        #expect(media.status == 200, "\(media.text)")
        #expect(durations(media) == [3.0, 3.0], "the first segment is fragments 3, 4 and 5 and nothing from before 3")
        let first = await bridge.fetch(ticket, "seg-0.m4s")
        #expect(first.status == 200)
        #expect(first.body == (try joined(fixture, 3..<6)))
        // The first picture is a key picture (the segment is fragment 3's moof first).
        #expect(try baseMediaDecodeTime(in: first.body) == fixture.fragments[3].mediaStart)
    }

    @Test func joinsContinuationFragmentsIntoOneSegment() async throws {
        let bridge = try await makeBridge { [self] in [try file($0)] }
        let fixture = bridge.archive.files[0]
        let ticket = try await bridge.ticket(to: 9_000)
        let media = await bridge.fetch(ticket, "media.m3u8")
        #expect(durations(media) == [3.0, 3.0, 3.0])
        for (number, group) in [0..<3, 3..<6, 6..<9].enumerated() {
            let segment = await bridge.fetch(ticket, "seg-\(number).m4s")
            #expect(segment.status == 200)
            #expect(segment.body == (try joined(fixture, group)), "segment \(number)")
            #expect(segment.headers["Content-Type"] == "video/iso.segment")
        }
        #expect((await bridge.fetch(ticket, "seg-3.m4s")).status == 404)
    }

    @Test func aNewFileIsADiscontinuityWithItsOwnMap() async throws {
        // The second file starts when the first ends (4 s) and has its own init segment (this one carries sound).
        let bridge = try await makeBridge { [self] in
            [try file($0, "13-24-05", fragments: 4, gop: 2), try file($0, "13-24-09", offsetMs: 4_000, fragments: 4, gop: 2, audio: true)]
        }
        let (first, second) = (bridge.archive.files[0], bridge.archive.files[1])
        let ticket = try await bridge.ticket(to: 8_000)
        let media = await bridge.fetch(ticket, "media.m3u8")
        let list = lines(media)
        #expect(list.filter { $0.hasPrefix("#EXT-X-MAP:") } == ["#EXT-X-MAP:URI=\"init-0.mp4\"", "#EXT-X-MAP:URI=\"init-1.mp4\""])
        #expect(list.filter { $0 == "#EXT-X-DISCONTINUITY" }.count == 1)
        let at = try #require(list.firstIndex(of: "#EXT-X-DISCONTINUITY"))
        #expect(list[at + 1] == "#EXT-X-MAP:URI=\"init-1.mp4\"", "the discontinuity comes before the new map")
        #expect(list[..<at].filter { $0.hasPrefix("seg-") } .count == 2 && list[at...].filter { $0.hasPrefix("seg-") }.count == 2)
        #expect((await bridge.fetch(ticket, "init-0.mp4")).body == first.initData)
        #expect((await bridge.fetch(ticket, "init-1.mp4")).body == second.initData, "the second file's own init, with its sound track")
        #expect((await bridge.fetch(ticket, "seg-2.m4s")).body == (try joined(second, 0..<2)))
        #expect((await bridge.fetch(ticket, "init-2.mp4")).status == 404)
    }

    @Test func endsWithEndList() async throws {
        let bridge = try await makeBridge { [self] in [try file($0)] }
        let media = await bridge.fetch(try await bridge.ticket(to: 9_000), "media.m3u8")
        let list = lines(media)
        #expect(list.first == "#EXTM3U" && list.last == "#EXT-X-ENDLIST")
        #expect(list.contains("#EXT-X-PLAYLIST-TYPE:VOD") && list.contains("#EXT-X-TARGETDURATION:3"))
        #expect(media.headers["Content-Type"] == "application/vnd.apple.mpegurl")
    }

    @Test func anOpenEventEndsAtNow() async throws {
        // It is 3.5 s into the recording: a `to` far ahead plays what exists, up to the fragment now is in.
        let bridge = try await makeBridge(files: { [self] in [try file($0)] }, now: 3_500)
        let ticket = try await bridge.ticket(to: 3 * 3_600_000)
        let media = await bridge.fetch(ticket, "media.m3u8")
        #expect(durations(media) == [3.0, 1.0], "fragments 0 to 2, then fragment 3 which now is in")
        // A start in the future is nothing recorded.
        #expect((await bridge.mint(from: Self.base + 10_000, to: Self.base + 20_000)).status == 404)
    }

    @Test func refusesMoreThanTwoHours() async throws {
        let bridge = try await makeBridge(files: { [self] in [try file($0)] }, now: 3 * 3_600_000)
        let over = await bridge.mint(from: Self.base, to: Self.base + 7_200_001)
        #expect(over.status == 400 && over.json["code"] as? String == "range_too_long", "\(over.text)")
        // Two hours exactly is allowed; a `to` past now is cut to now first, so it is the cut range that counts.
        #expect((await bridge.mint(from: Self.base, to: Self.base + 7_200_000)).status == 200)
        let early = try await makeBridge(files: { [self] in [try file($0)] }, now: 5_000)
        #expect((await early.mint(from: Self.base, to: Self.base + 4 * 3_600_000)).status == 200)
    }

    @Test func noRecordingsInTheRangeIsNotFoundAtMint() async throws {
        let bridge = try await makeBridge(files: { [self] in [try file($0, fragments: 3)] }, now: 3_600_000)
        let none = await bridge.mint(from: Self.base + 600_000, to: Self.base + 660_000)
        #expect(none.status == 404, "\(none.text)")
        #expect(await bridge.harness.app.hlsTickets.count(viewer: bridge.tv.id) == 0, "no ticket is held for it")
        let other = await bridge.mint(from: Self.base, to: Self.base + 3_000, camera: bridge.camera.id)
        #expect(other.status == 200)
    }

    @Test func aPlanIsKeptSoTheFilesDoNotWalkTheArchiveAgain() async throws {
        let bridge = try await makeBridge { [self] in [try file($0)] }
        let ticket = try await bridge.ticket(to: 9_000)
        let before = bridge.archive.reads.count
        _ = await bridge.fetch(ticket, "index.m3u8")
        _ = await bridge.fetch(ticket, "media.m3u8")
        #expect(bridge.archive.reads.count == before, "the playlists are written from the plan: no read")
        _ = await bridge.fetch(ticket, "seg-1.m4s")
        #expect(bridge.archive.reads.count - before == 3, "a segment reads its three fragments")
    }

    // MARK: Master

    @Test func theMasterTellsTheCodecsSizeAndRate() async throws {
        let bridge = try await makeBridge { [self] in [try file($0, audio: true)] }
        let fixture = bridge.archive.files[0]
        let ticket = try await bridge.ticket(to: 9_000)
        let master = await bridge.fetch(ticket, "index.m3u8")
        #expect(master.status == 200 && master.headers["Content-Type"] == "application/vnd.apple.mpegurl")
        let stream = try #require(lines(master).first { $0.hasPrefix("#EXT-X-STREAM-INF:") })
        #expect(stream.contains("CODECS=\"avc1.64001e,mp4a.40.2\""), "\(stream)")
        #expect(stream.contains("RESOLUTION=640x360"))
        // The largest segment's bytes (a stored fragment less its 32-byte prft) over its 3 s.
        let largest = (0..<3).map { group in (group * 3..<group * 3 + 3).reduce(0) { $0 + fixture.fragments[$1].byteLength - 32 } }.max()!
        let bandwidth = try #require(stream.split(separator: ",").first { $0.contains("BANDWIDTH=") }.flatMap { Int($0.split(separator: "=")[1]) })
        #expect(abs(bandwidth - largest * 8 / 3) <= 8, "\(bandwidth) against \(largest * 8 / 3)")
        #expect(lines(master).contains("media.m3u8"))
    }

    // MARK: Sound

    @Test func soundComesWithTheFragmentsWhenTheCameraSwitchIsOn() async throws {
        let bridge = try await makeBridge(files: { [self] in [try file($0, audio: true)] }, audioEnabled: true)
        let fixture = bridge.archive.files[0]
        let ticket = try await bridge.ticket(to: 9_000)
        #expect((await bridge.fetch(ticket, "init-0.mp4")).body == fixture.initData, "the whole init, sound track included")
        let segment = await bridge.fetch(ticket, "seg-0.m4s")
        #expect(segment.body == (try joined(fixture, 0..<3)))
        let videoOnly = try (0..<3).reduce(0) { $0 + (try ArchiveMedia.videoSegment(fixture.stored[$1])).count }
        #expect(segment.body.count > videoOnly, "the sound is still in the fragments")
    }

    @Test func aCameraWhoseSoundIsOffIsSentWithoutIt() async throws {
        let bridge = try await makeBridge(files: { [self] in [try file($0, audio: true)] }, audioEnabled: false)
        let fixture = bridge.archive.files[0]
        let ticket = try await bridge.ticket(to: 9_000)
        let initial = await bridge.fetch(ticket, "init-0.mp4")
        #expect(initial.body == (try ArchiveMedia.videoInit(fixture.initData)).data, "the video track only")
        #expect(try ArchiveMedia.soundInit(initial.body) == nil)
        let segment = await bridge.fetch(ticket, "seg-0.m4s")
        let video = try (0..<3).reduce(into: Data()) { out, index in try out.append(ArchiveMedia.videoSegment(fixture.stored[index])) }
        #expect(segment.body == video)
        let master = await bridge.fetch(ticket, "index.m3u8")
        #expect(master.text.contains("CODECS=\"avc1.64001e\""), "no sound in the codecs either: \(master.text)")
    }

    // MARK: Timestamps

    @Test func fragmentsOfAFileAbutInMediaTimeAndAreNotRebased() async throws {
        let bridge = try await makeBridge { [self] in [try file($0)] }
        let fixture = bridge.archive.files[0]
        let ticket = try await bridge.ticket(from: 4_500, to: 9_000)
        let first = await bridge.fetch(ticket, "seg-0.m4s")
        // The segment is whole moof + mdat pairs; each starts where the one before ended.
        var offset = 0
        var times: [Int64] = []
        while offset < first.body.count {
            let rest = first.body.subdata(in: offset..<first.body.count)
            times.append(try #require(try baseMediaDecodeTime(in: rest)))
            let moofSize = Int(rest.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
            let mdatSize = Int(rest.subdata(in: moofSize..<moofSize + 4).reduce(0) { $0 << 8 | UInt32($1) })
            offset += moofSize + mdatSize
        }
        #expect(times == [3, 4, 5].map { fixture.fragments[$0].mediaStart }, "the file's own times: the first segment does not start at 0")
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 == 90_000 })
    }

    @Test func sumOfExtinfMatchesTheRange() async throws {
        let bridge = try await makeBridge { [self] in [try file($0, fragments: 24, gop: 4)] }
        for (from, to) in [(0, 24_000), (1_500, 9_300), (5_000, 17_000)] as [(Int64, Int64)] {
            let media = await bridge.fetch(try await bridge.ticket(from: from, to: to), "media.m3u8")
            let total = durations(media).reduce(0, +)
            let range = Double(to - from) / 1000
            // It starts up to one group of pictures (4 s) early and ends with the fragment that holds `to` (up to 1 s late).
            #expect(total >= range && total <= range + 4 + 1, "\(total) for \(range)")
        }
    }

    // MARK: Files

    @Test func everyFileIsNoStoreAndTakesTheCameraFromTheTicketAlone() async throws {
        let bridge = try await makeBridge { [self] in [try file($0)] }
        let ticket = try await bridge.ticket(to: 9_000)
        let other = UUID().uuidString
        for name in ["index.m3u8", "media.m3u8", "init-0.mp4", "seg-0.m4s", "seg-9.m4s", "init-7.mp4", "other.txt"] {
            let answer = await bridge.fetch(ticket, name)
            #expect(answer.headers["Cache-Control"] == "no-store", "\(name)")
            // A camera named in the address changes nothing: the ticket says which one.
            let named = await bridge.fetch(ticket, name, query: "?camera=\(other)&cameras=\(other)&stream=main&from=0")
            #expect(named.status == answer.status && named.body == answer.body, "\(name)")
        }
        #expect((await bridge.fetch(ticket, "seg-0.m4s")).status == 200)
        #expect((await bridge.fetch(ticket, "seg-9.m4s")).status == 404)
    }

    @Test func aTicketPlaysItsOwnCameraWhenTwoHaveRecordings() async throws {
        let backend = FakeBackend()
        var porch = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "")
        var garage = CameraConfiguration(name: "Garage", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.21"), username: "")
        porch.audioEnabled = true
        garage.audioEnabled = true
        try await backend.addCamera(porch, password: nil)
        try await backend.addCamera(garage, password: nil)
        let archive = FakeArchiveReading([try file(porch.id, "13-24-05", fragments: 3, gop: 3), try file(garage.id, "13-24-05", fragments: 6, gop: 3)])
        backend.write { $0.archive = archive }
        let clock = Clock()
        let harness = try Harness(backend: backend) { $0.now = { clock.now } }
        let tv = try await harness.pairAppleTV(owner: try await harness.signIn())
        let bridge = Bridge(harness: harness, tv: tv, camera: garage, archive: archive, clock: clock)
        let ticket = try await bridge.ticket(to: 6_000)
        let media = await bridge.fetch(ticket, "media.m3u8")
        #expect(durations(media) == [3.0, 3.0], "the garage's six fragments, not the porch's three")
    }

    // MARK: Size

    @Test func aHEADOnARecordedInitOrSegmentIsRefusedWithoutReadingTheArchive() async throws {
        let bridge = try await makeBridge { [self] in [try file($0)] }
        let ticket = try await bridge.ticket(to: 9_000)
        let readsBefore = bridge.archive.reads.count
        for name in ["init-0.mp4", "seg-0.m4s"] {
            let answer = await bridge.head(ticket, name)
            #expect(answer.status == 405 && answer.headers["Allow"] == "GET", "\(name)")
            #expect(answer.headers["Cache-Control"] == "no-store", "\(name)")
        }
        #expect(bridge.archive.reads.count == readsBefore, "nothing was read")
        #expect(await bridge.head(ticket, "media.m3u8").status == 200, "a playlist costs nothing and still answers HEAD")
        #expect(await bridge.fetch(ticket, "seg-0.m4s").status == 200)
    }

    @Test func aPlanOfTheMostFragmentsIsUnderOneMebibyte() async throws {
        let bridge = try await makeBridge(files: { [self] in
            [try ArchiveFixture.file(camera: $0, segment: "\($0.uuidString)/2026-09-14/13-24-05", startMs: Double(Self.base), fragments: WebApp.hlsMostPlannedFragments,
                                     framesPerFragment: 1, gopFragments: 1)]
        }, now: 3_600_000)
        let plan = try await bridge.harness.app.planRecording(camera: bridge.camera.id, from: Self.base, to: Self.base + 3_600_000, keepSound: true, archive: bridge.archive)
        #expect(plan.segments.reduce(0) { $0 + $1.count } == WebApp.hlsMostPlannedFragments)
        #expect(plan.estimatedBytes < 1_048_576, "\(plan.estimatedBytes)")
        #expect(plan.estimatedBytes > MemoryLayout<HLSRecordedPlan.Segment>.stride * plan.segments.count)
    }

    @Test func moreThanTheMostFragmentsIsTooLong() async throws {
        let bridge = try await makeBridge(files: { [self] in
            [try ArchiveFixture.file(camera: $0, segment: "\($0.uuidString)/2026-09-14/13-24-05", startMs: Double(Self.base), fragments: WebApp.hlsMostPlannedFragments + 1,
                                     framesPerFragment: 1, gopFragments: 1)]
        }, now: 3_600_000)
        let answer = await bridge.mint(from: Self.base, to: Self.base + 3_600_000)
        #expect(answer.status == 400 && answer.json["code"] as? String == "range_too_long", "\(answer.text)")
        let message = answer.json["message"] as? String ?? ""
        #expect(message.contains("2 hours") && message.contains("fewer"), "the message is true for a range inside 2 hours: \(message)")
    }

    @Test func aSegmentTheBoxWouldAlwaysRefuseIsRefusedAtMint() async throws {
        let bridge = try await makeBridge { [self] in [try file($0)] }
        // Each key fragment with its two continuations is a few kilobytes: a cap of 1,000 bytes cannot hold one.
        await #expect(throws: APIError.self) {
            _ = try await bridge.harness.app.planRecording(camera: bridge.camera.id, from: Self.base, to: Self.base + 9_000, keepSound: true, largestSegment: 1_000, archive: bridge.archive)
        }
        do {
            _ = try await bridge.harness.app.planRecording(camera: bridge.camera.id, from: Self.base, to: Self.base + 9_000, keepSound: true, largestSegment: 1_000, archive: bridge.archive)
        } catch let error as APIError {
            #expect(error.status == 400 && error.code == "range_too_long")
        }
        _ = try await bridge.harness.app.planRecording(camera: bridge.camera.id, from: Self.base, to: Self.base + 9_000, keepSound: true, archive: bridge.archive)
    }

    // MARK: Admission

    @Test func takesAnArchiveSlotPerRead() async throws {
        let bridge = try await makeBridge(files: { [self] in [try file($0)] }) { $0.maximumArchiveReads = 1 }
        let ticket = try await bridge.ticket(to: 9_000)
        let gate = AsyncGate()
        bridge.archive.setReadGate(gate)
        let held = Task { await bridge.fetch(ticket, "seg-0.m4s") }
        #expect(await eventually { bridge.archive.readsInFlight == 1 })
        let busy = await bridge.fetch(ticket, "seg-1.m4s")
        #expect(busy.status == 429 && busy.json["code"] as? String == "busy", "\(busy.text)")
        #expect(busy.headers["Retry-After"] == "1" && busy.headers["Cache-Control"] == "no-store")
        // The playlists read nothing, so they need no slot.
        #expect((await bridge.fetch(ticket, "media.m3u8")).status == 200)
        gate.open()
        #expect((await held.value).status == 200)
        bridge.archive.setReadGate(nil)
        #expect(bridge.harness.app.archiveSlotsInUse == 0)
        #expect((await bridge.fetch(ticket, "seg-1.m4s")).status == 200)
    }

    @Test func aFragmentThatWentAwayIsSaidSoAfterwards() async throws {
        let bridge = try await makeBridge { [self] in [try file($0)] }
        let ticket = try await bridge.ticket(to: 9_000)
        bridge.archive.fail(bridge.archive.files[0].fragments[4].id, with: .fileGone)
        let gone = await bridge.fetch(ticket, "seg-1.m4s")
        #expect(gone.status == 410 && gone.headers["Cache-Control"] == "no-store")
        #expect((await bridge.fetch(ticket, "seg-0.m4s")).status == 200)
    }

    @Test func theTicketGoesWhenTheViewerDoes() async throws {
        let bridge = try await makeBridge { [self] in [try file($0)] }
        let ticket = try await bridge.ticket(to: 9_000)
        #expect((await bridge.fetch(ticket, "media.m3u8")).status == 200)
        await bridge.harness.app.hlsTickets.drop(viewer: bridge.tv.id)
        #expect((await bridge.fetch(ticket, "media.m3u8")).status == 404)
        #expect((await bridge.fetch(ticket, "seg-0.m4s")).status == 404)
    }
}
