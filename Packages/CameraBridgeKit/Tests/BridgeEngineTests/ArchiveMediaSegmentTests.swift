import BridgeSupport
import FMP4
import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

@Suite struct ArchiveMediaSegmentTests {
    private let capture = ArchiveMediaFixtures.tapoFormat

    private func twin(count: Int, keyEvery: Int, cutEvery: Int = 62, soundSeconds: Double = 4, compositionOffset: @escaping (Int) -> Int64 = { _ in 0 })
        throws -> (withSound: ArchiveMediaFile, videoOnly: ArchiveMediaFile) {
        let frames = ArchiveMediaFixtures.syntheticFrames(capture, count: count, keyEvery: keyEvery, compositionOffset: compositionOffset)
        return (try ArchiveMediaFixtures.mux(frames, audio: ArchiveMediaFixtures.syntheticAudio(seconds: soundSeconds), audioFormat: ArchiveMediaFixtures.aac, cutEvery: cutEvery),
                try ArchiveMediaFixtures.mux(frames, cutEvery: cutEvery))
    }

    @Test func aFragmentWithoutSoundIsTheStoredBytesMinusThePrft() throws {
        let file = try ArchiveMediaFixtures.mux(ArchiveMediaFixtures.syntheticFrames(capture, count: 60, keyEvery: 20), cutEvery: 8)
        #expect(file.fragments.count > 5)
        for fragment in file.fragments {
            #expect(fragment.prefix(8).suffix(4) == Data("prft".utf8) && ArchiveMediaBytes.readU32(fragment, at: 0) == 32)
            #expect(try ArchiveMedia.videoSegment(fragment) == fragment.dropFirst(32))
        }
    }

    @Test func aSliceOfALargerBufferWorksLikeTheBytesThemselves() throws {
        let (withSound, videoOnly) = try twin(count: 12, keyEvery: 6, cutEvery: 6)
        for stored in withSound.fragments + videoOnly.fragments {
            let slice = (Data(repeating: 0xEE, count: 5) + stored + Data(repeating: 0xEE, count: 3))[5..<5 + stored.count]
            #expect(slice.startIndex == 5)
            #expect(try ArchiveMedia.videoSegment(slice) == ArchiveMedia.videoSegment(stored))
        }
    }

    @Test func thePrftIsDroppedByItsBoxSizeNotByThirtyTwo() throws {
        let fragment = try #require(try ArchiveMediaFixtures.mux(ArchiveMediaFixtures.syntheticFrames(capture, count: 4, keyEvery: 4)).fragments.first)
        let prft = fragment.prefix(32)
        let longer = ArchiveMediaBytes.box("prft", Data(prft.dropFirst(8)) + Data(repeating: 0, count: 16))
        #expect(longer.count == 48)
        let expected = fragment.dropFirst(32)
        #expect(try ArchiveMedia.videoSegment(longer + expected) == expected)
        #expect(try ArchiveMedia.videoSegment(Data(expected)) == expected, "a fragment stored without a prft passes through")
        #expect(throws: ArchiveMedia.Failure.self) { _ = try ArchiveMedia.videoSegment(fragment + prft) }
        #expect(throws: ArchiveMedia.Failure.self) { _ = try ArchiveMedia.videoSegment(prft + prft + expected) }
    }

    /// The oracle is the muxer itself: the video of a fragment with sound is, byte for byte, the fragment a muxer without sound writes for the same
    /// pictures, once its prft is dropped (the data offset and the mdat are the two things the surgery changes).
    @Test func aFragmentWithSoundBecomesTheFragmentOfAMuxerWithoutSound() throws {
        let (withSound, videoOnly) = try twin(count: 100, keyEvery: 25, cutEvery: 12)
        #expect(withSound.fragments.count == videoOnly.fragments.count && withSound.fragments.count >= 8)
        for (stored, expected) in zip(withSound.fragments, videoOnly.fragments) {
            #expect(stored.count > expected.count)
            let segment = try ArchiveMedia.videoSegment(stored)
            #expect(segment == expected.dropFirst(32))
            #expect(ArchiveMediaBytes.isConsistentSegment(segment))
        }
    }

