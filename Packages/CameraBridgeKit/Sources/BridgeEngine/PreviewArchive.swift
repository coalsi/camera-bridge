import FMP4
import Foundation
import MediaCore
import Synchronization

/// Made-up recordings for the preview engine's `nvr` scenario (`-previewEngine YES -demoScenario nvr`; sample data, nothing on disk): a daily rhythm
/// of activity with bursts, a gap, and a camera that stopped recording, so the timeline, the grid and every tile state can be looked at. The video is
/// real: a short synthetic clip (two groups of pictures) is encoded and muxed once, and served for every fragment. The player takes the times of
/// the frames from the fragment, not from the bytes, so one clip fills every second of the archive. Hosts, names and times are sample data.
final class PreviewArchive: ArchiveReading, Sendable {
    struct Recording: Sendable {
        var camera: UUID
        var oldest: Date
        var newest: Date
        /// True for a camera that is recording now: its newest fragment follows the clock (`liveLag` behind it) instead of staying at `newest`.
        var followsClock = false
    }

    /// A fragment is one group of pictures of two seconds, so every fragment starts with a keyframe.
    static let fragmentDuration: TimeInterval = 2
    static let fragmentsPerFile = 450
    /// What the sample cameras' median activity is (bytes per second).
    static let typicalLevel = 2_400.0
    /// How far behind the clock the newest fragment of a recording camera is (a fragment is written when its two seconds are over).
    static let liveLag: TimeInterval = 2.5

    private struct FileKeys {
        var byKey: [String: (camera: UUID, file: Int)] = [:]
        /// How many files of each camera are in `byKey`.
        var filled: [UUID: Int] = [:]
    }

    private let recordings: [UUID: Recording]
    private let gap: Range<Date>
    private let codecs: any MediaCodecs
    private let clock: @Sendable () -> Date
    private let fileKeys = Mutex(FileKeys())
    private let clipTask = Mutex<Task<PreviewClip?, Never>?>(nil)

    /// `gap`: a period in which no camera recorded. Each recording runs from `oldest` to `newest` (the fragments in between that do not touch the gap);
    /// a recording that `followsClock` runs up to the clock's time (read through `clock`) minus `liveLag`.
    init(recordings: [Recording], gap: Range<Date>, codecs: any MediaCodecs, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.recordings = Dictionary(uniqueKeysWithValues: recordings.map { ($0.camera, $0) })
        self.gap = gap
        self.codecs = codecs
        self.clock = clock
    }

    /// The end of what `recording` has recorded now.
    private func newest(_ recording: Recording) -> Date {
        recording.followsClock ? max(recording.newest, clock().addingTimeInterval(-Self.liveLag)) : recording.newest
    }

    /// The file of `camera` that `fileKey` names, found among the files its recording has written so far (the table grows with the recording).
    private func file(forKey fileKey: String, camera: UUID) -> Int? {
        guard let recording = recordings[camera] else { return nil }
        let last = Int(newest(recording).timeIntervalSince(recording.oldest) / Self.fragmentDuration) / Self.fragmentsPerFile
        return fileKeys.withLock { keys in
            var next = keys.filled[camera] ?? 0
            while next <= last {
                keys.byKey[ArchiveIdentity.fileKey(forSegment: Self.segment(recording, file: next))] = (camera, next)
                next += 1
            }
            keys.filled[camera] = max(next, keys.filled[camera] ?? 0)
            guard let entry = keys.byKey[fileKey], entry.camera == camera else { return nil }
            return entry.file
        }
    }

    var isReady: Bool { true }
    var catalogVersion: Int { 1 }

    func extent(camera: UUID) -> ArchiveExtent? {
        recordings[camera].map { ArchiveExtent(oldest: $0.oldest, newest: newest($0), typicalGOP: Self.fragmentDuration) }
    }

    // MARK: Lookups

    func fragment(camera: UUID, containing time: Date) async -> ArchiveFragment? {
        guard let recording = recordings[camera], time >= recording.oldest else { return nil }
        return make(recording, index: Int((time.timeIntervalSince(recording.oldest) / Self.fragmentDuration).rounded(.down)))
    }

