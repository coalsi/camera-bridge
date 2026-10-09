import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// Raw pictures (`RawVideoFrame`) → H.264 with one ffmpeg child (`yuv420p` on stdin, FLV on stdout).
///
/// Each `encode` writes the picture and waits (bounded) for the access unit that comes out, so it returns one frame per picture
/// with the picture's PTS (zerolatency x264 has no lookahead and no B-frames; pictures and frames match in order). A forced
/// keyframe starts a fresh child, whose first picture is an IDR (ffmpeg takes no commands while it runs); so does a picture of
/// another size or a PTS more than 1 s before the previous one (a new source timeline), as `AppleVideoEncoder` starts a new
/// session then. Pictures of another size than `settings` are scaled with bars (letterboxed) inside ffmpeg.
final class FFmpegVideoEncoder: VideoEncoding, @unchecked Sendable {
    private final class Pipeline: @unchecked Sendable {
        let session: FFmpegSession
        var output: H264FLVOutput
        let inputWidth: Int
        let inputHeight: Int
        /// PTS and wall clock of the pictures written and not yet encoded.
        var queue: [(pts: MediaTime, wallClock: Date)] = []
        var lastPTS: MediaTime?
        var produced = 0

        init(session: FFmpegSession, output: H264FLVOutput, inputWidth: Int, inputHeight: Int) {
            self.session = session
            self.output = output
            self.inputWidth = inputWidth
            self.inputHeight = inputHeight
        }

        deinit { session.terminate() }

        func collect() -> [EncodedVideoFrame] {
            let packets = output.push(session.drain())
            guard let format = output.format else { return [] }
            return packets.map { packet in
                let entry = queue.isEmpty ? (pts: MediaTime(value: 0, timescale: 90_000), wallClock: Date()) : queue.removeFirst()
                produced += 1
                return EncodedVideoFrame(format: format, nalUnits: packet.nalUnits, isKeyframe: packet.isKeyframe, pts: entry.pts, dts: nil, wallClock: entry.wallClock)
            }
        }
    }

    static let firstFrameTimeout = Duration.seconds(8)
    static let frameTimeout = Duration.seconds(2)
    static let timelineRestart = 1.0

    private let runtime: FFmpegRuntime
    private let settings: VideoEncoderSettings
    private let backend: FFmpegVideoBackend
    private let state = Mutex<Pipeline?>(nil)
    private let live = Mutex<FFmpegSession?>(nil)
    private let invalidatedFlag = Atomic<Bool>(false)
    private let gate = AsyncGate()
    private let log = Log(category: "VideoEncoder")

    init(runtime: FFmpegRuntime, settings: VideoEncoderSettings) throws {
        guard settings.width > 1, settings.height > 1, settings.fps > 0, settings.bitrateKbps > 0 else {
            throw MediaCodecError.unsupported("encoder settings \(settings.width)×\(settings.height) @ \(settings.fps) fps, \(settings.bitrateKbps) kbit/s")
        }
        _ = try runtime.requireExecutable()
        var even = settings
        even.width &= ~1
        even.height &= ~1
        self.runtime = runtime
        self.settings = even
        backend = try runtime.videoBackend()
    }

    deinit { invalidate() }

    func encode(_ frame: any DecodedVideoFrame, wallClock: Date, forceKeyframe: Bool) async throws -> [EncodedVideoFrame] {
        try await gate.run { try await self.encodeNow(frame, wallClock: wallClock, forceKeyframe: forceKeyframe) }
    }

    private func encodeNow(_ frame: any DecodedVideoFrame, wallClock: Date, forceKeyframe: Bool) async throws -> [EncodedVideoFrame] {
        guard let picture = frame as? RawVideoFrame else {
            throw MediaCodecError.unsupported("FFmpegVideoEncoder encodes RawVideoFrame pictures only")
        }
        guard picture.isComplete else { throw MediaCodecError.unsupported("picture \(picture.width)×\(picture.height) holds \(picture.pixels.count) bytes") }
        guard !invalidatedFlag.load(ordering: .relaxed) else { return [] }
        let (pipeline, expected) = try state.withLock { current -> (Pipeline, Int) in
            var pipeline = current
            if let existing = pipeline {
                let newTimeline = existing.lastPTS.map { $0.seconds - picture.pts.seconds > Self.timelineRestart } ?? false
                if forceKeyframe || newTimeline || existing.inputWidth != picture.width || existing.inputHeight != picture.height || existing.session.exit != nil {
                    existing.session.terminate()
                    live.withLock { $0 = nil }
                    pipeline = nil
                }
            }
            let target = try pipeline ?? start(width: picture.width, height: picture.height)
            current = target
            target.lastPTS = picture.pts
            target.queue.append((picture.pts, wallClock))
            let before = target.produced
            do {
                try target.session.send(picture.pixels)
            } catch {
                let failure = target.session.exit != nil ? target.session.failure : (error as? MediaCodecError) ?? .unsupported("\(error)")
                target.session.terminate()
                live.withLock { $0 = nil }
                current = nil
                throw failure
            }
            return (target, before)
        }
        let deadline = ContinuousClock.now + (expected == 0 ? Self.firstFrameTimeout : Self.frameTimeout)
        while true {
            let frames = try state.withLock { _ -> [EncodedVideoFrame] in
                let frames = pipeline.collect()
                if frames.isEmpty, pipeline.session.exit != nil, pipeline.session.bufferedOutputBytes == 0 {
                    let failure = pipeline.session.failure
                    pipeline.session.terminate()
                    live.withLock { $0 = nil }
                    throw failure
                }
                return frames
            }
            if !frames.isEmpty { return frames }
            guard ContinuousClock.now < deadline, !invalidatedFlag.load(ordering: .relaxed) else {
                throw MediaCodecError.unsupported("ffmpeg (video encoder) produced no frame within \((expected == 0 ? Self.firstFrameTimeout : Self.frameTimeout) / .seconds(1)) s")
            }
            await pipeline.session.waitForOutputAsync(timeout: .milliseconds(20))
            try Task.checkCancellation()
        }
    }

    func invalidate() {
        invalidatedFlag.store(true, ordering: .relaxed)
        live.withLock { session in
            session?.terminate()
            session = nil
        }
    }

    private func start(width: Int, height: Int) throws -> Pipeline {
        let executable = try runtime.requireExecutable()
        let spec = VideoPipelineSpec(settings: settings, bitrateKbps: settings.bitrateKbps, backend: backend, sourceWidth: width, sourceHeight: height,
                                     overlay: nil, limitFrameRate: false, skipBeforeSeconds: nil, keyframeRequestsByTimestamp: false)
        let session = try FFmpegSession(launcher: runtime.launcher,
                                        spec: FFmpegProcessSpec(executable: executable, arguments: FFmpegArguments.rawEncoder(spec, inputWidth: width, inputHeight: height),
                                                                label: "video encoder"))
        live.withLock { $0 = session }
        log.info("ffmpeg video encoder started: \(width)×\(height) → H.264 \(settings.width)×\(settings.height) @ \(settings.fps) fps, \(settings.bitrateKbps) kbit/s, \(backend.description)")
        return Pipeline(session: session, output: H264FLVOutput(width: settings.width, height: settings.height), inputWidth: width, inputHeight: height)
    }
}
