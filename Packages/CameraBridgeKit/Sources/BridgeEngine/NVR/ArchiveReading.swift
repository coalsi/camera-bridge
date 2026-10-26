import Foundation

/// The reading side of the NVR: what the Mac app's player and the box's web routes use to find and read recorded video. The one
/// seam between the recorder/store (BridgeEngine/NVR) and every consumer. Foundation only; implemented by `ArchiveStore`.
public protocol ArchiveReading: Sendable {
    /// Activity per bin over `range`: `binCount` bins of equal length (the caller aligns `range.lowerBound` to a multiple of the bin length).
    func activity(camera: UUID, range: Range<Date>, binCount: Int) async -> ArchiveActivity
    /// The fragment with `start <= time < end`; nil in a gap. A later-started file wins an overlap.
    func fragment(camera: UUID, containing time: Date) async -> ArchiveFragment?
    /// The first fragment with `start > time`; crosses gaps and files.
    func fragment(camera: UUID, startingAfter time: Date) async -> ArchiveFragment?
    /// An exact lookup by `ArchiveFragment.id` in the cached tables; nil when retention removed it (or the id is unknown).
    func fragment(camera: UUID, id: String) async -> ArchiveFragment?
    /// The bytes of `part` of `fragment`. Throws `ArchiveError`; `.fileGone` and `.timedOut` mean "treat as a gap".
    func read(_ fragment: ArchiveFragment, _ part: ArchiveReadPart) async throws -> Data
    /// Memory only. Nil when the camera has no recording.
    func extent(camera: UUID) -> ArchiveExtent?
    /// +1 per written fragment, closed file, deletion and rollup batch.
    var catalogVersion: Int { get }
    /// False while the store repairs and loads its catalog after start (and for the placeholder archive): every lookup then answers nil or empty.
    var isReady: Bool { get }
    /// The cameras' events that began in `range`, newest first, at most `limit` (`ArchiveEventLog`: kept beside the recordings, whether or not
    /// video was recorded, and deleted with them). A page never splits a millisecond: when `limit` would cut through the events of one, they are
    /// left for the next page (asked with the range ending at the oldest start), unless they are all the page has, which then holds them all.
    /// Empty when no place for recordings is chosen. Throws `ArchiveUnavailable` while the catalog loads or the folder is missing (not "no
    /// events": ask again later), `ArchiveError.timedOut` when the drive does not answer. The default has none.
    func events(cameras: [UUID], range: Range<Date>, limit: Int) async throws -> ArchiveEventPage
    /// The stretch of `camera`'s recordings around `time` that is on the archive drive while that drive is not connected (it plays again when it is
    /// plugged back in): what a player shows instead of a gap there. Memory only; nil anywhere else. The default has none.
    func awaySpan(camera: UUID, containing time: Date) -> DateInterval?
}

extension ArchiveReading {
    public func events(cameras: [UUID], range: Range<Date>, limit: Int) async throws -> ArchiveEventPage {
        ArchiveEventPage(events: [], isTruncated: false)
    }

    public func awaySpan(camera: UUID, containing time: Date) -> DateInterval? { nil }
}

/// One event of a camera as the archive's event log keeps it.
public struct ArchiveEvent: Sendable, Equatable, Hashable, Identifiable {
    /// Unique per camera, stable across restarts, safe in a URL.
    public var id: String
    public var camera: UUID
    /// The bridge's word for it, as `SensorState.recentEvents` has it: "Motion", "Person", "Vehicle", "Doorbell ring", "Tamper", …
    public var kind: String
    public var start: Date
    /// Nil while it lasts, or when the bridge stopped before it ended.
    public var end: Date?
    /// The camera's recorder was writing when it began.
    public var hadVideo: Bool
    /// The recordings hold video of its start now (retention may have taken it since), or are still being written up to it.
    public var recorded: Bool
    /// What an AI service said it saw at the event's start, when the camera has descriptions on and one was written (the last one of the
    /// event's description lines in the log). The pictures it came from are not kept.
    public var description: EventDescription?

    public init(id: String, camera: UUID, kind: String, start: Date, end: Date? = nil, hadVideo: Bool = false, recorded: Bool = false,
                description: EventDescription? = nil) {
        self.id = id
        self.camera = camera
        self.kind = kind
        self.start = start
        self.end = end
        self.hadVideo = hadVideo
        self.recorded = recorded
        self.description = description
    }
}

/// Events newest first; `isTruncated` when `limit` cut older ones in the range off.
public struct ArchiveEventPage: Sendable, Equatable {
    public var events: [ArchiveEvent]
    public var isTruncated: Bool

    public init(events: [ArchiveEvent], isTruncated: Bool) {
        self.events = events
        self.isTruncated = isTruncated
    }
}

/// The archive cannot say which events there are now, and an empty answer would be wrong: ask again later.
public enum ArchiveUnavailable: Error, Equatable, Sendable {
    /// The store is still loading the folder's catalog.
    case loading
    /// The recordings folder is not there (its drive is away).
    case folderMissing
}

