// A camera with quirky video timestamps next to its audio: the recording (GOPFragmenter + FMP4Muxer, what HKSV uses) must
// keep the audio. A video timeline pushed ahead of the audio by keyframes stamped ahead of their pictures made the muxer drop
// the audio as "before the recording's first picture".
#if os(macOS)
import BridgeSupport
import FMP4
import Foundation
import MediaCore
import RTP
import Testing
@testable import RTSP

@Suite(.timeLimit(.minutes(3))) struct RTPQuirkRecordingTests {
    static let fps = 20
    static let step = UInt32(90_000 / fps)
    static let audioFormat = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)

    /// Video pictures (`quirk`-stamped) and 20 ms PCMU packets, arriving in real time, through one `MediaPipeline`.
    static func ingest(_ frames: [EncodedVideoFrame], quirk: RTPQuirk) async throws -> [MediaSample] {
        let video = RTSPTrack(kind: .video, control: "v", payloadType: 96, encoding: "H264", clockRate: 90_000)
        let audio = RTSPTrack(kind: .audio, control: "a", payloadType: 0, encoding: "PCMU", clockRate: 8_000)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MediaSample.self)
        let plans = [MediaPipeline.TrackPlan(track: video, rtpChannel: 0, rtcpChannel: 1, videoFormat: frames[0].format, audioFormat: nil),
                     MediaPipeline.TrackPlan(track: audio, rtpChannel: 2, rtcpChannel: 3, videoFormat: nil, audioFormat: Self.audioFormat)]
        let pipeline = MediaPipeline(plans: plans, continuation: continuation, log: Log(category: "RTPQuirkRecordingTests"))

        struct Event { var time: Double; var channel: UInt8; var packet: RTPPacket }
        var events: [Event] = []
        for (index, group) in QuirkyRTP.packets(frames, quirk: quirk, step: Self.step).enumerated() {
            for packet in group { events.append(Event(time: Double(index) / Double(Self.fps), channel: 0, packet: packet)) }
        }
        let duration = Double(frames.count) / Double(Self.fps)
        var audioTimestamp: UInt32 = 5_000
        var sequence: UInt16 = 900
        var time = 0.003   // audio flows from just after the first picture
        while time < duration {
            events.append(Event(time: time, channel: 2, packet: RTPPacket(marker: false, payloadType: 0, sequenceNumber: sequence, timestamp: audioTimestamp, ssrc: 0xA0D1,
                                                                        payload: Data(repeating: 0x55, count: 160))))
            sequence &+= 1
            audioTimestamp &+= 160
            time += 0.02
        }
        let start = Date()
        for event in events.sorted(by: { $0.time < $1.time }) {
            pipeline.handle(channel: event.channel, payload: event.packet.serialized(), arrival: start.addingTimeInterval(event.time))
        }
        pipeline.finish(throwing: nil)
        var samples: [MediaSample] = []
        for try await sample in stream { samples.append(sample) }
        return samples
    }

    /// Records `samples` like the recording producer: fragments of 2 s, AAC-LC audio (the PCMU frames stand in for transcoded
    /// AAC frames with the same times). Returns the audio frames the muxer dropped and how many it was given.
    static func record(_ samples: [MediaSample]) throws -> (dropped: Int, outOfRange: Int, offered: Int, written: Int) {
        guard case .video(let first)? = samples.first(where: { if case .video = $0 { true } else { false } }) else { return (0, 0, 0, 0) }
        let aac = AudioFormat.aacLC(sampleRate: 8_000, channels: 1)
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: first.format, audio: aac))
        var fragmenter = GOPFragmenter(targetDuration: .seconds(2))
        var dropped = 0, outOfRange = 0, offered = 0, written = 0
        func mux(_ groups: [FragmentGroup]) throws {
            for group in groups {
                offered += group.audio.count
                _ = try muxer.fragment(group)
                dropped += muxer.lastFragmentStatistics.droppedAudioFrames
                outOfRange += muxer.lastFragmentStatistics.outOfRangeAudioFrames
                written += muxer.lastFragmentStatistics.audioSamples
            }
        }
        for sample in samples {
            switch sample {
            case .video:
                try mux(fragmenter.pushGroups(sample))
            case .audio(let frame):
                try mux(fragmenter.pushGroups(.audio(EncodedAudioFrame(format: aac, data: frame.data, pts: frame.pts, sampleCount: frame.sampleCount,
                                                                       wallClock: frame.wallClock))))
            }
        }
        try mux(fragmenter.flushGroups())
        return (dropped, outOfRange, offered, written)
    }

    @Test(arguments: RTPQuirk.all) func recordingKeepsTheAudio(quirk: RTPQuirk) async throws {
        let frames = try RTPQuirkIngestTests.syntheticFrames(count: 101, keyframeInterval: 20)
        let samples = try await Self.ingest(frames, quirk: quirk)

        // Video and audio stay on one timeline: each one's time minus its arrival is the same, within a frame, all along.
        func offsets(video: Bool) -> [Double] {
            samples.enumerated().compactMap { _, sample in
                switch sample {
                case .video(let frame) where video: (frame.dts ?? frame.pts).seconds - frame.wallClock.timeIntervalSinceReferenceDate
                case .audio(let frame) where !video: frame.pts.seconds - frame.wallClock.timeIntervalSinceReferenceDate
                default: nil
                }
            }
        }
        let videoOffsets = offsets(video: true), audioOffsets = offsets(video: false)
        try #require(!videoOffsets.isEmpty && !audioOffsets.isEmpty)
        let videoSpread = (videoOffsets.max() ?? 0) - (videoOffsets.min() ?? 0)
        #expect(videoSpread <= 0.15, "\(quirk.name): video times wander \(videoSpread) s against the wall clock")

        let result = try Self.record(samples)
        // Audio before the first picture goes (a few packets at the start); everything after it is written.
        #expect(result.offered > 200, "\(quirk.name): only \(result.offered) audio frames reached the muxer")
        #expect(result.dropped + result.outOfRange <= 10, "\(quirk.name): \(result.dropped) of \(result.offered) audio frames dropped, \(result.outOfRange) out of range")
    }
}
#endif
