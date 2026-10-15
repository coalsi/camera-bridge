import BridgeSupport
import FMP4
import Foundation

/// Rebuilds the `.cbidx` index of an mp4 from its box headers (Mac spec 4.5): after a crash, for a file whose sidecar is missing, stale or
/// untrusted, or for a file the recorder abandoned. The mp4 is the truth, the index a cache. Reads the `ftyp`/`moov`, then the
/// `prft` + `moof` + `mdat` triples one after the other, parses each `prft` and `moof` with the one FMP4 parser (`MovieFragmentReader`) and
/// stops at the first fragment that is incomplete or does not parse. Blocking disk work, and only ever for a file nobody owns.
enum IndexScanner {
    /// The largest `moof` read into memory (a fragment of 900 samples has one of about 15 KB).
    private static let maximumMovieFragmentBytes = 1_048_576
    private static let maximumInitBytes = 1_048_576
    /// The most a crash can leave after the last whole fragment: one fragment (at most 16 MiB) and its boxes' headers. More than this after the
    /// last fragment that parses is damage in the middle of the file, not a torn tail: the file is indexed up to there and kept whole.
    static let maximumTornTail = UInt64(ArchiveConstants.fragmentMaximumBytes) + 1_048_576

    /// Reads `mp4` and works out the index of its whole fragments. Writes nothing.
    static func scan(mp4: URL, camera: UUID) throws -> IndexScanOutcome {
        let handle = try FileHandle(forReadingFrom: mp4)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let reader = BoxReader(handle: handle, fileSize: fileSize)

        // ftyp, moov
        guard let ftyp = try reader.header(at: 0), ftyp.type == "ftyp", let moov = try reader.header(at: ftyp.size), moov.type == "moov" else {
            return .unusable("the file does not start with an initialization segment")
        }
        let initLength = ftyp.size + moov.size
        guard initLength <= UInt64(maximumInitBytes), initLength <= fileSize else { return .unusable("the initialization segment is cut short") }
        let info: FMP4InitInfo
        do {
            info = try FMP4InitReader.parse(try reader.read(at: 0, count: Int(initLength)))
        } catch {
            return .unusable("the initialization segment cannot be read")
        }

        // prft + moof + mdat, repeated.
        var records: [CBIndexFragmentRecord] = []
        var startWallMs: Int64?
        var firstDecodeTime: UInt64?
        var lastDecodeTime: UInt64?
        var wholeSize = initLength
        var offset = initLength
        while offset < fileSize {
            guard let prft = try reader.header(at: offset), prft.type == "prft", prft.size >= 20, prft.size <= 64,
                  let moof = try reader.header(at: offset + prft.size), moof.type == "moof", moof.size <= UInt64(maximumMovieFragmentBytes),
                  let mdat = try reader.header(at: offset + prft.size + moof.size), mdat.type == "mdat" else {
                if records.isEmpty, let first = try reader.header(at: offset), first.type == "moof" {
                    return .unusable("the first fragment has no producer reference time")
                }
                break
            }
            let end = offset + prft.size + moof.size + mdat.size
            guard end <= fileSize, end - offset <= UInt64(UInt32.max) else { break }
            let moofStart = offset + prft.size
            let reference: ProducerReferenceTime
            let header: MovieFragmentHeader
            do {
                reference = try MovieFragmentReader.producerReferenceTime(prft: try reader.read(at: offset, count: Int(prft.size)))
                header = try MovieFragmentReader.parse(moof: try reader.read(at: moofStart, count: Int(moof.size)),
                                                       mdatPayloadSize: Int(mdat.size - UInt64(mdat.headerSize)))
            } catch {
                break
            }
            guard let video = header.tracks.first(where: { $0.trackID == info.videoTrackID }), !video.samples.isEmpty,
                  video.samples.count <= Int(UInt16.max) else { break }
            let first = firstDecodeTime ?? video.baseDecodeTime
            guard lastDecodeTime.map({ video.baseDecodeTime > $0 }) ?? true else { break }
            let measurement = FragmentIndexer.Measurement(
                length: Int(end - offset), headerLength: Int(prft.size) + Int(max(0, video.dataOffset)), mediaStart: video.baseDecodeTime,
                durationTicks: video.samples.reduce(UInt64(0)) { $0 + UInt64($1.duration) }, samples: video.samples.count,
                keyLength: video.samples[0].isSync ? Int(video.samples[0].size) : 0,
                nonKeyBytes: video.samples.filter { !$0.isSync }.reduce(0) { $0 + Int($1.size) }, wallClock: reference.wallClock, hasAudio: header.tracks.count > 1)
            guard video.dataOffset >= 0, measurement.headerLength <= measurement.length,
                  let record = try? FragmentIndexer.record(measurement, offset: offset, firstMediaTime: first, previousBackToKey: records.last.map { Int($0.backToKey) })
            else { break }
            if startWallMs == nil { startWallMs = Int64((reference.wallClock.timeIntervalSince1970 * 1_000).rounded()) }
            records.append(record)
            firstDecodeTime = first
            lastDecodeTime = video.baseDecodeTime
            wholeSize = end
            offset = end
        }
        guard let startWallMs, !records.isEmpty else { return .empty }
        let endWallMs = FragmentIndexer.endWallMs(startWallMs: startWallMs, records: records)
        // A torn tail goes; a stretch of the file that is too long to be one is damage, and stays.
        let keepSize = fileSize - wholeSize <= maximumTornTail ? wholeSize : fileSize
        let index = CBIndexFile(flags: info.audio == nil ? 0 : CBIndexFormat.flagHasAudio, camera: camera, startWallMs: startWallMs,
                                endWallMs: endWallMs, mp4Size: keepSize, initLength: UInt32(initLength),
                                rollups: FragmentIndexer.rollups(startWallMs: startWallMs, records: records), fragments: records)
        // Whatever this returns, the loader must be able to trust.
        guard (try? CBIndexFile.decode(index.encoded(), mp4Size: keepSize)) == index else { return .unusable("the fragments do not add up") }
        return .indexed(index, wholeSize: keepSize, fileSize: fileSize)
    }

