import Foundation

/// One segment of a recorded (VOD) playlist.
struct RecordedSegment: Sendable, Equatable {
    let number: Int
    let initNumber: Int
    let duration: Double
    let startsDiscontinuity: Bool
}

/// Writes HLS playlists as text. Paths are relative, so they inherit the ticket in the URL they are fetched from.
enum HLSPlaylist {
    static func master(codecs: String, width: Int, height: Int, bandwidth: Int) -> String {
        """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),CODECS="\(codecs)",RESOLUTION=\(width)x\(height)
        media.m3u8

        """
    }

    /// The sliding live playlist, or nil until three segments have been published, enough for a player to start on (`HLSSegmenter.hasFirstSegments`).
    static func live(_ s: HLSSegmenter) -> String? {
        guard s.hasFirstSegments, let target = s.targetDuration else { return nil }
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:\(s.mediaSequence)",
            "#EXT-X-DISCONTINUITY-SEQUENCE:\(s.discontinuitySequence)",
        ]
        // The target is fixed and a segment never ends off a key frame, so a longer one is reported at the target (RFC 8216: EXTINF rounded
        // must not exceed it). HLSSegment keeps the true duration.
        lines += segmentLines(s.published.map {
            let reported = Int($0.duration.rounded()) > target ? Double(target) : $0.duration
            return RecordedSegment(number: $0.number, initNumber: $0.initNumber, duration: reported, startsDiscontinuity: $0.startsDiscontinuity)
        })
        return lines.joined(separator: "\n") + "\n"
    }

    static func recorded(_ items: [RecordedSegment]) -> String {
        let longest = items.map(\.duration).max() ?? 0
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-TARGETDURATION:\(max(1, Int(longest.rounded(.up))))",
            "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MEDIA-SEQUENCE:0",
        ]
        lines += segmentLines(items)
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func segmentLines(_ items: [RecordedSegment]) -> [String] {
        var lines: [String] = []
        var mapped: Int?
        for item in items {
            if item.startsDiscontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            if mapped != item.initNumber {
                lines.append("#EXT-X-MAP:URI=\"init-\(item.initNumber).mp4\"")
                mapped = item.initNumber
            }
            lines.append("#EXTINF:\(String(format: "%.3f", item.duration)),")
            lines.append("seg-\(item.number).m4s")
        }
        return lines
    }
}
