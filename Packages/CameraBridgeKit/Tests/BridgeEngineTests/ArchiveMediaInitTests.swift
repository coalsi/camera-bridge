import BridgeSupport
import FMP4
import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

@Suite struct ArchiveMediaInitTests {
    private let frames = ArchiveMediaFixtures.syntheticFrames(ArchiveMediaFixtures.tapoFormat, count: 20, keyEvery: 10)

    @Test func thePictureSizeComesFromTheSampleEntry() throws {
        for (format, width, height) in [(ArchiveMediaFixtures.tapoFormat, 2688, 1520), (ArchiveMediaFixtures.smallH264Format, 640, 360), (ArchiveMediaFixtures.hevcFormat, 640, 360)] {
            let initData = try ArchiveMediaFixtures.mux(ArchiveMediaFixtures.syntheticFrames(format, count: 3, keyEvery: 3)).initSegment
            let video = try ArchiveMedia.videoInit(initData)
            let mime = try ArchiveMedia.mime(forInit: initData)
            #expect(video.width == width && video.height == height && video.mime == mime)
        }
        let initData = try ArchiveMediaFixtures.mux(ArchiveMediaFixtures.syntheticFrames(ArchiveMediaFixtures.tapoFormat, count: 3, keyEvery: 3)).initSegment
        let entry = try #require(try ArchiveMediaBytes.boxes(in: initData, at: "moov/trak/mdia/minf/stbl/stsd/avc1").first)
        for bytes in [[UInt8]([0, 0, 0, 0]), [0, 0, 0x05, 0xA0]] {
            let patched = ArchiveMediaBytes.patching(initData, at: entry.payloadOffset + 24, bytes)
            #expect(throws: ArchiveMedia.Failure.malformed("the video sample entry has no picture size")) { _ = try ArchiveMedia.videoInit(patched) }
        }
    }

    @Test func anInitWithoutSoundComesBackByteForByte() throws {
        let file = try ArchiveMediaFixtures.mux(frames)
        let video = try ArchiveMedia.videoInit(file.initSegment)
        #expect(video.data == file.initSegment && !video.hadAudio)
        #expect(video.mime == "video/mp4; codecs=\"avc1.4d0032\"" && video.width == 2688 && video.height == 1520)
    }

    /// The oracle is the muxer itself: dropping the sound track of an init segment gives what a muxer without sound writes for the same video.
    @Test func anInitWithSoundBecomesTheInitOfAMuxerWithoutSound() throws {
        let withSound = try ArchiveMediaFixtures.mux(frames, audio: ArchiveMediaFixtures.syntheticAudio(seconds: 1), audioFormat: ArchiveMediaFixtures.aac)
        let videoOnly = try ArchiveMediaFixtures.mux(frames)
        #expect(withSound.initSegment != videoOnly.initSegment)
        let video = try ArchiveMedia.videoInit(withSound.initSegment)
        #expect(video.data == videoOnly.initSegment)
        #expect(video.hadAudio && video.mime == "video/mp4; codecs=\"avc1.4d0032\"" && video.width == 2688 && video.height == 1520)
        #expect(try ArchiveMedia.mime(forInit: withSound.initSegment) == video.mime)
    }

    @Test func theRebuiltInitHasOneTrackAndOneTrex() throws {
        let withSound = try ArchiveMediaFixtures.mux(frames, audio: ArchiveMediaFixtures.syntheticAudio(seconds: 1), audioFormat: ArchiveMediaFixtures.aac)
        let rebuilt = try ArchiveMedia.videoInit(withSound.initSegment).data
        let paths = try ArchiveMediaBytes.boxes(in: rebuilt).map(\.path)
        #expect(paths.filter { $0 == "moov/trak" }.count == 1 && paths.filter { $0 == "moov/mvex/trex" }.count == 1)
        let mvhd = try #require(try ArchiveMediaBytes.boxes(in: rebuilt, at: "moov/mvhd").first)
        #expect(ArchiveMediaBytes.readU32(rebuilt, at: mvhd.offset + mvhd.size - 4) == 2, "next_track_ID follows the one track left")
        let trex = try #require(try ArchiveMediaBytes.boxes(in: rebuilt, at: "moov/mvex/trex").first)
        #expect(ArchiveMediaBytes.readU32(rebuilt, at: trex.payloadOffset + 4) == 1)
        #expect(try ArchiveMedia.videoInit(rebuilt).data == rebuilt, "a second pass changes nothing")
    }

    @Test func hevcWithSoundIsRebuiltToo() throws {
        let hevc = ArchiveMediaFixtures.syntheticFrames(ArchiveMediaFixtures.hevcFormat, count: 6, keyEvery: 3)
        let withSound = try ArchiveMediaFixtures.mux(hevc, audio: ArchiveMediaFixtures.syntheticAudio(seconds: 1), audioFormat: ArchiveMediaFixtures.aac)
        let video = try ArchiveMedia.videoInit(withSound.initSegment)
        #expect(video.data == (try ArchiveMediaFixtures.mux(hevc)).initSegment && video.hadAudio && video.mime == "video/mp4; codecs=\"hvc1.1.6.L63.B0\"")
    }

