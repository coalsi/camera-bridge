#if os(macOS)
import CoreMedia
import Foundation
import MediaCore
import Testing
@testable import PlatformApple

/// The live transcoder's own failure handling (audit 2 F2, R2, R8).
@Suite(.timeLimit(.minutes(2))) struct CodecsTranscoderRobustnessTests {
    static let output = VideoEncoderSettings(width: 640, height: 360, fps: 30, bitrateKbps: 800, profile: .main, level: .level4_0, keyframeInterval: .seconds(2))

    /// A keyframe whose slice data is garbage (same parameter sets as a real stream).
    private static func corruptKeyframe(like frame: EncodedVideoFrame) -> EncodedVideoFrame {
        var bad = frame
        var bytes = [UInt8](repeating: 0x5A, count: 400)
        bytes[0] = 0x65
        bad.nalUnits = [Data(bytes)]
        return bad
    }

    @Test func aKeyframeDecodeFailureSwitchesToSoftwareDecodingAfterTwoInARow() async throws {
        let stream = try CodecFixtures.encodedStream(width: 640, height: 360, count: 40, bitrateKbps: 800, keyframeInterval: .seconds(1))
        let transcoder = try AppleVideoTranscoder(output: Self.output)
        defer { transcoder.invalidate() }
        let nextKeyframe = try #require(stream.indices.first { $0 > 0 && stream[$0].isKeyframe })
        // A good keyframe first: the decoder exists and is the hardware one (if this Mac has it).
        _ = try transcoder.transcodeNow(stream[0])
        #expect(!transcoder.decoderIsSoftware)
        let bad = Self.corruptKeyframe(like: stream[0])
        var failures = 0
        for _ in 0..<2 {
            do { _ = try transcoder.transcodeNow(bad) } catch { failures += 1 }
        }
        #expect(failures == 2, "a garbage keyframe is an error, not silence")
        #expect(transcoder.decoderIsSoftware, "two keyframes in a row the decoder failed on: the next session is a software one")
        // And the stream recovers on the next good keyframe.
        let recovered = try transcoder.transcodeNow(stream[nextKeyframe])
        #expect(recovered.count == 1, "the next good keyframe decodes with the software decoder and is encoded again")
    }

    @Test func oneKeyframeFailureDoesNotSwitchTheDecoderAndAGoodKeyframeResetsTheCount() async throws {
        let stream = try CodecFixtures.encodedStream(width: 640, height: 360, count: 4, bitrateKbps: 800, keyframeInterval: .seconds(1))
        let transcoder = try AppleVideoTranscoder(output: Self.output)
        defer { transcoder.invalidate() }
        _ = try transcoder.transcodeNow(stream[0])
        let bad = Self.corruptKeyframe(like: stream[0])
        do { _ = try transcoder.transcodeNow(bad) } catch {}
        _ = try transcoder.transcodeNow(stream[0])   // a good one resets the count
        do { _ = try transcoder.transcodeNow(bad) } catch {}
        #expect(!transcoder.decoderIsSoftware)
    }

    @Test func aKeyframeRequestThatDidNotReachTheEncoderIsKept() async throws {
        let stream = try CodecFixtures.encodedStream(width: 640, height: 360, count: 40, bitrateKbps: 800, keyframeInterval: .seconds(4))
        let transcoder = try AppleVideoTranscoder(output: Self.output)
        defer { transcoder.invalidate() }
        for frame in stream.prefix(5) { _ = try transcoder.transcodeNow(frame) }
        transcoder.requestKeyframe()
        // The encode fails once: the request must survive for the next picture.
        transcoder.injectEncoderFailures(1)
        _ = try? transcoder.transcodeNow(stream[5])
        var out = try transcoder.transcodeNow(stream[6])
        out += try transcoder.transcodeNow(stream[7])
        #expect(out.contains { $0.isKeyframe }, "the requested keyframe came out once the encoder worked again")
    }

    @Test func theTranscoderSaysWhatItRunsOnAndSamplesItsInput() async throws {
        let stream = try CodecFixtures.encodedStream(width: 640, height: 360, count: 12, bitrateKbps: 800, keyframeInterval: .seconds(1))
        let transcoder = try AppleVideoTranscoder(output: Self.output)
        defer { transcoder.invalidate() }
        #expect(transcoder.diagnostics.inputPicture == nil && transcoder.diagnostics.lastKeyframeBytes == nil)
        for frame in stream { _ = try transcoder.transcodeNow(frame) }
        let diagnostics = transcoder.diagnostics
        #expect(diagnostics.inputPicture.map { !$0.isBlank } == true, "the sampled input picture is a real picture")
        #expect((diagnostics.lastKeyframeBytes ?? 0) > 0)
        #expect(diagnostics.lastKeyframeWidth == 640 && diagnostics.lastKeyframeHeight == 360)
        #expect((diagnostics.millisecondsPerPicture ?? 0) > 0)
        #expect(diagnostics.decoderIsHardware != nil && diagnostics.encoderIsHardware != nil, "VideoToolbox says which codecs it uses: \(diagnostics.codecDescription)")
    }
}
#endif
