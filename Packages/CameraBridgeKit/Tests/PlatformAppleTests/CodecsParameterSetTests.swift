#if os(macOS)
import BridgeSupport
import Foundation
import MediaCore
import Synchronization
import Testing
@testable import PlatformApple

private final class LogCapture: LogSink {
    private let entries = Mutex<[LogEntry]>([])

    func record(_ entry: LogEntry) {
        entries.withLock { $0.append(entry) }
    }

    func messages(category: String) -> [String] {
        entries.withLock { $0.filter { $0.category == category }.map(\.message) }
    }
}

/// A camera whose P pictures use another PPS than its IDR pictures (field report, Tapo C-series: the first picture of each GOP
/// decoded, every delta frame after it failed with kVTVideoDecoderBadDataErr, -12909): a decoder resolves the PPS a slice names
/// from its format description's avcC, so the format must carry every PPS the stream uses.
@Suite(.serialized, .timeLimit(.minutes(2))) struct CodecsParameterSetTests {
    /// Baseline 640×360 with its IDR on PPS 0 and its P pictures (slice headers rewritten) on PPS 1; `formats` per frame.
    struct Stream {
        var frames: [EncodedVideoFrame]
        var single: VideoFormat
        var both: VideoFormat
    }

    static func stream(width: Int = 640, height: Int = 360, count: Int = 8, keyframeInterval: Duration = .seconds(20)) throws -> Stream {
        let plain = try CodecFixtures.encodedStream(width: width, height: height, count: count, bitrateKbps: 800, profile: .baseline,
                                                    keyframeInterval: keyframeInterval)
        try #require(plain.first?.isKeyframe == true)
        let single = plain[0].format
        let pps1 = H264StreamEditing.pps(single.parameterSets[1], id: 1)
        var both = single
        both.parameterSets = single.parameterSets + [pps1]
        var frames = plain
        for index in frames.indices.dropFirst() {
            frames[index].nalUnits = frames[index].nalUnits.map {
                NALUnits.h264Type($0) == 1 ? H264StreamEditing.slice($0, ppsID: 1) : $0
            }
        }
        return Stream(frames: frames, single: single, both: both)
    }

    @Test func theEditedStreamUsesTwoPPS() throws {
        let stream = try Self.stream()
        let slices = stream.frames.flatMap(\.nalUnits)
        #expect(slices.filter { NALUnits.h264Type($0) == 5 }.allSatisfy { H264StreamEditing.ppsID(ofSlice: $0) == 0 })
        #expect(slices.filter { NALUnits.h264Type($0) == 1 }.allSatisfy { H264StreamEditing.ppsID(ofSlice: $0) == 1 })
        #expect(NALUnits.h264PPSIDs(stream.both.parameterSets[2])?.id == 1)
    }

    @Test func aDecoderRejectsSlicesThatNameAPPSItsFormatLacks() throws {
        let stream = try Self.stream()
        let lacking = try AppleVideoDecoder(format: stream.single)
        defer { lacking.invalidate() }
        #expect(try lacking.decodeAllNow(stream.frames[0]).count == 1)   // the IDR names PPS 0
        for frame in stream.frames.dropFirst().prefix(3) {
            #expect(throws: MediaCodecError.sessionFailed(-12909)) { _ = try lacking.decodeAllNow(frame) }
        }
        let carrying = try AppleVideoDecoder(format: stream.both)
        defer { carrying.invalidate() }
        for var frame in stream.frames {
            frame.format = stream.both   // what the depacketizer hands out once it has seen both PPS
            #expect(try carrying.decodeAllNow(frame).count == 1)
        }
    }

    @Test func aTranscoderDecodesEveryPictureOfAStreamWithASecondPPS() throws {
        let stream = try Self.stream()
        let transcoder = try AppleVideoTranscoder(output: VideoEncoderSettings(width: 320, height: 180, fps: 30, bitrateKbps: 300))
        defer { transcoder.invalidate() }
        var output = 0
        for var frame in stream.frames {
            frame.format = stream.both
            output += try transcoder.transcodeNow(frame).count
        }
        #expect(output == stream.frames.count)
    }

    @Test func aTranscoderThatCannotDecodeDeltaFramesSaysWhichParameterSetsItHas() throws {
        let capture = LogCapture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let stream = try Self.stream()
        let transcoder = try AppleVideoTranscoder(output: VideoEncoderSettings(width: 320, height: 180, fps: 30, bitrateKbps: 300))
        defer { transcoder.invalidate() }
        var output = 0
        for var frame in stream.frames {
            frame.format = stream.single
            output += try transcoder.transcodeNow(frame).count
        }
        #expect(output == 1, "only the keyframe decodes")
        let warnings = capture.messages(category: "VideoTranscoder").filter { $0.contains("dropping undecodable delta frame") }
        #expect(warnings.count == 1, "the first failure waits for a keyframe; the rest are skipped quietly")
        #expect(warnings.first?.contains("-12909") == true && warnings.first?.contains("H.264 640×360, 1 SPS + 1 PPS") == true, "\(warnings)")
    }

    /// A camera that sends its second PPS in front of a P picture: the format of that delta frame carries both, which is the
    /// same stream with one more set, so decoding goes on instead of waiting for the next keyframe.
    @Test func furtherParameterSetsOnADeltaFrameDoNotMakeTheTranscoderWaitForAKeyframe() throws {
        let capture = LogCapture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let stream = try Self.stream()
        let transcoder = try AppleVideoTranscoder(output: VideoEncoderSettings(width: 320, height: 180, fps: 30, bitrateKbps: 300))
        defer { transcoder.invalidate() }
        var output = 0
        for (index, var frame) in stream.frames.enumerated() {
            frame.format = index == 0 ? stream.single : stream.both
            output += try transcoder.transcodeNow(frame).count
        }
        #expect(output == stream.frames.count)
        let messages = capture.messages(category: "VideoTranscoder")
        #expect(messages.contains { $0.contains("further parameter sets arrived with a delta frame") && $0.contains("1 SPS + 2 PPS") }, "\(messages)")
        #expect(!messages.contains { $0.contains("waiting for the next keyframe") })
    }

    @Test func aChangedParameterSetOnADeltaFrameStillWaitsForTheNextKeyframe() throws {
        let capture = LogCapture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let first = try CodecFixtures.encodedStream(width: 640, height: 360, count: 3, bitrateKbps: 800, keyframeInterval: .seconds(20))
        var second = try CodecFixtures.encodedStream(width: 320, height: 180, count: 3, bitrateKbps: 400, keyframeInterval: .seconds(20))
        for index in second.indices { second[index].pts = second[index].pts + MediaTime(value: 900_000, timescale: 90_000) }   // later than `first`
        let transcoder = try AppleVideoTranscoder(output: VideoEncoderSettings(width: 320, height: 180, fps: 30, bitrateKbps: 300))
        defer { transcoder.invalidate() }
        #expect(try transcoder.transcodeNow(first[0]).count == 1)
        #expect(try transcoder.transcodeNow(first[1]).count == 1)
        #expect(try transcoder.transcodeNow(second[1]).isEmpty, "a delta frame of another stream: wait for its keyframe")
        #expect(try transcoder.transcodeNow(second[2]).isEmpty)
        #expect(try transcoder.transcodeNow(second[0]).count == 1, "its keyframe restarts decoding")
        let messages = capture.messages(category: "VideoTranscoder")
        #expect(messages.contains { $0.contains("parameter sets changed on a delta frame") && $0.contains("waiting for the next keyframe") }, "\(messages)")
    }

    /// Whatever else makes every delta frame after a keyframe fail (a stream the hardware decoder rejects though it is well formed),
    /// the transcoder rebuilds the decoder without the hardware decoder after two keyframes in a row without a decodable delta
    /// frame, and says why; a stream that fails in software too is reported once as the stream's fault.
    @Test func aTranscoderTriesSoftwareDecodingWhenNoDeltaFrameDecodesAfterTwoKeyframes() throws {
        let capture = LogCapture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let stream = try Self.stream(count: 130, keyframeInterval: .seconds(1))
        let keyframes = stream.frames.filter(\.isKeyframe).count
        try #require(keyframes >= 5, "keyframes: \(keyframes)")
        let transcoder = try AppleVideoTranscoder(output: VideoEncoderSettings(width: 320, height: 180, fps: 30, bitrateKbps: 300))
        defer { transcoder.invalidate() }
        var output = 0
        for var frame in stream.frames {
            frame.format = stream.single   // the second PPS never reaches the decoder
            output += try transcoder.transcodeNow(frame).count
        }
        #expect(output == keyframes, "only the keyframes decode")
        let decoder = capture.messages(category: "VideoDecoder")
        let rebuilt = decoder.filter { $0.contains("decoder session rebuilt for") && $0.contains("(software)") }
        #expect(rebuilt.first?.contains("switching to software decoding, no delta frame decoded after 2 keyframes in a row") == true, "\(decoder)")
        #expect(rebuilt.first?.contains("H.264 640×360, 1 SPS + 1 PPS (software)") == true, "\(decoder)")
        // Every failed delta frame also drops the session (its state is unknown), whichever decoder it was.
        #expect(decoder.contains { $0.contains("decoder session rebuilt for") && $0.contains("after a delta frame it failed on") }, "\(decoder)")
        let atFault = capture.messages(category: "VideoTranscoder").filter { $0.contains("software decoder rejects the delta frames") }
        #expect(atFault.count == 1, "said once")
    }

    @Test func aGoodStreamStaysOnTheHardwareDecoder() throws {
        let capture = LogCapture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let plain = try CodecFixtures.encodedStream(width: 640, height: 360, count: 130, bitrateKbps: 800, keyframeInterval: .seconds(1))
        let transcoder = try AppleVideoTranscoder(output: VideoEncoderSettings(width: 320, height: 180, fps: 30, bitrateKbps: 300))
        defer { transcoder.invalidate() }
        var output = 0
        for frame in plain { output += try transcoder.transcodeNow(frame).count }
        #expect(output == plain.count)
        #expect(!capture.messages(category: "VideoDecoder").contains { $0.contains("software") })
    }

    @Test func theSoftwareDecoderDecodesAnOrdinaryStream() throws {
        let plain = try CodecFixtures.encodedStream(width: 640, height: 360, count: 40, bitrateKbps: 800, keyframeInterval: .seconds(1))
        let decoder = try AppleVideoDecoder(format: plain[0].format)
        defer { decoder.invalidate() }
        #expect(try decoder.decodeAllNow(plain[0]).count == 1)
        decoder.useSoftwareDecoding(reason: "test")
        #expect(decoder.isSoftware)
        decoder.resetSession(reason: "test")
        // The new session starts at the next keyframe (frame 30), as the transcoder arranges.
        for frame in plain.dropFirst(30) { #expect(try decoder.decodeAllNow(frame).isEmpty == false) }
    }

    @Test func aDecoderSaysWhenItCreatesASessionAndWhenAFormatChangeRebuildsIt() throws {
        let capture = LogCapture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let small = try CodecFixtures.encodedStream(width: 640, height: 360, count: 2, bitrateKbps: 800, keyframeInterval: .seconds(20))
        let large = try CodecFixtures.encodedStream(width: 1280, height: 720, count: 2, bitrateKbps: 1_500, keyframeInterval: .seconds(20))
        let decoder = try AppleVideoDecoder(format: small[0].format)
        defer { decoder.invalidate() }
        _ = try decoder.decodeAllNow(small[0])
        _ = try decoder.decodeAllNow(large[0])
        let messages = capture.messages(category: "VideoDecoder")
        #expect(messages.contains { $0.contains("decoder session created for H.264 640×360, 1 SPS + 1 PPS") }, "\(messages)")
        let change = messages.first { $0.contains("decoder format changed") }
        #expect(change?.contains("H.264 640×360") == true && change?.contains("H.264 1280×720") == true, "\(messages)")
        #expect(change?.contains("session rebuilt") == true || change?.contains("session kept") == true, "the line says what became of the session: \(messages)")
    }
}
#endif
