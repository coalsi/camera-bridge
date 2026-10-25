import BridgeSupport
import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

// The sky detector's picture stream (Task 6): which stream to watch (`SkyStreamChoice`), the monitor that decodes it into luma pictures
// five a second (`SkyMonitor`), and the camera runtime's hookup (`CameraRuntime.startSky`). The decoder itself is `SkyDecoderTests`.

// MARK: - Fakes

/// A decoded picture that is a flat grey of the size its decoder was asked for; its level is the number of the frame (at 20 fps) it shows,
/// so a test can tell which frame a picture came from. It notes how wide a thumbnail it was asked for.
struct SkyFakePicture: DecodedVideoFrame {
    var width: Int
    var height: Int
    var pts: MediaTime
    let thumbnailWidths: Box<[Int]>

    var level: UInt8 { UInt8(truncatingIfNeeded: pts.value / 4_500) }

    func grayThumbnail(maxWidth: Int) -> GrayImage? {
        thumbnailWidths.update { $0.append(maxWidth) }
        let outWidth = min(maxWidth, width)
        let outHeight = max(1, height * outWidth / width)
        return GrayImage(width: outWidth, height: outHeight, pixels: [UInt8](repeating: level, count: outWidth * outHeight))
    }
}

/// A decoder that decodes nothing: it answers a frame with a flat picture of the size it was asked for (at most `maxOutputWidth` wide).
/// Like ffmpeg's with `select='not(mod(n\,N))'` it makes a picture for frames 0, N, 2N, … only (`honoursKeepEvery`; the default decoder of
/// `MediaCodecs.makeSkyDecoder` makes one for every frame); `lateBy` frames late, as a decoder that holds pictures back; `failFrom`: the
/// frame from which it throws.
final class SkyFakeDecoder: VideoDecoding {
    private struct State {
        var seen: [EncodedVideoFrame] = []
        var invalidated = false
    }

    let width: Int
    let height: Int
    let keepEvery: Int
    let honoursKeepEvery: Bool
    let lateBy: Int
    let failFrom: Int?
    let place: DecodingPlace?
    let thumbnailWidths: Box<[Int]>
    /// Every frame takes this long to decode (a keyframe that is slow to make a still of).
    let delay: Duration
    private let state = Mutex(State())

    init(width: Int, height: Int, keepEvery: Int, honoursKeepEvery: Bool, lateBy: Int, failFrom: Int?, place: DecodingPlace?, thumbnailWidths: Box<[Int]>,
         delay: Duration = .zero) {
        self.delay = delay
        self.width = width
        self.height = height
        self.keepEvery = keepEvery
        self.honoursKeepEvery = honoursKeepEvery
        self.lateBy = lateBy
        self.failFrom = failFrom
        self.place = place
        self.thumbnailWidths = thumbnailWidths
    }

    var decodingPlace: DecodingPlace? { place }
    var isInvalidated: Bool { state.withLock { $0.invalidated } }

    func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? {
        if delay > .zero { try? await Task.sleep(for: delay) }
        let (index, shown): (Int, EncodedVideoFrame?) = state.withLock { state in
            state.seen.append(frame)
            let index = state.seen.count - 1
            return (index, index - lateBy >= 0 ? state.seen[index - lateBy] : nil)
        }
        if let failFrom, index >= failFrom { throw MediaCodecError.unsupported("scripted decoder failure") }
        guard let shown else { return nil }
        if honoursKeepEvery, keepEvery > 1, (index - lateBy) % keepEvery != 0 { return nil }
        return SkyFakePicture(width: width, height: height, pts: shown.pts, thumbnailWidths: thumbnailWidths)
    }

    func invalidate() { state.withLock { $0.invalidated = true } }
}

/// Codecs for the sky tests: `makeSkyDecoder` makes `SkyFakeDecoder`s and notes what it was asked for; the decoder every other user asks for
/// answers a picture for every frame and `jpeg(from:…)` answers a line saying what it was asked (the still). Transcoders made are counted
/// (with and without a correction). The rest is `base`'s (the Apple codecs, for the demo camera's picture), or unavailable.
final class SkyFakeCodecs: MediaCodecs {
    struct Request: Sendable, Equatable {
        var width: Int
        var height: Int
        var maxOutputWidth: Int
        var keepEvery: Int
    }

    let requests = Box<[Request]>([])
    let decoders = Box<[SkyFakeDecoder]>([])
    let thumbnailWidths = Box<[Int]>([])
    let otherDecoders = Box(0)
    let correctedTranscoders = Box(0)
    let plainTranscoders = Box(0)
    let jpegs = Box<[String]>([])
    /// `resizeJPEG` throws while this is set (ffmpeg gone, a picture it cannot read).
    let resizeFails = Box(false)
    private let honoursKeepEvery: Bool
    private let lateBy: Int
    private let failFirstDecoderFrom: Int?
    private let place: DecodingPlace?
    private let base: (any MediaCodecs)?
    /// How long the other decoders (the ones that make a still of a keyframe) take over a frame.
    private let stillDelay: Duration
    var supportsPictureCorrection: Bool { true }

    init(honoursKeepEvery: Bool = true, lateBy: Int = 0, failFirstDecoderFrom: Int? = nil, place: DecodingPlace? = .software,
         base: (any MediaCodecs)? = nil, stillDelay: Duration = .zero) {
        self.stillDelay = stillDelay
        self.honoursKeepEvery = honoursKeepEvery
        self.lateBy = lateBy
        self.failFirstDecoderFrom = failFirstDecoderFrom
        self.place = place
        self.base = base
    }

