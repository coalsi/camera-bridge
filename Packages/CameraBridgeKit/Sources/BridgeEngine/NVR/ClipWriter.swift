import Foundation

/// Writes one part (counted from 1, like `ClipPart.index`) of a planned clip to a sink in one pass (export-clip spec 3.4): `ftyp`, `moov`, the `mdat` header, then the pictures of each
/// source fragment copied untouched (each followed by that fragment's sound, when the clip has sound), one fragment in memory at a time. The sink receives exactly `ClipPart.byteCount` bytes. It stops between
/// fragments when the caller cancels, and tells `progress` how many bytes have been written after every write.
package struct ClipWriter: Sendable {
    private let archive: any ArchiveReading

    /// The largest fragment accepted (a fragment is a few seconds of one camera; the largest seen is 1.77 MB). An index that claims more is lying.
    static let maximumFragmentBytes = 16 << 20

    package init(archive: any ArchiveReading) { self.archive = archive }

    /// Throws only `ClipError`: `cancelled`, `driveGone` for the first read that finds the recordings gone, `damaged(at:)` for a fragment that is
    /// not what the index said, `sink` for a sink that refused, and `notReady` for a plan that was not made by `ClipPlanner`.
    package func write(_ plan: ClipPlan, part: Int, to sink: any ClipSink, progress: @Sendable (Int64) -> Void) async throws {
        guard plan.parts.indices.contains(part - 1), plan.tables.indices.contains(part - 1) else { throw ClipError.notReady }
        let tables = plan.tables[part - 1]
        let layout = try ClipLayout.make(tables)
        var written: Int64 = 0

        func put(_ bytes: Data) async throws {
            if Task.isCancelled { throw ClipError.cancelled }
            do { try await sink.write(bytes) } catch let error as ClipError { throw error } catch {
                if Task.isCancelled { throw ClipError.cancelled }
                throw ClipError.sink(String(describing: error))
            }
            written += Int64(bytes.count)
            progress(written)
        }

        try await put(layout.ftyp)
        try await put(layout.moov)
        try await put(layout.mdatHeader)
        var reads = 0
        let sound = layout.hasSound ? tables.sound : nil
        var soundIndex = 0
        for (index, copy) in tables.copies.enumerated() {
            if Task.isCancelled { throw ClipError.cancelled }
            let fragment: Data
            do {
                fragment = try await archive.read(copy.fragment, .fragment)
            } catch let error as ArchiveError {
                switch error {
                case .fileGone, .timedOut: throw reads == 0 ? ClipError.driveGone : ClipError.damaged(at: copy.fragment.start)
                case .unreadable, .noKeyframe: throw ClipError.damaged(at: copy.fragment.start)
                }
            } catch is CancellationError {
                throw ClipError.cancelled
            }
            reads += 1
            let end = copy.skipBytes + copy.length
            guard copy.skipBytes >= 0, copy.length > 0, end <= fragment.count, fragment.count <= Self.maximumFragmentBytes else {
                throw ClipError.damaged(at: copy.fragment.start)
            }
            try await put(fragment.subdata(in: fragment.startIndex + copy.skipBytes ..< fragment.startIndex + end))
            while let sound, soundIndex < sound.copies.count, sound.follows[soundIndex] == index {
                let piece = sound.copies[soundIndex]
                let pieceEnd = piece.skipBytes + piece.length
                guard piece.fragment == copy.fragment, piece.skipBytes >= 0, piece.length > 0, pieceEnd <= fragment.count else {
                    throw ClipError.damaged(at: copy.fragment.start)
                }
                try await put(fragment.subdata(in: fragment.startIndex + piece.skipBytes ..< fragment.startIndex + pieceEnd))
                soundIndex += 1
            }
        }
        guard written == layout.totalBytes else { throw ClipError.damaged(at: tables.wallStart) }
    }
}
