import Foundation
import MediaCore
import Testing
@testable import FMP4

/// A recording cut at every byte offset (a crash, a pulled cable): the whole fragments in front of the cut are found and read in full, the torn
/// rest is never read as a fragment, and no reader throws anything but `FMP4Error` or reads past the bytes it was given.
@Suite struct TornFileTests {
    @Test func aFileCutAtEveryByteGivesItsWholeFragmentsAndNothingElse() throws {
        let format = try Golden.h264Format
        let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        // Three fragments: a keyframe fragment of 75 frames, its continuation of 75, and a second group of 20.
        var frames = ReaderFixture.frames(format, count: 170, gop: 150)
        frames = frames.enumerated().map { index, frame in
            var copy = frame
            copy.wallClock = ReaderFixture.wallStart.addingTimeInterval(Double(index) / 30)
            return copy
        }
        let fixture = try ReaderFixture.make(format: format, frames: frames, audioFormat: aac, audio: ReaderFixture.audioFrames(aac, count: 190), cutEvery: 75)
        #expect(fixture.fragments.count == 3)
        let info = try FMP4InitReader.parse(fixture.initialization)
        var ends: [Int] = []
        var total = fixture.initialization.count
        for fragment in fixture.fragments { total += fragment.count; ends.append(total) }
        let file = fixture.file
        #expect(file.count == total)
        for cut in 0...file.count {
            let torn = file.prefix(cut)
            let whole = TornFile.wholeFragments(in: torn)
            let expected = ends.filter { $0 <= cut }.count
            #expect(whole.fragments.count == expected, "cut at \(cut)")
            #expect(whole.end <= cut)
            for (index, range) in whole.fragments.enumerated() {
                let fragment = Data(torn[range])
                #expect(fragment == fixture.fragments[index])
                // Reading it in full never goes past the bytes: header, frames and sound.
                let (moof, mdat) = try fragment.moofAndMdat()
                let header = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat)
                let count = try #require(header.tracks.first).samples.count
                let video = try FMP4FrameSlicer.videoFrames(header: header, bytes: fragment, bytesStart: fragment.moofStart, info: info,
                                                            fragmentStart: ReaderFixture.wallStart, samples: 0..<count)
                #expect(video.map(\.nalUnits) == fixture.groups[index].map(\.nalUnits))
            }
            // The torn rest: whatever bytes follow the last whole fragment are not one, and reading them as a header fails cleanly.
            let rest = torn.dropFirst(whole.end)
            if rest.count >= 8, rest.count < Int(Bytes(Data(rest)).u32(0)) {
                #expect(throws: FMP4Error.self) { _ = try MovieFragmentReader.parse(moof: Data(rest.prefix(Int(Bytes(Data(rest)).u32(0))))) }
            }
        }
    }
}