    private static let unavailable = MediaCodecError.unsupported("not in this test")

    func makeSkyDecoder(format: VideoFormat, maxOutputWidth: Int, keepEvery: Int) throws -> any VideoDecoding {
        let first = requests.update { requests -> Bool in
            requests.append(Request(width: format.width, height: format.height, maxOutputWidth: maxOutputWidth, keepEvery: keepEvery))
            return requests.count == 1
        }
        // The size the ffmpeg decoder gives (`FFmpegVideoDecoder.outputSize`): even, the shape kept, not larger than the stream.
        let wider = format.width > maxOutputWidth && format.width > 0
        let outWidth = wider ? maxOutputWidth & ~1 : format.width
        let outHeight = wider ? max(2, Int((Double(format.height) * Double(maxOutputWidth) / Double(format.width)).rounded()) & ~1) : format.height
        let decoder = SkyFakeDecoder(width: outWidth, height: outHeight, keepEvery: keepEvery,
                                     honoursKeepEvery: honoursKeepEvery, lateBy: lateBy, failFrom: first ? failFirstDecoderFrom : nil, place: place,
                                     thumbnailWidths: thumbnailWidths)
        decoders.update { $0.append(decoder) }
        return decoder
    }

    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding {
        otherDecoders.update { $0 += 1 }
        return SkyFakeDecoder(width: format.width, height: format.height, keepEvery: 1, honoursKeepEvery: false, lateBy: 0, failFrom: nil, place: nil,
                              thumbnailWidths: thumbnailWidths, delay: stillDelay)
    }

    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding {
        guard let base else { throw Self.unavailable }
        return try base.makeVideoEncoder(settings: settings)
    }

    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding {
        plainTranscoders.update { $0 += 1 }
        guard let base else { throw Self.unavailable }
        return try base.makeVideoTranscoder(output: output)
    }

    func makeVideoTranscoder(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?,
                             correction: (any PictureCorrectionProviding)?) throws -> any VideoTranscoding {
        if correction != nil { correctedTranscoders.update { $0 += 1 } } else { plainTranscoders.update { $0 += 1 } }
        guard let base else { throw Self.unavailable }
        return try base.makeVideoTranscoder(output: output, overlay: overlay, correction: correction)
    }

    func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding {
        guard let base else { throw Self.unavailable }
        return try base.makeAudioTranscoder(input: input, output: output)
    }

    func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
        let line = "JPEG pts=\(frame.pts.value) q=\(quality) w=\(maxWidth.map(String.init) ?? "nil") h=\(maxHeight.map(String.init) ?? "nil")"
        jpegs.update { $0.append(line) }
        return Data(line.utf8)
    }

    func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data {
        if resizeFails.value { throw MediaCodecError.unsupported("not in this test") }
        return jpeg
    }

    func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
        guard let base else { throw Self.unavailable }
        return try base.silentAACFrames(duration: duration, sampleRate: sampleRate, channels: channels, startPTS: startPTS, wallClock: wallClock)
    }

    func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration, audio: AudioCodec?,
                             audioSampleRate: Int) -> any MediaSource {
        base?.makeSyntheticSource(displayName: displayName, width: width, height: height, fps: fps, keyframeInterval: keyframeInterval, audio: audio,
                                  audioSampleRate: audioSampleRate) ?? SilentSource()
    }

    /// A camera that never says anything.
    final class SilentSource: MediaSource {
        let displayName = "Silent"
        func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> { AsyncThrowingStream { _ in } }
        func stop() async {}
    }
}

/// What the sink was told, in order.
final class SkyRecordingSink: SkyFrameSink {
    enum Event: Sendable {
        case frame(SkyFrame)
        case gap(at: Date, reason: String)
    }

    private let storage = Mutex<[Event]>([])

    func frame(_ frame: SkyFrame) async { storage.withLock { $0.append(.frame(frame)) } }
    func gap(at: Date, reason: String) async { storage.withLock { $0.append(.gap(at: at, reason: reason)) } }

    var events: [Event] { storage.withLock { $0 } }
    var frames: [SkyFrame] { events.compactMap { if case .frame(let frame) = $0 { frame } else { nil } } }
    var gaps: [String] { events.compactMap { if case .gap(_, let reason) = $0 { reason } else { nil } } }
    /// "f" for a picture and "g" for a gap, in order: "fffgff".
    var shape: String { events.map { if case .frame = $0 { "f" } else { "g" } }.joined() }
}

/// A sink that takes its time with every picture.
final class SkySlowSink: SkyFrameSink {
    let recorded = SkyRecordingSink()
    private let delay: Duration

    init(delay: Duration) { self.delay = delay }

    func frame(_ frame: SkyFrame) async {
        try? await Task.sleep(for: delay)
        await recorded.frame(frame)
    }

    func gap(at: Date, reason: String) async { await recorded.gap(at: at, reason: reason) }
}

/// Frames of a made-up camera: frame `index` of a stream at `fps` is shown at `index / fps` s, and its wall clock is `origin` plus that.
enum SkyFeed {
    static func format(_ width: Int, _ height: Int) -> VideoFormat { VideoFormat(codec: .h264, width: width, height: height, parameterSets: []) }

