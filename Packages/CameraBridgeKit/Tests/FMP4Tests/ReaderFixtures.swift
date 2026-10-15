import Foundation
import MediaCore
import Testing
@testable import FMP4

/// A recording the way the NVR recorder writes it: the init segment, then fragments cut at every keyframe and every `cutEvery` frames
/// (the second and later pieces of a long group of pictures are continuation fragments), each with its `prft`.
struct ReaderFixture {
    var initialization: Data
    var fragments: [Data]
    /// The frames of each fragment, as given to the muxer.
    var groups: [[EncodedVideoFrame]]
    /// The audio of each fragment.
    var audio: [[EncodedAudioFrame]]
    var file: Data { fragments.reduce(initialization) { $0 + $1 } }

    static let wallStart = Date(timeIntervalSince1970: 1_790_000_000)

    /// `count` frames at 30 fps from a keyframe every `gop` frames. B-frame style timestamps when `reordered`: pts is two frames after dts.
    static func frames(_ format: VideoFormat, count: Int, gop: Int, reordered: Bool = false, nalSizes: [Int] = [12, 30]) -> [EncodedVideoFrame] {
        (0..<count).map { index in
            let dts = Int64(index) * 3_000
            return Synthetic.videoFrame(format, index: index, isKeyframe: index % gop == 0, pts: reordered ? dts + 6_000 : dts, dts: reordered ? dts : nil,
                                        nalSizes: nalSizes, wallClock: wallStart.addingTimeInterval(Double(index) / 30))
        }
    }

    static func audioFrames(_ format: AudioFormat, count: Int) -> [EncodedAudioFrame] {
        (0..<count).map { Synthetic.audioFrame(format, index: $0, pts: Int64($0) * 1_024, size: 20 + $0 % 5) }
    }

    static func make(format: VideoFormat, frames: [EncodedVideoFrame], audioFormat: AudioFormat? = nil, audio: [EncodedAudioFrame] = [], cutEvery: Int) throws -> ReaderFixture {
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: audioFormat, writeProducerReferenceTime: true))
        var fixture = ReaderFixture(initialization: muxer.initializationSegment(), fragments: [], groups: [], audio: [])
        var start = 0
        while start < frames.count {
            var end = start + 1
            while end < frames.count, end - start < cutEvery, !frames[end].isKeyframe { end += 1 }
            let group = Array(frames[start..<end])
            let next = end < frames.count ? MediaTime(value: (frames[end].dts ?? frames[end].pts).value, timescale: 90_000) : nil
            let boundary = next.map { Double($0.value) / 90_000 } ?? .infinity
            let sound = audio.filter { Double($0.pts.value) / Double($0.pts.timescale) >= Double((group[0].dts ?? group[0].pts).value) / 90_000
                && Double($0.pts.value) / Double($0.pts.timescale) < boundary }
            fixture.fragments.append(try muxer.fragment(video: group, audio: sound, nextDecodeTime: next, continuation: !group[0].isKeyframe))
            fixture.groups.append(group)
            fixture.audio.append(sound)
            start = end
        }
        return fixture
    }
}

extension Data {
    /// Where the `moof` box starts in a fragment that may begin with a `prft` (32 bytes).
    var moofStart: Int { Bytes(self).fourCC(4) == "prft" ? Int(Bytes(self).u32(0)) : 0 }

    /// The `moof` box and the `mdat` payload size of a fragment.
    func moofAndMdat() throws -> (moof: Data, mdatPayload: Int) {
        let moofSize = Int(Bytes(self).u32(moofStart))
        let mdatSize = Int(Bytes(self).u32(moofStart + moofSize))
        return (subdata(in: startIndex + moofStart..<startIndex + moofStart + moofSize), mdatSize - 8)
    }
}
