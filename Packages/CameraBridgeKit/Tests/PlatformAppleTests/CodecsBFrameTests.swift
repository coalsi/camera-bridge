#if os(macOS)
import Foundation
import MediaCore
import Testing
@testable import PlatformApple

/// Review finding (B-frames): VideoToolbox emits decoded pictures in decode order, and the transcoder encoded them that
/// way: an RTSP clip judders on every B-frame, and FrameRateLimiter dropped every picture of an FLV source presented
/// before the one decoded ahead of it (about half). The transcoder now encodes pictures in presentation order.
@Suite(.timeLimit(.minutes(1))) struct CodecsBFrameTranscoderTests {
    static let count = 50
    /// 50 pictures with B-frames, then an IDR (whose arrival releases every picture held before it).
    static let source: [EncodedVideoFrame] = (try? BFrameStream.encode(count: count + 1, keyframes: [count])) ?? []

    /// Transcodes `input` (640×360 at `fps`) and returns the output with the picture number each output frame shows.
    private func transcode(_ input: [EncodedVideoFrame], fps: Int = 25) throws -> [(frame: EncodedVideoFrame, shown: Int)] {
        let transcoder = try AppleVideoTranscoder(output: VideoEncoderSettings(width: 640, height: 360, fps: fps, bitrateKbps: 2_000,
                                                                               keyframeInterval: .seconds(4)))
        defer { transcoder.invalidate() }
        var frames: [EncodedVideoFrame] = []
        for frame in input { frames += try transcoder.transcodeNow(frame) }
        guard let first = frames.first else { return [] }
        let decoder = try AppleVideoDecoder(format: first.format)
        defer { decoder.invalidate() }
        return try frames.map { frame in
            let picture = try #require(try decoder.decodeNow(frame))
            return (frame, try #require(BFrameStream.index(of: picture)))
        }
    }

    /// The output before the closing IDR (which shows picture 0 again: the fixture's numbers wrap at 50).
    private func body(_ output: [(frame: EncodedVideoFrame, shown: Int)]) -> [(frame: EncodedVideoFrame, shown: Int)] {
        output.filter { BFrameStream.index(ofPTS: $0.frame.pts) < Self.count }
    }

    @Test func theFixtureReorders() throws {
        let source = Self.source
        try #require(source.count == Self.count + 1)
        #expect(BFrameStream.reorders(source))
        #expect(source.contains { $0.dts != nil })
    }

    /// FLV (and the RTSP ingest once it saw B-frames) mark reordered frames with decode times: every picture comes out,
    /// once, in display order, each with its own presentation time.
    @Test func framesWithDecodeTimesAreTranscodedInDisplayOrderWithoutLoss() throws {
        try #require(BFrameStream.reorders(Self.source))
        let output = try transcode(Self.source)
        let body = body(output)
        #expect(body.map(\.shown) == Array(0..<Self.count), "\(output.map(\.shown))")
        #expect(output.count <= Self.count + 1)
        #expect(zip(output.dropFirst(), output).allSatisfy { $0.frame.pts > $1.frame.pts }, "\(output.map(\.frame.pts.value))")
        #expect(body.allSatisfy { BFrameStream.index(ofPTS: $0.frame.pts) == $0.shown })
    }

    /// Without decode times the transcoder learns the reordering from the presentation times: the B-frames of the first
    /// group, whose anchor already went out, are dropped (never sent out of order), and once the buffer is as deep as
    /// the stream reorders everything comes out in display order. VideoToolbox picks the B-frame pattern itself and it
    /// varies from run to run (usually 0 4 2 1 3 …, under load sometimes 0 1 5 3 2 4 … or a deeper group later), so the
    /// expected loss is derived from the input's decode order (`isExpectedLoss`) rather than fixed.
    @Test func reorderingIsLearnedFromPresentationTimesAlone() throws {
        let input = Self.source.map { frame in
            var frame = frame
            frame.dts = nil
            return frame
        }
        try #require(BFrameStream.reorders(input))
        let output = try transcode(input)
        let shown = body(output).map(\.shown)
        #expect(zip(shown.dropFirst(), shown).allSatisfy { $0 > $1 }, "\(shown)")
        let decodeOrder = input.map { BFrameStream.index(ofPTS: $0.pts) }.filter { $0 < Self.count }
        let missing = Set(0..<Self.count).subtracting(shown)
        #expect(isExpectedLoss(missing, decodeOrder: decodeOrder), "missing \(missing.sorted()), decode order \(decodeOrder)")
        #expect(zip(output.dropFirst(), output).allSatisfy { $0.frame.pts > $1.frame.pts })
    }

    /// Decimation runs in display order: a 25 fps B-frame source at 12 fps keeps every second (sometimes third) picture.
    @Test func reorderedFramesAreDecimatedEvenly() throws {
        let shown = body(try transcode(Self.source, fps: 12)).map(\.shown)
        let steps = zip(shown.dropFirst(), shown).map { $0 - $1 }
        #expect(shown.count >= 20 && steps.allSatisfy { $0 == 2 || $0 == 3 }, "\(shown)")
    }
}

@Suite struct PresentationOrderTests {
    typealias Order = PresentationOrder<Int>

    /// Pushes picture numbers (25 fps presentation times) in decode order; returns what came out, in order.
    private func push(_ numbers: [Int], into order: inout Order) -> [Int] {
        numbers.flatMap { order.push($0, time: Double($0) / 25) }
    }

    @Test func inOrderPicturesAreNeverHeld() {
        var order = Order()
        for number in 0..<100 { #expect(order.push(number, time: Double(number) / 25) == [number]) }
        #expect(order.depth == 0 && order.droppedCount == 0)
    }

    /// A source that marks reordering (decode time ≠ presentation time) holds `fallbackDepth` pictures and releases them
    /// smallest presentation time first; `restart()` (a keyframe) releases the rest.
    @Test func markedReorderingIsReleasedInPresentationOrder() {
        var order = Order()
        order.noteReordering()
        #expect(order.depth == Order.fallbackDepth)
        #expect(push([0, 4, 2, 1, 3, 8, 6, 5, 7, 12, 10, 9, 11, 13, 14, 15, 16], into: &order) == Array(0...12))
        #expect(order.restart() == [13, 14, 15, 16])
        #expect(order.droppedCount == 0)
        // After a restart the next picture may be presented earlier than the last released one (a new GOP's timeline).
        #expect(push([5, 6, 7, 8, 9], into: &order) == [5])
    }

    /// Unmarked reordering: the first anchor is out before its B-frames arrive, which are dropped; the buffer then holds
    /// as many pictures as the stream reorders (2 for VideoToolbox's pyramid) and loses nothing more.
    @Test func reorderingSeenInPresentationTimesDeepensTheBuffer() {
        var order = Order()
        let released = push([0, 4, 2, 1, 3, 8, 6, 5, 7, 12, 10, 9, 11, 16, 14, 13, 15], into: &order)
        #expect(released == [0, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14])
        #expect(order.depth == 2 && order.droppedCount == 3)
    }

    /// More than 1 s back is a new timeline (a reconnected source): what was held comes out first, without deepening.
    @Test func aTimelineFarBackStartsOver() {
        var order = Order()
        order.noteReordering()
        #expect(push([100, 104, 102, 101, 103], into: &order) == [100])
        #expect(order.push(50, time: 2) == [101, 102, 103, 104])
        #expect(order.depth == Order.fallbackDepth && order.droppedCount == 0)
        #expect(push([51, 52, 53, 54], into: &order) == [50])
    }

    @Test func depthIsCappedAtTheDecodedPictureBufferLimit() {
        var order = Order()
        _ = push(Array(100..<120) + [99], into: &order)   // 17 recent pictures presented after 99, within 1 s
        #expect(order.depth == Order.maximumDepth)
    }

    /// VideoToolbox under load may send a P-frame before the first B-frame group: that group's B-frames are lost (their
    /// anchor is out), nothing after.
    @Test func aFirstGroupAfterAPFrameLosesItsBFrames() {
        var order = Order()
        let released = push([0, 1, 5, 3, 2, 4, 9, 7, 6, 8, 13, 11, 10, 12], into: &order)
        #expect(released == [0, 1, 5, 6, 7, 8, 9, 10, 11])
        #expect(order.depth == 2 && order.droppedCount == 3)
    }

    /// A first group that reorders less than a later one: the later picture that deepens the buffer is presented before
    /// one already released, so it is lost too.
    @Test func aDeeperGroupLaterLosesThePictureThatRevealsIt() {
        var order = Order()
        let released = push([0, 2, 1, 3, 7, 5, 4, 6, 11, 9, 8, 10], into: &order)
        #expect(released == [0, 2, 3, 5, 6, 7, 8, 9])
        #expect(order.depth == 2 && order.droppedCount == 2)
    }

    /// The transcoder test's expectation is exact where the decode order fixes the loss: losing less, or a picture
    /// after the buffer is as deep as the stream reorders, is rejected.
    @Test func theExpectedLossIsTight() {
        let pyramid = VideoToolboxDecodeOrders.all[0]
        #expect(isExpectedLoss([1, 2, 3], decodeOrder: pyramid))
        #expect(!isExpectedLoss([1, 2], decodeOrder: pyramid))
        #expect(!isExpectedLoss([1, 2, 3, 6], decodeOrder: pyramid))
        let deeperLater = [0, 2, 1, 3, 7, 5, 4, 6, 11, 9, 8, 10]
        #expect(isExpectedLoss([1, 4], decodeOrder: deeperLater))
        #expect(!isExpectedLoss([4], decodeOrder: deeperLater))
        #expect(!isExpectedLoss([1, 4, 9], decodeOrder: deeperLater))
        #expect(isExpectedLoss([], decodeOrder: Array(0..<10)) && !isExpectedLoss([3], decodeOrder: Array(0..<10)))
    }

    /// Review finding (flaky B-frame test): the transcoder test's source is a live VideoToolbox encode whose first group
    /// changes shape under load. Every shape VideoToolbox gave loses what `isExpectedLoss` accepts, with no decode times.
    @Test(arguments: VideoToolboxDecodeOrders.all) func lossOnEveryShapeVideoToolboxEncodesIsExpected(decodeOrder: [Int]) throws {
        try #require(decodeOrder.sorted() == Array(0..<50))
        var order = Order()
        let shown = push(decodeOrder, into: &order) + order.restart()   // the closing IDR releases what is held
        #expect(zip(shown.dropFirst(), shown).allSatisfy { $0 > $1 }, "\(shown)")
        let missing = Set(decodeOrder).subtracting(shown)
        #expect(isExpectedLoss(missing, decodeOrder: decodeOrder), "missing \(missing.sorted())")
    }
}

/// Whether a transcoder that learns the reordering from presentation times alone may lose `missing` (picture numbers)
/// of a source decoded in `decodeOrder` (picture numbers), derived from the decode order only (not by replaying it
/// through `PresentationOrder`).
///
/// Nothing is held until presentation times first step back, so the newest picture before that step (the first anchor)
/// is already out: every picture decoded after it but presented before it must be lost. Once the buffer is as deep as
/// the stream reorders (the most pictures decoded ahead of one and presented after it), nothing more is lost, so only
/// reordered pictures presented before the newest one decoded until then may be. The two coincide when the first group
/// reorders as deep as any (VideoToolbox's usual shapes); a deeper group later loses the picture that reveals it.
func isExpectedLoss(_ missing: Set<Int>, decodeOrder: [Int]) -> Bool {
    let presentedLater = decodeOrder.indices.map { index in decodeOrder[..<index].count { $0 > decodeOrder[index] } }
    guard let firstStep = presentedLater.firstIndex(where: { $0 > 0 }), let deepest = presentedLater.max(),
          let settled = presentedLater.firstIndex(of: deepest) else { return missing.isEmpty }   // no reordering: nothing lost
    let firstAnchor = decodeOrder[..<firstStep].max() ?? .min
    let lost = Set(decodeOrder[firstStep...].filter { $0 < firstAnchor })
    let newestSettled = decodeOrder[...settled].max() ?? .min
    let mayBeLost = Set(decodeOrder.indices.filter { presentedLater[$0] > 0 && decodeOrder[$0] < newestSettled }.map { decodeOrder[$0] })
    return missing.isSuperset(of: lost) && missing.isSubset(of: mayBeLost)
}

/// Decode orders (picture numbers) of `BFrameStream.encode(count: 51, keyframes: [50])` without the closing IDR, as
/// VideoToolbox gave them alone (the first) and with other encode sessions running: the first group's shape varies,
/// and in some a later group reorders deeper than the first.
enum VideoToolboxDecodeOrders {
    static let all: [[Int]] = [
        [0, 4, 2, 1, 3, 8, 6, 5, 7, 12, 10, 9, 11, 16, 14, 13, 15, 20, 18, 17, 19, 24, 22, 21, 23, 28, 26, 25, 27, 32, 30, 29, 31,
         36, 34, 33, 35, 40, 38, 37, 39, 44, 42, 41, 43, 48, 46, 45, 47, 49],
        [0, 1, 5, 3, 2, 4, 9, 7, 6, 8, 13, 11, 10, 12, 17, 15, 14, 16, 21, 19, 18, 20, 25, 23, 22, 24, 29, 27, 26, 28, 33, 31, 30,
         32, 37, 35, 34, 36, 41, 39, 38, 40, 45, 43, 42, 44, 49, 47, 46, 48],
        [0, 1, 4, 3, 2, 5, 9, 7, 6, 8, 10, 11, 15, 13, 12, 14, 19, 17, 16, 18, 20, 21, 25, 23, 22, 24, 29, 27, 26, 28, 33, 31, 30,
         32, 37, 35, 34, 36, 41, 39, 38, 40, 45, 43, 42, 44, 49, 47, 46, 48],
        [0, 1, 2, 6, 4, 3, 5, 10, 8, 7, 9, 11, 12, 16, 14, 13, 15, 20, 18, 17, 19, 21, 22, 26, 24, 23, 25, 30, 28, 27, 29, 34, 32,
         31, 33, 38, 36, 35, 37, 40, 39, 41, 45, 43, 42, 44, 47, 46, 48, 49],
        [0, 1, 2, 3, 7, 5, 4, 6, 11, 9, 8, 10, 12, 13, 17, 15, 14, 16, 21, 19, 18, 20, 22, 23, 27, 25, 24, 26, 31, 29, 28, 30, 35,
         33, 32, 34, 37, 36, 38, 42, 40, 39, 41, 46, 44, 43, 45, 47, 48, 49],
        [0, 3, 2, 1, 4, 8, 6, 5, 7, 12, 10, 9, 11, 16, 14, 13, 15, 20, 18, 17, 19, 24, 22, 21, 23, 28, 26, 25, 27, 30, 29, 31, 35,
         33, 32, 34, 39, 37, 36, 38, 40, 41, 45, 43, 42, 44, 49, 47, 46, 48],
        // One B-frame per group throughout.
        [0, 2, 1, 4, 3, 6, 5, 8, 7, 10, 9, 12, 11, 14, 13, 16, 15, 18, 17, 20, 19, 22, 21, 24, 23, 26, 25, 28, 27, 30, 29, 32, 31,
         34, 33, 36, 35, 38, 37, 40, 39, 42, 41, 44, 43, 46, 45, 48, 47, 49],
        // A first group with one or two B-frames, then deeper groups.
        [0, 2, 1, 3, 7, 5, 4, 6, 11, 9, 8, 10, 15, 13, 12, 14, 19, 17, 16, 18, 23, 21, 20, 22, 27, 25, 24, 26, 31, 29, 28, 30, 35,
         33, 32, 34, 39, 37, 36, 38, 41, 40, 42, 46, 44, 43, 45, 49, 48, 47],
        [0, 1, 3, 2, 4, 8, 6, 5, 7, 12, 10, 9, 11, 13, 14, 18, 16, 15, 17, 22, 20, 19, 21, 26, 24, 23, 25, 28, 27, 29, 33, 31, 30,
         32, 37, 35, 34, 36, 41, 39, 38, 40, 45, 43, 42, 44, 49, 47, 46, 48],
    ]
}
#endif
