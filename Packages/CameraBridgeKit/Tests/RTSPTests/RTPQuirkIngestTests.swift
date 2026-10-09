// Cameras whose RTP timestamps and marker bits do not delimit pictures (a Tapo C-series sends consecutive pictures with the
// same timestamp, keyframes stamped ahead of the pictures after them, and a malformed vendor SEI before most pictures):
// every picture must still reach the decoder as its own access unit, with strictly increasing times.
#if os(macOS)
import BridgeSupport
import Foundation
import MediaCore
import Testing
@testable import RTSP

@Suite(.timeLimit(.minutes(3))) struct RTPQuirkIngestTests {
    static let fps = 20
    static let step = UInt32(90_000 / fps)

    /// A vendor SEI like the Tapo's: payload type 764, declared size 34, only 32 bytes present.
    static let malformedSEI = Data([0x06, 0xFF, 0xFF, 0xFE, 34] + (0..<32).map { UInt8(truncatingIfNeeded: 0x40 + $0) })

    /// Real VideoToolbox pictures (no B-frames) with the SEI in front of every delta frame and every second keyframe, like
    /// the camera's.
    static func syntheticFrames(count: Int = 61, keyframeInterval: Int = 20) throws -> [EncodedVideoFrame] {
        var frames = try VideoToolboxFrames.encodeH264(width: 640, height: 360, count: count, keyframeInterval: keyframeInterval)
        for index in frames.indices where !frames[index].isKeyframe || index % 2 == 0 {
            frames[index].nalUnits.insert(malformedSEI, at: 0)
        }
        for index in frames.indices {   // the stream's 20 fps clock
            frames[index].pts = MediaTime(value: Int64(index) * Int64(Self.step), timescale: 90_000)
        }
        return frames
    }

    /// NAL units a decoder needs from `frame`: everything but SEI.
    static func slices(_ frame: EncodedVideoFrame) -> [Data] {
        frame.nalUnits.filter { NALUnits.h264Type($0) != 6 }
    }

    static func check(_ frames: [EncodedVideoFrame], quirk: RTPQuirk, width: Int, height: Int, comment: String) async throws {
        let packets = QuirkyRTP.packets(frames, quirk: quirk, step: Self.step)
        let lastHasMarker = packets.last?.last?.marker ?? false
        let delivered = try await QuirkyRTP.ingest(packets, format: frames[0].format, fps: Self.fps)

        // One access unit per picture, in order, with the picture's own NAL units (a camera without markers leaves its last
        // picture open: it ends with the next one).
        let expected = lastHasMarker ? frames.count : frames.count - 1
        #expect(delivered.count == expected, "\(quirk.name): \(delivered.count) access units for \(frames.count) pictures \(comment)")
        for (index, frame) in delivered.enumerated() where index < frames.count {
            #expect(Self.slices(frame) == Self.slices(frames[index]), "\(quirk.name): access unit \(index) holds another picture's slices")
            #expect(frame.isKeyframe == frames[index].isKeyframe, "\(quirk.name): access unit \(index) keyframe flag")
        }
        // Strictly increasing decode times, no reordering of the pictures.
        let decode = delivered.map { ($0.dts ?? $0.pts).value }
        #expect(zip(decode.dropFirst(), decode).allSatisfy { $0 > $1 }, "\(quirk.name): decode times not strictly increasing \(decode)")
        let presentation = delivered.map(\.pts.value)
        #expect(zip(presentation.dropFirst(), presentation).allSatisfy { $0 > $1 }, "\(quirk.name): presentation times not increasing")
        // The timeline keeps the pictures' real spacing: the camera sent them 1/fps apart, so no step is a sliver of a frame
        // interval or a jump of many, and the whole stays within a frame of real time (a keyframe stamped ahead of its
        // pictures must not push every later one further ahead).
        let interval = Int64(Self.step)
        let steps = zip(decode.dropFirst(), decode).map { $0 - $1 }
        #expect(steps.allSatisfy { $0 >= interval / 3 && $0 <= 3 * interval }, "\(quirk.name): decode steps \(Set(steps).sorted()) (frame interval \(interval))")
        let drift = (decode[decode.count - 1] - decode[0]) - Int64(decode.count - 1) * interval
        #expect(abs(drift) <= 2 * interval, "\(quirk.name): timeline off by \(Double(drift) / 90_000) s after \(decode.count) pictures")

        // Through the hub, decoded directly and transcoded: every picture comes out.
        let hubbed = await QuirkyRTP.throughHub(delivered)
        #expect(hubbed.count == delivered.count)
        let decoded = try await QuirkyRTP.decode(hubbed)
        #expect(decoded.firstFailure == nil, "\(quirk.name): decoding failed at \(decoded.firstFailure.map { "#\($0.index): \($0.error)" } ?? "") \(comment)")
        #expect(decoded.pictures == hubbed.count, "\(quirk.name): \(decoded.pictures) of \(hubbed.count) pictures decoded")
        let transcoded = try await QuirkyRTP.transcode(hubbed, width: width, height: height, fps: 60)
        #expect(transcoded.count == hubbed.count, "\(quirk.name): \(transcoded.count) of \(hubbed.count) pictures transcoded \(comment)")
    }

    @Test(arguments: RTPQuirk.all) func syntheticStreamSurvivesTheQuirk(quirk: RTPQuirk) async throws {
        try await Self.check(try Self.syntheticFrames(), quirk: quirk, width: 640, height: 360, comment: "(synthetic)")
    }

    /// The local Tapo capture (private; skipped without it) through the same quirks.
    @Test(arguments: RTPQuirk.all) func tapoCaptureSurvivesTheQuirk(quirk: RTPQuirk) async throws {
        guard let pictures = TapoCapture.pictures() else { return }
        let frames = AnnexBPictures.frames(pictures, fps: Self.fps)
        try #require(frames.count == 208)
        try await Self.check(frames, quirk: quirk, width: 1280, height: 720, comment: "(capture)")
    }
}
#endif
