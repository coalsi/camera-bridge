import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// Cuts ffmpeg's YUV4MPEG2 output (a header line, then "FRAME" lines each followed by one `yuv420p` picture) into pictures. Y4M
/// rather than bare `rawvideo`: ffmpeg's rawvideo muxer holds each picture back until the next one arrives.
struct Y4MPictureReader {
    let width: Int
    let height: Int
    private var buffer = Data()
    private var sawHeader = false
    /// The stream was not Y4M of this size.
    private(set) var failed = false
    var pictureBytes: Int { RawVideoFrame.byteCount(width: width, height: height) }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    mutating func push(_ data: Data) -> [Data] {
        guard !failed, !data.isEmpty else { return [] }
        buffer.append(data)
        var offset = 0
        var pictures: [Data] = []
        let newline = UInt8(ascii: "\n")
        if !sawHeader {
            guard let end = buffer.firstIndex(of: newline) else {
                if buffer.count > 4_096 { failed = true }
                return []
            }
            let header = String(decoding: buffer[0..<end], as: UTF8.self)
            let fields = header.split(separator: " ")
            guard fields.first == "YUV4MPEG2",
                  let w = fields.first(where: { $0.hasPrefix("W") }).flatMap({ Int($0.dropFirst()) }),
                  let h = fields.first(where: { $0.hasPrefix("H") }).flatMap({ Int($0.dropFirst()) }), w == width, h == height else {
                failed = true
                buffer = Data()
                return []
            }
            sawHeader = true
            offset = end + 1
        }
        let size = pictureBytes
        while true {
            let remaining = buffer.count - offset
            guard remaining > 0 else { break }
            // "FRAME" plus optional parameters, then a newline.
            guard let end = buffer[offset..<min(buffer.count, offset + 256)].firstIndex(of: newline) else {
                if remaining >= 256 { failed = true }
                break
            }
            guard buffer[offset..<min(end, offset + 5)].elementsEqual("FRAME".utf8) else {
                failed = true
                break
            }
            guard buffer.count - (end + 1) >= size else { break }
            pictures.append(Data(buffer[(end + 1)..<(end + 1 + size)]))
            offset = end + 1 + size
        }
        buffer = offset >= buffer.count ? Data() : Data(buffer[offset...])
        return pictures
    }

    var bufferedBytes: Int { buffer.count }
}

/// H.264/HEVC → raw pictures with one ffmpeg child (FLV in on stdin, `yuv420p` out on stdout as Y4M).
///
/// `decode` writes the frame and waits (bounded) for the picture that comes out, so for a stream without reordering it returns
/// that frame's own picture; with reordering it returns nil while the decoder holds frames back, and the newest picture when several
/// are ready. Presentation times are matched to pictures in order: the k-th picture out has the k-th smallest time of the frames
/// that went in (exact unless ffmpeg drops a frame it could not decode, then the times of that stretch are off by one frame).
/// Start-up (process, probe, first picture) may take a second; after the first picture a frame that yields none costs 0.4 s.
/// Calls are taken one at a time, in order. A parameter-set change starts a new child; a child that dies throws and is replaced by the next keyframe.
///
/// With `keepEvery` N above 1 (the sky detector's decoder) the child makes a picture of frames 0, N, 2N, … only, counted from the first
/// frame it is given (a keyframe): `decode` returns nil at once for any other frame, without waiting, and a kept picture takes the time of
/// its own frame (the N − 1 times before it go with it). A stream with reordering (a frame with a decode time before its presentation time)
/// is not waited for at all: its pictures come out frames late, and the call that brings one hands it over.
///
/// On the GPU (`hardwareWhenHeavy`): only a stream that is heavy on the CPU (HEVC, or larger than 1080p) and that the GPU's decoder takes
/// (`fitsHardware`). If the GPU's session ends before its first picture, streams like that one are decoded in software for 10 minutes, and the GPU
/// is tried again after that (`FFmpegRuntime.noteHardwareDecodeFailure`); `decodingPlace` says which.
final class FFmpegVideoDecoder: VideoDecoding, @unchecked Sendable {
    private final class Pipeline: @unchecked Sendable {
        let session: FFmpegSession
        var stream: VideoFLVStream
        var reader: Y4MPictureReader
        let format: VideoFormat
        /// The child decodes on the GPU.
        let hardware: Bool
        /// The child makes a picture of every Nth frame it is given (1: of every one).
        let keepEvery: Int
        /// Presentation times of the frames written and not yet matched to a picture, ascending.
        var pending: [MediaTime] = []
        var pictures = 0
        /// Frames written to the child.
        var written = 0
        /// A frame had a decode time before its presentation time.
        var reordered = false