    static func frame(_ index: Int, fps: Int = 20, format: VideoFormat, key: Bool, origin: Date, offsetTicks: Int64 = 0) -> MediaSample {
        .video(EncodedVideoFrame(format: format, nalUnits: [Data([key ? 0x65 : 0x41, UInt8(truncatingIfNeeded: index)])], isKeyframe: key,
                                 pts: MediaTime(value: offsetTicks + Int64(index) * 90_000 / Int64(fps), timescale: 90_000),
                                 wallClock: origin.addingTimeInterval(Double(index) / Double(fps))))
    }

    static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
}

// MARK: - The choice

@Suite struct SkyStreamChoiceTests {
    @Test func choosesSubOrMain() {
        // A sub stream 1280 wide or more is the one to watch, at its own width.
        let wide = SkyStreamChoice.choose(sub: VideoResolution(1280, 720, 0), subFrameRate: nil, main: nil, mainFrameRate: nil)
        #expect(wide == SkyStreamChoice(stream: .sub, analysisWidth: 1280, keepEvery: 1))
        let both = SkyStreamChoice.choose(sub: VideoResolution(1280, 720, 15), subFrameRate: 15, main: VideoResolution(4256, 1888, 20), mainFrameRate: 20)
        #expect(both == SkyStreamChoice(stream: .sub, analysisWidth: 1280, keepEvery: 3))
        // Narrower: the main stream, down to 1920 wide, every fourth picture of 20 a second.
        let narrow = SkyStreamChoice.choose(sub: VideoResolution(704, 312, 15), subFrameRate: 15, main: VideoResolution(4256, 1888, 20), mainFrameRate: 20)
        #expect(narrow == SkyStreamChoice(stream: .main, analysisWidth: 1920, keepEvery: 4))
        let edge = SkyStreamChoice.choose(sub: VideoResolution(1279, 720, 15), subFrameRate: 15, main: VideoResolution(1920, 1080, 25), mainFrameRate: 25)
        #expect(edge == SkyStreamChoice(stream: .main, analysisWidth: 1920, keepEvery: 5))
        // No sub stream: the main one.
        let single = SkyStreamChoice.choose(sub: nil, subFrameRate: nil, main: VideoResolution(4256, 1888, 20), mainFrameRate: 20)
        #expect(single == SkyStreamChoice(stream: .main, analysisWidth: 1920, keepEvery: 4))
        #expect(SkyStreamChoice.minimumSubWidth == 1280 && SkyStreamChoice.maximumAnalysisWidth == 1920 && SkyStreamChoice.analysisRate == 5)
    }

    @Test func nothingIsChosenBeforeThereIsAPictureToChooseFrom() {
        #expect(SkyStreamChoice.choose(sub: nil, subFrameRate: nil, main: nil, mainFrameRate: nil) == nil)
        // A sub stream that is too small is no help when the main one has not shown a picture.
        #expect(SkyStreamChoice.choose(sub: VideoResolution(640, 360, 15), subFrameRate: 15, main: nil, mainFrameRate: nil) == nil)
        #expect(SkyStreamChoice.choose(sub: nil, subFrameRate: nil, main: VideoResolution(0, 0, 20), mainFrameRate: 20) == nil)
    }

    @Test func aPictureNeverGrowsAndNoMoreThanFivePicturesASecondAreKept() {
        // Wider than 1920, a sub stream is analysed at 1920 too.
        let big = SkyStreamChoice.choose(sub: VideoResolution(2560, 1440, 10), subFrameRate: 10, main: VideoResolution(3840, 2160, 30), mainFrameRate: 30)
        #expect(big == SkyStreamChoice(stream: .sub, analysisWidth: 1920, keepEvery: 2))
        // max(1, round(fps / 5)); an unknown rate keeps every picture (the monitor still analyses at most five a second).
        func keepEvery(_ rate: Double?) -> Int? {
            SkyStreamChoice.choose(sub: nil, subFrameRate: nil, main: VideoResolution(1920, 1080, 0), mainFrameRate: rate)?.keepEvery
        }
        #expect(keepEvery(30) == 6 && keepEvery(25) == 5 && keepEvery(20) == 4 && keepEvery(15) == 3 && keepEvery(12.4) == 2)
        #expect(keepEvery(7) == 1 && keepEvery(2.4) == 1 && keepEvery(0.5) == 1 && keepEvery(nil) == 1 && keepEvery(0) == 1 && keepEvery(.nan) == 1)
        // The rate the resolution itself carries stands in for one that was not measured.
        let carried = SkyStreamChoice.choose(sub: nil, subFrameRate: nil, main: VideoResolution(1920, 1080, 15), mainFrameRate: nil)
        #expect(carried?.keepEvery == 3)
    }
}

// MARK: - The monitor

@Suite(.serialized) struct SkyMonitorTests {
    static let log = Log(category: "SkyTest")
    static let mainChoice = SkyStreamChoice(stream: .main, analysisWidth: 640, keepEvery: 4)

    private func makeMonitor(_ hub: MediaHub, _ codecs: SkyFakeCodecs, _ sink: SkyRecordingSink, choice: SkyStreamChoice = SkyMonitorTests.mainChoice,
                         stallTimeout: Duration = SkyMonitor.stallTimeout) -> SkyMonitor {
        SkyMonitor(hub: hub, codecs: codecs, choice: choice, sink: sink, log: Self.log, stallTimeout: stallTimeout)
    }

