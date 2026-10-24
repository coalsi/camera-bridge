import BridgeEngine
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeWeb

/// A time-lapse clip (`GET /nvr/cameras/:id/clip?…&speed=30|60|120|300`): the key pictures alone decoded, shown `speed` times as fast at 30
/// pictures a second, the label drawn at their real times, no sound; through the same converter, slots and niceness as labelled clips.
@Suite struct ClipTimelapseTests {
    static let runs: [(WebApp.LabelRun, String)] = [(.init(mediaStart: 0, mediaEnd: nil, wallBase: 0), "/t/a.txt")]

    static func value(_ option: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: option).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    static func contains(_ arguments: [String], _ run: [String]) -> Bool {
        arguments.count >= run.count && (0...(arguments.count - run.count)).contains { Array(arguments[$0 ..< $0 + run.count]) == run }
    }

    @Test func onlyTheFourTimeLapseSpeedsAreTaken() throws {
        #expect(try WebApp.timelapseSpeed(nil) == nil)
        for speed in [30, 60, 120, 300] { #expect(try WebApp.timelapseSpeed(String(speed)) == speed) }
        for bad in ["0", "2", "45", "301", "-60", "60.0", "x", ""] {
            #expect(throws: APIError.self) { try WebApp.timelapseSpeed(bad) }
        }
    }

    @Test func theFileSaysItIsATimeLapse() {
        #expect(WebApp.timelapseFileName("Gate 2026-10-24 14.00.00.mp4", speed: 60) == "Gate 2026-10-24 14.00.00 time-lapse 60x.mp4")
        #expect(WebApp.timelapseFileName("clip", speed: 300) == "clip time-lapse 300x")
    }

    @Test func theKeyPicturesAloneAreDecodedSpedUpAfterTheLabelWithoutSound() throws {
        let arguments = WebApp.clipArguments(input: "/t/clip.mp4", textFiles: Self.runs, style: TimestampOverlaySettings(), font: nil, correction: nil,
                                             vaapiDevice: nil, speed: 60)
        #expect(Self.contains(arguments, ["-nostdin", "-skip_frame", "nokey", "-i", "/t/clip.mp4"]), "skip_frame is the input's option")
        let filters = try #require(Self.value("-vf", in: arguments))
        #expect(filters.hasPrefix("scale='min(iw\\,3840)':-2,drawtext="), "\(filters)")
        #expect(filters.hasSuffix(",setpts=(PTS-STARTPTS)/60,fps=30"), "the label is drawn at the recording's times, before the speed-up: \(filters)")
        #expect(Self.contains(arguments, ["-map", "0:v:0", "-sn", "-dn", "-vf"]), "no sound is mapped")
        #expect(!arguments.contains("0:a:0?") && !arguments.contains("copy"))
        #expect(Self.contains(arguments, ["-an", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", "pipe:1"]))

        // Straightened too: the warp, the label, the speed-up, then the encoder's format; on the GPU the device comes before the input options.
        let maps: WebApp.ClipCorrectionMaps = (xMap: "/t/x.pgm", yMap: "/t/y.pgm", chromaXMap: "/t/cx.pgm", chromaYMap: "/t/cy.pgm", width: 1920, height: 852)
        let warped = WebApp.clipArguments(input: "/t/clip.mp4", textFiles: [], style: nil, font: nil, correction: maps, vaapiDevice: "/dev/dri/renderD128", speed: 300)
        #expect(Self.contains(warped, ["-vaapi_device", "/dev/dri/renderD128", "-skip_frame", "nokey", "-i", "/t/clip.mp4", "-i", "/t/x.pgm"]))
        let graph = try #require(Self.value("-filter_complex", in: warped))
        #expect(graph.hasSuffix(";[cbw]setpts=(PTS-STARTPTS)/300,fps=30,format=nv12,hwupload[cbv]"), "\(graph)")
        #expect(Self.contains(warped, ["-map", "[cbv]", "-sn", "-dn"]) && warped.contains("-an"))

        // No speed: the arguments of a plain labelled clip, sound and all.
        let plain = WebApp.clipArguments(input: "/t/clip.mp4", textFiles: Self.runs, style: TimestampOverlaySettings(), font: nil, correction: nil, vaapiDevice: nil)
        #expect(!plain.contains("-skip_frame") && plain.contains("0:a:0?") && !plain.contains("-an"))
    }

    // MARK: The route

    private func rig(_ name: String) async throws -> NVRRig {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        archive.files = [try rig.file(fragments: 8, gopFragments: 2)]
        rig.backend.write { $0.configurations[0].name = name }
        return rig
    }

    private func clip(_ rig: NVRRig, _ extra: String) async throws -> HTTPResponse {
        let response = await rig.harness.raw("GET", "/api/v1/nvr/cameras/\(rig.cameraID)/clip?from=\(rig.ms(1_500))&to=\(rig.ms(6_000))&tz=UTC&part=1" + extra,
                                             cookie: rig.session.cookie)
        if case .stream(let body) = response.body { try await body(ResponseStream { _ in }) }
        return response
    }

    @Test(.timeLimit(.minutes(1))) func aTimeLapseGoesThroughTheConverterAndABadSpeedIsRefusedInWords() async throws {
        let rig = try await rig("Lane")
        let bad = await rig.harness.raw("GET", "/api/v1/nvr/cameras/\(rig.cameraID)/clip?from=\(rig.ms(1_500))&to=\(rig.ms(6_000))&tz=UTC&part=1&speed=7",
                                        cookie: rig.session.cookie)
        #expect(bad.status == 400)
        let log = LogCapture()
        defer { log.stop() }
        let response = try await clip(rig, "&speed=60")
        guard WebApp.ffmpegPath() != nil else {
            #expect(response.status == 501, "no converter on this machine")
            return
        }
        // The fixture's pictures are not real H.264, so the converter's answer is not looked at here (the real-ffmpeg test plays one).
        #expect(response.status == 200)
        #expect(response.headers["Content-Disposition"]?.contains("time-lapse 60x") == true)
        #expect(log.text.contains { $0.hasSuffix(": a clip of Lane is being sent as a 60x time-lapse") })
        let labelled = try await clip(rig, "&speed=120&labels=1")
        #expect(labelled.status == 200)
        #expect(log.text.contains { $0.hasSuffix(": a clip of Lane is being sent as a 120x time-lapse, with its label") })
    }

    // MARK: With a real ffmpeg

    @Test(.enabled(if: ClipTools.available, "ffmpeg and ffprobe not found; set CB_FFMPEG and CB_FFPROBE"), .timeLimit(.minutes(1)))
    func aMinuteAt30TimesIsTwoSecondsOfVideoWithoutSound() async throws {
        let folder = try TemporaryDirectory(prefix: "cb-clip-timelapse")
        defer { folder.remove() }
        // A minute of a recording like the bridge's (H.264 in fragmented MP4 at 90 kHz, a key picture every 2 s) with sound.
        let recording = folder.file("recording.mp4")
        let made = try ClipTools.run(ClipTools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=s=320x180:r=25:d=60",
                                                        "-f", "lavfi", "-i", "sine=f=440:d=60", "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
                                                        "-g", "50", "-bf", "0", "-c:a", "aac", "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
                                                        "-video_track_timescale", "90000", recording.path])
        try #require(made.status == 0, "\(made.errors)")
        let arguments = WebApp.clipArguments(input: recording.path, textFiles: [], style: nil, font: nil, correction: nil, vaapiDevice: nil, speed: 30)
        let collected = Box(Data())
        try await WebApp.runStreaming(executable: try #require(ClipTools.ffmpeg), arguments: arguments, timeZone: "UTC",
                                      into: ResponseStream { data in collected.update { $0.append(data) } })
        let clip = folder.file("clip.mp4")
        try collected.value.write(to: clip)
        let probe = try ClipTools.run(ClipTools.ffprobe, ["-v", "error", "-count_frames", "-show_entries", "stream=codec_type,nb_read_frames,r_frame_rate",
                                                          "-of", "default=noprint_wrappers=1", clip.path])
        #expect(probe.status == 0, "\(probe.errors)")
        let lines = probe.text.split(separator: "\n").map(String.init)
        #expect(lines.filter { $0 == "codec_type=audio" }.isEmpty, "no sound: \(probe.text)")
        #expect(lines.contains("r_frame_rate=30/1"), "\(probe.text)")
        let frames = try #require(lines.first { $0.hasPrefix("nb_read_frames=") }.flatMap { Int($0.dropFirst("nb_read_frames=".count)) })
        #expect((55...62).contains(frames), "60 s at 30× is 2 s at 30 pictures a second: \(frames) pictures")
    }
}
