import Foundation
import MediaCore
import Testing
@testable import FMP4

/// `FMP4FrameSlicer`: stored fragment bytes back into the frames the live path carries.
@Suite struct FMP4FrameSlicerTests {
    /// Reads fragment `index` of `fixture` the way a player does: init info once, then header and bytes of the fragment.
    static func slice(_ fixture: ReaderFixture, fragment index: Int, start: Date, samples: Range<Int>? = nil) throws -> (video: [EncodedVideoFrame], audio: [EncodedAudioFrame]) {
        let info = try FMP4InitReader.parse(fixture.initialization)
        let fragment = fixture.fragments[index]
        let (moof, mdat) = try fragment.moofAndMdat()
        let header = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat)
        let count = header.tracks.first?.samples.count ?? 0
        let range = samples ?? 0..<count
        return (try FMP4FrameSlicer.videoFrames(header: header, bytes: fragment, bytesStart: fragment.moofStart, info: info, fragmentStart: start, samples: range),
                try FMP4FrameSlicer.audioFrames(header: header, bytes: fragment, bytesStart: fragment.moofStart, info: info, fragmentStart: start,
                                                samples: 0..<(header.tracks.first { $0.trackID == info.audioTrackID }?.samples.count ?? 0)))
    }

    static func ticks(_ date: Date) -> Int64 { Int64((date.timeIntervalSinceReferenceDate * 90_000).rounded()) }

    @Test func framesComeBackWithTheirBytesFlagsAndTimes() throws {
        let format = try Golden.h264Format
        let frames = ReaderFixture.frames(format, count: 10, gop: 10, nalSizes: [12, 30, 5])
        let fixture = try ReaderFixture.make(format: format, frames: frames, cutEvery: 10)
        let start = Date(timeIntervalSince1970: 1_790_000_123.25)
        let out = try Self.slice(fixture, fragment: 0, start: start).video
        #expect(out.count == 10)
        for (index, frame) in out.enumerated() {
            #expect(frame.nalUnits == frames[index].nalUnits, "frame \(index): byte-identical NAL units")
            #expect(frame.isKeyframe == (index == 0))
            #expect(frame.format == format)
            #expect(frame.pts.timescale == 90_000 && frame.pts.value == Self.ticks(start) + Int64(index) * 3_000, "frame \(index)")
            #expect(frame.dts == nil, "no composition offset, no dts")
            #expect(frame.wallClock == Date(timeIntervalSinceReferenceDate: Double(frame.pts.value) / 90_000))
        }
        #expect(out[0].pts.value > 70_000_000_000_000, "ticks since 2001 at 90 kHz fit an Int64 and are about 7e13")
    }

    @Test func inBandParameterSetsAndDelimitersAreNotInTheStoredSamples() throws {
        let format = try Golden.h264Format
        let slice = Data([0x65, 1, 2, 3, 4, 5])
        let keyframe = EncodedVideoFrame(format: format, nalUnits: [Data([0x09, 0xF0]), Golden.h264SPS, Golden.h264PPS, slice], isKeyframe: true,
                                         pts: MediaTime(value: 0, timescale: 90_000), wallClock: ReaderFixture.wallStart)
        let delta = Synthetic.videoFrame(format, index: 1, isKeyframe: false, pts: 3_000)
        let fixture = try ReaderFixture.make(format: format, frames: [keyframe, delta], cutEvery: 2)
        let out = try Self.slice(fixture, fragment: 0, start: ReaderFixture.wallStart).video
        #expect(out[0].nalUnits == [slice], "the muxer keeps parameter sets in the sample entry only; the format carries them")
        #expect(out[0].format.parameterSets == [Golden.h264SPS, Golden.h264PPS])
    }

    @Test func compositionOffsetsSetTheDecodeTime() throws {
        let format = try Golden.h264Format
        let frames = ReaderFixture.frames(format, count: 6, gop: 6, reordered: true)
        let fixture = try ReaderFixture.make(format: format, frames: frames, cutEvery: 6)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let out = try Self.slice(fixture, fragment: 0, start: start).video
        for (index, frame) in out.enumerated() {
            #expect(frame.dts?.value == Self.ticks(start) + Int64(index) * 3_000, "decode time of frame \(index)")
            #expect(frame.pts.value == Self.ticks(start) + Int64(index) * 3_000 + 6_000)
            #expect(frame.wallClock == Date(timeIntervalSinceReferenceDate: Double(frame.pts.value) / 90_000), "wallClock is the pts instant")
        }
    }

    @Test func aSubRangeKeepsTheTimesOfTheWholeFragment() throws {
        let format = try Golden.h264Format
        let fixture = try ReaderFixture.make(format: format, frames: ReaderFixture.frames(format, count: 20, gop: 20), cutEvery: 20)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let all = try Self.slice(fixture, fragment: 0, start: start).video
        let part = try Self.slice(fixture, fragment: 0, start: start, samples: 7..<12).video
        #expect(part.map(\.nalUnits) == all[7..<12].map(\.nalUnits) && part.map(\.pts) == all[7..<12].map(\.pts))
        let (moof, mdat) = try fixture.fragments[0].moofAndMdat()
        let header = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat)
        let info = try FMP4InitReader.parse(fixture.initialization)
        #expect(throws: FMP4Error.self) {
            _ = try FMP4FrameSlicer.videoFrames(header: header, bytes: fixture.fragments[0], bytesStart: 32, info: info, fragmentStart: start, samples: 5..<21)
        }
        #expect(try FMP4FrameSlicer.videoFrames(header: header, bytes: fixture.fragments[0], bytesStart: 32, info: info, fragmentStart: start, samples: 3..<3).isEmpty)
    }

    @Test func aContinuationFragmentSlicesToDeltaFramesThatContinueTheTimeline() throws {
        let format = try Golden.h264Format
        let frames = ReaderFixture.frames(format, count: 75, gop: 75)
        let fixture = try ReaderFixture.make(format: format, frames: frames, cutEvery: 25)
        #expect(fixture.fragments.count == 3)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let second = try Self.slice(fixture, fragment: 1, start: start.addingTimeInterval(25.0 / 30)).video
        #expect(second.count == 25 && second.allSatisfy { !$0.isKeyframe })
        #expect(second[0].nalUnits == frames[25].nalUnits)
        #expect(second[0].pts.value == Self.ticks(start) + 25 * 3_000)
    }

    @Test func soundIsPlacedRelativeToTheVideoOfItsFragment() throws {
        let format = try Golden.h264Format
        let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        let sound = ReaderFixture.audioFrames(aac, count: 40)
        let fixture = try ReaderFixture.make(format: format, frames: ReaderFixture.frames(format, count: 30, gop: 30), audioFormat: aac, audio: sound, cutEvery: 30)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let out = try Self.slice(fixture, fragment: 0, start: start)
        #expect(out.audio.count == fixture.audio[0].count && !out.audio.isEmpty)
        #expect(out.audio.map(\.data) == fixture.audio[0].map(\.data))
        let firstTicks = Int64((start.timeIntervalSinceReferenceDate * 32_000).rounded())
        #expect(out.audio[0].pts.timescale == 32_000 && out.audio[0].pts.value == firstTicks)
        #expect(out.audio[1].pts.value == firstTicks + 1_024 && out.audio[0].sampleCount == 1_024)
        #expect(out.audio[0].format == aac)
        let silent = try ReaderFixture.make(format: format, frames: ReaderFixture.frames(format, count: 30, gop: 30), cutEvery: 30)
        #expect(try Self.slice(silent, fragment: 0, start: start).audio.isEmpty, "a file without sound has no audio frames")
    }

    @Test func aKeyframeReadIsOneFrameAtTheFragmentStart() throws {
        let format = try Golden.h264Format
        let fixture = try ReaderFixture.make(format: format, frames: ReaderFixture.frames(format, count: 5, gop: 5, nalSizes: [20, 40]), cutEvery: 5)
        let info = try FMP4InitReader.parse(fixture.initialization)
        let (moof, mdat) = try fixture.fragments[0].moofAndMdat()
        let header = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat)
        let keyLength = Int(try #require(header.tracks.first).samples[0].size)
        let first = fixture.fragments[0].subdata(in: moof.count + 32 + 8..<moof.count + 32 + 8 + keyLength)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let frame = try FMP4FrameSlicer.frame(fromKeyframeBytes: first, info: info, start: start)
        #expect(frame.isKeyframe && frame.nalUnits == fixture.groups[0][0].nalUnits && frame.wallClock == start)
        #expect(frame.pts.value == Self.ticks(start) && frame.dts == nil && frame.format == format)
        #expect(throws: FMP4Error.self) { _ = try FMP4FrameSlicer.frame(fromKeyframeBytes: first.prefix(10), info: info, start: start) }
        #expect(throws: FMP4Error.self) { _ = try FMP4FrameSlicer.frame(fromKeyframeBytes: Data(), info: info, start: start) }
    }

    @Test func slicesOfDataWithAnOffsetStartIndexWork() throws {
        let format = try Golden.h264Format
        let fixture = try ReaderFixture.make(format: format, frames: ReaderFixture.frames(format, count: 8, gop: 8), cutEvery: 8)
        let padded = Data(repeating: 0xAA, count: 100) + fixture.fragments[0]
        let slice = padded[100...]
        #expect(slice.startIndex == 100)
        let (moof, mdat) = try fixture.fragments[0].moofAndMdat()
        let header = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat)
        let info = try FMP4InitReader.parse(fixture.initialization)
        let frames = try FMP4FrameSlicer.videoFrames(header: header, bytes: slice, bytesStart: 32, info: info, fragmentStart: ReaderFixture.wallStart, samples: 0..<8)
        #expect(frames.map(\.nalUnits) == fixture.groups[0].map(\.nalUnits))
    }

    @Test func damagedSampleBytesThrowInsteadOfReadingPastTheData() throws {
        let format = try Golden.h264Format
        let fixture = try ReaderFixture.make(format: format, frames: ReaderFixture.frames(format, count: 8, gop: 8), cutEvery: 8)
        let fragment = fixture.fragments[0]
        let (moof, mdat) = try fragment.moofAndMdat()
        let header = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat)
        let info = try FMP4InitReader.parse(fixture.initialization)
        // A fragment cut anywhere short of its end: the slicer throws, whatever the sample table says.
        for length in stride(from: 0, to: fragment.count, by: 7) {
            #expect(throws: FMP4Error.self) {
                _ = try FMP4FrameSlicer.videoFrames(header: header, bytes: fragment.prefix(length), bytesStart: 32, info: info, fragmentStart: ReaderFixture.wallStart, samples: 0..<8)
            }
        }
        // A NAL length that runs past its sample.
        var damaged = fragment
        damaged[32 + moof.count + 8] = 0x7F
        #expect(throws: FMP4Error.self) {
            _ = try FMP4FrameSlicer.videoFrames(header: header, bytes: damaged, bytesStart: 32, info: info, fragmentStart: ReaderFixture.wallStart, samples: 0..<8)
        }
    }
}
