import Foundation

// The types of exporting a clip (docs/superpowers/specs/2026-10-12-export-clip-design.md, 3.1): the request, the plan that says exactly what the file
// will be before a byte is written, the errors, and the two protocols the Mac app and the box's web routes talk to. The planner, the writer and the
// exporter that implement `ClipExporting` have files of their own; `ClipPartTables` is the only package type the plan refers to, so this file stands
// alone. Foundation only: BridgeEngine has no Apple-only framework.

/// How much one export may take, and how a gap between two recorded fragments is bridged (spec 1 and 3.3).
public struct ClipLimits: Sendable, Equatable {
    public var maxSecondsPerCamera: Int
    public var maxTotalBytes: Int64
    /// Gaps up to this long are held (frozen picture); longer ones are skipped.
    public var maxHold: TimeInterval
    /// A wall-clock difference smaller than this between fragments is continuity.
    public var continuity: TimeInterval
    public init(maxSecondsPerCamera: Int, maxTotalBytes: Int64, maxHold: TimeInterval, continuity: TimeInterval) {
        self.maxSecondsPerCamera = maxSecondsPerCamera
        self.maxTotalBytes = maxTotalBytes
        self.maxHold = maxHold
        self.continuity = continuity
    }
    /// Two hours of one camera and 20 GiB in all; a gap under 1 s is continuous, up to 10 s it is held, longer it is skipped.
    public static let standard = ClipLimits(maxSecondsPerCamera: 7_200, maxTotalBytes: 20 << 30, maxHold: 10, continuity: 1)
}

/// One camera and the stretch of its recordings to cut.
public struct ClipRequest: Sendable, Equatable {
    public var camera: UUID
    public var cameraName: String
    public var start: Date
    public var end: Date
    /// Used for file names only.
    public var timeZone: TimeZone
    public init(camera: UUID, cameraName: String, start: Date, end: Date, timeZone: TimeZone = .current) {
        self.camera = camera
        self.cameraName = cameraName
        self.start = start
        self.end = end
        self.timeZone = timeZone
    }
}

/// A stretch inside the range with no recording between two fragments.
public struct ClipGap: Sendable, Equatable {
    public var from: Date
    public var to: Date
    /// True: the picture freezes for the gap; false: the clip jumps over it.
    public var held: Bool
    public init(from: Date, to: Date, held: Bool) { self.from = from; self.to = to; self.held = held }
}

/// One output file. More than one only when the codec settings change inside the range.
public struct ClipPart: Sendable, Equatable {
    /// 1-based, and the number of parts of this camera's clip.
    public var index: Int
    public var count: Int
    /// The first picture (the key picture at or before the requested start) and the end of the last picture, holds included.
    public var start: Date
    public var end: Date
    /// Requested start minus `start`, never negative.
    public var leadIn: TimeInterval
    public var byteCount: Int64
    public var sampleCount: Int
    public var fileName: String
    public init(index: Int, count: Int, start: Date, end: Date, leadIn: TimeInterval, byteCount: Int64, sampleCount: Int, fileName: String) {
        self.index = index; self.count = count; self.start = start; self.end = end
        self.leadIn = leadIn; self.byteCount = byteCount; self.sampleCount = sampleCount; self.fileName = fileName
    }
}

