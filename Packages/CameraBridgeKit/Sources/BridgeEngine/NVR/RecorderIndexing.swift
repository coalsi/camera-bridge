import FMP4
import Foundation

/// What the index (`CBIndexFile`) needs to know about a stored fragment, measured from the fragment's own bytes with the one FMP4 parser
/// (`MovieFragmentReader`). The recorder calls it for every fragment it writes and the recovery scanner for every fragment it finds, so a sidecar
/// rebuilt from the mp4 equals the one the recorder wrote.
package enum FragmentIndexer {
    package enum Failure: Error, Equatable, Sendable {
        /// The bytes are not exactly one `[prft] moof mdat`.
        case notOneFragment(String)
        /// A value does not fit its index field (or a continuation fragment has no keyframe before it).
        case outOfRange(String)
    }

    /// One fragment as measured.
    package struct Measurement: Equatable, Sendable {
        /// `prft` through the end of `mdat`: the input's size.
        package var length: Int
        /// From the start of the fragment to the first video byte.
        package var headerLength: Int
        /// `tfdt` of the video track.
        package var mediaStart: UInt64
        /// The sum of the video sample durations, in ticks of the video timescale.
        package var durationTicks: UInt64
        package var samples: Int
        /// The size of the first video sample when it is a sync sample, else 0.
        package var keyLength: Int
        /// The bytes of the video samples that are not sync samples.
        package var nonKeyBytes: Int
        /// The `prft` time, nil when the fragment has none.
        package var wallClock: Date?
        /// The fragment carries an audio track fragment.
        package var hasAudio: Bool
    }

    /// `fragment`: `[prft] moof mdat` and nothing else.
    package static func measure(_ fragment: Data, videoTrackID: UInt32 = 1) throws -> Measurement {
        let bytes = fragment.startIndex
        func u32(_ offset: Int) -> Int {
            var value = 0
            for index in 0..<4 { value = value << 8 | Int(fragment[bytes + offset + index]) }
            return value
        }
        func type(_ offset: Int) -> String { String(decoding: fragment[bytes + offset + 4..<bytes + offset + 8], as: UTF8.self) }
        guard fragment.count >= 16 else { throw Failure.notOneFragment("\(fragment.count) bytes") }
        var position = 0
        var wallClock: Date?
        if type(0) == "prft" {
            let size = u32(0)
            guard size >= 8, size <= fragment.count else { throw Failure.notOneFragment("prft size") }
            wallClock = try MovieFragmentReader.producerReferenceTime(prft: fragment.subdata(in: bytes..<bytes + size)).wallClock
            position = size
        }
        guard fragment.count - position >= 16, type(position) == "moof" else { throw Failure.notOneFragment("no moof") }
        let moofSize = u32(position)
        guard moofSize >= 8, moofSize <= fragment.count - position - 8, type(position + moofSize) == "mdat" else { throw Failure.notOneFragment("moof size") }
        let mdatSize = u32(position + moofSize)
        guard mdatSize >= 8, position + moofSize + mdatSize == fragment.count else { throw Failure.notOneFragment("mdat size") }
        let header = try MovieFragmentReader.parse(moof: fragment.subdata(in: bytes + position..<bytes + position + moofSize), mdatPayloadSize: mdatSize - 8)
        guard let video = header.tracks.first(where: { $0.trackID == videoTrackID }), let first = video.samples.first else {
            throw Failure.notOneFragment("no video samples")
        }
        let duration = video.samples.reduce(UInt64(0)) { $0 + UInt64($1.duration) }
        let nonKey = video.samples.filter { !$0.isSync }.reduce(0) { $0 + Int($1.size) }
        return Measurement(length: fragment.count, headerLength: position + video.dataOffset, mediaStart: video.baseDecodeTime, durationTicks: duration,
                           samples: video.samples.count, keyLength: first.isSync ? Int(first.size) : 0, nonKeyBytes: nonKey, wallClock: wallClock,
                           hasAudio: header.tracks.count > 1)
    }

    /// The index record of a measured fragment. `offset`: where its `prft` starts in the mp4. `firstMediaTime`: the `tfdt` of the file's first fragment
    /// (0 for every file the recorder writes). `previousBackToKey`: the previous fragment's value, nil for the file's first fragment (which must
    /// start with a keyframe).
    package static func record(_ measurement: Measurement, offset: UInt64, firstMediaTime: UInt64, previousBackToKey: Int?) throws -> CBIndexFragmentRecord {
        guard measurement.mediaStart >= firstMediaTime else { throw Failure.outOfRange("a fragment before the first") }
        let relative = measurement.mediaStart - firstMediaTime
        guard let length = UInt32(exactly: measurement.length), let mediaStart = UInt32(exactly: relative),
              let duration = UInt32(exactly: measurement.durationTicks), let header = UInt32(exactly: measurement.headerLength),
              let key = UInt32(exactly: measurement.keyLength), let nonKey = UInt32(exactly: measurement.nonKeyBytes),
              let samples = UInt16(exactly: measurement.samples) else {
            throw Failure.outOfRange("a value does not fit the index")
        }
        let back: Int
        if measurement.keyLength > 0 {
            back = 0
        } else if let previousBackToKey {
            back = previousBackToKey + 1
        } else {
            throw Failure.outOfRange("the first fragment of a file does not start with a keyframe")
        }
        guard let backToKey = UInt16(exactly: back) else { throw Failure.outOfRange("a group of pictures of more than 65535 fragments") }
        let wallDelta = (relative + 45) / 90                                  // milliseconds, rounded
        guard let wallDeltaMs = UInt32(exactly: wallDelta) else { throw Failure.outOfRange("a file longer than 49 days") }
        return CBIndexFragmentRecord(offset: offset, length: length, wallDeltaMs: wallDeltaMs, mediaStart: mediaStart, durationTicks: duration,
                                     headerLength: header, keyLength: key, nonKeyBytes: nonKey, samples: samples, backToKey: backToKey)
    }

    /// The end of the last fragment, in epoch milliseconds.
    package static func endWallMs(startWallMs: Int64, records: [CBIndexFragmentRecord]) -> Int64 {
        guard let last = records.last else { return startWallMs }
        return startWallMs + Int64(last.wallDeltaMs) + Int64((UInt64(last.durationTicks) + 45) / 90)
    }

    /// Per-minute rollups: rollup `i` covers `[startWall + i minutes, +1 minute)`. `nonKeyBytes` is the sum of the fragments' non-key bytes weighted
    /// by how much of each fragment lies in the minute; `peakRate` the busiest overlapping fragment's non-key bytes per second; `coveredMs` the
    /// milliseconds of the minute that have video.
    package static func rollups(startWallMs: Int64, records: [CBIndexFragmentRecord]) -> [CBIndexRollup] {
        guard !records.isEmpty else { return [] }
        let minute: Int64 = 60_000
        let end = endWallMs(startWallMs: startWallMs, records: records) - startWallMs
        let count = min(CBIndexFormat.maximumRollups, Int((end + minute - 1) / minute))
        var bytes = [Double](repeating: 0, count: count)
        var peak = [Double](repeating: 0, count: count)
        var covered = [Int64](repeating: 0, count: count)
        for record in records {
            let begin = Int64(record.wallDeltaMs)
            let finish = begin + max(1, Int64((UInt64(record.durationTicks) + 45) / 90))
            let seconds = Double(finish - begin) / 1_000
            let rate = Double(record.nonKeyBytes) / seconds
            var index = Int(begin / minute)
            while index < count, Int64(index) * minute < finish {
                let overlap = min(finish, Int64(index + 1) * minute) - max(begin, Int64(index) * minute)
                if overlap > 0 {
                    bytes[index] += Double(record.nonKeyBytes) * Double(overlap) / Double(finish - begin)
                    peak[index] = max(peak[index], rate)
                    covered[index] += overlap
                }
                index += 1
            }
        }
        return (0..<count).map { index in
            CBIndexRollup(nonKeyBytes: UInt32(clamping: Int64(bytes[index].rounded())), peakRate: UInt32(clamping: Int64(peak[index].rounded())),
                          coveredMs: UInt16(clamping: min(covered[index], minute)))
        }
    }
}