    /// The largest fragment the recorder writes (`ArchiveConstants.fragmentMaximumBytes`, 16 MiB): one keyframe of a quarter of it and five other pictures,
    /// with sound. The cut is one pass over the bytes, not a loop over them.
    @Test func aFragmentOfTheLargestSizeIsCutInSeconds() throws {
        let limit = ArchiveConstants.fragmentMaximumBytes
        let frames = ArchiveMediaFixtures.syntheticFrames(capture, count: 6, keyEvery: 6, keySize: limit / 4, deltaSize: (limit - limit / 4 - 200_000) / 5)
        let withSound = try ArchiveMediaFixtures.mux(frames, audio: ArchiveMediaFixtures.syntheticAudio(seconds: 1), audioFormat: ArchiveMediaFixtures.aac, cutEvery: 100)
        let videoOnly = try ArchiveMediaFixtures.mux(frames, cutEvery: 100)
        #expect(withSound.fragments.count == 1 && withSound.fragments[0].count > limit - 1_000_000 && withSound.fragments[0].count < limit)
        let started = ContinuousClock.now
        let segment = try ArchiveMedia.videoSegment(withSound.fragments[0])
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(segment == videoOnly.fragments[0].dropFirst(32))
    }

    @Test func aTrackWithSoundButNoSoundInTheFragmentPassesThroughLikeVideoOnly() throws {
        let frames = ArchiveMediaFixtures.syntheticFrames(capture, count: 40, keyEvery: 10)
        let silent = try ArchiveMediaFixtures.mux(frames, audio: [], audioFormat: ArchiveMediaFixtures.aac, cutEvery: 10)
        #expect(try ArchiveMediaBytes.boxes(in: silent.fragments[0], at: "moof/traf").count == 1)
        for fragment in silent.fragments { #expect(try ArchiveMedia.videoSegment(fragment) == fragment.dropFirst(32)) }
    }

    @Test func continuationFragmentsOfAThirtySecondGroupOfPicturesPass() throws {
        let (withSound, videoOnly) = try twin(count: 800, keyEvery: 750, cutEvery: 62, soundSeconds: 33)
        #expect(withSound.fragments.count == videoOnly.fragments.count && withSound.fragments.count == 14)
        for (stored, expected) in zip(withSound.fragments, videoOnly.fragments) {
            #expect(try ArchiveMedia.videoSegment(stored) == expected.dropFirst(32))
        }
        let continuation = try ArchiveMedia.videoSegment(withSound.fragments[3])
        #expect(ArchiveMediaBytes.isConsistentSegment(continuation))
    }

    /// Composition offsets add 4 bytes to every sample entry (trun flags 0x000F01), negative ones make the trun version 1.
    @Test func compositionOffsetsAndSignedOnesPass() throws {
        let positive = try twin(count: 30, keyEvery: 10, cutEvery: 10) { index in index == 0 ? 0 : 7_200 }
        let signed = try twin(count: 30, keyEvery: 10, cutEvery: 10) { index in index % 3 == 1 ? -1_800 : 3_600 }
        for (name, pair, version) in [("positive", positive, UInt32(0)), ("signed", signed, UInt32(1))] {
            for (stored, expected) in zip(pair.withSound.fragments, pair.videoOnly.fragments) {
                let trun = try ArchiveMediaBytes.trun(in: expected, track: 1)
                #expect(ArchiveMediaBytes.readU32(expected, at: trun.payloadOffset) == version << 24 | 0xF01, "\(name) offsets use flags 0x000F01")
                #expect(try ArchiveMedia.videoSegment(stored) == expected.dropFirst(32))
                #expect(try ArchiveMedia.videoSegment(expected) == expected.dropFirst(32))
            }
        }
    }

    @Test func aTrunTheRecorderNeverWritesIsUnsupported() throws {
        let (withSound, _) = try twin(count: 12, keyEvery: 6, cutEvery: 6)
        let stored = withSound.fragments[0]
        // 0x001701 (the number the addendum quotes) adds sample-flags-first; 0x000700 loses the data offset; 0x000301 loses the sample flags.
        for flags: UInt32 in [0x00_1701, 0x00_0700, 0x00_0301, 0x00_0F00, 0x00_0705, 0x00_0000, 0x00_0F81] {
            let patched = try ArchiveMediaBytes.settingTrunFlags(stored, track: 1, flags: flags)
            #expect(throws: ArchiveMedia.Failure.unsupported("a trun with version 0 and flags 0x\(String(flags, radix: 16))")) { _ = try ArchiveMedia.videoSegment(patched) }
        }
        #expect(throws: ArchiveMedia.Failure.unsupported("a trun with version 2 and flags 0x701")) { _ = try ArchiveMedia.videoSegment(ArchiveMediaBytes.settingTrunFlags(stored, track: 1, flags: 0x701, version: 2)) }
        // Sound is written with 0x000701 and version 0 only.
        #expect(throws: ArchiveMedia.Failure.unsupported("a trun with version 0 and flags 0xf01")) { _ = try ArchiveMedia.videoSegment(ArchiveMediaBytes.settingTrunFlags(stored, track: 2, flags: 0xF01)) }
        #expect(throws: ArchiveMedia.Failure.unsupported("a trun with version 1 and flags 0x701")) { _ = try ArchiveMedia.videoSegment(ArchiveMediaBytes.settingTrunFlags(stored, track: 2, flags: 0x701, version: 1)) }
    }

    @Test func aTrafTheRecorderNeverWritesIsRefused() throws {
        let (withSound, _) = try twin(count: 12, keyEvery: 6, cutEvery: 6)
        let stored = withSound.fragments[0]
        let tfhds = try ArchiveMediaBytes.boxes(in: stored, at: "moof/traf/tfhd")
        let otherBase = ArchiveMediaBytes.patching(stored, at: tfhds[0].payloadOffset, [0, 0, 0, 1])
        #expect(throws: ArchiveMedia.Failure.unsupported("a tfhd that is not default-base-is-moof only")) { _ = try ArchiveMedia.videoSegment(otherBase) }
        let thirdTrack = ArchiveMediaBytes.patching(stored, at: tfhds[1].payloadOffset + 4, ArchiveMediaBytes.u32(3))
        #expect(throws: ArchiveMedia.Failure.unsupported("a traf for track 3")) { _ = try ArchiveMedia.videoSegment(thirdTrack) }
        let twoVideo = ArchiveMediaBytes.patching(stored, at: tfhds[1].payloadOffset + 4, ArchiveMediaBytes.u32(1))
        #expect(throws: ArchiveMedia.Failure.malformed("a moof has two traf boxes for track 1")) { _ = try ArchiveMedia.videoSegment(twoVideo) }
        let twoSound = ArchiveMediaBytes.patching(stored, at: tfhds[0].payloadOffset + 4, ArchiveMediaBytes.u32(2))
        #expect(throws: ArchiveMedia.Failure.malformed("a moof has two traf boxes for track 2")) { _ = try ArchiveMedia.videoSegment(twoSound) }
    }

    /// Where the samples are: the video samples start the mdat, the sound samples follow them, and together they are the whole mdat.
    @Test func samplesThatAreNotWhereTheMoofSaysAreRefused() throws {
        let (withSound, videoOnly) = try twin(count: 12, keyEvery: 6, cutEvery: 6)
        let stored = withSound.fragments[0]
        let videoOffset = ArchiveMediaBytes.readU32(stored, at: try ArchiveMediaBytes.trun(in: stored, track: 1).payloadOffset + 8)
        let soundOffset = ArchiveMediaBytes.readU32(stored, at: try ArchiveMediaBytes.trun(in: stored, track: 2).payloadOffset + 8)
        let movedVideo = try ArchiveMediaBytes.settingTrunField(stored, track: 1, at: 8, to: videoOffset + 4)
        #expect(throws: ArchiveMedia.Failure.unsupported("the video samples do not start the mdat")) { _ = try ArchiveMedia.videoSegment(movedVideo) }
        let movedSound = try ArchiveMediaBytes.settingTrunField(stored, track: 2, at: 8, to: soundOffset - 4)
        #expect(throws: ArchiveMedia.Failure.unsupported("the sound samples do not follow the video samples")) { _ = try ArchiveMedia.videoSegment(movedSound) }
        // A video sample size one byte off: with sound the sound samples no longer follow the video samples, without sound the sum no longer adds up.
        let silent = try #require(videoOnly.fragments.first)
        let silentSize = ArchiveMediaBytes.readU32(silent, at: try ArchiveMediaBytes.trun(in: silent, track: 1).payloadOffset + 12 + 4)
        let size = ArchiveMediaBytes.readU32(stored, at: try ArchiveMediaBytes.trun(in: stored, track: 1).payloadOffset + 12 + 4)
        for delta: Int32 in [1, -1] {
            let wrongSilent = ArchiveMediaBytes.patching(silent, at: try ArchiveMediaBytes.trun(in: silent, track: 1).payloadOffset + 12 + 4, ArchiveMediaBytes.u32(silentSize &+ UInt32(bitPattern: delta)))
            let sum = delta > 0 ? "one byte more" : "one byte less"
            do {
                _ = try ArchiveMedia.videoSegment(wrongSilent)
                Issue.record("a sample size \(sum) was accepted")
            } catch ArchiveMedia.Failure.malformed(let message) {
                #expect(message.hasPrefix("the samples add up to"), "\(message)")
            } catch {
                Issue.record("\(error)")
            }
            let wrongSound = ArchiveMediaBytes.patching(stored, at: try ArchiveMediaBytes.trun(in: stored, track: 1).payloadOffset + 12 + 4, ArchiveMediaBytes.u32(size &+ UInt32(bitPattern: delta)))
            #expect(throws: ArchiveMedia.Failure.unsupported("the sound samples do not follow the video samples")) { _ = try ArchiveMedia.videoSegment(wrongSound) }
        }
    }

    @Test func aVideoTrafWithoutSamplesIsMalformed() throws {
        let stored = try #require(try ArchiveMediaFixtures.mux(ArchiveMediaFixtures.syntheticFrames(capture, count: 4, keyEvery: 4)).fragments.first)
        let boxes = try MP4BoxReader.parse(stored)
        let moof = try #require(boxes.first { $0.type == "moof" })
        let traf = try #require(moof.child("traf"))
        func bytes(_ box: MP4Box) -> Data { stored.subdata(in: box.offset..<box.offset + box.size) }
        let emptyTrun = ArchiveMediaBytes.box("trun", Data([0, 0, 0x07, 0x01]) + Data(ArchiveMediaBytes.u32(0)) + Data(ArchiveMediaBytes.u32(0)))   // no samples, offset set below
        let emptyTraf = ArchiveMediaBytes.box("traf", bytes(try #require(traf.child("tfhd"))) + bytes(try #require(traf.child("tfdt"))) + emptyTrun)
        let emptyMoof = ArchiveMediaBytes.box("moof", bytes(try #require(moof.child("mfhd"))) + emptyTraf)
        let withOffset = ArchiveMediaBytes.patching(emptyMoof, at: emptyMoof.count - 4, ArchiveMediaBytes.u32(UInt32(emptyMoof.count + 8)))   // the mdat follows the moof
        #expect(throws: ArchiveMedia.Failure.malformed("the video traf has no samples")) { _ = try ArchiveMedia.videoSegment(withOffset + ArchiveMediaBytes.box("mdat", Data())) }
    }

    @Test func somethingThatIsNotAFragmentIsMalformed() throws {
        let (withSound, _) = try twin(count: 12, keyEvery: 6, cutEvery: 6)
        let stored = withSound.fragments[0]
        let moof = try #require(try MP4BoxReader.parse(stored).first { $0.type == "moof" })
        let mdat = try #require(try MP4BoxReader.parse(stored).first { $0.type == "mdat" })
        let shape = ArchiveMedia.Failure.malformed("a fragment is an optional prft, a moof and an mdat")
        #expect(throws: shape) { _ = try ArchiveMedia.videoSegment(Data()) }
        #expect(throws: shape) { _ = try ArchiveMedia.videoSegment(withSound.initSegment) }
        #expect(throws: shape) { _ = try ArchiveMedia.videoSegment(stored.subdata(in: mdat.offset..<stored.count)) }
        #expect(throws: shape) { _ = try ArchiveMedia.videoSegment(stored.subdata(in: 0..<moof.offset)) }
        #expect(throws: shape) { _ = try ArchiveMedia.videoSegment(stored + ArchiveMediaBytes.box("mdat", Data(count: 8))) }
        #expect(throws: shape) { _ = try ArchiveMedia.videoSegment(stored.subdata(in: 0..<mdat.offset) + ArchiveMediaBytes.box("free", Data()) + stored.subdata(in: mdat.offset..<stored.count)) }
    }

    @Test func aMoofWithABoxOfAnotherKindIsUnsupported() throws {
        let stored = try #require(try ArchiveMediaFixtures.mux(ArchiveMediaFixtures.syntheticFrames(capture, count: 4, keyEvery: 4)).fragments.first)
        let moof = try #require(try MP4BoxReader.parse(stored).first { $0.type == "moof" })
        let pssh = ArchiveMediaBytes.box("pssh", Data(count: 4))
        let size = ArchiveMediaBytes.readU32(stored, at: moof.offset) + UInt32(pssh.count)
        // The pssh sits at the end of the moof, so the video data offset moves too; the box check comes first.
        let patched = ArchiveMediaBytes.patching(stored.subdata(in: 0..<moof.offset + moof.size) + pssh + stored.subdata(in: moof.offset + moof.size..<stored.count), at: moof.offset, ArchiveMediaBytes.u32(size))
        #expect(throws: ArchiveMedia.Failure.unsupported("a moof holds a 'pssh' box the recorder never writes")) { _ = try ArchiveMedia.videoSegment(patched) }
    }
}
