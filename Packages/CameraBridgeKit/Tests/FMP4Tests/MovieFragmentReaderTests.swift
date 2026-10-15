import Foundation
import MediaCore
import Testing
@testable import FMP4

/// `MovieFragmentReader`: the one parser of the fragment headers `FMP4Muxer` writes.
@Suite struct MovieFragmentReaderTests {
    @Test func readsWhatTheMuxerWrote() throws {
        let format = try Golden.h264Format
        let frames = ReaderFixture.frames(format, count: 9, gop: 9)
        let fixture = try ReaderFixture.make(format: format, frames: frames, cutEvery: 9)
        let fragment = try #require(fixture.fragments.first)
        let (moof, mdat) = try fragment.moofAndMdat()
        let header = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat)
        let runs = try FragmentRuns(fragment)
        let video = try #require(header.tracks.first)
        #expect(header.sequenceNumber == runs.sequenceNumber && header.tracks.count == 1 && video.trackID == 1)
        #expect(video.baseDecodeTime == 0 && video.dataOffset == moof.count + 8)
        #expect(video.samples.count == 9)
        #expect(video.samples.map(\.duration) == runs.video?.run.samples.map(\.duration))
        #expect(video.samples.map(\.size) == runs.video?.run.samples.map(\.size))
        #expect(video.samples.map(\.flags) == runs.video?.run.samples.map(\.flags))
        #expect(video.samples.map(\.isSync) == [true] + Array(repeating: false, count: 8))
        #expect(video.samples.allSatisfy { $0.compositionOffset == 0 && $0.duration == 3_000 })
        #expect(video.samples.map { Int($0.size) }.reduce(0, +) == mdat)
    }

    @Test func readsAudioAndVideoTrackFragmentsAndTheirOffsets() throws {
        let format = try Golden.h264Format
        let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        let frames = ReaderFixture.frames(format, count: 30, gop: 30)
        let fixture = try ReaderFixture.make(format: format, frames: frames, audioFormat: aac, audio: ReaderFixture.audioFrames(aac, count: 40), cutEvery: 30)
        let fragment = try #require(fixture.fragments.first)
        let (moof, mdat) = try fragment.moofAndMdat()
        let header = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat)
        #expect(header.tracks.map(\.trackID) == [1, 2])
        let video = header.tracks[0], audio = header.tracks[1]
        let videoBytes = video.samples.map { Int($0.size) }.reduce(0, +)
        #expect(audio.dataOffset == video.dataOffset + videoBytes, "audio follows the video in the mdat")
        #expect(audio.samples.allSatisfy { $0.isSync && $0.duration == 1_024 || $0.duration > 0 })
        #expect(audio.samples.map { Int($0.size) }.reduce(0, +) + videoBytes == mdat)
    }

    @Test func bFramesGetSignedCompositionOffsetsAndAVersionOneTrun() throws {
        let format = try Golden.h264Format
        // Decode order with pictures that show out of order: composition offsets 6000, 9000, 0, 9000, 3000, 6000.
        var frames = ReaderFixture.frames(format, count: 6, gop: 6)
        let presentation: [Int64] = [6_000, 12_000, 6_000, 18_000, 15_000, 21_000]
        frames = frames.enumerated().map { index, frame in
            Synthetic.videoFrame(format, index: index, isKeyframe: index == 0, pts: presentation[index], dts: Int64(index) * 3_000, wallClock: frame.wallClock)
        }
        let fixture = try ReaderFixture.make(format: format, frames: frames, cutEvery: 6)
        let (moof, mdat) = try fixture.fragments[0].moofAndMdat()
        let video = try #require(try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat).tracks.first)
        #expect(video.samples.map(\.compositionOffset) == [6_000, 9_000, 0, 9_000, 3_000, 6_000])
        #expect(video.samples.contains { $0.compositionOffset < 0 } == false)
        // A negative offset needs trun version 1: a picture that shows before it decodes.
        let negative = (0..<4).map { index in
            Synthetic.videoFrame(format, index: index, isKeyframe: index == 0, pts: Int64(index) * 3_000 - (index == 2 ? 6_000 : 0), dts: Int64(index) * 3_000)
        }
        let second = try ReaderFixture.make(format: format, frames: negative, cutEvery: 4)
        let (moof2, mdat2) = try second.fragments[0].moofAndMdat()
        let samples = try #require(try MovieFragmentReader.parse(moof: moof2, mdatPayloadSize: mdat2).tracks.first).samples
        #expect(samples[2].compositionOffset == -6_000)
        #expect(Bytes(moof2).u8(try #require(MP4BoxReader.parse(moof2).first?.descendant(atPath: "traf/trun")).offset + 8) == 1, "trun version 1")
    }

    @Test func aFifteenHundredFrameGroupIsReadInFull() throws {
        let format = try Golden.h264Format
        let frames = ReaderFixture.frames(format, count: 1_500, gop: 1_500, nalSizes: [20])
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil))
        let fragment = try muxer.fragment(video: frames, audio: [])
        let (moof, mdat) = try fragment.moofAndMdat()
        let video = try #require(try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat).tracks.first)
        #expect(video.samples.count == 1_500 && video.samples.filter(\.isSync).count == 1)
    }

    @Test func producerReferenceTimeRoundTrips() throws {
        let format = try Golden.h264Format
        let frames = ReaderFixture.frames(format, count: 3, gop: 3)
        let fixture = try ReaderFixture.make(format: format, frames: frames, cutEvery: 3)
        let fragment = fixture.fragments[0]
        let prft = fragment.prefix(32)
        let time = try MovieFragmentReader.producerReferenceTime(prft: Data(prft))
        #expect(time.trackID == 1 && time.mediaTime == 0)
        #expect(abs(time.wallClock.timeIntervalSince(ReaderFixture.wallStart)) < 0.000_001, "NTP fraction resolution is 0.2 ns")
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.producerReferenceTime(prft: Data(fragment.prefix(31))) }
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.producerReferenceTime(prft: Data(fragment[32...].prefix(32))) }
    }

    @Test func producerReferenceTimeConvertsNTPToADate() {
        // 2026-10-10 00:00:00 UTC is 1_791_590_400 s after 1970; NTP counts from 1900 (2_208_988_800 s earlier). Half a second in the fraction.
        let ntp = (UInt64(1_791_590_400 + 2_208_988_800) << 32) | 0x8000_0000
        let time = ProducerReferenceTime(trackID: 1, ntpTimestamp: ntp, mediaTime: 0)
        #expect(time.wallClock == Date(timeIntervalSince1970: 1_791_590_400.5))
    }

    // MARK: Hand-built headers

    /// A `moof` with one `traf` made of the given `tfhd` and `trun` payloads.
    static func moof(tfhdFlags: UInt32 = 0x02_0000, tfhdExtra: [UInt8] = [], tfdt: UInt64 = 0, runs: [[UInt8]], trackID: UInt32 = 1) -> Data {
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let size = UInt32(payload.count + 8)
            return [UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16), UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)] + Array(type.utf8) + payload
        }
        func be32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
        let mfhd = box("mfhd", [0, 0, 0, 0] + be32(7))
        let tfhd = box("tfhd", [0, UInt8(tfhdFlags >> 16), UInt8(truncatingIfNeeded: tfhdFlags >> 8), UInt8(truncatingIfNeeded: tfhdFlags)] + be32(trackID) + tfhdExtra)
        let tfdtBox = box("tfdt", [1, 0, 0, 0] + be32(UInt32(tfdt >> 32)) + be32(UInt32(truncatingIfNeeded: tfdt)))
        let traf = box("traf", tfhd + tfdtBox + runs.flatMap { box("trun", $0) })
        return Data(box("moof", mfhd + traf))
    }

    /// A `trun` payload: version 0, `flags`, `count`, then the given fields in order.
    static func run(flags: UInt32, count: UInt32, fields: [UInt32]) -> [UInt8] {
        func be32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
        return [0, UInt8(flags >> 16), UInt8(truncatingIfNeeded: flags >> 8), UInt8(truncatingIfNeeded: flags)] + be32(count) + fields.flatMap(be32)
    }

    @Test func tfhdDefaultsAndFirstSampleFlagsApply() throws {
        // tfhd: default duration 1000, default size 50, default flags delta; the trun gives a data offset and first-sample flags only.
        let extra: [UInt8] = [0, 0, 3, 0xE8, 0, 0, 0, 50, 0x01, 0x01, 0x00, 0x00]
        let run = Self.run(flags: 0x001 | 0x004, count: 3, fields: [200, 0x0200_0000])
        let header = try MovieFragmentReader.parse(moof: Self.moof(tfhdFlags: 0x02_0000 | 0x08 | 0x10 | 0x20, tfhdExtra: extra, runs: [run]), mdatPayloadSize: 1_000)
        let samples = try #require(header.tracks.first).samples
        #expect(samples.map(\.duration) == [1_000, 1_000, 1_000] && samples.map(\.size) == [50, 50, 50])
        #expect(samples.map(\.isSync) == [true, false, false], "first-sample flags only for the first sample")
        #expect(header.tracks[0].dataOffset == 200)
    }

    @Test func severalTrunsContinueWhereThePreviousEnded() throws {
        let first = Self.run(flags: 0x001 | 0x100 | 0x200 | 0x400, count: 2, fields: [200, 10, 100, 0x0200_0000, 10, 110, 0x0101_0000])
        let second = Self.run(flags: 0x100 | 0x200 | 0x400, count: 1, fields: [10, 120, 0x0101_0000])
        let header = try MovieFragmentReader.parse(moof: Self.moof(runs: [first, second]), mdatPayloadSize: 1_000)
        let track = try #require(header.tracks.first)
        #expect(track.samples.map(\.size) == [100, 110, 120] && track.dataOffset == 200)
        let wrong = Self.run(flags: 0x001 | 0x100 | 0x200 | 0x400, count: 1, fields: [999, 10, 120, 0x0101_0000])
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: Self.moof(runs: [first, wrong])) }
    }

    @Test func refusesWhatItCannotPlace() throws {
        let good = Self.run(flags: 0x001 | 0x100 | 0x200 | 0x400, count: 1, fields: [200, 10, 100, 0x0200_0000])
        _ = try MovieFragmentReader.parse(moof: Self.moof(runs: [good]), mdatPayloadSize: 1_000)
        // An explicit base data offset or no default-base-is-moof: offsets would not be relative to the moof.
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: Self.moof(tfhdFlags: 0x02_0001, tfhdExtra: Array(repeating: 0, count: 8), runs: [good])) }
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: Self.moof(tfhdFlags: 0, runs: [good])) }
        // sample_count larger than the moof can hold, however few bytes follow.
        let many = Self.run(flags: 0x001, count: 0x7FFF_FFFF, fields: [200])
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: Self.moof(runs: [many])) }
        // Sizes that run past the mdat, a data offset inside the moof, one sample over 256 MB.
        let big = Self.run(flags: 0x001 | 0x100 | 0x200 | 0x400, count: 1, fields: [200, 10, 2_000, 0x0200_0000])
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: Self.moof(runs: [big]), mdatPayloadSize: 1_000) }
        let early = Self.run(flags: 0x001 | 0x100 | 0x200 | 0x400, count: 1, fields: [8, 10, 100, 0x0200_0000])
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: Self.moof(runs: [early]), mdatPayloadSize: 1_000) }
        let huge = Self.run(flags: 0x001 | 0x100 | 0x200 | 0x400, count: 1, fields: [200, 10, 0x1000_0001, 0x0200_0000])
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: Self.moof(runs: [huge])) }
        // A trun whose length does not match its sample count; a trun without a data offset; a tfdt version 2.
        let short = Self.run(flags: 0x001 | 0x100 | 0x200 | 0x400, count: 3, fields: [200, 10, 100, 0x0200_0000])
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: Self.moof(runs: [short])) }
        let none = Self.run(flags: 0x100 | 0x200 | 0x400, count: 1, fields: [10, 100, 0x0200_0000])
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: Self.moof(runs: [none])) }
    }

    @Test func boxSizesZeroAndHugeAreRefused() throws {
        let format = try Golden.h264Format
        let fixture = try ReaderFixture.make(format: format, frames: ReaderFixture.frames(format, count: 4, gop: 4), cutEvery: 4)
        let (moof, _) = try fixture.fragments[0].moofAndMdat()
        var zero = moof
        zero.replaceSubrange(0..<4, with: [0, 0, 0, 0])             // size 0: "to the end", which the reader accepts only when it is the whole moof
        _ = try MovieFragmentReader.parse(moof: zero)
        var huge = moof
        huge.replaceSubrange(0..<4, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: huge) }
        var large = moof
        large.replaceSubrange(0..<4, with: [0, 0, 0, 1])            // 64-bit size follows: not enough bytes for its own header contents
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: large) }
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: Data()) }
        #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: moof + moof) }
    }

    // MARK: Torn and fuzzed input

    @Test func aMoofCutAtEveryByteThrowsAndNeverTraps() throws {
        let format = try Golden.h264Format
        let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        let fixture = try ReaderFixture.make(format: format, frames: ReaderFixture.frames(format, count: 12, gop: 12), audioFormat: aac,
                                             audio: ReaderFixture.audioFrames(aac, count: 16), cutEvery: 12)
        let (moof, mdat) = try fixture.fragments[0].moofAndMdat()
        for length in 0..<moof.count {
            #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: moof.prefix(length), mdatPayloadSize: mdat) }
        }
        _ = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat)
    }

    @Test func flippedBitsNeverTrapOrAllocateBeyondTheDeclaredBytes() throws {
        let format = try Golden.h264Format
        let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        let fixture = try ReaderFixture.make(format: format, frames: ReaderFixture.frames(format, count: 12, gop: 12), audioFormat: aac,
                                             audio: ReaderFixture.audioFrames(aac, count: 16), cutEvery: 12)
        let (moof, mdat) = try fixture.fragments[0].moofAndMdat()
        var generator = SeededGenerator(seed: 0xC0FFEE)
        var parsed = 0
        for _ in 0..<20_000 {
            var damaged = moof
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                damaged[Int.random(in: 0..<damaged.count, using: &generator)] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &generator)
            }
            do {
                let header = try MovieFragmentReader.parse(moof: damaged, mdatPayloadSize: mdat)
                parsed += 1
                for track in header.tracks { #expect(track.samples.count <= moof.count / 4, "never more samples than the bytes can declare") }
            } catch is FMP4Error {
                continue
            }
        }
        #expect(parsed > 0, "some flips (inside sample sizes and flags) still parse")
    }
}
