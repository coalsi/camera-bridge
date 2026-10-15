import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// The sound of a recording on its own (`ArchiveMedia.soundInit`, `soundSegment`): what the page's audio element plays beside the picture.
@Suite struct ArchiveMediaSoundTests {
    private let capture = ArchiveMediaFixtures.tapoFormat

    @Test func theSoundOfAFileWithSoundIsItsOwnTrackAndItsOwnSamples() throws {
        let frames = ArchiveMediaFixtures.syntheticFrames(capture, count: 100, keyEvery: 25)
        let audio = ArchiveMediaFixtures.syntheticAudio(seconds: 4)
        let file = try ArchiveMediaFixtures.mux(frames, audio: audio, audioFormat: ArchiveMediaFixtures.aac, cutEvery: 12)
        let initSegment = try #require(try ArchiveMedia.soundInit(file.initSegment))
        #expect(initSegment.range(of: Data("soun".utf8)) != nil && initSegment.range(of: Data("vide".utf8)) == nil, "the sound track alone")
        var soundBytes = 0
        for stored in file.fragments {
            guard let segment = try ArchiveMedia.soundSegment(stored) else { continue }
            #expect(ArchiveMediaBytes.isConsistentSegment(segment))
            #expect(segment.count < stored.count)
            soundBytes += segment.count
        }
        #expect(soundBytes > 0)
        let frameBytes = audio.reduce(0) { $0 + $1.data.count }
        #expect(soundBytes > frameBytes, "every sound sample, each fragment with its moof")
    }

    @Test func aFileWithoutSoundHasNoSoundToGive() throws {
        let file = try ArchiveMediaFixtures.mux(ArchiveMediaFixtures.syntheticFrames(capture, count: 30, keyEvery: 10), cutEvery: 10)
        #expect(try ArchiveMedia.soundInit(file.initSegment) == nil)
        for stored in file.fragments { #expect(try ArchiveMedia.soundSegment(stored) == nil) }
        #expect(ArchiveMedia.soundMime == "audio/mp4; codecs=\"mp4a.40.2\"")
    }
}
