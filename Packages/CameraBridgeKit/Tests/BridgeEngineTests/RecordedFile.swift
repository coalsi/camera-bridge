import FMP4
import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// A recorded file read back the way the store and the player do: the sidecar, the init segment, and every fragment through the FMP4 readers.
struct RecordedFile {
    let mp4: Data
    let index: CBIndexFile
    let info: FMP4InitInfo

    init(root: URL, segment: String) throws {
        mp4 = try Data(contentsOf: root.appending(path: "\(segment).mp4"))
        index = try CBIndexFile.decode(try Data(contentsOf: root.appending(path: "\(segment).cbidx")), mp4Size: UInt64(mp4.count))
        info = try FMP4InitReader.parse(mp4)
    }

    /// Video samples in the file.
    var frameCount: Int { index.fragments.reduce(0) { $0 + Int($1.samples) } }

    var start: Date { Date(timeIntervalSince1970: Double(index.startWallMs) / 1_000) }

    func fragmentBytes(_ number: Int) -> Data {
        let record = index.fragments[number]
        return mp4.subdata(in: Int(record.offset)..<Int(record.offset) + Int(record.length))
    }

    /// The start of fragment `number` by the index rule: `startWall + wallDelta`.
    func fragmentStart(_ number: Int) -> Date {
        Date(timeIntervalSince1970: Double(index.startWallMs + Int64(index.fragments[number].wallDeltaMs)) / 1_000)
    }

    /// Every video frame of the file, in decode order.
    func videoFrames() throws -> [EncodedVideoFrame] {
        try index.fragments.indices.flatMap { number -> [EncodedVideoFrame] in
            let bytes = fragmentBytes(number)
            let (moof, mdat) = try Self.moofAndMdat(bytes)
            let header = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat)
            let count = try #require(header.tracks.first { $0.trackID == info.videoTrackID }).samples.count
            return try FMP4FrameSlicer.videoFrames(header: header, bytes: bytes, bytesStart: Int(bytes.count) - moof.count - mdat - 8, info: info,
                                                   fragmentStart: fragmentStart(number), samples: 0..<count)
        }
    }

    func audioFrames() throws -> [EncodedAudioFrame] {
        try index.fragments.indices.flatMap { number -> [EncodedAudioFrame] in
            let bytes = fragmentBytes(number)
            let (moof, mdat) = try Self.moofAndMdat(bytes)
            let header = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat)
            let count = header.tracks.first { $0.trackID == info.audioTrackID }?.samples.count ?? 0
            return try FMP4FrameSlicer.audioFrames(header: header, bytes: bytes, bytesStart: Int(bytes.count) - moof.count - mdat - 8, info: info,
                                                   fragmentStart: fragmentStart(number), samples: 0..<count)
        }
    }

    static func moofAndMdat(_ fragment: Data) throws -> (moof: Data, mdatPayload: Int) {
        func u32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 << 8 | Int(fragment[fragment.startIndex + offset + $1]) }
        }
        let start = String(decoding: fragment[fragment.startIndex + 4..<fragment.startIndex + 8], as: UTF8.self) == "prft" ? u32(0) : 0
        let moofSize = u32(start)
        return (fragment.subdata(in: fragment.startIndex + start..<fragment.startIndex + start + moofSize), u32(start + moofSize) - 8)
    }

    /// What a recovery scan finds in `mp4`, which may be torn anywhere: the init segment's size and the index records of the fragments that are whole
    /// (`[prft] moof mdat` complete), measured with `FragmentIndexer` alone. It stops at the first fragment that is not whole.
    static func scan(_ mp4: Data) throws -> (info: FMP4InitInfo, records: [CBIndexFragmentRecord], firstWall: Date?) {
        let info = try FMP4InitReader.parse(mp4)
        var records: [CBIndexFragmentRecord] = []
        var position = info.byteCount
        var first: UInt64?
        var firstWall: Date?
        func u32(_ offset: Int) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(mp4[mp4.startIndex + offset + $1]) } }
        func type(_ offset: Int) -> String { String(decoding: mp4[mp4.startIndex + offset + 4..<mp4.startIndex + offset + 8], as: UTF8.self) }
        while mp4.count - position >= 8 {
            var length = 0
            if type(position) == "prft" {
                length = u32(position)
                guard length >= 8, mp4.count - position >= length + 8 else { break }
            }
            guard type(position + length) == "moof" else { break }
            let moofSize = u32(position + length)
            guard moofSize >= 8, mp4.count - position >= length + moofSize + 8, type(position + length + moofSize) == "mdat" else { break }
            let mdatSize = u32(position + length + moofSize)
            guard mdatSize >= 8, mp4.count - position >= length + moofSize + mdatSize else { break }
            length += moofSize + mdatSize
            let measurement = try FragmentIndexer.measure(mp4.subdata(in: mp4.startIndex + position..<mp4.startIndex + position + length), videoTrackID: info.videoTrackID)
            first = first ?? measurement.mediaStart
            firstWall = firstWall ?? measurement.wallClock
            records.append(try FragmentIndexer.record(measurement, offset: UInt64(position), firstMediaTime: first ?? 0, previousBackToKey: records.last.map { Int($0.backToKey) }))
            position += length
        }
        return (info, records, firstWall)
    }

    /// A sidecar rebuilt from the mp4 alone with `FragmentIndexer`: what a recovery scan produces.
    func rescanned() throws -> CBIndexFile {
        let scanned = try Self.scan(mp4)
        let startWallMs = Int64(((scanned.firstWall ?? start).timeIntervalSince1970 * 1_000).rounded())
        return CBIndexFile(flags: info.audio == nil ? 0 : CBIndexFormat.flagHasAudio, camera: index.camera, startWallMs: startWallMs,
                           endWallMs: FragmentIndexer.endWallMs(startWallMs: startWallMs, records: scanned.records), mp4Size: UInt64(mp4.count),
                           initLength: UInt32(info.byteCount), rollups: FragmentIndexer.rollups(startWallMs: startWallMs, records: scanned.records),
                           fragments: scanned.records)
    }
}
