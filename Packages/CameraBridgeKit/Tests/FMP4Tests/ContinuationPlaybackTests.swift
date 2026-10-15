#if canImport(VideoToolbox) && canImport(AVFoundation)
import AVFoundation
import Foundation
import MediaCore
import Testing
import VideoToolbox
@testable import FMP4

/// The gate for continuation fragments (Mac spec 17): a VideoToolbox clip with a long group of pictures, cut into 2.5 s fragments the way the
/// NVR recorder cuts it (the pieces after the keyframe start on a delta frame), must decode completely with `AVAssetReader`, and so must the
/// copy a crash leaves after repair (cut back to the last whole fragment).
@Suite(.timeLimit(.minutes(2))) struct ContinuationPlaybackTests {
    private static func encoderAvailable(_ codec: VideoCodec) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 320, height: 240, codecType: codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                                refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr
    }

    struct Recording {
        var url: URL
        var data: Data
        var frames: Int
        var fragmentFrames: [Int]
        var fragmentEnds: [Int]
        var continuations: Int
    }

    /// `seconds` of 30 fps video with a keyframe every `gopSeconds`, cut at keyframes and every 75 frames (2.5 s).
    static func record(codec: VideoCodec, seconds: Int = 10, gopSeconds: Int = 5, withAudio: Bool = false) throws -> Recording {
        let fps = 30
        let clip = try encodeVideo(codec: codec, fps: fps, gop: gopSeconds * fps, frameCount: seconds * fps)
        let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        let sound = withAudio ? try encodeAAC(seconds: Double(seconds)) : []
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: clip.format, audio: withAudio ? aac : nil, writeProducerReferenceTime: true))
        var file = muxer.initializationSegment()
        var recording = Recording(url: FileManager.default.temporaryDirectory.appending(path: "continuation-\(UUID().uuidString).mp4"), data: Data(),
                                  frames: clip.frames.count, fragmentFrames: [], fragmentEnds: [], continuations: 0)
        var start = 0
        while start < clip.frames.count {
            var end = start + 1
            while end < clip.frames.count, end - start < 75, !clip.frames[end].isKeyframe { end += 1 }
            let group = Array(clip.frames[start..<end])
            let next = end < clip.frames.count ? clip.frames[end].dts ?? clip.frames[end].pts : nil
            let boundary = next.map(\.seconds) ?? .infinity
            let groupSound = sound.filter { $0.pts.seconds >= group[0].pts.seconds && $0.pts.seconds < boundary }
            let continuation = !group[0].isKeyframe
            file.append(try muxer.fragment(video: group, audio: groupSound, nextDecodeTime: next, continuation: continuation))
            recording.fragmentFrames.append(group.count)
            recording.fragmentEnds.append(file.count)
            recording.continuations += continuation ? 1 : 0
            start = end
        }
        recording.data = file
        try file.write(to: recording.url)
        return recording
    }

    @Test func aLongGroupCutIntoContinuationFragmentsDecodesCompletely() async throws {
        let recording = try Self.record(codec: .h264)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        #expect(recording.fragmentFrames == [75, 75, 75, 75] && recording.continuations == 2, "K C K C: two keyframe fragments, two continuations")
        let report = try await readBack(recording.url)
        #expect(report.videoTrackCount == 1)
        #expect(report.decodedVideoFrames == recording.frames, "every frame decodes, the continuation fragments included")
        #expect(report.videoReaderCompleted)
        #expect(abs(report.duration - 10) < 0.1, "duration \(report.duration)")
    }

    @Test func continuationFragmentsWithSoundDecodeCompletely() async throws {
        let recording = try Self.record(codec: .h264, seconds: 8, gopSeconds: 4, withAudio: true)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let report = try await readBack(recording.url)
        #expect(report.decodedVideoFrames == recording.frames && report.videoReaderCompleted)
        #expect(report.audioTrackCount == 1 && report.audioReaderCompleted && report.decodedAudioSamples > 32_000 * 6)
    }

    @Test(.enabled(if: ContinuationPlaybackTests.encoderAvailable(.hevc)))
    func hevcContinuationFragmentsDecodeCompletely() async throws {
        let recording = try Self.record(codec: .hevc)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        #expect(recording.continuations >= 2)
        let report = try await readBack(recording.url)
        #expect(report.decodedVideoFrames == recording.frames && report.videoReaderCompleted)
    }

    @Test func aCrashRecoveredCopyDecodesTheFragmentsThatWereWhole() async throws {
        let recording = try Self.record(codec: .h264)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        // The process died: the file ends in the middle of the third fragment, and after the second one's last byte, and in the middle of the 4th.
        let cuts = [recording.fragmentEnds[1] + 1_000, recording.fragmentEnds[1], recording.fragmentEnds[2] + 7, recording.fragmentEnds[3] - 1]
        for cut in cuts {
            let torn = recording.data.prefix(cut)
            let kept = TornFile.wholeFragments(in: Data(torn))
            let expectedFragments = recording.fragmentEnds.filter { $0 <= cut }.count
            #expect(kept.fragments.count == expectedFragments, "cut at \(cut)")
            let repaired = FileManager.default.temporaryDirectory.appending(path: "continuation-repaired-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: repaired) }
            try Data(torn.prefix(kept.end)).write(to: repaired)
            let report = try await readBack(repaired)
            #expect(report.decodedVideoFrames == recording.fragmentFrames.prefix(expectedFragments).reduce(0, +), "cut at \(cut): \(report.decodedVideoFrames) frames")
            #expect(report.videoReaderCompleted, "cut at \(cut)")
        }
    }
}
#endif
