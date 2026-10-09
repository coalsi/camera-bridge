import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MediaCore
import Synchronization

/// HTTP-FLV (e.g. Reolink `http://<host>/flv?port=1935&app=bcs&stream=channel0_main.bcs`) as a `MediaSource`, read
/// through `AuthenticatingHTTPClient.stream(for:)`.
///
/// The URL is requested as given (Reolink expects `user=`/`password=` query items; `Redact.url` masks them in logs);
/// `credentials` answer HTTP Basic/Digest challenges (Basic never once the camera asked for Digest, also across
/// `samples()` calls: one `BasicDowngradeGuard` per source). Output starts at the first video keyframe; FLV millisecond
/// timestamps become 90 kHz video pts and sample-rate audio pts (AAC spacing kept sample-exact), strictly increasing
/// per track (`TimestampSmoother`). The stream throws on HTTP errors (`RTSPError.unauthorized`, `.notFound`,
/// `.badStatus`), on EOF, and with `RTSPError.timeout` when no data arrives for `timeout`; it finishes normally after
/// `stop()`, and buffers at most `SampleDelivery.bufferLimit` samples for a slow consumer. Network errors are mapped
/// to `TransportError` / `RTSPError` values that never carry the URL (URLSession errors hold the full URL, password
/// included). `stop()`, or a newer `samples()` call, while `samples()` is still connecting cancels that connection:
/// the superseded call throws `TransportError.closed`.
public final class HTTPFLVMediaSource: MediaSource {
    public let displayName: String
    private let url: URL
    private let credentials: HTTPCredentials?
    private let timeout: Duration
    private let log: Log
    private let state = Mutex(State())
    /// Shared by the clients of every `samples()` call: once the camera asked for Digest, no reconnect answers Basic.
    private let downgradeGuard = BasicDowngradeGuard()

    private struct State {
        /// Bumped by every `samples()` and `stop()`: a `samples()` call whose generation is no longer current lost.
        var generation = 0
        var connecting: AuthenticatingHTTPClient?
        var running: Running?
    }

    private struct Running: Sendable {
        var task: Task<Void, Never>
        var continuation: AsyncThrowingStream<MediaSample, any Error>.Continuation
        var stopped: StopFlag
    }

    private final class StopFlag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    public convenience init(url: URL, credentials: HTTPCredentials?, displayName: String) {
        self.init(url: url, credentials: credentials, displayName: displayName, timeout: .seconds(10))
    }

    /// `timeout` bounds the connection and every wait for body data. `cameraID` tags the source's log lines
    /// (`LogEntry.cameraID`), so they show in the camera's own log.
    public init(url: URL, credentials: HTTPCredentials?, displayName: String, timeout: Duration, cameraID: UUID? = nil) {
        self.url = url
        self.credentials = credentials
        self.displayName = displayName
        self.timeout = timeout
        log = Log(category: "flv", cameraID: cameraID)
    }

    public func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        let client = AuthenticatingHTTPClient(credentials: credentials, timeout: timeout, allowSelfSignedTLS: true,
                                              maximumBodySize: AuthenticatingHTTPClient.defaultMaximumBodySize, downgradeGuard: downgradeGuard)
        let (generation, previous) = state.withLock { s in
            s.generation += 1
            defer {
                s.connecting = client
                s.running = nil
            }
            return (s.generation, (s.connecting, s.running))
        }
        Self.cancel(connecting: previous.0, running: previous.1)