    func fragment(camera: UUID, startingAfter time: Date) async -> ArchiveFragment? {
        guard let recording = recordings[camera] else { return nil }
        guard time >= recording.oldest else { return make(recording, index: 0) ?? make(recording, index: Self.firstIndex(after: gap.upperBound, in: recording)) }
        var index = Int((time.timeIntervalSince(recording.oldest) / Self.fragmentDuration).rounded(.down)) + 1
        for _ in 0..<2 {
            if let found = make(recording, index: index) { return found }
            let start = recording.oldest.addingTimeInterval(Double(index) * Self.fragmentDuration)
            guard start < newest(recording), start >= gap.lowerBound.addingTimeInterval(-Self.fragmentDuration), start < gap.upperBound else { return nil }
            index = Self.firstIndex(after: gap.upperBound, in: recording)   // inside the gap: the first fragment after it
        }
        return nil
    }

    func fragment(camera: UUID, id: String) async -> ArchiveFragment? {
        guard let parts = ArchiveIdentity.parseFragmentID(id), let recording = recordings[camera], parts.index < Self.fragmentsPerFile,
              let file = file(forKey: parts.fileKey, camera: camera) else { return nil }
        return make(recording, index: file * Self.fragmentsPerFile + parts.index)
    }

    private static func firstIndex(after time: Date, in recording: Recording) -> Int {
        Int((time.timeIntervalSince(recording.oldest) / fragmentDuration).rounded(.up))
    }

    private func make(_ recording: Recording, index: Int) -> ArchiveFragment? {
        guard index >= 0 else { return nil }
        let start = recording.oldest.addingTimeInterval(Double(index) * Self.fragmentDuration)
        let end = start.addingTimeInterval(Self.fragmentDuration)
        guard end <= newest(recording), !(start < gap.upperBound && end > gap.lowerBound) else { return nil }
        let file = index / Self.fragmentsPerFile
        return ArchiveFragment(camera: recording.camera, segment: Self.segment(recording, file: file), index: index % Self.fragmentsPerFile, start: start,
                               duration: Self.fragmentDuration, mediaStart: Int64(index % Self.fragmentsPerFile) * 180_000, hasKeyframe: true, gopStart: start,
                               backToKey: 0, byteLength: 100_000)
    }

    private static func segment(_ recording: Recording, file: Int) -> String {
        let start = recording.oldest.addingTimeInterval(Double(file * fragmentsPerFile) * fragmentDuration)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1)
        let time = String(format: "%02d-%02d-%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return "\(recording.camera.uuidString)/\(date)/\(time)"
    }

    // MARK: Bytes

    func read(_ fragment: ArchiveFragment, _ part: ArchiveReadPart) async throws -> Data {
        // One clip stands for every fragment of the made-up recordings, so there are no headers to plan a file from: nothing is exported from here.
        let nothingToExport = ArchiveError.unreadable("The preview has no recordings to export.")
        guard part != .header else { throw nothingToExport }
        guard let clip = await clip() else { throw ArchiveError.unreadable("The sample recordings have no pictures in this build.") }
        switch part {
        case .initialization: return clip.initialization
        case .fragment: return clip.fragments[fragment.index % 2]
        case .keyframe: return clip.keyframes[fragment.index % 2]
        case .header: throw nothingToExport
        }
    }

    private func clip() async -> PreviewClip? {
        let task = clipTask.withLock { stored -> Task<PreviewClip?, Never> in
            if let stored { return stored }
            let codecs = codecs
            let created = Task { await PreviewClip.make(codecs: codecs) }
            stored = created
            return created
        }
        return await task.value
    }

    // MARK: Activity

    func activity(camera: UUID, range: Range<Date>, binCount: Int) async -> ArchiveActivity {
        let count = max(binCount, 1)
        let binDuration = range.upperBound.timeIntervalSince(range.lowerBound) / Double(count)
        guard let recording = recordings[camera], binDuration > 0 else {
            return ArchiveActivity(start: range.lowerBound, binDuration: max(binDuration, 0), bins: Array(repeating: .init(coverage: 0, level: 0, peak: 0), count: count),
                                   typical: nil, isComplete: true)
        }
        let recordedUntil = newest(recording)
        let bins = (0..<count).map { index -> ArchiveActivity.Bin in
            let start = range.lowerBound.addingTimeInterval(Double(index) * binDuration), end = start.addingTimeInterval(binDuration)
            let recorded = Self.overlap(start..<end, recording.oldest..<recordedUntil) - Self.overlap(start..<end, gap.clamped(to: recording.oldest..<recordedUntil))
            let coverage = max(0, min(1, recorded / binDuration))
            guard coverage > 0 else { return .init(coverage: 0, level: 0, peak: 0) }
            // A few samples across the bin (a minute apart at most): the bin's mean and its busiest moment.
            let samples = max(1, min(32, Int(binDuration / 60)))
            let levels = (0..<samples).map { Self.level(at: start.addingTimeInterval(binDuration * (Double($0) + 0.5) / Double(samples))) }
            return .init(coverage: coverage, level: levels.reduce(0, +) / Double(samples), peak: (levels.max() ?? 0) * 1.4)
        }
        return ArchiveActivity(start: range.lowerBound, binDuration: binDuration, bins: bins, typical: Self.typicalLevel, isComplete: true)
    }

