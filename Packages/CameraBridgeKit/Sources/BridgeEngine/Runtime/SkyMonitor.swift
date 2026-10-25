import BridgeSupport
import Foundation
import MediaCore

/// Decodes one stream of a camera into the luma pictures the sky detector looks at (Task 6): at most five a second, at the width its
/// `SkyStreamChoice` says, each with the time of its frame in the stream's own clock and the wall clock of that encoded frame. It reads the hub's
/// frames from the newest keyframe on, so it starts at once and again at a keyframe after a break. The decoder is `MediaCodecs.makeSkyDecoder`,
/// asked to make a picture of every `keepEvery`th frame only; one that makes them all (the default) is kept to the rate here, from the pictures'
/// times. Nothing here straightens the picture (`PictureCorrection` is not applied anywhere on this path): the detector works on the camera's own.
///
/// A break in the pictures is told to the sink once (`SkyFrameSink.gap`) and the decoder starts again at the next keyframe, so its frame numbers and
/// times start afresh: the hub's source was reconnected (`MediaHub.discontinuityCount`), the stream's time went back or forward by more than
/// five seconds, no picture came for `stallTimeout` (once for a silence, however long), or the picture's codec or size changed. A monitor serves one
/// choice: when the format changes it tells the sink and **ends** (`isFinished`), and whoever made it chooses again (`CameraRuntime`).
actor SkyMonitor {
    /// A silence this long is a break.
    static let stallTimeout: Duration = .seconds(5)
    /// Pictures closer than this in the stream's time are not both analysed: five a second, with room for a camera's jitter.
    static let minimumSpacing: TimeInterval = 0.16
    /// A step of the stream's time bigger than this forward, or any step back, is a clock that restarted.
    static let timeJump: TimeInterval = 5
    /// The hub's queue for this monitor: a few GOPs (a consumer that falls behind loses the oldest whole GOP).
    static let bufferLimit = 240

    static let reconnectedReason = "the camera's stream was reconnected"
    static let formatChangedReason = "the picture format changed"
    static let timeJumpedReason = "the stream's time jumped"
    static func silenceReason(_ timeout: Duration) -> String { "no picture for \(MediaFit.seconds(timeout)) s" }

    /// What this monitor was made for.
    let choice: SkyStreamChoice
    private let hub: MediaHub
    private let codecs: any MediaCodecs
    private let sink: any SkyFrameSink
    private let log: Log
    private let stallTimeout: Duration

    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// `stop()` was called: nothing more is reported.
    private var stopped = false
    /// The monitor ended by itself (the picture's format changed): it has told the sink, and a new one is needed.
    private(set) var isFinished = false
    /// Pictures given to the sink.
    private(set) var analysed = 0
    /// Where the decoder decodes, once it has made a picture (`VideoDecoding.decodingPlace`).
    private(set) var decoding: DecodingPlace?

    /// When a picture last came out of the decoder (the stall check).
    private var lastPicture = ContinuousClock.now
    /// A break was told and no picture has been given since: another is not told (a silence, then a reconnect, is one break).
    private var gapOpen = false
    /// The silence check found the decoder wedged: it starts again at the next keyframe.
    private var decoderIsStale = false
    /// A picture is with the sink (which may take its time): that is no silence.
    private var delivering = false
    private var lastAnalysedTime: TimeInterval?
    /// The codec and size of the stream the decoder was made for.
    private var served: StreamShape?
    private var recent = FrameTimes()
    private var warned = false

    init(hub: MediaHub, codecs: any MediaCodecs, choice: SkyStreamChoice, sink: any SkyFrameSink, log: Log, stallTimeout: Duration = SkyMonitor.stallTimeout) {
        self.hub = hub
        self.codecs = codecs
        self.choice = choice
        self.sink = sink
        self.log = log
        self.stallTimeout = stallTimeout
    }

    func start() {
        guard task == nil, !stopped else { return }
        lastPicture = .now
        task = Task { [weak self] in await self?.run() }
        let timeout = stallTimeout
        watchdog = Task { [weak self] in
            let tick = min(Duration.seconds(1), timeout / 4)
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                await self?.checkSilence()
            }
        }
    }

    /// Stops decoding and releases the hub and the decoder; nothing is given to the sink after it returns.
    func stop() async {
        stopped = true
        let analysis = task
        let silence = watchdog
        task = nil
        watchdog = nil
        analysis?.cancel()
        silence?.cancel()
        await analysis?.value
        await silence?.value
    }

    // MARK: The loop

    /// The size and codec a decoder serves: what makes a different choice, and a gap.
    private struct StreamShape: Equatable {
        var codec: VideoCodec
        var width: Int
        var height: Int

        init(_ format: VideoFormat) {
            codec = format.codec
            width = format.width
            height = format.height
        }
    }

    private func run() async {
        let subscription = await hub.subscribe(from: .prebuffer(.zero), bufferLimit: Self.bufferLimit)
        defer { subscription.cancel() }
        var decoder: (any VideoDecoding)?
        var reconnects = hub.discontinuityCount
        var lastDecodeTime: Double?
        for await sample in subscription.samples {
            guard case .video(let frame) = sample, !Task.isCancelled, !stopped else { continue }

            // Breaks the frame shows.
            var reasons: [String] = []
            let count = hub.discontinuityCount
            if count != reconnects {
                reconnects = count
                reasons.append(Self.reconnectedReason)
            }
            let shape = StreamShape(frame.format)
            let formatChanged = served != nil && served != shape
            if formatChanged { reasons.append(Self.formatChangedReason) }
            let decodeTime = (frame.dts ?? frame.pts).seconds
            if let last = lastDecodeTime, decodeTime < last - 0.001 || decodeTime - last > Self.timeJump { reasons.append(Self.timeJumpedReason) }
            lastDecodeTime = decodeTime
            if !reasons.isEmpty || decoderIsStale {
                decoder?.invalidate()
                decoder = nil
                decoderIsStale = false
                lastAnalysedTime = nil
                recent.removeAll()
                if !reasons.isEmpty { await reportGap(at: frame.wallClock, reasons.joined(separator: "; ")) }
                if formatChanged { break }   // this monitor's choice is for the old format: its owner chooses again
            }

            // A decoder starts at a keyframe.
            if decoder == nil {
                guard frame.isKeyframe, !stopped else { continue }
                do {
                    decoder = try codecs.makeSkyDecoder(format: frame.format, maxOutputWidth: choice.analysisWidth, keepEvery: choice.keepEvery)
                    served = shape
                } catch {
                    if !warned { log.warning("The sky detector could not start a decoder for the stream (\(error))") }
                    warned = true
                    continue
                }
            }
            guard let current = decoder else { continue }

            recent.record(frame.pts, frame.wallClock)
            do {
                guard let picture = try await current.decode(frame), !Task.isCancelled, !stopped else { continue }
                await analyse(picture, of: current, arrivingWith: frame)
            } catch is CancellationError {
                break
            } catch {
                if !warned { log.warning("The sky detector could not decode the stream (\(error))") }
                warned = true
                current.invalidate()   // a new decoder at the next keyframe
                decoder = nil
            }
        }
        decoder?.invalidate()
        isFinished = true
    }

    /// Gives the picture to the sink unless it is too soon after the last one.
    private func analyse(_ picture: any DecodedVideoFrame, of decoder: any VideoDecoding, arrivingWith frame: EncodedVideoFrame) async {
        lastPicture = .now
        decoding = decoder.decodingPlace
        let time = picture.pts.seconds
        if let last = lastAnalysedTime, time - last < Self.minimumSpacing { return }
        guard let image = picture.grayThumbnail(maxWidth: choice.analysisWidth) else { return }
        lastAnalysedTime = time
        analysed += 1
        gapOpen = false
        delivering = true
        defer { delivering = false; lastPicture = .now }
        await sink.frame(SkyFrame(image: image, time: time, wallClock: recent.wallClock(of: picture.pts) ?? frame.wallClock, clockOffset: hub.wallClockOffset,
                                  pictureWidth: served?.width ?? 0, pictureHeight: served?.height ?? 0, stream: choice.stream, decoding: decoding))
    }

    // MARK: Breaks

    /// Tells the sink of a break, once for a stretch without pictures.
    private func reportGap(at date: Date, _ reason: String) async {
        guard !gapOpen, !stopped else { return }
        gapOpen = true   // before the first suspension: a second report finds it
        log.info("The sky detector's pictures break: \(reason)")
        await sink.gap(at: date, reason: reason)
    }

    /// No picture for `stallTimeout`: a break, and a decoder that starts again at the next keyframe (it may be wedged).
    private func checkSilence() async {
        guard !stopped, !gapOpen, !delivering, ContinuousClock.now - lastPicture > stallTimeout else { return }
        decoderIsStale = true
        await reportGap(at: Date(), Self.silenceReason(stallTimeout))
    }

    /// The wall clocks of the frames given to the decoder lately, by presentation time: a picture may come out frames after the one it shows,
    /// and takes the wall clock of its own.
    private struct FrameTimes {
        private var order: [Int64] = []
        private var table: [Int64: Date] = [:]
        static let capacity = 256

        mutating func record(_ pts: MediaTime, _ wallClock: Date) {
            let key = pts.converted(to: 90_000).value
            if table.updateValue(wallClock, forKey: key) == nil { order.append(key) }
            if order.count > Self.capacity { table.removeValue(forKey: order.removeFirst()) }
        }

        func wallClock(of pts: MediaTime) -> Date? { table[pts.converted(to: 90_000).value] }

        mutating func removeAll() {
            order.removeAll()
            table.removeAll()
        }
    }
}
