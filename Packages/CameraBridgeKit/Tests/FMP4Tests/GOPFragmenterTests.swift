import Foundation
import MediaCore
import Testing
@testable import FMP4

@Suite struct GOPFragmenterTests {
    private typealias Fragment = (video: [EncodedVideoFrame], audio: [EncodedAudioFrame])
    private let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)

    /// Video at `fps` with a keyframe every `gop` seconds, plus (optionally) 1024-sample AAC frames at 32 kHz, merged in pts
    /// order. `audioLead` shifts each audio frame's position in the push order (positive: pushed earlier than its pts).
    private func timeline(seconds: Double, fps: Double = 30, gop: Double, audio: Bool = false, videoOffset: Double = 0) throws -> [MediaSample] {
        let format = try Golden.h264Format
        var samples: [(time: Double, sample: MediaSample)] = []
        let frameCount = Int((seconds * fps).rounded())
        let framesPerGOP = max(1, Int((gop * fps).rounded()))
        for i in 0..<frameCount {
            let time = videoOffset + Double(i) / fps
            let frame = Synthetic.videoFrame(format, index: i, isKeyframe: i % framesPerGOP == 0, pts: Int64((time * 90_000).rounded()))
            samples.append((time, .video(frame)))
        }
        if audio {
            var index = 0
            while Double(index) * 1_024 / 32_000 < seconds {
                let pts = Int64(index) * 1_024
                samples.append((Double(pts) / 32_000, .audio(Synthetic.audioFrame(aac, index: index, pts: pts))))
                index += 1
            }
        }
        // Stable sort: at equal times video comes first (it was appended first).
        return samples.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element.sample)
    }

    private func run(_ samples: [MediaSample], target: Duration) -> (fragments: [Fragment], tail: Fragment?) {
        var fragmenter = GOPFragmenter(targetDuration: target)
        var fragments: [Fragment] = []
        for sample in samples { fragments += fragmenter.push(sample) }
        return (fragments, fragmenter.flush())
    }

    private func keyframeCount(_ fragment: Fragment) -> Int { fragment.video.filter(\.isKeyframe).count }
    private func start(_ fragment: Fragment) -> Double { fragment.video.first?.pts.seconds ?? .nan }

    @Test func twoSecondGOPWithFourSecondTargetMakesTwoGOPFragments() throws {
        let (fragments, tail) = run(try timeline(seconds: 10, gop: 2), target: .seconds(4))
        #expect(fragments.count == 2)
        #expect(fragments.map(start) == [0, 4])
        #expect(fragments.map(keyframeCount) == [2, 2])
        #expect(fragments.map(\.video.count) == [120, 120])
        let rest = try #require(tail)
        #expect(start(rest) == 8 && rest.video.count == 60 && keyframeCount(rest) == 1)
        #expect((fragments + [rest]).allSatisfy { $0.video.first?.isKeyframe == true })
    }

    @Test func fourSecondGOPMakesOneGOPPerFragment() throws {
        let (fragments, tail) = run(try timeline(seconds: 12, gop: 4), target: .seconds(4))
        #expect(fragments.map(start) == [0, 4])
        #expect(fragments.map(keyframeCount) == [1, 1])
        #expect(fragments.map(\.video.count) == [120, 120])
        #expect(tail.map(start) == 8)
    }

    @Test func gopLongerThanTargetClosesAtEveryKeyframe() throws {
        let (fragments, _) = run(try timeline(seconds: 15, gop: 5), target: .seconds(4))
        #expect(fragments.map(start) == [0, 5])
        #expect(fragments.map(keyframeCount) == [1, 1])
    }

    @Test func fragmentsStayWithinTheTargetWhenAnotherGOPWouldOverflowIt() throws {
        // 3 s GOPs: two would make a 6 s fragment, longer than the 4 s HKSV fragment length.
        let (fragments, _) = run(try timeline(seconds: 12, gop: 3), target: .seconds(4))
        #expect(fragments.map(start) == [0, 3, 6])
        // A "4 s" GOP that is a frame short still gets its own fragment instead of doubling to ~8 s.
        let short = run(try timeline(seconds: 12, fps: 30, gop: 119.0 / 30), target: .seconds(4))
        #expect(short.fragments.map(keyframeCount).allSatisfy { $0 == 1 })
        #expect(short.fragments.allSatisfy { Double($0.video.count) / 30 <= 4 })
        // 1 s GOPs fill a 4 s fragment.
        let small = run(try timeline(seconds: 9, gop: 1), target: .seconds(4))
        #expect(small.fragments.map(start) == [0, 4])
        #expect(small.fragments.map(keyframeCount) == [4, 4])
    }

    @Test func twoGOPsSlightlyLongerThanTheTargetAreNotMerged() throws {
        // 2.1 s GOPs: two of them make a 4.2 s fragment, longer than a 4 s HKSV fragmentLength.
        let (fragments, _) = run(try timeline(seconds: 13, gop: 2.1), target: .seconds(4))
        #expect(fragments.map(start) == [0, 2.1, 4.2, 6.3, 8.4, 10.5])
        #expect(fragments.map(keyframeCount).allSatisfy { $0 == 1 })
        #expect(fragments.allSatisfy { Double($0.video.count) / 30 <= 4 })
    }

    @Test func keyframeJitterDoesNotSplitTwoGOPFragments() throws {
        // Nominal 2 s GOPs whose keyframes arrive up to ±10 ms off (RTP timestamp jitter) still pair up into ~4 s fragments.
        let format = try Golden.h264Format
        var random = SeededGenerator(seed: 7)
        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        var fragments: [Fragment] = []
        for i in 0..<(30 * 20) {
            let jitter = i % 60 == 0 && i > 0 ? Int64.random(in: -900...900, using: &random) : 0
            fragments += fragmenter.push(.video(Synthetic.videoFrame(format, index: i, isKeyframe: i % 60 == 0, pts: Int64(i) * 3_000 + jitter)))
        }
        #expect(fragments.count == 4)
        #expect(fragments.map(keyframeCount) == [2, 2, 2, 2])
    }

    /// For GOP lengths from 0.5 s to 6 s: a fragment is never longer than the target (plus timestamp-jitter allowance) unless
    /// it is a single GOP, which cannot be split.
    @Test(arguments: [0.5, 0.9, 1.3, 1.9, 2.0, 2.05, 2.1, 2.5, 2.7, 3.0, 3.5, 3.9, 4.0, 4.1, 6.0])
    func fragmentsAreNoLongerThanTheTargetUnlessOneGOP(gop: Double) throws {
        let (fragments, _) = run(try timeline(seconds: 30, gop: gop), target: .seconds(4))
        #expect(fragments.count >= 4)
        for (index, fragment) in fragments.enumerated() {
            let length = Double(fragment.video.count) / 30
            #expect(length <= 4.05 || keyframeCount(fragment) == 1, "fragment \(index): \(length) s, \(keyframeCount(fragment)) GOPs")
        }
    }

    // MARK: - Variable GOPs (W4 review: merging GOPs on the guess that the next GOP is as long as the last one ran
    // fragments past the target whenever the next GOP turned out longer)

    /// A video timeline (seconds, keyframe) whose every GOP is at most 4 s, so a passthrough recording with a 4 s
    /// fragment length takes it, and the fragment starts expected with a 4 s target.
    struct VariableGOPSource: Sendable, CustomTestStringConvertible {
        var name: String
        var points: [Point]
        var starts: [Double]
        var testDescription: String { name }

        struct Point: Sendable {
            var time: Double
            var isKeyframe: Bool
        }

        /// At `fps`, keyframes at the given frame indices.
        init(_ name: String, frames: Int, fps: Double = 25, keyframes: Set<Int>, starts: [Double]) {
            self.init(name, points: (0..<frames).map { Point(time: Double($0) / fps, isKeyframe: keyframes.contains($0)) }, starts: starts)
        }

        init(_ name: String, points: [Point], starts: [Double]) {
            self.name = name
            self.points = points
            self.starts = starts
        }

        private static let nightMode: [Point] = (0..<300).map { (index: Int) -> Point in
            let time: Double = index < 150 ? Double(index) / 25 : 6 + Double(index - 150) / 12.5
            return Point(time: time, isKeyframe: index % 50 == 0)
        }

        static let all: [VariableGOPSource] = [
            // 50-frame GOPs: 25 fps (2 s GOPs) until 6 s, then 12.5 fps (night mode: 4 s GOPs). Was [4, 6, 4] s.
            VariableGOPSource("night-mode frame-rate drop", points: nightMode, starts: [0, 4, 6, 10, 14]),
            // 4 s GOPs; the source reconnects 0.48 s into the second one (the timeline is joined). Was [4, 4.48, 4, 4] s.
            VariableGOPSource("reconnect cuts a GOP short", frames: 500, keyframes: [0, 100, 112, 212, 312, 412], starts: [0, 4, 4.48, 8.48, 12.48, 16.48]),
            // 1 s and 3.52 s GOPs in turn. Was 4.52 s every time.
            VariableGOPSource("alternating 1 s and 3.52 s GOPs", frames: 600,
                              keyframes: [0, 25, 113, 138, 226, 251, 339, 364, 452, 477, 565, 590],
                              starts: [0, 1, 4.52, 5.52, 9.04, 10.04, 13.56, 14.56, 18.08, 19.08, 22.6]),
            // 1.52, 1.48 and 3.88 s GOPs in turn (control: the guess happened to hold).
            VariableGOPSource("irregular IDR spacing", frames: 600, keyframes: [0, 38, 75, 172, 210, 247, 344, 382, 419, 516, 554, 591],
                              starts: [0, 3, 6.88, 9.88, 13.76, 16.76, 20.64, 23.64]),
        ]
    }

    private func frames(_ source: VariableGOPSource) throws -> [EncodedVideoFrame] {
        let format = try Golden.h264Format
        return source.points.enumerated().map { index, point in
            Synthetic.videoFrame(format, index: index, isKeyframe: point.isKeyframe, pts: Int64((point.time * 90_000).rounded()))
        }
    }

    @Test(arguments: VariableGOPSource.all)
    func variableGOPsNeverMakeAFragmentLongerThanTheTarget(source: VariableGOPSource) throws {
        let keyframeTimes = source.points.filter(\.isKeyframe).map(\.time)
        #expect(zip(keyframeTimes.dropFirst(), keyframeTimes).allSatisfy { $0 - $1 <= 4 }, "every GOP fits the 4 s target")
        let input = try frames(source)
        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        var groups: [FragmentGroup] = []
        for frame in input { groups += fragmenter.pushGroups(.video(frame)) }
        let all = groups + fragmenter.flushGroups()
        // Nothing lost or reordered; each fragment starts on a keyframe and ends where the next one starts.
        #expect(all.flatMap(\.video).map(\.pts) == input.map(\.pts))
        #expect(all.allSatisfy { $0.video.first?.isKeyframe == true })
        for (group, next) in zip(all, all.dropFirst()) { #expect(group.nextDecodeTime == next.video.first?.pts) }
        #expect(all.map { ($0.video.first?.pts.seconds ?? .nan) * 100 }.map { $0.rounded() / 100 } == source.starts)
        // Muxed length (first sample to the closing keyframe; the tail's last frame lasts as long as the one before)
        // within the target plus the 50 ms jitter allowance, unless the fragment is one GOP.
        for (index, group) in all.enumerated() {
            let first = try #require(group.video.first).pts
            let end: MediaTime
            if let next = group.nextDecodeTime {
                end = next
            } else {
                let last = try #require(group.video.last).pts
                end = group.video.count < 2 ? last : last + (last - group.video[group.video.count - 2].pts)
            }
            let length = (end - first).seconds
            let gops = group.video.filter(\.isKeyframe).count
            #expect(length <= 4.05 + 1e-9 || gops == 1, "\(source.name): fragment \(index) is \(length) s of \(gops) GOPs")
        }
    }

    @Test func aGOPThatWouldOverflowIsSplitOffAsSoonAsAFrameShowsIt() throws {
        // Night mode: the GOP that started at 6 s (25 fps until then) runs at 12.5 fps. Once a frame past 8.05 s arrives
        // (8.08 s), [4 s, 6 s) plus that GOP certainly exceeds 4 s, so [4 s, 6 s) goes out then, not at the keyframe at 10 s.
        let source = VariableGOPSource.all[0]
        let input = try frames(source)
        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        var returnedAt: [Double] = []
        for frame in input where !fragmenter.pushGroups(.video(frame)).isEmpty { returnedAt.append(frame.pts.seconds) }
        #expect(returnedAt == [4, 8.08, 10, 14])
    }

    @Test func aDroppedFrameDoesNotSplitAFragmentThatFits() throws {
        // 2 s GOPs at 25 fps; the camera drops the frames at 3.88 s and 3.92 s. The 0.12 s gap before 3.96 s says nothing
        // about where the next frame comes: the keyframe at 4 s still closes one 4 s fragment of two GOPs.
        let indices = (0..<150).filter { (index: Int) -> Bool in index != 97 && index != 98 }
        let points = indices.map { (index: Int) -> VariableGOPSource.Point in
            VariableGOPSource.Point(time: Double(index) / 25, isKeyframe: index % 50 == 0)
        }
        let input = try frames(VariableGOPSource("dropped frames", points: points, starts: []))
        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        var groups: [FragmentGroup] = []
        for frame in input { groups += fragmenter.pushGroups(.video(frame)) }
        #expect(groups.map { $0.video.filter(\.isKeyframe).count } == [2])
        #expect(groups.first?.nextDecodeTime?.seconds == 4)
    }

    @Test func flushGroupsSplitsOffAPendingGOPThatWouldMakeTheTailTooLong() throws {
        // A 2 s GOP at 25 fps, then night mode (12.5 fps) from 2 s; the stream ends with the frame at 4.0 s. As one tail the
        // fragment would mux to 4.08 s (the last frame repeats the 0.08 s interval): the GOP from 2 s goes on its own.
        let points = (0..<76).map { (index: Int) -> VariableGOPSource.Point in
            let time: Double = index <= 50 ? Double(index) / 25 : 2 + Double(index - 50) * 0.08
            return VariableGOPSource.Point(time: time, isKeyframe: index % 50 == 0)
        }
        let input = try frames(VariableGOPSource("night mode at the end", points: points, starts: []))
        func push(_ fragmenter: inout GOPFragmenter) -> [FragmentGroup] { input.flatMap { fragmenter.pushGroups(.video($0)) } }
        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        #expect(push(&fragmenter).isEmpty)
        let groups = fragmenter.flushGroups()
        #expect(groups.map(\.video.count) == [50, 26])
        #expect(groups.map { $0.nextDecodeTime?.seconds } == [2, nil])
        #expect(fragmenter.flushGroup() == nil)
        // flushGroup() / flush() return the fragment whole, as the contract has it.
        var whole = GOPFragmenter(targetDuration: .seconds(4))
        _ = push(&whole)
        #expect(whole.flushGroup()?.video.count == 76)
        // A tail that fits stays one group.
        var fits = GOPFragmenter(targetDuration: .seconds(4))
        for frame in input.dropLast() { _ = fits.pushGroups(.video(frame)) }
        #expect(fits.flushGroups().map(\.video.count) == [75])
    }

    @Test func audioFollowsAGOPThatIsSplitOff() throws {
        // Night-mode drop with 32 kHz AAC: audio stays with the fragment whose video span covers it.
        let source = VariableGOPSource.all[0]
        var samples: [(time: Double, sample: MediaSample)] = try frames(source).map { ($0.pts.seconds, .video($0)) }
        var index = 0
        while Double(index) * 1_024 / 32_000 < 17.9 {
            let pts = Int64(index) * 1_024
            samples.append((Double(pts) / 32_000, .audio(Synthetic.audioFrame(aac, index: index, pts: pts))))
            index += 1
        }
        let ordered = samples.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element.sample)
        let (fragments, tail) = run(ordered, target: .seconds(4))
        let all = fragments + [try #require(tail)]
        #expect(all.map(start) == source.starts)
        let starts = all.map(start) + [.infinity]
        for (position, fragment) in all.enumerated() {
            #expect(!fragment.audio.isEmpty)
            for frame in fragment.audio {
                #expect(frame.pts.seconds >= starts[position] && frame.pts.seconds < starts[position + 1], "audio \(frame.pts.seconds) in fragment \(position)")
            }
        }
        #expect(all.reduce(0) { $0 + $1.audio.count } == index)
    }

    @Test func flushReturnsAGOPThatStillFitsWithItsFragment() throws {
        // 2 s GOPs at 30 fps: the GOP from 2 s is still open (it fits so far) when the stream ends at 3 s.
        let (fragments, tail) = run(try timeline(seconds: 3, gop: 2), target: .seconds(4))
        #expect(fragments.isEmpty)
        let rest = try #require(tail)
        #expect(rest.video.count == 90 && keyframeCount(rest) == 2)
    }

    @Test func timestampJumpBackwardsAfterAPendingGOPClosesTheFragmentAsIs() throws {
        let format = try Golden.h264Format
        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        var groups: [FragmentGroup] = []
        for i in 0..<75 { groups += fragmenter.pushGroups(.video(Synthetic.videoFrame(format, index: i, isKeyframe: i % 30 == 0, pts: 900_000 + Int64(i) * 3_000))) }
        #expect(groups.isEmpty)
        groups += fragmenter.pushGroups(.video(Synthetic.videoFrame(format, index: 75, isKeyframe: true, pts: 0)))
        #expect(groups.map(\.video.count) == [75])
        #expect(groups.first?.nextDecodeTime == nil)
        #expect(fragmenter.flushGroup()?.video.first?.pts.value == 0)
    }

    @Test func pushGroupsCarriesTheClosingKeyframesDecodeTime() throws {
        let format = try Golden.h264Format
        var fragmenter = GOPFragmenter(targetDuration: .seconds(1))
        var groups: [FragmentGroup] = []
        for i in 0..<95 {
            // Keyframes carry a dts one frame before their pts (a stream with reordering).
            let key = i % 30 == 0
            let frame = Synthetic.videoFrame(format, index: i, isKeyframe: key, pts: Int64(i) * 3_000 + 3_000, dts: Int64(i) * 3_000)
            groups += fragmenter.pushGroups(.video(frame))
        }
        #expect(groups.count == 3)
        #expect(groups.map { $0.nextDecodeTime?.value } == [90_000, 180_000, 270_000])
        #expect(fragmenter.flushGroup()?.nextDecodeTime == nil)
        // The contract API returns the same groups.
        var plain = GOPFragmenter(targetDuration: .seconds(1))
        var tuples: [Fragment] = []
        for i in 0..<95 {
            tuples += plain.push(.video(Synthetic.videoFrame(format, index: i, isKeyframe: i % 30 == 0, pts: Int64(i) * 3_000)))
        }
        #expect(tuples.map(\.video.count) == groups.map(\.video.count))
    }

    @Test func openFragmentIsBoundedWhenNoKeyframeArrives() throws {
        // A lost IDR (or a very long smart-codec GOP): 20 000 delta frames and their audio after one keyframe.
        let format = try Golden.h264Format
        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        var groups: [FragmentGroup] = []
        groups += fragmenter.pushGroups(.video(Synthetic.videoFrame(format, index: 0, isKeyframe: true, pts: 0)))
        for i in 1..<20_000 {
            groups += fragmenter.pushGroups(.video(Synthetic.videoFrame(format, index: i, isKeyframe: false, pts: Int64(i) * 3_000)))
            groups += fragmenter.pushGroups(.audio(Synthetic.audioFrame(aac, index: i, pts: Int64(i) * 1_067)))
        }
        // The fragment is cut off once it spans the limit; later delta frames are dropped until a keyframe arrives.
        #expect(groups.count == 1)
        let cut = try #require(groups.first)
        #expect(cut.video.first?.isKeyframe == true)
        let span = try #require(cut.video.last).pts.seconds - (try #require(cut.video.first).pts.seconds)
        #expect(span <= GOPFragmenter.maximumFragmentDuration(target: 4) && span > 20)
        #expect(cut.nextDecodeTime == nil)
        #expect(cut.audio.count <= GOPFragmenter.maximumFragmentAudioFrames)
        #expect(fragmenter.flushGroup() == nil)

        // Normal operation resumes at the next keyframe; audio held meanwhile is bounded and kept from that keyframe on.
        var resumed = GOPFragmenter(targetDuration: .seconds(4))
        _ = resumed.pushGroups(.video(Synthetic.videoFrame(format, index: 0, isKeyframe: true, pts: 0)))
        for i in 1..<2_000 { _ = resumed.pushGroups(.video(Synthetic.videoFrame(format, index: i, isKeyframe: false, pts: Int64(i) * 3_000))) }
        _ = resumed.pushGroups(.audio(Synthetic.audioFrame(aac, index: 0, pts: 32_000 * 70)))
        _ = resumed.pushGroups(.video(Synthetic.videoFrame(format, index: 2_000, isKeyframe: true, pts: 90_000 * 70)))
        let flushed = resumed.flushGroup()
        let tail = try #require(flushed)
        #expect(tail.video.count == 1 && tail.audio.count == 1)
    }

    @Test func openFragmentFrameCountIsBoundedWhenTimestampsStall() throws {
        let format = try Golden.h264Format
        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        var groups: [FragmentGroup] = []
        for i in 0..<(GOPFragmenter.maximumFragmentFrames * 3) {
            groups += fragmenter.pushGroups(.video(Synthetic.videoFrame(format, index: i, isKeyframe: i == 0, pts: 0)))
        }
        #expect(groups.map(\.video.count) == [GOPFragmenter.maximumFragmentFrames])
        #expect(fragmenter.flushGroup() == nil)
    }

    @Test func audioGoesToTheFragmentCoveringItsPTS() throws {
        let (fragments, tail) = run(try timeline(seconds: 10, gop: 2, audio: true), target: .seconds(4))
        let all = fragments + [try #require(tail)]
        let starts = all.map(start) + [.infinity]
        var total = 0
        for (index, fragment) in all.enumerated() {
            #expect(!fragment.audio.isEmpty)
            for frame in fragment.audio {
                #expect(frame.pts.seconds >= starts[index] && frame.pts.seconds < starts[index + 1], "audio \(frame.pts.seconds) in fragment \(index)")
            }
            total += fragment.audio.count
        }
        #expect(total == Int((10.0 * 32_000 / 1_024).rounded(.up)))
    }

    @Test func audioPushedBeforeTheBoundaryKeyframeMovesToTheNextFragment() throws {
        let format = try Golden.h264Format
        var fragmenter = GOPFragmenter(targetDuration: .seconds(1))
        _ = fragmenter.push(.video(Synthetic.videoFrame(format, index: 0, isKeyframe: true, pts: 0)))
        _ = fragmenter.push(.audio(Synthetic.audioFrame(aac, index: 0, pts: 0)))
        // Audio for t = 1.0 s arrives before the keyframe at t = 1.0 s.
        _ = fragmenter.push(.audio(Synthetic.audioFrame(aac, index: 1, pts: 32_000)))
        let closed = fragmenter.push(.video(Synthetic.videoFrame(format, index: 30, isKeyframe: true, pts: 90_000)))
        #expect(closed.count == 1)
        #expect(closed.first?.audio.map(\.pts.value) == [0])
        #expect(fragmenter.flush()?.audio.map(\.pts.value) == [32_000])
    }

    @Test func audioArrivingAfterItsFragmentClosedGoesToTheOpenFragment() throws {
        let format = try Golden.h264Format
        var fragmenter = GOPFragmenter(targetDuration: .seconds(1))
        _ = fragmenter.push(.video(Synthetic.videoFrame(format, index: 0, isKeyframe: true, pts: 0)))
        let closed = fragmenter.push(.video(Synthetic.videoFrame(format, index: 30, isKeyframe: true, pts: 90_000)))
        #expect(closed.count == 1)
        _ = fragmenter.push(.audio(Synthetic.audioFrame(aac, index: 0, pts: 31_000)))   // 0.97 s: late
        #expect(fragmenter.flush()?.audio.count == 1)
    }

    @Test func samplesBeforeTheFirstKeyframe() throws {
        let format = try Golden.h264Format
        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        #expect(fragmenter.push(.video(Synthetic.videoFrame(format, index: 0, isKeyframe: false, pts: 0))).isEmpty)
        #expect(fragmenter.push(.audio(Synthetic.audioFrame(aac, index: 0, pts: 0))).isEmpty)           // before the keyframe: dropped
        #expect(fragmenter.push(.audio(Synthetic.audioFrame(aac, index: 1, pts: 3_300))).isEmpty)       // 0.103 s: kept
        #expect(fragmenter.push(.video(Synthetic.videoFrame(format, index: 3, isKeyframe: true, pts: 9_000))).isEmpty)
        let flushed = fragmenter.flush()
        let tail = try #require(flushed)
        #expect(tail.video.count == 1 && tail.video.first?.isKeyframe == true)
        #expect(tail.audio.map(\.pts.value) == [3_300])
    }

    @Test func flushResetsTheFragmenter() throws {
        let format = try Golden.h264Format
        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        #expect(fragmenter.flush() == nil)
        _ = fragmenter.push(.video(Synthetic.videoFrame(format, index: 0, isKeyframe: true, pts: 0)))
        #expect(fragmenter.flush()?.video.count == 1)
        #expect(fragmenter.flush() == nil)
        // After a flush it waits for a keyframe again.
        #expect(fragmenter.push(.video(Synthetic.videoFrame(format, index: 1, isKeyframe: false, pts: 3_000))).isEmpty)
        #expect(fragmenter.flush() == nil)
    }

    @Test func timestampJumpBackwardsStartsANewFragment() throws {
        let format = try Golden.h264Format
        var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
        _ = fragmenter.push(.video(Synthetic.videoFrame(format, index: 0, isKeyframe: true, pts: 900_000)))
        _ = fragmenter.push(.video(Synthetic.videoFrame(format, index: 1, isKeyframe: false, pts: 903_000)))
        let closed = fragmenter.push(.video(Synthetic.videoFrame(format, index: 2, isKeyframe: true, pts: 0)))
        #expect(closed.map(\.video.count) == [2])
        #expect(fragmenter.flush()?.video.first?.pts.value == 0)
    }

    @Test func misalignedAudioClockDoesNotAccumulate() throws {
        // Audio pts 1000 s ahead of video: it cannot cover any fragment, so it stays in arrival order instead of piling up.
        let format = try Golden.h264Format
        var fragmenter = GOPFragmenter(targetDuration: .seconds(1))
        var emitted: [Fragment] = []
        for i in 0..<300 {
            emitted += fragmenter.push(.video(Synthetic.videoFrame(format, index: i, isKeyframe: i % 30 == 0, pts: Int64(i) * 3_000)))
            if i % 3 == 0 {
                emitted += fragmenter.push(.audio(Synthetic.audioFrame(aac, index: i, pts: 32_000 * 1_000 + Int64(i / 3) * 1_024)))
            }
        }
        #expect(emitted.count == 9)
        #expect(emitted.allSatisfy { $0.audio.count <= 11 })
    }
}
