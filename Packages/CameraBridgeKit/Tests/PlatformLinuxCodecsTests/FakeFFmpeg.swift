import Foundation
import MediaCore
import Synchronization
@testable import PlatformLinux

/// A process layer without processes: records what would have been run and written, and lets the test play ffmpeg's part
/// (stdout bytes, exit).
final class FakeFFmpegLauncher: FFmpegProcessLaunching, @unchecked Sendable {
    final class Child: FFmpegProcess, @unchecked Sendable {
        let spec: FFmpegProcessSpec
        private let lock = NSLock()
        private var written = Data()
        private(set) var inputClosed = false
        private(set) var terminated = false
        private var stderrTail: [String] = []
        private let onOutput: @Sendable (Data) -> Void
        private let onExit: @Sendable (FFmpegExit) -> Void
        /// Throws from `write` once set (a child that closed its stdin).
        var failWrites = false
        /// Called with every write, outside the lock (a scripted ffmpeg answers from here).
        var onWrite: (@Sendable (Child, Data) -> Void)?

        init(spec: FFmpegProcessSpec, onOutput: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (FFmpegExit) -> Void) {
            self.spec = spec
            self.onOutput = onOutput
            self.onExit = onExit
        }

        func write(_ data: Data) throws {
            lock.lock()
            if failWrites || terminated || inputClosed {
                lock.unlock()
                throw MediaCodecError.unsupported("fake child is not accepting input")
            }
            written.append(data)
            lock.unlock()
            onWrite?(self, data)
        }

        func closeInput() {
            lock.lock()
            inputClosed = true
            lock.unlock()
        }

        func terminate() {
            lock.lock()
            let first = !terminated
            terminated = true
            lock.unlock()
            if first { onExit(FFmpegExit(status: 15, signaled: true, stderrTail: stderrTail)) }
        }

        var input: Data {
            lock.lock()
            defer { lock.unlock() }
            return written
        }

        var arguments: [String] { spec.arguments }

        func emit(_ data: Data) { onOutput(data) }

        func addStderr(_ line: String) {
            lock.lock()
            stderrTail.append(line)
            lock.unlock()
        }

        /// The child ends by itself.
        func exit(status: Int32, stderr: [String] = []) {
            lock.lock()
            let lines = stderrTail + stderr
            lock.unlock()
            onExit(FFmpegExit(status: status, signaled: false, stderrTail: lines))
        }
    }

    private let state = Mutex<[Child]>([])
    /// Called after a child was launched (to script it).
    var onLaunch: (@Sendable (Child) -> Void)?
    var launchFailure: (any Error)?

    var children: [Child] { state.withLock { $0 } }

    func launch(_ spec: FFmpegProcessSpec, onOutput: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (FFmpegExit) -> Void) throws -> any FFmpegProcess {
        if let launchFailure { throw launchFailure }
        let child = Child(spec: spec, onOutput: onOutput, onExit: onExit)
        state.withLock { $0.append(child) }
        onLaunch?(child)
        return child
    }
}

/// Plays ffmpeg's encoder: the answer to a video pipeline's stdin, as FLV on stdout.
struct FakeEncoderOutput {
    let format: VideoFormat

    func header() -> Data {
        FLVWriter.fileHeader(video: true, audio: false) + (FLVWriter.videoSequenceHeader(format) ?? Data())
    }

    func frame(ptsMs: UInt32, keyframe: Bool, size: Int = 20) -> Data {
        FLVWriter.videoFrame(format: format, nalUnits: [Data([keyframe ? 0x65 : 0x41]) + Data(repeating: 7, count: size)], isKeyframe: keyframe,
                             dtsMs: ptsMs, ptsMs: ptsMs, inBandParameterSets: false)
    }
}

enum TestFormats {
    static let sps = Data([0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x01, 0x40, 0x16, 0xE8, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x0C, 0x23, 0xC6, 0x0C, 0x92])
    static let pps = Data([0x68, 0xCE, 0x31, 0x52])
    static var h264: VideoFormat { VideoFormat.h264(sps: sps, pps: pps)! }

    /// A source frame at `index` of a stream at 25 fps starting at 90 kHz time 0.
    static func frame(_ index: Int, key: Bool, format: VideoFormat? = nil, fps: Int = 25) -> EncodedVideoFrame {
        EncodedVideoFrame(format: format ?? h264, nalUnits: [Data([key ? 0x65 : 0x41]) + Data(repeating: UInt8(index & 0x7F), count: 30)], isKeyframe: key,
                          pts: MediaTime(value: Int64(index) * 90_000 / Int64(fps), timescale: 90_000), wallClock: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) / Double(fps)))
    }
}

extension FFmpegMediaCodecs {
    /// Codecs over a fake launcher that pretends ffmpeg is installed with libx264, drawtext, Opus and AAC.
    static func fake(_ launcher: FakeFFmpegLauncher, configuration: FFmpegCodecsConfiguration = FFmpegCodecsConfiguration(fontFile: TestFonts.path),
                     deviceExists: @escaping @Sendable (String) -> Bool = { _ in false }) -> FFmpegMediaCodecs {
        launcher.onLaunch = { child in
            // The capability probe: answer `-encoders` and `-filters`.
            if child.arguments.contains("-encoders") {
                child.emit(Data(FakeListings.encoders.utf8))
                child.exit(status: 0)
            } else if child.arguments.contains("-decoders") {
                child.emit(Data(FakeListings.decoders.utf8))
                child.exit(status: 0)
            } else if child.arguments.contains("-filters") {
                child.emit(Data(FakeListings.filters.utf8))
                child.exit(status: 0)
            } else if child.arguments.contains("-version") {
                child.emit(Data("ffmpeg version 7.1.1-fake Copyright (c) 2000-2025 the FFmpeg developers\n".utf8))
                child.exit(status: 0)
            }
        }
        return FFmpegMediaCodecs(configuration: configuration, launcher: launcher, executable: URL(fileURLWithPath: "/usr/bin/ffmpeg"), deviceExists: deviceExists)
    }
}

enum FakeListings {
    static let encoders = """
    Encoders:
     V..... = Video
     A..... = Audio
     ------
     V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
     V....D h264_vaapi           H.264/AVC (VAAPI) (codec h264)
     VFS... mjpeg                MJPEG (Motion JPEG)
     A....D aac                  AAC (Advanced Audio Coding)
     A....D libopus              libopus Opus (codec opus)
     A....D pcm_alaw             PCM A-law / G.711 A-law
    """
    static let decoders = """
    Decoders:
     ------
     VFS..D h264                 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10
    """
    static let filters = """
    Filters:
      T.. = Timeline support
      .S. = Slice threading
      ..C = Command support
      A = Audio input/output
      V = Video input/output
      N = Dynamic number and/or type of input/output
      | = Source or sink filter
     ... abench            A->A       Benchmark part of a filtergraph.
     ... scale             V->V       Scale the input video size and/or convert the image format.
     T.C drawtext          V->V       Draw text on top of video frames using libfreetype library.
     ... testsrc           |->V       Generate test pattern.
    """
}

enum TestFonts {
    /// An existing file the fake ffmpeg is told is a font (the overlay code only needs the path to be a readable file).
    static let path: String = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-bridge-test-font.ttf")
        try? Data("not a font".utf8).write(to: url)
        return url.path
    }()
}