/// One fragment: `prft` + `moof` + `mdat`, at most `ArchiveConstants.fragmentMaximumDuration` of video, 16 MiB.
public struct ArchiveFragment: Sendable, Equatable, Hashable {
    public let camera: UUID
    /// The mp4's path relative to the recordings folder, without extension: "<camera directory>/<yyyy-MM-dd>/<HH-mm-ss>". Stable across launches.
    public let segment: String
    /// `ArchiveIdentity.fileKey(forSegment: segment)`: 12 lowercase hex digits.
    public let fileKey: String
    /// Position in the file's fragment table.
    public let index: Int
    /// The derived start (Mac spec 4.3: file anchor + media time).
    public let start: Date
    public let duration: TimeInterval
    /// `tfdt` of the video track in 90 kHz ticks, counted from the file's first fragment (so 0 for it).
    public let mediaStart: Int64
    /// The fragment's first video sample is a keyframe (`keyLength > 0`).
    public let hasKeyframe: Bool
    /// The start of the fragment that holds the governing keyframe (this fragment's own start when `hasKeyframe`).
    public let gopStart: Date
    /// Fragments back to the one holding the governing keyframe (0 when `hasKeyframe`). A group of pictures never spans files.
    public let backToKey: Int
    /// `prft` through the end of `mdat`.
    public let byteLength: Int

    // Reader-internal (package): where the bytes are and what the index recorded about them.
    package var byteOffset: UInt64 = 0
    package var headerLength: Int = 0
    package var keyLength: Int = 0
    package var nonKeyBytes: Int = 0
    package var samples: Int = 0

    public var end: Date { start.addingTimeInterval(duration) }
    /// "<fileKey>.<index>": stable across restarts, unique per camera, safe in a URL.
    public var id: String { ArchiveIdentity.fragmentID(fileKey: fileKey, index: index) }

    public init(camera: UUID, segment: String, index: Int, start: Date, duration: TimeInterval, mediaStart: Int64, hasKeyframe: Bool,
                gopStart: Date, backToKey: Int, byteLength: Int) {
        self.camera = camera
        self.segment = segment
        self.fileKey = ArchiveIdentity.fileKey(forSegment: segment)
        self.index = index
        self.start = start
        self.duration = duration
        self.mediaStart = mediaStart
        self.hasKeyframe = hasKeyframe
        self.gopStart = gopStart
        self.backToKey = backToKey
        self.byteLength = byteLength
    }
}

public enum ArchiveReadPart: Sendable, Equatable {
    /// `ftyp` + `moov` of the fragment's file (bytes 0..<initLength).
    case initialization
    /// The first video sample only (length-prefixed NAL units): one positioned read of `keyLength` bytes. Throws `.noKeyframe` when `!hasKeyframe`.
    case keyframe
    /// `prft` + `moof` + `mdat`.
    case fragment
    /// `prft` + `moof` + the 8-byte `mdat` header: the first `headerLength` bytes of the fragment, up to its first video byte. What a clip is planned
    /// from, before any video is read.
    case header
}

public struct ArchiveExtent: Sendable, Equatable {
    public var oldest: Date
    /// The end of the newest written fragment.
    public var newest: Date
    /// The typical keyframe-to-keyframe time, nil before it is known.
    public var typicalGOP: TimeInterval?

    public init(oldest: Date, newest: Date, typicalGOP: TimeInterval? = nil) {
        self.oldest = oldest
        self.newest = newest
        self.typicalGOP = typicalGOP
    }
}

public struct ArchiveActivity: Sendable, Equatable {
    public struct Bin: Sendable, Equatable {
        /// 0...1: how much of the bin has recorded video.
        public var coverage: Double
        /// Mean non-keyframe bytes per second over the recorded part of the bin.
        public var level: Double
        /// The busiest fragment's bytes per second in the bin.
        public var peak: Double
        /// 0...1: how much of the bin is recorded on the archive drive while it is not connected (not in `coverage`: it cannot be played now).
        public var away: Double

        public init(coverage: Double, level: Double, peak: Double, away: Double = 0) {
            self.coverage = coverage
            self.level = level
            self.peak = peak
            self.away = away
        }
    }

    public var start: Date
    public var binDuration: TimeInterval
    public var bins: [Bin]
    /// Median non-keyframe bytes per second over the recorded minutes of the last 24 h; nil under 30 min of recorded video.
    public var typical: Double?
    /// False while older rollups are still loading; callers ask again when `catalogVersion` changes.
    public var isComplete: Bool

    public init(start: Date, binDuration: TimeInterval, bins: [Bin], typical: Double?, isComplete: Bool) {
        self.start = start
        self.binDuration = binDuration
        self.bins = bins
        self.typical = typical
        self.isComplete = isComplete
    }
}

public enum ArchiveError: Error, Equatable, Sendable {
    /// The file was removed or the folder is not there: treat as a gap.
    case fileGone
    /// No answer within `ArchiveConstants.readDeadline`: treat as a gap.
    case timedOut
    /// The bytes are not what the index said (a damaged fragment), or the archive cannot answer.
    case unreadable(String)
    /// `.keyframe` was asked of a fragment that does not start with one.
    case noKeyframe
}