        init(session: FFmpegSession, stream: VideoFLVStream, reader: Y4MPictureReader, format: VideoFormat, hardware: Bool, keepEvery: Int) {
            self.session = session
            self.stream = stream
            self.reader = reader
            self.format = format
            self.hardware = hardware
            self.keepEvery = keepEvery
        }

        deinit { session.terminate() }

        /// The newest picture among those ready now.
        func collect() -> RawVideoFrame? {
            var newest: RawVideoFrame?
            for data in reader.push(session.drain()) {
                // A kept picture stands for N frames: the N − 1 before it (their pictures were dropped) are owed their times first.
                if pictures > 0, keepEvery > 1 { pending.removeFirst(min(keepEvery - 1, max(0, pending.count - 1))) }
                let pts: MediaTime
                if pending.isEmpty { pts = MediaTime(value: 0, timescale: 90_000) } else { pts = pending.removeFirst() }
                newest = RawVideoFrame(width: reader.width, height: reader.height, pts: pts, pixels: data)
                pictures += 1
            }
            return newest
        }
    }

    private struct State {
        var pipeline: Pipeline?
        var invalidated = false
    }

    static let firstPictureTimeout = Duration.seconds(6)
    static let pictureTimeout = Duration.milliseconds(400)

    private let runtime: FFmpegRuntime
    private let sessionLogLevel: LogLevel
    private let lowPriority: Bool
    private let state: Mutex<State>
    private let live = Mutex<FFmpegSession?>(nil)
    private let invalidatedFlag = Atomic<Bool>(false)
    private let gate = AsyncGate()
    private let log = Log(category: "VideoDecoder")
    private let initialFormat: VideoFormat
    /// Pictures come out at most this wide (the aspect kept); nil: the stream's size.
    private let maxOutputWidth: Int?
    /// Decode on the GPU (VA-API, when usable) for a stream that is heavy on the CPU: HEVC, or larger than 1080p.
    private let hardwareWhenHeavy: Bool
    /// Only every Nth picture is made (at least 1).
    private let keepEvery: Int
    /// The child runs under `nice -n <niceness>` (nil: as the engine does).
    private let niceness: Int?
    /// Scale with a good downscale filter (`FFmpegArguments.decoder`).
    private let highQualityScaling: Bool
    /// Where the current (or last) pipeline decodes; apart from `state` so that a status line never waits for a decode.
    private let place = Mutex<DecodingPlace?>(nil)

    /// Motion detection's picture width (it analyses a 320-pixel thumbnail of it).
    static let motionPictureWidth = 640

    /// The sky detector's decoders run at this niceness (`nice -n 10`, as the clip conversions do): live video and recordings keep the box's cores.
    static let skyNiceness = 10

    init(runtime: FFmpegRuntime, format: VideoFormat, sessionLogLevel: LogLevel = .info, lowPriority: Bool = false, maxOutputWidth: Int? = nil,
         hardwareWhenHeavy: Bool = false, keepEvery: Int = 1, niceness: Int? = nil, highQualityScaling: Bool = false) throws {
        _ = try runtime.requireExecutable()
        guard format.width > 0, format.height > 0, FLVWriter.videoSequenceHeader(format) != nil else {
            throw MediaCodecError.unsupported("video format \(format.codec.rawValue) \(format.width)×\(format.height) with \(format.parameterSets.count) parameter sets")
        }
        self.runtime = runtime
        self.sessionLogLevel = sessionLogLevel
        self.lowPriority = lowPriority
        self.maxOutputWidth = maxOutputWidth
        self.hardwareWhenHeavy = hardwareWhenHeavy
        self.keepEvery = max(1, keepEvery)
        self.niceness = niceness
        self.highQualityScaling = highQualityScaling
        initialFormat = format
        state = Mutex(State())
    }

