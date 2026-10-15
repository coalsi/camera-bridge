import BridgeSupport
import Foundation

/// The `.cbidx` v1 sidecar (Mac spec 4.4): big-endian, written once when a file closes. The mp4 is the truth; the index is a cache that
/// the recovery scanner can rebuild from the `prft`/`moof` headers. There is no append, tag, CRC or trailer.
///
///     0   'CBNX'                      4 B
///     4   version = 1                 u16
///     6   flags (bit 0: audio track)  u16
///     8   camera UUID                 16 B, in `UUID.uuid` order
///     24  startWallMs                 i64   the file's anchor in Unix epoch milliseconds
///     32  endWallMs                   i64   the end of the last fragment
///     40  mp4Size                     u64   the mp4's size when the file closed
///     48  initLength                  u32   bytes of ftyp+moov at the start of the mp4
///     52  count                       u32   fragment records
///     56  rollupCount                 u16   per-minute rollups
///     58  reserved                    6 B   zero
///     64  rollupCount x 12 B          nonKeyBytes u32, peakRate u32, coveredMs u16, reserved u16 (zero)
///     ..  count x 40 B                offset u64, length u32, wallDeltaMs u32, mediaStart u32, durationTicks u32, headerLength u32,
///                                     keyLength u32, nonKeyBytes u32, samples u16, backToKey u16
///
/// Rollup `i` covers `[startWall + i minutes, startWall + (i + 1) minutes)`; `peakRate` is the busiest fragment's non-keyframe bytes
/// per second in it and `coveredMs` how much of it has video. A record's `offset` is where its `prft` starts in the mp4 and `length` runs
/// to the end of its `mdat`; `wallDeltaMs` is the derived start (Mac spec 4.3) minus `startWallMs`; `mediaStart` is `tfdt` minus the
/// file's first `tfdt`; `headerLength` is the distance from `offset` to the first video byte; `keyLength` is the first sample's size
/// when it is a sync sample, else 0; `backToKey` counts fragments back to the one holding the governing keyframe.
package enum CBIndexFormat {
    static let magic: [UInt8] = Array("CBNX".utf8)
    static let version: UInt16 = 1
    static let headerLength = 64
    static let rollupLength = 12
    static let recordLength = 40
    static let flagHasAudio: UInt16 = 1
    /// A file holds at most 900 s of 2.5 s fragments; a sidecar claiming more records than this is damaged.
    static let maximumRecords = 100_000
    static let maximumRollups = 1_000
}

package struct CBIndexRollup: Equatable, Sendable {
    package var nonKeyBytes: UInt32
    package var peakRate: UInt32
    package var coveredMs: UInt16

    package init(nonKeyBytes: UInt32, peakRate: UInt32, coveredMs: UInt16) {
        self.nonKeyBytes = nonKeyBytes
        self.peakRate = peakRate
        self.coveredMs = coveredMs
    }
}

package struct CBIndexFragmentRecord: Equatable, Sendable {
    package var offset: UInt64
    package var length: UInt32
    package var wallDeltaMs: UInt32
    package var mediaStart: UInt32
    package var durationTicks: UInt32
    package var headerLength: UInt32
    package var keyLength: UInt32
    package var nonKeyBytes: UInt32
    package var samples: UInt16
    package var backToKey: UInt16

    package init(offset: UInt64, length: UInt32, wallDeltaMs: UInt32, mediaStart: UInt32, durationTicks: UInt32, headerLength: UInt32,
                 keyLength: UInt32, nonKeyBytes: UInt32, samples: UInt16, backToKey: UInt16) {
        self.offset = offset
        self.length = length
        self.wallDeltaMs = wallDeltaMs
        self.mediaStart = mediaStart
        self.durationTicks = durationTicks
        self.headerLength = headerLength
        self.keyLength = keyLength
        self.nonKeyBytes = nonKeyBytes
        self.samples = samples
        self.backToKey = backToKey
    }

    package var hasKeyframe: Bool { keyLength > 0 }
}

package enum CBIndexError: Error, Equatable, Sendable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt16)
    /// The file is not `64 + rollupCount x 12 + count x 40` bytes, or claims more records than a file can hold.
    case sizeMismatch
    /// The index was written for an mp4 of another size: it is stale.
    case mp4SizeMismatch
    /// Record `n` points outside the mp4, overlaps its predecessor or contradicts itself.
    case inconsistentRecord(Int)
}

