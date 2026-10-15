import Foundation

/// A closed file that retention may delete: own-pattern name, valid sidecar, owned by no recorder. Nothing else is ever a candidate.
struct RetentionCandidate: Equatable, Sendable {
    var camera: UUID
    var segment: String
    var startMs: Int64
    var endMs: Int64
    /// The mp4 plus its sidecar.
    var bytes: UInt64
}

/// Which files to delete (Mac spec 6 with the Linux changes). Pure. Two rules, from the archive's own measured bytes only: files that ended
/// before the keep time, then the oldest-start-first across every camera until the archive fits `maximumBytes`. Free space is not an input:
/// unlinking need not raise it (snapshots, recycle bins), so a rule fed by it could eat the whole archive.
enum RetentionPlanner {
    struct Input: Sendable {
        /// Every closed, own-pattern file with a valid sidecar, whether or not its camera is configured.
        var closed: [RetentionCandidate]
        /// The bytes of files a recorder has open (counted, never deleted).
        var openBytes: UInt64
        /// The newest start of any file, open or closed (the clock-jump guard).
        var newestStartMs: Int64?
        var nowMs: Int64
        var keepDays: Int
        /// `ArchiveStorageStatus.effectiveMaximumBytes(maxSizeGB:)`.
        var maximumBytes: UInt64
    }

    /// The files to delete, in the order to delete them: the aged ones (oldest first), then the oldest others until the rest fits.
    static func plan(_ input: Input) -> [RetentionCandidate] {
        var used = input.closed.reduce(input.openBytes) { $0 + $1.bytes }
        var deletions: [RetentionCandidate] = []
        var remaining = input.closed.sorted { ($0.startMs, $0.segment) < ($1.startMs, $1.segment) }

        // Age: files that ended before the keep time. Skipped while the newest file starts in the future (the clock jumped).
        let futureLimit = input.nowMs + Int64(ArchiveConstants.futureFileGuard * 1_000)
        if !(input.newestStartMs.map { $0 > futureLimit } ?? false) {
            let cutoff = input.nowMs - Int64(input.keepDays) * 86_400_000
            let aged = remaining.filter { $0.endMs < cutoff }
            deletions += aged
            used -= aged.reduce(0) { $0 + $1.bytes }
            remaining.removeAll { $0.endMs < cutoff }
        }

        // Size: oldest start first, across all cameras.
        for candidate in remaining {
            guard used > input.maximumBytes else { break }
            deletions.append(candidate)
            used -= candidate.bytes
        }
        return deletions
    }
}
