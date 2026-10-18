import BridgeSupport
import Foundation
import MediaCore
import TestSupport
import Testing

/// What the decode tests add to the fixtures: pictures from an Annex B stream, and ffmpeg and ffprobe to decode what `ArchiveMedia` made.
extension ArchiveMediaFixtures {
    // MARK: Pictures from an Annex B stream (ffmpeg's or the capture)

    /// Pictures of an Annex B stream with single-slice pictures: parameter sets, SEI and delimiters are dropped (the format carries the parameter sets),
    /// every slice NAL unit is a picture and an IDR slice a keyframe. Picture `i` is at `i * ticks`. nil when the stream has no SPS and PPS.
    static func h264Frames(annexB stream: Data, ticks: Int64) -> [EncodedVideoFrame]? {
        let units = NALUnits.splitAnnexB(stream)
        guard let sps = units.first(where: { NALUnits.h264Type($0) == 7 }), let pps = units.first(where: { NALUnits.h264Type($0) == 8 }),
              let format = VideoFormat.h264(sps: sps, pps: pps) else { return nil }
        let slices = units.filter { [1, 5].contains(NALUnits.h264Type($0)) }
        return slices.enumerated().map { index, nal in
            EncodedVideoFrame(format: format, nalUnits: [nal], isKeyframe: NALUnits.h264Type(nal) == 5,
                              pts: MediaTime(value: Int64(index) * ticks, timescale: 90_000),
                              wallClock: Date(timeIntervalSince1970: 1_800_000_000 + Double(Int64(index) * ticks) / 90_000))
        }
    }

    /// As `h264Frames` for an HEVC stream (VPS 32, SPS 33, PPS 34; slice NAL types 0...31, IRAP 16...23 are keyframes).
    static func hevcFrames(annexB stream: Data, ticks: Int64) -> [EncodedVideoFrame]? {
        let units = NALUnits.splitAnnexB(stream)
        guard let vps = units.first(where: { NALUnits.hevcType($0) == 32 }), let sps = units.first(where: { NALUnits.hevcType($0) == 33 }),
              let pps = units.first(where: { NALUnits.hevcType($0) == 34 }), let format = VideoFormat.hevc(vps: vps, sps: sps, pps: pps) else { return nil }
        let slices = units.filter { NALUnits.hevcType($0) < 32 }
        return slices.enumerated().map { index, nal in
            EncodedVideoFrame(format: format, nalUnits: [nal], isKeyframe: (16...23).contains(NALUnits.hevcType(nal)),
                              pts: MediaTime(value: Int64(index) * ticks, timescale: 90_000),
                              wallClock: Date(timeIntervalSince1970: 1_800_000_000 + Double(Int64(index) * ticks) / 90_000))
        }
    }

    /// The private Tapo capture: `Tools/captures/tapo.h264` in the repository (the folder is not committed and a worktree does not have it), else the file
    /// named by `CAMERABRIDGE_TAPO_CAPTURE`. nil when absent; the tests that need it are then skipped.
    static let capture: Data? = {
        let fallback = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Tools/captures/tapo.h264").standardizedFileURL.path
        let path = ProcessInfo.processInfo.environment["CAMERABRIDGE_TAPO_CAPTURE"] ?? fallback
        return FileManager.default.fileExists(atPath: path) ? try? Data(contentsOf: URL(fileURLWithPath: path)) : nil
    }()
}

/// ffmpeg and ffprobe for the decode tests: `CB_FFMPEG` / `CB_FFPROBE`, else Homebrew and system locations. The tests are skipped without them.
enum ArchiveMediaTools {
    static let ffmpeg = locate("ffmpeg", variable: "CB_FFMPEG")
    static let ffprobe = locate("ffprobe", variable: "CB_FFPROBE")
    static var available: Bool { ffmpeg != nil && ffprobe != nil }

    /// Whether this ffmpeg can encode with `encoder` (libx265 is optional).
    static func canEncode(_ encoder: String) -> Bool {
        guard let output = try? run(ffmpeg, ["-hide_banner", "-encoders"]) else { return false }
        return output.text.split(separator: "\n").contains { $0.split(separator: " ").dropFirst().first == Substring(encoder) }
    }

