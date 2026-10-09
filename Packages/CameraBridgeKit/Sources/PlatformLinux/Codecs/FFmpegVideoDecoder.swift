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
final class FFmpegVideoDecoder: VideoDecoding, @unchecked Sendable {
    private final class Pipeline: @unchecked Sendable {
        let session: FFmpegSession
        var stream: VideoFLVStream
        var reader: Y4MPictureReader
        let format: VideoFormat
        /// Presentation times of the frames written and not yet matched to a picture, ascending.
        var pending: [MediaTime] = []
        var pictures = 0

        init(session: FFmpegSession, stream: VideoFLVStream, reader: Y4MPictureReader, format: VideoFormat) {
            self.session = session
            self.stream = stream
            self.reader = reader
            self.format = format
        }

        deinit { session.terminate() }

        /// The newest picture among those ready now.
        func collect() -> RawVideoFrame? {
            var newest: RawVideoFrame?
            for data in reader.push(session.drain()) {
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

    init(runtime: FFmpegRuntime, format: VideoFormat, sessionLogLevel: LogLevel = .info, lowPriority: Bool = false) throws {
        _ = try runtime.requireExecutable()
        guard format.width > 0, format.height > 0, FLVWriter.videoSequenceHeader(format) != nil else {
            throw MediaCodecError.unsupported("video format \(format.codec.rawValue) \(format.width)×\(format.height) with \(format.parameterSets.count) parameter sets")
        }
        self.runtime = runtime
        self.sessionLogLevel = sessionLogLevel
        self.lowPriority = lowPriority
        initialFormat = format
        state = Mutex(State())
    }

    deinit { invalidate() }

    func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
        try await gate.run { try await self.decodeNow(frame) }
    }

    private func decodeNow(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
        let (pipeline, already) = try state.withLock { state -> (Pipeline?, Int) in
            guard !invalidatedFlag.load(ordering: .relaxed) else { return (nil, 0) }
            let pipeline = try prepare(for: frame, state: &state)
            guard let pipeline else { return (nil, 0) }
            let request = pipeline.pictures
            do {
                let (data, _) = pipeline.stream.tag(for: frame, requestKeyframe: false)
                pipeline.pending.append(frame.pts)
                pipeline.pending.sort()
                try pipeline.session.send(data)
            } catch {
                let failure = pipeline.session.exit != nil ? pipeline.session.failure : (error as? MediaCodecError) ?? .unsupported("\(error)")
                drop(pipeline, state: &state)
                throw failure
            }
            return (pipeline, request)
        }
        guard let pipeline else { return nil }
        let timeout = already == 0 ? Self.firstPictureTimeout : Self.pictureTimeout
        let deadline = ContinuousClock.now + timeout
        while true {
            let picture = try state.withLock { state -> RawVideoFrame? in
                let picture = pipeline.collect()
                if picture == nil, pipeline.session.exit != nil, pipeline.session.bufferedOutputBytes == 0 {
                    let failure = pipeline.session.failure
                    drop(pipeline, state: &state)
                    throw failure
                }
                return picture
            }
            if let picture { return picture }
            guard ContinuousClock.now < deadline, !invalidatedFlag.load(ordering: .relaxed) else { return nil }
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
        let spec = FFmpegProcessSpec(executable: executable, arguments: FFmpegArguments.decoder(width: format.width, height: format.height),
                                     label: "video decoder")
        let session = try FFmpegSession(launcher: runtime.launcher, spec: spec)
        do {
            try session.send(header)
        } catch {
            session.terminate()
            throw error
        }
        let pipeline = Pipeline(session: session, stream: stream, reader: Y4MPictureReader(width: format.width, height: format.height),
                                format: format)
        state.pipeline = pipeline
        live.withLock { $0 = session }
        let message = "ffmpeg video decoder started: \(format.codec.rawValue) \(format.width)×\(format.height)"
        if sessionLogLevel <= .debug { log.debug(message) } else { log.info(message) }
        return pipeline
    }

    private func drop(_ pipeline: Pipeline, state: inout State) {
        pipeline.session.terminate()
        live.withLock { $0 = nil }
        if state.pipeline === pipeline { state.pipeline = nil }
    }

    private static func sameStream(_ a: VideoFormat, _ b: VideoFormat) -> Bool {
        guard a.codec == b.codec, a.width == b.width, a.height == b.height else { return false }
        let significant = a.codec == .hevc ? 2 : 1
        return Array(a.parameterSets.prefix(significant)) == Array(b.parameterSets.prefix(significant))
    }
}