        var request = URLRequest(url: url)
        request.setValue("CameraBridge/1.0", forHTTPHeaderField: "User-Agent")
        let response: HTTPURLResponse
        let body: AsyncThrowingStream<Data, any Error>
        do {
            (response, body) = try await client.stream(for: request)
        } catch {
            client.invalidate()
            throw isCurrent(generation, clearing: client) ? Self.sanitized(error) : TransportError.closed
        }
        guard isCurrent(generation, clearing: client) else {   // stopped or superseded while connecting
            client.invalidate()
            throw TransportError.closed
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: client.invalidate(); throw RTSPError.unauthorized
        case 404: client.invalidate(); throw RTSPError.notFound
        default: client.invalidate(); throw RTSPError.badStatus(response.statusCode)
        }
        log.info("HTTP-FLV connected to \(Redact.url(url))")

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self, bufferingPolicy: SampleDelivery.bufferingPolicy)
        let stopped = StopFlag()
        let log = self.log
        let redacted = Redact.url(url)
        let task = Task {
            var demuxer = FLVDemuxer()
            var timeline = FLVTimeline()
            var delivery = SampleDelivery(log: log)
            do {
                for try await chunk in body {
                    let arrival = Date()
                    for sample in try demuxer.append(chunk) {
                        if let mapped = timeline.map(sample, arrival: arrival) { delivery.deliver(mapped, to: continuation) }
                    }
                }
                if stopped.isSet || Task.isCancelled {
                    continuation.finish()
                } else {
                    log.warning("HTTP-FLV stream from \(redacted) ended")
                    continuation.finish(throwing: RTSPError.protocolError("HTTP-FLV stream ended"))
                }
            } catch {
                continuation.finish(throwing: stopped.isSet ? nil : Self.sanitized(error))
            }
            client.invalidate()
        }
        continuation.onTermination = { _ in task.cancel() }
        let running = Running(task: task, continuation: continuation, stopped: stopped)
        let installed = state.withLock { s -> Bool in
            guard s.generation == generation else { return false }
            s.running = running
            return true
        }
        if !installed { Self.cancel(connecting: nil, running: running) }   // stopped in the meantime: finishes normally
        return stream
    }

    public func stop() async {
        let (connecting, running) = state.withLock { s in
            s.generation += 1
            defer {
                s.connecting = nil
                s.running = nil
            }
            return (s.connecting, s.running)
        }
        Self.cancel(connecting: connecting, running: running)
    }

    /// True when `generation` is still the latest; then `client` is no longer tracked as connecting.
    private func isCurrent(_ generation: Int, clearing client: AuthenticatingHTTPClient) -> Bool {
        state.withLock { s in
            guard s.generation == generation else { return false }
            if s.connecting === client { s.connecting = nil }
            return true
        }
    }

    private static func cancel(connecting: AuthenticatingHTTPClient?, running: Running?) {
        connecting?.invalidate()
        guard let running else { return }
        running.stopped.set()
        running.task.cancel()
        running.continuation.finish()
    }

    /// The error without the request URL (URLSession errors carry it, with Reolink's `password=` query item):
    /// BridgeSupport's `URLFreeErrors.sanitized`, with a timeout as `RTSPError.timeout` and `RTSPError` passed unchanged.
    static func sanitized(_ error: any Error) -> any Error {
        URLFreeErrors.sanitized(error, request: "HTTP-FLV request", timedOut: RTSPError.timeout, passing: { $0 is RTSPError })
    }
}

/// FLV timestamps → pts / wall clock.
struct FLVTimeline: Sendable {
    private struct Track {
        var smoother: TimestampSmoother
        var origin: Int64
        var lastRaw: Int64?
        var lastSamples = 0
        var lastWallClock: Date?
    }

    private var originMilliseconds: Int64?
    private var video: Track?
    private var audio: Track?
    private var waitingForKeyframe = true

    mutating func map(_ sample: FLVSample, arrival: Date) -> MediaSample? {
        switch sample {
        case .video(let frame):
            if waitingForKeyframe {
                guard frame.isKeyframe else { return nil }
                waitingForKeyframe = false
            }
            let origin = originMilliseconds ?? frame.timestamp
            originMilliseconds = origin
            let raw = frame.timestamp.clampedSubtracting(origin).clampedMultiplied(by: 90)
            var track = video ?? Track(smoother: TimestampSmoother(clockRate: 90_000), origin: max(0, raw))
            let dts = track.origin.clampedAdding(track.smoother.smooth(raw, arrival: arrival))
            let wall = max(arrival, track.lastWallClock ?? arrival)
            track.lastWallClock = wall
            video = track
            let offset = Int64(frame.compositionOffset) * 90   // 24-bit milliseconds × 90: cannot overflow
            let dtsTime = MediaTime(value: dts, timescale: 90_000)
            return .video(EncodedVideoFrame(format: frame.format, nalUnits: frame.nalUnits, isKeyframe: frame.isKeyframe,
                                            pts: MediaTime(value: dts.clampedAdding(offset), timescale: 90_000), dts: offset == 0 ? nil : dtsTime,
                                            wallClock: wall))
        case .audio(let frame):
            guard !waitingForKeyframe else { return nil }
            let rate = Int64(min(max(1, frame.format.sampleRate), timingClockRateRange.upperBound))
            let origin = originMilliseconds ?? frame.timestamp
            originMilliseconds = origin
            var raw = frame.timestamp.clampedSubtracting(origin).clampedMultiplied(by: rate) / 1000
            let samples = frame.format.codec == .aac || frame.format.codec == .aacELD
                ? frame.format.samplesPerFrame : frame.data.count / max(1, frame.format.channels)
            var track = audio ?? Track(smoother: TimestampSmoother(clockRate: Int(rate)), origin: max(0, raw))
            // Millisecond timestamps jitter by up to 1 ms: keep sample-exact spacing while within 20 ms of it.
            if let lastRaw = track.lastRaw {
                let expected = lastRaw.clampedAdding(Int64(track.lastSamples))
                if raw.clampedSubtracting(expected).magnitude <= UInt64(rate / 50) { raw = expected }
            }
            track.lastRaw = raw
            track.lastSamples = samples
            let pts = track.origin.clampedAdding(track.smoother.smooth(raw, arrival: arrival))
            let wall = max(arrival, track.lastWallClock ?? arrival)
            track.lastWallClock = wall
            audio = track
            return .audio(EncodedAudioFrame(format: frame.format, data: frame.data, pts: MediaTime(value: pts, timescale: Int32(clamping: rate)),
                                            sampleCount: samples, wallClock: wall))
        }
    }
}