package struct CBIndexFile: Equatable, Sendable {
    package var flags: UInt16
    package var camera: UUID
    package var startWallMs: Int64
    package var endWallMs: Int64
    package var mp4Size: UInt64
    package var initLength: UInt32
    package var rollups: [CBIndexRollup]
    package var fragments: [CBIndexFragmentRecord]

    package init(flags: UInt16 = 0, camera: UUID, startWallMs: Int64, endWallMs: Int64, mp4Size: UInt64, initLength: UInt32,
                 rollups: [CBIndexRollup] = [], fragments: [CBIndexFragmentRecord] = []) {
        self.flags = flags
        self.camera = camera
        self.startWallMs = startWallMs
        self.endWallMs = endWallMs
        self.mp4Size = mp4Size
        self.initLength = initLength
        self.rollups = rollups
        self.fragments = fragments
    }

    package var hasAudio: Bool { flags & CBIndexFormat.flagHasAudio != 0 }

    /// The size of an encoded index with these counts.
    package static func byteCount(rollups: Int, fragments: Int) -> Int {
        CBIndexFormat.headerLength + rollups * CBIndexFormat.rollupLength + fragments * CBIndexFormat.recordLength
    }

    package func encoded() -> Data {
        var writer = ByteWriter()
        writer.write(Data(CBIndexFormat.magic))
        writer.writeUInt16BE(CBIndexFormat.version)
        writer.writeUInt16BE(flags)
        withUnsafeBytes(of: camera.uuid) { writer.write(Data($0)) }
        writer.writeUInt64BE(UInt64(bitPattern: startWallMs))
        writer.writeUInt64BE(UInt64(bitPattern: endWallMs))
        writer.writeUInt64BE(mp4Size)
        writer.writeUInt32BE(initLength)
        writer.writeUInt32BE(UInt32(fragments.count))
        writer.writeUInt16BE(UInt16(rollups.count))
        writer.write(Data(count: 6))
        for rollup in rollups {
            writer.writeUInt32BE(rollup.nonKeyBytes)
            writer.writeUInt32BE(rollup.peakRate)
            writer.writeUInt16BE(rollup.coveredMs)
            writer.writeUInt16BE(0)
        }
        for record in fragments {
            writer.writeUInt64BE(record.offset)
            writer.writeUInt32BE(record.length)
            writer.writeUInt32BE(record.wallDeltaMs)
            writer.writeUInt32BE(record.mediaStart)
            writer.writeUInt32BE(record.durationTicks)
            writer.writeUInt32BE(record.headerLength)
            writer.writeUInt32BE(record.keyLength)
            writer.writeUInt32BE(record.nonKeyBytes)
            writer.writeUInt16BE(record.samples)
            writer.writeUInt16BE(record.backToKey)
        }
        return writer.data
    }

    /// Trusted only if magic and version match, the size is exactly `64 + rollupCount x 12 + count x 40`, `mp4Size` equals the mp4's
    /// current size and every record lies inside the mp4 after its predecessor. Anything else throws and the scanner rebuilds the index.
    package static func decode(_ data: Data, mp4Size currentSize: UInt64) throws -> CBIndexFile {
        guard data.count >= CBIndexFormat.headerLength else { throw CBIndexError.truncated }
        var reader = ByteReader(data)
        do {
            guard try reader.readBytes(4) == Data(CBIndexFormat.magic) else { throw CBIndexError.badMagic }
            let version = try reader.readUInt16BE()
            guard version == CBIndexFormat.version else { throw CBIndexError.unsupportedVersion(version) }
            let flags = try reader.readUInt16BE()
            let uuidBytes = try reader.readBytes(16)
            let startWallMs = Int64(bitPattern: try reader.readUInt64BE())
            let endWallMs = Int64(bitPattern: try reader.readUInt64BE())
            let mp4Size = try reader.readUInt64BE()
            let initLength = try reader.readUInt32BE()
            let count = Int(try reader.readUInt32BE())
            let rollupCount = Int(try reader.readUInt16BE())
            try reader.skip(6)
            guard count <= CBIndexFormat.maximumRecords, rollupCount <= CBIndexFormat.maximumRollups,
                  data.count == byteCount(rollups: rollupCount, fragments: count) else { throw CBIndexError.sizeMismatch }
            guard mp4Size == currentSize else { throw CBIndexError.mp4SizeMismatch }
            var rollups: [CBIndexRollup] = []
            rollups.reserveCapacity(rollupCount)
            for _ in 0..<rollupCount {
                let nonKeyBytes = try reader.readUInt32BE()
                let peakRate = try reader.readUInt32BE()
                let coveredMs = try reader.readUInt16BE()
                try reader.skip(2)
                rollups.append(CBIndexRollup(nonKeyBytes: nonKeyBytes, peakRate: peakRate, coveredMs: coveredMs))
            }
            var fragments: [CBIndexFragmentRecord] = []
            fragments.reserveCapacity(count)
            var nextFree = UInt64(initLength)
            for index in 0..<count {
                let record = CBIndexFragmentRecord(
                    offset: try reader.readUInt64BE(), length: try reader.readUInt32BE(), wallDeltaMs: try reader.readUInt32BE(),
                    mediaStart: try reader.readUInt32BE(), durationTicks: try reader.readUInt32BE(), headerLength: try reader.readUInt32BE(),
                    keyLength: try reader.readUInt32BE(), nonKeyBytes: try reader.readUInt32BE(), samples: try reader.readUInt16BE(),
                    backToKey: try reader.readUInt16BE())
                let (end, overflow) = record.offset.addingReportingOverflow(UInt64(record.length))
                guard record.offset >= nextFree, !overflow, end <= mp4Size, record.length > 0, record.headerLength <= record.length,
                      record.keyLength <= record.length, Int(record.backToKey) <= index, record.keyLength == 0 || record.backToKey == 0
                else { throw CBIndexError.inconsistentRecord(index) }
                nextFree = end
                fragments.append(record)
            }
            let b = [UInt8](uuidBytes)
            let camera = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            return CBIndexFile(flags: flags, camera: camera, startWallMs: startWallMs, endWallMs: endWallMs, mp4Size: mp4Size,
                               initLength: initLength, rollups: rollups, fragments: fragments)
        } catch is ByteError {
            throw CBIndexError.truncated
        }
    }
}