    private static func locate(_ name: String, variable: String) -> URL? {
        let candidates = [ProcessInfo.processInfo.environment[variable], "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    struct Output { var status: Int32; var text: String; var errors: String }

    /// Runs `tool` with its output in temporary files, and stops it after `timeout` seconds.
    @discardableResult
    static func run(_ tool: URL?, _ arguments: [String], timeout: TimeInterval = 60) throws -> Output {
        let tool = try #require(tool, "ffmpeg tools not found; set CB_FFMPEG and CB_FFPROBE")
        let scratch = try TemporaryDirectory(prefix: "cb-archive-media-tool")
        defer { scratch.remove() }
        let standardOutput = scratch.file("out.txt"), standardError = scratch.file("err.txt")
        FileManager.default.createFile(atPath: standardOutput.path, contents: nil)
        FileManager.default.createFile(atPath: standardError.path, contents: nil)
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: standardOutput)
        process.standardError = try FileHandle(forWritingTo: standardError)
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        return Output(status: process.terminationStatus, text: String(decoding: try Data(contentsOf: standardOutput), as: UTF8.self),
                      errors: String(decoding: try Data(contentsOf: standardError), as: UTF8.self))
    }

    /// An Annex B elementary stream of ffmpeg's test pattern: `frames` pictures at `rate` (a fraction such as `30000/1001`), a keyframe every `gop`,
    /// no B-frames, one slice per picture.
    static func encode(codec: VideoCodec, size: String, rate: String, frames: Int, gop: Int, in directory: TemporaryDirectory) throws -> Data {
        let output = directory.file("source-\(UUID().uuidString).\(codec == .h264 ? "h264" : "hevc")")
        let video: [String] = switch codec {
        case .h264: ["-c:v", "libx264", "-preset", "ultrafast", "-g", "\(gop)", "-keyint_min", "\(gop)", "-sc_threshold", "0", "-bf", "0",
                     "-x264-params", "slices=1", "-pix_fmt", "yuv420p", "-f", "h264"]
        case .hevc: ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error:keyint=\(gop):min-keyint=\(gop):bframes=0:scenecut=0:repeat-headers=1",
                     "-pix_fmt", "yuv420p", "-f", "hevc"]
        }
        let result = try run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=\(rate)",
                                      "-frames:v", "\(frames)"] + video + [output.path])
        try #require(result.status == 0, "ffmpeg could not make the test stream: \(result.errors)")
        return try Data(contentsOf: output)
    }

    /// What ffprobe says about the video stream of `file`: the number of pictures it decodes (`-count_frames`), `r_frame_rate` and the others in `fields`.
    static func probe(_ file: URL, fields: [String]) throws -> [String: String] {
        let result = try run(ffprobe, ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries",
                                       "stream=" + (fields + ["nb_read_frames"]).joined(separator: ","), "-of", "flat", file.path])
        try #require(result.status == 0, "ffprobe failed: \(result.errors)")
        var values: [String: String] = [:]
        for line in result.text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[String(parts[0].split(separator: ".").last ?? "")] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return values
    }

    /// Bytes 1 to 3 of the avcC ffprobe reads for the video stream of `file` (AVCProfileIndication, profile_compatibility, AVCLevelIndication): what
    /// ffprobe 8.1 makes `mime_codec_string` from. Read from the extradata every ffprobe prints with `-show_data` (`00000000: 014d 0032 ...`, 16 bytes a
    /// line, their hexadecimal in the 41 columns after the offset), so an ffprobe before 8.1, which prints no codec string, still says it. nil when the
    /// extradata is not an avcC.
    static func avcConfiguration(_ file: URL) throws -> (profile: UInt8, compatibility: UInt8, level: UInt8)? {
        let result = try run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_data", "-show_entries", "stream=extradata",
                                       "-of", "default=noprint_wrappers=1:nokey=1", file.path])
        try #require(result.status == 0, "ffprobe failed: \(result.errors)")
        guard let line = result.text.split(separator: "\n").first(where: { $0.hasPrefix("00000000: ") }) else { return nil }
        var digits = Substring(line.dropFirst(10).prefix(41).filter { $0 != " " })
        var bytes: [UInt8] = []
        while digits.count >= 2, let byte = UInt8(digits.prefix(2), radix: 16) {
            bytes.append(byte)
            digits = digits.dropFirst(2)
        }
        guard bytes.count >= 4, bytes[0] == 1 else { return nil }
        return (bytes[1], bytes[2], bytes[3])
    }

    /// The profile_idc of the H.264 profile names ffprobe prints (libavcodec's; a constrained or intra profile has the profile_idc it constrains).
    static let avcProfiles: [String: UInt8] = ["Constrained Baseline": 66, "Baseline": 66, "Main": 77, "Extended": 88, "High": 100, "High 10": 110,
                                               "High 10 Intra": 110, "High 4:2:2": 122, "High 4:2:2 Intra": 122, "High 4:4:4 Predictive": 244,
                                               "High 4:4:4 Intra": 244]

    /// The number of streams in `file`.
    static func streamCount(_ file: URL) throws -> Int {
        let result = try run(ffprobe, ["-v", "error", "-show_entries", "stream=index", "-of", "csv=p=0", file.path])
        return result.text.split(separator: "\n").count
    }

    /// Decodes every picture of `file` and treats any decoder message as a failure: ffmpeg's exit status and stderr.
    static func decodeErrors(_ file: URL) throws -> String {
        let result = try run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-xerror", "-i", file.path, "-f", "null", "-"])
        return result.status == 0 ? result.errors : "exit \(result.status): \(result.errors)"
    }
}
