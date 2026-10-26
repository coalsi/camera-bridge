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

    // MARK: With an archive drive

    /// The archive drive as retention sees it, given only while it is connected, its files are loaded and it answers (otherwise there is no
    /// archive and the plan is `plan(_:)` exactly).
    struct ArchiveInput: Sendable {
        /// Every file on the archive drive (all closed).
        var closed: [RetentionCandidate]
        /// What the archive keeps its files under: its size minus twice its floor (`ArchiveStorageStatus.effectiveMaximumBytes` with no chosen limit).
        var maximumBytes: UInt64
        /// Measured free space of the archive, and the free space it never goes below.
        var freeBytes: UInt64
        var floorBytes: UInt64
        /// Files of the box that are not moved (their move failed on their side, or the archive has another file of that name): they go as today.
        var unmovable: Set<String> = []
        /// The box's last line (`ArchiveStorageStatus.hardMaximumBytes`): above it the oldest are deleted as today even with an archive, so moves
        /// that lag behind (a slow or stuck USB drive) never let the box's disk fill to the point where recording pauses.
        var mainHardMaximumBytes: UInt64
    }

    /// What one pass of retention does with an archive drive.
    struct TieredPlan: Sendable, Equatable {
        /// Files deleted from the box: aged ones, then the size rule's (oldest first).
        var deletions: [RetentionCandidate] = []
        /// Files the size rule moves to the archive, oldest first.
        var moves: [RetentionCandidate] = []
        /// The archive's own retention: aged files, then the oldest to make room (never a file newer than what comes in).
        var archiveDeletions: [RetentionCandidate] = []
    }

    /// `plan(_:)` with an archive drive. Without one (`archive == nil`) it is `plan(_:)`, unchanged. With one:
    /// 1. Age, on both drives: files that ended before the keep time are deleted where they are (skipped while the clock looks wrong).
    /// 2. The archive over its own maximum by itself (a smaller drive): its oldest files go until it fits.
    /// 3. Size, on the box: over `mainHardMaximumBytes` the oldest are deleted (as today); over `maximumBytes` they leave the box oldest first,
    ///    each moved when the archive can take it within its maximum and above its floor, after the archive let go of what is older than it (its
    ///    own files, or a file planned to move in this pass, which is then deleted instead). A file the archive cannot take is deleted as today.
    ///    So the recordings kept, on both drives together, are always the newest.
    static func plan(_ input: Input, archive: ArchiveInput?) -> TieredPlan {
        guard let archive else { return TieredPlan(deletions: plan(input)) }
        let order: (RetentionCandidate, RetentionCandidate) -> Bool = { ($0.startMs, $0.segment) < ($1.startMs, $1.segment) }
        var result = TieredPlan()
        var used = input.closed.reduce(input.openBytes) { $0 + $1.bytes }
        var remaining = input.closed.sorted(by: order)
        var archived = archive.closed.sorted(by: order)

        // 1. Age, both drives.
        let futureLimit = input.nowMs + Int64(ArchiveConstants.futureFileGuard * 1_000)
        if !(input.newestStartMs.map { $0 > futureLimit } ?? false) {
            let cutoff = input.nowMs - Int64(input.keepDays) * 86_400_000
            let aged = remaining.filter { $0.endMs < cutoff }
            result.deletions += aged
            used -= aged.reduce(0) { $0 + $1.bytes }
            remaining.removeAll { $0.endMs < cutoff }
            result.archiveDeletions += archived.filter { $0.endMs < cutoff }
            archived.removeAll { $0.endMs < cutoff }
        }

        // 2. The archive's own maximum.
        var archiveUsed = archived.reduce(0) { $0 + $1.bytes }
        var free = archive.freeBytes
        for file in result.archiveDeletions { free = free.addingReportingOverflow(file.bytes).partialValue }
        while archiveUsed > archive.maximumBytes, !archived.isEmpty {
            let oldest = archived.removeFirst()
            result.archiveDeletions.append(oldest)
            archiveUsed -= oldest.bytes
            free = free.addingReportingOverflow(oldest.bytes).partialValue
        }

        // 3. Size on the box. What will be on the archive, oldest first: its files and the files planned to move (`incoming`).
        var residents: [(file: RetentionCandidate, incoming: Bool)] = archived.map { ($0, false) }
        var sizeDeletions: [RetentionCandidate] = []
        var moves: [RetentionCandidate] = []
        func fits(_ bytes: UInt64) -> Bool {
            let (total, overflow) = archiveUsed.addingReportingOverflow(bytes)
            let (needed, neededOverflow) = archive.floorBytes.addingReportingOverflow(bytes)
            return !overflow && !neededOverflow && total <= archive.maximumBytes && free >= needed
        }
        for candidate in remaining {
            guard used > input.maximumBytes else { break }
            let overHardLimit = used > archive.mainHardMaximumBytes
            used -= candidate.bytes
            if overHardLimit || archive.unmovable.contains(candidate.segment) {
                sizeDeletions.append(candidate)
                continue
            }
            while !fits(candidate.bytes), let first = residents.first, order(first.file, candidate) {
                residents.removeFirst()
                archiveUsed -= first.file.bytes
                free = free.addingReportingOverflow(first.file.bytes).partialValue
                if first.incoming {
                    moves.removeAll { $0.segment == first.file.segment && $0.camera == first.file.camera }
                    sizeDeletions.append(first.file)
                } else {
                    result.archiveDeletions.append(first.file)
                }
            }
            guard fits(candidate.bytes) else {
                sizeDeletions.append(candidate)
                continue
            }
            moves.append(candidate)
            archiveUsed += candidate.bytes
            free -= candidate.bytes
            let position = residents.firstIndex { order(candidate, $0.file) } ?? residents.count
            residents.insert((candidate, true), at: position)
        }
        result.deletions += sizeDeletions.sorted(by: order)
        result.moves = moves
        return result
    }
}
