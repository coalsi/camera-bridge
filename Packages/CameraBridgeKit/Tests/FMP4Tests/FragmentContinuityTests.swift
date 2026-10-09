import Foundation
import MediaCore
import Testing
@testable import FMP4

/// ISO/IEC 14496-12 §8.8.12: a fragment's tfdt is the sum of the durations of every earlier sample of its track. The last
/// video sample of a fragment must therefore end exactly where the next fragment starts.
@Suite struct FragmentContinuityTests {
    private func frame(_ format: VideoFormat, _ index: Int, key: Bool, pts: Int64) -> EncodedVideoFrame {
        Synthetic.videoFrame(format, index: index, isKeyframe: key, pts: pts)
    }

    @Test func lastVideoSampleEndsWhereTheNextFragmentStarts() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        // The last interval of the first fragment is jittered: 6 100 → 9 000 is 2 900 ticks, not the 3 100 before it.
        let first = FragmentGroup(video: [frame(format, 0, key: true, pts: 0), frame(format, 1, key: false, pts: 3_000),
                                          frame(format, 2, key: false, pts: 6_100)],
                                  audio: [], nextDecodeTime: MediaTime(value: 9_000, timescale: 90_000))
        let second = FragmentGroup(video: [frame(format, 3, key: true, pts: 9_000), frame(format, 4, key: false, pts: 12_000)], audio: [])
        let a = try #require(try FragmentRuns(try muxer.fragment(first)).video)
        let b = try #require(try FragmentRuns(try muxer.fragment(second)).video)
        #expect(a.run.samples.map(\.duration) == [3_000, 3_100, 2_900])
        #expect(b.decodeTime == a.decodeTime + a.run.samples.reduce(0) { $0 + UInt64($1.duration) })
        #expect(b.decodeTime == 9_000)
    }

    @Test func nextDecodeTimeInAnotherTimescaleIsConverted() throws {
        let format = try Golden.h264Format
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil, videoTimescale: 30_000))
        let fragment = try muxer.fragment(video: [frame(format, 0, key: true, pts: 0), frame(format, 1, key: false, pts: 3_000)], audio: [],
                                          nextDecodeTime: MediaTime(value: 1_001, timescale: 15_000))   // 0.0667 s = 2 002 ticks
        #expect(try FragmentRuns(fragment).video?.run.samples.map(\.duration) == [1_000, 1_002])
    }

    @Test func withoutAUsableSuccessorTheLastDurationIsGuessed() throws {
        let format = try Golden.h264Format
        let video = [frame(format, 0, key: true, pts: 0), frame(format, 1, key: false, pts: 3_000), frame(format, 2, key: false, pts: 6_100)]
        // Unknown (contract API, flushed tail), at or before the last sample, or beyond a 32-bit duration: previous interval.
        for next: MediaTime? in [nil, MediaTime(value: 6_100, timescale: 90_000), MediaTime(value: 0, timescale: 90_000),
                                 MediaTime(value: 6_100 + Int64(UInt32.max) + 1, timescale: 90_000)] {
            var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
            let fragment = try muxer.fragment(video: video, audio: [], nextDecodeTime: next)
            #expect(try FragmentRuns(fragment).video?.run.samples.map(\.duration) == [3_000, 3_100, 3_100], "next \(String(describing: next))")
        }
    }

    /// 30 fps with ±4 ms jitter, bursts (two frames 5 ms apart, then a long gap), a drop to 15 fps halfway ("night mode"),
    /// 2 s GOPs, 4 s target, AAC audio: every fragment's tfdt equals the previous tfdt plus its durations, and every sample
    /// decodes at exactly its (rebased) source time.
    @Test(arguments: [1, 2, 3, 4] as [UInt64]) func jitteredTimelineStaysContinuous(seed: UInt64) throws {
        let format = try Golden.h264Format
        let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        var random = SeededGenerator(seed: seed)
        let origin: Int64 = 90_000 * 5_000
        var samples: [(time: Int64, sample: MediaSample)] = []
        var time: Int64 = 0
        var videoTimes: [Int64] = []
        var index = 0
        while time < 90_000 * 20 {
            let interval: Int64 = time < 90_000 * 10 ? 3_000 : 6_000
            let isKeyframe = index == 0 || videoTimes.last.map { time / 180_000 > $0 / 180_000 } ?? false
            samples.append((time, .video(frame(format, index, key: isKeyframe, pts: origin + time))))
            videoTimes.append(time)
            index += 1
            if index % 17 == 0 {
                time += 450                                                           // burst: 5 ms later
            } else {
                let jitter = Int64.random(in: -360...360, using: &random)             // ±4 ms
                time += max(90, interval + jitter + (index % 17 == 1 ? 2_550 : 0))    // the gap after a burst
            }
        }
        var audioIndex: Int64 = 0
        while audioIndex * 1_024 < 32_000 * 20 {
            let pts = Int64(5_000) * 32_000 + audioIndex * 1_024
            samples.append((audioIndex * 1_024 * 90_000 / 32_000, .audio(Synthetic.audioFrame(aac, index: Int(audioIndex), pts: pts))))
            audioIndex += 1
        }
        samples = samples.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)

        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac))
        var fragments: [Data] = []
        for entry in samples {
            for group in fragmenter.pushGroups(entry.sample) { fragments.append(try muxer.fragment(group)) }
        }
        if let tail = fragmenter.flushGroup() { fragments.append(try muxer.fragment(tail)) }
        #expect(fragments.count >= 5)

        var expectedStart: UInt64 = 0
        var decodeTimes: [Int64] = []
        for (number, fragment) in fragments.enumerated() {
            let video = try #require(try FragmentRuns(fragment).video)
            #expect(video.decodeTime == expectedStart, "fragment \(number): tfdt \(video.decodeTime), running sum \(expectedStart)")
            var decode = Int64(video.decodeTime)
            for sample in video.run.samples {
                decodeTimes.append(decode)
                decode += Int64(sample.duration)
            }
            expectedStart = UInt64(decode)
        }
        #expect(decodeTimes == videoTimes)
    }
}