    private static func overlap(_ a: Range<Date>, _ b: Range<Date>) -> TimeInterval {
        max(0, min(a.upperBound, b.upperBound).timeIntervalSince(max(a.lowerBound, b.lowerBound)))
    }

    /// Non-keyframe bytes per second at `time`: quiet at night, busier by day (a rhythm of 24 h), and now and then a minute of high activity.
    static func level(at time: Date) -> Double {
        let seconds = time.timeIntervalSinceReferenceDate
        let hour = (seconds / 3_600).truncatingRemainder(dividingBy: 24)
        let day = max(0, sin((hour - 5) / 24 * 2 * .pi))
        var hash = UInt64(bitPattern: Int64(seconds / 60)) &* 0x9E37_79B9_7F4A_7C15
        hash ^= hash >> 29
        let burst: Double = hash % 23 == 0 ? 6 : (hash % 7 == 0 ? 2 : 1)
        return (800 + 2_700 * day) * burst * (0.85 + 0.3 * Double((hash >> 40) & 0xFF) / 255)
    }
}

private extension Range where Bound == Date {
    /// This range cut to `limits` (an empty range at the lower bound when they do not meet).
    func clamped(to limits: Range<Date>) -> Range<Date> {
        let lower = Swift.min(Swift.max(lowerBound, limits.lowerBound), limits.upperBound)
        let upper = Swift.max(lower, Swift.min(upperBound, limits.upperBound))
        return lower..<upper
    }
}

/// The video of the sample recordings: an initialization segment, two fragments (two groups of pictures) and their keyframes as `.keyframe` reads
/// give them.
struct PreviewClip: Sendable {
    var initialization: Data
    var fragments: [Data]
    var keyframes: [Data]

    /// Encodes about five seconds of a moving test pattern and muxes its first two groups of pictures; nil when the codecs cannot (Linux, tests).
    static func make(codecs: any MediaCodecs) async -> PreviewClip? {
        let source = codecs.makeSyntheticSource(displayName: "Sample recording", width: 1_280, height: 720, fps: 15, keyframeInterval: .seconds(2), audio: nil, audioSampleRate: 0)
        var groups: [[EncodedVideoFrame]] = []
        do {
            for try await sample in try await source.samples() {
                guard case .video(let frame) = sample else { continue }
                if frame.isKeyframe {
                    if groups.count == 2 { break }
                    groups.append([])
                }
                if !groups.isEmpty { groups[groups.count - 1].append(frame) }
            }
        } catch {}
        await source.stop()
        guard groups.count == 2, let first = groups[0].first, let second = groups[1].first else { return nil }
        do {
            let configuration = FMP4Configuration(video: first.format, audio: nil, writeProducerReferenceTime: true)
            var muxer = try FMP4Muxer(configuration: configuration)
            let initialization = muxer.initializationSegment()
            let one = try muxer.fragment(video: groups[0], audio: [], nextDecodeTime: second.dts ?? second.pts)
            let two = try muxer.fragment(video: groups[1], audio: [], nextDecodeTime: nil)
            var keyframes: [Data] = []
            for group in groups {
                var single = try FMP4Muxer(configuration: configuration)
                let piece = try single.fragment(video: [group[0]], audio: [], nextDecodeTime: nil)
                guard let mdat = try MP4BoxReader.parse(piece).first(where: { $0.type == "mdat" }) else { return nil }
                keyframes.append(piece.subdata(in: mdat.payloadOffset..<(mdat.offset + mdat.size)))   // the one sample, length-prefixed
            }
            return PreviewClip(initialization: initialization, fragments: [one, two], keyframes: keyframes)
        } catch {
            return nil
        }
    }
}
