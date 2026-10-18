// The B-frame test stream keeps its promise: keyframes exactly where asked, also while other encodes run (macOS only).
#if os(macOS)
import Foundation
import MediaCore
import Testing

/// VideoToolbox's hardware encoder adds keyframes of its own while other sessions use it (about a third of 16 parallel encodes had one),
/// which moved where BFrameIngestTests joined the stream (at picture 19 instead of 30: 41 pictures shown instead of 30). Here other
/// sessions encode on the hardware encoder at the same time, as the bridge's transcoders in other tests and test processes do, and the
/// stream still has exactly the keyframes asked for.
@Suite(.timeLimit(.minutes(1))) struct BFrameStreamTests {
    @Test func keyframesAreTheRequestedOnesWhileOtherSessionsEncode() throws {
        let others = DispatchGroup()
        for _ in 0..<6 {
            DispatchQueue.global().async(group: others) {
                for _ in 0..<3 { _ = try? BFrameStream.encodeUnchecked(count: 61, fps: 25, keyframes: [30, 60], hardware: true) }
            }
        }
        defer { others.wait() }
        for attempt in 0..<4 {
            let source = try BFrameStream.encode(count: 61, fps: 25, keyframes: [30, 60])
            #expect(source.filter(\.isKeyframe).map { BFrameStream.index(ofPTS: $0.pts) } == [0, 30, 60], "encode \(attempt)")
            #expect(BFrameStream.reorders(source), "encode \(attempt) has B-frames")
        }
    }
}
#endif