    /// `scan`, then cuts a torn tail off the mp4 and writes the sidecar (atomically, 0600). For a file nobody owns only. A file with damage in
    /// the middle is not cut: its sidecar lists the fragments before the damage and gives the file's whole size.
    static func repair(mp4: URL, sidecar: URL, camera: UUID) throws -> IndexScanOutcome {
        let outcome = try scan(mp4: mp4, camera: camera)
        guard case .indexed(let index, let wholeSize, let fileSize) = outcome else { return outcome }
        if fileSize > wholeSize {
            let handle = try FileHandle(forUpdating: mp4)
            defer { try? handle.close() }
            try handle.truncate(atOffset: wholeSize)
            try handle.synchronize()
        }
        try PrivateFiles.write(index.encoded(), to: sidecar)
        return outcome
    }
}

/// Positioned reads of box headers from an open file.
private struct BoxReader {
    struct Header {
        var type: String
        /// The box's size, header included; a box that runs to the end of the file (size 0) has the rest of the file.
        var size: UInt64
        var headerSize: Int
    }

    var handle: FileHandle
    var fileSize: UInt64

    /// The header of the box at `offset`; nil at or past the end of the file or when it is cut short or its size is impossible.
    func header(at offset: UInt64) throws -> Header? {
        guard offset + 8 <= fileSize else { return nil }
        let bytes = try read(at: offset, count: Int(min(16, fileSize - offset)))
        var reader = ByteReader(bytes)
        guard let size32 = try? reader.readUInt32BE(), let name = try? reader.readBytes(4) else { return nil }
        var size = UInt64(size32)
        var headerSize = 8
        if size32 == 1 {
            guard let large = try? reader.readUInt64BE() else { return nil }
            size = large
            headerSize = 16
        } else if size32 == 0 {
            size = fileSize - offset
        }
        guard size >= UInt64(headerSize), offset + size <= fileSize else { return nil }
        return Header(type: String(decoding: name, as: UTF8.self), size: size, headerSize: headerSize)
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        var data = Data()
        while data.count < count {
            guard let piece = try handle.read(upToCount: count - data.count), !piece.isEmpty else { break }
            data.append(piece)
        }
        guard data.count == count else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}