    /// Starts the monitor and waits until it is subscribed: a monitor that subscribes late starts at the hub's newest keyframe, which would change what
    /// these tests count (the frames fed before it were a GOP or more).
    private func begin(_ monitor: SkyMonitor, on hub: MediaHub) async {
        await monitor.start()
        #expect(await eventually(timeout: .seconds(10)) { await hub.subscriberCount == 1 }, "the monitor subscribed")
    }

    /// Frames `range` of a 20 fps stream, one every `pause` (a stream that is not in a hurry), keyframes every 20 frames.
    private func feed(_ hub: MediaHub, _ range: Range<Int>, format: VideoFormat, fps: Int = 20, key: Int = 20, offsetTicks: Int64 = 0,
                      pause: Duration = .zero) async throws {
        for index in range {
            await hub.ingest(SkyFeed.frame(index, fps: fps, format: format, key: index % key == 0, origin: SkyFeed.origin, offsetTicks: offsetTicks))
            if pause > .zero { try await Task.sleep(for: pause) }
        }
    }

    @Test(.timeLimit(.minutes(1))) func framesReachTheSinkAtFivePerSecond() async throws {
        let hub = MediaHub()
        let sink = SkyRecordingSink()
        let monitor = makeMonitor(hub, SkyFakeCodecs(), sink)
        await begin(monitor, on: hub)
        let clock = ContinuousClock()
        let start = clock.now
        let format = SkyFeed.format(640, 360)
        for index in 0..<60 {   // three seconds of a 20 fps camera, as they come
            try await clock.sleep(until: start + .milliseconds(index * 50))
            await hub.ingest(SkyFeed.frame(index, format: format, key: index % 20 == 0, origin: SkyFeed.origin))
        }
        #expect(await eventually(timeout: .seconds(5)) { sink.frames.count >= 14 })
        try await Task.sleep(for: .milliseconds(200))
        let frames = sink.frames
        #expect((13...17).contains(frames.count), "\(frames.count) pictures in three seconds")
        #expect(await monitor.analysed == frames.count)
        for (index, frame) in frames.enumerated() {
            #expect(abs(frame.time - Double(index) * 0.2) < 1e-6, "the time is the stream's: picture \(index) at \(frame.time)")
            #expect(abs(frame.wallClock.timeIntervalSince(SkyFeed.origin) - Double(index) * 0.2) < 1e-6, "the encoded frame's wall clock")
            #expect(frame.image.width == 640 && frame.image.height == 360)
            #expect(frame.pictureWidth == 640 && frame.pictureHeight == 360 && frame.clockOffset == hub.wallClockOffset)
        }
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.wallClock < $1.wallClock && $0.time < $1.time })
        #expect(sink.gaps.isEmpty)
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aDecoderThatMakesEveryPictureStillGivesAtMostFivePicturesASecond() async throws {
        // The default `makeSkyDecoder` (Apple's) ignores `keepEvery`: the monitor keeps the rate itself, from the pictures' times.
        let hub = MediaHub()
        let sink = SkyRecordingSink()
        let codecs = SkyFakeCodecs(honoursKeepEvery: false)
        let monitor = makeMonitor(hub, codecs, sink)
        await begin(monitor, on: hub)
        try await feed(hub, 0..<80, format: SkyFeed.format(640, 360))   // four seconds of 20 fps, all at once
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count >= 20 })
        try await Task.sleep(for: .milliseconds(200))
        let times = sink.frames.map(\.time)
        #expect(times.count == 20, "\(times)")
        #expect(zip(times, times.dropFirst()).allSatisfy { abs($1 - $0 - 0.2) < 1e-6 })
        // The thumbnails were made only for the pictures analysed, at the analysis width.
        #expect(codecs.thumbnailWidths.value.count == 20 && Set(codecs.thumbnailWidths.value) == [640])
        #expect(codecs.requests.value == [SkyFakeCodecs.Request(width: 640, height: 360, maxOutputWidth: 640, keepEvery: 4)])
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aPictureTakesTheWallClockOfItsOwnFrameNotOfTheOneThatBroughtIt() async throws {
        let hub = MediaHub()
        let sink = SkyRecordingSink()
        let monitor = makeMonitor(hub, SkyFakeCodecs(lateBy: 2), sink)
        await begin(monitor, on: hub)
        try await feed(hub, 0..<30, format: SkyFeed.format(640, 360))
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count >= 7 })
        for frame in sink.frames {
            let shown = Int(frame.image.pixels[0])   // the number of the frame the picture shows
            #expect(frame.wallClock == SkyFeed.origin.addingTimeInterval(Double(shown) / 20), "picture of frame \(shown)")
            #expect(abs(frame.time - Double(shown) / 20) < 1e-6)
        }
        #expect(sink.frames.map { Int($0.image.pixels[0]) }.prefix(4) == [0, 4, 8, 12])
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aFormatChangeIsOneGapAndTheMonitorEnds() async throws {
        let hub = MediaHub()
        let sink = SkyRecordingSink()
        let codecs = SkyFakeCodecs()
        let monitor = makeMonitor(hub, codecs, sink, choice: SkyStreamChoice(stream: .main, analysisWidth: 1920, keepEvery: 4))
        await begin(monitor, on: hub)
        try await feed(hub, 0..<20, format: SkyFeed.format(4256, 1888))
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count == 5 })
        let before = sink.frames.count
        #expect(await !monitor.isFinished)
        // The camera now sends 2560×1440 (a keyframe with new parameter sets): one gap, and the monitor is done; its owner chooses again.
        try await feed(hub, 20..<60, format: SkyFeed.format(2560, 1440))
        #expect(await eventually(timeout: .seconds(10)) { await monitor.isFinished })
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.gaps.count == 1 && sink.gaps[0].contains("format"), "\(sink.gaps)")
        #expect(sink.shape == String(repeating: "f", count: before) + "g", "nothing follows the gap: \(sink.shape)")
        #expect(codecs.requests.value.count == 1)
        await monitor.stop()
        #expect(await hub.subscriberCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func aReconnectOfTheCameraIsOneGap() async throws {
        let hub = MediaHub()
        let sink = SkyRecordingSink()
        let codecs = SkyFakeCodecs()
        let monitor = makeMonitor(hub, codecs, sink)
        await begin(monitor, on: hub)
        let format = SkyFeed.format(640, 360)
        try await feed(hub, 0..<40, format: format)
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count == 10 })
        // The camera went and came back with the same picture size and a clock of its own: the decoder starts again at its keyframe.
        await hub.discontinuity()
        try await feed(hub, 0..<40, format: format, offsetTicks: 900_000)
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count == 20 })
        #expect(sink.gaps.count == 1 && sink.gaps[0].contains("reconnect"), "\(sink.gaps)")
        #expect(sink.shape == "ffffffffff" + "g" + "ffffffffff", "\(sink.shape)")
        #expect(codecs.requests.value.count == 2, "a new decoder: its frame numbers and times start afresh")
        #expect(sink.frames[10].time == 10 && abs(sink.frames[11].time - 10.2) < 1e-6, "the new clock")
        #expect(await !monitor.isFinished)
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aJumpInTheStreamsTimeIsOneGap() async throws {
        let hub = MediaHub()
        let sink = SkyRecordingSink()
        let monitor = makeMonitor(hub, SkyFakeCodecs(), sink)
        await begin(monitor, on: hub)
        let format = SkyFeed.format(640, 360)
        try await feed(hub, 0..<20, format: format)
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count == 5 })
        // The time goes back (a camera that restarted its clock without the connection noticing)…
        try await feed(hub, 0..<20, format: format, offsetTicks: -900_000 + 90_000)
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count == 10 })
        // …and forward by more than five seconds.
        try await feed(hub, 0..<20, format: format, offsetTicks: 90_000 * 60)
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count == 15 })
        #expect(sink.shape == "fffff" + "g" + "fffff" + "g" + "fffff", "\(sink.shape)")
        #expect(sink.gaps.allSatisfy { $0.contains("time") }, "\(sink.gaps)")
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1))) func fiveSecondsWithoutAPictureIsOneGapNotMore() async throws {
        let hub = MediaHub()
        let sink = SkyRecordingSink()
        let monitor = makeMonitor(hub, SkyFakeCodecs(), sink, stallTimeout: .milliseconds(400))
        await begin(monitor, on: hub)
        let format = SkyFeed.format(640, 360)
        try await feed(hub, 0..<10, format: format)
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count == 3 })
        // Nothing for much longer than the timeout: one gap, not one for every check.
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(sink.gaps.count == 1 && sink.gaps[0].contains("picture"), "\(sink.gaps)")
        // The pictures return (at a keyframe, as a decoder is started again): no second gap.
        try await feed(hub, 10..<30, format: format)
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count > 3 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.gaps.count == 1, "\(sink.shape)")
        #expect(sink.shape.hasPrefix("fffg") && sink.shape.dropFirst(4).allSatisfy { $0 == "f" }, "\(sink.shape)")
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aSlowSinkIsNoSilence() async throws {
        // The detector may take longer over a picture than the silence timeout: pictures are arriving, so nothing is told.
        let hub = MediaHub()
        let sink = SkySlowSink(delay: .milliseconds(600))
        let monitor = SkyMonitor(hub: hub, codecs: SkyFakeCodecs(), choice: Self.mainChoice, sink: sink, log: Self.log, stallTimeout: .milliseconds(400))
        await begin(monitor, on: hub)
        try await feed(hub, 0..<12, format: SkyFeed.format(640, 360))
        #expect(await eventually(timeout: .seconds(10)) { sink.recorded.frames.count == 3 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.recorded.gaps.isEmpty, "\(sink.recorded.gaps)")
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aDecodeFailureStartsAgainAtTheNextKeyframe() async throws {
        let hub = MediaHub()
        let sink = SkyRecordingSink()
        let codecs = SkyFakeCodecs(failFirstDecoderFrom: 6)
        let monitor = makeMonitor(hub, codecs, sink)
        await begin(monitor, on: hub)
        try await feed(hub, 0..<60, format: SkyFeed.format(640, 360))
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count >= 7 })
        #expect(codecs.requests.value.count == 2, "a decoder that fails is replaced")
        #expect(codecs.decoders.value[0].isInvalidated)
        let times = sink.frames.map(\.time)
        #expect(times.prefix(2) == [0, 0.2] && times.contains(1.0), "the frames between the failure and the next keyframe (1 s) give nothing: \(times)")
        #expect(!times.contains { $0 > 0.4 && $0 < 1.0 })
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1))) func stoppingEndsTheDecoderAndTheSubscription() async throws {
        let hub = MediaHub()
        let sink = SkyRecordingSink()
        let codecs = SkyFakeCodecs()
        let monitor = makeMonitor(hub, codecs, sink)
        await begin(monitor, on: hub)
        let format = SkyFeed.format(640, 360)
        try await feed(hub, 0..<20, format: format)
        #expect(await eventually(timeout: .seconds(10)) { sink.frames.count == 5 })
        #expect(await hub.subscriberCount == 1)
        await monitor.stop()
        #expect(await hub.subscriberCount == 0)
        #expect(codecs.decoders.value.allSatisfy { $0.isInvalidated })
        try await feed(hub, 20..<40, format: format)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.frames.count == 5, "nothing after the stop")
        await monitor.stop()   // again: harmless
    }

    @Test(.timeLimit(.minutes(1))) func whereTheDecoderDecodesIsReported() async throws {
        for place in [DecodingPlace.gpu, .software, nil] {
            let hub = MediaHub()
            let sink = SkyRecordingSink()
            let monitor = makeMonitor(hub, SkyFakeCodecs(place: place), sink)
            #expect(await monitor.decoding == nil)
            await begin(monitor, on: hub)
            try await feed(hub, 0..<8, format: SkyFeed.format(640, 360))
            #expect(await eventually(timeout: .seconds(10)) { sink.frames.count == 2 })
            #expect(await monitor.decoding == place)
            await monitor.stop()
        }
    }
}