/// What an export will write: the parts with their exact sizes, the gaps, and (for the writer) the sample tables. Made by a planner after reading
/// fragment headers; a fake in another target makes one through the public initializer.
public struct ClipPlan: Sendable {
    public let request: ClipRequest
    public let parts: [ClipPart]
    public let gaps: [ClipGap]
    /// Some file in the range has sound that the clip could not carry (the clip carries the recordings' AAC sound when it can).
    public let soundOmitted: Bool
    /// One entry per part; empty for plans made by fakes.
    package let tables: [ClipPartTables]
    public var byteCount: Int64 { parts.reduce(0) { $0 + $1.byteCount } }
    public var duration: TimeInterval { parts.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
    /// For fakes in other targets' tests (no tables).
    public init(request: ClipRequest, parts: [ClipPart], gaps: [ClipGap], soundOmitted: Bool) {
        self.init(request: request, parts: parts, gaps: gaps, soundOmitted: soundOmitted, tables: [])
    }
    package init(request: ClipRequest, parts: [ClipPart], gaps: [ClipGap], soundOmitted: Bool, tables: [ClipPartTables]) {
        self.request = request; self.parts = parts; self.gaps = gaps; self.soundOmitted = soundOmitted; self.tables = tables
    }
}

/// Why a plan or an export stopped. Every case has a sentence in the Mac app and a status on the box.
public enum ClipError: Error, Equatable, Sendable {
    /// No footage at all in the range.
    case nothingRecorded
    /// The archive is still loading.
    case notReady
    /// The recordings folder is not available.
    case driveGone
    /// A fragment could not be read or parsed.
    case damaged(at: Date)
    /// More than `maxSeconds` of one camera.
    case tooLong(maxSeconds: Int)
    /// More than `maxBytes` in all.
    case tooLarge(maxBytes: Int64)
    case cancelled
    /// The destination refused or ran out of space.
    case sink(String)
}

/// Where the bytes go: the Mac's file, the HTTP body, a test's counter. Each call is one write, in order.
public protocol ClipSink: Sendable {
    func write(_ bytes: Data) async throws
}

public protocol ClipExporting: Sendable {
    /// A dry run: reads fragment headers only; throws `ClipError`.
    func plan(_ request: ClipRequest) async throws -> ClipPlan
    /// Writes part `part` (1-based) of `plan` to `sink`; `progress` gets the bytes written so far.
    func export(_ plan: ClipPlan, part: Int, to sink: any ClipSink, progress: @Sendable (Int64) -> Void) async throws
}

// MARK: Planner to writer (package)

/// One video sample as it goes into the sample tables, in decode order.
package struct ClipSample: Sendable, Equatable {
    package var size: UInt32
    /// 90 kHz ticks; a held gap lengthens the last sample before it.
    package var duration: UInt32
    package var compositionOffset: Int32
    package var isSync: Bool
    package init(size: UInt32, duration: UInt32, compositionOffset: Int32, isSync: Bool) {
        self.size = size
        self.duration = duration
        self.compositionOffset = compositionOffset
        self.isSync = isSync
    }
}

/// Bytes to copy from one fragment: `length` bytes starting `skipBytes` into the fragment's `.fragment` read
/// (`skipBytes == fragment.headerLength`, so the first copied byte is the first video byte); a trimmed fragment copies a prefix.
package struct ClipCopy: Sendable, Equatable {
    package var fragment: ArchiveFragment
    package var skipBytes: Int
    package var length: Int
    package var firstSample: Int
    package var sampleCount: Int
    package init(fragment: ArchiveFragment, skipBytes: Int, length: Int, firstSample: Int, sampleCount: Int) {
        self.fragment = fragment
        self.skipBytes = skipBytes
        self.length = length
        self.firstSample = firstSample
        self.sampleCount = sampleCount
    }
}

/// One sound sample (an AAC frame) as it goes into the sample tables, in order.
package struct ClipSoundSample: Sendable, Equatable {
    package var size: UInt32
    /// Ticks of the sound's timescale; lengthened where the picture holds still or a gap is skipped, so the sound stays with the picture.
    package var duration: UInt32
    package init(size: UInt32, duration: UInt32) {
        self.size = size
        self.duration = duration
    }
}

/// The sound track of a part: its samples, the bytes to copy (each right after the pictures of the same fragment in the `mdat`), and how long after
/// the first picture it begins.
package struct ClipSoundTables: Sendable, Equatable {
    package var samples: [ClipSoundSample]
    package var copies: [ClipCopy]
    /// For each copy, the index of the picture copy (same fragment) it follows.
    package var follows: [Int]
    /// Ticks of `timescale` between the first picture and the first sound (an empty edit in the clip).
    package var leadTicks: Int64
    package var timescale: UInt32
    package init(samples: [ClipSoundSample], copies: [ClipCopy], follows: [Int], leadTicks: Int64, timescale: UInt32) {
        self.samples = samples
        self.copies = copies
        self.follows = follows
        self.leadTicks = leadTicks
        self.timescale = timescale
    }
}

/// Everything the writer needs for one part: no archive access, no wall-clock logic.
package struct ClipPartTables: Sendable {
    /// `ftyp` + `moov` of the part's first file (`stsd`, `hdlr`, `vmhd`, `dinf` are copied from it).
    package var initialization: Data
    package var samples: [ClipSample]
    /// In output order; one `stco` chunk per copy.
    package var copies: [ClipCopy]
    /// The first sample's wall time (creation time of the file).
    package var wallStart: Date
    package var width: Int
    package var height: Int
    /// The recordings' sound, nil without.
    package var sound: ClipSoundTables?
    package init(initialization: Data, samples: [ClipSample], copies: [ClipCopy], wallStart: Date, width: Int, height: Int, sound: ClipSoundTables? = nil) {
        self.initialization = initialization
        self.samples = samples
        self.copies = copies
        self.wallStart = wallStart
        self.width = width
        self.height = height
        self.sound = sound
    }
}
