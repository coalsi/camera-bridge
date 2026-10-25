import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

extension RecorderFixtures {
    static let pcmu8k = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)

    /// G.711 camera audio: 20 ms (160 samples) a frame.
    static func g711Frames(seconds: Double) -> [EncodedAudioFrame] {
        (0..<Int(seconds * 50)).map { number in
            EncodedAudioFrame(format: pcmu8k, data: Data((0..<160).map { UInt8(truncatingIfNeeded: number &+ $0) }),
                              pts: MediaTime(value: Int64(number) * 160, timescale: 8_000), sampleCount: 160,
                              wallClock: base.addingTimeInterval(Double(number) * 0.02))
        }
    }
}

/// Codecs that can do exactly one thing: turn G.711 into AAC-LC (a fake: one AAC frame for every six G.711 frames), or refuse.
final class FakeAudioCodecs: MediaCodecs, Sendable {
    private let converts: Bool
    /// How many audio converters were made (each is a process or an encoder session on the box).
    let convertersMade = Box(0)

    init(converts: Bool) {
        self.converts = converts
    }

    private struct Unsupported: Error {}

    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { throw Unsupported() }
    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { throw Unsupported() }
    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { throw Unsupported() }
    func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data { throw Unsupported() }
    func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { throw Unsupported() }
    func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] { throw Unsupported() }
    func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration, audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource {
        fatalError("not used")
    }

    func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding {
        guard converts, input.codec == .pcmu, output.codec == .aac else { throw Unsupported() }
        convertersMade.update { $0 += 1 }
        return FakeG711ToAAC(sampleRate: input.sampleRate, channels: output.channels)
    }
}

final class FakeG711ToAAC: AudioTranscoding {
    let outputFormat: AudioFormat
    private let seen = Box(0)

    init(sampleRate: Int, channels: Int) {
        outputFormat = .aacLC(sampleRate: sampleRate, channels: channels)
    }

    func transcode(_ frame: EncodedAudioFrame) throws -> [EncodedAudioFrame] {
        let count = seen.update { value -> Int in
            value += 1
            return value
        }
        guard count % 6 == 0 else { return [] }
        let first = frame.pts.value - 5 * 160
        return [EncodedAudioFrame(format: outputFormat, data: Data([0xAA, UInt8(truncatingIfNeeded: count)]), pts: MediaTime(value: first, timescale: frame.pts.timescale),
                                  sampleCount: 1_024, wallClock: frame.wallClock)]
    }

    func flush() throws -> [EncodedAudioFrame] { [] }
}

/// Record sound (Mac spec 5): off by default, AAC-LC as it comes, other camera audio converted, and a note when sound cannot be recorded.
@Suite struct RecorderAudioTests {
    static func record(_ rig: RecorderRig, recorder: CameraArchiveRecorder, video: Range<Int>, audio: [EncodedAudioFrame]) async {
        let frames = RecorderFixtures.videoFrames(video, gop: 60)
        await rig.feed(RecorderFixtures.interleaved(frames, audio), to: recorder)
    }