    deinit { invalidate() }

    var decodingPlace: DecodingPlace? { place.withLock { $0 } }

    func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
        try await gate.run { try await self.decodeNow(frame) }
    }

    private func decodeNow(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
        let (pipeline, already, waits) = try state.withLock { state -> (Pipeline?, Int, Bool) in
            guard !invalidatedFlag.load(ordering: .relaxed) else { return (nil, 0, false) }
            let pipeline = try prepare(for: frame, state: &state)
            guard let pipeline else { return (nil, 0, false) }
            let request = pipeline.pictures
            let index = pipeline.written
            pipeline.written += 1
            if let decodeTime = frame.dts, decodeTime != frame.pts { pipeline.reordered = true }
            do {
                let (data, _) = pipeline.stream.tag(for: frame, requestKeyframe: false)
                pipeline.pending.append(frame.pts)
                pipeline.pending.sort()
                try pipeline.session.send(data)
            } catch {
                let failure = pipeline.session.exit != nil ? pipeline.session.failure : (error as? MediaCodecError) ?? .unsupported("\(error)")
                noteHardwareFailure(of: pipeline)
                drop(pipeline, state: &state)
                throw failure
            }
            // The picture of a frame that is not kept never comes: nothing to wait for. (A picture of one that is may come frames late
            // when the stream has reordering; then no call waits, and the call that brings it hands it over.)
            let waits = pipeline.keepEvery <= 1 || (index % pipeline.keepEvery == 0 && !pipeline.reordered)
            return (pipeline, request, waits)
        }
        guard let pipeline else { return nil }
        guard waits else { return try poll(pipeline) }
        let timeout = already == 0 ? Self.firstPictureTimeout : Self.pictureTimeout
        let deadline = ContinuousClock.now + timeout
        while true {
            if let picture = try poll(pipeline) { return picture }
            guard ContinuousClock.now < deadline, !invalidatedFlag.load(ordering: .relaxed) else { return nil }
            await pipeline.session.waitForOutputAsync(timeout: .milliseconds(20))
            try Task.checkCancellation()
        }
    }

    /// The picture that is ready now, if any; a child that ended with nothing left to read throws its failure and is dropped.
    private func poll(_ pipeline: Pipeline) throws -> RawVideoFrame? {
        try state.withLock { state -> RawVideoFrame? in
            let picture = pipeline.collect()
            if picture == nil, pipeline.session.exit != nil, pipeline.session.bufferedOutputBytes == 0 {
                let failure = pipeline.session.failure
                noteHardwareFailure(of: pipeline)
                drop(pipeline, state: &state)
                throw failure
            }
            return picture
        }
    }

    func invalidate() {
        invalidatedFlag.store(true, ordering: .relaxed)
        live.withLock { session in
            session?.terminate()
            session = nil
        }
        state.withLockIfAvailable { $0.pipeline = nil }
    }

    // MARK: Private

    /// The running pipeline for `frame`, a new one when the stream changed or none runs; nil for a delta frame with nothing to start from.
    private func prepare(for frame: EncodedVideoFrame, state: inout State) throws -> Pipeline? {
        if let pipeline = state.pipeline {
            if pipeline.session.exit == nil, Self.sameStream(pipeline.format, frame.format) { return pipeline }
            if pipeline.session.exit == nil, !frame.isKeyframe { return nil }   // wait for the new stream's keyframe
            drop(pipeline, state: &state)
        }
        guard frame.isKeyframe else { return nil }
        let executable = try runtime.requireExecutable()
        let format = frame.format
        let stream = VideoFLVStream(format: format)
        guard let header = stream.header else {
            throw MediaCodecError.unsupported("the stream's parameter sets cannot be described to ffmpeg")
        }
        // CPU decoding by default: on the reference box (N150, five H.264 cameras) decoding on the GPU saved nothing measurable and copying
        // the pictures back cost a little (2026-10-14). A heavy stream (HEVC, above 1080p) decoded all the time is where it pays, if the GPU's
        // decoder takes it (Intel's H.264 one stops at 4096 wide or tall) and has not already failed on a stream like it.
        let hardware = hardwareWhenHeavy && Self.isHeavy(format) && Self.fitsHardware(format) ? runtime.hardwareDecodeDevice(for: format) : nil
        let output = Self.outputSize(width: format.width, height: format.height, maxWidth: maxOutputWidth)
        let spec = FFmpegProcessSpec(executable: executable,
                                     arguments: FFmpegArguments.decoder(width: output.width, height: output.height, hardwareDevice: hardware,
                                                                        keepEvery: keepEvery, highQualityScaling: highQualityScaling),
                                     label: "video decoder", niceness: niceness)
        let session = try FFmpegSession(launcher: runtime.launcher, spec: spec)
        do {
            try session.send(header)
        } catch {
            if hardware != nil, let exit = session.exit { runtime.noteHardwareDecodeFailure(format, reason: exit.stderrTail.last) }
            session.terminate()
            throw error
        }
        let pipeline = Pipeline(session: session, stream: stream, reader: Y4MPictureReader(width: output.width, height: output.height),
                                format: format, hardware: hardware != nil, keepEvery: keepEvery)
        state.pipeline = pipeline
        live.withLock { $0 = session }
        place.withLock { $0 = hardware != nil ? .gpu : .software }
        let message = "ffmpeg video decoder started: \(format.codec.rawValue) \(format.width)×\(format.height)"
            + (output.width != format.width ? " → \(output.width)×\(output.height)" : "") + (hardware != nil ? " on the GPU" : "")
            + (keepEvery > 1 ? ", every \(keepEvery)th picture" : "")
        if sessionLogLevel <= .debug { log.debug(message) } else { log.info(message) }
        return pipeline
    }

    /// A GPU session that ended before its first picture: streams like this one are decoded in software for a while.
    private func noteHardwareFailure(of pipeline: Pipeline) {
        guard pipeline.hardware, pipeline.pictures == 0, let exit = pipeline.session.exit else { return }
        runtime.noteHardwareDecodeFailure(pipeline.format, reason: exit.stderrTail.last)
    }

    private func drop(_ pipeline: Pipeline, state: inout State) {
        pipeline.session.terminate()
        live.withLock { $0 = nil }
        if state.pipeline === pipeline { state.pipeline = nil }
    }

    /// HEVC, or more pixels than 1080p.
    static func isHeavy(_ format: VideoFormat) -> Bool {
        format.codec == .hevc || format.width * format.height > 1920 * 1088
    }

    /// Whether the GPU's decoder takes a stream of this size at all: Intel's H.264 decoder stops at 4096 pixels wide or tall (a camera's
    /// 4256×1888 H.264 cannot go to the GPU), its HEVC decoder at 8192.
    static func fitsHardware(_ format: VideoFormat) -> Bool {
        let limit = format.codec == .hevc ? 8192 : 4096
        return format.width <= limit && format.height <= limit
    }

    /// The picture size for `maxWidth` (even numbers, the aspect kept); the stream's own size when it is not wider.
    static func outputSize(width: Int, height: Int, maxWidth: Int?) -> (width: Int, height: Int) {
        guard let maxWidth, width > maxWidth, width > 0 else { return (width, height) }
        let scaled = Int((Double(height) * Double(maxWidth) / Double(width)).rounded())
        return (maxWidth & ~1, max(2, scaled & ~1))
    }

    private static func sameStream(_ a: VideoFormat, _ b: VideoFormat) -> Bool {
        guard a.codec == b.codec, a.width == b.width, a.height == b.height else { return false }
        let significant = a.codec == .hevc ? 2 : 1
        return Array(a.parameterSets.prefix(significant)) == Array(b.parameterSets.prefix(significant))
    }
}
