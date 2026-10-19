import BridgeEngine
import FMP4
import Foundation
import MediaCore
import Synchronization

// The frame source of the cell tests: frames made from a `FakeTimeline`'s fragments, with a latency the test sets on the virtual clock.

nonisolated final class FakeFrameSource: RecordedFrameSource {
    enum Kind: Equatable { case initialization, keyframe, fragment }

    static let format = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [Data([0x67, 1, 2, 3]), Data([0x68, 4])])

    private struct State {
        var reads: [(kind: Kind, id: String)] = []
        var inFlight = 0
        var peakInFlight = 0
        var failures: [String: any Error] = [:]
        var allFail: (any Error)?
    }

    private let state = Mutex(State())
    let fps: Double
    let withSound: Bool
    /// The picture's width (the init segment says it).
    let width: Int
    /// Runs before each read returns (latency on the virtual clock).
    private let latency: Mutex<(@Sendable (Kind) async throws -> Void)?> = Mutex(nil)

    init(fps: Double = 25, withSound: Bool = false, width: Int = 640) {
        self.fps = fps
        self.withSound = withSound
        self.width = width
    }

    func setLatency(_ handler: (@Sendable (Kind) async throws -> Void)?) { latency.withLock { $0 = handler } }
    func fail(fragment id: String, with error: any Error) { state.withLock { $0.failures[id] = error } }
    func failEverything(with error: (any Error)?) { state.withLock { $0.allFail = error } }

    var reads: [(kind: Kind, id: String)] { state.withLock { $0.reads } }
    func ids(of kind: Kind) -> [String] { reads.filter { $0.kind == kind }.map(\.id) }
    var peakInFlight: Int { state.withLock { $0.peakInFlight } }

    private func enter(_ kind: Kind, _ id: String) async throws {
        let failure = state.withLock { state -> (any Error)? in
            state.reads.append((kind, id))
            state.inFlight += 1
            state.peakInFlight = max(state.peakInFlight, state.inFlight)
            return state.failures[id] ?? state.allFail
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        if let latency = latency.withLock({ $0 }) { try await latency(kind) }
        if let failure { throw failure }
    }

    func initInfo(for fragment: ArchiveFragment) async throws -> FMP4InitInfo {
        try await enter(.initialization, fragment.id)
        var video = Self.format
        video.width = width
        return FMP4InitInfo(video: video, videoTimescale: 90_000, nalLengthSize: 4, videoTrackID: 1,
                            audio: withSound ? .aacLC(sampleRate: 16_000, channels: 1) : nil, audioTrackID: withSound ? 2 : nil, byteCount: 600)
    }

    func keyframe(of fragment: ArchiveFragment, info: FMP4InitInfo) async throws -> EncodedVideoFrame {
        try await enter(.keyframe, fragment.id)
        return video(of: fragment)[0]
    }

    func frames(of fragment: ArchiveFragment, info: FMP4InitInfo, withAudio: Bool) async throws -> DecodedFragment {
        try await enter(.fragment, fragment.id)
        return DecodedFragment(video: video(of: fragment), audio: withAudio && withSound ? audio(of: fragment) : [])
    }

    /// The frames of `fragment`: one every `1 / fps` seconds from its start; the first is a keyframe when the fragment holds one.
    func video(of fragment: ArchiveFragment) -> [EncodedVideoFrame] {
        let count = Int((fragment.duration * fps).rounded())
        return (0..<count).map { index in
            let date = fragment.start.addingTimeInterval(Double(index) / fps)
            let key = index == 0 && fragment.hasKeyframe
            return EncodedVideoFrame(format: Self.format, nalUnits: [Data([key ? 0x65 : 0x41, UInt8(index & 0xFF)])], isKeyframe: key,
                                     pts: MediaTime(value: Int64((date.timeIntervalSinceReferenceDate * 90_000).rounded()), timescale: 90_000), wallClock: date)
        }
    }

    /// AAC frames of 64 ms (1024 samples at 16 kHz).
    func audio(of fragment: ArchiveFragment) -> [EncodedAudioFrame] {
        let count = Int(fragment.duration / 0.064)
        return (0..<count).map { index in
            let date = fragment.start.addingTimeInterval(Double(index) * 0.064)
            return EncodedAudioFrame(format: .aacLC(sampleRate: 16_000, channels: 1), data: Data([1, 2]),
                                     pts: MediaTime(value: Int64(index) * 1_024, timescale: 16_000), sampleCount: 1_024, wallClock: date)
        }
    }
}