    @Test func aacPassesThroughIntoASoundTrackAndComesBackUnchanged() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        let sound = RecorderFixtures.audioFrames(seconds: 5)
        await Self.record(rig, recorder: recorder, video: 0..<150, audio: sound)
        await recorder.stop()
        let segment = try #require(rig.target.openedSegments.first)
        guard case .opened(_, _, _, let hasAudio)? = rig.target.events.first else { Issue.record("no open event"); return }
        #expect(hasAudio)
        let file = try RecordedFile(rig, segment: segment)
        #expect(file.info.audio == RecorderFixtures.aac32k && file.index.hasAudio && file.info.audioTrackID == 2)
        let out = try file.audioFrames()
        #expect(out.map(\.data) == sound.map(\.data), "every AAC frame, byte-identical, in order")
        #expect(out.first?.pts.timescale == 32_000 && out.first.map { abs($0.wallClock.timeIntervalSince(file.start)) < 0.001 } == true)
        #expect(try file.videoFrames().count == 150)
        #expect(try file.rescanned() == file.index, "the sound does not change what the index says")
        #expect(recorder.status.notes.isEmpty)
    }

    @Test func soundIsOffByDefault() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: false))
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await Self.record(rig, recorder: recorder, video: 0..<150, audio: RecorderFixtures.audioFrames(seconds: 5))
        await recorder.stop()
        let file = try RecordedFile(rig, segment: item(rig.target.openedSegments, 0))
        #expect(file.info.audio == nil && !file.index.hasAudio && recorder.status.notes.isEmpty)
        #expect(try file.videoFrames().count == 150)
    }

    @Test func recordSoundWithCameraAudioOffSaysSoFromTheStart() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true, audioEnabled: false))
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        #expect(recorder.status.notes == [ArchiveNote(id: .sound, text: "no sound is recorded while Camera audio is off")])
        await Self.record(rig, recorder: recorder, video: 0..<150, audio: RecorderFixtures.audioFrames(seconds: 5))
        await recorder.stop()
        let file = try RecordedFile(rig, segment: item(rig.target.openedSegments, 0))
        #expect(file.info.audio == nil)
    }

    @Test func aCameraWithoutSoundGetsANoteAndAVideoOnlyFile() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        await rig.feed(RecorderFixtures.videoFrames(0..<150, gop: 60), to: recorder)
        await recorder.stop()
        let recorded = try RecordedFile(rig, segment: item(rig.target.openedSegments, 0))
        #expect(recorded.info.audio == nil)
        #expect(recorder.status.notes.isEmpty, "stopped recorders show nothing")
        let again = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        defer { again.root.remove() }
        let live = again.recorder()
        await live.start()
        await again.feed(RecorderFixtures.videoFrames(0..<150, gop: 60), to: live)
        #expect(live.status.notes == [ArchiveNote(id: .sound, text: "this camera sends no sound")])
        await live.stop()
    }

    @Test func g711IsConvertedToAACAtItsOwnRate() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        defer { rig.root.remove() }
        let recorder = rig.recorder(codecs: FakeAudioCodecs(converts: true))
        await recorder.start()
        await Self.record(rig, recorder: recorder, video: 0..<150, audio: RecorderFixtures.g711Frames(seconds: 5))
        await recorder.stop()
        let file = try RecordedFile(rig, segment: item(rig.target.openedSegments, 0))
        #expect(file.info.audio == AudioFormat.aacLC(sampleRate: 8_000, channels: 1), "AAC-LC at the source rate")
        let out = try file.audioFrames()
        #expect(out.count >= 40 && out.allSatisfy { $0.data.first == 0xAA }, "the converter's frames, not the G.711 bytes")
        #expect(recorder.status.notes.isEmpty)
    }

    @Test func audioTheCodecsCannotConvertMeansVideoOnlyAndANote() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        defer { rig.root.remove() }
        let recorder = rig.recorder(codecs: FakeAudioCodecs(converts: false))
        await recorder.start()
        await Self.record(rig, recorder: recorder, video: 0..<150, audio: RecorderFixtures.g711Frames(seconds: 5))
        #expect(recorder.status.notes == [ArchiveNote(id: .sound, text: "sound could not be recorded")])
        await recorder.stop()
        let file = try RecordedFile(rig, segment: item(rig.target.openedSegments, 0))
        let videoFrames = try file.videoFrames().count
        #expect(file.info.audio == nil && videoFrames == 150, "the video is complete")
    }

    @Test func aChangeOfTheCamerasAudioFormatEndsTheFile() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        let other = AudioFormat.aacLC(sampleRate: 16_000, channels: 1)
        // 32 kHz sound for the first 3 s, then the camera switches to 16 kHz (the same timeline: 48 000 ticks of 16 kHz are 3 s).
        let first = RecorderFixtures.audioFrames(seconds: 3)
        let second = (0..<150).map { number in
            EncodedAudioFrame(format: other, data: Data([UInt8(number), 7, 7, 7]), pts: MediaTime(value: 48_000 + Int64(number) * 1_024, timescale: 16_000),
                              sampleCount: 1_024, wallClock: RecorderFixtures.base.addingTimeInterval(3 + Double(number) * 0.064))
        }
        let video = RecorderFixtures.videoFrames(0..<300, gop: 60)
        await rig.feed(RecorderFixtures.interleaved(video, first + second), to: recorder)
        await recorder.stop()
        let segments = rig.target.openedSegments
        #expect(segments.count == 2)
        let a = try RecordedFile(rig, segment: item(segments, 0)), b = try RecordedFile(rig, segment: item(segments, 1))
        #expect(a.info.audio == RecorderFixtures.aac32k && b.info.audio == other)
        let framesInA = try a.videoFrames().count, framesInB = try b.videoFrames().count
        #expect(framesInA == 91 && framesInB == 180, "the first file ends with the frame at 3 s; frames 91...119 wait for the keyframe at 4 s, which opens the second file")
    }

    @Test func soundThatShowsUpAfterTheFirstFragmentRollsTheFileSoTheNextOneHasIt() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        defer { rig.root.remove() }
        let recorder = rig.recorder()
        await recorder.start()
        let video = RecorderFixtures.videoFrames(0..<300, gop: 60)
        await rig.feed(Array(video[0..<130]), to: recorder)                                  // 4.3 s of video, no sound: the file has no sound track
        let late = RecorderFixtures.audioFrames(seconds: 10).filter { $0.pts.seconds >= 4.4 }
        await rig.feed(RecorderFixtures.interleaved(Array(video[130..<300]), late), to: recorder)
        await recorder.stop()
        let segments = rig.target.openedSegments
        #expect(segments.count == 2)
        let a = try RecordedFile(rig, segment: item(segments, 0)), b = try RecordedFile(rig, segment: item(segments, 1))
        #expect(a.info.audio == nil && b.info.audio == RecorderFixtures.aac32k)
        let framesInA = try a.videoFrames().count, framesInB = try b.videoFrames().count
        #expect(framesInA + framesInB == 300)
    }

    @Test func aNudgeOrAClockJumpDoesNotRestartTheAudioConverter() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        defer { rig.root.remove() }
        let codecs = FakeAudioCodecs(converts: true)
        let recorder = rig.recorder(codecs: codecs)
        await recorder.start()
        // 0 to 3.3 s; a frame 0.13 s late (a nudge); a jump of 10 s (a cut) and another 3.3 s.
        let video = RecorderFixtures.videoFrames(0..<100, gop: 60) + [RecorderFixtures.video(95, gop: 60)]
            + RecorderFixtures.videoFrames(400..<500, gop: 60)
        await rig.feed(RecorderFixtures.interleaved(video, RecorderFixtures.g711Frames(seconds: 17)), to: recorder)
        await recorder.stop()
        #expect(await recorder.nudges == 1)
        let segments = rig.target.openedSegments
        #expect(segments.count == 2, "\(segments)")
        #expect(codecs.convertersMade.value == 1, "one converter served both files")
        guard segments.count == 2 else { return }
        for segment in segments {
            let file = try RecordedFile(rig, segment: segment)
            let audioFrames = try file.audioFrames()
            #expect(file.info.audio == AudioFormat.aacLC(sampleRate: 8_000, channels: 1) && !audioFrames.isEmpty)
        }
    }

    @Test func aChangeOfTheCamerasAudioFormatStartsANewConverter() async throws {
        let rig = try RecorderRig(camera: RecorderFixtures.camera(recordSound: true))
        defer { rig.root.remove() }
        let codecs = FakeAudioCodecs(converts: true)
        let recorder = rig.recorder(codecs: codecs)
        await recorder.start()
        let a = RecorderFixtures.g711Frames(seconds: 3)
        let b = RecorderFixtures.g711Frames(seconds: 6).dropFirst(150).map { frame -> EncodedAudioFrame in
            var copy = frame
            copy.format = AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 2)
            return copy
        }
        await rig.feed(RecorderFixtures.interleaved(RecorderFixtures.videoFrames(0..<300, gop: 60), a + b), to: recorder)
        await recorder.stop()
        #expect(codecs.convertersMade.value == 2)
    }
}
