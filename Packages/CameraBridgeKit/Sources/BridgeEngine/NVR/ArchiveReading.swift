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

        public init(coverage: Double, level: Double, peak: Double) {
            self.coverage = coverage
            self.level = level
            self.peak = peak
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