// MARK: - The camera runtime

#if canImport(Darwin)
import PlatformApple

@Suite(.serialized) struct RuntimeSkyTests {
    /// A camera whose main stream is never there: the test feeds `runtime.hub` itself. Its stream is let alone once it failed.
    private static func deadCamera(_ name: String) -> CameraConfiguration {
        var camera = CameraConfiguration(name: name, kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "127.0.0.1", rtspPort: 1), username: "")
        camera.mainStreamURL = URL(string: "rtsp://127.0.0.1:1/main")
        camera.motionSource = .webhook
        return camera
    }

    private static func tuning(sub: DemoStream? = nil, main: DemoStream? = nil) -> EngineTuning {
        var tuning = EngineTuning.testing
        tuning.driverFactory = { _, _, _ in ScriptedEventDriver() }
        tuning.subStreamIdleStop = .milliseconds(300)
        tuning.ingest.initialBackoff = .seconds(3_600)
        tuning.ingest.maximumBackoff = .seconds(3_600)
        if let sub { tuning.demoSub = sub }
        if let main { tuning.demoMain = main }
        return tuning
    }

    @MainActor private static func started(_ camera: CameraConfiguration, tuning: EngineTuning, codecs: SkyFakeCodecs) async throws
        -> (fixture: EngineFixture, runtime: CameraRuntime) {
        let fixture = try await EngineFixture(tuning: tuning, adjust: { $0.codecs = codecs })
        try await fixture.engine.addCamera(camera, password: nil)
        await fixture.engine.start()
        let runtime = try #require(fixture.engine.runtimes[camera.id])
        return (fixture, runtime)
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func onDemandCamerasCannotWatchTheSky() async throws {
        var tuning = Self.tuning()
        tuning.driverFactory = { _, _, _ in ScriptedEventDriver(streamsOnDemand: true) }
        let camera = EngineFixture.demoCamera(name: "Battery Sky")
        let (fixture, runtime) = try await Self.started(camera, tuning: tuning, codecs: SkyFakeCodecs(base: AppleMediaCodecs()))
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let sink = SkyRecordingSink()
        #expect(await runtime.startSky(sink: sink) == false, "an on-demand camera sleeps; watching it would keep it awake")
        #expect(await runtime.skyStream == nil)
        try await Task.sleep(for: .milliseconds(600))
        #expect(sink.events.isEmpty && fixture.engine.runtimes[camera.id] != nil)
        #expect(await runtime.subStreamUsers == 0)
        await fixture.tearDown()
        #expect(await runtime.startSky(sink: sink) == false, "nor a camera that is not running")
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func framesReachTheSinkAtFivePerSecond() async throws {
        let camera = EngineFixture.demoCamera(name: "Demo Sky")
        let tuning = Self.tuning(main: DemoStream(width: 640, height: 360, fps: 20, keyframeInterval: .seconds(1)))
        let codecs = SkyFakeCodecs(base: AppleMediaCodecs())
        let (fixture, runtime) = try await Self.started(camera, tuning: tuning, codecs: codecs)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let sink = SkyRecordingSink()
        #expect(await runtime.startSky(sink: sink))
        #expect(await fixture.until(.seconds(30)) { sink.frames.count >= 3 }, "the first pictures")
        // The demo camera's 320×180 sub stream is too small to watch: the main stream, every fourth picture.
        #expect(await runtime.skyStream == SkyStreamChoice(stream: .main, analysisWidth: 640, keepEvery: 4))
        #expect(codecs.requests.value.last == SkyFakeCodecs.Request(width: 640, height: 360, maxOutputWidth: 640, keepEvery: 4))
        let before = sink.frames.count
        try await Task.sleep(for: .seconds(3))
        let frames = sink.frames
        let counted = frames.count - before
        #expect((13...17).contains(counted), "\(counted) pictures in three seconds")
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.wallClock < $1.wallClock && abs($1.time - $0.time - 0.2) < 0.03 })
        #expect(await runtime.skyDecoding == .software)
        await runtime.stopSky()
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func aFormatChangeChoosesTheStreamAgain() async throws {
        let camera = Self.deadCamera("North Sky")
        let codecs = SkyFakeCodecs()
        let (fixture, runtime) = try await Self.started(camera, tuning: Self.tuning(), codecs: codecs)
        let isOffline: @MainActor () -> Bool = {
            if case .offline = fixture.status(camera.id)?.connection { return true }
            return false
        }
        #expect(await fixture.waitFor(.seconds(20)) { isOffline() }, "the camera's own stream has failed: the test feeds the hub")
        let sink = SkyRecordingSink()
        #expect(await runtime.startSky(sink: sink))
        #expect(await runtime.skyStream == nil, "nothing to choose from before a picture")

        // 4256×1888 at 20 a second: the main stream, 1920 wide, every fourth picture.
        let hub = runtime.hub
        let big = SkyFeed.format(4256, 1888)
        for index in 0..<60 {
            await hub.ingest(SkyFeed.frame(index, format: big, key: index % 20 == 0, origin: SkyFeed.origin))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.until(.seconds(10)) { await runtime.skyStream == SkyStreamChoice(stream: .main, analysisWidth: 1920, keepEvery: 4) })
        #expect(await fixture.until(.seconds(10)) { sink.frames.count >= 4 })
        #expect(sink.frames.allSatisfy { $0.image.width == 1920 && $0.image.height == 852 }, "1920×852 from 4256×1888")
        #expect(sink.frames.allSatisfy { $0.pictureWidth == 4256 && $0.pictureHeight == 1888 }, "the original picture's size goes with each")
        #expect(sink.gaps.isEmpty)

        // The camera restarts its stream at 2560×1440 and 10 a second: one gap, then pictures at the new choice.
        await hub.discontinuity()
        let medium = SkyFeed.format(2560, 1440)
        let later = SkyFeed.origin.addingTimeInterval(30)
        for index in 0..<60 {
            await hub.ingest(SkyFeed.frame(index, fps: 10, format: medium, key: index % 10 == 0, origin: later))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await fixture.until(.seconds(10)) { await runtime.skyStream == SkyStreamChoice(stream: .main, analysisWidth: 1920, keepEvery: 2) })
        #expect(await fixture.until(.seconds(10)) { sink.frames.last?.image.height == 1080 }, "pictures at the new size")
        #expect(sink.gaps.count == 1 && sink.gaps[0].contains("format"), "\(sink.gaps)")
        #expect(sink.shape.filter { $0 == "g" }.count == 1)
        let afterGap = sink.events.drop { if case .gap = $0 { false } else { true } }.dropFirst()
        #expect(afterGap.allSatisfy { if case .frame(let frame) = $0 { frame.image.height == 1080 && frame.pictureWidth == 2560 } else { false } },
                "no old-size picture after the gap")
        #expect(codecs.requests.value.last == SkyFakeCodecs.Request(width: 2560, height: 1440, maxOutputWidth: 1920, keepEvery: 2))
        #expect(await runtime.subStreamUsers == 0)
        await runtime.stopSky()
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func theSubStreamIsHeldAndReleased() async throws {
        let camera = EngineFixture.demoCamera(name: "Wide Sub Sky")
        let tuning = Self.tuning(sub: DemoStream(width: 1280, height: 720, fps: 10, keyframeInterval: .seconds(1)))
        let codecs = SkyFakeCodecs(base: AppleMediaCodecs())
        let (fixture, runtime) = try await Self.started(camera, tuning: tuning, codecs: codecs)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(await !runtime.isSubStreamRunning, "connected only on demand")
        let sink = SkyRecordingSink()
        #expect(await runtime.startSky(sink: sink))
        // The sub stream is looked at first: 1280 wide is wide enough, so it is the one watched, at 10 a second: every second picture.
        #expect(await fixture.until(.seconds(30)) { await runtime.skyStream == SkyStreamChoice(stream: .sub, analysisWidth: 1280, keepEvery: 2) })
        let users = await runtime.subStreamUsers
        let running = await runtime.isSubStreamRunning
        #expect(users == 1 && running, "one user while the sky uses the sub stream")
        #expect(await fixture.until(.seconds(20)) { sink.frames.count >= 3 })
        #expect(sink.frames.allSatisfy { $0.image.width == 1280 })
        #expect(codecs.requests.value.last == SkyFakeCodecs.Request(width: 1280, height: 720, maxOutputWidth: 1280, keepEvery: 2))
        try await Task.sleep(for: .milliseconds(700))
        #expect(await runtime.isSubStreamRunning, "held past the idle stop")

        await runtime.stopSky()
        let usersAfter = await runtime.subStreamUsers
        let scheduled = await runtime.isSubIdleStopScheduled
        #expect(usersAfter == 0 && scheduled, "given back: the idle stop is scheduled")
        #expect(await runtime.skyStream == nil)
        #expect(await fixture.until(.seconds(10)) { await !runtime.isSubStreamRunning }, "and the sub stream stops when it comes")
        let count = sink.frames.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(sink.frames.count == count, "no picture after the stop")
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func aSubStreamThatIsTooSmallIsLetGoAgainOnceItsSizeIsKnown() async throws {
        let camera = EngineFixture.demoCamera(name: "Small Sub Sky")
        let (fixture, runtime) = try await Self.started(camera, tuning: Self.tuning(), codecs: SkyFakeCodecs(base: AppleMediaCodecs()))
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let sink = SkyRecordingSink()
        #expect(await runtime.startSky(sink: sink))
        #expect(await fixture.until(.seconds(30)) { await runtime.skyStream?.stream == .main })
        #expect(await fixture.until(.seconds(10)) { await runtime.subStreamUsers == 0 }, "the sub stream was held only to see its size (320 wide)")
        #expect(await fixture.until(.seconds(10)) { await !runtime.isSubStreamRunning })
        await runtime.stopSky()
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func theSkySeesTheOriginalPicture() async throws {
        var camera = EngineFixture.demoCamera(name: "Straight Sky")
        camera.pictureCorrection = PictureCorrection(straighten: 0.4, level: 0.15)
        let codecs = SkyFakeCodecs(base: AppleMediaCodecs())
        let (fixture, runtime) = try await Self.started(camera, tuning: Self.tuning(), codecs: codecs)
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let sink = SkyRecordingSink()
        #expect(await runtime.startSky(sink: sink))
        #expect(await fixture.until(.seconds(30)) { sink.frames.count >= 3 })
        // Straighten the picture is on for the camera, and the sky decoder is the one that sees it as it is: no transcoder with a correction
        // was made for it, nor any other decoder.
        #expect(codecs.requests.value.count >= 1)
        #expect(codecs.correctedTranscoders.value == 0 && codecs.plainTranscoders.value == 0)
        #expect(codecs.otherDecoders.value == 0)
        #expect(Set(codecs.thumbnailWidths.value).count == 1, "only the analysis width was asked for: \(Set(codecs.thumbnailWidths.value))")
        await runtime.stopSky()
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func aStillIsTheOriginalPictureOfTheKeyframeNearestTheTime() async throws {
        let camera = Self.deadCamera("Still Sky")
        let codecs = SkyFakeCodecs()
        let (fixture, runtime) = try await Self.started(camera, tuning: Self.tuning(), codecs: codecs)
        let isOffline: @MainActor () -> Bool = {
            if case .offline = fixture.status(camera.id)?.connection { return true }
            return false
        }
        #expect(await fixture.waitFor(.seconds(20)) { isOffline() })
        #expect(await runtime.skyStill(around: SkyFeed.origin) == nil, "no keyframe held yet")

        // A keyframe every two seconds, and frames between them.
        let hub = runtime.hub
        let format = SkyFeed.format(4256, 1888)
        for index in 0..<200 {
            await hub.ingest(SkyFeed.frame(index, format: format, key: index % 40 == 0, origin: SkyFeed.origin))
        }
        let still = try #require(await runtime.skyStill(around: SkyFeed.origin.addingTimeInterval(4.6)))
        #expect(still.at == SkyFeed.origin.addingTimeInterval(4), "the keyframes are at 0, 2, 4, 6 and 8 s: 4 s is nearest to 4.6 s")
        // Of the picture as the camera sent it (the first picture decoded, no correction), at full size, quality 0.8.
        let line = String(decoding: still.jpeg, as: UTF8.self)
        #expect(line == "JPEG pts=360000 q=0.8 w=nil h=nil", "\(line)")
        let far = try #require(await runtime.skyStill(around: SkyFeed.origin.addingTimeInterval(500)))
        #expect(far.at == SkyFeed.origin.addingTimeInterval(8), "the nearest the ring has; `at` says which")
        let early = try #require(await runtime.skyStill(around: SkyFeed.origin.addingTimeInterval(-3)))
        #expect(early.at == SkyFeed.origin)
        await fixture.tearDown()
        #expect(await runtime.skyStill(around: SkyFeed.origin) == nil, "nothing from a camera that is not running")
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func stoppingTheCameraStopsTheSky() async throws {
        let camera = EngineFixture.demoCamera(name: "Stopping Sky")
        let tuning = Self.tuning(sub: DemoStream(width: 1280, height: 720, fps: 10, keyframeInterval: .seconds(1)))
        let (fixture, runtime) = try await Self.started(camera, tuning: tuning, codecs: SkyFakeCodecs(base: AppleMediaCodecs()))
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        let sink = SkyRecordingSink()
        #expect(await runtime.startSky(sink: sink))
        #expect(await fixture.until(.seconds(30)) { sink.frames.count >= 2 })
        #expect(await runtime.subStreamUsers == 1)
        await fixture.engine.stop()
        let leftOver = await runtime.skyStream
        let usersLeft = await runtime.subStreamUsers
        #expect(leftOver == nil && usersLeft == 0, "the sub stream is given back with the camera")
        #expect(await runtime.hub.subscriberCount == 0)
        let count = sink.frames.count
        try await Task.sleep(for: .milliseconds(700))
        #expect(sink.frames.count == count, "no picture after the camera stopped")
        // The detector starts the sky again when the camera runs again.
        await fixture.engine.start()
        let again = try #require(fixture.engine.runtimes[camera.id])
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online })
        #expect(await again.startSky(sink: sink))
        #expect(await fixture.until(.seconds(30)) { sink.frames.count > count })
        await fixture.tearDown()
    }
}
#endif
