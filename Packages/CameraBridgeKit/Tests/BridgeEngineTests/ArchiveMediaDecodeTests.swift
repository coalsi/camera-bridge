import BridgeSupport
import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

/// What a browser gets from `ArchiveMedia` must decode: the init segment and every segment, joined in order, are a file ffmpeg decodes without a
/// message to exactly the pictures that went in, with the codec string ffprobe 8.1 prints for it (made from the avcC by an older ffprobe). Skipped without
/// ffmpeg and ffprobe (`CB_FFMPEG`, `CB_FFPROBE`, or Homebrew and system locations).
///
/// With `CB_ARCHIVE_MEDIA_EXPORT=<an existing directory>` the files of every fixture are also written there, for the browser spike and the dev server
/// (`<label>.stored.mp4` as the recorder writes it, `<label>.init.mp4`, `<label>.segment-NNN.m4s` as the routes serve them, `<label>.video-only.mp4` as a
/// browser sees them joined, and `<label>.json` with the codec string and the counts). Fixtures made from the private capture are never exported.
@Suite(.timeLimit(.minutes(5)), .enabled(if: ArchiveMediaTools.available, "ffmpeg and ffprobe not found; set CB_FFMPEG and CB_FFPROBE"))
struct ArchiveMediaDecodeTests {
    /// The init segment and the segments of `file` as the page appends them, written to `directory`; returns what ffprobe and ffmpeg say about it, and
    /// ffprobe's codec string for it (nil for HEVC, which no ffprobe has one for).
    @discardableResult
    private func verify(_ file: ArchiveMediaFile, label: String, in directory: TemporaryDirectory, rate: String? = nil)
        throws -> (video: ArchiveMedia.VideoInit, probe: [String: String], codec: String?) {
        let video = try ArchiveMedia.videoInit(file.initSegment)
        let segments = try file.fragments.map(ArchiveMedia.videoSegment)
        let stripped = segments.reduce(into: video.data) { $0.append($1) }
        let url = directory.file("\(label).mp4")
        try stripped.write(to: url)
        try export(file, video: video, segments: segments, label: label)
        let probe = try ArchiveMediaTools.probe(url, fields: ["codec_name", "width", "height", "r_frame_rate", "mime_codec_string", "profile", "level"])
        #expect(probe["nb_read_frames"] == "\(file.frameCount)", "\(label): the pictures that decode")
        #expect(probe["width"] == "\(video.width)" && probe["height"] == "\(video.height)", "\(label): the picture size")
        if let rate { #expect(probe["r_frame_rate"] == rate, "\(label): the frame rate") }
        #expect(try ArchiveMediaTools.decodeErrors(url) == "", "\(label): ffmpeg decodes without a message")
        #expect(try ArchiveMediaTools.streamCount(url) == 1, "\(label): one stream")
        var codec = probe["mime_codec_string"]
        if probe["codec_name"] == "h264" {
            // ffprobe 8.1 prints the codec string, made from bytes 1 to 3 of the avcC. One before 8.1 (7.1 on Camera Bridge OS, 8.0 in the Linux
            // container) prints none, so it is made the same way from the avcC every ffprobe prints; with 8.1 the two must be the same.
            let avcC = try #require(try ArchiveMediaTools.avcConfiguration(url), "\(label): ffprobe's extradata is an avcC")
            let made = "avc1." + [avcC.profile, avcC.compatibility, avcC.level].map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
            #expect(codec == nil || codec == made, "\(label): the codec string made as ffprobe 8.1 makes it")
            codec = codec ?? made
            // The profile and the level ffprobe decodes from the SPS, not from the avcC: the first byte, and the last as a decimal number.
            #expect(ArchiveMediaTools.avcProfiles[probe["profile"] ?? ""] == avcC.profile && probe["level"] == "\(avcC.level)",
                    "\(label): the profile and the level ffprobe decodes (\(probe["profile"] ?? "none"), \(probe["level"] ?? "none"))")
        }
        if let codec { #expect(video.mime == "video/mp4; codecs=\"\(codec)\"", "\(label): ffprobe's codec string") }
        return (video, probe, codec)
    }

    private func export(_ file: ArchiveMediaFile, video: ArchiveMedia.VideoInit, segments: [Data], label: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CB_ARCHIVE_MEDIA_EXPORT"], !label.hasPrefix("capture") else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            Issue.record("CB_ARCHIVE_MEDIA_EXPORT is not an existing directory")
            return
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try file.bytes.write(to: folder.appendingPathComponent("\(label).stored.mp4"))
        try video.data.write(to: folder.appendingPathComponent("\(label).init.mp4"))
        for (index, segment) in segments.enumerated() {
            try segment.write(to: folder.appendingPathComponent("\(label).segment-\(String(format: "%03d", index + 1)).m4s"))
        }
        try segments.reduce(into: video.data) { $0.append($1) }.write(to: folder.appendingPathComponent("\(label).video-only.mp4"))
        let info: [String: Any] = ["mime": video.mime, "width": video.width, "height": video.height, "hadAudio": video.hadAudio,
                                   "frames": file.frameCount, "segments": segments.count]
        try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]).write(to: folder.appendingPathComponent("\(label).json"))
    }

    /// The file as the recorder writes it, and with sound added to the same pictures.
    private func variants(_ frames: [EncodedVideoFrame], cutEvery: Int, soundSeconds: Double) throws -> [(String, ArchiveMediaFile)] {
        [("video", try ArchiveMediaFixtures.mux(frames, cutEvery: cutEvery)),
         ("sound", try ArchiveMediaFixtures.mux(frames, audio: ArchiveMediaFixtures.syntheticAudio(seconds: soundSeconds), audioFormat: ArchiveMediaFixtures.aac, cutEvery: cutEvery))]
    }

    @Test func aThirtySecondGroupOfPicturesDecodes() throws {
        let directory = try TemporaryDirectory(prefix: "cb-archive-media")
        defer { directory.remove() }
        let source = try ArchiveMediaTools.encode(codec: .h264, size: "160x90", rate: "25", frames: 800, gop: 750, in: directory)
        let frames = try #require(ArchiveMediaFixtures.h264Frames(annexB: source, ticks: 3_600))
        #expect(frames.count == 800 && frames.filter(\.isKeyframe).count == 2)
        for (label, file) in try variants(frames, cutEvery: 62, soundSeconds: 33) {
            #expect(file.fragments.count == 14, "a group of 750 pictures is cut every 62 pictures (2.5 s)")
            try verify(file, label: "gop30-\(label)", in: directory, rate: "25/1")
        }
    }

    @Test func ntscFrameRatesKeepTheirExactDurations() throws {
        let directory = try TemporaryDirectory(prefix: "cb-archive-media")
        defer { directory.remove() }
        let source = try ArchiveMediaTools.encode(codec: .h264, size: "160x90", rate: "30000/1001", frames: 91, gop: 30, in: directory)
        let frames = try #require(ArchiveMediaFixtures.h264Frames(annexB: source, ticks: 3_003))
        for (label, file) in try variants(frames, cutEvery: 75, soundSeconds: 4) {
            try verify(file, label: "ntsc-\(label)", in: directory, rate: "30000/1001")
        }
    }

    @Test func soundIsDroppedAndTheVideoIsWhole() throws {
        let directory = try TemporaryDirectory(prefix: "cb-archive-media")
        defer { directory.remove() }
        let source = try ArchiveMediaTools.encode(codec: .h264, size: "320x180", rate: "25", frames: 125, gop: 25, in: directory)
        let frames = try #require(ArchiveMediaFixtures.h264Frames(annexB: source, ticks: 3_600))
        let file = try ArchiveMediaFixtures.mux(frames, audio: ArchiveMediaFixtures.syntheticAudio(seconds: 5), audioFormat: ArchiveMediaFixtures.aac, cutEvery: 62)
        let original = directory.file("original.mp4")
        try file.bytes.write(to: original)
        #expect(try ArchiveMediaTools.streamCount(original) == 2, "the stored file has video and sound")
        let video = try verify(file, label: "sound", in: directory, rate: "25/1").video
        #expect(video.hadAudio)
        let silent = try ArchiveMediaFixtures.mux(frames, cutEvery: 62)
        #expect(try ArchiveMedia.videoInit(silent.initSegment).data == silent.initSegment, "a file without sound is served as it is")
    }

    @Test func twoFilesWithDifferentParameterSetsEachDecodeWithTheirOwnMime() throws {
        let directory = try TemporaryDirectory(prefix: "cb-archive-media")
        defer { directory.remove() }
        var mimes: [String] = []
        for (size, width, height) in [("320x180", 320, 180), ("640x360", 640, 360)] {
            let source = try ArchiveMediaTools.encode(codec: .h264, size: size, rate: "25", frames: 50, gop: 25, in: directory)
            let frames = try #require(ArchiveMediaFixtures.h264Frames(annexB: source, ticks: 3_600))
            for (label, file) in try variants(frames, cutEvery: 62, soundSeconds: 3) {
                let video = try verify(file, label: "sps-\(size)-\(label)", in: directory).video
                #expect(video.width == width && video.height == height)
                if label == "video" { mimes.append(video.mime) }
            }
        }
        #expect(Set(mimes).count == 2, "a new parameter set is a new file with its own codec string")
    }

    @Test(.enabled(if: ArchiveMediaTools.canEncode("libx265"), "this ffmpeg has no libx265"))
    func anHevcFileDecodesAndItsCodecStringNamesTheStreamsProfileAndLevel() throws {
        let directory = try TemporaryDirectory(prefix: "cb-archive-media")
        defer { directory.remove() }
        let source = try ArchiveMediaTools.encode(codec: .hevc, size: "320x180", rate: "25", frames: 50, gop: 25, in: directory)
        let frames = try #require(ArchiveMediaFixtures.hevcFrames(annexB: source, ticks: 3_600))
        for (label, file) in try variants(frames, cutEvery: 62, soundSeconds: 3) {
            let (video, probe, _) = try verify(file, label: "hevc-\(label)", in: directory, rate: "25/1")
            // ffprobe prints no codec string for HEVC, so the oracle is what it does print: Main profile (hvc1.1.6) and the level, as a decimal after L.
            #expect(probe["profile"] == "Main" && video.mime.hasPrefix("video/mp4; codecs=\"hvc1.1.6.L\(probe["level"] ?? "?")"), "\(video.mime)")
        }
    }

    @Test(.enabled(if: ArchiveMediaFixtures.capture != nil, "the private Tapo capture is not here (Tools/captures/tapo.h264 or CAMERABRIDGE_TAPO_CAPTURE)"))
    func theTapoCaptureDecodesAndHasTheCaptureMime() throws {
        let directory = try TemporaryDirectory(prefix: "cb-archive-media")
        defer { directory.remove() }
        let capture = try #require(ArchiveMediaFixtures.capture)
        let frames = try #require(ArchiveMediaFixtures.h264Frames(annexB: capture, ticks: 4_500))
        #expect(frames.count == 208 && frames.filter(\.isKeyframe).count == 6)
        for (label, file) in try variants(frames, cutEvery: 50, soundSeconds: 11) {
            let (video, _, codec) = try verify(file, label: "capture-\(label)", in: directory, rate: "20/1")
            #expect(video.mime == "video/mp4; codecs=\"avc1.4d0032\"" && codec == "avc1.4d0032")
            #expect(video.width == 2688 && video.height == 1520)
        }
    }
}