    @Test func aSliceOfALargerBufferWorksLikeTheBytesThemselves() throws {
        let withSound = try ArchiveMediaFixtures.mux(frames, audio: ArchiveMediaFixtures.syntheticAudio(seconds: 1), audioFormat: ArchiveMediaFixtures.aac)
        let padded = Data(repeating: 0xEE, count: 37) + withSound.initSegment + Data(repeating: 0xEE, count: 11)
        let slice = padded[37..<37 + withSound.initSegment.count]
        #expect(slice.startIndex == 37)
        #expect(try ArchiveMedia.videoInit(slice) == ArchiveMedia.videoInit(withSound.initSegment))
        #expect(try ArchiveMedia.mime(forInit: slice) == ArchiveMedia.mime(forInit: withSound.initSegment))
    }

    @Test func somethingThatIsNotAnInitSegmentIsMalformed() throws {
        let initData = try ArchiveMediaFixtures.mux(frames).initSegment
        let moov = try #require(try MP4BoxReader.parse(initData).first { $0.type == "moov" })
        let ftyp = initData.prefix(moov.offset)
        #expect(throws: ArchiveMedia.Failure.malformed("an initialization segment is an ftyp and a moov")) { _ = try ArchiveMedia.videoInit(Data()) }
        #expect(throws: ArchiveMedia.Failure.malformed("an initialization segment is an ftyp and a moov")) { _ = try ArchiveMedia.videoInit(Data(ftyp)) }
        #expect(throws: ArchiveMedia.Failure.self) { _ = try ArchiveMedia.videoInit(initData + ArchiveMediaBytes.box("free", Data(count: 4))) }
        #expect(throws: ArchiveMedia.Failure.self) { _ = try ArchiveMedia.videoInit(Data(initData.dropFirst(ftyp.count))) }
        #expect(throws: ArchiveMedia.Failure.self) { _ = try ArchiveMedia.videoInit(try ArchiveMediaFixtures.mux(frames).fragments[0]) }
        #expect(throws: ArchiveMedia.Failure.malformed("an initialization segment is under 1 MiB")) { _ = try ArchiveMedia.videoInit(initData + Data(count: 1_048_576)) }
    }

    /// A moov the recorder never writes: an extra child, a second video track or sound track, other track ids, no video track, no video trex.
    @Test func aMoovTheRecorderNeverWritesIsRefused() throws {
        let withSound = try ArchiveMediaFixtures.mux(frames, audio: ArchiveMediaFixtures.syntheticAudio(seconds: 1), audioFormat: ArchiveMediaFixtures.aac).initSegment
        let top = try MP4BoxReader.parse(withSound)
        let moov = try #require(top.first { $0.type == "moov" })
        func bytes(_ box: MP4Box) -> Data { withSound.subdata(in: box.offset..<box.offset + box.size) }
        func rebuilt(_ children: [Data]) -> Data {
            Data(withSound.prefix(moov.offset)) + ArchiveMediaBytes.box("moov", children.reduce(Data()) { $0 + $1 })
        }
        let mvhd = bytes(try #require(moov.child("mvhd"))), video = bytes(moov.children(ofType: "trak")[0]), sound = bytes(moov.children(ofType: "trak")[1])
        let mvex = bytes(try #require(moov.child("mvex")))
        #expect(try ArchiveMedia.videoInit(rebuilt([mvhd, video, sound, mvex])).hadAudio, "the control: the same parts in the same order are accepted")
        let extra = ArchiveMediaBytes.box("udta", Data(count: 4))
        #expect(throws: ArchiveMedia.Failure.unsupported("a moov holds a 'udta' box the recorder never writes")) { _ = try ArchiveMedia.videoInit(rebuilt([mvhd, video, sound, mvex, extra])) }
        #expect(throws: ArchiveMedia.Failure.unsupported("more than one video track")) { _ = try ArchiveMedia.videoInit(rebuilt([mvhd, video, video, mvex])) }
        #expect(throws: ArchiveMedia.Failure.unsupported("more than one sound track")) { _ = try ArchiveMedia.videoInit(rebuilt([mvhd, video, sound, sound, mvex])) }
        #expect(throws: ArchiveMedia.Failure.malformed("a moov needs an mvhd, a video track and an mvex")) { _ = try ArchiveMedia.videoInit(rebuilt([mvhd, sound, mvex])) }
        let videoTkhd = try #require(try MP4BoxReader.parse(video).first?.child("tkhd"))
        let renumberedVideo = ArchiveMediaBytes.patching(video, at: videoTkhd.payloadOffset + 12, ArchiveMediaBytes.u32(7))
        #expect(throws: ArchiveMedia.Failure.unsupported("video track id 7 (the recorder writes 1)")) { _ = try ArchiveMedia.videoInit(rebuilt([mvhd, renumberedVideo, sound, mvex])) }
        let soundTkhd = try #require(try MP4BoxReader.parse(sound).first?.child("tkhd"))
        let renumbered = ArchiveMediaBytes.patching(sound, at: soundTkhd.payloadOffset + 12, ArchiveMediaBytes.u32(3))
        #expect(throws: ArchiveMedia.Failure.unsupported("sound track id 3 (the recorder writes 2)")) { _ = try ArchiveMedia.videoInit(rebuilt([mvhd, video, renumbered, mvex])) }
        let trexOfSound = try #require(try MP4BoxReader.parse(mvex).first?.children(ofType: "trex").last)
        let noVideoTrex = ArchiveMediaBytes.box("mvex", mvex.subdata(in: trexOfSound.offset..<trexOfSound.offset + trexOfSound.size))
        #expect(throws: ArchiveMedia.Failure.malformed("the mvex has no trex for the video track")) { _ = try ArchiveMedia.videoInit(rebuilt([mvhd, video, sound, noVideoTrex])) }
    }
}
