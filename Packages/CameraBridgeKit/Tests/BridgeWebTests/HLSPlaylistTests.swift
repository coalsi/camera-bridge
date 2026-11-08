import BridgeEngine
import Foundation
import Testing
@testable import BridgeWeb

@Suite(.timeLimit(.minutes(1))) struct HLSPlaylistTests {
    private static let mime = #"video/mp4; codecs="hvc1.1.6.L93.B0,mp4a.40.2""#

    /// 7 segments of 2 s; an init change before segment 4; first six slide to 3...6 (+ one more to keep 6).
    private static func segmenter() -> HLSSegmenter {
        var s = HLSSegmenter()
        let frame: Int64 = 3_000
        func init_(_ t: UInt8) { s.add(.initialization(Data([t]), mime: mime, width: 1280, height: 720)) }
        func second(_ key: Bool) {
            for i in 0..<30 { s.add(.media(Data([1, 2, 3]), keyframe: key && i == 0, duration: frame)) }
        }
        init_(0)
        for _ in 0..<4 { second(true); second(false) } // segments 0...2 published as keys arrive
        init_(1)
        for _ in 0..<4 { second(true); second(false) }
        s.add(.media(Data([1]), keyframe: true, duration: frame))
        return s
    }

    @Test func liveGolden() throws {
        let s = Self.segmenter()
        #expect(s.mediaSequence == 1)
        let text = try #require(HLSPlaylist.live(s))
        #expect(text.hasPrefix("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-TARGETDURATION:6\n"))
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:1\n"))
        #expect(text.contains("#EXT-X-DISCONTINUITY-SEQUENCE:0\n"))
        #expect(text.contains("#EXT-X-MAP:URI=\"init-0.mp4\"\n#EXTINF:2.000,\nseg-1.m4s\n"))
        #expect(text.contains("#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init-1.mp4\"\n#EXTINF:2.000,\nseg-3.m4s\n"))
        #expect(!text.contains("#EXT-X-ENDLIST"))
        #expect(!text.contains("PLAYLIST-TYPE"))
    }

    @Test func liveCountsRemovedDiscontinuities() throws {
        var s = Self.segmenter()
        for _ in 0..<4 {
            for _ in 0..<2 { for i in 0..<30 { s.add(.media(Data([1]), keyframe: i == 0, duration: 3_000)) } }
        }
        s.add(.media(Data([1]), keyframe: true, duration: 3_000))
        let text = try #require(HLSPlaylist.live(s))
        #expect(s.discontinuitySequence == 1)
        #expect(text.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1\n"))
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:\(s.mediaSequence)\n"))
        #expect(text.contains("#EXT-X-MAP:URI=\"init-1.mp4\""))
    }

    @Test func recordedGolden() {
        let text = HLSPlaylist.recorded([
            RecordedSegment(number: 0, initNumber: 0, duration: 2.5, startsDiscontinuity: false),
            RecordedSegment(number: 1, initNumber: 1, duration: 4.0, startsDiscontinuity: true),
        ])
        #expect(text == """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-TARGETDURATION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="init-0.mp4"
        #EXTINF:2.500,
        seg-0.m4s
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="init-1.mp4"
        #EXTINF:4.000,
        seg-1.m4s
        #EXT-X-ENDLIST

        """)
    }

    @Test func masterGolden() {
        let text = HLSPlaylist.master(codecs: "hvc1.1.6.L93.B0,mp4a.40.2", width: 1280, height: 720, bandwidth: 2_000_000)
        #expect(text == """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="hvc1.1.6.L93.B0,mp4a.40.2",RESOLUTION=1280x720
        media.m3u8

        """)
    }

    @Test func aLongSegmentIsReportedAtTheTarget() throws {
        var s = HLSSegmenter()
        s.add(.initialization(Data([0]), mime: Self.mime, width: 1280, height: 720))
        func seconds(_ n: Int, keyEvery: Int) {
            for i in 0..<(n * 30) { s.add(.media(Data([1]), keyframe: i % (keyEvery * 30) == 0, duration: 3_000)) }
        }
        seconds(2, keyEvery: 2)
        seconds(2, keyEvery: 2)
        seconds(8, keyEvery: 8)
        s.add(.media(Data([1]), keyframe: true, duration: 3_000))
        #expect(s.targetDuration == 6)
        #expect(s.published.last?.duration == 8.0)
        let text = try #require(HLSPlaylist.live(s))
        #expect(text.contains("#EXTINF:6.000,\nseg-2.m4s\n"))
        #expect(!text.contains("8.000"))
    }

    /// Big segments can leave only the newest in the window. The playlist was out, and players are polling it: it stays, however short.
    @Test func aPlaylistStaysWhenTheByteCapLeavesOneSegment() throws {
        var s = HLSSegmenter(maximumBytes: 1_000)
        s.add(.initialization(Data([0]), mime: Self.mime, width: 1280, height: 720))
        for second in 0..<6 {
            for i in 0..<30 { s.add(.media(Data(repeating: 1, count: 12), keyframe: i == 0 && second % 2 == 0, duration: 3_000)) }
        }
        s.add(.media(Data([1]), keyframe: true, duration: 3_000))
        #expect(s.published.count == 1 && s.mediaSequence == 2)
        let text = try #require(HLSPlaylist.live(s))
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:2\n") && text.contains("seg-2.m4s\n"))
    }
}
